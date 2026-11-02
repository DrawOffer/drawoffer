import DrawOfferCore
import SwiftUI
import WebKit

/// 原生 → 可编辑纸面的指令（editor protocol 1，见 `apps/native/renderer/editor.tsx`）。
public enum ResumeEditorCommand: Sendable {
    case undo, redo, focus, resetOrder
    case jump(String?)
    case reorder([String])
    case rename(String, String)
    case remove(String)
    case add(kind: String, title: String)

    var json: JSONValue {
        switch self {
        case .undo: return .object(["type": .string("undo")])
        case .redo: return .object(["type": .string("redo")])
        case .focus: return .object(["type": .string("focus")])
        case .resetOrder: return .object(["type": .string("reset-order")])
        case .jump(let id): return .object(["type": .string("jump"), "nodeId": id.map(JSONValue.string) ?? .null])
        case .reorder(let ids): return .object(["type": .string("reorder"), "nodeIds": .array(ids.map(JSONValue.string))])
        case .rename(let id, let title): return .object(["type": .string("rename"), "nodeId": .string(id), "title": .string(title)])
        case .remove(let id): return .object(["type": .string("remove"), "nodeId": .string(id)])
        case .add(let kind, let title): return .object(["type": .string("add"), "kind": .string(kind), "title": .string(title)])
        }
    }
}

/// 纸面 → 原生的事件。
public enum ResumeEditorEvent: Sendable {
    case changed(data: JSONValue, style: JSONValue)
    case history(canUndo: Bool, canRedo: Bool)
    /// 选区工具栏「问 AI」：选中的那一行与一句修改要求。
    case ask(unitID: String, lineID: String, text: String, instruction: String)
    case zoom(Double)
    case error(String)
}

/// 把指令排进纸面：编辑器视图持有它，页面 ready 后才真正执行。
@MainActor
public final class ResumeEditorChannel {
    weak var bridge: EditorBridge?
    public init() {}
    public func send(_ command: ResumeEditorCommand) { bridge?.call("command", command.json) }
    /// 原生改写正文（引导写入、AI 采纳）：页面按当前模板重新排版。
    public func replaceData(_ data: JSONValue) { bridge?.call("replaceData", data) }
}

/// 可编辑简历纸面：WKWebView 挂载与 Web 相同的 TipTap 编辑器、分页、斜杠菜单与选区工具栏。
/// 页面经 `drawoffer-paper://` 加载；纸面里的 `/api/...` 图片与图片上传由 `PaperSchemeHandler` 带凭据转发，
/// 页面本身不持有凭据，也不能访问其他地址。
public struct ResumeEditorPaperView: NSViewRepresentable {
    let resumeID: String
    let data: JSONValue
    let style: JSONValue
    let layoutPlan: JSONValue?
    /// 当前版式：`styleRevision` 变化（排版面板）时下发给页面；页面内编辑产生的版式变化不回传，避免回环。
    let liveStyle: JSONValue
    let styleRevision: Int
    let zoom: Double
    let horizontal: Bool
    let channel: ResumeEditorChannel
    let api: any APIClient
    let onEvent: (ResumeEditorEvent) -> Void

    public init(resumeID: String, data: JSONValue, style: JSONValue, layoutPlan: JSONValue?, liveStyle: JSONValue, styleRevision: Int, zoom: Double, horizontal: Bool,
                channel: ResumeEditorChannel, api: any APIClient, onEvent: @escaping (ResumeEditorEvent) -> Void) {
        self.resumeID = resumeID; self.data = data; self.style = style; self.layoutPlan = layoutPlan; self.liveStyle = liveStyle; self.styleRevision = styleRevision
        self.zoom = zoom; self.horizontal = horizontal; self.channel = channel; self.api = api; self.onEvent = onEvent
    }

    public func makeCoordinator() -> EditorBridge { EditorBridge(onEvent: onEvent) }

    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "drawoffer")
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(PaperSchemeHandler(resumeID: resumeID, api: api), forURLScheme: PaperSchemeHandler.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.attach(webView)
        channel.bridge = context.coordinator
        context.coordinator.load(resumeID: resumeID, data: data, style: style, layoutPlan: layoutPlan, styleRevision: styleRevision)
        context.coordinator.setView(zoom: zoom, horizontal: horizontal)
        webView.load(URLRequest(url: PaperSchemeHandler.editorURL))
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        channel.bridge = context.coordinator
        context.coordinator.updateStyle(liveStyle, revision: styleRevision)
        context.coordinator.setView(zoom: zoom, horizontal: horizontal)
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: EditorBridge) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "drawoffer")
        coordinator.detach()
        webView.stopLoading()
    }
}

@MainActor
public final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onEvent: (ResumeEditorEvent) -> Void
    private weak var webView: WKWebView?
    private var isReady = false
    private var queue: [(String, JSONValue)] = []
    private var styleRevision = -1
    private var lastView: JSONValue?

    init(onEvent: @escaping (ResumeEditorEvent) -> Void) { self.onEvent = onEvent }

    func attach(_ webView: WKWebView) { self.webView = webView; webView.navigationDelegate = self }
    func detach() { queue = []; isReady = false; webView = nil }

    func load(resumeID: String, data: JSONValue, style: JSONValue, layoutPlan: JSONValue?, styleRevision: Int) {
        self.styleRevision = styleRevision
        call("load", .object(["resumeId": .string(resumeID), "data": data, "style": style, "layout_plan": layoutPlan ?? .null]))
    }

    func updateStyle(_ style: JSONValue, revision: Int) {
        guard revision != styleRevision else { return }
        styleRevision = revision
        call("setStyle", style)
    }

    func setView(zoom: Double, horizontal: Bool) {
        let view: JSONValue = .object(["zoom": .number(zoom), "arrangement": .string(horizontal ? "horizontal" : "vertical")])
        guard view != lastView else { return }
        lastView = view
        call("setView", view)
    }

    /// 参数经 JSONEncoder 编码为 JS 字面量，不拼接未转义的用户文字。
    func call(_ method: String, _ argument: JSONValue) {
        guard isReady else { queue.append((method, argument)); return }
        guard let data = try? JSONEncoder().encode(argument), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.drawofferEditor.\(method)(\(json))")
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // 只允许编辑器页本身；纸面里的链接不在 App 里打开
        decisionHandler(navigationAction.request.url == PaperSchemeHandler.editorURL ? .allow : .cancel)
    }

    public nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                guard body["protocol"] as? Int == 1 else { onEvent(.error("编辑器资源版本不匹配，请更新客户端。")); return }
                isReady = true
                let pending = queue; queue = []
                for (method, argument) in pending { call(method, argument) }
            case "changed":
                guard let data = Self.json(body["data"]), let style = Self.json(body["style"]) else { return }
                onEvent(.changed(data: data, style: style))
            case "history":
                onEvent(.history(canUndo: body["canUndo"] as? Bool ?? false, canRedo: body["canRedo"] as? Bool ?? false))
            case "ask":
                guard let unit = body["unitId"] as? String, let line = body["lineId"] as? String else { return }
                onEvent(.ask(unitID: unit, lineID: line, text: body["text"] as? String ?? "", instruction: body["instruction"] as? String ?? ""))
            case "zoom":
                if let value = body["zoom"] as? Double { onEvent(.zoom(value)) }
            case "error":
                onEvent(.error(body["message"] as? String ?? "编辑器出错，请重试。"))
            default: break
            }
        }
    }

    /// WebKit 把页面对象转成 Foundation 类型；转回 JSON 再解码为 JSONValue。
    private static func json(_ value: Any?) -> JSONValue? {
        guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// `drawoffer-paper://editor/`：编辑器页、模板示例头像、简历图片读取与上传。其余地址一律 404。
final class PaperSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "drawoffer-paper"
    static let editorURL = URL(string: "drawoffer-paper://editor/index.html")!
    private static let maxUploadBytes = 14 * 1024 * 1024

    private let resumeID: String
    private let api: any APIClient
    private let lock = NSLock()
    private var running = Set<ObjectIdentifier>()

    init(resumeID: String, api: any APIClient) { self.resumeID = resumeID; self.api = api }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        lock.withLock { _ = running.insert(id) }
        let request = task.request
        guard let url = request.url, url.host == "editor" else { finish(task, id, status: 404, body: Data(), type: "text/plain"); return }
        let path = url.path
        let method = request.httpMethod ?? "GET"
        if path == "/index.html", method == "GET",
           let file = Bundle.module.url(forResource: "editor", withExtension: "html"), let html = try? Data(contentsOf: file) {
            finish(task, id, status: 200, body: html, type: "text/html; charset=utf-8"); return
        }
        if path.hasPrefix("/templates/"), method == "GET" {
            let name = String(path.dropFirst("/templates/".count))
            let ext = (name as NSString).pathExtension
            if PaperAssets.isBundledTemplate(path), let file = Bundle.module.url(forResource: (name as NSString).deletingPathExtension, withExtension: ext, subdirectory: "templates"),
               let data = try? Data(contentsOf: file) {
                finish(task, id, status: 200, body: data, type: ["png": "image/png", "jpg": "image/jpeg", "svg": "image/svg+xml"][ext] ?? "application/octet-stream")
            } else { finish(task, id, status: 404, body: Data(), type: "text/plain") }
            return
        }
        let api = self.api, resumeID = self.resumeID
        if path == "/api/resumes/\(resumeID)/assets", method == "POST" {
            // 页面上传：`{file_name, data_url}`，与 Web `api.uploadResumeAsset` 同一请求体
            guard let body = Self.body(of: request), body.count <= Self.maxUploadBytes,
                  let payload = try? JSONDecoder().decode(JSONValue.self, from: body),
                  let name = payload["file_name"]?.stringValue, let dataURL = payload["data_url"]?.stringValue else {
                finish(task, id, status: 400, body: Data(#"{"error":"INVALID_ASSET"}"#.utf8), type: "application/json"); return
            }
            Task {
                do {
                    let result = try await api.careerRequest(path: "/api/resumes/\(resumeID)/assets", method: "POST", query: [:], body: .object([
                        "file_name": .string(String(name.prefix(120))), "data_url": .string(dataURL),
                    ]))
                    self.finish(task, id, status: 200, body: (try? JSONEncoder().encode(result)) ?? Data("{}".utf8), type: "application/json")
                } catch {
                    let status: Int, code: String
                    switch error {
                    case APIError.unauthorized: (status, code) = (401, "UNAUTHORIZED")
                    case APIError.server(let s, let c): (status, code) = (s, c)
                    default: (status, code) = (502, "UPLOAD_FAILED")
                    }
                    let payload = (try? JSONEncoder().encode(JSONValue.object(["error": .string(code)]))) ?? Data()
                    self.finish(task, id, status: status, body: payload, type: "application/json")
                }
            }
            return
        }
        if path.hasPrefix("/api/"), method == "GET" {
            Task {
                do {
                    let image = try await api.resumeImage(path: path)
                    self.finish(task, id, status: 200, body: image.data, type: image.contentType)
                } catch { self.finish(task, id, status: 404, body: Data(), type: "text/plain") }
            }
            return
        }
        finish(task, id, status: 404, body: Data(), type: "text/plain")
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        _ = lock.withLock { running.remove(ObjectIdentifier(task)) }
    }

    private static func body(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
            if data.count > maxUploadBytes { return nil }
        }
        return data
    }

    /// WebKit 要求在主线程回调 task，且 stop 之后不能再回调。
    private func finish(_ task: any WKURLSchemeTask, _ id: ObjectIdentifier, status: Int, body: Data, type: String) {
        let send = { [self] in
            guard lock.withLock({ running.remove(id) }) != nil else { return }
            let response = HTTPURLResponse(url: task.request.url ?? Self.editorURL, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": type, "Content-Length": "\(body.count)", "Cache-Control": "no-store"])!
            task.didReceive(response)
            task.didReceive(body)
            task.didFinish()
        }
        if Thread.isMainThread { send() } else { DispatchQueue.main.async(execute: send) }
    }
}
