import Foundation

/// 全部面试记录与导入真实面试的纯逻辑，照 Web `v2/RecordsPage.tsx`、`v2/ImportDialog.tsx`。
public enum MockRecords {
    public static let lowScore = 60

    public static func rowTitle(_ record: JSONValue) -> String {
        record.text("kind") == "real" ? record.text("round").nonEmptyValue ?? record.text("title") : record.text("title")
    }

    /// 卡在哪一处：差一步的是“待追问”，没答到的是“待补齐”。
    public static func stuckLine(_ record: JSONValue) -> String? {
        guard let stuck = record["stuck"], stuck != .null else { return nil }
        let topic = stuck.text("topic")
        let outcome = (record["topics"]?.items ?? []).first { $0.text("name") == topic }?.text("outcome")
        return topic + (outcome == "one_short" ? "待追问" : "待补齐")
    }

    public static func rowSub(_ record: JSONValue) -> String {
        let type = record.text("type_label").nonEmptyValue ?? (record.text("kind") == "real" ? "技术面" : nil)
        let count = (record["question_count"]?.integer).flatMap { $0 > 0 ? "\($0) 题" : nil }
        let stuck = record["answered"]?.bool == false ? nil : stuckLine(record)
        return [MockHome.mmdd(record.text("at")), type, count, stuck].compactMap { $0 }.joined(separator: " · ")
    }

    /// 组头右边：一周内的标橙点“3 天后 · 二面 11-21”，更远的只写“二面 11-26”。
    public static func nextLabel(_ next: JSONValue?, now: Date = Date(), calendar: Calendar = Beijing.calendar) -> (soon: Bool, text: String)? {
        guard let next, next != .null, let at = CareerApplication.date(next.text("at")) else { return nil }
        let diff = MockMap.dayDiff(now, at, calendar: calendar)
        let day: String? = diff == 0 ? "今天" : diff == 1 ? "明天" : diff > 1 && diff <= 7 ? "\(diff) 天后" : nil
        return (day != nil, [day, "\(next.text("label")) \(MockHome.mmdd(next.text("at"), calendar: calendar))"].compactMap { $0 }.joined(separator: " · "))
    }

    /// 分组标题“公司 · 岗位”拆成公司和岗位。
    public static func splitTitle(_ title: String) -> (company: String, job: String?) {
        guard let range = title.range(of: " · ") else { return (title, nil) }
        return (String(title[..<range.lowerBound]), String(title[range.upperBound...]))
    }

    public struct Section: Equatable {
        public var key: String
        public var title: String
        public var next: JSONValue?
        public var rows: [JSONValue]
    }

    /// 按投递分组；没挂投递（或投递不在组里）的归“专项与通用练习”。filter：all / real / mock。
    public static func sections(_ overview: JSONValue, filter: String) -> [Section] {
        let rows = kept(overview).filter { filter == "all" || $0.text("kind") == filter }
        let groups = overview["groups"]?.items ?? []
        let known = Set(groups.map { $0.display("application_id") })
        var list = groups.map { group in
            Section(key: group.display("application_id"), title: group.text("title"), next: group["next"].flatMap { $0 == .null ? nil : $0 },
                    rows: rows.filter { $0.display("application_id") == group.display("application_id") })
        }.filter { !$0.rows.isEmpty }
        let rest = rows.filter { $0.display("application_id").isEmpty || !known.contains($0.display("application_id")) }
        if !rest.isEmpty { list.append(Section(key: "general", title: "专项与通用练习", next: nil, rows: rest)) }
        return list
    }

    public static func kept(_ overview: JSONValue) -> [JSONValue] { (overview["records"]?.items ?? []).filter { $0.text("status") != "abandoned" } }
    public static func abandoned(_ overview: JSONValue, filter: String) -> [JSONValue] {
        filter == "real" ? [] : (overview["records"]?.items ?? []).filter { $0.text("status") == "abandoned" }
    }
    public static func counts(_ overview: JSONValue) -> [String: Int] {
        let rows = kept(overview)
        return ["all": rows.count, "real": rows.filter { $0.text("kind") == "real" }.count, "mock": rows.filter { $0.text("kind") == "mock" }.count]
    }

    // MARK: 导入真实面试

    /// 挂到哪：已结束的一场，或已有投递下补一轮。
    public enum Target: Equatable {
        case session(JSONValue)
        case application(JSONValue)
        public var label: String {
            switch self {
            case .session(let s): "\(s.text("title")) · \(MockHome.mmdd(s.text("at"))) · 已结束"
            case .application(let a): "\(a.text("company_name")) · \(a.text("job_title"))"
            }
        }
        public var company: String {
            switch self {
            case .session(let s): s.text("title")
            case .application(let a): a.text("company_name")
            }
        }
    }

    /// 默认选中点进来的那一场，否则最近结束的一场，再没有就第一条投递。
    public static func defaultTarget(_ targets: JSONValue, sessionID: String?) -> Target? {
        let sessions = targets["sessions"]?.items ?? []
        if let session = sessions.first(where: { $0.display("session_id") == sessionID }) ?? sessions.first { return .session(session) }
        return (targets["applications"]?.items.first).map { .application($0) }
    }

    /// 补一轮时默认的轮次：下一轮在一到三面之间就用它，否则三面。
    public static func defaultRound(_ application: JSONValue) -> String {
        let next = application["next_round"]?.integer ?? 0
        return (1...3).contains(next) ? "\(next)" : "3"
    }

    /// `POST /api/mock-interviews/imports` 的请求体；round 为 "1"–"3" 或 "hr"，day 为 yyyy-MM-dd。
    public static func importBody(_ target: Target, replace: Bool, round: String, day: String) -> JSONValue {
        switch target {
        case .session(let s):
            var fields: [String: JSONValue] = ["session_id": .string(s.display("session_id"))]
            if replace { fields["replace"] = .bool(true) }
            return .object(fields)
        case .application(let a):
            var fields: [String: JSONValue] = ["application_id": .string(a.display("application_id")), "occurred_on": .string(day)]
            if round == "hr" { fields["stage_type"] = .string("hr") } else { fields["stage_type"] = .string("interview"); fields["round_no"] = .number(Double(Int(round) ?? 1)) }
            return .object(fields)
        }
    }
}

/// 复盘总览「本场知识点掌握度」曲线的几何（Web `ReviewCharts.WaveChart`）：968 × 220 的画布，0–100 分映射到 212–32。
public enum MockWave {
    public static let width = 968.0, top = 32.0, bottom = 212.0, left = 34.0
    public static let pass = 60
    public static func y(_ score: Int) -> Double { bottom - Double(max(0, min(100, score))) / 100 * (bottom - top) }
    public static func xs(_ count: Int) -> [Double] {
        let x0 = left + 54, x1 = width - 54
        guard count > 1 else { return [(x0 + x1) / 2] }
        return (0..<count).map { x0 + Double($0) * (x1 - x0) / Double(count - 1) }
    }

    /// 单调三次插值的切线：相邻两段坡向相反时取 0，曲线不会冲出点的上下范围。
    public static func tangents(_ points: [(x: Double, y: Double)]) -> [Double] {
        guard points.count > 1 else { return points.map { _ in 0 } }
        let slopes = (1..<points.count).map { (points[$0].y - points[$0 - 1].y) / (points[$0].x - points[$0 - 1].x) }
        return points.indices.map { i in
            if i == 0 { return slopes[0] }
            if i == points.count - 1 { return slopes[i - 1] }
            let a = slopes[i - 1], b = slopes[i]
            return a * b <= 0 ? 0 : (a + b) / 2
        }
    }

    public enum Anchor: Equatable { case start, middle, end }
    public struct Call: Equatable { public var x: Double; public var y: Double; public var anchor: Anchor }

    /// 分数写在哪：低谷写在点下面，上坡、下坡往线外侧让开，其余写在点上面；下面压到底线时还是写在上面。
    public static func calls(_ scores: [Int]) -> [Call] {
        let xs = xs(scores.count)
        return scores.indices.map { i in
            let x = xs[i], y = y(scores[i])
            let prev = i > 0 ? scores[i - 1] : nil, next = i + 1 < scores.count ? scores[i + 1] : nil
            let higherBefore = prev.map { $0 > scores[i] } ?? false, higherAfter = next.map { $0 > scores[i] } ?? false
            let valley = (higherBefore || higherAfter) && (prev == nil || higherBefore) && (next == nil || higherAfter)
            if valley && y + 30 <= bottom { return Call(x: x, y: y + 24, anchor: .middle) }
            if higherBefore != higherAfter && !valley { return Call(x: higherBefore ? x - 2 : x + 2, y: y - 14, anchor: higherBefore ? .start : .end) }
            return Call(x: x, y: y - 14, anchor: .middle)
        }
    }
}
