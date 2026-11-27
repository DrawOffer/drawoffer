import Foundation

// 首页 · 哪里要提升：移植 Web `features/assistant/homeImprove/scene.ts`。
// 按用户此刻的状态挑一种画面（起步、有资料没简历、经历、有简历没练过、备战/没打牢、回流、结论形成中），
// 同样的输入得到同样的结论、清单、星图节点与时间轴。

public struct PracticeFocus: Equatable, Hashable, Sendable {
    public let kind: String
    public let ref: String
    public let label: String
    /// 练经历（Web `newMockInterviewPath` 的 resume / scope / hook / short）：经历在哪份简历、只练延伸点还是整段、从哪个延伸点开始、趁热练的短版
    public var resumeID: String?
    public var scope: String?
    public var hook: String?
    public var short = false
    /// 从哪来（outline / section_hint / assistant），只用于产品指标
    public var origin: String?
    public init(kind: String, ref: String, label: String, resumeID: String? = nil, scope: String? = nil, hook: String? = nil, short: Bool = false, origin: String? = nil) {
        self.kind = kind; self.ref = ref; self.label = label
        self.resumeID = resumeID; self.scope = scope; self.hook = hook; self.short = short; self.origin = origin
    }
    init?(_ json: JSONValue?) {
        guard let json, case .object = json, !json.text("ref").isEmpty else { return nil }
        kind = json.text("kind"); ref = json.text("ref"); label = json.text("label")
        resumeID = json.display("resume_id").nonEmptyValue; hook = json.text("hook").nonEmptyValue
    }
}

public struct MemoryHome: Sendable {
    public struct Ask: Sendable { public let date: String; public let kind: String; public let sourceID: String; public let company: String?; public let stage: String? }
    public struct Node: Sendable {
        public let key: String, name: String, grade: String?, gradeLabel: String?
        public let level: Int?, bestLevel: Int?, lastDate: String?, asks: [Ask]
    }
    public struct Issue: Sendable {
        public let key: String, kind: String, statement: String, node: String?, name: String
        public let experience: String?, element: String?, facet: String?, cause: String?, held: String?, date: String?
        public let practice: PracticeFocus?
    }
    public struct Link: Sendable { public let key: String, name: String, parent: String? }
    public struct Edge: Sendable { public let src: String, dst: String }
    public struct Tech: Sendable { public let key: String, name: String, topics: [String] }
    public struct Gap: Sendable { public let facet: String?, element: String?, issue: String }
    public struct Experience: Sendable { public let key: String, title: String, told: Bool, gaps: [Gap], practice: PracticeFocus? }
    public struct Competency: Sendable { public let key: String, name: String, grade: String?, gradeLabel: String?, coverage: Double }
    public struct Origin: Sendable { public let kind: String, company: String?, title: String }

    public let enabled: Bool
    public let targetComputing: Bool?
    public let nodes: [Node]
    public let issues: [Issue]
    public let links: [Link]
    public let edges: [Edge]
    public let neighbors: [String: [String]]
    public let resumeTechnologies: [Tech]
    public let experiences: [Experience]
    public let competencies: [Competency]
    public let unasked: [String]
    public let unaskedFrom: Origin?

    public init(json: JSONValue) {
        func opt(_ value: JSONValue, _ key: String) -> String? { let text = value.text(key); return text.isEmpty ? nil : text }
        func int(_ value: JSONValue, _ key: String) -> Int? { value[key]?.numberValue.map { Int($0) } }
        enabled = json["enabled"]?.bool ?? false
        targetComputing = json["target"].flatMap { target -> Bool? in if case .object = target { return target["computing"]?.bool ?? false }; return nil }
        nodes = (json["nodes"]?.items ?? []).map { node in
            Node(key: node.text("key"), name: node.text("name"), grade: opt(node, "grade"), gradeLabel: opt(node, "grade_label"),
                 level: int(node, "level"), bestLevel: int(node, "best_level"), lastDate: opt(node, "last_date"),
                 asks: (node["asks"]?.items ?? []).map { ask in
                     Ask(date: ask.text("date"), kind: ask.text("kind"), sourceID: ask.text("source_id"), company: opt(ask, "company"), stage: opt(ask, "stage"))
                 })
        }
        issues = (json["issues"]?.items ?? []).map { issue in
            Issue(key: issue.text("key"), kind: issue.text("kind"), statement: issue.text("statement"), node: opt(issue, "node"),
                  name: issue.text("name"), experience: opt(issue, "experience"), element: opt(issue, "element"), facet: opt(issue, "facet"),
                  cause: opt(issue, "cause"), held: opt(issue, "held"), date: opt(issue, "date"), practice: PracticeFocus(issue["practice"]))
        }
        links = (json["links"]?.items ?? []).map { Link(key: $0.text("key"), name: $0.text("name"), parent: opt($0, "parent")) }
        edges = (json["edges"]?.items ?? []).map { Edge(src: $0.text("src"), dst: $0.text("dst")) }
        var neighbors: [String: [String]] = [:]
        if case .object(let map)? = json["neighbors"] { for (key, value) in map { neighbors[key] = value.items.compactMap(\.stringValue) } }
        self.neighbors = neighbors
        resumeTechnologies = (json["resume_technologies"]?.items ?? []).map {
            Tech(key: $0.text("key"), name: $0.text("name"), topics: ($0["topics"]?.items ?? []).compactMap(\.stringValue))
        }
        experiences = (json["experiences"]?.items ?? []).map { item in
            Experience(key: item.text("key"), title: item.text("title"), told: item["told"]?.bool ?? false,
                       gaps: (item["gaps"]?.items ?? []).map { Gap(facet: opt($0, "facet"), element: opt($0, "element"), issue: $0.text("issue")) },
                       practice: PracticeFocus(item["practice"]))
        }
        competencies = (json["competencies"]?.items ?? []).map {
            Competency(key: $0.text("key"), name: $0.text("name"), grade: opt($0, "grade"), gradeLabel: opt($0, "grade_label"), coverage: $0["coverage"]?.numberValue ?? 0)
        }
        unasked = (json["unasked"]?.items ?? []).compactMap(\.stringValue)
        unaskedFrom = json["unasked_from"].flatMap { from -> Origin? in
            guard case .object = from else { return nil }
            return Origin(kind: from.text("kind"), company: opt(from, "company"), title: from.text("title"))
        }
    }
}

public struct HomeDataset: Sendable {
    public let id: String, fileName: String, createdAt: Date
    public let document: Bool
    public init(json: JSONValue) {
        id = json.display("id"); fileName = json.text("file_name")
        createdAt = ResumeSummary.parseTimestamp(json.text("created_at")) ?? Date.distantPast
        let kind = json.text("asset_kind").isEmpty ? "document" : json.text("asset_kind")
        document = kind == "document" && json.text("upload_status") == "succeeded" && json.text("parse_status") == "succeeded"
    }
}

public struct HomeSession: Sendable {
    public let id: String, status: String, startAt: Date, company: String, stageLabel: String
    public init?(json: JSONValue) {
        guard let start = CareerApplication.date(json.text("start_at")) else { return nil }
        id = json.display("id"); status = json.text("status"); startAt = start
        company = json.text("company_name"); stageLabel = json.text("stage_label")
    }
}

public struct HomeResume: Sendable { public let id: String, title: String, updatedAt: String
    public init(id: String, title: String, updatedAt: String) { self.id = id; self.title = title; self.updatedAt = updatedAt } }

public enum HomeSym: String, Sendable { case mastered, weak, pending, untested, due, anchor, topic, planet }
public enum HomeTone: String, Sendable { case ink, blue, orange, soft }

public struct HomeMapNode: Identifiable, Sendable {
    public let id: String
    public var sym: HomeSym
    public var label: String
    public var sub: String?
    public var subTone: HomeTone?
    public var level: Int?
    public var badge: Int?
    public var group: String
    public var parent: String?
    public var focus: PracticeFocus?
    public var ask: String?
}
public struct HomeMapEdge: Sendable { public let from: String, to: String; public let prereq: Bool }
public struct HomeRegion: Sendable { public let members: [String]; public let title: String }
public struct HomeListItem: Identifiable, Sendable {
    public let id: String; public let sym: HomeSym; public let title: String; public let right: String?
    public let sub: String; public let badge: Int?; public let level: Int?; public let focus: PracticeFocus?
}
public enum HomeAction: Sendable { case mock(PracticeFocus?), chat(String), suggest(String), guide([String]) }
public struct HomeMark: Identifiable, Sendable { public let id: String; public let at: Date; public let label: String; public let sub: String?; public let tone: HomeTone; public let future: Bool }
public struct HomePlanet: Identifiable, Sendable { public let id: String; public let label: String; public let sub: String; public let subTone: HomeTone?; public let links: [String]; public let near: Bool }

public struct HomeScene: Sendable {
    public var key = ""
    public var eyebrow = ""
    public var eyebrowTone: HomeTone = .blue
    public var title = ""
    public var sub = ""
    public var listTitle = ""
    public var list: [HomeListItem] = []
    public var action: (label: String, run: HomeAction, verb: String?, hint: String?)?
    public var secondary: (label: String, run: HomeAction)?
    public var mapTitle = ""
    public var mapNote = ""
    public var nodes: [HomeMapNode] = []
    public var edges: [HomeMapEdge] = []
    public var planets: [HomePlanet] = []
    public var region: HomeRegion?
    public var legend: [(HomeSym, String)] = []
    public var marks: [HomeMark] = []
    public var suggestion = ""
    public var disclose: [String] = []
}

public struct HomeInput: Sendable {
    public var now: Date
    public var home: MemoryHome?
    public var resumes: [HomeResume]
    public var datasets: [HomeDataset]
    public var sessions: [HomeSession]
    public var directions: [String]
    public var targetRole: String?
    public init(now: Date, home: MemoryHome?, resumes: [HomeResume], datasets: [HomeDataset], sessions: [HomeSession], directions: [String], targetRole: String?) {
        self.now = now; self.home = home; self.resumes = resumes; self.datasets = datasets; self.sessions = sessions
        self.directions = directions; self.targetRole = targetRole
    }
}

public enum HomeScenes {
    public static let levelNames = ["了解", "熟悉", "掌握", "精通", "专家"]
    static let day: TimeInterval = 86_400
    static let weekday = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
    static let causeShort: [String: String] = [
        "single": "相关的几点都答得不错，只差这一点", "theme": "相关的几点也要一起补",
        "prerequisite": "它依赖的基础还不稳，先补基础", "shallow": "再往深追问时容易卡住", "misconception": "有一处说法反复出现偏差",
    ]
    static let facets: [(String, String)] = [("background", "背景"), ("task", "任务"), ("action", "行动"), ("result", "结果")]

    public static func mmdd(_ date: Date) -> String {
        let parts = Beijing.calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0) · \(parts.day ?? 0)"
    }
    /// Web `dateOf`：日期取当天中午（东八区），避免跨时区换日。
    static func dateOf(_ text: String) -> Date {
        let calendar = Beijing.calendar
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date.distantPast }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) ?? Date.distantPast
    }
    static func levelOf(_ held: String?) -> Int? {
        guard let held, held.count == 2, held.first == "L", let value = Int(String(held.last!)), (1...5).contains(value) else { return nil }
        return value
    }
    static func levelName(_ level: Int?) -> String { guard let level, level > 0 else { return "" }; return levelNames[min(5, max(1, level)) - 1] }
    static func goalOf(_ level: Int?) -> Int { min(5, max(3, (level ?? 2) + 1)) }
    static func nextName(_ level: Int?) -> String { levelNames[goalOf(level) - 1] }
    static func countZh(_ count: Int) -> String { ["", "一", "两", "三"].indices.contains(count) ? ["", "一", "两", "三"][count] : String(count) }
    static func startOfDay(_ date: Date) -> Date { Beijing.calendar.startOfDay(for: date) }
    static func weekdayLabel(_ at: Date, _ now: Date) -> String {
        let days = Int(((startOfDay(at).timeIntervalSince(startOfDay(now))) / day).rounded())
        return days == 0 ? "今天" : days == 1 ? "明天" : days == 2 ? "后天" : weekday[Beijing.calendar.component(.weekday, from: at) - 1]
    }

    struct Tree {
        let links: [String: MemoryHome.Link]
        let home: MemoryHome
        init(_ home: MemoryHome) { self.home = home; links = Dictionary(home.links.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }) }
        func top(_ key: String) -> String {
            var at = key
            for _ in 0..<8 { guard let parent = links[at]?.parent, links[parent] != nil else { return at }; at = parent }
            return at
        }
        func mid(_ key: String) -> String? {
            var at = key, below = key
            for _ in 0..<8 {
                guard let parent = links[at]?.parent, links[parent] != nil else { return below == key ? nil : below }
                below = at; at = parent
            }
            return nil
        }
        func name(_ key: String) -> String { links[key]?.name ?? home.nodes.first { $0.key == key }?.name ?? key }
    }

    static func symOf(_ node: MemoryHome.Node?, _ issues: [MemoryHome.Issue]) -> (HomeSym, Int) {
        let issue = node.flatMap { node in issues.first { $0.node == node.key && $0.kind != "unclear_telling" } }
        let level = node?.bestLevel ?? node?.level ?? 0
        if issue?.kind == "knowledge_gap" { return (.weak, levelOf(issue?.held) ?? node?.level ?? 2) }
        if issue?.kind == "review_due" { return (.due, max(3, level)) }
        guard let node else { return (.untested, 0) }
        return node.grade != nil ? (.mastered, max(1, level == 0 ? 3 : level)) : (.pending, level)
    }

    static func subOf(_ sym: HomeSym, _ node: MemoryHome.Node?, _ issue: MemoryHome.Issue?) -> (String, HomeTone) {
        switch sym {
        case .weak:
            let held = levelOf(issue?.held) ?? node?.level
            if let held, goalOf(held) > held { return ("\(levelName(held)) · 差 \(goalOf(held) - held) 级", .orange) }
            return ("还不稳定", .orange)
        case .due: return ("该复测 · 上次\(levelName(node?.bestLevel ?? node?.level).isEmpty ? "答到了" : levelName(node?.bestLevel ?? node?.level))", .blue)
        case .mastered:
            let name = levelName(node?.bestLevel ?? node?.level)
            return (name.isEmpty ? (node?.gradeLabel ?? "有结论") : name, .blue)
        case .pending: return ("答过一次 · 还说不准", .soft)
        default: return ("还没问过", .soft)
        }
    }

    static func marks(_ input: HomeInput, weakKeys: Set<String>) -> [HomeMark] {
        var seen: [String: HomeMark] = [:]
        for node in input.home?.nodes ?? [] {
            for ask in node.asks {
                let at = dateOf(ask.date)
                if input.now.timeIntervalSince(at) > 45 * day { continue }
                let tone: HomeTone = weakKeys.contains(node.key) ? .orange : seen[ask.sourceID]?.tone ?? .soft
                seen[ask.sourceID] = HomeMark(id: ask.sourceID, at: at, label: mmdd(at),
                    sub: ask.kind == "real" ? "\(ask.company ?? "")\(ask.stage ?? "面试")" : "模拟面试", tone: tone, future: false)
            }
        }
        let past = seen.values.sorted { $0.at > $1.at }.prefix(4)
        let future = input.sessions
            .filter { $0.status == "scheduled" && $0.startAt > input.now && $0.startAt.timeIntervalSince(input.now) < 21 * day }
            .sorted { $0.startAt < $1.startAt }.prefix(2)
            .map { session -> HomeMark in
                let days = max(0, Int((startOfDay(session.startAt).timeIntervalSince(startOfDay(input.now)) / day).rounded()))
                return HomeMark(id: session.id, at: session.startAt, label: "\(weekdayLabel(session.startAt, input.now)) \(session.company)\(session.stageLabel)",
                                sub: days > 0 ? "还有 \(days) 天" : "就在今天", tone: .blue, future: true)
            }
        return Array(past) + future
    }

    static func uploads(_ input: HomeInput, _ docs: [HomeDataset]) -> [HomeMark] {
        var days: [Date: Int] = [:]
        for doc in docs {
            let at = startOfDay(doc.createdAt)
            if input.now.timeIntervalSince(at) <= 45 * day { days[at, default: 0] += 1 }
        }
        return days.sorted { $0.key > $1.key }.prefix(3).map {
            HomeMark(id: "up:\($0.key.timeIntervalSince1970)", at: $0.key, label: mmdd($0.key), sub: "上传 \($0.value) 份", tone: .soft, future: false)
        }
    }

    static func upcoming(_ input: HomeInput, days: Double) -> HomeSession? {
        input.sessions.filter { $0.status == "scheduled" && $0.startAt > input.now && $0.startAt.timeIntervalSince(input.now) < days * day }
            .min { $0.startAt < $1.startAt }
    }

    static func lastPractice(_ home: MemoryHome) -> Date {
        home.nodes.flatMap(\.asks).map { dateOf($0.date) }.max() ?? Date(timeIntervalSince1970: 0)
    }

    static func resumePlanet(_ input: HomeInput, links: [String], sub: String = "你的简历", tone: HomeTone? = nil) -> [HomePlanet] {
        guard let resume = input.resumes.max(by: { $0.updatedAt < $1.updatedAt }) else { return [] }
        return [HomePlanet(id: "resume:\(resume.id)", label: resume.title.isEmpty ? "你的简历" : resume.title, sub: sub, subTone: tone, links: links, near: false)]
    }

    public static func nonComputing(_ input: HomeInput) -> Bool {
        if let computing = input.home?.targetComputing { return !computing }
        return input.directions.first.map { $0 != "rd" } ?? false
    }

    public static func pick(_ input: HomeInput) -> HomeScene {
        var scene = choose(input)
        scene.mapNote = unaskedNote(input.home, scene.nodes)
        return scene
    }

    static func unaskedNote(_ home: MemoryHome?, _ nodes: [HomeMapNode]) -> String {
        guard let home, let from = home.unaskedFrom, nodes.contains(where: { home.unasked.contains($0.id) }) else { return "" }
        if from.kind == "direction" { return "还没问过的点：「\(from.title)」方向常问的要求" }
        let title = from.title.count > 18 ? String(from.title.prefix(18)) + "…" : from.title
        return "还没问过的点来自\(from.kind == "application" ? "投递" : "岗位")：\(from.company.map { "\($0) · " } ?? "")\(title)"
    }

    static func choose(_ input: HomeInput) -> HomeScene {
        let docs = input.datasets.filter(\.document)
        if input.resumes.isEmpty { return docs.isEmpty ? start(input) : materials(input, docs) }
        guard let home = input.home, home.enabled else { return experience(input) }
        let weak = home.issues.filter { $0.kind == "knowledge_gap" && $0.node != nil }
        let due = home.issues.filter { $0.kind == "review_due" && $0.node != nil }
        if home.nodes.isEmpty && weak.isEmpty {
            return !nonComputing(input) && !home.resumeTechnologies.isEmpty ? resumeScene(input) : experience(input)
        }
        let interview = upcoming(input, days: 7)
        if !weak.isEmpty { return weakScene(input, weak, interview) }
        if !due.isEmpty && input.now.timeIntervalSince(lastPractice(home)) >= 14 * day { return returnScene(input, due) }
        let telling = home.issues.contains { $0.kind == "unclear_telling" }
        if nonComputing(input) && telling && !home.nodes.contains(where: { $0.grade != nil }) { return experience(input) }
        return forming(input)
    }

    static let categoryPoints: [String: (String, [String])] = [
        "rd": ("研发 / 技术", ["数据结构与算法", "数据库", "项目里的技术难点"]),
        "product": ("产品", ["需求分析", "竞品分析", "数据指标"]),
        "design": ("设计", ["作品集讲解", "设计思路", "用户研究"]),
        "operations": ("运营", ["内容策划", "数据复盘", "用户增长"]),
        "marketing": ("市场 / 销售", ["市场分析", "客户沟通", "目标拆解"]),
        "functions": ("职能", ["专业基础", "流程与制度", "细节把控"]),
        "finance": ("财务 / 审计", ["会计准则", "财务分析", "税务与内控"]),
        "hr": ("人力资源", ["招聘与面试", "薪酬绩效", "劳动法规"]),
        "admin": ("行政 / 文秘", ["公文写作", "会务与接待", "流程与制度"]),
        "legal": ("法务", ["合同审查", "公司法务", "合规风控"]),
        "manufacturing": ("生产 / 制造", ["工艺流程", "设备与安全", "问题排查"]),
        "quality": ("质量", ["质量体系", "问题分析", "改进方法"]),
        "supply_chain": ("供应链", ["采购与谈判", "库存与物流", "成本控制"]),
        "banking": ("金融 / 银行证券", ["金融市场", "估值与财报", "风险管理"]),
        "consulting": ("咨询", ["案例分析", "市场估算", "商业框架"]),
        "healthcare": ("医药 / 医疗", ["医学基础", "药品与法规", "临床流程"]),
        "media": ("新闻 / 编辑", ["选题策划", "写作与编辑", "新闻伦理"]),
        "construction": ("建筑 / 土木", ["结构与材料", "施工管理", "造价与规范"]),
        "electronics": ("电子 / 硬件", ["电路基础", "器件选型", "调试与测试"]),
        "civil_service": ("公务员 / 事业单位", ["综合分析", "组织协调", "应急应变"]),
        "teacher": ("教师招聘", ["试讲", "教学设计", "班级管理"]),
        "postgraduate": ("考研复试", ["专业课", "科研经历", "英语口语"]),
    ]

    static func node(_ id: String, _ sym: HomeSym, _ label: String, group: String, parent: String? = nil, sub: String? = nil) -> HomeMapNode {
        HomeMapNode(id: id, sym: sym, label: label, sub: sub, subTone: nil, level: nil, badge: nil, group: group, parent: parent, focus: nil, ask: nil)
    }
    static func treeEdges(_ nodes: [HomeMapNode]) -> [HomeMapEdge] { nodes.compactMap { node in node.parent.map { HomeMapEdge(from: $0, to: node.id, prereq: false) } } }

    static func categoryMap(_ input: HomeInput, planets: [HomePlanet], into scene: inout HomeScene) {
        let category = input.directions.first
        let points = category.flatMap { categoryPoints[$0]?.1 }
        let role = input.targetRole.flatMap { $0.isEmpty ? nil : $0 } ?? category.flatMap { categoryPoints[$0]?.0 }
        var nodes: [HomeMapNode] = [node("g:exp", .anchor, "你的经历", group: "g:exp", sub: "每段经历都会被追问")]
        nodes += facets.map { node("g:exp:\($0.0)", .untested, $0.1, group: "g:exp", parent: "g:exp") }
        nodes.append(node("g:cmp", .anchor, "通用能力", group: "g:cmp", sub: "各行业都会问"))
        nodes += ["沟通协作", "抗压", "学习能力", "主动性"].enumerated().map { node("g:cmp:\($0.offset)", .untested, $0.element, group: "g:cmp", parent: "g:cmp") }
        nodes.append(node("g:job", .anchor, "岗位相关", group: "g:job", sub: points != nil ? "这个方向常问" : "选好方向后出现"))
        nodes += (points ?? ["", "", ""]).enumerated().map { node("g:job:\($0.offset)", .untested, $0.element, group: "g:job", parent: "g:job") }
        scene.nodes = nodes
        scene.edges = treeEdges(nodes)
        scene.planets = planets
        scene.legend = [(.anchor, "类别"), (.untested, "还没问过"), (.mastered, "练后 · 答好了"), (.weak, "练后 · 没打牢")]
        scene.mapTitle = role.map { "\($0) · 面试常问的三类问题" } ?? "面试常问的三类问题"
    }

    static func start(_ input: HomeInput) -> HomeScene {
        var scene = HomeScene(); scene.key = "start"
        categoryMap(input, planets: [HomePlanet(id: "next:resume", label: "你的简历", sub: "第 2 步后出现", subTone: nil, links: ["g:exp"], near: true)], into: &scene)
        scene.marks = [
            HomeMark(id: "next:resume", at: input.now.addingTimeInterval(4 * day), label: "第一份简历", sub: "第 2 步", tone: .blue, future: true),
            HomeMark(id: "next:mock", at: input.now.addingTimeInterval(9 * day), label: "第一场模拟面试", sub: "第 3 步", tone: .blue, future: true),
        ]
        return scene
    }

    static func stem(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    static func materials(_ input: HomeInput, _ docs: [HomeDataset]) -> HomeScene {
        let shown = Array(docs.sorted { $0.createdAt > $1.createdAt }.prefix(4))
        var scene = HomeScene(); scene.key = "materials"
        scene.eyebrow = "资料已整理"
        scene.title = "\(docs.count) 份资料，够写出第一份简历"
        scene.sub = "我先读完它们，把能用的写进简历，缺的再一项项问你；之后练一场，就能看出哪里要补"
        scene.listTitle = "会用到的资料"
        scene.list = shown.map { HomeListItem(id: $0.id, sym: .planet, title: $0.fileName, right: nil, sub: "\(mmdd($0.createdAt)) 上传", badge: nil, level: nil, focus: nil) }
        scene.action = ("写第一份简历", .guide(shown.map(\.id)), "开始", "读完资料先写上纸，缺的再问你")
        scene.secondary = ("或者先补一段经历", .suggest("我想先补一段经历："))
        categoryMap(input, planets: shown.map { HomePlanet(id: "doc:\($0.id)", label: stem($0.fileName), sub: "\(mmdd($0.createdAt)) 上传", subTone: nil, links: [], near: false) }, into: &scene)
        scene.marks = uploads(input, docs) + [HomeMark(id: "next:resume", at: input.now.addingTimeInterval(2 * day), label: "第一份简历", sub: "跟着引导写", tone: .blue, future: true)]
        scene.suggestion = shown.first.map { "帮我把《\(stem($0.fileName))》写成一段经历" } ?? ""
        return scene
    }

    static func shortName(_ label: String, _ top: String) -> String {
        guard label.hasPrefix(top) else { return label }
        let trimmed = label.dropFirst(top.count).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? label : trimmed
    }

    static func resumeScene(_ input: HomeInput) -> HomeScene {
        let home = input.home!, tree = Tree(home)
        let techs = Array(home.resumeTechnologies.prefix(6))
        var nodes: [HomeMapNode] = []
        for (index, tech) in techs.enumerated() {
            nodes.append(node(tech.key, .anchor, tech.name, group: tech.key, sub: "简历写到"))
            for (at, topic) in tech.topics.prefix(index < 3 ? 2 : 1).enumerated() {
                let likely = at == 0 && index < 3
                var item = node(topic, .untested, shortName(tree.name(topic), tech.name), group: tech.key, parent: tech.key, sub: likely ? "最可能被追问" : "还没问过")
                item.subTone = likely ? .ink : .soft
                item.focus = PracticeFocus(kind: "topic", ref: topic, label: tree.name(topic))
                item.ask = "\(tree.name(topic))面试官一般会怎么追问？"
                nodes.append(item)
            }
        }
        let likely = techs.prefix(3).compactMap { tech in tech.topics.first.map { (tech, $0) } }
        var scene = HomeScene(); scene.key = "resume"
        scene.eyebrow = "记忆还是空的"
        scene.title = "简历上的 \(techs.count) 项技术，还没被检验"
        scene.sub = "答过一次它们才会亮起来；先从最可能被追问的 \(likely.count) 处开始"
        scene.listTitle = "最可能被追问"
        scene.list = likely.map { tech, topic in
            HomeListItem(id: topic, sym: .untested, title: tree.name(topic), right: nil, sub: "简历写到 \(tech.name)", badge: nil, level: nil,
                         focus: PracticeFocus(kind: "topic", ref: topic, label: tree.name(topic)))
        }
        scene.action = ("来一场模拟面试，点亮第一批", .mock(likely.first.map { PracticeFocus(kind: "topic", ref: $0.1, label: tree.name($0.1)) }), nil, nil)
        scene.nodes = nodes; scene.edges = treeEdges(nodes)
        scene.planets = resumePlanet(input, links: techs.map(\.key))
        scene.legend = [(.planet, "你的简历"), (.anchor, "简历写的技术"), (.untested, "还没问过")]
        scene.marks = marks(input, weakKeys: [])
        scene.suggestion = likely.first.map { "\(tree.name($0.1))面试官一般会怎么追问？" } ?? ""
        return scene
    }

    static let competencyGroup = "g:cmp"
    static func isCompetency(_ key: String) -> Bool { key.hasPrefix("cmp:") }

    static func competencyNode(_ home: MemoryHome, _ key: String, _ issues: [MemoryHome.Issue], _ badges: [String: Int]) -> HomeMapNode {
        let found = home.competencies.first { $0.key == key }
        let label = found?.name ?? issues.first { $0.node == key }?.name ?? key
        let issue = issues.first { $0.node == key && $0.kind == "knowledge_gap" }
        let sym: HomeSym = issue != nil ? .weak : found?.grade != nil ? .mastered : (found?.coverage ?? 0) > 0 ? .pending : .untested
        let sub = issue != nil ? "还不够稳" : found?.gradeLabel ?? ((found?.coverage ?? 0) > 0 ? "有过表现 · 还说不准" : "还没看出来")
        return HomeMapNode(id: key, sym: sym, label: label, sub: sub, subTone: issue != nil ? .orange : found?.grade != nil ? .blue : .soft,
                           level: 3, badge: badges[key], group: competencyGroup, parent: competencyGroup, focus: issue?.practice, ask: "面试里怎么体现「\(label)」？")
    }

    static func extraKeys(_ home: MemoryHome, _ keys: [String]) -> [String] {
        let competencies = home.competencies.filter { item in item.coverage > 0 || home.issues.contains { $0.node == item.key } }
            .map(\.key).filter { !keys.contains($0) }.prefix(3)
        let unasked = home.unasked.filter { !keys.contains($0) }.prefix(3)
        return keys + unasked + competencies
    }

    static func knowledgeMap(_ home: MemoryHome, _ keys: [String], _ issues: [MemoryHome.Issue], _ badges: [String: Int] = [:]) -> ([HomeMapNode], [HomeMapEdge]) {
        let tree = Tree(home)
        let nodeBy = Dictionary(home.nodes.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var nodes: [HomeMapNode] = [], edges: [HomeMapEdge] = [], has = Set<String>()
        var selfSub: [String: (String, HomeTone)] = [:]
        func add(_ item: HomeMapNode) { if has.insert(item.id).inserted { nodes.append(item) } }
        for key in keys {
            if isCompetency(key) {
                add(node(competencyGroup, .anchor, "通用能力", group: competencyGroup))
                add(competencyNode(home, key, issues, badges))
                edges.append(HomeMapEdge(from: competencyGroup, to: key, prereq: false))
                continue
            }
            let root = tree.top(key), atlas = nodeBy[key], rootName = tree.name(root)
            add(node(root, .anchor, rootName, group: root))
            if root == key {
                let own = symOf(atlas, issues)
                selfSub[root] = subOf(own.0, atlas, issues.first { $0.node == key })
                continue
            }
            var parent = root
            if let between = tree.mid(key), between != key {
                add(node(between, .topic, shortName(tree.name(between), rootName), group: root, parent: root))
                if !edges.contains(where: { $0.to == between }) { edges.append(HomeMapEdge(from: root, to: between, prereq: false)) }
                parent = between
            }
            let issue = issues.first { $0.node == key }
            let (sym, level) = symOf(atlas, issues)
            let (sub, tone) = subOf(sym, atlas, issue)
            add(HomeMapNode(id: key, sym: sym, label: shortName(tree.name(key), rootName), sub: sub, subTone: tone, level: level, badge: badges[key],
                            group: root, parent: parent, focus: PracticeFocus(kind: "topic", ref: key, label: tree.name(key)), ask: "「\(tree.name(key))」我上次答到哪了，怎么补？"))
            edges.append(HomeMapEdge(from: parent, to: key, prereq: false))
        }
        for edge in home.edges where has.contains(edge.src) && has.contains(edge.dst) { edges.append(HomeMapEdge(from: edge.src, to: edge.dst, prereq: true)) }
        for index in nodes.indices where nodes[index].sym == .anchor {
            let id = nodes[index].id
            let members = nodes.filter { $0.group == id && $0.sym != .anchor && $0.sym != .topic }
            let weak = members.filter { $0.sym == .weak }.count
            let pending = members.filter { $0.sym == .pending }.count
            let graded = members.filter { $0.sym == .mastered || $0.sym == .due }.count
            let untested = members.filter { $0.sym == .untested }.count
            if members.isEmpty, let own = selfSub[id] { nodes[index].sub = own.0; nodes[index].subTone = own.1; continue }
            nodes[index].sub = weak > 0 ? "\(members.count) 个点 · \(weak) 处没打牢"
                : pending > 0 ? "\(graded) 个有结论 · \(pending) 个待定"
                : untested == members.count && !members.isEmpty ? "\(members.count) 个点 · 还没问过"
                : untested > 0 ? "\(graded) 个达到要求 · \(untested) 个还没问过"
                : !members.isEmpty ? "\(members.count) 个点 · 都达到要求" : nil
            nodes[index].subTone = weak > 0 ? .orange : .soft
        }
        return (nodes, edges)
    }

    static func pickKeys(_ home: MemoryHome, _ first: [String], limit: Int = 14) -> [String] {
        let tree = Tree(home)
        var keys = first
        var roots = Set(first.map(tree.top))
        for node in home.nodes {
            if keys.count >= limit { break }
            let root = tree.top(node.key)
            if keys.contains(node.key) || (!roots.contains(root) && roots.count >= 4) { continue }
            roots.insert(root); keys.append(node.key)
        }
        return keys
    }

    static func weakScene(_ input: HomeInput, _ weak: [MemoryHome.Issue], _ interview: HomeSession?) -> HomeScene {
        let home = input.home!, tree = Tree(home)
        let shown = Array(weak.prefix(3))
        let firstNode = shown[0].node!
        let area = tree.mid(firstNode) ?? tree.top(firstNode)
        let neighbors = (home.neighbors[firstNode] ?? []).filter { key in !shown.contains { $0.node == key } }
        let badges = Dictionary(shown.enumerated().map { ($0.element.node!, $0.offset + 1) }, uniquingKeysWith: { a, _ in a })
        let keys = extraKeys(home, pickKeys(home, shown.map { $0.node! } + neighbors))
        let (nodes, edges) = knowledgeMap(home, keys, home.issues, badges)
        let regionMembers = nodes.filter { $0.id == area || (tree.mid($0.id) == area && $0.sym != .anchor) }.map(\.id)
        let held = levelOf(shown[0].held)
        var scene = HomeScene(); scene.key = interview != nil ? "prep" : "weak"
        if let interview { scene.eyebrow = "\(weekdayLabel(interview.startAt, input.now))\(interview.company)\(interview.stageLabel.isEmpty ? "面试" : interview.stageLabel)前" }
        else { scene.eyebrow = "先补这几处" }
        scene.eyebrowTone = .orange
        scene.title = isCompetency(firstNode) ? "「\(shown[0].name)」还不够稳" : "\(tree.name(area))没打牢"
        scene.sub = held.map { "最近几次都停在「\(levelName($0))」，再往下追问就讲不出" } ?? shown[0].statement
        scene.listTitle = "先补这\(countZh(shown.count))处"
        scene.list = shown.enumerated().map { index, item in
            let level = levelOf(item.held) ?? home.nodes.first { $0.key == item.node }?.level
            return HomeListItem(id: item.key, sym: .weak, title: item.name, right: level.map { "\(levelName($0)) → \(nextName($0))" },
                                sub: item.cause.flatMap { causeShort[$0] } ?? (level.map { "追问到「\(nextName($0))」时讲不出" } ?? "最近的练习里还不稳定"),
                                badge: index + 1, level: nil, focus: item.practice)
        }
        scene.action = ("从 ① 开始练", .mock(shown[0].practice), nil, nil)
        scene.nodes = nodes; scene.edges = edges
        scene.region = regionMembers.count > 1 ? HomeRegion(members: regionMembers, title: "没打牢 · \(shortName(tree.name(area), tree.name(tree.top(area))))") : nil
        scene.planets = resumePlanet(input, links: [firstNode])
        scene.legend = [(.mastered, "掌握"), (.weak, "没打牢"), (.untested, "没问过"), (.planet, "你的简历")]
        scene.marks = marks(input, weakKeys: Set(weak.compactMap(\.node)))
        scene.suggestion = neighbors.first.map { "\(shown[0].name)和\(tree.name($0))有什么关系？" } ?? "\(shown[0].name)面试一般会怎么追问？"
        scene.disclose = shown.map(\.key)
        return scene
    }

    static func returnScene(_ input: HomeInput, _ due: [MemoryHome.Issue]) -> HomeScene {
        let home = input.home!
        let shown = Array(due.prefix(3))
        let (nodes, edges) = knowledgeMap(home, extraKeys(home, pickKeys(home, shown.map { $0.node! })), home.issues)
        let days = Int((input.now.timeIntervalSince(lastPractice(home)) / day).rounded())
        let recent = home.nodes.filter { node in node.grade != nil && node.lastDate.map { input.now.timeIntervalSince(dateOf($0)) < 30 * day } == true }.count
        var scene = HomeScene(); scene.key = "return"
        scene.eyebrow = days >= 28 ? "一个月没练了" : "两周没练了"
        scene.title = "\(shown.count) 个点该复测了"
        scene.sub = "上次都答到了，隔久了容易忘\(recent > 0 ? "；这个月一共亮起 \(recent) 个点" : "")"
        scene.listTitle = "该复测"
        scene.list = shown.map { item in
            let node = home.nodes.first { $0.key == item.node }
            let name = levelName(node?.bestLevel ?? node?.level)
            return HomeListItem(id: item.key, sym: .due, title: item.name, right: nil,
                                sub: "上次 \(item.date.map { mmdd(dateOf($0)) } ?? "较早") 答到「\(name.isEmpty ? "掌握" : name)」", badge: nil, level: nil, focus: item.practice)
        }
        scene.action = ("复测这 \(shown.count) 个点", .mock(shown[0].practice), nil, nil)
        scene.nodes = nodes; scene.edges = edges
        scene.planets = resumePlanet(input, links: Array(shown.compactMap(\.node).prefix(2)))
        scene.legend = [(.mastered, "掌握（越大越深）"), (.due, "该复测"), (.planet, "你的简历")]
        scene.marks = withNext(input, marks(input, weakKeys: []))
        scene.suggestion = "帮我出 3 道\(shown[0].name)的复测题"
        scene.disclose = shown.map(\.key)
        return scene
    }

    static func withNext(_ input: HomeInput, _ found: [HomeMark]) -> [HomeMark] {
        if found.contains(where: \.future) { return found }
        return found + [HomeMark(id: "next:none", at: input.now.addingTimeInterval(8 * day), label: "还没有下一场", sub: "去面试日程加一场", tone: .soft, future: true)]
    }

    static func isUnder(_ home: MemoryHome, _ key: String, _ tech: String) -> Bool {
        let links = Tree(home).links
        var at: String? = key
        for _ in 0..<8 { guard let current = at else { return false }; if current == tech { return true }; at = links[current]?.parent }
        return false
    }

    static func withResumeTechs(_ home: MemoryHome, _ map: ([HomeMapNode], [HomeMapEdge])) -> ([HomeMapNode], [HomeMapEdge], [String]) {
        let tree = Tree(home)
        var nodes = map.0, edges = map.1
        var known = Set(nodes.map(\.id))
        let asked = Set(home.nodes.map(\.key))
        var added: [String] = []
        for tech in home.resumeTechnologies {
            let onMap = known.contains(tech.key)
            if !onMap && home.nodes.contains(where: { isUnder(home, $0.key, tech.key) }) { continue }
            if !onMap && added.count >= 2 { continue }
            let topics = tech.topics.filter { !asked.contains($0) && !known.contains($0) }.prefix(onMap ? 2 : 1)
            if !onMap {
                nodes.append(node(tech.key, .anchor, tech.name, group: tech.key, sub: "简历写到"))
                known.insert(tech.key); added.append(tech.key)
            }
            for topic in topics {
                var item = node(topic, .untested, shortName(tree.name(topic), tech.name), group: tech.key, parent: tech.key, sub: "还没问过")
                item.subTone = .soft
                item.focus = PracticeFocus(kind: "topic", ref: topic, label: tree.name(topic))
                item.ask = "\(tree.name(topic))面试官一般会怎么追问？"
                nodes.append(item); known.insert(topic)
                edges.append(HomeMapEdge(from: tech.key, to: topic, prereq: false))
            }
        }
        return (nodes, edges, added)
    }

    static func coverage(_ home: MemoryHome) -> String {
        var parts: [String] = []
        let techs = home.resumeTechnologies
        if !techs.isEmpty { parts.append("简历技术问到 \(techs.filter { tech in home.nodes.contains { isUnder(home, $0.key, tech.key) } }.count)/\(techs.count)") }
        if !home.experiences.isEmpty { parts.append("经历讲过 \(home.experiences.filter(\.told).count)/\(home.experiences.count)") }
        return parts.joined(separator: " · ")
    }

    static func forming(_ input: HomeInput) -> HomeScene {
        let home = input.home!
        let graded = home.nodes.filter { $0.grade != nil }
        let pending = home.nodes.filter { $0.grade == nil }
        let due = home.issues.filter { $0.kind == "review_due" && $0.node != nil }
        let answered = knowledgeMap(home, extraKeys(home, pickKeys(home, pending.prefix(4).map(\.key))), home.issues)
        let (nodes, edges, techs) = withResumeTechs(home, answered)
        let done = pending.isEmpty
        var scene = HomeScene(); scene.key = "forming"
        scene.eyebrow = done ? "记忆已经成形" : "记忆正在形成"
        scene.title = done ? "答过的 \(home.nodes.count) 个知识点都有了结论" : "答过 \(home.nodes.count) 个知识点，\(graded.count) 个有了结论"
        scene.sub = done ? (!due.isEmpty ? "\(due.count) 个点之后该复测；想更稳可以挑一处再往深练" : "都达到要求了；想更稳可以挑一处再往深练")
            : "另外 \(pending.count) 个只答过一次，还说不准；下一场会先把它们问清"
        scene.listTitle = done ? (!due.isEmpty ? "之后该复测" : "") : "下一场先问清"
        scene.list = done
            ? due.prefix(3).map { HomeListItem(id: $0.key, sym: .due, title: $0.name, right: nil, sub: "上次 \($0.date.map { mmdd(dateOf($0)) } ?? "较早") 问到", badge: nil, level: nil, focus: $0.practice) }
            : pending.prefix(4).map { node in
                HomeListItem(id: node.key, sym: .pending, title: node.name, right: nil,
                             sub: node.level.map { "答到「\(levelName($0))」，只答过一次" } ?? "只答过一次", badge: nil, level: nil,
                             focus: PracticeFocus(kind: "topic", ref: node.key, label: node.name))
            }
        let focus = pending.first.map { PracticeFocus(kind: "topic", ref: $0.key, label: $0.name) } ?? due.first?.practice
        scene.action = (done ? "再练一场，往深里问" : "再练一场，把它们问清", .mock(focus), nil, nil)
        scene.nodes = nodes; scene.edges = edges
        scene.mapTitle = coverage(home)
        scene.planets = resumePlanet(input, links: pending.prefix(1).map(\.key) + techs)
        scene.legend = [(.mastered, "有结论（越大越深）"), (.pending, "答过、还说不准"), (.untested, "没问过"), (.anchor, "技术"), (.planet, "你的简历")]
        scene.marks = marks(input, weakKeys: [])
        scene.suggestion = pending.first.map { "我上次\($0.name)答到哪了？" } ?? graded.first.map { "\($0.name)还能往哪里深挖？" } ?? ""
        scene.disclose = done ? due.prefix(3).map(\.key) : []
        return scene
    }

    static func experience(_ input: HomeInput) -> HomeScene {
        let home = input.home
        let experiences = Array((home?.experiences ?? []).prefix(3))
        var scene = HomeScene(); scene.key = "experience"
        if experiences.isEmpty {
            scene.eyebrow = "记忆还是空的"
            scene.title = "简历已经有了，还没在面试里讲过"
            scene.sub = "练一场模拟面试，就能看出哪段经历讲得清、哪里要补"
            scene.action = ("来一场模拟面试", .mock(nil), nil, nil)
            categoryMap(input, planets: resumePlanet(input, links: ["g:exp"]), into: &scene)
            scene.marks = marks(input, weakKeys: [])
            scene.suggestion = "我的简历里哪段经历最容易被追问？"
            return scene
        }
        let telling = (home?.issues ?? []).filter { $0.kind == "unclear_telling" }
        let badges = Dictionary(telling.prefix(3).enumerated().map { ($0.element.key, $0.offset + 1) }, uniquingKeysWith: { a, _ in a })
        var nodes: [HomeMapNode] = []
        for item in experiences {
            let gaps = item.gaps
            var anchor = node(item.key, .anchor, item.title, group: item.key,
                              sub: !gaps.isEmpty ? "\(facets.count) 个要素 · 缺 \(gaps.count) 个" : item.told ? "讲清楚了" : "还没练过")
            anchor.subTone = gaps.isEmpty ? .soft : .orange
            anchor.focus = item.practice
            nodes.append(anchor)
            var list = facets
            for gap in gaps { if let facet = gap.facet, !list.contains(where: { $0.0 == facet }) { list[1] = (facet, gap.element ?? facet) } }
            for (facet, label) in list {
                let gap = gaps.first { $0.facet == facet }
                nodes.append(HomeMapNode(id: "\(item.key):\(facet)", sym: gap != nil ? .weak : item.told ? .mastered : .untested,
                    label: gap?.element ?? label, sub: gap != nil ? "还没讲清楚" : item.told ? "讲清楚了" : "还没讲过",
                    subTone: gap != nil ? .orange : item.told ? .blue : .soft, level: 3, badge: gap.flatMap { badges[$0.issue] },
                    group: item.key, parent: item.key, focus: item.practice, ask: "\(item.title)的\(gap?.element ?? label)该怎么讲？"))
            }
        }
        let first = telling.first
        let firstExp = experiences.first { $0.key == first?.experience }
        let untold = experiences.filter { !$0.told }
        var listed = telling.prefix(3).map { HomeListItem(id: $0.key, sym: .weak, title: "\($0.name) · \($0.element ?? "")", right: nil, sub: $0.statement, badge: nil, level: nil, focus: $0.practice) }
            + untold.map { HomeListItem(id: $0.key, sym: .untested, title: $0.title, right: nil, sub: "还没练过怎么讲", badge: nil, level: nil, focus: $0.practice) }
        listed = Array(listed.prefix(3))
        if first != nil { listed = listed.enumerated().map { HomeListItem(id: $0.element.id, sym: $0.element.sym, title: $0.element.title, right: nil, sub: $0.element.sub, badge: $0.offset + 1, level: nil, focus: $0.element.focus) } }
        scene.eyebrow = "你的经历记忆"
        scene.eyebrowTone = first != nil ? .orange : .blue
        scene.title = first.map { "「\($0.name)」这段还讲不完整" } ?? (!untold.isEmpty ? "\(untold.count) 段经历，还没在面试里讲过" : "\(experiences.count) 段经历都讲清楚了")
        scene.sub = first.map { "面试官问到\($0.element ?? "细节")时，还没讲清楚" } ?? (!untold.isEmpty ? "讲过一次就知道哪里要补" : "想更稳可以换个角度再讲一遍")
        scene.listTitle = first != nil ? "先补这\(countZh(listed.count))处" : !untold.isEmpty ? "还没讲过" : ""
        scene.list = listed
        scene.action = (first.map { "练讲「\($0.name)」" } ?? "来一场模拟面试", .mock(first?.practice ?? untold.first?.practice), nil, nil)
        scene.nodes = nodes; scene.edges = treeEdges(nodes)
        scene.region = firstExp.map { exp in HomeRegion(members: nodes.filter { $0.group == exp.key }.map(\.id), title: "讲不完整 · \(exp.title)") }
        scene.planets = resumePlanet(input, links: experiences.map(\.key))
        scene.legend = [(.mastered, "讲清楚了"), (.weak, "缺了 / 偏弱"), (.untested, "没讲过"), (.planet, "你的简历")]
        scene.marks = marks(input, weakKeys: [])
        scene.suggestion = first.map { "\($0.name)的\($0.element ?? "这段")该怎么讲才有说服力？" } ?? "\(experiences[0].title)面试官会怎么追问？"
        scene.disclose = telling.prefix(3).map(\.key)
        return scene
    }
}
