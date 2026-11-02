import Foundation

/// 模拟面试 V2 的掌握程度图与地平线（Web `mock-interview/v2/geom.ts`、`pathModel.ts`、`experienceModel.ts`、
/// `homeModel.ts`、`sessionLayout.ts`）：画布按设计稿坐标排版（首页 1151 × 828，面试中 1368 × 828），再整体缩放。
public enum MockMap {
    public static let levels = ["了解", "熟悉", "掌握", "精通", "专家"]
    public static let sectorAngles: [Double] = [-120, -60, 0, 60, 120, 180]
    public static let horizonRadius = 3000.0

    public static func levelName(_ level: Double?) -> String {
        guard let level, level >= 1 else { return "" }
        return levels[min(5, max(1, Int(level.rounded()))) - 1]
    }

    // MARK: 几何

    public struct Geo: Sendable {
        public let cx: Double, cy: Double, k: Double
        public init(cx: Double, cy: Double, k: Double) { self.cx = cx; self.cy = cy; self.k = k }
        /// 第 L 层圆环的中线（点画在这里）与内沿（目标线画在这里）。
        public func rOf(_ level: Double) -> Double { k * (225 - 45 * (level - 1) - 22.5) }
        public func ringOf(_ level: Double) -> Double { k * (225 - 45 * (level - 1) - 45) }
        public func P(_ angle: Double, _ radius: Double) -> (x: Double, y: Double) {
            (cx + radius * cos(angle * .pi / 180), cy + radius * sin(angle * .pi / 180))
        }
    }

    /// 地平线：半径 3000 的大圆弧，顶点在画布正中。
    public static func arcY(width: Double, top: Double) -> (Double) -> Double {
        { x in top + horizonRadius - (horizonRadius * horizonRadius - pow(x - width / 2, 2)).squareRoot() }
    }

    // MARK: 图上的点

    public struct Point: Equatable, Sendable {
        public var id: String
        public var name: String
        public var sector: String
        public var angle: Double
        /// 答到第几层；0 表示还没被问过（画在外圈虚线上）。
        public var level: Double
        /// 被问概率 1 低 · 2 中 · 3 高。
        public var ask: Int
        public var job = false
        public var prev: Double? = nil
        public var pending = false
        public var offset: Double = 0
        public init(id: String, name: String, sector: String, angle: Double, level: Double, ask: Int, job: Bool = false, prev: Double? = nil, pending: Bool = false, offset: Double = 0) {
            self.id = id; self.name = name; self.sector = sector; self.angle = angle; self.level = level; self.ask = ask
            self.job = job; self.prev = prev; self.pending = pending; self.offset = offset
        }
    }

    public struct Sector: Equatable, Sendable { public var name: String; public var angle: Double; public init(name: String, angle: Double) { self.name = name; self.angle = angle } }
    /// 一场练习的提问路线：每道主问题从起问层走到追问停下的那层；ok=false 是在那层没答上，nil 是正在问。
    public struct PathStep: Equatable, Sendable { public var id: String; public var from: Double; public var to: Double; public var ok: Bool? }

    public struct Placed: Equatable, Sendable { public var point: Point; public var x: Double; public var y: Double }

    public static func place(_ g: Geo, _ points: [Point]) -> [Placed] {
        points.map { point in
            let radius = (point.level == 0 ? 248 * g.k : g.rOf(point.level)) + point.offset * g.k
            let p = g.P(point.angle, radius)
            return Placed(point: point, x: p.x, y: p.y)
        }
    }

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

    // MARK: 简历经历（experienceModel）

    private static let skipKinds: Set<String> = ["profile", "skills", "interests", "languages", "certificates"]
    private static let normDrop = Set("「」“”\"'‘’，。,.、：:；;（）()·-—…~～")

    static func norm(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace && !normDrop.contains($0) }).lowercased()
    }

    static func strings(_ value: JSONValue, _ out: inout [String]) {
        switch value {
        case .array(let items): for item in items { strings(item, &out) }
        case .object(let object):
            // 与 Web Object.entries 一致按插入顺序遍历做不到，这里按键名排序；只影响「第一条正文」的兜底名字。
            for key in object.keys.sorted() {
                let item = object[key]!
                if key == "value", case .string(let text) = item { out.append(text) }
                else if case .object = item { strings(item, &out) }
                else if case .array = item { strings(item, &out) }
            }
        default: break
        }
    }

    static func shortLabel(_ text: String, _ limit: Int = 8) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
    }

    static func overlap(_ anchor: String, _ body: String) -> Int {
        guard !anchor.isEmpty, !body.isEmpty else { return 0 }
        if body.contains(anchor) { return 1000 }
        let chars = Array(anchor.utf16)
        let size = chars.count < 16 ? 4 : 6
        var hits = 0, index = 0
        while index + size <= chars.count {
            if let piece = String(utf16CodeUnits: Array(chars[index..<index + size]), count: size) as String?, body.contains(piece) { hits += 1 }
            index += 2
        }
        return hits
    }

    /// 简历题出自哪段经历：在简历里找包含这句话（或重合最多）的那条经历，用公司 / 项目 / 论文名作扇区名。
    public static func experienceIndex(_ resume: JSONValue?) -> (String?) -> String? {
        var items: [(label: String, body: String)] = []
        for section in resume?["sections"]?.items ?? [] {
            if skipKinds.contains(section.text("semantic_kind")) { continue }
            for entry in section["entries"]?.items ?? [] {
                let field = entry["fields"]?["organization"]?.text("value").nonEmptyValue ?? entry["fields"]?["name"]?.text("value").nonEmptyValue
                var label: String?
                if let field, !field.trimmingCharacters(in: .whitespaces).isEmpty { label = shortLabel(field) }
                else {
                    var first: [String] = []
                    if let blocks = entry["blocks"] { strings(blocks, &first) }
                    let title = section["title"]?.text("value") ?? ""
                    label = first.first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : shortLabel($0) }
                        ?? (title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : shortLabel(title))
                }
                var texts: [String] = []
                strings(entry, &texts)
                if let label { items.append((label, norm(texts.joined()))) }
            }
        }
        return { anchor in
            let text = norm(anchor ?? "")
            guard !text.isEmpty, !items.isEmpty else { return nil }
            var best: (label: String, score: Int)?
            for item in items {
                let score = overlap(text, item.body)
                if score > (best?.score ?? 0) { best = (item.label, score) }
            }
            return best?.label
        }
    }

    // MARK: 首页模型（homeModel）

    public static let diffLevel: [String: Double] = ["junior": 2, "intermediate": 3, "senior": 4]
    public static let diffName = ["junior": "初级", "intermediate": "中级", "senior": "高级"]
    public static let typeNames = ["technical": "专业面", "project_deep_dive": "项目深挖", "comprehensive": "综合面", "hr": "HR 面"]
    public static func typeName(_ item: JSONValue) -> String { item.text("type_label").nonEmptyValue ?? typeNames[item.text("interview_type")] ?? "综合面" }
    public static let verdictName = [
        "likely_pass": "达到目标", "promising": "接近目标", "at_risk": "还差一些", "likely_fail": "差距较大", "insufficient": "证据不足",
        "meets": "达标", "borderline": "接近达标", "below": "未达标",
    ]
    public enum Tone: Sendable { case blue, orange, ink, gray }
    public static func verdictTone(_ level: String?) -> Tone {
        switch level {
        case "likely_pass", "meets": return .blue
        case "promising", "borderline": return .orange
        case "insufficient", nil, "": return .gray
        default: return .ink
        }
    }

    public static let projectSector = "项目经历"
    public static let expressSector = "表达"
    private static let expressKinds: Set<String> = ["type_point", "competency"]
    private static let maxPoints = 14

    public struct Focus: Equatable, Sendable {
        public let kind: String, ref: String, label: String
        public init(kind: String, ref: String, label: String) { self.kind = kind; self.ref = ref; self.label = label }
        public init?(_ json: JSONValue?) {
            guard let json, json != .null, !json.text("label").isEmpty else { return nil }
            kind = json.text("kind"); ref = json.text("ref"); label = json.text("label")
        }
        public var json: JSONValue { .object(["kind": .string(kind), "ref": .string(ref), "label": .string(label)]) }
    }

    public struct HomePoint: Sendable {
        public var point: Point
        /// 出处：知识点、简历说法或岗位要求。
        public var source: String
        public var node: JSONValue? = nil
        public var hook: JSONValue? = nil
        public var focus: Focus? = nil
        public var followUps: [String] = []
    }

    static func ask(_ node: JSONValue) -> Int {
        let real = node["real_count"]?.integer ?? 0, mock = node["mock_count"]?.integer ?? 0
        if real >= 2 || real + mock >= 3 { return 3 }
        if real >= 1 || mock >= 2 { return 2 }
        return 1
    }
    static let asked = ["高": 3, "中": 2, "低": 1]

    static func spread(_ center: Double, _ count: Int, _ width: Double = 48) -> [Double] {
        (0..<count).map { center - width / 2 + width * (Double($0) + 0.5) / Double(count) }
    }

    static func shortName(_ text: String, _ limit: Int = 10) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Web 用 String.length（UTF-16）截断。
        let units = Array(clean.utf16)
        return units.count > limit ? (String(utf16CodeUnits: Array(units.prefix(limit)), count: limit)) + "…" : clean
    }

    /// 扇区：问得最多的四个技术领域 + 项目经历 + 表达；其余领域并进「其他」。
    public static func sectors(_ nodes: [JSONValue]) -> (sectors: [Sector], sectorOf: (JSONValue) -> String) {
        let tech = nodes.filter { !expressKinds.contains($0.text("kind")) }
        var counts: [(String, Int)] = []
        for node in tech {
            let domain = node.text("domain").nonEmptyValue ?? "其他"
            let add = (node["real_count"]?.integer ?? 0) * 2 + (node["mock_count"]?.integer ?? 0) + 1
            if let index = counts.firstIndex(where: { $0.0 == domain }) { counts[index].1 += add } else { counts.append((domain, add)) }
        }
        // 稳定排序：同分按出现先后（与 JS Array.sort 一致）。
        let ranked = counts.enumerated().sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }.map(\.element.0)
        var named = ranked.count > 4 ? Array(ranked.prefix(3)) + ["其他"] : ranked
        while named.count < 4 { named.append("__empty_\(named.count)") }
        let all = Array(named.prefix(4)) + [projectSector, expressSector]
        let sectors = all.enumerated().map { Sector(name: $0.element, angle: sectorAngles[$0.offset]) }
        let sectorOf: (JSONValue) -> String = { node in
            if expressKinds.contains(node.text("kind")) { return expressSector }
            let domain = node.text("domain").nonEmptyValue ?? "其他"
            return named.contains(domain) ? domain : "其他"
        }
        return (sectors, sectorOf)
    }

    public static func homePoints(atlas: JSONValue?, outline: JSONValue?, match: JSONValue?, type: String) -> (points: [HomePoint], sectors: [Sector]) {
        let nodes = atlas?["enabled"]?.bool == true ? atlas?["nodes"]?.items ?? [] : []
        let (sectors, sectorOf) = Self.sectors(nodes)
        var groupOrder: [String] = []
        var grouped: [String: [HomePoint]] = [:]
        func push(_ sector: String, _ point: HomePoint) {
            var point = point
            point.point.sector = sector
            if grouped[sector] == nil { groupOrder.append(sector) }
            grouped[sector, default: []].append(point)
        }
        var known = Set<String>()
        for node in nodes {
            let level = node["level"]?.numberValue ?? 0
            known.insert(node.text("name")); known.insert(node.text("key"))
            let prev = node["previous_level"]?.numberValue
            push(sectorOf(node), HomePoint(
                point: Point(id: "n:\(node.text("key"))", name: shortName(node.text("name"), 10), sector: "", angle: 0, level: level, ask: ask(node),
                             prev: prev.flatMap { $0 > 0 && $0 < level ? $0 : nil }),
                source: "atlas", node: node, focus: Focus(kind: "topic", ref: node.text("key"), label: node.text("name"))))
        }
        let hooks = outline?["enabled"]?.bool == true ? outline?["hooks"]?.items ?? [] : []
        func held(_ hook: JSONValue) -> (untested: Bool, level: Double) {
            (hook["held"]?.text("status") == "untested", hook["held"]?["level"]?.numberValue ?? 0)
        }
        if type == "project_deep_dive" {
            for hook in hooks.prefix(6) {
                let state = held(hook)
                push(projectSector, HomePoint(
                    point: Point(id: "h:\(hook.display("id"))", name: "「\(shortName(hook.text("text"), 9))」", sector: "", angle: 0,
                                 level: state.untested ? 0 : state.level, ask: asked[hook.text("asked")] ?? 1),
                    source: "hook", hook: hook, focus: Focus(hook["practice"]),
                    followUps: (hook["follow_ups"]?.items ?? []).map { $0.text("question") }))
            }
        } else {
            var order: [String] = []
            var byExperience: [String: [JSONValue]] = [:]
            for hook in hooks {
                let key = hook.text("experience").nonEmptyValue ?? hook.text("text")
                if byExperience[key] == nil { order.append(key) }
                byExperience[key, default: []].append(hook)
            }
            for experience in order.prefix(3) {
                let list = byExperience[experience] ?? []
                let tested = list.filter { !held($0).untested && held($0).level > 0 }
                let level = tested.isEmpty ? 0 : tested.map { held($0).level }.min() ?? 0
                let ask = list.map { asked[$0.text("asked")] ?? 1 }.max() ?? 1
                let first = list.first { Focus($0["practice"]) != nil } ?? list[0]
                push(projectSector, HomePoint(
                    point: Point(id: "e:\(experience)", name: shortName(experience, 8), sector: "", angle: 0, level: level, ask: ask),
                    source: "hook", hook: first, focus: Focus(first["practice"]),
                    followUps: list.flatMap { ($0["follow_ups"]?.items ?? []).map { $0.text("question") } }))
            }
        }
        if match?["enabled"]?.bool == true, match?.text("match_status") == "ready" {
            for requirement in match?["requirements"]?.items ?? [] {
                if requirement.text("group") == "qualification" || requirement["interview"]?.text("status") != "insufficient" { continue }
                let node = requirement["nodes"]?.items.first
                let name = node?.text("name").nonEmptyValue ?? requirement["interview"]?["skills"]?.items.first?.text("name").nonEmptyValue
                    ?? shortName(requirement.text("text"), 8)
                if name.isEmpty || known.contains(name) || (node.map { known.contains($0.text("key")) } ?? false) { continue }
                known.insert(name)
                let sector = sectors.prefix(4).first { requirement.text("text").contains($0.name) }?.name ?? sectors[3].name
                let importance = requirement.text("importance")
                push(sector, HomePoint(
                    point: Point(id: "j:\(requirement.display("id").nonEmptyValue ?? name)", name: name, sector: "", angle: 0, level: 0,
                                 ask: importance == "must" || importance == "high" ? 3 : 2, job: true),
                    source: "job", focus: node.map { Focus(kind: "topic", ref: $0.text("key"), label: $0.text("name")) }))
            }
        }
        var points: [HomePoint] = []
        let perSector = max(2, Int((Double(maxPoints) / 6).rounded(.up)))
        for sector in sectors {
            let list = (grouped[sector.name] ?? []).enumerated().sorted { a, b in
                let x = a.element.point, y = b.element.point
                if x.job != y.job { return x.job }
                if x.ask != y.ask { return x.ask > y.ask }
                if x.level != y.level { return x.level < y.level }
                return a.offset < b.offset
            }.map(\.element)
            let deep = type == "project_deep_dive" && sector.name == projectSector
            let shown = Array(list.prefix(deep ? 6 : perSector))
            let angles = spread(deep ? sector.angle - 6 : sector.angle, shown.count, deep ? 104 : 48)
            for (index, item) in shown.enumerated() {
                var item = item
                item.point.angle = angles[index]
                item.point.offset = deep && item.point.level == 0 && index % 2 == 1 ? -22 : 0
                points.append(item)
            }
        }
        _ = groupOrder
        return (points, sectors)
    }

    /// 先问的那一处：被问概率高、离目标差得最多的点；都答到了就交给「让面试官决定」。
    public static func suggestFocus(_ points: [HomePoint], targetLevel: Double) -> HomePoint? {
        let scored = points.enumerated().compactMap { index, item -> (HomePoint, Double, Int)? in
            guard item.focus != nil else { return nil }
            let point = item.point
            let gap = point.level == 0 ? (point.job ? targetLevel - 0.5 : 0) : max(0, targetLevel - point.level)
            return gap > 0 ? (item, gap * 2 + Double(point.ask), index) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.first?.0
    }

    public enum SubTone: Sendable { case orange, blue, mute }

    public static func pointSubs(_ points: [HomePoint], targetLevel: Double, focusID: String?) -> [String: (String, SubTone)] {
        var subs: [String: (String, SubTone)] = [:]
        if let focus = points.first(where: { $0.point.id == focusID }), focus.point.level > 0, focus.point.level < targetLevel {
            let real = (focus.node?["asks"]?.items ?? []).reversed().first { $0.text("kind") == "real" && ($0["depth"]?.numberValue ?? -1) == focus.point.level }
            let where_ = real.map { $0.text("company") + $0.text("stage") } ?? ""
            subs[focus.point.id] = ("\(where_)只答到「\(levelName(focus.point.level))」· 差 \(Int(targetLevel - focus.point.level)) 层", .orange)
        }
        if let job = points.first(where: { $0.point.job && $0.point.level == 0 && $0.point.id != focusID }) { subs[job.point.id] = ("岗位要求有 · 还没被问过", .orange) }
        if let progress = points.first(where: { $0.point.prev != nil && $0.point.ask == 3 && subs[$0.point.id] == nil }) {
            let diff = Int(progress.point.level - (progress.point.prev ?? 0))
            subs[progress.point.id] = ("高频 · 比上次多答\(diff > 1 ? " \(diff) " : "一")层", .blue)
        }
        return subs
    }

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

    public static func hhmm(_ date: Date, calendar: Calendar = Beijing.calendar) -> String {
        String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }

    public static func mmddDot(_ date: Date, calendar: Calendar = Beijing.calendar) -> String {
        String(format: "%02d·%02d", calendar.component(.month, from: date), calendar.component(.day, from: date))
    }
    public static func mmddDot(_ value: String) -> String { CareerApplication.date(value).map { mmddDot($0) } ?? "" }

    public struct ChainItem: Equatable, Sendable {
        public enum Tone: Sendable { case done, now, todo }
        public var label: String; public var tone: Tone; public var check = false
    }

    /// 投递 — 笔试 — 一面 — 二面 · 周五 — HR — Offer：走过的墨黑，当前一步蓝色，后面灰色。
    public static func stageChain(_ application: JSONValue?, session: JSONValue?, now: Date) -> [ChainItem] {
        guard let application else { return [] }
        let stages = (application["stages"]?.items ?? []).filter { $0.text("stage_status") != "cancelled" }
            .sorted { ($0["sequence_no"]?.numberValue ?? 0) < ($1["sequence_no"]?.numberValue ?? 0) }
        var items = [ChainItem(label: "投递", tone: .done)]
        let currentID = application["current_stage"]?.display("id") ?? ""
        for (index, stage) in stages.enumerated() where stage.text("stage_type") != "screening" {
            let current = (stage["current_marker"] ?? .null) != .null || (!currentID.isEmpty && stage.display("id") == currentID)
            items.append(ChainItem(label: stage.text("stage_label"), tone: current ? .now : .done,
                                   check: !current && stage.text("stage_result") == "passed" && index == stages.count - 1))
        }
        if let session {
            let label = session.text("stage_label").nonEmptyValue ?? application.text("current_stage_label")
            let when = relativeDay(CareerApplication.date(session.text("start_at")) ?? now, now: now)
            if let last = items.last, last.label == label {
                items[items.count - 1].label = "\(label) · \(when)"; items[items.count - 1].tone = .now
            } else {
                for index in items.indices where items[index].tone == .now { items[index].tone = .done }
                items.append(ChainItem(label: "\(label) · \(when)", tone: .now))
            }
        } else if !items.contains(where: { $0.tone == .now }) && items.count > 1 {
            items[items.count - 1].tone = .now
        }
        let reached = items.map(\.label).joined(separator: " ")
        if reached.range(of: "HR", options: .caseInsensitive) == nil { items.append(ChainItem(label: "HR", tone: .todo)) }
        if reached.range(of: "Offer", options: .caseInsensitive) == nil { items.append(ChainItem(label: "Offer", tone: .todo)) }
        return items
    }

    // MARK: 地平线

    public struct HorizonSession: Equatable, Sendable {
        public let id: String
        public let x: Double
        public let date: String
        public let score: Int?
        public let level: String?
        public let mine: Bool
        public let title: String
        public let delta: Int?
        public let detail: String
    }

    public struct Interview: Equatable, Sendable { public let x: Double; public let title: String; public let sub: String?; public let subGray: Bool; public let dash: Bool }

    public struct Horizon: Sendable {
        public let sessions: [HorizonSession]
        public let today: Double
        public let days: [(x: Double, label: String)]
        public let interview: Interview?
        public let past: (title: String, sub: String?)
    }

    public static let todayX = 520.0
    public static let homeHorizonTop = 668.0

    public static func horizon(list: [JSONValue], target: Target, difficulty: String, now: Date) -> Horizon {
        let finished = list.filter { ["completed", "abandoned"].contains($0.text("status")) }
            .sorted { ($0.text("finished_at").nonEmptyValue ?? $0.text("created_at")) < ($1.text("finished_at").nonEmptyValue ?? $1.text("created_at")) }
            .suffix(7)
        var lastScore: [String: Int] = [:]
        let sessions = finished.enumerated().map { index, item -> HorizonSession in
            let app = item.display("job_application_id")
            let mine = target.kind == .general ? app.isEmpty && item.text("difficulty") == difficulty
                : target.application.map { app == $0.display("id") && item.text("difficulty") == difficulty } ?? false
            let score = item.text("status") == "completed" ? item["total_score"]?.numberValue.map { Int($0.rounded()) } : nil
            let group = "\(app.isEmpty ? "general" : app):\(item.text("difficulty"))"
            let previous = lastScore[group]
            if let score { lastScore[group] = score }
            let date = mmddDot(item.text("finished_at").nonEmptyValue ?? item.text("created_at"))
            let count = item["question_count"]?.integer ?? 0
            return HorizonSession(
                id: item.text("id"), x: todayX - 80 - Double(finished.count - 1 - index) * 58, date: date, score: score,
                level: item.text("verdict").nonEmptyValue, mine: mine,
                title: [date, item.text("company_name").nonEmptyValue ?? "通用练习", typeName(item), diffName[item.text("difficulty")] ?? ""].joined(separator: " · "),
                delta: score != nil && previous != nil ? score! - previous! : nil,
                detail: score == nil ? "\(count) 题 · 中途放弃，没有报告" : "\(count) 题")
        }
        let practiced = list.filter { ["completed", "abandoned"].contains($0.text("status")) }.count
        let latest = sessions.reversed().first { $0.score != nil }
        let past: (String, String?) = practiced == 0 ? ("还没练过", "练过的每一场会排在这条线上")
            : ("练过 \(practiced) 场", latest.map { "最近 \($0.score!) 分" + ($0.delta.map { " · 比上一场同岗位 \($0 >= 0 ? "+" : "")\($0)" } ?? "") } ?? "还没有完成的场次")
        var days: [(Double, String)] = []
        var interview: Interview? = nil
        if let session = target.session, let start = CareerApplication.date(session.text("start_at")) {
            let diff = max(0, dayDiff(now, start))
            let x = min(1040, 760 + Double(max(0, diff - 1)) * 150)
            var day = 1
            while day < diff && 760 + Double(day - 1) * 150 < x {
                let date = Beijing.calendar.date(byAdding: .day, value: day, to: now) ?? now
                days.append((760 + Double(day - 1) * 150, weekdays[Beijing.calendar.component(.weekday, from: date) - 1]))
                day += 1
            }
            let label = session.text("stage_label").nonEmptyValue ?? target.application?.text("current_stage_label").nonEmptyValue ?? "面试"
            interview = Interview(x: diff == 0 ? 760 : x, title: "\(relativeDay(start, now: now))  \(label)", sub: diff == 0 ? "\(hhmm(start)) 开始" : "还有 \(diff) 天", subGray: false, dash: false)
        } else if target.kind == .application {
            interview = Interview(x: 910, title: "还没安排面试", sub: "在面试日程里加上时间后会显示在这里", subGray: true, dash: true)
        }
        return Horizon(sessions: Array(sessions), today: todayX, days: days, interview: interview, past: past)
    }

    public static func trackLine(list: [JSONValue], target: Target, difficulty: String) -> [JSONValue] {
        list.filter { item in
            guard item.text("status") == "completed", item["total_score"]?.numberValue != nil, item.text("difficulty") == difficulty else { return false }
            let app = item.display("job_application_id")
            return target.kind == .general ? app.isEmpty : app == (target.application?.display("id") ?? "")
        }.sorted { ($0.text("finished_at").nonEmptyValue ?? $0.text("created_at")) < ($1.text("finished_at").nonEmptyValue ?? $1.text("created_at")) }
    }

    public static func companyName(_ target: Target) -> String {
        target.application?.text("company_name_snapshot").nonEmptyValue ?? target.session?.text("company_name") ?? ""
    }

    /// 地平线上分数越高竖杆越高；低于 45 分的按 45 算。
    public static func homeScoreY(_ arcY: (Double) -> Double, _ x: Double, _ score: Int) -> Double {
        arcY(x) - 30 - (Double(max(45, min(100, score))) - 50) * 2.1
    }
    public static func slotXs(_ count: Int) -> [Double] { (0..<count).map { 590 + Double($0) * 28 } }

    /// 积分说明（后端 billing.service.mock_question_price）。
    public static func credits(text: JSONValue?, voice: JSONValue?, count: Int) -> String? {
        func unit(_ price: JSONValue?) -> Double? { price?["unitPoints"]?.numberValue ?? price?["unitPoints"]?.stringValue.flatMap(Double.init) }
        func mode(_ price: JSONValue?) -> String { price?.text("priceMode") ?? "" }
        let trim = { (value: Double) -> String in
            let rounded = (value * 100).rounded() / 100
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }
        if mode(text) == "fixed", let textUnit = unit(text) {
            if mode(voice) == "free" { return "本次免费" }
            let each = mode(voice) == "fixed" ? unit(voice) ?? textUnit : textUnit
            return "\(trim(each * Double(count))) 积分（每题 \(trim(each))）"
        }
        if mode(text) == "free" { return "本次免费" }
        if mode(text) == "usage" { return "按实际用量计积分" }
        return nil
    }
}
