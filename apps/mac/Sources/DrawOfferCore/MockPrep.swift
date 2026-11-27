import Foundation

/// 开始前（准备题目 + 检查设备）的文案与选题动画的编排，照 Web `v2/PrepAndCheck.tsx`、`v2/PrepOrbit.tsx`。
public enum MockPrep {
    // MARK: 文案

    private static let pace = ["quiet": "只挑最影响你通过的点，不再试探新内容", "near": "先补短板，顺带确认几处你拿不准的",
                               "far": "先多问几处你拿不准的，摸清底，再集中补短板", "none": "还没有约面试，按两周的节奏：先摸清你还拿不准的点"]

    static func who(_ detail: JSONValue) -> String {
        [detail.text("company_name"), detail.text("stage_label")].joined().nonEmptyValue ?? "面试"
    }
    static func hasJob(_ detail: JSONValue) -> Bool { !detail.text("job_title").isEmpty || !detail.text("company_name").isEmpty }
    public static func prep(_ detail: JSONValue) -> JSONValue? { detail["prep"].flatMap { $0 == .null ? nil : $0 } }
    private static func daysLeft(_ prep: JSONValue?) -> Int? { prep?["days_left"].flatMap { $0 == .null ? nil : $0.integer } }

    /// 标题下一行：离云川科技二面还有 1 天；没约面试时说按什么挑。
    public static func daysLine(_ detail: JSONValue) -> String {
        if let days = daysLeft(prep(detail)) { return days <= 0 ? "今天就是\(who(detail))" : "离\(who(detail))还有 \(days) 天" }
        return "按\(hasJob(detail) ? "岗位要求和你的经历" : "你的经历和这个方向常考的点")为你挑题"
    }

    /// 读简历时底部轮播的小字。
    public static func readingLines(_ detail: JSONValue) -> [String] {
        let focus = detail["practice_focus"]?.text("label").nonEmptyValue
        return [
            "通常 20–40 秒。可以先离开页面，准备好了会提醒你",
            hasJob(detail) ? "先看这场属于什么方向，再找出岗位要求里写到的考点" : "先看你的经历属于什么方向，再找这个方向常考的点",
            "简历里写到的每段经历、每一行，都会对上你以前练得怎么样",
            focus.map { "你选的「\($0)」会放在最前面问" } ?? (detail["has_past_practice"]?.bool == true ? "也会翻一遍以前的练习：上次没答好的点，这次会再确认一次" : nil),
        ].compactMap { $0 }
    }

    /// 挑题时底部轮播的小字：第一句按这场的节奏写，其余只留和这场有关的。
    public static func pickingLines(_ detail: JSONValue) -> [String] {
        guard let prep = prep(detail) else { return readingLines(detail) }
        let tags = Set((prep["picks"]?.items ?? []).map { $0.text("tag") })
        let strategy = prep.text("strategy")
        let days = daysLeft(prep)
        let line = pace[strategy].map { pace in days.map { $0 > 0 } == true ? "离\(who(detail))只剩 \(days!) 天：\(pace)" : pace }
        return [
            line,
            strategy == "quiet" || strategy == "near" ? "如果面试还有两周，会先多问几处你拿不准的，摸清底，再集中补短板" : nil,
            hasJob(detail) ? "岗位要求里点名的考点优先挑；你简历里还没写到的，也会问你接触过没有" : "这个方向常考的点会配几道，看看基础稳不稳",
            tags.contains("retest") || detail["has_past_practice"]?.bool == true ? "上次模拟没答好的点，这次会再问一次，看看有没有补上" : nil,
            "从你的经历里挑还没练过的那一段深挖；最近刚问过的，这次先换一段",
            "每道题都对着你简历里的原话出，不会问你没写过的事",
            "题目按真实面试的顺序排：先聊经历热身，再问基础和岗位题",
            "每道题出完都会再检查一遍：问得清不清楚、有没有和前面重复，不合格就重写",
        ].compactMap { $0 }
    }

    /// 准备页的大标题；picked = 选题动画已经演完。
    public static func title(_ detail: JSONValue, picked: Bool) -> String {
        let status = detail.text("status")
        let prep = prep(detail)
        if status == "preparation_failed" { return "面试官没能准备好题目" }
        if status == "in_progress" && (picked || prep == nil) { return "题目已经准备好" }
        guard let prep else { return "面试官在读你的简历" }
        return picked && prep.text("stage") == "opening" ? "第一道问题快好了" : "正在为这一场挑题"
    }

    /// 底部「这一场 …」：云川科技 · 二面 · Java 后端 · 语音 · 5 道题。
    public static func sessionLine(_ detail: JSONValue, voice: Bool? = nil) -> String {
        let isVoice = voice ?? (detail.text("answer_mode") == "voice")
        return [
            [detail.text("company_name"), detail.text("stage_label")].filter { !$0.isEmpty }.joined(separator: " · ").nonEmptyValue,
            detail.text("job_title").nonEmptyValue ?? detail.text("target_role").nonEmptyValue,
            isVoice ? "语音" : "文字",
            "\(detail["question_count"]?.integer ?? 0) 道题",
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// 检查设备页底部：题目准备到哪了。
    public static func prepNote(_ detail: JSONValue) -> String {
        let count = detail["question_count"]?.integer ?? 0
        guard detail.text("status") == "preparing" else { return "题目已经准备好" }
        let picks = prep(detail)?["picks"]?.items.count ?? 0
        return picks > 0 ? "题目还在准备，已挑好 \(min(picks, count)) / \(count) 道" : "题目还在准备"
    }

    public static let phrase = "我准备好了，可以开始了"
    public static let interviewerLine = "你好，我们开始吧。"

    /// 请读的那句：按顺序对上认出来的字；标点在读到第一个字之后算对上。
    public static func phraseHits(_ heard: String) -> [Bool] {
        let spoken = Array(heard.filter { !$0.isWhitespace })
        var cursor = 0
        return phrase.map { char in
            let punct = "，。,.".contains(char)
            guard !punct, let at = spoken[min(cursor, spoken.count)...].firstIndex(of: char) else { return punct && cursor > 0 }
            cursor = at + 1
            return true
        }
    }

    /// 至少答过一题（不算开场自我介绍）才有复盘（Web `hasAnswers`）。
    public static func hasAnswers(_ detail: JSONValue) -> Bool {
        if case .array(let items)? = detail["report"]?["questions"] {
            return items.isEmpty || items.contains { $0["is_intro"]?.bool != true && $0["skipped"]?.bool != true }
        }
        let intro = detail["has_intro"]?.bool == true
        return (detail["questions"]?.items ?? []).contains { $0.text("answer_status") == "answered" && !(intro && $0["plan_index"]?.integer == 0) }
    }

    // MARK: 选题动画

    /// 开场：简历纸淡出、来源展开；之后每道题一轮（秒）。
    public static let opening = 2.0
    public static let round = 5.6
    public static let sourceLimit = 6
    /// 挑完一共要多久：页面用它决定标题什么时候换。
    public static func duration(picks: Int) -> Double { opening + Double(picks) * round }

    public struct Source: Equatable, Sendable {
        public struct Node: Equatable, Sendable { public var text: String; public var state: String }
        public var name: String
        public var know: Bool
        public var nodes: [Node]
    }
    public struct Round: Equatable, Sendable {
        public var source: Int
        public var node: Int
        public var title: String
        public var why: String
        public var from: String
        /// 题卡来源点的颜色（十六进制）
        public var dot: String
    }

    private static let tagDot = ["retest": "E05A47", "probe": "3F6FD8", "focus": "3F6FD8", "practice": "A8A29E", "job": "7FA98F", "basics": "A8A29E", "resume": "EAB34B", "competency": "A8A29E"]

    private static func group(_ tag: String) -> String {
        tag == "resume" ? "resume" : tag == "job" ? "job" : ["retest", "probe", "focus"].contains(tag) ? "retest" : "basics"
    }

    /// 没有 sources 的旧数据：按题目的来源类别拼几个知识来源，动画照样能演。
    private static func fallbackSources(_ picks: [JSONValue]) -> [(id: String, source: Source)] {
        let groups: [(String, String, (String) -> Bool)] = [
            ("resume", "你的经历", { $0 == "resume" }),
            ("basics", "这个方向常考", { ["basics", "practice", "competency"].contains($0) }),
            ("job", "岗位要求", { $0 == "job" }),
            ("retest", "上次没答好", { ["retest", "probe", "focus"].contains($0) }),
        ]
        return groups.compactMap { id, name, match in
            let nodes = picks.filter { match($0.text("tag")) }.map { Source.Node(text: $0.text("topic"), state: $0.text("tag") == "retest" ? "weak" : "new") }
            return nodes.isEmpty ? nil : (id, Source(name: name, know: id != "resume", nodes: nodes))
        }
    }

    /// 每道题对上外圈的哪个来源、哪一行，以及题卡上写什么。
    public static func plan(_ prep: JSONValue) -> (sources: [Source], rounds: [Round]) {
        let picks = prep["picks"]?.items ?? []
        let given = prep["sources"]?.items ?? []
        let raw: [(id: String, source: Source)] = (given.isEmpty ? fallbackSources(picks) : given.map { item in
            (item.text("id"), Source(name: item.text("name"), know: item.text("kind") == "know",
                                     nodes: (item["nodes"]?.items ?? []).map { Source.Node(text: $0.text("text"), state: $0.text("state")) }))
        }).prefix(sourceLimit).map { $0 }
        let sources = raw.map(\.source)
        var used = Set<String>()
        let rounds = picks.enumerated().map { index, pick -> Round in
            let tag = pick.text("tag"), topic = pick.text("topic"), note = pick.text("note")
            let fallback: String? = given.isEmpty ? group(tag) : tag == "job" ? "job" : tag == "basics" ? "basics" : nil
            let wanted = pick.text("source").nonEmptyValue ?? fallback
            var source = raw.firstIndex { $0.id == wanted } ?? -1
            if source < 0 { source = index % max(1, raw.count) }
            let nodes = source < sources.count ? sources[source].nodes : []
            func free(_ position: Int) -> Bool { !used.contains("\(source)-\(position)") }
            func byState(_ state: String) -> Int? { nodes.indices.first { free($0) && nodes[$0].state == state } }
            var node = nodes.indices.first { free($0) && nodes[$0].text == topic }
                ?? (tag == "retest" ? byState("weak") : nil)
                ?? byState("new") ?? byState("weak") ?? byState("held") ?? -1
            if node < 0 && !nodes.isEmpty { node = index % nodes.count }
            if node >= 0 { used.insert("\(source)-\(node)") }
            let line = node >= 0 ? nodes[node] : nil
            let exp = source < sources.count && !sources[source].know
            let why: String
            switch tag {
            case "retest": why = "上次没答好，这次再问一次"
            case "focus": why = "你点名要练的，先问它"
            case "probe": why = "还拿不准你掌握没有，补问一题确认"
            case "job": why = note.isEmpty ? "岗位要求里点名的考点" : "岗位要、\(note)：先问接触过没有"
            default:
                why = !exp ? "这个方向常考，真实面试里问得多"
                    : line?.state == "weak" ? "这一行上次没守住，再问一次" : line?.state == "held" ? "这一行守住过，换个角度深挖" : "这一行还没练过，先问它"
            }
            let from = exp ? "出自你简历里的一行" : tag == "retest" ? "上次没答好 · 复测" : tag == "job" ? (note.isEmpty ? "岗位要求" : "岗位要求 · \(note)") : "方向常考"
            return Round(source: source, node: node, title: topic, why: why, from: from, dot: tagDot[tag] ?? "A8A29E")
        }
        return (sources, rounds)
    }
}
