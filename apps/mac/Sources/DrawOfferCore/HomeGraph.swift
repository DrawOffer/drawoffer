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
        public let size: Double

        /// 图上的分类（Web `stageNodeOf`）：橙色只给还不牢或写高了的，蓝色给刚练稳的；场次一律墨色。
        public enum Tone: Sendable { case plain, hot, new }
        public var tone: Tone {
            if kind == .session { return .plain }
            if status == .weak || overstated { return .hot }
            return changedUp ? .new : .plain
        }
        public var label: String {
            let base = name.components(separatedBy: "（").first ?? name
            return kind == .highlight ? "“\(base)”" : base
        }
        /// 首页右栏只画经历、技术和问到过的知识点；展开后全画。
        public var onHome: Bool { kind == .experience || kind == .technology || (kind == .point && status != .none) }
        /// 图上的短名：汉字算 2、字母数字算 1，经历放宽到 20，其余 16；经历放不下就只留公司。
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
            case .highlight: return "“\(clip(base, 16))”"
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
        public var id: String { "\(kind.rawValue):\(sourceID)" }
    }

    public struct Entries: Sendable, Equatable {
        public var interviewCount = 0, interviewCompany: String?, interviewStage: String?, interviewStart: String?
        public var mockCount = 0, mockLastScore: Double?
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
                        overstated: item.text("flag") == "overstated", changedUp: item.text("changed") == "up", size: item["size"]?.numberValue ?? 1)
        }
        edges = (json["graph"]?["edges"]?.items ?? []).map { Edge(src: $0.text("src"), dst: $0.text("dst"), kind: $0.text("kind")) }
        hasConclusions = json["has_conclusions"]?.bool == true
        points = int(json["points"])
        weakPoints = int(json["weak_points"])
        weakest = json["weakest"].flatMap { value in
            value.text("key").isEmpty ? nil : Pick(key: value.text("key"), name: value.text("name"), experiences: int(value["experiences"]))
        }
        timeline = (json["timeline"]?.items ?? []).compactMap { item in
            guard let kind = Progress.Source(rawValue: item.text("kind")) else { return nil }
            let practice = item["practice"]
            return Progress(kind: kind, date: item.text("date"), source: item.text("source"), sourceID: item.text("source_id"),
                            tone: Progress.Tone(rawValue: item.text("tone")) ?? .info, name: opt(item["name"]), before: opt(item["before"]), after: opt(item["after"]),
                            asked: int(item["asked"]), missed: int(item["missed"]),
                            practiceLabel: practice.flatMap { opt($0["label"]) }, practiceRef: practice.flatMap { opt($0["ref"]) }, practiceKind: practice.flatMap { opt($0["kind"]) })
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

/// 首页选哪一屏（Web `HomeMemory` + `pickFirstSteps`）。
public enum HomeStage: Equatable, Sendable {
    public enum FirstSteps: String, Sendable { case start, ongoing, evaluating, failed, report }
    /// 01：没有简历
    case newUser
    /// 03 / 06：有简历、第一份报告看完之前
    case firstSteps(FirstSteps)
    /// 07：有结论、有最近进展
    case feedback
    /// 有简历但还没有可展示的进展：仍按“练一场”引导
    case resumeOnly

    /// 只给这套首页上线之后才练完第一场的人看“第一份报告好了”。
    static let firstReportSince = parseDate("2026-11-14T00:00:00+08:00")!

    public static func pick(graph: HomeGraph, mocks: HomeMockProgress?, reportSeen: Bool) -> HomeStage {
        guard graph.resumeID != nil else { return .newUser }
        if let mocks, let steps = firstSteps(mocks, hasConclusions: graph.hasConclusions, reportSeen: reportSeen) { return .firstSteps(steps) }
        if graph.hasConclusions, !graph.nodes.isEmpty, !graph.timeline.isEmpty { return .feedback }
        return .resumeOnly
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

    public static func text(_ item: HomeGraph.Progress, weakPoints: Int) -> Text {
        let left = weakPoints > 0 ? "还有 \(weakPoints) 个不牢。" : "图上没有还不牢的了。"
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

// MARK: 图谱摆放

/// 知识图谱的摆放：确定性的力导向（同一份数据每次摆得一样），坐标归一到 0…1，界面按区域大小换算。
/// Web 画布每帧都在动；桌面端首页只要静态摆好、点开放大，不做逐帧漂浮。
public enum HomeGraphLayout {
    public static func layout(nodes: [HomeGraph.Node], edges: [HomeGraph.Edge], iterations: Int = 320) -> [String: (x: Double, y: Double)] {
        guard !nodes.isEmpty else { return [:] }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        let links = edges.compactMap { edge -> (Int, Int)? in
            guard edge.kind != "EE", let a = index[edge.src], let b = index[edge.dst], a != b else { return nil }
            return (a, b)
        }
        let count = nodes.count
        // 起点：按序号放在螺旋上，确定且不重叠
        var position = (0..<count).map { i -> (Double, Double) in
            let angle = Double(i) * 2.399963
            let radius = 0.08 + 0.42 * sqrt(Double(i + 1) / Double(count + 1))
            return (0.5 + radius * cos(angle), 0.5 + radius * sin(angle))
        }
        let k = 0.9 * sqrt(1.0 / Double(count))
        var temperature = 0.1
        for _ in 0..<iterations {
            var move = Array(repeating: (0.0, 0.0), count: count)
            for i in 0..<count {
                for j in (i + 1)..<count {
                    var dx = position[i].0 - position[j].0, dy = position[i].1 - position[j].1
                    var distance = sqrt(dx * dx + dy * dy)
                    if distance < 1e-4 { dx = 0.001 * Double(i - j); dy = 0.001; distance = 0.0015 }
                    let force = k * k / distance
                    move[i].0 += dx / distance * force; move[i].1 += dy / distance * force
                    move[j].0 -= dx / distance * force; move[j].1 -= dy / distance * force
                }
            }
            for (a, b) in links {
                let dx = position[a].0 - position[b].0, dy = position[a].1 - position[b].1
                let distance = max(sqrt(dx * dx + dy * dy), 1e-4)
                let force = distance * distance / k
                move[a].0 -= dx / distance * force; move[a].1 -= dy / distance * force
                move[b].0 += dx / distance * force; move[b].1 += dy / distance * force
            }
            for i in 0..<count {
                // 轻微拉向中心，孤立节点不飞出去
                move[i].0 += (0.5 - position[i].0) * 0.02; move[i].1 += (0.5 - position[i].1) * 0.02
                let length = max(sqrt(move[i].0 * move[i].0 + move[i].1 * move[i].1), 1e-9)
                position[i].0 += move[i].0 / length * min(length, temperature)
                position[i].1 += move[i].1 / length * min(length, temperature)
            }
            temperature = max(0.002, temperature * 0.985)
        }
        // 归一到 0…1，留 6% 边距
        let xs = position.map(\.0), ys = position.map(\.1)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let spanX = max(maxX - minX, 1e-6), spanY = max(maxY - minY, 1e-6)
        var result: [String: (x: Double, y: Double)] = [:]
        for (i, node) in nodes.enumerated() {
            result[node.id] = (0.06 + 0.88 * (position[i].0 - minX) / spanX, 0.06 + 0.88 * (position[i].1 - minY) / spanY)
        }
        return result
    }
}
