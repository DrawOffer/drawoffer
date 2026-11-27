import CoreText
import Foundation
import Testing
@testable import DrawOfferCore

private final class FixedTokens: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: DesktopCredentialRecord? = DesktopCredentialRecord(accountID: "1", refreshToken: "fixture-session.secret", generation: UUID())
    func load(scope: String) throws -> DesktopCredentialRecord? { lock.withLock { saved } }
    func save(_ record: DesktopCredentialRecord, scope: String) throws { lock.withLock { saved = record } }
    func clear(scope: String) throws { lock.withLock { saved = nil } }
}

/// 每次 career 调用都记一笔并返回递增的计数，用来判断是否真的发了请求。
private actor CountingTransport: DesktopRequesting {
    nonisolated let origin = URL(string: "https://api.example.test/")!
    private(set) var careerCalls: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var holding = false

    func hold() { holding = true }
    func release() { holding = false; gate?.resume(); gate = nil }

    func career(path: String, method: String, query: [String: String], body: JSONValue?, access: String?) async throws -> JSONValue {
        careerCalls.append(method + " " + path)
        if holding { await withCheckedContinuation { gate = $0 } }
        return .object(["n": .number(Double(careerCalls.count))])
    }

    /// 条件读：版本号 `revision` 不变时对带对 ETag 的请求回 304。
    private(set) var conditional: [String?] = []
    var revision = 1
    func bump() { revision += 1 }
    func validated(path: String, query: [String: String], etag: String?, access: String?) async throws -> (value: JSONValue?, etag: String?) {
        conditional.append(etag)
        let tag = "W/\"r\(revision)\""
        if etag == tag { return (nil, tag) }
        return (.object(["resumes": .array([]), "revision": .number(Double(revision))]), tag)
    }

    private(set) var imports: [(name: String, type: String, key: String)] = []
    var acceptsText = true
    func rejectText() { acceptsText = false }
    func importResume(_ upload: ResumeImportUpload, access: String?) async throws -> JSONValue {
        imports.append((upload.fileName, upload.contentType, upload.idempotencyKey))
        if upload.contentType == "text/plain" && !acceptsText { throw APIError.server(status: 415, code: "UNSUPPORTED_IMPORT_FORMAT") }
        return .object(["import": .object(["id": .string("7")])])
    }

    func events(access: String?, onEvent: @escaping @Sendable (UserEvent) async -> Void) async throws { throw APIError.unauthorized }

    private(set) var images: [String] = []
    func downloadImage(path: String, limit: Int, access: String?) async throws -> DesktopImage {
        images.append(path)
        return DesktopImage(data: Data([0x89, 0x50, 0x4E, 0x47]), contentType: "image/png")
    }

    func send<T: Decodable & Sendable>(_ type: T.Type, path: String, body: [String: String]?, access: String?) async throws -> T {
        let json = path == "/api/auth/desktop/refresh"
            ? #"{"user":{"id":"1","email":null,"nickname":"张三","is_admin":false},"access_token":"fixture-access","refresh_token":"fixture-session.next","expires_in":600,"session_protocol":1}"#
            : #"{"ok":true}"#
        return try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}

@Test func readCacheRulesKeepLiveStatusUncached() {
    #expect(ReadCache.lifetime(path: "/api/billing/feature-prices", query: [:]) == 600)
    #expect(ReadCache.lifetime(path: "/api/job-applications", query: ["scope": "all"]) == 60)
    #expect(ReadCache.lifetime(path: "/api/job-descriptions/7/logo", query: ["v": String(repeating: "a", count: 64)]) == ReadCache.forever)
    #expect(ReadCache.lifetime(path: "/api/job-descriptions/7/logo", query: ["v": "short"]) == nil)
    for pool in ["/api/job-pool", "/api/job-pool/count", "/api/job-pool/by-company", "/api/job-pool/filters", "/api/job-pool/companies/page"] {
        #expect(ReadCache.lifetime(path: pool, query: [:]) == 120)
    }
    // 单个岗位带「已加入」状态，不缓存。
    #expect(ReadCache.lifetime(path: "/api/job-pool/12", query: [:]) == nil)
    for live in ["/api/mock-interviews/3", "/api/datasets", "/api/billing/summary", "/api/notifications", "/api/interview-sessions/4", "/api/resume-overview"] {
        #expect(ReadCache.lifetime(path: live, query: [:]) == nil)
    }
    #expect(ReadCache.key(path: "/a", query: ["b": "2", "a": "1"]) == "/a?a=1&b=2")
    let floored = ReadCache.floor(Date(timeIntervalSince1970: 1_000_000 + 299), minutes: 5)
    #expect(floored.timeIntervalSince1970 == 1_000_200)
}

@Test func cachedReadsAreReusedUntilAWrite() async throws {
    let transport = CountingTransport()
    let coordinator = SessionCoordinator(transport: transport, tokens: FixedTokens())
    let first = try await coordinator.careerRequest(path: "/api/job-applications", method: "GET", query: ["scope": "all"], body: nil)
    let second = try await coordinator.careerRequest(path: "/api/job-applications", method: "GET", query: ["scope": "all"], body: nil)
    #expect(first == second)
    #expect(await transport.careerCalls.count == 1)
    // 不同参数分开缓存；不在规则里的接口每次都请求
    _ = try await coordinator.careerRequest(path: "/api/job-applications", method: "GET", query: ["scope": "active"], body: nil)
    _ = try await coordinator.careerRequest(path: "/api/interview-sessions/4", method: "GET", query: [:], body: nil)
    _ = try await coordinator.careerRequest(path: "/api/interview-sessions/4", method: "GET", query: [:], body: nil)
    #expect(await transport.careerCalls.count == 4)
    // 写请求之后重新读
    _ = try await coordinator.careerRequest(path: "/api/job-applications/9", method: "PUT", query: [:], body: .object([:]))
    let third = try await coordinator.careerRequest(path: "/api/job-applications", method: "GET", query: ["scope": "all"], body: nil)
    #expect(third != first)
    // 主动作废（回到前台、轮询）同样重新读
    await coordinator.purgeCache()
    _ = try await coordinator.careerRequest(path: "/api/job-applications", method: "GET", query: ["scope": "all"], body: nil)
    #expect(await transport.careerCalls.filter { $0 == "GET /api/job-applications" }.count == 4)
}

@Test func concurrentIdenticalReadsShareOneRequest() async throws {
    let transport = CountingTransport()
    await transport.hold()
    let coordinator = SessionCoordinator(transport: transport, tokens: FixedTokens())
    let reads = (0..<5).map { _ in Task { try await coordinator.careerRequest(path: "/api/interview-sessions", method: "GET", query: ["limit": "500"], body: nil) } }
    while await transport.careerCalls.isEmpty { await Task.yield() }
    try await Task.sleep(for: .milliseconds(50))
    await transport.release()
    var values: [JSONValue] = []
    for read in reads { values.append(try await read.value) }
    #expect(Set(values).count == 1)
    #expect(await transport.careerCalls.count == 1)
}

@Test func readStartedBeforeAWriteIsNotKept() async throws {
    let transport = CountingTransport()
    await transport.hold()
    let coordinator = SessionCoordinator(transport: transport, tokens: FixedTokens())
    let stale = Task { try await coordinator.careerRequest(path: "/api/job-applications", method: "GET", query: [:], body: nil) }
    while await transport.careerCalls.isEmpty { await Task.yield() }
    await coordinator.purgeCache()
    await transport.release()
    _ = try await stale.value
    _ = try await coordinator.careerRequest(path: "/api/job-applications", method: "GET", query: [:], body: nil)
    #expect(await transport.careerCalls.count == 2)
}

@Test func signOutDropsCachedReads() async throws {
    let transport = CountingTransport()
    let coordinator = SessionCoordinator(transport: transport, tokens: FixedTokens())
    _ = try await coordinator.careerRequest(path: "/api/account/user-profile", method: "GET", query: [:], body: nil)
    try await coordinator.signOut()
    await #expect(throws: APIError.self) {
        _ = try await coordinator.careerRequest(path: "/api/account/user-profile", method: "GET", query: [:], body: nil)
    }
    #expect(await transport.careerCalls.count == 1)
}

@Test func resumeReadsRevalidateWithETag() async throws {
    let transport = CountingTransport()
    let coordinator = SessionCoordinator(transport: transport, tokens: FixedTokens())
    let first = try await coordinator.careerRequest(path: "/api/resumes", method: "GET", query: [:], body: nil)
    await coordinator.purgeCache()
    // 没变：带上次的 ETag，回 304，拿到同一份
    let second = try await coordinator.careerRequest(path: "/api/resumes", method: "GET", query: [:], body: nil)
    #expect(second == first)
    // 变了：拿到新的一份
    await transport.bump()
    await coordinator.purgeCache()
    let third = try await coordinator.careerRequest(path: "/api/resumes", method: "GET", query: [:], body: nil)
    #expect(third["revision"]?.numberValue == 2)
    #expect(await transport.conditional == [nil, "W/\"r1\"", "W/\"r1\""])
    // 单份简历不进 60 秒缓存，但同样带 ETag
    _ = try await coordinator.careerRequest(path: "/api/resumes/12", method: "GET", query: [:], body: nil)
    _ = try await coordinator.careerRequest(path: "/api/resumes/12", method: "GET", query: [:], body: nil)
    #expect(await transport.conditional.suffix(2) == [nil, "W/\"r2\""])
    #expect(ReadCache.validates(path: "/api/resumes/12/guide", query: [:]) == false)
    #expect(ReadCache.validates(path: "/api/resumes", query: ["limit": "1"]) == false)
    // 岗位广场筛选项同样带 ETag；带查询参数的岗位列表不带
    #expect(ReadCache.validates(path: "/api/job-pool/filters", query: [:]))
    #expect(ReadCache.validates(path: "/api/job-pool", query: [:]) == false)
}

@Test func writesOnlyDropTheReadsTheyAffect() async throws {
    #expect(ReadCache.affected(byWriteTo: "/api/account/preferences", key: "/api/account/preferences"))
    #expect(!ReadCache.affected(byWriteTo: "/api/account/preferences", key: "/api/job-applications?scope=all"))
    #expect(!ReadCache.affected(byWriteTo: "/api/datasets/3", key: "/api/resumes"))
    #expect(ReadCache.affected(byWriteTo: "/api/datasets/3", key: "/api/datasets/folders"))
    #expect(!ReadCache.affected(byWriteTo: "/api/mock-interviews/5/answers", key: "/api/interview-sessions"))
    #expect(!ReadCache.affected(byWriteTo: "/api/job-applications/9", key: "/api/billing/feature-prices"))
    #expect(!ReadCache.affected(byWriteTo: "/api/job-applications/9", key: "send:/api/resume-templates"))
    #expect(ReadCache.affected(byWriteTo: "/api/job-applications/9", key: "/api/interview-sessions?limit=500"))

    let transport = CountingTransport()
    let coordinator = SessionCoordinator(transport: transport, tokens: FixedTokens())
    _ = try await coordinator.careerRequest(path: "/api/job-applications", method: "GET", query: [:], body: nil)
    _ = try await coordinator.careerRequest(path: "/api/billing/feature-prices", method: "GET", query: [:], body: nil)
    _ = try await coordinator.careerRequest(path: "/api/account/preferences", method: "PATCH", query: [:], body: .object([:]))
    _ = try await coordinator.careerRequest(path: "/api/job-applications", method: "GET", query: [:], body: nil)
    // 回到前台的整体作废也留着配置类
    await coordinator.purgeCache()
    _ = try await coordinator.careerRequest(path: "/api/billing/feature-prices", method: "GET", query: [:], body: nil)
    #expect(await transport.careerCalls == ["GET /api/job-applications", "GET /api/billing/feature-prices", "PATCH /api/account/preferences"])
}

@Test func imagesSurviveRestartUntilSignOut() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("drawoffer-images-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = ImageDiskCache(root: root)
    let transport = CountingTransport()
    let first = SessionCoordinator(transport: transport, tokens: FixedTokens(), imageDisk: disk)
    _ = try await first.accountAvatar(path: "/api/assets/users/1/assets/avatar/a.png")
    // 新进程（新的会话层）直接读磁盘，不再下载
    let restarted = SessionCoordinator(transport: transport, tokens: FixedTokens(), imageDisk: disk)
    _ = try await restarted.accountAvatar(path: "/api/assets/users/1/assets/avatar/a.png")
    #expect(await transport.images.count == 1)
    try await restarted.signOut()
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func structuredJobTextParsesLocally() {
    let text = """
    【职位】后端开发工程师
    公司名称：示例科技有限公司
    工作地点：杭州
    薪资：25-40K·15薪
    学历要求：本科及以上
    岗位职责：
    1. 负责交易系统
    """
    let fields = JobDraftParser.parse(text)
    #expect(fields?["job_title"] == "后端开发工程师")
    #expect(fields?["company_name"] == "示例科技有限公司")
    #expect(fields?["work_city"] == "杭州")
    #expect(fields?["salary_text"] == "25-40K·15薪")
    #expect(fields?["education_requirement"] == "本科及以上")
    #expect(fields?["description"]?.hasPrefix("【职位】") == true)
    #expect(fields?["job_title"] != "职责：")
    // 没有标注的自由文本交给 AI
    #expect(JobDraftParser.parse("我们正在招一名后端工程师，地点在杭州，欢迎投递") == nil)
    #expect(JobDraftParser.parse("职位：后端工程师\n岗位职责：写代码") == nil)
    #expect(JobDraftParser.field("工作地点：杭州市西湖区文三路 100 号")?.1 == "杭州市西湖区文三路 100 号")
}

/// 一页单栏、有文字层的 PDF（Core Text 画字），用来验证本机取字。
private func samplePDF(lines: [String], x: CGFloat = 56) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 11, nil)
    for (index, text) in lines.enumerated() {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: index % 2 == 1 && x > 100 ? x : 56, y: 800 - CGFloat(index) * 18)
        CTLineDraw(line, context)
    }
    context.endPDFPage(); context.closePDF()
    return data as Data
}

private let sampleLines = (1...24).map { "第 \($0) 行：负责示例系统的接口设计与性能优化，带领三人小组完成迁移。" }

@Test func singleColumnPDFTextIsExtractedLocally() throws {
    let text = try #require(ResumeText.extract(pdf: samplePDF(lines: sampleLines)))
    #expect(text.contains("第 1 行"))
    #expect(text.contains("第 24 行"))
    // 一半的行从页面右半边起笔：当作双栏，交给服务端
    #expect(ResumeText.extract(pdf: samplePDF(lines: sampleLines, x: 320)) == nil)
    // 文字太少（扫描件、图片简历）
    #expect(ResumeText.extract(pdf: samplePDF(lines: ["张三", "后端工程师"])) == nil)
    #expect(ResumeText.extract(pdf: Data("not a pdf".utf8)) == nil)
    #expect(!ResumeText.readable(String(repeating: "\u{E001}", count: 300)))
    let key = ResumeText.fallbackKey("0f8fad5b-d9cb-469f-a165-70867728950e")
    #expect(key == ResumeText.fallbackKey("0f8fad5b-d9cb-469f-a165-70867728950e"))
    #expect(UUID(uuidString: key)?.uuidString.lowercased() == key)
}

@Test func textImportFallsBackToTheOriginalFileOnOlderServers() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drawoffer-import-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("示例简历.pdf")
    try samplePDF(lines: sampleLines).write(to: file)
    let upload = try ResumeImportUpload(file: file, templateID: "3")

    let transport = CountingTransport()
    let coordinator = SessionCoordinator(transport: transport, tokens: FixedTokens())
    _ = try await coordinator.importResume(upload)
    var imports = await transport.imports
    #expect(imports.map(\.name) == ["示例简历.txt"])
    #expect(imports.first?.type == "text/plain")
    #expect(imports.first?.key == upload.idempotencyKey)

    // 服务端还不认 .txt：这次退回原文件（派生的幂等键），之后直接传原文件
    await transport.rejectText()
    let older = SessionCoordinator(transport: transport, tokens: FixedTokens())
    _ = try await older.importResume(upload)
    _ = try await older.importResume(upload)
    imports = Array(await transport.imports.dropFirst())
    #expect(imports.map(\.type) == ["text/plain", "application/pdf", "application/pdf"])
    #expect(imports[1].key == ResumeText.fallbackKey(upload.idempotencyKey))
    #expect(imports[2].key == upload.idempotencyKey)
}

@Test func eventStreamUnauthorizedDoesNotSignOut() async throws {
    let transport = CountingTransport()
    let coordinator = SessionCoordinator(transport: transport, tokens: FixedTokens())
    await #expect(throws: APIError.server(status: 401, code: "EVENTS_UNAUTHORIZED")) { try await coordinator.streamEvents { _ in } }
    // 其他接口照常可用
    _ = try await coordinator.careerRequest(path: "/api/job-applications", method: "GET", query: [:], body: nil)
    #expect(await transport.careerCalls == ["GET /api/job-applications"])
}
