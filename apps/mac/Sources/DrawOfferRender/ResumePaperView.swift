import DrawOfferCore
import SwiftUI
import WebKit

/// 简历纸面。整个 App 里唯一用到网页视图的地方：加载随包的离线 paper.html，
/// 通过 `window.drawoffer.render(request)` 注入数据；页面渲染完回报纸面高度。
/// 外框、切换动画在 SwiftUI 这一侧完成。缩放不要用 `scaleEffect`（那是把 794px 的位图缩小，字会发虚）：
/// 直接给视图目标尺寸，页面按 794 CSS 像素排版，再用 CSS `scale = 视图宽度 / 794` 整体缩放（paper.html 里处理，同 Web 卡片），文字按实际尺寸绘制；回报的高度仍是未缩放的 CSS 像素。
public struct ResumePaperView: NSViewRepresentable {
    private let request: ResumeRenderRequest
    private let highlights: [String]
    private let onError: (String) -> Void
    private let onRendered: (CGFloat) -> Void
    private let onSnapshot: ((NSImage) -> Void)?

    /// `highlights`：纸面上包含这些文字的段落与列表项加底色标出（AI 待确认修改的原文）。
    public init(request: ResumeRenderRequest, highlights: [String] = [], onRendered: @escaping (CGFloat) -> Void = { _ in }, onError: @escaping (String) -> Void = { _ in },
                onSnapshot: ((NSImage) -> Void)? = nil) {
        self.onError = onError
        self.onSnapshot = onSnapshot
        self.request = request
        self.highlights = highlights
        self.onRendered = onRendered
    }

    public func makeCoordinator() -> PaperBridge {
        let bridge = PaperBridge(onRendered: onRendered, onError: onError)
        bridge.onSnapshot = onSnapshot
        return bridge
    }

    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "drawoffer")
        // 纸面纯展示：关掉网络数据存储，页面本身的 CSP 也只允许内联资源
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.attach(webView)
        if let url = Bundle.module.url(forResource: "paper", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        context.coordinator.highlights = highlights
        context.coordinator.render(request)
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onError = onError
        context.coordinator.onRendered = onRendered
        context.coordinator.onSnapshot = onSnapshot
        context.coordinator.setHighlights(highlights)
        context.coordinator.render(request)
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: PaperBridge) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "drawoffer")
        coordinator.detach()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }
}

/// 原生 ↔ 纸面页的桥。页面 ready 之前到达的渲染请求先暂存，ready 后补发最新一份。
@MainActor
public final class PaperBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onError: (String) -> Void
    var onRendered: (CGFloat) -> Void
    /// 渲染完成后把第一页（视图大小）按 2 倍截成图片交回；用于压在其他内容下面、只展示的纸（网页视图不受 SwiftUI 裁剪与层级约束）。
    var onSnapshot: ((NSImage) -> Void)?
    private weak var webView: WKWebView?
    private var isReady = false
    private var pending: Data?
    private var lastSent: Data?

    init(onRendered: @escaping (CGFloat) -> Void, onError: @escaping (String) -> Void) {
        self.onError = onError
        self.onRendered = onRendered
    }

    var highlights: [String] = []
    private var rendered = false

    func detach() { pending = nil; lastSent = nil; isReady = false; rendered = false; webView = nil }

    func setHighlights(_ next: [String]) {
        guard next != highlights else { return }
        highlights = next
        if rendered { applyHighlights() }
    }

    /// 只改元素的内联样式（CSSOM 不受页面 CSP 限制），文字列表经 JSONEncoder 编码为 JS 字面量。
    private func applyHighlights() {
        let texts = highlights.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let data = try? JSONEncoder().encode(texts), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("""
        (function (texts) {
          var root = document.getElementById("paper-root"); if (!root) return 0;
          root.querySelectorAll("[data-lr-pending]").forEach(function (node) {
            node.removeAttribute("data-lr-pending"); node.style.backgroundColor = ""; node.style.boxShadow = ""; node.style.borderRadius = "";
          });
          var hits = Array.prototype.filter.call(root.querySelectorAll("p, li"), function (node) {
            return texts.some(function (text) { return (node.textContent || "").indexOf(text) >= 0; });
          });
          hits.forEach(function (node) {
            node.setAttribute("data-lr-pending", "");
            node.style.backgroundColor = "rgba(255, 204, 0, 0.28)"; node.style.boxShadow = "0 0 0 2px rgba(255, 204, 0, 0.28)"; node.style.borderRadius = "2px";
          });
          return hits.length;
        })(\(json))
        """)
    }

    private func snapshot() {
        guard onSnapshot != nil, let webView, webView.bounds.width > 0 else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width) * 2)
        // 图片与头像在 rendered 之后才解码完，稍等再截
        Task { @MainActor [weak self, weak webView] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let webView, let image = try? await webView.takeSnapshot(configuration: configuration) else { return }
            self?.onSnapshot?(image)
        }
    }

    func attach(_ webView: WKWebView) { self.webView = webView; webView.navigationDelegate = self }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let paper = Bundle.module.url(forResource: "paper", withExtension: "html")
        decisionHandler(url == paper || url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func render(_ request: ResumeRenderRequest) {
        guard let payload = try? JSONEncoder().encode(request), payload != lastSent else { return }
        pending = payload
        flush()
    }

    private func flush() {
        guard isReady, let payload = pending, let json = String(data: payload, encoding: .utf8) else { return }
        pending = nil
        lastSent = payload
        // payload 是 JSONEncoder 的输出，本身就是合法的 JS 字面量，不经过字符串拼接用户输入
        webView?.evaluateJavaScript("window.drawoffer.render(\(json))")
    }

    public nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit 在主线程回调；body 的读取也放进主线程隔离区
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                guard body["protocol"] as? Int == 1 else { onError("纸面资源版本不匹配，请更新客户端。"); return }
                isReady = true
                flush()
            case "rendered":
                rendered = true
                if !highlights.isEmpty { applyHighlights() }
                onRendered(CGFloat(body["heightPx"] as? Double ?? 0))
                snapshot()
            case "error":
                onError(body["message"] as? String ?? "纸面预览失败，请重试。")
            default:
                break
            }
        }
    }
}
