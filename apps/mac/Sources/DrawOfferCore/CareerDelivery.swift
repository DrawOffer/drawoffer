import Foundation

/// 记录投递（Web `progress/RecordAppliedDialog.tsx`）：待投递只走这一步；看板拖到测评、笔试、面试列时，
/// 投递和进入那一步是同一次保存，标题、进展胶囊和按钮都写成目标那一步。
public enum CareerRecordApplied {
    public enum Step: Equatable, Sendable {
        case screening
        /// `assessment`、`written_test`、`ai_interview`。
        case written(String)
        case interview
    }

    /// 「现在到哪一步」的选项，顺序同 Web（筛选中、测评、笔试、AI 面试、面试）。
    public static let steps: [(Step, String)] = [
        (.screening, "筛选中"), (.written("assessment"), "测评"), (.written("written_test"), "笔试"), (.written("ai_interview"), "AI 面试"), (.interview, "面试"),
    ]
    /// 投递渠道的常见选项，记录投递与补充投递信息共用（Web `CHANNELS`）。
    public static let channels = ["招聘官网", "同事内推", "校园招聘", "BOSS 直聘", "猎聘", "拉勾", "牛客", "实习僧", "邮件投递", "其他"]

    /// 从看板拖到某一列时换算成预选（Web `stepFromColumn`）；「面试中」是没有轮次名称时的兜底列，记为一面。
    public static func preset(stage: String, label: String) -> (step: Step, interviewLabel: String) {
        switch stage {
        case "assessment", "written_test", "ai_interview": return (.written(stage), "一面")
        case "hr": return (.interview, "HR 面")
        case "interview":
            let name = label.trimmingCharacters(in: .whitespaces)
            return (.interview, name.isEmpty || name == "面试中" ? "一面" : name)
        default: return (.screening, "一面")
        }
    }

    /// 目标那一步的名字；只记投递（进入筛选中）时为 nil。
    public static func target(_ step: Step, interviewLabel: String) -> String? {
        switch step {
        case .screening: return nil
        case .written(let type): return steps.first { $0.0 == .written(type) }?.1 ?? "笔试"
        case .interview: return interviewLabel
        }
    }

    public static func submitLabel(_ target: String?) -> String { target.map { "记录投递并进入\($0)" } ?? "记录投递" }
    public static func footHint(_ target: String?) -> String { target.map { "先记下投递，再进入\($0)；排期在详情页「安排时间」" } ?? "之后的排期在详情页「安排时间」" }

    /// 有简历可选时必须绑定一份；一份简历都没有时仍可先记下投递。
    public static func resumeMissing(selected: String?, resumeCount: Int) -> Bool {
        (selected ?? "").isEmpty && resumeCount > 0
    }

    /// 投递日期只到天：按北京时间当天中午写，避免跨时区显示成前一天。
    public static func appliedAt(_ day: Date) -> Date {
        Beijing.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    /// `POST /api/job-applications/{id}/stages` 的请求体（不含 `client_request_id`、`base_lock_version`）。
    public static func stageBody(step: Step, interviewLabel: String, roundNo: Int?, appliedOn: Date?, channel: String, resumeID: String?) -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        switch step {
        case .screening: body["stage_type"] = .string("screening")
        case .written(let type): body["stage_type"] = .string(type)
        case .interview:
            body["stage_type"] = .string("interview")
            body["stage_label"] = .string(interviewLabel)
            body["interview_round_no"] = .number(Double(roundNo ?? 1))
        }
        if let appliedOn { body["applied_at"] = .string(ISO8601DateFormatter().string(from: appliedAt(appliedOn))) }
        if let value = channel.trimmingCharacters(in: .whitespaces).nonEmptyValue { body["applied_channel"] = .string(value) }
        if let resumeID, !resumeID.isEmpty { body["resume_id"] = .string(resumeID) }
        return body
    }
}

/// 结束时刻（Web `EndClockInput`，Figma 07 · 13.02）：从开始往后每 15 分钟一档，共 8 小时，后面写时长；选了换算回时长。
public enum CareerTimeSpan {
    public struct Option: Equatable, Sendable {
        public let minutes: Int
        public let clock: String
        public let span: String
    }

    /// `startMinute` 是开始时刻在一天里的分钟数；没选开始时按 10:00 算。现有时长不在档位上时也列出来。
    public static func options(startMinute: Int?, current: Int) -> [Option] {
        let base = startMinute ?? 10 * 60
        var offsets = (1...32).map { $0 * 15 }
        if current > 0 && !offsets.contains(current) { offsets.append(current); offsets.sort() }
        return offsets.map { offset in
            let total = (base + offset) % (24 * 60)
            return Option(minutes: offset, clock: String(format: "%02d:%02d", total / 60, total % 60), span: label(offset))
        }
    }

    /// 「45 分钟」「1.5 小时」「1.25 小时」。
    public static func label(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = (Double(minutes) / 60 * 100).rounded() / 100
        return hours == hours.rounded() ? "\(Int(hours)) 小时" : "\(hours) 小时"
    }
}

/// 往投递详情拖文件（Web `ProgressDeckPage` onDrop）：资料放进正在看的那一轮，没有就放当前这一轮；
/// 录音那几步只收录音和视频，其余文件交给资料页按格式和大小逐个校验。
public enum CareerDropRule {
    /// Web `DEFAULT_DATASET_LIMITS`：录音视频 500MB，文档 10MB。
    public static let media = ["webm", "m4a", "mp3", "wav", "ogg", "mp4", "mov"]
    public static let documents = ["pdf", "docx", "md", "txt"]
    public static let recordingOnlyNotice = "这里只放录音或视频。文字稿可以粘贴文字，PDF、Word 从右上角 ⋯ 的「资料」上传。"

    public static func isMedia(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return media.contains(name[name.index(after: dot)...].lowercased())
    }

    public static func recordingOnly(_ figure: CareerJourneyFigure) -> Bool { [.recordEmpty, .recordRunning, .recordFailed].contains(figure) }

    /// 留下能交给资料页的文件；录音那几步挡掉非录音时带上提示。
    public static func accept(_ names: [String], figure: CareerJourneyFigure) -> (kept: [Int], notice: String?) {
        guard recordingOnly(figure) else { return (Array(names.indices), nil) }
        let kept = names.indices.filter { isMedia(names[$0]) }
        return (kept, kept.count < names.count ? recordingOnlyNotice : nil)
    }
}
