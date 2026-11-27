import Foundation

/// 求职进度页的视图模型，对应 Web `features/interviews/progress/progressDeck.ts` 的 `buildDeck` / `buildLine`：
/// 投递是第 1 站，之后每个记录的阶段一站；左侧站点线的段长跟着每站用掉的天数。
public struct CareerStation: Identifiable, Sendable {
    public enum Kind: String, Sendable { case apply, screening, written, interview, oc, offer }
    public let id: String
    public let stage: JSONValue?
    public let kind: Kind
    /// 站点线上的短名：投递 / 筛选 / 笔试 / 一面 / OC …
    public let short: String
    public let title: String
    public let start: Date
    /// 离开这一站的时间；当前站为 nil。
    public let end: Date?
    public let session: JSONValue?
    public let current: Bool
    public let result: String
    /// 从 1 开始，显示为「第 N 站」。
    public let index: Int
}

public struct CareerDeckEnded: Sendable {
    public enum Kind: String, Sendable { case rejected, accepted, withdrew, declined, other }
    public let kind: Kind
    public let at: Date
}

public struct CareerDeck: Sendable {
    public let stations: [CareerStation]
    public let pending: Bool
    public let ended: CareerDeckEnded?
    public let stageState: String
    public let days: Int
    public let daysLabel: String
    public let reviews: Int
    public let sessions: [JSONValue]

    public var current: CareerStation? { stations.first { $0.current } }
}

public enum CareerDeckFormat {
    public static func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
    public static func monthDay(_ date: Date?, calendar: Calendar = Beijing.calendar) -> String {
        guard let date else { return "—" }
        let parts = calendar.dateComponents([.month, .day], from: date)
        return two(parts.month ?? 0) + "." + two(parts.day ?? 0)
    }
    public static func clock(_ date: Date, calendar: Calendar = Beijing.calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return two(parts.hour ?? 0) + ":" + two(parts.minute ?? 0)
    }
    public static func weekday(_ date: Date, calendar: Calendar = Beijing.calendar) -> String {
        "周" + ["日", "一", "二", "三", "四", "五", "六"][(calendar.component(.weekday, from: date) - 1) % 7]
    }
    public static func dayCount(_ from: Date, _ to: Date, calendar: Calendar = Beijing.calendar) -> Int {
        max(0, CareerFormat.days(from: from, to: to, calendar: calendar))
    }
}

extension CareerDeck {
    static func kind(_ stage: JSONValue) -> CareerStation.Kind {
        switch stage.text("stage_type") {
        case "screening": return .screening
        case "written_test", "assessment": return .written
        case "oc": return .oc
        case "offer": return .offer
        default: return .interview
        }
    }

    static func short(_ stage: JSONValue) -> String {
        switch stage.text("stage_type") {
        case "screening": return "筛选"
        case "written_test": return "笔试"
        case "assessment": return "测评"
        case "ai_interview": return "AI 面试"
        case "hr": return "HR 面"
        case "oc": return "OC"
        case "offer": return "Offer"
        default:
            let label = stage.text("stage_label")
            let first = label.split(whereSeparator: { $0 == "·" || $0.isWhitespace }).first.map(String.init) ?? ""
            return first.isEmpty ? label : first
        }
    }

    static func title(_ stage: JSONValue, session: JSONValue?) -> String {
        let type = stage.text("stage_type")
        let label = stage.text("stage_label").trimmingCharacters(in: .whitespaces)
        switch type {
        case "screening": return "简历筛选"
        case "oc": return "OC · 口头意向"
        case "offer": return "Offer"
        case "written_test", "assessment":
            let base = type == "written_test" ? "笔试" : "测评"
            if !label.isEmpty && label != base { return label.contains(base) ? label : "\(base) · \(label)" }
            if session?.text("mode") == "onsite" { return "\(base) · 现场" }
            return type == "written_test" ? "笔试 · 在线笔试" : "测评 · 在线测评"
        default: return label.isEmpty ? short(stage) : label
        }
    }

    public static func hasReview(_ session: JSONValue?) -> Bool {
        guard let session else { return false }
        if session.text("review_status") == "ready" { return true }
        if let report = session["review_report"], report != .null { return true }
        return !session.text("review_summary").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func source(_ app: JSONValue) -> String? {
        let channel = app.text("applied_channel").trimmingCharacters(in: .whitespacesAndNewlines)
        if !channel.isEmpty { return channel }
        let snapshot = app["job_snapshot"] ?? .null
        let value = (snapshot.text("source_platform").isEmpty ? snapshot.text("source_channel") : snapshot.text("source_platform")).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 早于阶段历史的记录只保存当前阶段，按它补一站。
    static func legacyStage(_ app: JSONValue, ended: Bool) -> JSONValue {
        let column = CareerDetailModel.column(app)
        let currentType = app.text("current_stage_type")
        let type = currentType == "offer" ? "offer" : column == "written_test" ? "written_test" : column == "assessment" ? "assessment"
            : currentType == "screening" ? "screening" : currentType == "hr" ? "hr" : "interview"
        let label = app.text("current_stage_label").trimmingCharacters(in: .whitespaces)
        return .object([
            "id": .string("legacy-" + app.text("id")), "stage_type": .string(type),
            "stage_label": .string(label.isEmpty ? CareerBoard.stageLabel(app) : label),
            "sequence_no": .number(1), "stage_result": .string(app.text("status") == "rejected" ? "rejected" : "pending"),
            "current_marker": ended ? .null : .number(1),
            "entered_at": .string(app.text("applied_at").isEmpty ? app.text("updated_at") : app.text("applied_at")),
            "completed_at": ended ? .string(app.text("updated_at")) : .null, "updated_at": .string(app.text("updated_at")),
        ])
    }

    public init(application app: JSONValue, sessions all: [JSONValue], now: Date = Date()) {
        let date = { (field: String, fallback: String) -> Date in
            CareerApplication.date(app.text(field)) ?? CareerApplication.date(app.text(fallback)) ?? now
        }
        let pending = CareerDetailModel.column(app) == "pending"
        let terminated = app.text("lifecycle_status") == "terminated" || app.text("status") != "active"
        let accepted = app.text("offer_status") == "accepted"
        var ended: CareerDeckEnded?
        if terminated || accepted {
            let reason = app.text("termination_reason"), status = app.text("status")
            let kind: CareerDeckEnded.Kind = accepted ? .accepted
                : status == "rejected" || reason == "company_rejected" ? .rejected
                : app.text("offer_status") == "declined" || reason == "offer_declined" ? .declined
                : status == "withdrawn" || reason == "user_withdrew" ? .withdrew : .other
            ended = CareerDeckEnded(kind: kind, at: date("terminated_at", "updated_at"))
        }
        let appID = app.text("id")
        let sessions = all.filter { $0.text("application_id") == appID }
            .map { CareerSessions.withEffectiveStatus($0, now: now) }
            .sorted { (CareerApplication.date($0.text("start_at")) ?? .distantPast) < (CareerApplication.date($1.text("start_at")) ?? .distantPast) }
        let recorded = (app["stages"]?.items ?? []).sorted { ($0["sequence_no"]?.integer ?? 0) < ($1["sequence_no"]?.integer ?? 0) }
        let stages = !recorded.isEmpty || pending ? recorded : [Self.legacyStage(app, ended: ended != nil)]
        let currentID = app["current_stage"]?.text("id").nonEmptyValue ?? stages.first { $0["current_marker"]?.integer == 1 }?.text("id")

        let live = sessions.filter { $0.text("status") != "cancelled" }
        func session(for stage: JSONValue, current: Bool) -> JSONValue? {
            let label = stage.text("stage_label").trimmingCharacters(in: .whitespaces)
            return live.first { $0.text("application_stage_id") == stage.text("id") }
                ?? live.first { $0.text("application_stage_id").isEmpty && $0.text("stage_label").trimmingCharacters(in: .whitespaces) == label }
                ?? (current ? live.first { $0.text("application_stage_id").isEmpty && CareerSessions.matchesCurrentStage(app, $0) } : nil)
        }

        let applyStart = pending ? date("created_at", "created_at") : date("applied_at", "created_at")
        let firstEntered = stages.first.flatMap { CareerApplication.date($0.text("entered_at")) }
        var stations = [CareerStation(id: "apply", stage: nil, kind: .apply, short: "投递", title: "投递", start: applyStart,
                                      end: pending ? nil : firstEntered ?? ended?.at, session: nil, current: pending,
                                      result: pending ? "pending" : "passed", index: 1)]
        for (position, stage) in stages.enumerated() {
            let isCurrent = ended == nil && (currentID.map { stage.text("id") == $0 } ?? (position == stages.count - 1))
            let match = session(for: stage, current: isCurrent)
            let next = position + 1 < stages.count ? stages[position + 1] : nil
            let end: Date? = isCurrent ? nil
                : next.flatMap { CareerApplication.date($0.text("entered_at")) }
                ?? CareerApplication.date(stage.text("completed_at")) ?? ended?.at ?? CareerApplication.date(stage.text("updated_at"))
            stations.append(CareerStation(id: stage.text("id"), stage: stage, kind: Self.kind(stage), short: Self.short(stage),
                                          title: Self.title(stage, session: match), start: CareerApplication.date(stage.text("entered_at")) ?? now,
                                          end: end, session: match, current: isCurrent, result: stage.text("stage_result"), index: position + 2))
        }

        let current = stations.first { $0.current }
        let scheduled = current?.session?.text("status") == "scheduled"
        let elapsed = current?.session?.text("status") == "completed"
        let stageState = app.text("stage_state") == "scheduled" && !scheduled && elapsed ? "awaiting_result" : app.text("stage_state")
        let daysFrom = pending ? date("created_at", "created_at") : date("applied_at", "created_at")

        self.stations = stations
        self.pending = pending
        self.ended = ended
        self.stageState = stageState
        self.days = CareerDeckFormat.dayCount(daysFrom, ended?.at ?? now)
        self.daysLabel = pending ? "已导入" : ended != nil ? "共投递" : "已投递"
        self.reviews = sessions.filter { Self.hasReview($0) }.count
        self.sessions = sessions
    }
}

extension String {
    public var nonEmptyValue: String? { isEmpty ? nil : self }
}
