import Foundation

/// App 注入真实 HTTP 客户端；Mock 仅用于离线测试。
public protocol APIClient: Sendable {
    func uploadDataset(_ upload: DatasetUpload) async throws -> JSONValue
    func downloadDataset(id: String, limit: Int64) async throws -> DatasetFile
    func careerRequest(path: String, method: String, query: [String: String], body: JSONValue?) async throws -> JSONValue
    func currentUser() async throws -> User?
    func signIn(email: String, password: String) async throws -> User
    func signOut() async throws
    func preparePaper(_ request: ResumeRenderRequest) async throws -> PaperPreparation
    func listResumeTemplates() async throws -> [ResumeTemplate]
    func listResumes() async throws -> [ResumeSummary]
    func downloadResumePDF(id: String, lockVersion: Int) async throws -> Data
    func streamAgent(path: String, method: String, body: JSONValue?, onEvent: @MainActor @Sendable (AgentEvent) async -> Void) async throws
    func importResume(_ upload: ResumeImportUpload) async throws -> JSONValue
    func accountAvatar(path: String) async throws -> Data
    func resumeImage(path: String) async throws -> (data: Data, contentType: String)
    func mockAudio(path: String, method: String, body: JSONValue?) async throws -> Data
    func speechSocket(interviewID: String, questionID: String, purpose: String, local: Bool) async throws -> URLSessionWebSocketTask
    /// 作废可变读缓存：窗口回到前台、轮询刷新前调用，确保读到服务端最新状态。
    func purgeCache() async
    /// 实时事件流；服务端没有启用时抛 404。
    func streamEvents(onEvent: @escaping @Sendable (UserEvent) async -> Void) async throws
}

public enum APIError: Error, Equatable {
    case unauthorized
    case server(status: Int, code: String)
    case invalidResponse
}

/// 离线 mock：客户端不携带模板，登录后模板列表为空，真实目录只来自 `GET /api/resume-templates`。
/// 需后端：登录目前不校验密码，任意邮箱都能进。
public actor MockAPIClient: APIClient {
    private var user: User?

    public init(signedIn: Bool = false) {
        user = signedIn ? MockAPIClient.previewUser : nil
    }

    public static let previewUser = User(id: "1", email: "v3-preview@example.com", nickname: "预览用户", isAdmin: false)

    public func currentUser() async throws -> User? { user }

    public func signIn(email: String, password: String) async throws -> User {
        guard !email.isEmpty, !password.isEmpty else { throw APIError.server(status: 400, code: "INVALID_CREDENTIALS") }
        let signedIn = User(id: "1", email: email, nickname: email.split(separator: "@").first.map(String.init) ?? "用户", isAdmin: false)
        user = signedIn
        return signedIn
    }

    public func signOut() async throws { user = nil }

    public func listResumeTemplates() async throws -> [ResumeTemplate] {
        guard user != nil else { throw APIError.unauthorized }
        return []
    }
}


extension APIClient {
    public func purgeCache() async {}
    public func streamEvents(onEvent: @escaping @Sendable (UserEvent) async -> Void) async throws { throw APIError.server(status: 404, code: "NOT_FOUND") }
    public func uploadDataset(_ upload: DatasetUpload) async throws -> JSONValue { throw APIError.unauthorized }
    public func downloadDataset(id: String, limit: Int64) async throws -> DatasetFile { throw APIError.unauthorized }
    public func careerRequest(path: String, method: String = "GET", query: [String: String] = [:], body: JSONValue? = nil) async throws -> JSONValue { throw APIError.unauthorized }
    public func listResumes() async throws -> [ResumeSummary] { throw APIError.unauthorized }
    public func downloadResumePDF(id: String, lockVersion: Int) async throws -> Data { throw APIError.unauthorized }
    public func streamAgent(path: String, method: String, body: JSONValue?, onEvent: @MainActor @Sendable (AgentEvent) async -> Void) async throws { throw APIError.unauthorized }
    public func importResume(_ upload: ResumeImportUpload) async throws -> JSONValue { throw APIError.unauthorized }
    public func accountAvatar(path: String) async throws -> Data { throw APIError.unauthorized }
    public func resumeImage(path: String) async throws -> (data: Data, contentType: String) { throw APIError.unauthorized }
    public func mockAudio(path: String, method: String, body: JSONValue?) async throws -> Data { throw APIError.unauthorized }
    public func speechSocket(interviewID: String, questionID: String, purpose: String, local: Bool) async throws -> URLSessionWebSocketTask { throw APIError.unauthorized }
    public func preparePaper(_ request: ResumeRenderRequest) async throws -> PaperPreparation {
        try await PaperAssets.prepare(request, account: "") { _, _ in throw APIError.invalidResponse }
    }
}

/// `GET /api/events` 的一条事件：`ready` 表示刚连上或期间可能丢了事件（全部重读），`change` 是某个后台任务状态变了。
public enum UserEvent: Sendable, Equatable {
    case ready
    case change(topic: String, ref: String?)
}
