import Foundation

/// 模拟面试的提问路线、下一场与日期文案（Web `mock-interview/v2/pathModel.ts`、`homeModel.ts`）。
public enum MockMap {
    // MARK: 提问路线（pathModel）

    public struct Round: Sendable {
        public let main: JSONValue
        public let turns: [JSONValue]
        public let topic: String
        public let from: Double
        public let to: Double
        public let ok: Bool?
        public let skipped: Bool
        public let intro: Bool
    }

    static func depth(_ question: JSONValue) -> Double { question["depth_level"]?.numberValue ?? 0 }

    public static func isIntro(_ detail: JSONValue, _ question: JSONValue) -> Bool {
        detail["has_intro"]?.bool == true && question.text("kind") == "main" && (question["plan_index"]?.numberValue ?? -1) == 0
    }

    public static func rounds(_ detail: JSONValue) -> [Round] {
        let questions = detail["questions"]?.items ?? []
        let sequence = { (q: JSONValue) in q["sequence_no"]?.numberValue ?? 0 }
        let mains = questions.filter { $0.text("kind") == "main" }.sorted { sequence($0) < sequence($1) }
        return mains.map { main in
            let id = main.display("id")
            let turns = [main] + questions.filter { $0.display("parent_id") == id && !id.isEmpty }.sorted { sequence($0) < sequence($1) }
            let from = max(1, depth(main) == 0 ? 1 : depth(main))
            let deepest = turns.map { depth($0) == 0 ? from : depth($0) }.max() ?? from
            let evaluation = main["evaluation"]
            let hasEvaluation = evaluation != nil && evaluation != .null
            let skipped = main.text("answer_status") == "skipped"
            let pending = turns.contains { $0.text("answer_status") == "pending" }
            let achieved = evaluation?["achieved_depth"]?.numberValue ?? 0
            let reached = hasEvaluation ? max(1, achieved == 0 ? 1 : achieved) : deepest
            let probed = evaluation?["probed_depth"]?.numberValue ?? deepest
            let ok: Bool?
            if pending && !hasEvaluation && detail.text("status") == "in_progress" { ok = nil }
            else if skipped { ok = false }
            else if hasEvaluation { ok = evaluation?.text("depth_status") == "met" || reached >= probed }
            else { ok = turns.last?.text("answer_status") == "answered" }
            let topic = main.text("topic").isEmpty ? String(main.text("content").prefix(8)) : main.text("topic")
            let to = max(from, hasEvaluation ? max(reached, ok == true ? reached : probed) : deepest)
            return Round(main: main, turns: turns, topic: topic, from: from, to: to, ok: ok, skipped: skipped, intro: isIntro(detail, main))
        }
    }

    public struct Stats: Sendable { public let rounds: [Round]; public let follows: Int; public let answered: Int; public let minutes: Int? }

    public static func stats(_ detail: JSONValue) -> Stats {
        let rounds = rounds(detail).filter { !$0.intro }
        let follows = (detail["questions"]?.items ?? []).filter { $0.text("kind") == "follow_up" }.count
        let answered = rounds.filter { $0.main.text("answer_status") == "answered" }.count
        var minutes: Int? = nil
        if let start = CareerApplication.date(detail.text("started_at")), let end = CareerApplication.date(detail.text("finished_at")) {
            minutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
        }
        return Stats(rounds: rounds, follows: follows, answered: answered, minutes: minutes)
    }

    // MARK: 首页模型（homeModel）

    public static let diffLevel: [String: Double] = ["junior": 2, "intermediate": 3, "senior": 4]
    public static let diffName = ["junior": "初级", "intermediate": "中级", "senior": "高级"]
    public static let typeNames = ["technical": "专业面", "project_deep_dive": "项目深挖", "comprehensive": "综合面", "hr": "HR 面"]
    public static func typeName(_ item: JSONValue) -> String { item.text("type_label").nonEmptyValue ?? typeNames[item.text("interview_type")] ?? "综合面" }

    // MARK: 下一场

    public struct Target: Sendable {
        public enum Kind: Sendable { case interview, application, general }
        public let kind: Kind
        public let application: JSONValue?
        public let session: JSONValue?
        public init(kind: Kind, application: JSONValue?, session: JSONValue?) { self.kind = kind; self.application = application; self.session = session }
    }

    static func stageRank(_ application: JSONValue) -> Int {
        let order = ["screening", "assessment", "written_test", "ai_interview", "interview", "hr", "offer"]
        let type = application["current_stage"]?.text("stage_type").nonEmptyValue ?? application.text("current_stage_type")
        return max(0, order.firstIndex(of: type) ?? -1) * 10 + (application["current_round_no"]?.integer ?? 0)
    }

    public static func pickTarget(applications: [JSONValue], sessions: [JSONValue], now: Date, chosen: String?) -> Target {
        if chosen == "general" { return Target(kind: .general, application: nil, session: nil) }
        let date = { (value: String) in CareerApplication.date(value) ?? .distantPast }
        let active = applications.filter { $0.text("status") == "active" && ($0["archived_at"] ?? .null) == .null && $0.text("lifecycle_status") != "terminated" }
        let upcoming = sessions.filter { $0.text("status") == "scheduled" && date($0.text("end_at")) >= now }.sorted { date($0.text("start_at")) < date($1.text("start_at")) }
        if let chosen, let application = active.first(where: { $0.display("id") == chosen }) ?? applications.first(where: { $0.display("id") == chosen }) {
            let session = upcoming.first { $0.display("application_id") == application.display("id") }
            return Target(kind: session == nil ? .application : .interview, application: application, session: session)
        }
        if let session = upcoming.first(where: { item in active.contains { $0.display("id") == item.display("application_id") } }) {
            return Target(kind: .interview, application: active.first { $0.display("id") == session.display("application_id") }, session: session)
        }
        let ranked = active.filter { ($0["job_description_id"] ?? .null) != .null }.enumerated().sorted { a, b in
            let x = stageRank(a.element), y = stageRank(b.element)
            if x != y { return x > y }
            let u = a.element.text("updated_at"), v = b.element.text("updated_at")
            return u != v ? u > v : a.offset < b.offset
        }.map(\.element)
        if let first = ranked.first { return Target(kind: .application, application: first, session: nil) }
        return Target(kind: .general, application: nil, session: nil)
    }

    static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    public static func dayDiff(_ from: Date, _ to: Date, calendar: Calendar = Beijing.calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }

    public static func relativeDay(_ date: Date, now: Date, calendar: Calendar = Beijing.calendar) -> String {
        let diff = dayDiff(now, date, calendar: calendar)
        if diff == 0 { return calendar.component(.hour, from: date) >= 18 ? "今晚" : "今天" }
        if diff == 1 { return "明天" }
        if diff > 1 && diff < 7 { return weekdays[calendar.component(.weekday, from: date) - 1] }
        return "\(calendar.component(.month, from: date))·" + String(format: "%02d", calendar.component(.day, from: date))
    }

    public static func mmddDot(_ date: Date, calendar: Calendar = Beijing.calendar) -> String {
        String(format: "%02d·%02d", calendar.component(.month, from: date), calendar.component(.day, from: date))
    }
    public static func mmddDot(_ value: String) -> String { CareerApplication.date(value).map { mmddDot($0) } ?? "" }

    public static func companyName(_ target: Target) -> String {
        target.application?.text("company_name_snapshot").nonEmptyValue ?? target.session?.text("company_name") ?? ""
    }
}
