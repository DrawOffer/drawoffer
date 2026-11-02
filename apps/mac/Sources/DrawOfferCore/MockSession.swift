import Foundation

/// 面试中（Web `mock-interview/v2/sessionModel.ts`、`Horizon.tsx` 的 `sessionBeadXs`）：顶栏标题与进度、
/// 「这一场」的图（当前这题转到左侧，往圆心走一圈是追问深一层，笔记标在对应的层上）、地平线上的题目珠子。
public enum MockSession {
    public static func heading(_ detail: JSONValue) -> String {
        let mode = detail.text("answer_mode") == "voice" ? "语音面试" : "文字面试"
        let who = [detail.text("company_name").nonEmptyValue, detail.text("stage_label").nonEmptyValue.map { "\($0)准备" }].compactMap { $0 }.joined(separator: " ")
        return "\(who.isEmpty ? detail.text("resume_title") : who) · \(mode)"
    }

    public static func subtitle(_ detail: JSONValue) -> String {
        let focus = detail["practice_focus"]?.text("label").nonEmptyValue.map { "先问 \($0)" }
        return [MockMap.typeName(detail), MockMap.diffName[detail.text("difficulty")], "\(detail["question_count"]?.integer ?? 0) 题", focus].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public static func current(_ detail: JSONValue) -> JSONValue? {
        let id = detail.display("current_question_id")
        guard !id.isEmpty else { return nil }
        return (detail["questions"]?.items ?? []).first { $0.display("id") == id }
    }

    public static func lastAsked(_ detail: JSONValue) -> JSONValue? {
        (detail["questions"]?.items ?? []).max { ($0["sequence_no"]?.numberValue ?? 0) < ($1["sequence_no"]?.numberValue ?? 0) }
    }

    public static func roundOf(_ detail: JSONValue, _ question: JSONValue?) -> MockMap.Round? {
        guard let question else { return nil }
        let root = question.display("parent_id").nonEmptyValue ?? question.display("id")
        return MockMap.rounds(detail).first { $0.main.display("id") == root }
    }

    public static func progress(_ detail: JSONValue, _ question: JSONValue?) -> String {
        let count = detail["question_count"]?.integer ?? 0
        guard let question else { return "\(count) / \(count) 题" }
        if MockMap.isIntro(detail, question) { return "开场 · 自我介绍" }
        let rounds = MockMap.rounds(detail).filter { !$0.intro }
        let round = roundOf(detail, question)
        let index = round.flatMap { r in rounds.firstIndex { $0.main.display("id") == r.main.display("id") } } ?? rounds.count - 1
        let follows = round.map { $0.turns.count - 1 } ?? 0
        return "第 \(index + 1) / \(count) 题" + (follows > 0 ? " · 追问 \(follows) 次" : "")
    }

    public struct Note: Equatable, Sendable {
        public let kind: String
        public let text: String
        public let level: Double
    }

    /// 这道主问题下面试官记下的所有要点，按追问的层排。
    public static func notes(_ round: MockMap.Round?) -> [Note] {
        guard let round else { return [] }
        return round.turns.flatMap { turn in
            (turn["notes"]?.items ?? []).map { Note(kind: $0.text("kind"), text: $0.text("text"), level: max(1, turn["depth_level"]?.numberValue ?? 1)) }
        }
    }

    /// 笔记只取第一句；按显示宽度截（英文字母约半个汉字宽），不把英文单词截成半截。
    public static func shortNote(_ text: String, _ limit: Double = 12) -> String {
        let stops = Set("：:，,。；;")
        let head = text.firstIndex { stops.contains($0) }.map { String(text[..<$0]) } ?? text
        let clean = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(clean)
        let ascii = { (c: Character) in c.unicodeScalars.count == 1 && (0x20...0x7E).contains(c.unicodeScalars.first!.value) }
        let alnum = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber) }
        var width = 0.0, end = 0
        while end < chars.count {
            let next = width + (ascii(chars[end]) ? 0.55 : 1)
            if next > limit { break }
            width = next; end += 1
        }
        if end >= chars.count { return clean }
        var cut = end
        while cut > 0 && alnum(chars[cut - 1]) && alnum(chars[cut]) { cut -= 1 }
        if Double(cut) < Double(end) / 2 { cut = end }
        var kept = String(chars[..<cut])
        while let last = kept.last, last == "、" || last.isWhitespace { kept.removeLast() }
        return kept + "…"
    }

    public enum Phase: Sendable { case asking, answering, thinking, done }
    public enum NoteTone: Sendable { case blue, orange }
    public struct Annotation: Equatable, Sendable { public let level: Double; public let text: String; public let tone: NoteTone }

    public struct Map: Sendable {
        public var points: [MockMap.Point]
        public var sectors: [MockMap.Sector]
        public var path: [MockMap.PathStep]
        public var now: String?
        public var hot: [String]
        public var rotation: Double
        public var annotations: [Annotation]
        public var rounds: [MockMap.Round]
        /// 扇区分界线的角度（这一场有题时才有）。
        public var bounds: [Double]?
    }

    /// 当前这题转到左侧（180°），其余的点跟着一起转。`memory` 是长期记忆里的点（首页图），只用来给题找领域。
    public static func map(_ detail: JSONValue, memory: [MockMap.Point], memorySectors: [MockMap.Sector], experienceOf: ((String?) -> String?)?, current: JSONValue?, phase: Phase) -> Map {
        let slots = MockLayout.slots(detail, memory: memory, experienceOf: experienceOf)
        let path = slots?.path ?? []
        let rounds = slots?.rounds ?? []
        let points = slots?.points ?? memory
        let sectors = slots?.sectors ?? memorySectors
        let round = roundOf(detail, current)
        let index = round.flatMap { r in rounds.firstIndex { $0.main.display("id") == r.main.display("id") } } ?? -1
        let step = index >= 0 && index < path.count ? path[index] : nil
        let point = step.flatMap { s in points.first { $0.id == s.id } }
        let rotation = point.map { 180 - $0.angle } ?? 0
        var deepest = 1.0
        for turn in round?.turns ?? [] {
            let depth = turn["depth_level"]?.numberValue ?? 0
            deepest = max(deepest, depth == 0 ? 1 : depth)
        }
        let steps = path.enumerated().map { i, item -> MockMap.PathStep in
            guard i == index, round != nil else { return item }
            return MockMap.PathStep(id: item.id, from: item.from, to: deepest, ok: phase == .done ? item.ok : nil)
        }
        var annotations: [Annotation] = []
        if let round, point != nil, phase != .done {
            let list = notes(round)
            var level = max(1, round.from)
            while level <= deepest {
                let here = list.filter { $0.level == level }
                let question = here.first { $0.kind == "question" }
                let hit = here.first { $0.kind == "hit" }
                if let question, level == deepest, phase == .thinking {
                    annotations.append(Annotation(level: level, text: "? \(MockMap.levelName(level)) · \(shortNote(question.text, 10))", tone: .orange))
                } else if let hit {
                    annotations.append(Annotation(level: level, text: "✓ \(MockMap.levelName(level)) · \(shortNote(hit.text, 10))", tone: .blue))
                } else if level == round.from && round.turns.count == 1 {
                    annotations.append(Annotation(level: level, text: MockMap.levelName(level), tone: .blue))
                } else if level > round.from {
                    annotations.append(Annotation(level: level, text: "追问 · \(MockMap.levelName(level))", tone: .blue))
                }
                level += 1
            }
        }
        return Map(
            points: points.map { var p = $0; p.angle += rotation; return p },
            sectors: sectors.map { MockMap.Sector(name: $0.name, angle: $0.angle + rotation) },
            path: steps,
            now: phase == .done ? nil : point?.id,
            hot: path.map(\.id),
            rotation: rotation,
            annotations: annotations,
            rounds: rounds,
            bounds: slots.map { $0.bounds.map { $0 + rotation } }
        )
    }

    /// 作答页只给当前这题写名字（下面挂最新一行标注）；其余题只画题号。准备页、结束页给每题写名字。
    public static func layout(_ map: Map, targetLevel: Double, labelAll: Bool) -> MockLayout.Layout? {
        guard map.bounds != nil else { return nil }
        let stage = MockLayout.session
        let placed = MockMap.place(stage.at, map.points)
        let notes = Array(map.annotations.suffix(1))
        let nowAt = placed.first { $0.point.id == map.now }
        var input = MockLayout.Input(g: stage.at, points: placed, path: map.path, sectors: map.sectors, frame: stage.frame)
        input.sectorFrame = stage.sectorFrame
        input.now = map.now
        input.nowLines = nowAt == nil ? 0 : notes.count
        input.nowLineWidth = notes.map { MockLayout.textWidth($0.text, 10) }.max() ?? 0
        input.labelIDs = labelAll ? nil : map.now.map { [$0] } ?? []
        return MockLayout.layout(input)
    }

    public struct Bead: Equatable, Sendable {
        public enum State: Sendable { case done, now, todo, skip }
        public let id: String
        public let title: String
        public let state: State
        public let followUps: Int
        public let miss: Bool
    }

    public static func beads(_ detail: JSONValue, _ current: JSONValue?) -> [Bead] {
        let rounds = MockMap.rounds(detail).filter { !$0.intro }
        let now = roundOf(detail, current)
        var beads = rounds.map { round in
            Bead(id: round.main.display("id"), title: round.topic,
                 state: now?.main.display("id") == round.main.display("id") && detail.text("status") == "in_progress" ? .now : round.skipped ? .skip : .done,
                 followUps: round.turns.count - 1, miss: round.ok == false)
        }
        let count = detail["question_count"]?.integer ?? 0
        while beads.count < count { beads.append(Bead(id: "todo-\(beads.count)", title: "…", state: .todo, followUps: 0, miss: false)) }
        return beads
    }

    public static func introNow(_ detail: JSONValue, _ current: JSONValue?) -> Bool {
        current.map { MockMap.isIntro(detail, $0) } ?? false
    }

    public static func beadXs(_ count: Int) -> [Double] {
        (0..<count).map { 300 + 790 * (Double($0) + 0.5) / Double(max(1, count)) }
    }

    public static func sourceChip(_ question: JSONValue?) -> (label: String, quote: String)? {
        guard let question, question.text("kind") == "main", let anchor = question.text("anchor").nonEmptyValue else { return nil }
        switch question.text("anchor_kind") {
        case "intro": return nil
        case "job": return ("从岗位要求里来", anchor)
        case "material": return ("从资料里来", anchor)
        default: return ("从简历里来", anchor)
        }
    }

    public static func mmss(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// 引用的原话在题目里蓝色标出。
    public static func splitQuoted(_ text: String, _ quote: String?) -> (before: String, quote: String, after: String)? {
        guard let quote, !quote.isEmpty, let range = text.range(of: quote) else { return nil }
        return (String(text[..<range.lowerBound]), quote, String(text[range.upperBound...]))
    }

    public static func hasAnswered(_ detail: JSONValue) -> Bool {
        (detail["questions"]?.items ?? []).contains { $0.text("answer_status") == "answered" && !MockMap.isIntro(detail, $0) }
    }
}
