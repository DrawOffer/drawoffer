import DrawOfferCore
import SwiftUI
import WebKit

/// 纸上临时显示的一处改法（分区 12：浅蓝底 = 还没换上，橙色 = 要核实）。只是装饰，不改正文。
public struct PaperLineChange: Equatable, Sendable {
    public let lineID: String
    /// AI 看到的原句：纸上这一行已经不是它时不预览。
    public let before: String
    public let text: String
    public let risky: [String]
    public init(lineID: String, before: String, text: String, risky: [String] = []) {
        self.lineID = lineID; self.before = before; self.text = text; self.risky = risky
    }
    var json: JSONValue {
        .object(["lineId": .string(lineID), "before": .string(before), "text": .string(text), "risky": .array(risky.map(JSONValue.string))])
    }
}

/// 检查简历纸边的小圆圈（12.7–12.11）：空心 = 还没看，蓝 = 正在看，灰 = 看过。
public struct PaperMark: Equatable, Sendable {
    public enum State: String, Sendable { case pending, current, done }
    public let key: String
    public let nodeIDs: [String]
    public let state: State
    public init(key: String, nodeIDs: [String], state: State) { self.key = key; self.nodeIDs = nodeIDs; self.state = state }
}

/// 光标 / 选区所在的行（纸面 `line` 事件）。坐标是纸面视图里的点，已含缩放。
public struct PaperLine: Equatable, Sendable {
    public let unitID: String
    public let lineIDs: [String]
    /// 只选了一行里的几个字时，字符范围。
    public let selection: Range<Int>?
    /// 第一行的位置。
    public let rect: CGRect
    /// 纸面（第一页所在的整张纸）的位置。
    public let paper: CGRect
}

/// 原生 → 可编辑纸面的指令（editor protocol 1，见 `apps/native/renderer/editor.tsx`）。
public enum ResumeEditorCommand: Sendable {
    case undo, redo, focus, resetOrder
    case jump(String?)
    case reorder([String])
    case rename(String, String)
    case remove(String)
    case add(kind: String, title: String)
    /// 临时高亮这几行、把改法预览在纸上；同一 `source` 再发一次即替换，两项都空即清除。
    case decorate(source: String, highlight: [String], preview: [PaperLineChange])
    case marks([PaperMark])
    /// 滚到这几行（放在屏幕中间）。
    case reveal([String])
    /// 智能排版：量纸上每段的行数与末行（页面回 `layoutMetrics`）。
    case layoutMeasure(requestID: String)
    /// 把 `review:layout` 的返回交给页面核验并写进纸里（页面回 `layoutApplied`）。
    case layoutApply(requestID: String, response: JSONValue)
    /// 排版后纸面没再改过时整批撤回（页面回 `layoutUndo`）。
    case layoutUndo

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
        case .decorate(let source, let highlight, let preview):
            return .object(["type": .string("decorate"), "source": .string(source), "highlight": .array(highlight.map(JSONValue.string)),
                            "preview": .array(preview.map(\.json))])
        case .marks(let marks):
            return .object(["type": .string("marks"), "marks": .array(marks.map {
                .object(["key": .string($0.key), "nodeIds": .array($0.nodeIDs.map(JSONValue.string)), "state": .string($0.state.rawValue)])
            })])
        case .reveal(let ids): return .object(["type": .string("reveal"), "nodeIds": .array(ids.map(JSONValue.string))])
        case .layoutMeasure(let id): return .object(["type": .string("layout-measure"), "requestId": .string(id)])
        case .layoutApply(let id, let response):
            return .object(["type": .string("layout-apply"), "requestId": .string(id), "response": response])
        case .layoutUndo: return .object(["type": .string("layout-undo")])
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
    /// 光标所在的可改写行；nil 表示不在可改的行上（或正在打字）。
    case line(PaperLine?)
    /// 在纸面里按了 ⌘K。
    case lineOpen(PaperLine)
    /// 纸面总页数。
    case pages(Int)
    /// 点了纸边的小圆圈。
    case mark(String)
    /// 智能排版：每段度量（Web `measureDocumentLayout`，字段同 `review:layout` 的 blocks，未截断）与当时的页数。
    case layoutMetrics(requestID: String, blocks: [JSONValue], pages: Int)
    /// 智能排版写进纸里了：`total` 条建议里换上了 `applied` 处；`undoable` 表示可以整批撤回。
    case layoutApplied(LayoutApplied)
    /// 整批撤回的结果（false：排版后纸面又改过，没撤）。
    case layoutUndo(Bool)
    /// 排版后纸面又被改过，不能再整批撤回。
    case layoutUndoExpired
}

public struct LayoutApplied: Equatable, Sendable {
    public let requestID: String
    public let total: Int
    public let applied: Int
    public let summary: String
    public let pagesBefore: Int
    public let pagesAfter: Int
    public let undoable: Bool
}

/// 把指令排进纸面：编辑器视图持有它，页面 ready 后才真正执行。
@MainActor
public final class ResumeEditorChannel {
    weak var bridge: EditorBridge?
    public init() {}
    public func send(_ command: ResumeEditorCommand) { bridge?.call("command", command.json) }
    /// 原生改写正文（引导写入、AI 采纳）：页面按当前模板重新排版。
    public func replaceData(_ data: JSONValue) { bridge?.call("replaceData", data) }
    /// 07.2 模板悬停预览：`template-preview` 接口返回的 preview（data / style / layout_plan）；nil 恢复原纸面。不改正文、不保存。
    public func previewTemplate(_ preview: JSONValue?) { bridge?.call("previewTemplate", preview ?? .null) }
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
        // features.lineChat：选区工具栏只管格式，纸面上报光标所在的行（改这一条在原生）
        call("load", .object(["resumeId": .string(resumeID), "data": data, "style": style, "layout_plan": layoutPlan ?? .null,
                              "features": .object(["lineChat": .bool(true)])]))
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
            case "line":
                onEvent(.line(Self.line(body)))
            case "line-open":
                if let line = Self.line(body) { onEvent(.lineOpen(line)) }
            case "pages":
                if let count = (body["count"] as? NSNumber)?.intValue, count > 0 { onEvent(.pages(count)) }
            case "mark":
                if let key = body["key"] as? String { onEvent(.mark(key)) }
            case "layout-metrics":
                guard let id = body["requestId"] as? String, case .array(let blocks)? = Self.json(body["blocks"]) else { return }
                onEvent(.layoutMetrics(requestID: id, blocks: blocks, pages: (body["pages"] as? NSNumber)?.intValue ?? 1))
            case "layout-applied":
                guard let id = body["requestId"] as? String else { return }
                let int = { (key: String) in (body[key] as? NSNumber)?.intValue ?? 0 }
                onEvent(.layoutApplied(LayoutApplied(requestID: id, total: int("total"), applied: int("count"), summary: body["summary"] as? String ?? "",
                                                     pagesBefore: int("pagesBefore"), pagesAfter: int("pagesAfter"), undoable: body["undoable"] as? Bool ?? false)))
            case "layout-undo":
                onEvent(.layoutUndo(body["ok"] as? Bool ?? false))
            case "layout-undoable":
                if body["value"] as? Bool == false { onEvent(.layoutUndoExpired) }
            default: break
            }
        }
    }

    private static func box(_ value: Any?) -> CGRect? {
        guard let object = value as? [String: Any] else { return nil }
        let number = { (key: String) in (object[key] as? NSNumber)?.doubleValue }
        guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height") else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func line(_ body: [String: Any]) -> PaperLine? {
        guard let unit = body["unitId"] as? String, let ids = body["lineIds"] as? [String], !ids.isEmpty,
              let rect = box(body["rect"]), let paper = box(body["paper"]) else { return nil }
        var selection: Range<Int>?
        if let range = body["selection"] as? [String: Any], let start = (range["start"] as? NSNumber)?.intValue,
           let end = (range["end"] as? NSNumber)?.intValue, end > start { selection = start..<end }
        return PaperLine(unitID: unit, lineIDs: ids, selection: selection, rect: rect, paper: paper)
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
            if PaperAssets.isBundledTemplate(path) || PaperAssets.isTemplateStyleImage(path), let file = Bundle.module.url(forResource: (name as NSString).deletingPathExtension, withExtension: ext, subdirectory: "templates"),
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
