import Foundation

/// 单片上传的发送进度（每片自己的任务委托；重定向仍由会话的委托拒绝）。
final class PieceProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Int64) -> Void
    init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension DesktopTransport {
    func uploadDataset(_ upload: DatasetUpload, access: String?) async throws -> JSONValue {
        guard DatasetRequest.id(upload.folder), UUID(uuidString:upload.id)?.uuidString.lowercased() == upload.id,
              !upload.name.isEmpty, !upload.name.contains(where:{ "\r\n\"\\/".contains($0) }), upload.limit > 0, upload.limit <= 512 * 1024 * 1024 else { throw APIError.invalidResponse }
        let size = try upload.file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= upload.limit else { throw APIError.invalidResponse }
        let directory = try DatasetUpload.privateDirectory(); defer { try? FileManager.default.removeItem(at:directory) }
        let container = directory.appendingPathComponent("multipart")
        FileManager.default.createFile(atPath:container.path,contents:nil,attributes:[.posixPermissions:0o600])
        let output = try FileHandle(forWritingTo:container), input = try FileHandle(forReadingFrom:upload.file)
        defer { try? input.close(); try? output.close() }
        let boundary = "DrawOffer-" + UUID().uuidString
        func write(_ text:String) throws { try output.write(contentsOf:Data(text.utf8)) }
        func field(_ name:String,_ value:String) throws { try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n") }
        var path = "/api/datasets", method = "POST"
        if let session = upload.session {
            guard DatasetRequest.id(session), upload.replacing == nil else { throw APIError.invalidResponse }
            path = "/api/interview-sessions/" + session + "/assets"; try field("source_type","uploaded")
            if !upload.transcribe { try field("transcribe","false") }
        } else if let replacing = upload.replacing {
            guard DatasetRequest.id(replacing), let revision = upload.revision, revision.allSatisfy({$0 >= "0" && $0 <= "9"}), !revision.isEmpty else { throw APIError.invalidResponse }
            path += "/" + replacing + "/file"; method = "PUT"; try field("confirm_replace","true")
        } else { try field("folder_id",upload.folder); try field("file_name",upload.name) }
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(upload.name)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        var copied = 0
        while let data = try input.read(upToCount:65536), !data.isEmpty { try Task.checkCancellation(); copied += data.count; guard copied <= upload.limit else { throw APIError.invalidResponse }; try output.write(contentsOf:data) }
        guard copied == size else { throw APIError.invalidResponse }
        try write("\r\n--\(boundary)--\r\n"); try output.synchronize()
        var request = URLRequest(url:origin.appending(path:path)); request.httpMethod = method; request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type")
        request.setValue(upload.id,forHTTPHeaderField:"Idempotency-Key")
        if let replacing = upload.replacing { request.setValue("\"dataset-\(replacing)-\(upload.revision!)\"",forHTTPHeaderField:"If-Match") }
        if let access { request.setValue("Bearer \(access)",forHTTPHeaderField:"Authorization") }
        let (data,response) = try await session.upload(for:request,fromFile:container)
        guard let http = response as? HTTPURLResponse, data.count <= 4 * 1024 * 1024 else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw APIError.server(status:http.statusCode,code:(try? JSONDecoder().decode(JSONValue.self,from:data))?.text("error") ?? "HTTP_\(http.statusCode)") }
        return try JSONDecoder().decode(JSONValue.self,from:data)
    }
    // MARK: 公共上传通道 /api/uploads（分片上传）

    /// 只走白名单里的五个路径；带 Bearer、不带 Cookie、拒绝重定向（同一个 URLSession）；响应体最多 1 MiB。
    private func uploads(_ path: String, method: String, body: Data? = nil, type: String? = nil, key: String? = nil, access: String?,
                         progress: (@Sendable (Int64) -> Void)? = nil) async throws -> JSONValue {
        guard UploadRequest.allowed(path: path, method: method) else { throw APIError.invalidResponse }
        var request = URLRequest(url: origin.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method; request.timeoutInterval = 120
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        if let access { request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization") }
        let (data, response) = if let body { try await session.upload(for: request, from: body, delegate: progress.map(PieceProgressDelegate.init)) }
            else { try await session.data(for: request) }
        guard let http = response as? HTTPURLResponse, data.count <= 1024 * 1024 else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: http.statusCode, code: (try? JSONDecoder().decode(JSONValue.self, from: data))?.text("error") ?? "HTTP_\(http.statusCode)")
        }
        if http.statusCode == 204 || data.isEmpty { return .null }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    private func state(_ value: JSONValue) throws -> PieceUploadState {
        guard let state = PieceUploadState(json: value) else { throw APIError.invalidResponse }
        return state
    }
    /// `POST /api/uploads`：`Idempotency-Key` 必填（小写 UUID），完成时作为入库幂等键。
    func startPieceUpload(_ start: PieceUploadStart, key: String, access: String?) async throws -> PieceUploadState {
        guard start.valid, UUID(uuidString: key)?.uuidString.lowercased() == key else { throw APIError.invalidResponse }
        let result = try state(try await uploads("/api/uploads", method: "POST", body: try JSONEncoder().encode(start.json), type: "application/json", key: key, access: access))
        guard result.fileSize == start.fileSize else { throw APIError.invalidResponse }
        return result
    }
    func pieceUploadState(_ id: String, access: String?) async throws -> PieceUploadState {
        try state(try await uploads("/api/uploads/" + id, method: "GET", access: access))
    }
    /// `PUT /api/uploads/{id}/chunks/{index}`：原始字节，单片不超过 4 MiB，成功 204。
    func putPiece(_ id: String, index: Int, data: Data, access: String?, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard index >= 0, !data.isEmpty, Int64(data.count) <= PieceUpload.chunkBytes else { throw APIError.invalidResponse }
        _ = try await uploads("/api/uploads/\(id)/chunks/\(index)", method: "PUT", body: data, type: "application/octet-stream", access: access, progress: progress)
    }
    func completePieceUpload(_ id: String, access: String?) async throws -> PieceUploadState {
        try state(try await uploads("/api/uploads/\(id)/complete", method: "POST", access: access))
    }
    func cancelPieceUpload(_ id: String, access: String?) async throws {
        _ = try await uploads("/api/uploads/" + id, method: "DELETE", access: access)
    }

    func downloadDataset(id:String,to target:URL,limit:Int64,access:String?) async throws {
        guard DatasetRequest.id(id), limit > 0, limit <= 512 * 1024 * 1024 else { throw APIError.invalidResponse }
        var request = URLRequest(url:origin.appending(path:"/api/datasets/" + id + "/source"),cachePolicy:.reloadIgnoringLocalCacheData); request.timeoutInterval = 600
        if let access { request.setValue("Bearer \(access)",forHTTPHeaderField:"Authorization") }
        let (bytes,response) = try await session.bytes(for:request); defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard http.statusCode == 200 else { throw APIError.server(status:http.statusCode,code:"DATASET_SOURCE_UNAVAILABLE") }
        guard http.expectedContentLength <= limit else { throw APIError.invalidResponse }
        FileManager.default.createFile(atPath:target.path,contents:Data(),attributes:[.posixPermissions:0o600])
        let output = try FileHandle(forWritingTo:target); defer { try? output.close() }
        try output.truncate(atOffset:0)
        var buffer = Data(), count:Int64 = 0
        for try await byte in bytes { try Task.checkCancellation(); count += 1; guard count <= limit else { throw APIError.invalidResponse }; buffer.append(byte); if buffer.count >= 65536 { try output.write(contentsOf:buffer); buffer.removeAll(keepingCapacity:true) } }
        guard count > 0 else { throw APIError.invalidResponse }; try output.write(contentsOf:buffer)
    }
}

/// 对话附件（Web `ChatAttachments`）：图片、文档与录音，单个 10 MiB，一次最多 10 个、合计 30 MiB。
public struct AgentAttachmentUpload: Sendable {
    public static let maxBytes = 10 * 1024 * 1024
    public static let maxFiles = 10
    public static let maxTotalBytes = 30 * 1024 * 1024
    public static let extensions = ["png", "jpg", "jpeg", "webp", "pdf", "docx", "md", "txt", "mp3", "wav", "m4a", "ogg", "webm"]

    public let session: String
    public let file: URL
    public let name: String
    public let id: String

    public init(session: String, file: URL) throws {
        let name = file.lastPathComponent
        guard Self.extensions.contains(file.pathExtension.lowercased()), !name.contains(where: { "\r\n\"\\/".contains($0) }) else {
            throw APIError.server(status: 415, code: "AGENT_ATTACHMENT_TYPE_UNSUPPORTED")
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw APIError.server(status: 400, code: "AGENT_ATTACHMENT_EMPTY") }
        guard size <= Self.maxBytes else { throw APIError.server(status: 413, code: "AGENT_ATTACHMENT_TOO_LARGE") }
        self.session = session; self.file = file; self.name = name; self.id = UUID().uuidString.lowercased()
    }

    /// 与 Web `chatFileKind` 相同的分类。
    public static func kind(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp"].contains(ext) ? "image" : ["mp3", "wav", "m4a", "ogg", "webm"].contains(ext) ? "audio" : "document"
    }

    public static func errorMessage(_ error: Error) -> String {
        guard case APIError.server(_, let code) = error else { return "上传失败，请重试。" }
        switch code {
        case "AGENT_ATTACHMENT_TYPE_UNSUPPORTED": return "不支持这种文件类型。"
        case "AGENT_ATTACHMENT_TOO_LARGE": return "单个文件不能超过 10 MB。"
        case "AGENT_ATTACHMENT_EMPTY": return "文件是空的。"
        case "AGENT_ATTACHMENT_LIMIT_REACHED": return "一次最多附加 10 个文件。"
        default: return "上传失败，请重试。"
        }
    }
}

extension DesktopTransport {
    func uploadAgentAttachment(_ upload: AgentAttachmentUpload, access: String?) async throws -> JSONValue {
        let path = "/api/agent/sessions/\(upload.session)/attachments"
        guard AgentRequest.allowed(path: path, method: "POST") else { throw APIError.invalidResponse }
        let data = try Data(contentsOf: upload.file)
        guard data.count <= AgentAttachmentUpload.maxBytes else { throw APIError.server(status: 413, code: "AGENT_ATTACHMENT_TOO_LARGE") }
        let boundary = "DrawOffer-" + UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(upload.name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: origin.appending(path: path)); request.httpMethod = "POST"; request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(upload.id, forHTTPHeaderField: "Idempotency-Key")
        if let access { request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization") }
        let (result, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, result.count <= 1024 * 1024 else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: http.statusCode, code: (try? JSONDecoder().decode(JSONValue.self, from: result))?.text("error") ?? "HTTP_\(http.statusCode)")
        }
        return try JSONDecoder().decode(JSONValue.self, from: result)
    }
}
