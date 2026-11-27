import AppKit
import DrawOfferCore
import Foundation

/// 导入面试记录（文字或文档）的后台处理（Web `features/mock-interview/v2/backgroundRecordImports.ts`）：弹窗建好记录后把内容交给这里就关，
/// 拆题（一次模型调用，长稿要半分钟以上）、保存和生成复盘都在后台做，进度和失败都在侧栏铃铛里；复盘一开始这一条就收起，复盘好了由后端发通知。
/// 文字和文档只在这次运行的内存里跑：退出 App 会中断，所以处理中退出先确认。
/// 录音传完后（`BackgroundUploads`）也交到这里等转写：转写在服务端跑，这里每 15 秒（或收到场次变化事件时）看一眼，转好了自动提交复盘；
/// 等转写的名单按账号记在本地，退出不影响转写，下次打开接着盯。
@MainActor @Observable
final class RecordImports {
    enum Source { case text(String), file(DatasetUpload) }

    private(set) var items: [RecordImport] = []
    /// 后台处理推进了一步（Web `notifyMockInterviews`）：模拟面试首页与记录页据此重读。
    private(set) var changed = 0
    @ObservationIgnored private var sources: [String: Source] = [:]
    /// 已经存好问题的记录，重试时直接从生成复盘开始，不再拆一遍题。
    @ObservationIgnored private var saved: Set<String> = []
    @ObservationIgnored private var recordings: [String: RecordingJob] = [:]
    @ObservationIgnored private var checking: Set<String> = []
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var account = ""
    @ObservationIgnored private var api: (any APIClient)?

    /// 退出前确认用（App 委托拿不到环境里的对象）。
    static weak var current: RecordImports?
    init() { Self.current = self }

    /// 文字、文档还在处理（录音在服务端转写，退出不影响）。
    var working: Bool { items.contains { $0.working && recordings[$0.id] == nil } }

    /// 登录、退出或换账号：停掉手上的处理，换成这个账号还在等转写的录音接着盯。
    func reset(account: String, api: any APIClient) {
        self.api = api
        guard account != self.account else { return }
        tasks.values.forEach { $0.cancel() }; tasks = [:]
        poller?.cancel(); poller = nil
        for case .file(let upload) in sources.values { upload.discard() }
        sources = [:]; saved = []; recordings = [:]; checking = []; items = []
        self.account = account
        guard !account.isEmpty else { return }
        for job in readRecordings() { watch(job) }
    }

    // MARK: 文字与文档

    /// 弹窗建好这场面试后调用（Web `startRecordImport`）：把文字或文档快照交给后台处理，调用后弹窗就可以关了。
    func start(session sessionID: String, company: String, source: Source) {
        let id = UUID().uuidString.lowercased()
        sources[id] = source
        if case .file = source { items.append(RecordImport(id: id, sessionID: sessionID, company: company, step: .uploading)) }
        else { items.append(RecordImport(id: id, sessionID: sessionID, company: company, step: .structuring)) }
        tasks[id] = Task { await run(id) }
    }

    func retry(_ id: String) {
        if sources[id] != nil { tasks[id]?.cancel(); tasks[id] = Task { await run(id) } }
        else if recordings[id] != nil {
            patch(id) { $0.move(to: .transcribing) }
            Task { await check(id, again: true) }
        }
    }

    /// 收起这一条：复盘已开始，或用户删掉没导入完的。
    func dismiss(_ id: String) {
        tasks.removeValue(forKey: id)?.cancel()
        if case .file(let upload) = sources.removeValue(forKey: id) { upload.discard() }
        saved.remove(id)
        if recordings.removeValue(forKey: id) != nil { saveRecording(id, nil) }
        items.removeAll { $0.id == id }
    }

    private func run(_ id: String) async {
        guard let api, let item = items.first(where: { $0.id == id }), let source = sources[id] else { return }
        let sessionID = item.sessionID, owner = account
        defer { if owner == account { changed += 1 } }
        do {
            if !saved.contains(id) {
                var input: JSONValue
                switch source {
                case .text(let text):
                    input = .object(["source": .string("text"), "text": .string(text)])
                case .file(let snapshot):
                    patch(id) { $0.move(to: .uploading); $0.uploaded = 0 }
                    // Web `uploadInterviewAsset(..., { transcribe: false })`：只当资料保存，等解析出文字再拆题
                    var upload = snapshot.rekey(); upload.transcribe = false
                    let result = try await api.uploadDataset(upload) { loaded, total in
                        Task { @MainActor [weak self] in
                            self?.patch(id) { if $0.step == .uploading, total > 0 { $0.uploaded = min(99, Int(Double(loaded) / Double(total) * 100)) } }
                        }
                    }
                    try Task.checkCancellation()
                    patch(id) { $0.move(to: .reading) }
                    let asset = result["asset"]?.display("id").nonEmptyValue ?? result.display("id")
                    guard DatasetRequest.id(asset), try await waitForParse(asset, api: api) else { throw RecordImportFlow.Unreadable() }
                    input = .object(["source": .string("dataset"), "dataset_id": .string(asset)])
                }
                patch(id) { $0.move(to: .structuring) }
                let draft = try await api.careerRequest(path: "/api/interview-sessions/\(sessionID)/record:structure", method: "POST", query: [:], body: input)
                let markdown = InterviewRecord.serialize(InterviewRecord.draft(draft))
                let before = try await api.careerRequest(path: "/api/interview-sessions/\(sessionID)", method: "GET", query: [:], body: nil)
                _ = try await api.careerRequest(path: "/api/interview-sessions/\(sessionID)", method: "PUT", query: [:],
                                                body: .object(["questions_markdown": markdown.isEmpty ? .null : .string(markdown),
                                                               "base_lock_version": before["session"]?["lock_version"] ?? .number(1)]))
                saved.insert(id)
            }
            try Task.checkCancellation()
            patch(id) { $0.move(to: .reviewing) }
            let current = try await api.careerRequest(path: "/api/interview-sessions/\(sessionID)", method: "GET", query: [:], body: nil)
            _ = try await api.careerRequest(path: "/api/interview-sessions/\(sessionID)/review:generate", method: "POST", query: [:],
                                            body: .object(["request_id": .string(UUID().uuidString.lowercased()),
                                                           "base_lock_version": current["session"]?["lock_version"] ?? .number(1)]))
            guard owner == account else { return }
            dismiss(id)
        } catch {
            if PieceUpload.cancelled(error) || Task.isCancelled || owner != account { return }
            let (text, retryable) = RecordImportFlow.failure(error)
            if !retryable, case .file(let upload) = sources.removeValue(forKey: id) { upload.discard() }
            tasks[id] = nil
            patch(id) { $0.fail(text, retryable: retryable) }
        }
    }

    /// Web `waitForParse`：最多看 30 次、隔 2 秒。
    private func waitForParse(_ id: String, api: any APIClient) async throws -> Bool {
        for _ in 0..<RecordImportFlow.parseAttempts {
            switch RecordImportFlow.parse(try await api.careerRequest(path: "/api/datasets/\(id)", method: "GET", query: [:], body: nil)) {
            case .succeeded: return true
            case .failed: return false
            case .pending: try await Task.sleep(for: RecordImportFlow.parseWait)
            }
        }
        return false
    }

    // MARK: 录音等转写

    /// 录音传完后调用（Web `startRecordingReview`）：盯着转写，转好自动复盘。
    func startRecordingReview(session sessionID: String, application applicationID: String, dataset datasetID: String, title: String, replace: Bool) {
        guard !account.isEmpty else { return }
        let job = RecordingJob(sessionID: sessionID, applicationID: applicationID, datasetID: datasetID, title: title, replace: replace)
        guard job.valid else { return }
        saveRecording(job.id, job)
        watch(job)
    }

    private func watch(_ job: RecordingJob) {
        recordings[job.id] = job
        items.append(RecordImport(id: job.id, sessionID: job.sessionID, company: job.title, step: .transcribing, since: Date(timeIntervalSince1970: job.since)))
        Task { await check(job.id) }
        schedule()
    }

    /// 还有在等转写的就保持一个轮询：每 15 秒，或收到场次变化事件（Web `useUserEvents("interview_session", checkRecordings)`）时看一眼。
    private func schedule() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                let mark = EventHub.shared.mark("interview_session", nil), start = Date()
                while !Task.isCancelled, Date().timeIntervalSince(start) < 15, EventHub.shared.mark("interview_session", nil) == mark {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard let self, !Task.isCancelled else { return }
                let waiting = items.filter { recordings[$0.id] != nil && $0.working }.map(\.id)
                if waiting.isEmpty { poller = nil; return }
                for id in waiting { await check(id) }
            }
        }
    }

    /// 看一眼这份录音转好没有：转好就提交复盘，没好下次再看。`again` 是用户点了重试。
    private func check(_ id: String, again: Bool = false) async {
        guard let api, var job = recordings[id], !checking.contains(id) else { return }
        let owner = account
        checking.insert(id)
        defer { checking.remove(id); if owner == account { schedule() } }
        do {
            let detail = try await api.careerRequest(path: "/api/interview-sessions/\(job.sessionID)", method: "GET", query: [:], body: nil)
            guard owner == account, recordings[id] != nil else { return }
            let session = detail["session"] ?? .null
            if RecordImportFlow.setBase(&job, session: session) { recordings[id] = job; saveRecording(id, job) }
            switch RecordImportFlow.recordingStep(session, job: job, again: again) {
            case .dismiss: dismiss(id)
            case .wait: break
            case .fail(let text, let retryable): patch(id) { $0.fail(text, retryable: retryable) }
            case .retranscribe:
                _ = try await api.careerRequest(path: "/api/interview-sessions/\(job.sessionID)/transcriptions/\(job.datasetID):retry", method: "POST", query: [:], body: nil)
            case .review(let apply, var version):
                if apply {
                    let applied = try await api.careerRequest(path: "/api/interview-sessions/\(job.sessionID)/transcriptions/\(job.datasetID):apply", method: "POST",
                                                              query: [:], body: .object(["base_lock_version": .number(version)]))
                    version = applied["session"]?["lock_version"]?.numberValue ?? version
                }
                patch(id) { $0.move(to: .reviewing) }
                _ = try await api.careerRequest(path: "/api/interview-sessions/\(job.sessionID)/review:generate", method: "POST", query: [:],
                                                body: .object(["request_id": .string(UUID().uuidString.lowercased()), "base_lock_version": .number(version)]))
                guard owner == account else { return }
                dismiss(id)
            }
        } catch {
            guard owner == account, recordings[id] != nil else { return }
            switch RecordImportFlow.recordingError(error) {
            case .dismiss: dismiss(id)
            case .fail(let text, let retryable): patch(id) { $0.fail(text, retryable: retryable) }
            case .later: patch(id) { if $0.step == .reviewing { $0.move(to: .transcribing) } }
            }
        }
    }

    private func patch(_ id: String, _ change: (inout RecordImport) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]; change(&item)
        if item != items[index] { items[index] = item }
    }

    private var recordingKey: String { RecordingJob.key(account: account) }
    private func readRecordings() -> [RecordingJob] { RecordingJob.decode(UserDefaults.standard.data(forKey: recordingKey)) }
    /// 每次都在本地最新的名单上改这一条。
    private func saveRecording(_ id: String, _ job: RecordingJob?) {
        guard !account.isEmpty else { return }
        let next = readRecordings().filter { $0.id != id } + (job.map { [$0] } ?? [])
        if next.isEmpty { UserDefaults.standard.removeObject(forKey: recordingKey) }
        else if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: recordingKey) }
    }
}
