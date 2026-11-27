import CryptoKit
import Foundation
import Security

public struct RefreshJournal: Codable, Sendable {
    public let requestID: String
    public let refreshToken: String
    public let startedAt: Date
}

public struct DesktopCredentialRecord: Codable, Sendable {
    public let accountID: String
    public let refreshToken: String
    public let generation: UUID
    public let pending: RefreshJournal?

    public init(accountID: String, refreshToken: String, generation: UUID, pending: RefreshJournal? = nil) {
        self.accountID = accountID
        self.refreshToken = refreshToken
        self.generation = generation
        self.pending = pending
    }
}

// Implementations must atomically replace the record in a system credential store, scoped by origin/channel/app.
public protocol TokenStore: Sendable {
    func load(scope: String) throws -> DesktopCredentialRecord?
    func save(_ record: DesktopCredentialRecord, scope: String) throws
    func clear(scope: String) throws
}

public struct DesktopLoginChallenge: Sendable {
    public let qrcode: DesktopQRCode
    fileprivate let verifier: String
    fileprivate let requestID: String
    fileprivate let generation: UUID
}

/// 浏览器登录的一次挑战：verifier 只留在本进程内存，浏览器只拿到 S256 challenge 与随机 state。
public struct BrowserLoginChallenge: Sendable {
    public let authorizeURL: URL
    public let state: String
    fileprivate let verifier: String
    fileprivate let requestID: String
    fileprivate let generation: UUID
}

public actor SessionCoordinator {
    public nonisolated var origin: URL { transport.origin }
    private let transport: any DesktopRequesting
    private let tokens: any TokenStore
    private let scope: String
    private var generation = UUID()
    private var disabled = false
    private var browserChallenge: BrowserLoginChallenge?
    private var access: String?
    private var accessDeadline = Date.distantPast
    private var flight: (id: UUID, task: Task<DesktopTokens, Error>)?
    private var exchange: (requestID: String, task: Task<DesktopTokens, Error>)?
    private typealias LogoutRecovery = (id: UUID, saved: DesktopCredentialRecord?, refresh: Task<DesktopTokens, Error>?, exchange: Task<DesktopTokens, Error>?)
    private var logoutRecovery: LogoutRecovery?
    private var logoutFlight: (id: UUID, task: Task<Void, Error>)?
    /// 读缓存（规则见 `ReadCache`）：键 → 结果与过期时间；同一请求正在路上时后来的调用共用它。
    /// `cacheEpoch` 在作废时加一，作废前发出、作废后才回来的读结果不再写回缓存。
    private var readCache: [String: (value: any Sendable, expires: Date)] = [:]
    private var readFlights: [String: (epoch: Int, task: Task<any Sendable, Error>)] = [:]
    private var cacheEpoch = 0
    private var images = ImageMemoryCache()
    private let imageDisk: ImageDiskCache?
    /// 简历列表与详情最近一次的 ETag 和正文（只在内存，换账号即清空）；作废缓存后再读时用它发条件请求。
    private var validators: [String: (etag: String, value: JSONValue)] = [:]
    private var textImportUnsupported = false

    init(transport: any DesktopRequesting, tokens: any TokenStore, imageDisk: ImageDiskCache? = nil) {
        self.transport = transport
        self.tokens = tokens
        self.imageDisk = imageDisk
        // Stored credential key from before the DrawOffer rename; keep it so users stay signed in.
        scope = "LinkResume:macos:desktop:\(transport.origin.absoluteString)"
    }

    public func capabilities() async throws -> DesktopCapabilities {
        let result = try await transport.send(DesktopCapabilities.self, path: "/api/auth/desktop/capabilities")
        guard result.session_protocol == 1 else { throw APIError.invalidResponse }
        return result
    }

    /// 公开的 `GET /api/auth/capabilities`（新手引导开关等）：不带凭据，但和其他请求共用同一个连接池，不再单独握手。
    public func authCapabilities() async throws -> JSONValue {
        try await transport.send(JSONValue.self, path: "/api/auth/capabilities")
    }

    public func beginLogin(clientVersion: String) async throws -> DesktopLoginChallenge {
        let current = UUID()
        try await signOut(generation: current)
        guard generation == current else { throw APIError.unauthorized }
        disabled = false
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw APIError.invalidResponse }
        let verifier = base64url(Data(random))
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let qr = try await transport.send(DesktopQRCode.self, path: "/api/auth/desktop/wechat/qrcode", body: [
            "platform": "macos", "client_version": clientVersion,
            "code_challenge": challenge, "code_challenge_method": "S256",
        ])
        guard current == generation, !disabled else { throw APIError.unauthorized }
        return DesktopLoginChallenge(qrcode: qr, verifier: verifier, requestID: UUID().uuidString, generation: current)
    }

    public func loginStatus(_ challenge: DesktopLoginChallenge) async throws -> String {
        guard challenge.generation == generation, !disabled else { throw APIError.unauthorized }
        struct Status: Decodable, Sendable { let status: String }
        let result = try await transport.send(Status.self, path: "/api/auth/desktop/wechat/status", body: [
            "scene": challenge.qrcode.scene, "poll_token": challenge.qrcode.poll_token,
        ])
        guard challenge.generation == generation, !disabled else { throw APIError.unauthorized }
        return result.status
    }

    public func completeLogin(_ challenge: DesktopLoginChallenge) async throws -> User {
        guard challenge.generation == generation, !disabled else { throw APIError.unauthorized }
        guard exchange == nil || exchange?.requestID == challenge.requestID else { throw APIError.unauthorized }
        if exchange == nil {
            exchange = (challenge.requestID, Task {
                try await transport.send(DesktopTokens.self, path: "/api/auth/desktop/wechat/exchange", body: [
                    "scene": challenge.qrcode.scene, "poll_token": challenge.qrcode.poll_token,
                    "code_verifier": challenge.verifier, "request_id": challenge.requestID,
                ])
            })
        }
        let shared = exchange!
        let result: DesktopTokens
        do { result = try await sharedTaskValue(shared.task) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if exchange?.requestID == shared.requestID { exchange = nil }
            throw error
        }
        try Task.checkCancellation()
        guard challenge.generation == generation, !disabled else { throw APIError.unauthorized }
        if exchange?.requestID == shared.requestID {
            try persist(result, expectedAccount: nil)
            exchange = nil
        }
        return result.user
    }

    /// 生成浏览器授权地址；新的挑战会先退出旧会话，并使之前的挑战失效。
    public func beginBrowserLogin(clientVersion: String) async throws -> BrowserLoginChallenge {
        let current = UUID()
        try await signOut(generation: current)
        guard generation == current else { throw APIError.unauthorized }
        disabled = false
        let verifier = try randomToken(32)
        let state = try randomToken(24)
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: transport.origin.appendingPathComponent("desktop-login"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "challenge", value: challenge), URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "platform", value: "macos"), URLQueryItem(name: "client_version", value: clientVersion),
        ]
        guard let url = components.url else { throw APIError.invalidResponse }
        browserChallenge = BrowserLoginChallenge(authorizeURL: url, state: state, verifier: verifier,
                                                 requestID: UUID().uuidString, generation: current)
        return browserChallenge!
    }

    /// 处理 `drawoffer://auth/callback?code&state`：state 必须与当前挑战一致，授权码只换取一次。
    public func completeBrowserLogin(callback: URL) async throws -> User {
        guard let challenge = browserChallenge, challenge.generation == generation, !disabled else { throw APIError.unauthorized }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard callback.scheme == "drawoffer", callback.host == "auth", callback.path == "/callback",
              let state = items.first(where: { $0.name == "state" })?.value, state == challenge.state,
              let code = items.first(where: { $0.name == "code" })?.value, code.count <= 128 else {
            throw APIError.server(status: 400, code: "LOGIN_CALLBACK_INVALID")
        }
        let result = try await transport.send(DesktopTokens.self, path: "/api/auth/desktop/browser/exchange", body: [
            "code": code, "code_verifier": challenge.verifier, "request_id": challenge.requestID,
        ])
        try Task.checkCancellation()
        guard challenge.generation == generation, !disabled, browserChallenge?.state == challenge.state else { throw APIError.unauthorized }
        try persist(result, expectedAccount: nil)
        browserChallenge = nil
        return result.user
    }

    /// 开发/本地环境的邮箱密码登录：服务端校验后返回一次性授权码，再用本地 PKCE verifier 走 browser/exchange 换会话。
    public func passwordLogin(email: String, password: String, clientVersion: String) async throws -> User {
        let current = UUID()
        try await signOut(generation: current)
        guard generation == current else { throw APIError.unauthorized }
        disabled = false
        let verifier = try randomToken(32)
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        struct Code: Decodable, Sendable { let code: String }
        let code = try await transport.send(Code.self, path: "/api/auth/desktop/password", body: [
            "platform": "macos", "client_version": clientVersion, "code_challenge": challenge,
            "code_challenge_method": "S256", "email": email, "password": password,
        ])
        guard generation == current, !disabled else { throw APIError.unauthorized }
        let result = try await transport.send(DesktopTokens.self, path: "/api/auth/desktop/browser/exchange", body: [
            "code": code.code, "code_verifier": verifier, "request_id": UUID().uuidString.lowercased(),
        ])
        try Task.checkCancellation()
        guard generation == current, !disabled else { throw APIError.unauthorized }
        try persist(result, expectedAccount: nil)
        return result.user
    }

    private func randomToken(_ count: Int) throws -> String {
        var random = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw APIError.invalidResponse }
        return base64url(Data(random))
    }

    public func restore() async throws -> User? {
        guard !disabled, try tokens.load(scope: scope) != nil else { return nil }
        let current = generation
        _ = try await refresh()
        guard generation == current, !disabled else { throw APIError.unauthorized }
        struct Envelope: Decodable, Sendable { let user: User }
        let result = try await request(Envelope.self, path: "/api/auth/desktop/me")
        guard generation == current, !disabled else { throw APIError.unauthorized }
        return result.user
    }

    func request<T: Decodable & Sendable>(_ type: T.Type, path: String) async throws -> T {
        let transport = self.transport
        guard let lifetime = ReadCache.lifetime(path: path, query: [:]) else {
            return try await authorized { access in try await transport.send(type, path: path, body: nil, access: access) }
        }
        return try await cachedRead(key: "send:" + path, lifetime: lifetime) {
            try await self.authorized { access in try await transport.send(type, path: path, body: nil, access: access) }
        }
    }

    /// 未登录时的公开接口（匿名反馈、交流群链接）：不带凭据直接发，不刷新会话。
    public func anonymousRequest(path: String, method: String, body: JSONValue?) async throws -> JSONValue {
        guard FeedbackRequest.allowed(path: path, method: method) else { throw APIError.invalidResponse }
        return try await transport.career(path: path, method: method, query: [:], body: body, access: nil)
    }

    public func careerRequest(path: String, method: String, query: [String: String], body: JSONValue?) async throws -> JSONValue {
        guard CareerRequest.allowed(path: path, method: method) else { throw APIError.invalidResponse }
        let transport = self.transport
        guard method == "GET" else {
            // 写请求前后都作废受影响的读（规则见 `ReadCache.affected`）：之前读到的可能已经过时，路上的读也不再写回。
            purgeCache(afterWriteTo: path)
            defer { purgeCache(afterWriteTo: path) }
            return try await authorized { access in try await transport.career(path: path, method: method, query: query, body: body, access: access) }
        }
        let key = ReadCache.key(path: path, query: query)
        let validates = ReadCache.validates(path: path, query: query)
        guard let lifetime = ReadCache.lifetime(path: path, query: query) else {
            if validates { return try await validatedRead(key: key, path: path) }
            return try await authorized { access in try await transport.career(path: path, method: method, query: query, body: body, access: access) }
        }
        if lifetime == ReadCache.forever, readCache[key] == nil, let saved = ReadCache.readDisk(key) {
            readCache[key] = (saved, .distantFuture)
        }
        let value: JSONValue = try await cachedRead(key: key, lifetime: lifetime) {
            if validates { return try await self.validatedRead(key: key, path: path) }
            return try await self.authorized { access in try await transport.career(path: path, method: method, query: query, body: body, access: access) }
        }
        if lifetime == ReadCache.forever { ReadCache.writeDisk(key, value) }
        return value
    }

    /// 带 ETag 的读：手里有上一份时带 `If-None-Match`，304 就复用上一份。
    private func validatedRead(key: String, path: String) async throws -> JSONValue {
        let transport = self.transport, current = generation
        let saved = validators[key]
        let result = try await authorized { access in try await transport.validated(path: path, query: [:], etag: saved?.etag, access: access) }
        guard current == generation else { throw APIError.unauthorized }
        guard let value = result.value else {
            guard let saved else { throw APIError.invalidResponse }
            return saved.value
        }
        validators[key] = result.etag.map { ($0, value) }
        return value
    }

    /// 作废用户数据的读缓存（长期缓存的 logo 和配置类不受影响）。窗口回到前台、后台任务落定、上传与 AI 对话时调用。
    public func purgeCache() {
        cacheEpoch += 1
        readCache = readCache.filter { $0.value.expires == .distantFuture || ReadCache.configPaths.contains(Self.readPath($0.key)) }
        readFlights = [:]
    }

    /// 只作废某个写请求影响到的读。
    func purgeCache(afterWriteTo path: String) {
        cacheEpoch += 1
        readCache = readCache.filter { !ReadCache.affected(byWriteTo: path, key: $0.key) }
        readFlights = readFlights.filter { !ReadCache.affected(byWriteTo: path, key: $0.key) }
    }

    private static func readPath(_ key: String) -> String {
        key.hasPrefix("send:") ? String(key.dropFirst(5)) : String(key.split(separator: "?", maxSplits: 1).first ?? "")
    }

    private func cachedRead<T: Sendable>(key: String, lifetime: TimeInterval, _ load: @escaping @Sendable () async throws -> T) async throws -> T {
        if let hit = readCache[key], hit.expires > Date(), let value = hit.value as? T { return value }
        let epoch = cacheEpoch
        let task: Task<any Sendable, Error>
        if let flight = readFlights[key], flight.epoch == epoch { task = flight.task }
        else { task = Task { () async throws -> any Sendable in try await load() }; readFlights[key] = (epoch, task) }
        do {
            let value = try await SharedRead.value(of: task)
            if readFlights[key]?.task == task { readFlights[key] = nil }
            guard let typed = value as? T else { throw APIError.invalidResponse }
            if epoch == cacheEpoch {
                readCache[key] = (typed, lifetime == ReadCache.forever ? .distantFuture : Date().addingTimeInterval(lifetime))
            }
            return typed
        } catch {
            // 只有请求本身失败才丢掉这次合并；调用方自己被取消时，请求照常跑完留给其他人。
            if !(error is CancellationError), readFlights[key]?.task == task { readFlights[key] = nil }
            throw error
        }
    }

    private func dropAccountCaches() {
        cacheEpoch += 1
        readCache = [:]
        readFlights = [:]
        validators = [:]
        images.removeAll()
        imageDisk?.removeAll()
    }

    public func uploadAgentAttachment(_ upload: AgentAttachmentUpload) async throws -> JSONValue {
        let transport = self.transport
        purgeCache(); defer { purgeCache() }
        return try await authorized { access in try await transport.uploadAgentAttachment(upload, access: access) }
    }

    public func uploadDataset(_ upload: DatasetUpload) async throws -> JSONValue {
        let transport = self.transport
        purgeCache(afterWriteTo: "/api/datasets"); defer { purgeCache(afterWriteTo: "/api/datasets") }
        return try await authorized { access in try await transport.uploadDataset(upload, access: access) }
    }
    /// 带进度的资料上传（Web `uploadDataset` / `replaceDataset` / `uploadInterviewAsset`）：超过 4 MiB 走公共上传通道，
    /// 同时发 3 片、断了按服务端记录补缺片；小文件仍是一次 multipart。取消或遇到重试也不会好的错误时通知服务端丢掉已传的分片。
    public func uploadDataset(_ upload: DatasetUpload, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> JSONValue {
        let size = Int64(try upload.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard PieceUpload.chunked(size: size) else {
            let result = try await uploadDataset(upload); progress(size, size); return result
        }
        guard size <= upload.limit else { throw APIError.invalidResponse }
        purgeCache(afterWriteTo: "/api/datasets"); defer { purgeCache(afterWriteTo: "/api/datasets") }
        let started = try await startPieceUpload(try PieceUploadStart.from(upload, size: size), key: upload.id)
        do {
            let state = try await PieceSender.send(CoordinatorPieces(coordinator: self), id: started.id, file: upload.file, size: size,
                                                   events: PieceEvents(progress: progress))
            guard let result = state.result else { throw APIError.invalidResponse }
            return result
        } catch {
            if PieceUpload.cancelled(error) || PieceUpload.isFinal(error) {
                Task { try? await self.cancelPieceUpload(started.id) }
            }
            throw error
        }
    }
    public func startPieceUpload(_ start: PieceUploadStart, key: String) async throws -> PieceUploadState {
        let transport = self.transport
        return try await authorized { access in try await transport.startPieceUpload(start, key: key, access: access) }
    }
    public func pieceUploadState(_ id: String) async throws -> PieceUploadState {
        let transport = self.transport
        return try await authorized { access in try await transport.pieceUploadState(id, access: access) }
    }
    public func putPiece(_ id: String, index: Int, data: Data, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let transport = self.transport
        try await authorized { access in try await transport.putPiece(id, index: index, data: data, access: access, progress: progress) }
    }
    public func completePieceUpload(_ id: String) async throws -> PieceUploadState {
        let transport = self.transport
        purgeCache(afterWriteTo: "/api/datasets"); defer { purgeCache(afterWriteTo: "/api/datasets") }
        return try await authorized { access in try await transport.completePieceUpload(id, access: access) }
    }
    public func cancelPieceUpload(_ id: String) async throws {
        let transport = self.transport
        try await authorized { access in try await transport.cancelPieceUpload(id, access: access) }
    }
    public func downloadDataset(id: String, limit: Int64) async throws -> DatasetFile {
        let directory = try DatasetUpload.privateDirectory(), target = directory.appendingPathComponent("source")
        let transport = self.transport
        do { try await authorized { access in try await transport.downloadDataset(id:id, to:target, limit:limit, access:access) }; return DatasetFile(url:target,directory:directory) }
        catch { try? FileManager.default.removeItem(at:directory); throw error }
    }

    /// 本人简历列表；generation 拒绝退出或切换账号后的迟到结果。
    public func listResumes() async throws -> [ResumeSummary] { try await listResumePage().resumes }

    /// 简历列表与默认简历（`default_resume_id`，旧接口没有时为 nil）。
    public func listResumePage() async throws -> (resumes: [ResumeSummary], defaultID: String?) {
        struct Envelope: Decodable, Sendable { let resumes: [ResumeSummary]; let default_resume_id: String? }
        let current = generation
        // 与其他页面共用 `/api/resumes` 的读缓存和 ETag。
        let value = try await careerRequest(path: "/api/resumes", method: "GET", query: [:], body: nil)
        guard current == generation, !disabled else { throw APIError.unauthorized }
        let result = try JSONDecoder().decode(Envelope.self, from: JSONEncoder().encode(value))
        return (result.resumes, result.default_resume_id)
    }

    /// 单份 PDF 最多 20 MiB，只保存在内存，由界面写到用户选择的位置。
    public func downloadResumePDF(id: String, lockVersion: Int) async throws -> Data {
        let transport = self.transport, current = generation
        let data = try await authorized { access in try await transport.downloadResumePDF(id: id, lockVersion: lockVersion, limit: 20 * 1024 * 1024, access: access) }
        guard current == generation, !disabled else { throw APIError.unauthorized }
        return data
    }

    /// 本人头像（`/api/assets/users/{本人}/assets/avatar/...`），只接受当前账号路径与 PNG/JPEG，最多 4 MiB，同一路径在内存里复用。
    public func accountAvatar(path: String) async throws -> Data {
        guard !disabled, let account = try tokens.load(scope: scope)?.accountID else { throw APIError.unauthorized }
        let checked = try PaperAssets.path(path, account: account)
        guard checked.hasPrefix("/api/assets/users/\(account)/assets/") else { throw APIError.invalidResponse }
        let current = generation
        let image = try await self.image(path: checked, limit: 4 * 1024 * 1024)
        guard current == generation, !disabled else { throw APIError.unauthorized }
        return image.data
    }

    /// 可编辑纸面里的简历图片（`/api/resumes/{id}/assets/...` 与本人 `/api/assets/users/{本人}/...`）：
    /// 与纸面预览同一路径白名单，只接受 PNG/JPEG，单张最多 10 MiB，同一路径在内存里复用。
    public func resumeImage(path: String) async throws -> (data: Data, contentType: String) {
        guard !disabled, let account = try tokens.load(scope: scope)?.accountID else { throw APIError.unauthorized }
        let checked = try PaperAssets.path(path, account: account)
        let current = generation
        let image = try await self.image(path: checked, limit: PaperAssets.maximumBytes)
        guard current == generation, !disabled else { throw APIError.unauthorized }
        _ = try PaperAssets.dataURL(image, limit: PaperAssets.maximumBytes)
        return (image.data, image.contentType)
    }

    public func mockAudio(path: String, method: String, body: JSONValue?) async throws -> Data {
        let transport = self.transport
        return try await authorized { access in try await transport.mockAudio(path: path, method: method, body: body, access: access) }
    }

    /// 打开识别 WebSocket 前先确保 access 有效；握手失败（4401）由界面按登录失效处理。
    public func speechSocket(interviewID: String, questionID: String, purpose: String, local: Bool) async throws -> URLSessionWebSocketTask {
        let transport = self.transport
        var query = questionID.isEmpty ? ["purpose": purpose] : ["question_id": questionID, "purpose": purpose]
        if local { query["recognizer"] = "local" }
        return try await authorized { [query] access in
            try transport.speechSocket(path: "/api/mock-interviews/\(interviewID)/speech", query: query, access: access)
        }
    }

    /// 单栏、有文字层的 PDF 先在本机取出文字只传 `.txt`，服务端省掉文件转换与 OCR；
    /// 服务端还不认 `.txt`（415 `UNSUPPORTED_IMPORT_FORMAT`）时本次退回原文件，本进程之后都直接传原文件。
    public func importResume(_ upload: ResumeImportUpload) async throws -> JSONValue {
        let transport = self.transport
        purgeCache(); defer { purgeCache() }
        if !textImportUnsupported, let text = upload.textVariant() {
            do { return try await authorized { access in try await transport.importResume(text, access: access) } }
            catch APIError.server(415, _) { textImportUnsupported = true }
            let original = upload.withIdempotencyKey(ResumeText.fallbackKey(upload.idempotencyKey))
            return try await authorized { access in try await transport.importResume(original, access: access) }
        }
        return try await authorized { access in try await transport.importResume(upload, access: access) }
    }

    /// 实时事件流（`GET /api/events`）：连着时逐个回调事件，正常结束（令牌到期、服务端重启）时返回，由调用方重连。
    /// 401 不按登录失效处理（服务端可能还没对桌面开放这个接口），只抛给调用方退避；其他接口的登录状态不受影响。
    public func streamEvents(onEvent: @escaping @Sendable (UserEvent) async -> Void) async throws {
        guard !disabled else { throw APIError.unauthorized }
        let current = generation
        if access == nil || accessDeadline <= Date() { _ = try await refresh() }
        guard generation == current, !disabled else { throw APIError.unauthorized }
        let transport = self.transport, sent = access
        do { try await transport.events(access: sent, onEvent: onEvent) }
        catch APIError.unauthorized { throw APIError.server(status: 401, code: "EVENTS_UNAUTHORIZED") }
        guard generation == current, !disabled else { throw APIError.unauthorized }
    }

    /// AI 助手 SSE。只在开始响应前处理 401 续期；已开始的流不重放，避免重复提交消息（消息自带幂等键）。
    public func streamAgent(path: String, method: String, body: JSONValue?, onEvent: @MainActor @Sendable (AgentEvent) async -> Void) async throws {
        let transport = self.transport, current = generation
        // AI 对话可能经工具改简历、投递或面试：开始和结束都作废读缓存。
        purgeCache(); defer { purgeCache() }
        try await authorized { access in
            try await transport.streamAgent(path: path, method: method, body: body, access: access, onEvent: onEvent)
        }
        guard current == generation, !disabled else { throw APIError.unauthorized }
    }

    public func preparePaper(_ request: ResumeRenderRequest) async throws -> PaperPreparation {
        guard !disabled, let account = try tokens.load(scope: scope)?.accountID else { throw APIError.unauthorized }
        let current = generation
        let result = try await PaperAssets.prepare(request, account: account) { path, limit in
            try await self.image(path: path, limit: limit)
        }
        guard current == generation, !disabled else { throw APIError.unauthorized }
        return result
    }

    /// 图片路径带上传时间与随机串，同一路径内容不变：先查内存，再查本账号的磁盘缓存，都没有才下载；退出或换账号即清空。
    private func image(path: String, limit: Int) async throws -> DesktopImage {
        if let hit = images.get(path), hit.data.count <= limit { return hit }
        let account = (try? tokens.load(scope: scope))?.accountID
        if let account, let saved = imageDisk?.get(account: account, path: path), saved.data.count <= limit {
            images.put(path, saved)
            return saved
        }
        let transport = self.transport, current = generation
        let image = try await authorized { access in try await transport.downloadImage(path: path, limit: limit, access: access) }
        if current == generation {
            images.put(path, image)
            if let account, (try? tokens.load(scope: scope))?.accountID == account { imageDisk?.put(account: account, path: path, image: image) }
        }
        return image
    }

    private func authorized<T: Sendable>(_ send: @Sendable (String?) async throws -> T) async throws -> T {
        guard !disabled else { throw APIError.unauthorized }
        let current = generation
        if access == nil || accessDeadline <= Date() { _ = try await refresh() }
        guard generation == current, !disabled else { throw APIError.unauthorized }
        let sentAccess = access
        do {
            let result = try await send(sentAccess)
            guard generation == current, !disabled else { throw APIError.unauthorized }
            return result
        } catch APIError.unauthorized {
            guard generation == current, !disabled else { throw APIError.unauthorized }
            if access == sentAccess { _ = try await refresh() }
            guard generation == current, !disabled else { throw APIError.unauthorized }
            do {
                let result = try await send(access)
                guard generation == current, !disabled else { throw APIError.unauthorized }
                return result
            } catch APIError.unauthorized {
                if generation == current { try invalidate() }
                throw APIError.unauthorized
            }
        }
    }

    private func refresh() async throws -> DesktopTokens {
        guard !disabled, let saved = try tokens.load(scope: scope) else { throw APIError.unauthorized }
        let current = generation
        if flight == nil {
            let journal = saved.pending ?? RefreshJournal(requestID: UUID().uuidString, refreshToken: saved.refreshToken, startedAt: Date())
            guard Date().timeIntervalSince(journal.startedAt) < 120 else {
                try invalidate()
                throw APIError.unauthorized
            }
            try tokens.save(DesktopCredentialRecord(accountID: saved.accountID, refreshToken: saved.refreshToken,
                                                   generation: saved.generation, pending: journal), scope: scope)
            let id = UUID()
            flight = (id, Task {
                do {
                    let result = try await transport.send(DesktopTokens.self, path: "/api/auth/desktop/refresh", body: [
                        "refresh_token": journal.refreshToken, "request_id": journal.requestID,
                    ])
                    if generation == current, !disabled {
                        access = nil
                        try persist(result, expectedAccount: saved.accountID)
                    }
                    if flight?.id == id { flight = nil }
                    return result
                } catch {
                    if flight?.id == id { flight = nil }
                    if generation == current, case APIError.unauthorized = error { try invalidate() }
                    throw error
                }
            })
        }
        let shared = flight!
        let result = try await sharedTaskValue(shared.task)
        try Task.checkCancellation()
        guard generation == current, !disabled else { throw APIError.unauthorized }
        return result
    }

    private func persist(_ result: DesktopTokens, expectedAccount: String?) throws {
        guard result.session_protocol == 1, result.expires_in >= 0,
              !result.access_token.isEmpty, !result.refresh_token.isEmpty,
              expectedAccount == nil || expectedAccount == result.user.id else { throw APIError.invalidResponse }
        // 新登录（不是续期）：上一个账号留下的读缓存一律不用。
        if expectedAccount == nil { dropAccountCaches() }
        try tokens.save(DesktopCredentialRecord(accountID: result.user.id, refreshToken: result.refresh_token,
                                               generation: generation), scope: scope)
        access = result.access_token
        accessDeadline = Date().addingTimeInterval(TimeInterval(result.expires_in))
    }

    private func invalidate() throws {
        disabled = true
        generation = UUID()
        access = nil
        dropAccountCaches()
        flight = nil
        try tokens.clear(scope: scope)
    }

    public func signOut() async throws {
        try await signOut(generation: UUID())
    }

    private func signOut(generation nextGeneration: UUID) async throws {
        disabled = true
        generation = nextGeneration
        access = nil
        dropAccountCaches()
        let shared = flight
        flight = nil
        let pendingExchange = exchange
        exchange = nil
        let currentSaved = try tokens.load(scope: scope)
        if logoutRecovery == nil, currentSaved != nil || pendingExchange != nil {
            logoutRecovery = (UUID(), currentSaved, shared?.task, pendingExchange?.task)
        }
        var clearError: (any Error)?
        do { try tokens.clear(scope: scope) } catch { clearError = error }
        guard let recovery = logoutRecovery else {
            if let clearError { throw clearError }
            return
        }
        if logoutFlight == nil {
            logoutFlight = (UUID(), Task { try await revoke(recovery) })
        }
        let remote = logoutFlight!
        do { try await remote.task.value }
        catch {
            if logoutFlight?.id == remote.id { logoutFlight = nil }
            throw APIError.server(status: 503, code: "REMOTE_LOGOUT_UNCONFIRMED")
        }
        if logoutFlight?.id == remote.id { logoutFlight = nil }
        if let clearError { throw clearError }
        if logoutRecovery?.id == recovery.id { logoutRecovery = nil }
    }

    private func revoke(_ recovery: LogoutRecovery) async throws {
        let saved = recovery.saved
        var refresh = saved?.refreshToken ?? ""
        do {
            if let pendingExchange = recovery.exchange { refresh = try await pendingExchange.value.refresh_token }
            else if let shared = recovery.refresh {
                do { refresh = try await shared.value.refresh_token }
                catch {
                    guard let journal = saved?.pending else { throw error }
                    let recovered = try await transport.send(DesktopTokens.self, path: "/api/auth/desktop/refresh", body: [
                        "refresh_token": journal.refreshToken, "request_id": journal.requestID,
                    ])
                    refresh = recovered.refresh_token
                }
            }
            else if let journal = saved?.pending {
                let recovered = try await transport.send(DesktopTokens.self, path: "/api/auth/desktop/refresh", body: [
                    "refresh_token": journal.refreshToken, "request_id": journal.requestID,
                ])
                refresh = recovered.refresh_token
            }
            struct Result: Decodable, Sendable { let ok: Bool }
            let result = try await transport.send(Result.self, path: "/api/auth/desktop/logout", body: ["refresh_token": refresh])
            guard result.ok else { throw APIError.invalidResponse }
        } catch {
            throw APIError.server(status: 503, code: "REMOTE_LOGOUT_UNCONFIRMED")
        }
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// 等合并的读请求：调用方被取消时立即返回 `CancellationError`，共享的请求不受影响、继续给其他等待者。
private enum SharedRead {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<any Sendable, Error>?
        private var finished = false
        func set(_ next: CheckedContinuation<any Sendable, Error>) -> Bool {
            lock.withLock { if finished { return false }; continuation = next; return true }
        }
        func finish(_ result: Result<any Sendable, Error>) {
            let waiting: CheckedContinuation<any Sendable, Error>? = lock.withLock {
                guard !finished else { return nil }
                finished = true
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(with: result)
        }
    }

    static func value(of task: Task<any Sendable, Error>) async throws -> any Sendable {
        let once = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard once.set(continuation) else { continuation.resume(throwing: CancellationError()); return }
                Task { do { once.finish(.success(try await task.value)) } catch { once.finish(.failure(error)) } }
            }
        } onCancel: { once.finish(.failure(CancellationError())) }
    }
}

/// 分片发送时每个请求都回到会话协调器，拿当前的访问令牌。
private struct CoordinatorPieces: PieceTransport {
    let coordinator: SessionCoordinator
    func state(_ id: String) async throws -> PieceUploadState { try await coordinator.pieceUploadState(id) }
    func put(_ id: String, index: Int, data: Data, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await coordinator.putPiece(id, index: index, data: data, progress: progress)
    }
    func complete(_ id: String) async throws -> PieceUploadState { try await coordinator.completePieceUpload(id) }
}
