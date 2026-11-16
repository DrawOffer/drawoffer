// 原生客户端的「可编辑简历纸面」页（Mac WKWebView）。
//
// 直接挂载 Web 编辑器同一套 TipTap 扩展、分页、斜杠菜单与选区工具栏，纸面排版、编辑行为和工具栏与 Web 一致；
// 外框、面板、保存由原生负责。页面通过 drawoffer-paper:// 自定义 scheme 加载，
// 纸面里的 /api/... 图片与图片上传由原生带登录凭据转发，页面本身不持有凭据。
//
// 协议（editor protocol 1）：
//   原生 → 页面：window.drawofferEditor.load(payload) / setStyle(style) / setView(view) / replaceData(data) / command(cmd)
//                / previewTemplate(preview | null)
//   页面 → 原生：{ type: "ready" } / { type: "changed", data, style } / { type: "history", canUndo, canRedo }
//                { type: "ask", unitId, lineId, text, instruction } / { type: "zoom", zoom } / { type: "error", message }
//                { type: "pages", count }
//
// 以下为向后兼容的增量（旧客户端不发、也不处理，不影响原有消息）：
//   load(payload) 可带 features: { lineChat: true }。打开后选区工具栏只管格式（不再有“问 AI”，也就不再发 ask），并且：
//     页面 → 原生：{ type: "line", unitId, lineIds, selection, rect, paper }（光标 / 选区所在的行；unitId 为 null 表示不在可改的行上，
//                  正在打字时也发 null，停一秒再发）
//                  { type: "line-open", unitId, lineIds, selection, rect, paper }（⌘K / Ctrl+K）
//                  { type: "mark", key }（点了纸边的小圆圈）
//   command 新增：{ type: "decorate", source, highlight: nodeIds, preview: [{ lineId, before, text, risky }] }（临时高亮 / 预览改法，
//                  不进文档；同一 source 再发一次即替换，两项都空即清除）
//                 { type: "marks", marks: [{ key, nodeIds, state: "pending" | "current" | "done" }] }（纸边小圆圈）
//                 { type: "reveal", nodeIds }（滚到这几行）
//   rect / paper 是页面视口坐标（CSS px，与原生视图的点一致），已含纸面缩放。
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
import "../../web/src/features/workbench/guide/resume-guide.css";
import { Plugin, PluginKey } from "@tiptap/pm/state";
import type { Node as PMNode } from "@tiptap/pm/model";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
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
import { deleteOutlineSection, insertOutlineSection, outlineSnapshot, renameOutlineSection } from "../../web/src/features/workbench/outlineModel";
import { blockIdSelector, pmBlockAnchors } from "../../web/src/features/workbench/blockAnchors";
import { currentLineText, focusUnitsFromDoc, type FocusUnit } from "../../web/src/features/workbench/sectionFocus/sectionModel";
import { GuidePaperPreview } from "../../web/src/features/workbench/guide/GuidePaper";

type Payload = {
  resumeId: string;
  data: CanonicalResumeDocument;
  style: CanonicalResumePresentation;
  layout_plan?: unknown;
  /** 宿主支持的新能力；旧宿主不传，行为与之前一致。 */
  features?: { lineChat?: boolean };
};
type TemplatePreview = { data: CanonicalResumeDocument; style: CanonicalResumePresentation; layout_plan?: unknown };
type LineChange = { lineId: string; before: string; text: string; risky?: string[] };
type PaperMark = { key: string; nodeIds: string[]; state: "pending" | "current" | "done" };
type View = { zoom: number; arrangement: "vertical" | "horizontal" };
type Command =
  | { type: "undo" } | { type: "redo" } | { type: "focus" }
  | { type: "jump"; nodeId: string | null }
  | { type: "reorder"; nodeIds: string[] }
  | { type: "reset-order" }
  | { type: "rename"; nodeId: string; title: string }
  | { type: "remove"; nodeId: string }
  | { type: "add"; kind: ResumeSectionKind; title: string }
  | { type: "decorate"; source: string; highlight?: string[]; preview?: LineChange[] }
  | { type: "marks"; marks: PaperMark[] }
  | { type: "reveal"; nodeIds: string[] };

declare global {
  interface Window {
    webkit?: { messageHandlers?: { drawoffer?: { postMessage(message: unknown): void } } };
    drawofferEditor: {
      load(payload: Payload): void;
      setStyle(style: CanonicalResumePresentation): void;
      setView(view: View): void;
      replaceData(data: CanonicalResumeDocument): void;
      command(command: Command): void;
      previewTemplate(preview: TemplatePreview | null): void;
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

/* ── 原生临时装饰（分区 12）：高亮这几行、把改法直接显示在纸上；只是装饰，不改文档 ── */

type Decor = { highlight: string[]; preview: LineChange[] };
const decorKey = new PluginKey<DecorationSet>("drawoffer:nativeDecor");

/** 文档里锚点落在这些 ID 上的文本块（条目 ID 会命中条目标题行）。 */
function blocksFor(doc: PMNode, ids: string[]) {
  const wanted = new Set(ids);
  const found: Array<{ pos: number; node: PMNode }> = [];
  if (!wanted.size) return found;
  doc.descendants((node, pos) => {
    if (!node.isTextblock) return true;
    if (pmBlockAnchors(node).some((anchor) => wanted.has(anchor.blockId))) found.push({ pos, node });
    return false;
  });
  return found;
}

/** 新句子按要核实的词切开，要核实的词标橙（与 Web `LineChat` 相同）。 */
function riskySegments(text: string, risky: string[]) {
  const terms = [...new Set(risky.map((term) => term.trim()).filter(Boolean))].sort((a, b) => b.length - a.length);
  const segments: Array<{ text: string; risky: boolean }> = [];
  let rest = text;
  while (rest) {
    let hit: { index: number; term: string } | null = null;
    for (const term of terms) {
      const index = rest.indexOf(term);
      if (index >= 0 && (!hit || index < hit.index)) hit = { index, term };
    }
    if (!hit) { segments.push({ text: rest, risky: false }); break; }
    if (hit.index > 0) segments.push({ text: rest.slice(0, hit.index), risky: false });
    segments.push({ text: hit.term, risky: true });
    rest = rest.slice(hit.index + hit.term.length);
  }
  return segments;
}

function buildDecorations(doc: PMNode, sources: Map<string, Decor>) {
  const items: Decoration[] = [];
  const previewed = new Set<string>();
  for (const { preview } of sources.values()) {
    for (const change of preview) {
      // 这一行已经被改过（和 AI 看到的原句不一样）就不预览，换上时原生会提示
      if ((currentLineText(doc, change.lineId) ?? "").trim() !== change.before.trim()) continue;
      const line = blocksFor(doc, [change.lineId])[0];
      if (!line || previewed.has(change.lineId)) continue;
      previewed.add(change.lineId);
      const from = line.pos + 1;
      const to = line.pos + line.node.nodeSize - 1;
      items.push(Decoration.node(line.pos, line.pos + line.node.nodeSize, { class: "wbs-chat-preview" }));
      if (to > from) items.push(Decoration.inline(from, to, { class: "wbs-chat-was" }));
      items.push(Decoration.widget(from, () => {
        const span = document.createElement("span");
        span.className = "wbs-chat-now";
        for (const segment of riskySegments(change.text, change.risky ?? [])) {
          if (segment.risky) {
            const mark = document.createElement("span");
            mark.className = "wbs-chat-risky";
            mark.textContent = segment.text;
            span.appendChild(mark);
          } else {
            span.appendChild(document.createTextNode(segment.text));
          }
        }
        return span;
      }, { side: -1, key: `native-preview:${change.lineId}:${change.text}`, ignoreSelection: true }));
    }
  }
  const lit = new Set<number>();
  for (const { highlight } of sources.values()) {
    for (const { pos, node } of blocksFor(doc, highlight)) {
      if (lit.has(pos)) continue;
      // 已经在预览新句子的行不再盖一层“正在改”的底色
      if (pmBlockAnchors(node).some((anchor) => previewed.has(anchor.blockId))) continue;
      lit.add(pos);
      items.push(Decoration.node(pos, pos + node.nodeSize, { class: "wbs-chat-target" }));
    }
  }
  return DecorationSet.create(doc, items);
}

function nativeDecorPlugin(sources: Map<string, Decor>) {
  return new Plugin<DecorationSet>({
    key: decorKey,
    state: {
      init: (_, state) => buildDecorations(state.doc, sources),
      apply: (tr, value) => {
        if (tr.getMeta(decorKey) || tr.docChanged) return buildDecorations(tr.doc, sources);
        return value;
      },
    },
    props: { decorations: (state) => decorKey.getState(state) },
  });
}

/* ── 光标 / 选区所在的行（与 Web `LineChat.targetFromEditor` 相同的取法） ── */

type LineTarget = { unitId: string; lineIds: string[]; selection: { start: number; end: number } | null };
type Box = { x: number; y: number; width: number; height: number };

function lineTargetFromEditor(editor: Editor): LineTarget | null {
  const units: FocusUnit[] = focusUnitsFromDoc(editor.state.doc);
  const { from, to, empty } = editor.state.selection;
  const doc = editor.state.doc;
  const hits: Array<{ unit: FocusUnit; lineId: string }> = [];
  const visit = (node: PMNode) => {
    if (!node.isTextblock) return true;
    const ids = new Set(pmBlockAnchors(node).map((anchor) => anchor.blockId));
    const unit = units.find((item) => item.lines.some((line) => ids.has(line.id)));
    for (const line of unit?.lines ?? []) {
      if (ids.has(line.id) && unit && !hits.some((hit) => hit.lineId === line.id)) hits.push({ unit, lineId: line.id });
    }
    return false;
  };
  if (empty) visit(editor.state.selection.$from.parent);
  else doc.nodesBetween(from, to, visit);
  if (!hits.length) return null;
  const unitId = hits[0].unit.id;
  const lineIds = hits.filter((hit) => hit.unit.id === unitId).map((hit) => hit.lineId);
  let selection: LineTarget["selection"] = null;
  if (!empty && lineIds.length === 1 && editor.state.selection.$from.sameParent(editor.state.selection.$to)) {
    const text = currentLineText(doc, lineIds[0]) ?? "";
    const selected = doc.textBetween(from, to, "", "");
    const start = text.indexOf(selected);
    if (selected.trim() && start >= 0 && selected.length < text.trim().length) selection = { start, end: start + selected.length };
  }
  return { unitId, lineIds, selection };
}

function boxOf(rect: DOMRect): Box {
  return { x: Math.round(rect.left * 10) / 10, y: Math.round(rect.top * 10) / 10, width: Math.round(rect.width * 10) / 10, height: Math.round(rect.height * 10) / 10 };
}

/** 这几行在视口里的位置（第一行）和纸面的位置。 */
function lineGeometry(editor: Editor, lineIds: string[]): { rect: Box; paper: Box } | null {
  const first = blocksFor(editor.state.doc, lineIds)[0];
  if (!first) return null;
  const dom = editor.view.nodeDOM(first.pos);
  const element = dom instanceof HTMLElement ? dom : dom?.parentElement;
  const paper = editor.view.dom.closest(".resume-paper");
  if (!element || !paper) return null;
  return { rect: boxOf(element.getBoundingClientRect()), paper: boxOf(paper.getBoundingClientRect()) };
}

/** 纸边小圆圈（Figma 12.7–12.11）：空心 = 还没看，蓝 = 正在看，灰 = 看过；点一下打开那一处。 */
function PaperMarks({ editor, marks }: { editor: Editor; marks: PaperMark[] }) {
  const [dots, setDots] = useState<Array<PaperMark & { x: number; y: number }>>([]);
  const marksRef = useRef(marks);
  marksRef.current = marks;
  useEffect(() => {
    let frame: number | null = null;
    const measure = () => {
      frame = null;
      const root = editor.view.dom;
      const paper = root.closest(".resume-paper")?.getBoundingClientRect();
      if (!paper) return;
      const next: Array<PaperMark & { x: number; y: number }> = [];
      for (const mark of marksRef.current) {
        const element = mark.nodeIds.map((id) => root.querySelector(blockIdSelector(id))).find(Boolean);
        if (!element) continue;
        const box = element.getBoundingClientRect();
        next.push({ ...mark, x: paper.right + 16, y: box.top + Math.min(box.height, 18) / 2 });
      }
      setDots((value) => JSON.stringify(value) === JSON.stringify(next) ? value : next);
    };
    const schedule = () => { if (frame === null) frame = requestAnimationFrame(measure); };
    schedule();
    const timer = window.setInterval(schedule, 300);
    const scroller = editor.view.dom.closest(".workbench-paper-scroll");
    scroller?.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule, { passive: true });
    editor.on("transaction", schedule);
    return () => {
      if (frame !== null) cancelAnimationFrame(frame);
      window.clearInterval(timer);
      scroller?.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
      editor.off("transaction", schedule);
    };
  }, [editor, marks]);
  if (!dots.length) return null;
  return (
    <div className="native-paper-marks" aria-label="要改的几处">
      {dots.map((dot) => (
        <button
          key={dot.key}
          type="button"
          className={`native-paper-mark is-${dot.state}`}
          style={{ left: dot.x, top: dot.y }}
          disabled={dot.state === "done"}
          aria-label={dot.state === "current" ? "正在看的这一处" : dot.state === "done" ? "看过的一处" : "要改的一处"}
          onMouseDown={(event) => event.preventDefault()}
          onClick={() => post({ type: "mark", key: dot.key })}
        />
      ))}
    </div>
  );
}

const NATIVE_STYLE = `
.native-paper-marks { position: fixed; inset: 0; z-index: 27; pointer-events: none; }
.native-paper-mark { position: absolute; width: 7px; height: 7px; margin: -3.5px 0 0 -3.5px; box-sizing: border-box; border: 1px solid #b9b9b2; border-radius: 50%; background: transparent; padding: 0; cursor: pointer; pointer-events: auto; }
.native-paper-mark::after { content: ""; position: absolute; inset: -6px; }
.native-paper-mark.is-pending:hover { border-color: #1d1d1b; }
.native-paper-mark.is-current { border-color: var(--v3-bl, #2f6bea); background: var(--v3-bl, #2f6bea); }
.native-paper-mark.is-done { border-color: #c9c9c4; background: #c9c9c4; cursor: default; }
`;

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

function Workbench({ payload, styleOverride, view, dataOverride, templatePreview }: {
  payload: Payload;
  styleOverride: CanonicalResumePresentation | null;
  view: View;
  dataOverride: { data: CanonicalResumeDocument; sequence: number } | null;
  templatePreview: TemplatePreview | null;
}) {
  const lineChat = Boolean(payload.features?.lineChat);
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
  // 原生下发的临时装饰：按来源（改这一条 / 检查简历）分开存，互不覆盖
  const decorSources = useRef(new Map<string, Decor>()).current;
  const [marks, setMarks] = useState<PaperMark[]>([]);

  const editor = useEditor({
    shouldRerenderOnTransaction: false,
    extensions: [...resumeEditorExtensions, PaginationExtension, LineInsertMenuExtension.configure({ onOpen: setCommandMenu })],
    content: initial,
    editorProps: { attributes: { class: "resume-content", spellcheck: "false" }, transformPastedHTML: plainParagraphsFromHtml },
    onCreate: ({ editor: current }) => {
      current.registerPlugin(nativeDecorPlugin(decorSources));
      current.commands.blur();
      reportHistory(current);
    },
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
        case "decorate": {
          const highlight = command.highlight ?? [];
          const preview = command.preview ?? [];
          if (!highlight.length && !preview.length) decorSources.delete(command.source);
          else decorSources.set(command.source, { highlight, preview });
          if (!editor.isDestroyed) editor.view.dispatch(editor.state.tr.setMeta(decorKey, true).setMeta("addToHistory", false));
          break;
        }
        case "marks": setMarks(Array.isArray(command.marks) ? command.marks : []); break;
        case "reveal": {
          const element = command.nodeIds.map((id) => editor.view.dom.querySelector(blockIdSelector(id))).find(Boolean);
          element?.scrollIntoView({ block: "center", behavior: "smooth" });
          break;
        }
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

  // 总页数（Web 规格行“共 N 页”与检查简历的 page_count 同一来源）：变了才报
  useEffect(() => {
    if (!editor) return;
    let last = 0;
    const report = () => {
      const count = outlineSnapshot(editor.state).pageCount;
      if (count === last) return;
      last = count;
      post({ type: "pages", count });
    };
    report();
    editor.on("transaction", report);
    return () => { editor.off("transaction", report); };
  }, [editor]);

  // 光标 / 选区所在的行：原生在行旁画“改这一条 ⌘K”。正在打字时先收起，停一秒再出来；滚动、缩放时跟着报新位置。
  useEffect(() => {
    if (!editor || !lineChat) return;
    let target: LineTarget | null = null;
    let quiet = true;
    let timer: number | null = null;
    let frame: number | null = null;
    let last = "";
    const payloadOf = (value: LineTarget | null) => {
      const geometry = value ? lineGeometry(editor, value.lineIds) : null;
      return value && geometry ? { ...value, ...geometry } : null;
    };
    const send = () => {
      frame = null;
      const value = quiet ? payloadOf(target) : null;
      const message = value ? { type: "line", ...value } : { type: "line", unitId: null };
      const key = JSON.stringify(message);
      if (key === last) return;
      last = key;
      post(message);
    };
    const schedule = () => { if (frame === null) frame = requestAnimationFrame(send); };
    const read = () => {
      target = lineTargetFromEditor(editor);
      schedule();
    };
    const onUpdate = () => {
      quiet = false;
      if (timer !== null) window.clearTimeout(timer);
      timer = window.setTimeout(() => { quiet = true; read(); }, 1000);
      read();
    };
    const onKey = (event: KeyboardEvent) => {
      const mod = event.metaKey || event.ctrlKey;
      if (!mod || event.altKey || event.shiftKey || event.key.toLowerCase() !== "k" || !editor.isFocused) return;
      const current = lineTargetFromEditor(editor);
      const value = payloadOf(current);
      if (!value) return;
      event.preventDefault();
      post({ type: "line-open", ...value });
    };
    const scroller = editor.view.dom.closest(".workbench-paper-scroll");
    editor.on("selectionUpdate", read);
    editor.on("focus", read);
    editor.on("update", onUpdate);
    editor.on("transaction", schedule);
    scroller?.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule, { passive: true });
    document.addEventListener("keydown", onKey, true);
    return () => {
      if (timer !== null) window.clearTimeout(timer);
      if (frame !== null) cancelAnimationFrame(frame);
      editor.off("selectionUpdate", read);
      editor.off("focus", read);
      editor.off("update", onUpdate);
      editor.off("transaction", schedule);
      scroller?.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
      document.removeEventListener("keydown", onKey, true);
      post({ type: "line", unitId: null });
    };
  }, [editor, lineChat]);

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
  // 07.2 模板悬停预览：同一份内容按那套模板排一张只读纸，叠在真纸上；不改文档、不保存
  const preview = useMemo(() => {
    if (!templatePreview) return null;
    const previewContent = editorContentForResume({ data: templatePreview.data, style: templatePreview.style, layout_plan: templatePreview.layout_plan as never });
    return { content: previewContent, settings: settingsFor(templatePreview.style), style: paperStyle(templatePreview.style, previewContent) };
  }, [templatePreview]);
  const scale = horizontal ? getTwoPageFitScale(width, padding) * view.zoom : view.zoom * getSinglePageFitScale(width, padding, EDITOR_PAGE_BASE_SCALE);

  if (!editor) return null;
  return (
    <div className="resume-workbench wb3 is-embedded" data-ui-theme="light">
      <SelectionBubble editor={editor} scale={scale}>
        {lineChat ? (
          // 分区 06.3–06.5：工具条只管格式；AI 修改由纸右边的“改这一条”承担
          <SelectionFormattingToolbar editor={editor} />
        ) : (
          <SelectionAsk editor={editor} onAsk={(ask) => post({ type: "ask", ...ask })}>
            {(trigger) => <SelectionFormattingToolbar editor={editor} leading={trigger} />}
          </SelectionAsk>
        )}
      </SelectionBubble>
      {marks.length > 0 && <PaperMarks editor={editor} marks={marks} />}
      {commandMenu && (
        <SlashCommandMenu editor={editor} resumeId={payload.resumeId} state={commandMenu} onClose={() => setCommandMenu(null)}
          onNotice={(message) => post({ type: "error", message })} />
      )}
      <main className="workbench-canvas">
        <div ref={scrollRef} className={`workbench-paper-scroll${horizontal ? " pages-horizontal" : ""}`}
          style={{ "--workbench-preview-scale": scale } as React.CSSProperties}>
          <div className={`workbench-document-stack${horizontal ? " pages-horizontal" : ""}`}>
            <div className={`workbench-paper-frame${preview ? " has-guide-preview" : ""}`}>
              <article className={`resume-paper theme-${settings.theme}${settings.smartOnePage ? " smart-one-page" : ""}${horizontal ? " pages-horizontal" : ""}${preview ? " is-guide-hidden" : ""}`}
                style={paperStyle(style, content)} aria-label="可编辑简历页面">
                <EditorContent editor={editor} className="workbench-page-flow" />
              </article>
              {preview && (
                <GuidePaperPreview
                  content={preview.content}
                  className={`resume-paper theme-${preview.settings.theme}${preview.settings.smartOnePage ? " smart-one-page" : ""}${horizontal ? " pages-horizontal" : ""}`}
                  style={preview.style}
                />
              )}
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
  template: TemplatePreview | null;
} = { payload: null, style: null, view: { zoom: 1, arrangement: "vertical" }, data: null, template: null };

const root = createRoot(document.getElementById("paper-root")!);
function paint() {
  if (!state.payload) { root.render(null); return; }
  root.render(<Workbench key={state.payload.resumeId} payload={state.payload} styleOverride={state.style} view={state.view} dataOverride={state.data}
    templatePreview={state.template} />);
}

window.drawofferEditor = {
  load(payload) { state = { ...state, payload, style: null, data: null, template: null }; paint(); },
  setStyle(style) { state = { ...state, style }; paint(); },
  setView(view) { state = { ...state, view }; paint(); },
  replaceData(data) { state = { ...state, data: { data, sequence: Date.now() } }; paint(); },
  command(command) { commandSink?.(command); },
  previewTemplate(preview) {
    state = { ...state, template: preview && typeof preview === "object" && preview.data && preview.style ? preview : null };
    paint();
  },
};

const nativeStyle = document.createElement("style");
nativeStyle.textContent = NATIVE_STYLE;
document.head.appendChild(nativeStyle);

window.addEventListener("error", (event) => post({ type: "error", message: String(event.message) }));
// Web 保存时用 editorSettingsToStyle 回写版式；原生自己维护版式，这里只保留引用以确保两端同一实现
void editorSettingsToStyle;
post({ type: "ready", protocol: 1 });
