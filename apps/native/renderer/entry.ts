// 原生客户端的「简历纸面」渲染页。
//
// Mac（WKWebView）和 Windows（WebView2）都只在纸面这一块嵌入网页视图，
// 加载本文件打包出的单个离线 HTML。渲染逻辑直接复用 Web 端的
// renderResumePrintDocument 与同一份模板样式。字体、换行与分页仍受渲染引擎影响。
//
// 与原生层的协议（protocol_version 1）：
//   原生 → 页面：调用 window.drawoffer.render(request)，request 同 ResumeRenderRequestV1
//   页面 → 原生：postMessage({ type: "ready" }) / { type: "rendered", heightPx } / { type: "error", message }
import applicationStyles from "../../web/src/app.css?raw";
import themeStyles from "../../web/src/resume-themes.css?raw";
import collectionStyles from "../../web/src/crafted-style-collection.css?raw";
import baseStyles from "../../web/src/styles.css?raw";
import printStyles from "../../web/src/features/preview/print/resume-print.css?raw";
import museStyles from "../../web/src/muse-templates.css?raw";
import administrativeAvatar from "../../web/public/templates/avatar-administrative.png";
import campusAvatar from "../../web/public/templates/avatar-campus.png";
import templateAvatar from "../../web/public/templates/avatar-cat.jpg";
import civicAvatar from "../../web/public/templates/avatar-civic.png";
import creativeAvatar from "../../web/public/templates/avatar-creative.png";
import samplePhotoFemale from "../../web/public/templates/sample-photo-female.jpg";
import samplePhotoMale from "../../web/public/templates/sample-photo-male.jpg";
import {
  renderResumePrintDocument,
  RESUME_RENDER_PROTOCOL_VERSION,
  type ResumeRenderRequestV1,
} from "../../web/src/features/preview/print/resumePrintDocument";
import { syncResumeIdentityCentering, syncResumeSheetColumns } from "../../web/src/features/preview/print/resumeSheetDecoration";
import { paginateShareDocument } from "../../web/src/features/share/sharePagination";
import { A4_HEIGHT_CSS_PX } from "../../web/src/features/workbench/pagination";

// 同 Web 卡片（app.css `.resume-readonly-preview-card .resume-preview-paper { scale }`）：纸面固定按 A4 794 CSS 像素排版，
// 再按视图宽度整体 `scale`，由 WebKit 按最终尺寸绘制文字（原生侧不再缩位图）。测量时先撤掉缩放。
const PAPER_WIDTH = 794;
function paperScale() {
  const width = document.documentElement.clientWidth;
  return width > 0 ? width / PAPER_WIDTH : 1;
}
function applyScale() {
  const root = document.getElementById("paper-root");
  if (!root) return;
  const scale = paperScale();
  root.style.width = `${PAPER_WIDTH}px`;
  root.style.transformOrigin = "0 0";
  root.style.scale = Math.abs(scale - 1) < 0.001 ? "" : String(scale);
}
window.addEventListener("resize", applyScale);

/// 原生扩展：`first_page_only` 为 true 时同 Web `ResumePreview firstPageOnly`（我的简历卡片）——
/// 不用智能一页，按 A4 分页后只画第一页，正文裁在第一页内容区下沿。
type NativeRenderRequest = ResumeRenderRequestV1 & { first_page_only?: boolean };

type NativeMessage =
  | { type: "ready"; protocol: number }
  | { type: "rendered"; heightPx: number }
  | { type: "error"; message: string };

// 内置模板头像随包内联，纸面不发任何网络请求
const BUNDLED_ASSETS: Record<string, string> = {
  "/templates/avatar-administrative.png": administrativeAvatar,
  "/templates/avatar-administrative.svg": administrativeAvatar,
  "/templates/avatar-campus.png": campusAvatar,
  "/templates/avatar-campus.svg": campusAvatar,
  "/templates/avatar-cat.jpg": templateAvatar,
  "/templates/avatar-civic.png": civicAvatar,
  "/templates/avatar-civic.svg": civicAvatar,
  "/templates/avatar-creative.png": creativeAvatar,
  "/templates/avatar-creative.svg": creativeAvatar,
  // 模板预览与换模板时的虚构示例证件照（Web `templateSamplePhoto`），只在纸面显示，不写进用户简历
  "/templates/sample-photo-female.jpg": samplePhotoFemale,
  "/templates/sample-photo-male.jpg": samplePhotoMale,
};

declare global {
  interface Window {
    webkit?: { messageHandlers?: { drawoffer?: { postMessage(message: unknown): void } } };
    chrome?: { webview?: { postMessage(message: unknown): void } };
    drawoffer: { render(request: NativeRenderRequest): void; clear(): void };
  }
}

function post(message: NativeMessage) {
  // WKWebView 走 messageHandlers，WebView2 走 chrome.webview；两者都没有时（浏览器里调试）打到控制台
  if (window.webkit?.messageHandlers?.drawoffer) window.webkit.messageHandlers.drawoffer.postMessage(message);
  else if (window.chrome?.webview) window.chrome.webview.postMessage(message);
  else console.info("[drawoffer-renderer]", message);
}

let generation = 0;
async function render(request: NativeRenderRequest) {
  const current = ++generation;
  try {
    if (request.protocol_version !== undefined && request.protocol_version !== RESUME_RENDER_PROTOCOL_VERSION) {
      throw new Error("RENDERER_PROTOCOL_UNSUPPORTED");
    }
    const root = document.getElementById("paper-root");
    if (!root) throw new Error("RENDERER_ROOT_MISSING");
    const { first_page_only: firstPageOnly = false, ...printRequest } = request;
    const style = firstPageOnly
      ? { ...printRequest.style, portable: { ...printRequest.style.portable, smart_one_page: false } }
      : printRequest.style;
    root.classList.toggle("resume-readonly-preview-first-page", firstPageOnly);
    root.innerHTML = renderResumePrintDocument({
      ...printRequest,
      style,
      assets: { ...BUNDLED_ASSETS, ...(request.assets ?? {}) },
    } as ResumeRenderRequestV1);
    const paper = root.firstElementChild as HTMLElement | null;
    if (!paper || paper.dataset.renderState === "unavailable") throw new Error("RENDERER_LAYOUT_UNAVAILABLE");
    // 图片与字体加载后再报告高度；快速切换时只报告最新请求。
    await document.fonts.ready;
    let missingImages = 0;
    await Promise.all(Array.from(root.querySelectorAll("img"), async (image) => {
      try { await image.decode(); }
      catch {
        missingImages += 1;
        image.src = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGM4c+bMfwAIMANkhLK+mwAAAABJRU5ErkJggg==";
        image.alt = "图片不可用";
        await image.decode();
      }
    }));
    // 后台窗口可能暂停动画帧；测量不能因此一直等待。
    await new Promise<void>((resolve) => {
      const timer = window.setTimeout(resolve, 100);
      requestAnimationFrame(() => { window.clearTimeout(timer); resolve(); });
    });
    if (current !== generation) return;
    root.style.scale = "";
    root.style.width = `${PAPER_WIDTH}px`;
    // 与 Web ResumePreview 的布局同步一致：居中身份区、侧栏补满；第一页模式再分页并记下第一页内容区高度
    syncResumeIdentityCentering({ paper });
    if (firstPageOnly) {
      paginateShareDocument(paper, 1);
      const content = paper.querySelector<HTMLElement>(".resume-print-content");
      if (content) {
        const contentTop = content.getBoundingClientRect().top - paper.getBoundingClientRect().top;
        const bottomPadding = Number.parseFloat(getComputedStyle(paper).paddingBottom) || 0;
        paper.style.setProperty("--resume-first-page-content-height", `${Math.max(0, A4_HEIGHT_CSS_PX - contentTop - bottomPadding)}px`);
      }
    }
    syncResumeSheetColumns({ paper });
    const heightPx = Math.ceil(paper.getBoundingClientRect().height);
    applyScale();
    post({ type: "rendered", heightPx });
    if (missingImages) post({ type: "error", message: "部分图片不可用，正文仍可预览。" });
  } catch (error) {
    if (current === generation) post({ type: "error", message: "纸面预览失败，请检查模板布局与图片资源。" });
  }
}

const style = document.createElement("style");
// 与 PDF CLI 相同：模板样式（resume-themes.css）不再在 app.css 里，一次拼进全部样式；
// 风格合集已单独拼入，去掉它的 @import。样式里的 /templates/ 装饰图改为相对地址，从纸面旁边随包的 templates 目录读。
const templateStyles = `${themeStyles.replace('@import "./crafted-style-collection.css";', "")}\n${collectionStyles}`;
style.textContent = `${baseStyles}\n${applicationStyles}\n${templateStyles}\n${printStyles}\n${museStyles}`.replace(/url\((["']?)\/templates\//gu, "url($1templates/") + `\nhtml,body{margin:0;background:transparent;overflow:hidden}\nhtml[data-drawoffer-native-renderer] [data-resume-print-document]{height:auto;overflow:visible}\nhtml[data-drawoffer-native-renderer] .resume-readonly-preview-first-page [data-resume-print-document]{height:297mm;min-height:297mm;overflow:hidden}`;
document.head.appendChild(style);

// 原生 evaluateJavaScript 不接受 Promise 返回值，桥接入口保持同步 void。
window.drawoffer = {
  render(request: NativeRenderRequest) { void render(request); },
  clear() {
    generation += 1;
    document.getElementById("paper-root")?.replaceChildren();
  },
};
post({ type: "ready", protocol: RESUME_RENDER_PROTOCOL_VERSION });
