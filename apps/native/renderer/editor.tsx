// 原生客户端的「可编辑简历纸面」页（Mac WKWebView）。
//
// 直接挂载 Web 编辑器同一套 TipTap 扩展、分页、斜杠菜单与选区工具栏，纸面排版、编辑行为和工具栏与 Web 一致；
// 外框、面板、保存由原生负责。页面通过 drawoffer-paper:// 自定义 scheme 加载，
// 纸面里的 /api/... 图片与图片上传由原生带登录凭据转发，页面本身不持有凭据。
//
// 协议（editor protocol 1）：
//   原生 → 页面：window.drawofferEditor.load(payload) / setStyle(style) / setView(view) / replaceData(data) / command(cmd)
//   页面 → 原生：{ type: "ready" } / { type: "changed", data, style } / { type: "history", canUndo, canRedo }
//                { type: "ask", unitId, lineId, text, instruction } / { type: "zoom", zoom } / { type: "error", message }
import "../../web/src/styles.css";
import "../../web/src/design-system/tokens.css";
import "../../web/src/design-system/utilities.css";
import "../../web/src/app.css";
import "../../web/src/muse-templates.css";
import "../../web/src/v3/v3.css";
import "../../web/src/features/workbench/workbench-v3.css";
import type { Editor, JSONContent } from "@tiptap/core";
import { BubbleMenu, EditorContent, useEditor } from "@tiptap/react";
import { TextSelection } from "@tiptap/pm/state";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import type { Instance as TippyInstance } from "tippy.js";
import {
  editorSettingsToStyle,
  resumePresentationAccentColor,
  styleToEditorSettings,
  withResumePresentationAvatarSize,
  type CanonicalResumeDocument,
  type CanonicalResumePresentation,
} from "../../web/src/api/resumeContract";
import { normalizeResumeFontFamily } from "../../web/src/lib/resumeFontCatalog";
import { editorContentForResume, useResumeStore } from "../../web/src/store/resumeStore";
import { resumeEditorExtensions } from "../../web/src/features/workbench/editorExtensions";
import { editorDocumentUserAvatar, resumeDocumentFromEditorDocument } from "../../web/src/features/workbench/resumeEditorPersistence";
import { resumeEditorAvatarWidth } from "../../web/src/features/workbench/templateLayout";
import { PaginationExtension } from "../../web/src/features/workbench/paginationPlugin";
import { LineInsertMenuExtension, SlashCommandMenu, slashCommandQuery, type CommandMenuState } from "../../web/src/features/workbench/slashCommand";
import { SelectionFormattingToolbar } from "../../web/src/features/workbench/WorkbenchToolbar";
import { SelectionAsk } from "../../web/src/features/workbench/sectionFocus/SelectionAsk";
import {
  createSelectionBubbleAnchor,
  refreshSelectionBubblePosition,
  selectionBubbleContainer,
  selectionEndAnchorRect,
  shouldShowSelectionAgentBubble,
} from "../../web/src/features/workbench/selectionBubbleAnchor";
import { getSinglePageFitScale, getTwoPageFitScale, getWheelZoomScale } from "../../web/src/features/workbench/workbenchZoom";
import { liveResumePageMargins } from "../../web/src/features/preview/resumePageMargins";
import { jumpToSection } from "../../web/src/features/workbench/WorkbenchSectionOrderControl";
import { applySectionOrder, resetSectionOrder, resumeSectionOrderGroups, type ResumeSectionKind } from "../../web/src/features/workbench/resumeSectionOrder";
import { deleteOutlineSection, insertOutlineSection, renameOutlineSection } from "../../web/src/features/workbench/outlineModel";

type Payload = {
  resumeId: string;
  data: CanonicalResumeDocument;
  style: CanonicalResumePresentation;
  layout_plan?: unknown;
};
type View = { zoom: number; arrangement: "vertical" | "horizontal" };
type Command =
  | { type: "undo" } | { type: "redo" } | { type: "focus" }
  | { type: "jump"; nodeId: string | null }
  | { type: "reorder"; nodeIds: string[] }
  | { type: "reset-order" }
  | { type: "rename"; nodeId: string; title: string }
  | { type: "remove"; nodeId: string }
  | { type: "add"; kind: ResumeSectionKind; title: string };

declare global {
  interface Window {
    webkit?: { messageHandlers?: { drawoffer?: { postMessage(message: unknown): void } } };
    drawofferEditor: {
      load(payload: Payload): void;
      setStyle(style: CanonicalResumePresentation): void;
      setView(view: View): void;
      replaceData(data: CanonicalResumeDocument): void;
      command(command: Command): void;
    };
  }
}

function post(message: Record<string, unknown>) {
  if (window.webkit?.messageHandlers?.drawoffer) window.webkit.messageHandlers.drawoffer.postMessage(message);
  else console.info("[drawoffer-editor]", message);
}

// 与 Web 工作台相同：纸面基准 560 / A4 宽，再按画布可用宽度收缩
const A4_WIDTH_IN_CSS_PIXELS = (210 / 25.4) * 96;
const EDITOR_PAGE_BASE_SCALE = 560 / A4_WIDTH_IN_CSS_PIXELS;

const supportsCssZoom = typeof CSS !== "undefined" && typeof CSS.supports === "function" && CSS.supports("zoom", "1");

function currentSelectionRect(editor: Editor) {
  const { ranges } = editor.state.selection;
  const to = Math.max(...ranges.map((range) => range.$to.pos));
  return selectionEndAnchorRect(editor.view.coordsAtPos(to, -1));
}

// 与 Web `plainParagraphsFromHtml` 相同：编辑器内复制保留结构，外部 HTML 拍平为段落
function plainParagraphsFromHtml(html: string) {
  if (html.includes("data-pm-slice")) return html;
  const root = document.createElement("div");
  root.innerHTML = html;
  const blockTags = new Set(["ADDRESS", "ARTICLE", "BLOCKQUOTE", "DIV", "H1", "H2", "H3", "H4", "H5", "H6", "LI", "P", "PRE", "SECTION", "TR"]);
  const readNode = (node: Node): string => {
    if (node.nodeType === Node.TEXT_NODE) return node.textContent ?? "";
    if (!(node instanceof HTMLElement)) return "";
    if (node.tagName === "BR") return "\n";
    const content = Array.from(node.childNodes).map(readNode).join("");
    return blockTags.has(node.tagName) ? `${content}\n` : content;
  };
  const plain = Array.from(root.childNodes).map(readNode).join("").replace(/ /g, " ").trim();
  const escape = (value: string) => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return plain.split(/\n+/).map((line) => `<p>${escape(line) || "<br>"}</p>`).join("");
}

// Web `StableSelectionToolbarBubble`：工具栏跟随选区末端，缩小时一起缩小，放大不超过基准尺寸
function SelectionBubble({ editor, scale, children }: { editor: Editor; scale: number; children: ReactNode }) {
  const anchorRef = useRef<ReturnType<typeof createSelectionBubbleAnchor> | null>(null);
  const tippyRef = useRef<TippyInstance | null>(null);
  if (!anchorRef.current) anchorRef.current = createSelectionBubbleAnchor();
  const anchor = anchorRef.current;
  const bubbleScale = Math.min(scale, 1);
  useEffect(() => {
    const scrollArea = editor.view.dom.closest(".workbench-paper-scroll");
    const refresh = () => refreshSelectionBubblePosition(anchor, () => currentSelectionRect(editor), () => { void tippyRef.current?.popperInstance?.update(); });
    tippyRef.current?.setProps({ offset: [0, 8 * bubbleScale] });
    scrollArea?.addEventListener("scroll", refresh, { passive: true });
    window.addEventListener("resize", refresh, { passive: true });
    refresh();
    return () => {
      scrollArea?.removeEventListener("scroll", refresh);
      window.removeEventListener("resize", refresh);
    };
  }, [anchor, editor, scale, bubbleScale]);
  return (
    <BubbleMenu
      editor={editor}
      tippyOptions={{
        appendTo: () => selectionBubbleContainer(editor.view.dom, document.body),
        duration: 150,
        maxWidth: "none",
        placement: "bottom-start",
        offset: [0, 8 * bubbleScale],
        getReferenceClientRect: () => anchor.getRect(() => currentSelectionRect(editor)),
        onCreate: (instance) => { tippyRef.current = instance; },
        onDestroy: (instance) => { if (tippyRef.current === instance) tippyRef.current = null; },
      }}
      shouldShow={({ editor: current, view, from, to }) => {
        const visible = shouldShowSelectionAgentBubble({
          editable: current.isEditable,
          selectionEmpty: current.state.selection.empty,
          selectionIsText: current.state.selection instanceof TextSelection,
        });
        anchor.observe(visible ? { from, to } : { from, to: from }, () => selectionEndAnchorRect(view.coordsAtPos(to, -1)));
        return visible;
      }}
    >
      <div
        className={`selection-toolbar-bubble-scale${supportsCssZoom ? "" : " is-scale-fallback"}`}
        style={{ "--selection-toolbar-scale": bubbleScale } as React.CSSProperties}
      >
        {children}
      </div>
    </BubbleMenu>
  );
}

function settingsFor(style: CanonicalResumePresentation) {
  const settings = styleToEditorSettings(style);
  return { ...settings, fontFamily: normalizeResumeFontFamily(settings.fontFamily) };
}

// Web `resumeWorkbenchStyle`
function paperStyle(style: CanonicalResumePresentation, content: JSONContent | string) {
  const settings = settingsFor(style);
  const margins = liveResumePageMargins(settings, style);
  return {
    "--resume-avatar-width": `${resumeEditorAvatarWidth(content)}px`,
    "--resume-font-family": settings.fontFamily,
    "--resume-font-size": `${settings.fontSize}pt`,
    "--resume-line-height": settings.lineHeight,
    "--resume-page-margin-x": `${settings.pageMargin}mm`,
    "--resume-page-margin-y": `${settings.verticalPageMargin}mm`,
    "--resume-page-margin-top": `${margins.top}mm`,
    "--resume-page-margin-right": `${margins.right}mm`,
    "--resume-page-margin-bottom": `${margins.bottom}mm`,
    "--resume-page-margin-left": `${margins.left}mm`,
    "--preview-accent": resumePresentationAccentColor(style),
  } as React.CSSProperties;
}

function Workbench({ payload, styleOverride, view, dataOverride }: {
  payload: Payload;
  styleOverride: CanonicalResumePresentation | null;
  view: View;
  dataOverride: { data: CanonicalResumeDocument; sequence: number } | null;
}) {
  const style = styleOverride ?? payload.style;
  const dataRef = useRef(payload.data);
  const styleRef = useRef(style);
  styleRef.current = style;
  const [commandMenu, setCommandMenu] = useState<CommandMenuState | null>(null);
  const [width, setWidth] = useState(() => window.innerWidth);
  const [padding, setPadding] = useState(80);
  const scrollRef = useRef<HTMLDivElement>(null);
  const initial = useMemo(() => editorContentForResume({ data: payload.data, style: payload.style, layout_plan: payload.layout_plan as never }), [payload]);
  const [content, setContent] = useState<JSONContent | string>(initial);

  const report = (current: Editor) => {
    const json = current.getJSON();
    setContent(json);
    const data = resumeDocumentFromEditorDocument(json, dataRef.current);
    dataRef.current = data;
    const avatar = editorDocumentUserAvatar(json);
    const nextStyle = avatar ? withResumePresentationAvatarSize(styleRef.current, avatar.size) : styleRef.current;
    post({ type: "changed", data, style: nextStyle });
  };
  const reportHistory = (current: Editor) => post({ type: "history", canUndo: current.can().undo(), canRedo: current.can().redo() });

  const editor = useEditor({
    shouldRerenderOnTransaction: false,
    extensions: [...resumeEditorExtensions, PaginationExtension, LineInsertMenuExtension.configure({ onOpen: setCommandMenu })],
    content: initial,
    editorProps: { attributes: { class: "resume-content", spellcheck: "false" }, transformPastedHTML: plainParagraphsFromHtml },
    onCreate: ({ editor: current }) => { current.commands.blur(); reportHistory(current); },
    onUpdate: ({ editor: current }) => {
      report(current);
      reportHistory(current);
      const { from, $from } = current.state.selection;
      if (!current.state.selection.empty) { setCommandMenu(null); return; }
      const line = current.state.doc.textBetween($from.start(), from, "\n", "￼");
      const query = slashCommandQuery(line);
      if (query === null) { setCommandMenu((menu) => menu?.replaceRange ? null : menu); return; }
      const coordinates = current.view.coordsAtPos(from);
      setCommandMenu({
        x: Math.max(12, Math.min(coordinates.left, window.innerWidth - 244)),
        y: Math.max(12, Math.min(coordinates.bottom + 6, window.innerHeight - 380)),
        query,
        replaceRange: { from: from - query.length - 1, to: from },
      });
    },
  }, [payload]);

  // 原生替换正文（引导写入、AI 采纳、聚焦这段）：按当前模板重新排版，不进撤销历史
  useEffect(() => {
    if (!editor || !dataOverride) return;
    dataRef.current = dataOverride.data;
    const next = editorContentForResume({ data: dataOverride.data, style: styleRef.current, layout_plan: payload.layout_plan as never });
    editor.commands.setContent(next, false);
    setContent(next);
  }, [editor, dataOverride, payload.layout_plan]);

  useEffect(() => {
    if (!editor) return;
    const run = (command: Command) => {
      switch (command.type) {
        case "undo": editor.chain().focus().undo().run(); break;
        case "redo": editor.chain().focus().redo().run(); break;
        case "focus": editor.commands.focus(); break;
        case "jump": jumpToSection(editor, command.nodeId); break;
        case "reset-order": resetSectionOrder(editor); break;
        case "reorder":
          for (const group of resumeSectionOrderGroups(editor.getJSON())) {
            const ids = new Set(group.items.map((item) => item.nodeId).filter(Boolean));
            applySectionOrder(editor, group.side, command.nodeIds.filter((id) => ids.has(id)));
          }
          break;
        case "rename": renameOutlineSection(editor, command.nodeId, command.title); break;
        case "remove": if (deleteOutlineSection(editor, command.nodeId)) editor.view.focus(); break;
        case "add": if (insertOutlineSection(editor, command.kind, command.title)) editor.view.focus(); break;
      }
    };
    commandSink = run;
    return () => { if (commandSink === run) commandSink = null; };
  }, [editor]);

  useEffect(() => {
    const area = scrollRef.current;
    if (!area) return;
    const measure = () => {
      const computed = getComputedStyle(area);
      setWidth(area.clientWidth);
      setPadding((parseFloat(computed.paddingLeft) || 0) + (parseFloat(computed.paddingRight) || 0));
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(area);
    return () => observer.disconnect();
  }, []);

  useEffect(() => { useResumeStore.setState({ activeResumeId: payload.resumeId }); }, [payload.resumeId]);

  // Web 工作台：⌘ / Ctrl + 滚轮缩放纸面；缩放值交给原生保存并显示百分比提示
  const zoomRef = useRef(view.zoom);
  zoomRef.current = view.zoom;
  useEffect(() => {
    const area = scrollRef.current;
    if (!area) return;
    const onWheel = (event: WheelEvent) => {
      const next = getWheelZoomScale(zoomRef.current, event);
      if (next === null) return;
      event.preventDefault();
      zoomRef.current = next;
      post({ type: "zoom", zoom: next });
    };
    area.addEventListener("wheel", onWheel, { passive: false });
    return () => area.removeEventListener("wheel", onWheel);
  }, []);


  const settings = settingsFor(style);
  const horizontal = view.arrangement === "horizontal" && !settings.smartOnePage;
  const scale = horizontal ? getTwoPageFitScale(width, padding) * view.zoom : view.zoom * getSinglePageFitScale(width, padding, EDITOR_PAGE_BASE_SCALE);

  if (!editor) return null;
  return (
    <div className="resume-workbench wb3 is-embedded" data-ui-theme="light">
      <SelectionBubble editor={editor} scale={scale}>
        <SelectionAsk editor={editor} onAsk={(ask) => post({ type: "ask", ...ask })}>
          {(trigger) => <SelectionFormattingToolbar editor={editor} leading={trigger} />}
        </SelectionAsk>
      </SelectionBubble>
      {commandMenu && (
        <SlashCommandMenu editor={editor} resumeId={payload.resumeId} state={commandMenu} onClose={() => setCommandMenu(null)}
          onNotice={(message) => post({ type: "error", message })} />
      )}
      <main className="workbench-canvas">
        <div ref={scrollRef} className={`workbench-paper-scroll${horizontal ? " pages-horizontal" : ""}`}
          style={{ "--workbench-preview-scale": scale } as React.CSSProperties}>
          <div className={`workbench-document-stack${horizontal ? " pages-horizontal" : ""}`}>
            <div className="workbench-paper-frame">
              <article className={`resume-paper theme-${settings.theme}${settings.smartOnePage ? " smart-one-page" : ""}${horizontal ? " pages-horizontal" : ""}`}
                style={paperStyle(style, content)} aria-label="可编辑简历页面">
                <EditorContent editor={editor} className="workbench-page-flow" />
              </article>
            </div>
          </div>
        </div>
      </main>
    </div>
  );
}

let commandSink: ((command: Command) => void) | null = null;
let state: {
  payload: Payload | null;
  style: CanonicalResumePresentation | null;
  view: View;
  data: { data: CanonicalResumeDocument; sequence: number } | null;
} = { payload: null, style: null, view: { zoom: 1, arrangement: "vertical" }, data: null };

const root = createRoot(document.getElementById("paper-root")!);
function paint() {
  if (!state.payload) { root.render(null); return; }
  root.render(<Workbench key={state.payload.resumeId} payload={state.payload} styleOverride={state.style} view={state.view} dataOverride={state.data} />);
}

window.drawofferEditor = {
  load(payload) { state = { ...state, payload, style: null, data: null }; paint(); },
  setStyle(style) { state = { ...state, style }; paint(); },
  setView(view) { state = { ...state, view }; paint(); },
  replaceData(data) { state = { ...state, data: { data, sequence: Date.now() } }; paint(); },
  command(command) { commandSink?.(command); },
};

window.addEventListener("error", (event) => post({ type: "error", message: String(event.message) }));
// Web 保存时用 editorSettingsToStyle 回写版式；原生自己维护版式，这里只保留引用以确保两端同一实现
void editorSettingsToStyle;
post({ type: "ready", protocol: 1 });
