import Foundation

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

protocol DesktopRequesting: Sendable {
    func uploadDataset(_ upload: DatasetUpload, access: String?) async throws -> JSONValue
    func uploadAgentAttachment(_ upload: AgentAttachmentUpload, access: String?) async throws -> JSONValue
    func downloadDataset(id: String, to: URL, limit: Int64, access: String?) async throws
    var origin: URL { get }
    func downloadImage(path: String, limit: Int, access: String?) async throws -> DesktopImage
    func downloadResumePDF(id: String, lockVersion: Int, limit: Int, access: String?) async throws -> Data
    func streamAgent(path: String, method: String, body: JSONValue?, access: String?, onEvent: @MainActor @Sendable (AgentEvent) async -> Void) async throws
    func importResume(_ upload: ResumeImportUpload, access: String?) async throws -> JSONValue
    func mockAudio(path: String, method: String, body: JSONValue?, access: String?) async throws -> Data
    func speechSocket(path: String, query: [String: String], access: String?) throws -> URLSessionWebSocketTask
    func career(path: String, method: String, query: [String: String], body: JSONValue?, access: String?) async throws -> JSONValue
    /// 带 `If-None-Match` 的 GET：服务端回 304 时 `value` 为 nil，调用方用自己留着的那份。
    func validated(path: String, query: [String: String], etag: String?, access: String?) async throws -> (value: JSONValue?, etag: String?)
    func send<T: Decodable & Sendable>(_ type: T.Type, path: String, body: [String: String]?, access: String?) async throws -> T
    func events(access: String?, onEvent: @escaping @Sendable (UserEvent) async -> Void) async throws
}

extension DesktopRequesting {
    func uploadDataset(_ upload: DatasetUpload, access: String?) async throws -> JSONValue { throw APIError.invalidResponse }
    func uploadAgentAttachment(_ upload: AgentAttachmentUpload, access: String?) async throws -> JSONValue { throw APIError.invalidResponse }
    func downloadDataset(id: String, to: URL, limit: Int64, access: String?) async throws { throw APIError.invalidResponse }
    func career(path: String, method: String, query: [String: String], body: JSONValue?, access: String?) async throws -> JSONValue { throw APIError.invalidResponse }
    func downloadImage(path: String, limit: Int, access: String?) async throws -> DesktopImage { throw APIError.invalidResponse }
    func downloadResumePDF(id: String, lockVersion: Int, limit: Int, access: String?) async throws -> Data { throw APIError.invalidResponse }
    func streamAgent(path: String, method: String, body: JSONValue?, access: String?, onEvent: @MainActor @Sendable (AgentEvent) async -> Void) async throws { throw APIError.invalidResponse }
    func importResume(_ upload: ResumeImportUpload, access: String?) async throws -> JSONValue { throw APIError.invalidResponse }
    func mockAudio(path: String, method: String, body: JSONValue?, access: String?) async throws -> Data { throw APIError.invalidResponse }
    func speechSocket(path: String, query: [String: String], access: String?) throws -> URLSessionWebSocketTask { throw APIError.invalidResponse }
    func events(access: String?, onEvent: @escaping @Sendable (UserEvent) async -> Void) async throws { throw APIError.server(status: 404, code: "NOT_FOUND") }
    func validated(path: String, query: [String: String], etag: String?, access: String?) async throws -> (value: JSONValue?, etag: String?) {
        (try await career(path: path, method: "GET", query: query, body: nil, access: access), nil)
    }
    func send<T: Decodable & Sendable>(_ type: T.Type, path: String, body: [String: String]? = nil) async throws -> T {
        try await send(type, path: path, body: body, access: nil)
    }
}

final class DesktopTransport: DesktopRequesting {
    let origin: URL
    let session: URLSession

    init(origin: URL, allowLocalHTTP: Bool = false, protocolClasses: [AnyClass]? = nil) throws {
        guard let host = origin.host, !host.isEmpty,
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/",
              origin.scheme == "https" || (allowLocalHTTP && origin.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(origin.host ?? "")) else {
            throw APIError.invalidResponse
        }
        self.origin = origin.appendingPathComponent("")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        // 不交给系统缓存：304 只在 `validated` 里由我们自己带 If-None-Match、自己留缓存体时处理。
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.protocolClasses = protocolClasses
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func downloadImage(path: String, limit: Int, access: String?) async throws -> DesktopImage {
        guard path.hasPrefix("/api/"), !path.contains(".."), !path.contains("?"), !path.contains("#"), limit > 0 else { throw APIError.invalidResponse }
        var request = URLRequest(url: origin.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("image/png, image/jpeg", forHTTPHeaderField: "Accept")
        if let access { request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            throw APIError.server(status: http.statusCode, code: "IMAGE_READ_FAILED")
        }
        guard let type = http.mimeType?.lowercased(), ["image/png", "image/jpeg"].contains(type),
              http.expectedContentLength <= Int64(limit) else { throw APIError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw APIError.invalidResponse }
            data.append(byte)
        }
        return DesktopImage(data: data, contentType: type)
    }

    /// `GET /api/resumes/{id}/pdf?lock_version=`：服务端按当前版本生成 PDF，版本过期返回 409。
    /// 流式读取并同时校验 MIME、声明大小、实际大小与文件头，不落盘。
    func downloadResumePDF(id: String, lockVersion: Int, limit: Int, access: String?) async throws -> Data {
        guard !id.isEmpty, id.count <= 20, id.allSatisfy({ $0.isASCII && $0.isNumber }), lockVersion > 0, limit > 0 else { throw APIError.invalidResponse }
        var url = URLComponents(url: origin.appending(path: "/api/resumes/\(id)/pdf"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "lock_version", value: String(lockVersion))]
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 180
        request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        if let access { request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        var data = Data()
        guard http.statusCode == 200 else {
            // 错误体是小段 JSON，只读前 16 KiB 取 error 码
            for try await byte in bytes { guard data.count < 16 * 1024 else { break }; data.append(byte) }
            let code = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?.stringValue
            throw APIError.server(status: http.statusCode, code: code ?? "HTTP_\(http.statusCode)")
        }
        guard http.mimeType?.lowercased() == "application/pdf", http.expectedContentLength <= Int64(limit) else { throw APIError.invalidResponse }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw APIError.invalidResponse }
            data.append(byte)
        }
        guard data.count >= 5, String(decoding: data.prefix(5), as: UTF8.self) == "%PDF-" else { throw APIError.invalidResponse }
        return data
    }

    /// `POST /api/resumes/import`：multipart 上传文件，`Idempotency-Key` 固定为本次导入的 UUID，重试不重复受理。
    func importResume(_ upload: ResumeImportUpload, access: String?) async throws -> JSONValue {
        let boundary = "DrawOffer-" + UUID().uuidString
        var data = Data()
        func append(_ text: String) { data.append(Data(text.utf8)) }
        let safeName = upload.fileName.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(upload.contentType)\r\n\r\n")
        data.append(upload.content); append("\r\n")
        if let template = upload.templateID { append("--\(boundary)\r\nContent-Disposition: form-data; name=\"template_id\"\r\n\r\n\(template)\r\n") }
        append("--\(boundary)--\r\n")
        var request = URLRequest(url: origin.appending(path: "/api/resumes/import"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.httpBody = data
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(upload.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        if let access { request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization") }
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(JSONValue.self, from: body))?["error"]?.stringValue
            throw APIError.server(status: http.statusCode, code: code ?? "HTTP_\(http.statusCode)")
        }
        return try JSONDecoder().decode(JSONValue.self, from: body)
    }

    /// 模拟面试的二进制音频：试听 mp3 与录音 wav，最多 16 MiB，只在内存中交给播放器。
    func mockAudio(path: String, method: String, body: JSONValue?, access: String?) async throws -> Data {
        guard MockInterviewRequest.audio(path: path, method: method) else { throw APIError.invalidResponse }
        var request = URLRequest(url: origin.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("audio/mpeg, audio/wav", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        if let access { request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        let limit = 16 * 1024 * 1024
        var data = Data()
        guard http.statusCode == 200 else {
            for try await byte in bytes { guard data.count < 16 * 1024 else { break }; data.append(byte) }
            let code = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?.stringValue
            throw APIError.server(status: http.statusCode, code: code ?? "HTTP_\(http.statusCode)")
        }
        guard let type = http.mimeType?.lowercased(), ["audio/mpeg", "audio/wav", "audio/x-wav", "audio/wave"].contains(type),
              http.expectedContentLength <= Int64(limit) else { throw APIError.invalidResponse }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw APIError.invalidResponse }
            data.append(byte)
        }
        return data
    }

    /// 实时语音识别 WebSocket：`/api/mock-interviews/{id}/speech?question_id=&purpose=`，握手携带 desktop Bearer。
    /// 作答与输入框语音带题号；设备检测试读一句不带题号（结果不保存、不能用来提交回答）。
    /// 可选 `recognizer=local`：本机识别，服务端只保存录音并接收 `stop` 里的文字与词时间。
    static func speechQueryAllowed(_ query: [String: String]) -> Bool {
        var query = query
        if let recognizer = query.removeValue(forKey: "recognizer"), recognizer != "local" { return false }
        let question = query["question_id"] ?? ""
        let numeric = !question.isEmpty && question.allSatisfy { $0.isASCII && $0.isNumber }
        switch query["purpose"] {
        case "voice_input", "voice_answer": return numeric && query.count == 2
        case "device_check": return query.count == 1
        default: return false
        }
    }

    func speechSocket(path: String, query: [String: String], access: String?) throws -> URLSessionWebSocketTask {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "api", parts[1] == "mock-interviews", UUID(uuidString: parts[2])?.uuidString.lowercased() == parts[2],
              parts[3] == "speech", Self.speechQueryAllowed(query) else { throw APIError.invalidResponse }
        var components = URLComponents(url: origin.appending(path: path), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        if let access { request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization") }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1024 * 1024
        return task
    }

    /// AI 助手的 SSE 流：逐帧解析并按顺序回调；收到终止事件即结束，未收到即视为中断。
    /// 单帧最多 1 MiB、整条流最多 16 MiB；空闲超过 5 分钟由 URLSession 超时中断。
    func streamAgent(path: String, method: String, body: JSONValue?, access: String?, onEvent: @MainActor @Sendable (AgentEvent) async -> Void) async throws {
        guard AgentRequest.streams(path: path, method: method) else { throw APIError.invalidResponse }
        var request = URLRequest(url: origin.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.timeoutInterval = 300
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        if let access { request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { guard data.count < 16 * 1024 else { break }; data.append(byte) }
            let code = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?.stringValue
            throw APIError.server(status: http.statusCode, code: code ?? "HTTP_\(http.statusCode)")
        }
        guard http.mimeType == "text/event-stream" else { throw APIError.invalidResponse }
        var frame = Data(), total = 0, previous: UInt8 = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            total += 1
            guard total <= 16 * 1024 * 1024, frame.count <= 1024 * 1024 else { throw APIError.invalidResponse }
            if byte == 0x0A && previous == 0x0A {
                if let event = AgentEvent.parse(frame: String(decoding: frame, as: UTF8.self)) {
                    await onEvent(event)
                    if event.isTerminal { return }
                }
                frame.removeAll(keepingCapacity: true); previous = 0; continue
            }
            if byte != 0x0D { frame.append(byte); previous = byte }
        }
        throw APIError.server(status: 502, code: "AGENT_STREAM_INCOMPLETE")
    }

    func career(path: String, method: String, query: [String: String], body: JSONValue?, access: String?) async throws -> JSONValue {
        guard CareerRequest.allowed(path: path, method: method), !query.keys.contains(where: { !["scope", "cursor", "limit", "week_start", "timezone", "application_id", "include_archived", "v", "job_application_id", "resume_id", "status", "folder_id", "confirm_contents", "start_at", "end_at", "type", "q", "prefix", "session_id", "include_history", "keyword", "company_ids", "city", "job_category", "recruitment_type", "job_id", "page", "page_size", "sort", "industry", "direction", "published_within", "exclude_joined", "intent", "seed"].contains($0) }) else { throw APIError.invalidResponse }
        var url = URLComponents(url: origin.appending(path: path), resolvingAgainstBaseURL: false)!
        url.queryItems = JobPool.queryItems(query)
        var request = URLRequest(url: url.url!)
        request.httpMethod = method
        var payload = body
        if MockInterviewRequest.allowed(path: path, method: method), path.hasSuffix("/answers") || path.hasSuffix("/skip") {
            guard let key = body?.text("__idempotency_key"), let id = UUID(uuidString: key), id.uuidString.lowercased() == key,
                  case .object(var fields) = body else { throw APIError.invalidResponse }
            fields.removeValue(forKey: "__idempotency_key"); payload = .object(fields)
            request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        }
        if method == "PUT", path.hasSuffix("/text"), DatasetRequest.allowed(path: path, method: method) {
            // MD / TXT 原地保存带当前版本（`If-Match`），别处改过时服务端回 412。
            guard let (tag, fields) = DatasetViewer.textSave(path: path, body: body) else { throw APIError.invalidResponse }
            payload = fields
            request.setValue(tag, forHTTPHeaderField: "If-Match")
        }
        request.timeoutInterval = 180
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        if let access { request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization") }
        if path.hasSuffix("/logo") {
            guard method == "GET", query.count == 1, let revision = query["v"], revision.count == 64,
                  revision.allSatisfy({ ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0)) }) else { throw APIError.invalidResponse }
            request.setValue("image/webp", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            if http.statusCode == 401 { throw APIError.unauthorized }
            guard http.statusCode == 200, http.mimeType == "image/webp", http.expectedContentLength <= 256 * 1024 else { throw APIError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 256 * 1024 else { throw APIError.invalidResponse }
                data.append(byte)
            }
            guard data.count >= 12, String(decoding: data.prefix(4), as: UTF8.self) == "RIFF",
                  String(decoding: data[8..<12], as: UTF8.self) == "WEBP" else { throw APIError.invalidResponse }
            return .object(["image_base64": .string(data.base64EncodedString())])
        }
        if let body {
            if path == "/api/job-descriptions/parse-draft" {
                let boundary = "DrawOffer-" + UUID().uuidString
                var data = Data()
                func append(_ text: String) { data.append(Data(text.utf8)) }
                if let encoded = body["image_base64"]?.stringValue {
                    guard let image = Data(base64Encoded: encoded), image.count <= 10 * 1024 * 1024 else { throw APIError.invalidResponse }
                    let type = body.text("content_type")
                    guard ["image/png", "image/jpeg"].contains(type) else { throw APIError.invalidResponse }
                    append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"upload.\(type == "image/png" ? "png" : "jpg")\"\r\nContent-Type: \(type)\r\n\r\n")
                    data.append(image); append("\r\n")
                } else { append("--\(boundary)\r\nContent-Disposition: form-data; name=\"text\"\r\n\r\n\(body.text("text"))\r\n") }
                append("--\(boundary)--\r\n"); request.httpBody = data
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            } else if path.hasSuffix("/written-questions:extract") {
                let (data, type) = try CareerUpload.writtenImport(body)
                request.httpBody = data; request.setValue(type, forHTTPHeaderField: "Content-Type")
            } else { request.httpBody = try JSONEncoder().encode(payload); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        }
        let data: Data
        let response: URLResponse
        if path.hasPrefix("/api/mock-interviews/") && method == "POST" && ["answers", "skip", "reply:retry"].contains(String(path.split(separator: "/").last ?? "")) {
            let (bytes, headers) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard headers.expectedContentLength <= Int64(MockInterviewRequest.maximumTurnBytes) else { throw APIError.invalidResponse }
            var buffer = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard buffer.count < MockInterviewRequest.maximumTurnBytes else { throw APIError.invalidResponse }
                buffer.append(byte)
            }
            data = buffer; response = headers
        } else { (data, response) = try await session.data(for: request) }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?.stringValue
            throw APIError.server(status: http.statusCode, code: code ?? "HTTP_\(http.statusCode)")
        }
        if http.mimeType == "text/event-stream", path.hasPrefix("/api/mock-interviews/") { return try MockInterviewRequest.decodeEvents(data) }
        if http.statusCode == 204 || data.isEmpty { return .null }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// `GET /api/events` SSE：`event: ready`（连上或服务端重连 MQ，期间事件可能丢）、`event: change` + `data: {"topic","ref"}`、`: ping` 心跳。
    /// 系统的按行读取会跳过空行，所以 `ready` 在读到事件名时就回调，`change` 在读到 data 行时回调。心跳 25 秒，70 秒没有数据算断线。
    func events(access: String?, onEvent: @escaping @Sendable (UserEvent) async -> Void) async throws {
        var request = URLRequest(url: origin.appending(path: "/api/events"), cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 70
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        if let access { request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { guard data.count < 16 * 1024 else { break }; data.append(byte) }
            let code = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?.stringValue
            throw APIError.server(status: http.statusCode, code: code ?? "HTTP_\(http.statusCode)")
        }
        guard http.mimeType?.lowercased() == "text/event-stream" else { throw APIError.invalidResponse }
        var name = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.count <= 16 * 1024, !line.hasPrefix(":") else { continue }
            if line.hasPrefix("event:") {
                name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if name == "ready" { await onEvent(.ready); name = "" }
            } else if line.hasPrefix("data:"), name == "change" {
                name = ""
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.dropFirst(5).utf8)),
                      let topic = value["topic"]?.stringValue, !topic.isEmpty, topic.count <= 64 else { continue }
                let ref = value["ref"]?.stringValue ?? value["ref"]?.numberValue.map { String(Int($0)) }
                await onEvent(.change(topic: topic, ref: ref))
            }
        }
    }

    /// 简历列表与详情的条件读：服务端按版本列算弱 ETag，没变时回 304 不带正文。
    func validated(path: String, query: [String: String], etag: String?, access: String?) async throws -> (value: JSONValue?, etag: String?) {
        guard ReadCache.validates(path: path, query: query) else {
            return (try await career(path: path, method: "GET", query: query, body: nil, access: access), nil)
        }
        var request = URLRequest(url: origin.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 180
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        if let access { request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization") }
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        if http.statusCode == 304 {
            guard etag != nil else { throw APIError.invalidResponse }
            return (nil, http.value(forHTTPHeaderField: "ETag") ?? etag)
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?.stringValue
            throw APIError.server(status: http.statusCode, code: code ?? "HTTP_\(http.statusCode)")
        }
        return (try JSONDecoder().decode(JSONValue.self, from: data), http.value(forHTTPHeaderField: "ETag"))
    }

    func send<T: Decodable & Sendable>(_ type: T.Type, path: String, body: [String: String]? = nil, access: String? = nil) async throws -> T {
        guard path.hasPrefix("/api/"), !path.contains(".."), !path.contains("?"), !path.contains("#") else { throw APIError.invalidResponse }
        var request = URLRequest(url: origin.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        if let access { request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            let code = (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["error"]?.stringValue
            throw APIError.server(status: http.statusCode, code: code ?? "HTTP_\(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

public struct DesktopCapabilities: Decodable, Sendable {
    public let wechat_login_enabled: Bool
    public let browser_login_enabled: Bool?
    public let password_login_enabled: Bool?
    public let session_protocol: Int
}

public struct DesktopQRCode: Decodable, Sendable {
    public let scene: String
    public let poll_token: String
    public let qr_base64: String
    public let expires_in: Int
    public let poll_interval_seconds: Int
}

struct DesktopTokens: Decodable, Sendable {
    let user: User
    let access_token: String
    let refresh_token: String
    let expires_in: Int
    let session_protocol: Int
}

public struct HTTPAPIClient: APIClient {
    public let coordinator: SessionCoordinator

    public init(baseURL: URL, tokens: any TokenStore, allowLocalHTTP: Bool = false) throws {
        coordinator = SessionCoordinator(transport: try DesktopTransport(origin: baseURL, allowLocalHTTP: allowLocalHTTP), tokens: tokens,
                                         imageDisk: ImageDiskCache.standard())
    }

    init(coordinator: SessionCoordinator) { self.coordinator = coordinator }

    public func preparePaper(_ request: ResumeRenderRequest) async throws -> PaperPreparation { try await coordinator.preparePaper(request) }
    public func uploadDataset(_ upload: DatasetUpload) async throws -> JSONValue { try await coordinator.uploadDataset(upload) }
    public func downloadDataset(id: String, limit: Int64) async throws -> DatasetFile { try await coordinator.downloadDataset(id: id, limit: limit) }
    public func careerRequest(path: String, method: String, query: [String: String], body: JSONValue?) async throws -> JSONValue { try await coordinator.careerRequest(path: path, method: method, query: query, body: body) }
    public func uploadAgentAttachment(_ upload: AgentAttachmentUpload) async throws -> JSONValue { try await coordinator.uploadAgentAttachment(upload) }
    public func capabilities() async throws -> DesktopCapabilities { try await coordinator.capabilities() }
    public func beginLogin(clientVersion: String) async throws -> DesktopLoginChallenge { try await coordinator.beginLogin(clientVersion: clientVersion) }
    public func loginStatus(_ challenge: DesktopLoginChallenge) async throws -> String { try await coordinator.loginStatus(challenge) }
    public func completeLogin(_ challenge: DesktopLoginChallenge) async throws -> User { try await coordinator.completeLogin(challenge) }
    public func beginBrowserLogin(clientVersion: String) async throws -> BrowserLoginChallenge { try await coordinator.beginBrowserLogin(clientVersion: clientVersion) }
    public func completeBrowserLogin(callback: URL) async throws -> User { try await coordinator.completeBrowserLogin(callback: callback) }
    public func currentUser() async throws -> User? { try await coordinator.restore() }
    public func signIn(email: String, password: String) async throws -> User {
        try await coordinator.passwordLogin(email: email, password: password, clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
    }
    public func signOut() async throws { try await coordinator.signOut() }
    public func listResumeTemplates() async throws -> [ResumeTemplate] {
        struct Envelope: Decodable, Sendable { let templates: [ResumeTemplate] }
        return try await coordinator.request(Envelope.self, path: "/api/resume-templates").templates
            .filter { !ResumeRequest.retiredTemplateKeys.contains($0.key) }
    }
    /// 站点 origin；分享链接 `{origin}/share/{token}` 使用。
    public var origin: URL { coordinator.origin }
    public func listResumes() async throws -> [ResumeSummary] { try await coordinator.listResumes() }
    public func listResumePage() async throws -> (resumes: [ResumeSummary], defaultID: String?) { try await coordinator.listResumePage() }
    public func downloadResumePDF(id: String, lockVersion: Int) async throws -> Data { try await coordinator.downloadResumePDF(id: id, lockVersion: lockVersion) }
    public func streamAgent(path: String, method: String, body: JSONValue?, onEvent: @MainActor @Sendable (AgentEvent) async -> Void) async throws {
        try await coordinator.streamAgent(path: path, method: method, body: body, onEvent: onEvent)
    }
    public func importResume(_ upload: ResumeImportUpload) async throws -> JSONValue { try await coordinator.importResume(upload) }
    public func mockAudio(path: String, method: String, body: JSONValue?) async throws -> Data { try await coordinator.mockAudio(path: path, method: method, body: body) }
    public func speechSocket(interviewID: String, questionID: String, purpose: String, local: Bool) async throws -> URLSessionWebSocketTask {
        try await coordinator.speechSocket(interviewID: interviewID, questionID: questionID, purpose: purpose, local: local)
    }
    public func accountAvatar(path: String) async throws -> Data { try await coordinator.accountAvatar(path: path) }
    public func purgeCache() async { await coordinator.purgeCache() }
    public func streamEvents(onEvent: @escaping @Sendable (UserEvent) async -> Void) async throws { try await coordinator.streamEvents(onEvent: onEvent) }
    public func resumeImage(path: String) async throws -> (data: Data, contentType: String) { try await coordinator.resumeImage(path: path) }
}
