import Foundation
import Testing
@testable import DrawOfferCore

@Test func mockTemplatesRequireSignIn() async throws {
    let api = MockAPIClient()
    await #expect(throws: APIError.unauthorized) { try await api.listResumeTemplates() }
}

/// 客户端不再随包携带模板；测试直接读仓库里的共享样例。
private func fixtureTemplates() throws -> [ResumeTemplate] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../native/shared/fixtures/resume-templates.json").standardizedFileURL
    struct Envelope: Decodable { let templates: [ResumeTemplate] }
    return try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url)).templates
}

@Test func fixtureTemplatesCarryLayoutPlans() throws {
    let templates = try fixtureTemplates()
    #expect(templates.count == 9)
    #expect(templates.allSatisfy { $0.layoutPlan != nil })
}

@Test func renderRequestMatchesWebPresentationRule() async throws {
    let template = try #require(try fixtureTemplates().first)
    let encoded = try JSONEncoder().encode(template.renderRequest())
    let request = try JSONDecoder().decode(JSONValue.self, from: encoded)
    #expect(request["protocol_version"] == .number(1))
    #expect(request["style"]?["schema_version"]?.stringValue == "resume-presentation.v1")
    #expect(request["style"]?["template_scoped"]?[template.key] == .object([:]))
    #expect(request["style"]?["template_snapshot"] == template.style)
}

@MainActor
@Test func sessionRestoreAndSignOut() async {
    let session = SessionStore(api: MockAPIClient(signedIn: true))
    await session.restore()
    #expect(session.phase == .signedIn(MockAPIClient.previewUser))
    await session.signOut()
    #expect(session.phase == .signedOut)
}

private actor DelayedIdentityAPI: APIClient {
    private var result: CheckedContinuation<User?, any Error>?
    private var entered: CheckedContinuation<Void, Never>?

    func currentUser() async throws -> User? {
        try await withCheckedThrowingContinuation {
            result = $0
            entered?.resume()
            entered = nil
        }
    }
    func waitForRestore() async {
        if result != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func finishRestore(failure: Bool) {
        if failure { result?.resume(throwing: APIError.unauthorized) }
        else { result?.resume(returning: MockAPIClient.previewUser) }
        result = nil
    }
    func signIn(email: String, password: String) async throws -> User { MockAPIClient.previewUser }
    func signOut() async throws {}
    func listResumeTemplates() async throws -> [ResumeTemplate] { [] }
}

@MainActor
@Test(arguments: [false, true]) func sessionIgnoresRestoreAfterSignOut(failure: Bool) async {
    let api = DelayedIdentityAPI()
    let session = SessionStore(api: api)
    let restore = Task { await session.restore() }
    await api.waitForRestore()
    await session.signOut()
    await api.finishRestore(failure: failure)
    await restore.value
    #expect(session.phase == .signedOut)
    #expect(session.errorMessage == nil)
}

@Test func navigationMatchesWebOrder() {
    #expect(WorkspaceSection.sidebar.map(\.title) == ["首页", "我的简历", "简历模板", "投递看板", "面试日程", "模拟面试", "岗位广场", "资料库"])
}

@Test func guestCannotListTemplates() async throws {
    let api = MockAPIClient()
    await #expect(throws: APIError.unauthorized) { try await api.listResumeTemplates() }
    #expect(try await api.currentUser() == nil)
}

@Test func parityAllowlistMatchesBackendDesktopRoutes() {
    #expect(CareerRequest.allowed(path: "/api/memory/home", method: "GET"))
    #expect(CareerRequest.allowed(path: "/api/memory/home/disclosures", method: "POST"))
    #expect(CareerRequest.allowed(path: "/api/announcements/read-all", method: "POST"))
    #expect(CareerRequest.allowed(path: "/api/billing/summary", method: "GET"))
    // Clearing memory and sharing grants stay Web-only.
    #expect(!CareerRequest.allowed(path: "/api/memory/clear", method: "POST"))
    #expect(!CareerRequest.allowed(path: "/api/memory/grants", method: "GET"))
    #expect(!CareerRequest.allowed(path: "/api/billing/summary", method: "POST"))
    #expect(CareerRequest.allowed(path: "/api/job-pool/companies/12", method: "GET"))
    #expect(CareerRequest.allowed(path: "/api/job-pool/34/join", method: "POST"))
    #expect(!CareerRequest.allowed(path: "/api/admin/job-pool/sources", method: "GET"))
    #expect(!CareerRequest.allowed(path: "/api/job-pool/abc", method: "GET"))
}

/// 模板卡片与预览：没有头像、显示系统默认头像的模板换成示例证件照，散列与 Web `templateSamplePhoto` 一致；隐藏头像的模板不动。
@Test func templatePreviewUsesWebSamplePhoto() throws {
    #expect(ResumeTemplate.samplePhoto("classic-tech") == "/templates/sample-photo-male.jpg")
    #expect(ResumeTemplate.samplePhoto("swiss-orange") == "/templates/sample-photo-female.jpg")
    let templates = try fixtureTemplates()
    let campus = try #require(templates.first { $0.key == "featured-campus-cn" })
    let avatar = campus.previewRequest().data["identity"]?["avatar"]
    #expect(avatar?["src"]?.stringValue == ResumeTemplate.samplePhoto("featured-campus-cn"))
    #expect(avatar?["system_fallback"] == .bool(false))
    let hidden = try #require(templates.first { $0.key == "muse-code-cn" })
    #expect(hidden.previewRequest().data["identity"]?["avatar"] == hidden.renderRequest().data["identity"]?["avatar"])
}
