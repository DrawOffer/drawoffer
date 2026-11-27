import Foundation

/// 工作区首页（Web `assistant/home/HomeMemory.tsx`，macOS 设计稿 02A 页）：读 `GET /api/memory/home/graph`，
/// 按“有没有简历、练过几场、有没有结论”选 01 新用户 / 03 练第一场 / 07 有记忆三种首页。
public struct HomeGraph: Sendable, Equatable {
    public enum Status: String, Sendable { case top, good, ok, weak, none }
    public enum Kind: String, Sendable { case experience, highlight, technology, point, session }

    public struct Node: Sendable, Equatable, Identifiable {
        public let id: String
        public let kind: Kind
        public let name: String
        public let status: Status
        public let overstated: Bool
        public let changedUp: Bool
        /// 面试或练习问到过：status 为 none 时区分“问过，还说不准”和“还没问到”
        public let asked: Bool
        /// 经历节点（highlight）是服务的业务（business）还是做成的事（work）
        public let facet: String?
        public let size: Double

        /// 图上的分类（Web `stageNodeOf`）：橙色只给还不牢或写高了的，蓝色给刚练稳的；场次一律墨色。
        public enum Tone: Sendable { case plain, hot, new }
        public var tone: Tone {
            if kind == .session { return .plain }
            if status == .weak || overstated { return .hot }
            return changedUp ? .new : .plain
        }
        public var label: String { name.components(separatedBy: "（").first ?? name }
        /// 服务的业务：名字前带一个小方块
        public var business: Bool { kind == .highlight && facet == "business" }
        /// 掌握情况的一句话（Web `describe` 的 held）
        public var held: String {
            switch status {
            case .top: "答得很稳"
            case .good: "答得不错"
            case .ok: "答到了基础"
            case .weak: "还不牢"
            case .none: asked ? "问过，还说不准" : "还没问到"
            }
        }
        /// 「聊一聊」对话里挂着的状态（Web `describe` 的 state）
        public var chatState: String {
            switch kind {
            case .experience: return ""
            case .session: return "这一场"
            case .highlight: return business ? "服务的业务" : "做成的事"
            case .technology, .point:
                if overstated { return "写高了" }
                if kind == .technology { return status == .none ? "" : held }
                if changedUp && status != .weak { return "刚练稳" }
                return held
            }
        }
        /// 图上的短名：汉字算 2、字母数字算 1，经历和场次放宽到 20，其余 16；经历放不下就只留公司。
        public var short: String {
            func units(_ c: Character) -> Int { c.unicodeScalars.allSatisfy { $0.value < 0x250 } ? 1 : 2 }
            func width(_ s: String) -> Int { s.reduce(0) { $0 + units($1) } }
            func clip(_ s: String, _ limit: Int) -> String {
                var used = 0, out = ""
                for c in s { used += units(c); if used > limit { return out.trimmingCharacters(in: .whitespaces) + "…" }; out.append(c) }
                return s
            }
            let base = name.components(separatedBy: "（").first ?? name
            switch kind {
            case .experience: return width(base) <= 20 ? base : clip(base.components(separatedBy: " · ").first ?? base, 16)
            case .session: return clip(base, 20)
            default: return clip(base, 16)
            }
        }
    }

    public struct Edge: Sendable, Equatable { public let src: String; public let dst: String; public let kind: String }
    public struct Pick: Sendable, Equatable { public let key: String; public let name: String; public let experiences: Int }

    /// 最近进展的一条（Web `HomeGraphProgress`）。
    public struct Progress: Sendable, Equatable, Identifiable {
        public enum Source: String, Sendable { case mock, real, resume }
        public enum Tone: String, Sendable { case up, weak, info }
        public let kind: Source
        public let date: String
        public let source: String
        public let sourceID: String
        public let tone: Tone
        public let name: String?
        public let before: String?
        public let after: String?
        public let asked: Int
        public let missed: Int
        public let practiceLabel: String?
        public let practiceRef: String?
        public let practiceKind: String?
        /// 练经历时从哪个延伸点开始、经历在哪份简历（Web `HomeGraphFocus.hook / resume_id`）
        public var practiceHook: String? = nil
        public var practiceResumeID: String? = nil
        public var id: String { "\(kind.rawValue):\(sourceID)" }
    }

    public struct Entries: Sendable, Equatable {
        public var interviewCount = 0, interviewCompany: String?, interviewStage: String?, interviewStart: String?
        public var mockCount = 0, mockLastScore: Double?, mockLastID: String?
        public var applicationsOpen = 0, applicationsAwaiting = 0
        public var jobsSaved = 0
        public var datasets = 0
    }

    public let resumeID: String?
    public let resumeTitle: String
    public let topics: [String]
    public let nodes: [Node]
    public let edges: [Edge]
    public let hasConclusions: Bool
    public let points: Int
    public let weakPoints: Int
    public let strongest: Pick?
    public let weakest: Pick?
    public let timeline: [Progress]
    public let today: String
    public let entries: Entries?
    public let sources: (resumes: Int, mocks: Int, interviews: Int)

    public static func == (lhs: HomeGraph, rhs: HomeGraph) -> Bool {
        lhs.resumeID == rhs.resumeID && lhs.nodes == rhs.nodes && lhs.edges == rhs.edges && lhs.timeline == rhs.timeline && lhs.entries == rhs.entries
    }

    public init(json: JSONValue) {
        func int(_ value: JSONValue?) -> Int { Int(value?.numberValue ?? 0) }
        func opt(_ value: JSONValue?) -> String? { value?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        let resume = json["resume"]
        resumeID = resume.flatMap { opt($0["id"]) }
        resumeTitle = resume?.text("title") ?? ""
        // 练之前的面试纸先按经历出两道题：项目、工作、实习、校园依次取
        let order = ["project", "work", "internship", "campus"]
        topics = (json["groups"]?.items ?? [])
            .filter { order.contains($0.text("kind")) }
            .sorted { (order.firstIndex(of: $0.text("kind")) ?? 9) < (order.firstIndex(of: $1.text("kind")) ?? 9) }
            .flatMap { $0["items"]?.items ?? [] }.map { $0.text("title") }.filter { !$0.isEmpty }
        nodes = (json["graph"]?["nodes"]?.items ?? []).compactMap { item in
            guard let kind = Kind(rawValue: item.text("kind")), !item.text("key").isEmpty else { return nil }
            return Node(id: item.text("key"), kind: kind, name: item.text("name"), status: Status(rawValue: item.text("status")) ?? .none,
                        overstated: item.text("flag") == "overstated", changedUp: item.text("changed") == "up",
                        asked: item["asked"]?.bool == true, facet: opt(item["facet"]), size: item["size"]?.numberValue ?? 0)
        }
        edges = (json["graph"]?["edges"]?.items ?? []).map { Edge(src: $0.text("src"), dst: $0.text("dst"), kind: $0.text("kind")) }
        hasConclusions = json["has_conclusions"]?.bool == true
        points = int(json["points"])
        weakPoints = int(json["weak_points"])
        func pick(_ value: JSONValue?) -> Pick? {
            value.flatMap { $0.text("key").isEmpty ? nil : Pick(key: $0.text("key"), name: $0.text("name"), experiences: int($0["experiences"])) }
        }
        strongest = pick(json["strongest"])
        weakest = pick(json["weakest"])
        timeline = (json["timeline"]?.items ?? []).compactMap { item in
            guard let kind = Progress.Source(rawValue: item.text("kind")) else { return nil }
            let practice = item["practice"]
            var progress = Progress(kind: kind, date: item.text("date"), source: item.text("source"), sourceID: item.text("source_id"),
                            tone: Progress.Tone(rawValue: item.text("tone")) ?? .info, name: opt(item["name"]), before: opt(item["before"]), after: opt(item["after"]),
                            asked: int(item["asked"]), missed: int(item["missed"]),
                            practiceLabel: practice.flatMap { opt($0["label"]) }, practiceRef: practice.flatMap { opt($0["ref"]) }, practiceKind: practice.flatMap { opt($0["kind"]) })
            progress.practiceHook = practice.flatMap { opt($0["hook"]) }
            progress.practiceResumeID = practice.flatMap { opt($0["resume_id"]) }
            return progress
        }
        today = json.text("today")
        entries = json["entries"].map { value in
            var entries = Entries()
            entries.interviewCount = int(value["interview"]?["count"])
            entries.interviewCompany = value["interview"].flatMap { opt($0["company"]) }
            entries.interviewStage = value["interview"].flatMap { opt($0["stage"]) }
            entries.interviewStart = value["interview"].flatMap { opt($0["start_at"]) }
            entries.mockCount = int(value["mock"]?["count"])
            entries.mockLastScore = value["mock"]?["last_score"]?.numberValue
            entries.mockLastID = value["mock"].flatMap { opt($0["last_id"]) }
            entries.applicationsOpen = int(value["applications"]?["open"])
            entries.applicationsAwaiting = int(value["applications"]?["awaiting_result"])
            entries.jobsSaved = int(value["jobs"]?["saved"])
            entries.datasets = int(value["datasets"]?["count"])
            return entries
        }
        sources = (int(json["sources"]?["resumes"]), int(json["sources"]?["mocks"]), int(json["sources"]?["interviews"]))
    }
}

/// 已经完成或正在出报告的模拟面试（Web `readMockProgress`）：不含放弃和准备失败的场次，最近的在前。
public struct HomeMockProgress: Sendable, Equatable {
    public let count: Int
    public let firstID: String?
    public let firstStatus: String?
    public let firstFinishedAt: Date?
    public var none: Bool { count == 0 }

    public init(json: JSONValue) {
        let counted: Set<String> = ["in_progress", "evaluating", "evaluation_failed", "completed"]
        let items = (json["items"]?.items ?? []).filter { counted.contains($0.text("status")) }
        count = items.count
        let first = items.count == 1 ? items[0] : nil
        firstID = first?.text("id")
        firstStatus = first?.text("status")
        firstFinishedAt = first.flatMap { HomeStage.parseDate($0.text("finished_at")) }
    }
}

/// 首页选哪一屏（Web `HomeMemory` + `pickFirstSteps`）：新手阶段（03 / 06）属于新手引导，跟管理端开关走，关着时有简历一律是日常首页。
public enum HomeStage: Equatable, Sendable {
    public enum FirstSteps: String, Sendable { case start, ongoing, evaluating, failed, report }
    /// 01：没有简历
    case newUser
    /// 03 / 06：有简历、第一份报告看完之前
    case firstSteps(FirstSteps)
    /// 07：日常首页；缺图谱节点或最近进展时只换对应那一块
    case feedback

    /// 只给这套首页上线之后才练完第一场的人看“第一份报告好了”。
    static let firstReportSince = parseDate("2026-11-14T00:00:00+08:00")!

    public static func pick(graph: HomeGraph, mocks: HomeMockProgress?, reportSeen: Bool, guideOn: Bool) -> HomeStage {
        guard graph.resumeID != nil else { return .newUser }
        if guideOn, let mocks, let steps = firstSteps(mocks, hasConclusions: graph.hasConclusions, reportSeen: reportSeen) { return .firstSteps(steps) }
        return .feedback
    }

    static func firstSteps(_ mocks: HomeMockProgress, hasConclusions: Bool, reportSeen: Bool) -> FirstSteps? {
        if mocks.none { return hasConclusions ? nil : .start }
        guard mocks.count == 1 else { return nil }
        let mode: FirstSteps? = switch mocks.firstStatus {
        case "in_progress": .ongoing
        case "evaluating": .evaluating
        case "evaluation_failed": .failed
        case "completed": .report
        default: nil
        }
        guard mode == .report else { return mode }
        guard let finished = mocks.firstFinishedAt else { return nil }
        return reportSeen || finished < firstReportSince ? nil : .report
    }

    static func parseDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

// MARK: 最近进展的文字（Web `progressText` / `whenOf`）

public enum HomeProgressText {
    public struct Text: Equatable, Sendable {
        /// 两行标题，每行是（前、重点词、后）；重点词上色
        public let lines: [(String, String, String)]
        public let weak: Bool
        public let short: String
        public let desc: String
        public static func == (lhs: Text, rhs: Text) -> Bool {
            lhs.short == rhs.short && lhs.desc == rhs.desc && lhs.weak == rhs.weak && lhs.lines.map { [$0.0, $0.1, $0.2] } == rhs.lines.map { [$0.0, $0.1, $0.2] }
        }
    }

    public static func text(_ item: HomeGraph.Progress, weakPoints: Int, hasConclusions: Bool) -> Text {
        let left = !hasConclusions ? "多练几场，这里会说得更准。" : weakPoints > 0 ? "还有 \(weakPoints) 个不牢。" : "图上没有还不牢的了。"
        if item.kind == .resume {
            return Text(lines: [("简历有更新", "", ""), ("", "图谱跟着重读了", "")], weak: false,
                        short: "更新了《\(item.name ?? "")》", desc: "简历里写的技术和经历都已经记进图谱。" + left)
        }
        if item.tone == .up, let name = item.name, let after = item.after {
            return Text(lines: [(name, "", ""), (item.before.map { "从\($0)练到了" } ?? "这次答到了", after, "")], weak: false,
                        short: item.before.map { "\(name)从\($0)练到了\(after)" } ?? "\(name)答到了\(after)",
                        desc: "这一场问到 \(item.asked) 处。" + left)
        }
        if item.tone == .weak, let name = item.name {
            return Text(lines: [(name, "没答好", ""), ("已排进下一次练习", "", "")], weak: true,
                        short: "\(name)没答好，已排进下一次练习", desc: "这一场问到 \(item.asked) 处，\(item.missed) 处没答好。")
        }
        return Text(lines: [("这一场问到 \(item.asked) 处", "", ""), ("", "都记进了图谱", "")], weak: false,
                    short: "问到 \(item.asked) 处，都记进了图谱", desc: left)
    }

    /// 相对今天：今天、昨天、几天前，一周以上写月-日。
    public static func when(_ date: String, today: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: String(date.prefix(10))) else { return String(date.dropFirst(5)) }
        let now = formatter.date(from: String(today.prefix(10))) ?? Date()
        let days = Int((now.timeIntervalSince(day) / 86_400).rounded())
        if days < 0 { return String(date.prefix(10).dropFirst(5)) }
        if days == 0 { return "今天" }
        if days == 1 { return "昨天" }
        return days <= 7 ? "\(days) 天前" : String(date.prefix(10).dropFirst(5))
    }
}

// MARK: 最近进展为空时的结论（Web `summaryOf`，00 分区 R2）

public struct HomeSummary: Equatable, Sendable {
    public let eyebrow: String
    public let title: [String]
    public let desc: String

    /// 夹在一句话里的名字太长时截断，免得一行字超出左栏
    static func clip(_ name: String, _ limit: Int) -> String { name.count > limit ? String(name.prefix(limit - 1)) + "…" : name }

    /// 最稳、最该补的一处；还没有结论时只说接着练。两行之间不加标点。
    public static func of(_ graph: HomeGraph) -> HomeSummary {
        let mocks = graph.sources.mocks
        guard graph.hasConclusions else {
            return HomeSummary(eyebrow: mocks > 0 ? "练过 \(mocks) 场模拟面试" : "长期记忆",
                               title: mocks > 0 ? ["练过的都记在这里", "接着练下一处"] : ["练一场模拟面试", "记忆从这里开始"],
                               desc: "每练一场，答得好和卡住的地方都会记进图谱。")
        }
        let strong = graph.strongest.map { clip(KnowledgeGraph.shortName($0.name), 12) } ?? ""
        let weak = graph.weakest.map { clip(KnowledgeGraph.shortName($0.name), 12) } ?? ""
        let title = !strong.isEmpty && !weak.isEmpty ? ["\(strong) 答得很稳", "\(weak) 还要再练"]
            : !weak.isEmpty ? ["\(weak) 还要再练", "先把它补上"]
            : !strong.isEmpty ? ["\(strong) 答得很稳", "接着练下一处"]
            : ["练过的都记在这里", "接着练下一处"]
        let uses = graph.weakest?.experiences ?? 0
        let desc = weak.isEmpty ? "再练一场，这里会记得更清楚。" : uses > 1 ? "\(uses) 段经历都用到 \(weak)，先补它最划算。" : "\(weak) 最该补，先练它最划算。"
        return HomeSummary(eyebrow: mocks > 0 ? "最近 \(mocks) 场模拟面试的结论" : "长期记忆的结论", title: title, desc: desc)
    }
}
