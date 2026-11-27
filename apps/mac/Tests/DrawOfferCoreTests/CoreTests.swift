import Foundation
import Testing
@testable import DrawOfferCore

@Test func mockTemplatesRequireSignIn() async throws {
    let api = MockAPIClient()
    await #expect(throws: APIError.unauthorized) { try await api.listResumeTemplates() }
}

@Test func mockTemplatesAreEmptyAfterSignIn() async throws {
    // 客户端不携带模板，真实目录只来自后端
    #expect(try await MockAPIClient(signedIn: true).listResumeTemplates().isEmpty)
}

/// 只是 `GET /api/resume-templates` 的结构样例（字段照后端 ResumeTemplateRecord），不是可见模板。
private func shapeTemplate(key: String, avatar: String) throws -> ResumeTemplate {
    let json = """
    {"id":"7","key":"\(key)","name":"结构样例","description":null,"style_categories":["现代"],"use_cases":["校招"],
     "data":{"schema_version":"canonical-resume.v1","identity":{"name":{"value":"张三"},"avatar":null},"sections":[]},
     "style":{"schema_version":"template-definition.v1","template_key":"\(key)",
              "avatar":{"visibility":"\(avatar)","fallback_asset":"system-default"}},
     "layout_plan":{"schema_version":"layout-plan.v1"},"switchable":true,"incompatibility_reason":null,"use_count":3}
    """
    return try JSONDecoder().decode(ResumeTemplate.self, from: Data(json.utf8))
}

@Test func templateRecordDecodesBackendShape() throws {
    let template = try shapeTemplate(key: "shape-sample-cn", avatar: "show")
    #expect(template.useCount == 3)
    #expect(template.styleCategories == ["现代"] && template.useCases == ["校招"])
    #expect(template.layoutPlan != nil)
}

@Test func renderRequestMatchesWebPresentationRule() async throws {
    let template = try shapeTemplate(key: "shape-sample-cn", avatar: "show")
    let encoded = try JSONEncoder().encode(template.renderRequest())
    let request = try JSONDecoder().decode(JSONValue.self, from: encoded)
    #expect(request["protocol_version"] == .number(1))
    #expect(request["style"]?["schema_version"]?.stringValue == "resume-presentation.v1")
    #expect(request["style"]?["template_scoped"]?[template.key] == .object([:]))
    #expect(request["style"]?["template_snapshot"] == template.style)
    #expect(request["layout_plan"] == template.layoutPlan)
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
    #expect(CareerRequest.allowed(path: "/api/job-pool/count", method: "GET"))
    #expect(CareerRequest.allowed(path: "/api/job-pool/by-company", method: "GET"))
}

/// 模板卡片与预览：没有头像、显示系统默认头像的模板换成示例证件照，散列与 Web `templateSamplePhoto` 一致；隐藏头像的模板不动。
@Test func templatePreviewUsesWebSamplePhoto() throws {
    #expect(ResumeTemplate.samplePhoto("classic-tech") == "/templates/sample-photo-male.jpg")
    #expect(ResumeTemplate.samplePhoto("swiss-orange") == "/templates/sample-photo-female.jpg")
    let shown = try shapeTemplate(key: "featured-campus-cn", avatar: "show")
    let avatar = shown.previewRequest().data["identity"]?["avatar"]
    #expect(avatar?["src"]?.stringValue == ResumeTemplate.samplePhoto("featured-campus-cn"))
    #expect(avatar?["system_fallback"] == .bool(false))
    let hidden = try shapeTemplate(key: "muse-code-cn", avatar: "hide")
    #expect(hidden.previewRequest().data["identity"]?["avatar"] == hidden.renderRequest().data["identity"]?["avatar"])
}
