import Foundation

/// 导入面试记录的后台处理（Web `features/mock-interview/v2/backgroundRecordImports.ts` 与 `RecordImportBell.tsx`）：
/// 导入弹窗建好记录后把文字或文档交给后台就关，上传（不转写）→ 等解析 → 拆题 → 保存问题 → 生成复盘都在后台做，进度和失败都在侧栏铃铛里；
/// 录音传完后（后台上传）也交到这里等转写：转写在服务端跑，这里只盯着，转好了自动提交复盘。这里是不依赖界面的状态、判断与文案。
public struct RecordImport: Identifiable, Sendable, Equatable {
    public enum Step: String, Sendable { case uploading, reading, structuring, transcribing, reviewing }
    public enum Status: String, Sendable { case working, failed }

    public var id: String
    public var sessionID: String
    /// 铃铛里显示的公司名（场次标题或投递的公司）。
    public var company: String
    public var status: Status = .working
    public var step: Step
    /// 这一步从什么时候开始，用来估进度。
    public var since: Date
    /// 上传文档时的进度（0–99）。
    public var uploaded = 0
    public var error: String? = nil
    /// 失败后能否点重试（读不出文字、没找到问题这类重试也没用）。
    public var retryable = false

    public init(id: String, sessionID: String, company: String, step: Step, since: Date = Date()) {
        self.id = id; self.sessionID = sessionID; self.company = company; self.step = step; self.since = since
    }

    public var working: Bool { status == .working }

    /// Web `patch`：换了步骤或变成失败时重新计时。
    public mutating func move(to step: Step, now: Date = Date()) {
        self.step = step; status = .working; error = nil; since = now
    }
    public mutating func fail(_ text: String, retryable: Bool, now: Date = Date()) {
        status = .failed; error = text; self.retryable = retryable; since = now
    }

    /// 拆题没有进度，按已过时间估：约 25 秒到 63%；录音转写约 3 分钟到 63%。
    static let pace = 25.0, transcribePace = 180.0

    /// Web `importProgress`：导入只是这件事的前一小段，进度到 15%，后面交给复盘。
    public func progress(now: Date) -> Double {
        let elapsed = max(0, now.timeIntervalSince(since))
        switch step {
        case .uploading: return Double(uploaded) / 100 * 0.05
        case .reviewing: return 0.15
        case .transcribing: return 0.14 * (1 - exp(-elapsed / Self.transcribePace))
        case .reading, .structuring:
            let from = step == .reading ? 0.05 : 0.07, to = step == .reading ? 0.07 : 0.14
            return from + (to - from) * (1 - exp(-elapsed / Self.pace))
        }
    }

    /// 进度行：「正在导入「公司」面试记录」+ 这一步在做什么。
    public var runningTitle: String { "正在导入「\(company)」面试记录" }
    public var stepText: String {
        switch step {
        case .uploading: return "正在上传文件 \(uploaded)% · 可以先去做别的"
        case .reading: return "正在读取文件里的文字 · 可以先去做别的"
        case .structuring: return "正在整理面试问题 · 整理完自动复盘"
        case .transcribing: return "正在转写录音 · 转好自动复盘 · 可以先去做别的"
        case .reviewing: return "整理好了，正在开始复盘"
        }
    }
    /// 没导入完的条目（Web `FailedRow`）。
    public var failedTitle: String { "\(company)的面试记录没导入完" }

    public static func ago(_ since: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(since)) / 60)
        if minutes < 1 { return "刚刚" }
        return minutes < 60 ? "\(minutes) 分钟前" : "\(minutes / 60) 小时前"
    }
}

/// 等转写的一份录音（Web `RecordingJob`，本地记 `drawoffer.recordingReviews.v1`）。
/// `base` 是盯上时这场复盘的开始时间：变了说明别处已经开始复盘，不再提交一次。`baseSet` 为 false 表示还没看过（Web 的 `undefined`）。
public struct RecordingJob: Codable, Sendable, Equatable {
    public var id: String
    public var sessionID: String
    public var applicationID: String
    public var datasetID: String
    public var title: String
    public var replace: Bool
    public var since: Double
    public var baseSet = false
    public var base: String? = nil

    public init(id: String = UUID().uuidString.lowercased(), sessionID: String, applicationID: String, datasetID: String, title: String, replace: Bool,
                since: Date = Date()) {
        self.id = id; self.sessionID = sessionID; self.applicationID = applicationID; self.datasetID = datasetID
        self.title = title; self.replace = replace; self.since = since.timeIntervalSince1970
    }

    public var valid: Bool { !id.isEmpty && DatasetRequest.id(sessionID) && DatasetRequest.id(datasetID) }

    public static func key(account: String) -> String { "drawoffer.recordingReviews.v1." + account }
    public static func decode(_ data: Data?) -> [RecordingJob] {
        guard let data, let list = try? JSONDecoder().decode([RecordingJob].self, from: data) else { return [] }
        return list.filter(\.valid)
    }
}

public enum RecordImportFlow {
    /// 文档解析最多看 30 次、每次隔 2 秒（Web `PARSE_ATTEMPTS` / `PARSE_WAIT_MS`）。
    public static let parseAttempts = 30
    public static let parseWait: Duration = .seconds(2)
    /// 等转写每 15 秒看一次（Web `RECORDING_POLL_MS`）；服务端说面试有变化时提前看。
    public static let recordingPoll: Duration = .seconds(15)

    /// 读不出文字（解析失败或一直没解析完）。
    public struct Unreadable: Error, Equatable { public init() {} }

    public enum Parse: Equatable { case succeeded, failed, pending }
    /// `GET /api/datasets/{id}` 的 `parse_status`（兼容外面包一层 `dataset`）。
    public static func parse(_ dataset: JSONValue) -> Parse {
        let status = dataset["dataset"]?.text("parse_status").nonEmptyValue ?? dataset.text("parse_status")
        return status == "succeeded" ? .succeeded : status == "failed" ? .failed : .pending
    }

    /// Web `failure()`：导入失败的文案与能否重试。
    public static func failure(_ error: Error) -> (text: String, retryable: Bool) {
        if error is Unreadable { return ("这个文件读不出文字，换一份再导入。", false) }
        if case APIError.server(_, let code) = error {
            if code == "INTERVIEW_QUESTIONS_NOT_FOUND" { return ("没找到面试问题，换一份文字稿再导入。", false) }
            if code == "INTERVIEW_REVIEW_IN_PROGRESS" { return ("另一场面试正在复盘，等它好了再点重试。", true) }
            if let credit = creditText(code) { return (credit, true) }
        }
        return ("网络或服务暂时不稳，稍后点重试。", true)
    }

    /// Web `creditErrorMessage`：402 积分不够、403 当前额度不能用（桌面端拿不到 `reason`，按「这项功能」说）。
    public static func creditText(_ code: String) -> String? {
        if code == "CREDIT_INSUFFICIENT" { return "积分已用完，本次 AI 请求没有发出。" }
        if code == "PAID_CREDIT_REQUIRED" { return "当前额度不能使用这项功能。" }
        return nil
    }

    /// 看一眼录音的下一步（Web `checkRecording` 里拿到场次之后的判断）。
    public enum RecordingStep: Equatable {
        /// 收起这一条：复盘已在别处开始、转写被取消、或这场原本就没有记录可复盘。
        case dismiss
        /// 让服务端重新转写（`transcriptions/{id}:retry`），之后接着盯。
        case retranscribe
        case fail(String, retryable: Bool)
        /// 还没转好，下次再看。
        case wait
        /// 转好了：`apply` 为 true 时先用转写替换原有记录，再按 `version` 提交复盘。
        case review(apply: Bool, version: Double)
    }

    /// 第一次看时记下复盘开始时间作基线（Web `job.base === undefined`）；返回 true 表示要存一下名单。
    public static func setBase(_ job: inout RecordingJob, session: JSONValue) -> Bool {
        guard !job.baseSet else { return false }
        job.baseSet = true; job.base = session.text("review_started_at").nonEmptyValue
        return true
    }

    /// `session` 是 `GET /api/interview-sessions/{id}` 里的 `session`；`again` 是用户点了重试。调用前先 `setBase`。
    public static func recordingStep(_ session: JSONValue, job: RecordingJob, again: Bool) -> RecordingStep {
        let started = session.text("review_started_at").nonEmptyValue
        if session.text("review_status") == "generating" || started != job.base { return .dismiss }
        guard let transcription = (session["transcriptions"]?.items ?? []).first(where: { $0.display("dataset_id") == job.datasetID }) else {
            // 这场原来就有记录时，服务端不会自动转写新录音；用户确认过替换才转
            return job.replace ? .retranscribe : .fail("录音已经传好，但没有转写。到这场面试的资料里看看。", retryable: false)
        }
        switch transcription.text("status") {
        case "cancelled": return .dismiss
        case "failed": return again ? .retranscribe : .fail("录音没有转出文字，可以再试一次，或者改成粘贴文字导入。", retryable: true)
        case "succeeded": break
        default: return .wait
        }
        let version = session["lock_version"]?.numberValue ?? 1
        if transcription["pending_replace"]?.bool == true {
            return job.replace ? .review(apply: true, version: version) : .fail("这场已经有别的记录，没有替换。转写好的文字在这场面试的资料里。", retryable: false)
        }
        if session.text("questions_markdown").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .dismiss }
        return .review(apply: false, version: version)
    }

    public enum RecordingError: Equatable {
        /// 面试删了，或者换了账号。
        case dismiss
        case fail(String, retryable: Bool)
        /// 另一场正在复盘、刚被改过、网络断了：下次再看。
        case later
    }

    /// Web `checkRecording` 的 catch：哪些错误停下来显示失败，哪些下次再看。
    public static func recordingError(_ error: Error) -> RecordingError {
        guard case APIError.server(let status, let code) = error else { return .later }
        if status == 404 { return .dismiss }
        switch code {
        case "INTERVIEW_REVIEW_TEXT_TOO_LONG": return .fail("转写的文字太长，到这场面试里删减后再复盘。", retryable: false)
        case "INTERVIEW_TRANSCRIPTION_DISABLED": return .fail("录音已经传好，现在不能转写，可以改成粘贴文字导入。", retryable: false)
        case "INTERVIEW_INVALID_TRANSITION": return .fail("这条投递已归档，或这场面试还没结束，没有复盘。", retryable: true)
        default: break
        }
        if [400, 402, 403, 422].contains(status) {
            let (text, retryable) = failure(error)
            return .fail(text, retryable: retryable)
        }
        return .later
    }
}
