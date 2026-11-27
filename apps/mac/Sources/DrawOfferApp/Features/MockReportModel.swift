import Foundation
import DrawOfferCore

/// 面试复盘的统一结构（Figma 09 · 10 复盘；Web `interviews/report/reviewView.ts`、`fromMock.ts`）：
/// 一题是一道主问题连同它的追问；只有语音面试才有的录音、语音指标按数据有无显示。
enum MockRV {
    enum Outcome: String { case reached, oneShort = "one_short", missed, unrecorded }

    struct Turn: Equatable, Identifiable {
        var id: String
        var ask: String
        var answer: String?
        var missing: String
        var follow: Bool
        var durationMs: Double?
        var hasRecording: Bool
        var editable: Bool
    }

    struct Signal: Equatable {
        var label: String; var state: String; var quote: String?
        /// 要点的短名、为什么要说、差在哪（新报告才有）
        var name: String? = nil; var explain: String? = nil; var gap: String? = nil
    }
    struct Slip: Equatable { var quote: String?; var description: String; var correction: String? }
    struct Expression: Equatable { var state: String; var quote: String?; var note: String? }

    struct Question: Equatable, Identifiable {
        var id: String
        var no: Int
        var ref: String
        var title: String
        var outcome: Outcome
        var layered = true
        var level: Int?
        var aiLevel: Int?
        var expected: Int
        var score: Int?
        var follows: Int
        var line: String?
        var turns: [Turn]
        var signals: [Signal]
        var better: String?
        var highlight: String?
        var advice: String?
        var reEvaluated: Int
        /// 这题的起点层（score_basis.start_depth）；核心要点全没说到时分数封顶，写「还没达到起点」
        var start: Int? = nil
        var belowStart = false
        /// 重练同一道题时，上次那题的分
        var previousScore: Int? = nil
        /// 这道题考什么
        var intent: String? = nil
        /// 「表现与表达」一段：亮点、表达和语速
        var delivery: String? = nil
        var slips: [Slip] = []
        var expression: Expression? = nil
        var weak: Bool { outcome == .missed || outcome == .oneShort }
    }

    struct Ability: Equatable { var key: String; var label: String; var score: Int; var past: Double? }
    struct Voice: Equatable {
        var speed: String; var pauses: String; var fillers: String
        /// 偏快 / 偏慢，在参考范围内为空
        var pace: String? = nil
        var longPauses = 0
    }

    struct View {
        var title: String
        var meta: String
        var recordTitle: String
        var recordMeta = ""
        var score: Int?
        var conclusion: String
        /// 分数下面加粗的一句话和一段说明
        var headline: String? = nil
        var summary: String? = nil
        var compare: String
        /// 上一场的总分，没有可比的为空
        var previous: Int? = nil
        var questions: [Question]
        var target: Int
        var abilities: [Ability]
        var voice: Voice?
        var pastCount: Int
    }

    static let levels = ["了解", "熟悉", "掌握", "精通", "专家"]
    static func levelLabel(_ level: Int) -> String { levels[max(0, min(4, level - 1))] }

    static let verdictName = ["likely_pass": "达到目标", "promising": "接近目标", "at_risk": "还差一些", "likely_fail": "差距较大", "insufficient": "证据不足",
                              "meets": "达标", "borderline": "接近达标", "below": "未达标"]

    static func outcomeText(_ q: Question) -> String {
        if !q.layered { return [.reached: "说清了", .oneShort: "说了一半", .missed: "没说清", .unrecorded: "没记下"][q.outcome] ?? "" }
        return [.reached: "答到位", .oneShort: "差一点", .missed: "没答上", .unrecorded: "没记下"][q.outcome] ?? ""
    }

    static func outcomeAt(_ level: Int, _ expected: Int) -> Outcome {
        let gap = expected - level
        return gap <= 0 ? .reached : gap == 1 ? .oneShort : .missed
    }

    /// 卡片深度下面的一行：答到「熟悉」· 要到「掌握」
    static func depthLine(_ q: Question, asReached: Bool = false) -> String {
        guard let level = q.level else { return "没记下回答" }
        let at = level <= 0 ? "没到「了解」" : "答到「\(levelLabel(level))」"
        return q.outcome == .reached || asReached ? at : "\(at) · 要到「\(levelLabel(q.expected))」"
    }

    /// 每道题右边、单题分数下面的一句：达到「熟悉」，要求「掌握」（Web `reachLine`）
    static func reachLine(_ q: Question) -> String {
        MockPracticeResult.reachLine(layered: q.layered, level: q.level, reached: q.outcome == .reached, expected: q.expected,
                                     start: q.start, belowStart: q.belowStart, outcome: outcomeText(q))
    }

    static func gaps(_ q: Question) -> [String] { q.signals.filter { $0.state != "hit" }.map(\.label) }

    /// 建议先补的几处：分低的在前，同分按题号。
    static func suggestions(_ questions: [Question], limit: Int = 3) -> [Question] {
        Array(questions.filter(\.weak).sorted { a, b in
            if (a.score ?? 0) != (b.score ?? 0) { return (a.score ?? 0) < (b.score ?? 0) }
            return a.no < b.no
        }.prefix(limit))
    }

    static func advice(_ q: Question) -> String { q.advice ?? q.line ?? "先把这一段补上，再练一次。" }

    /// 单题「达标」线：单题 60 分以上（和后端 interview_scoring.REACHED_SCORE 同一条线）。
    static let passScore = 60

    static func monthDay(_ value: String) -> String {
        guard let date = CareerApplication.date(value) else { return "" }
        let parts = Beijing.calendar.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0)
    }

    private static let clean = CharacterSet(charactersIn: " \n\t，。！？、,.!?：:“”\"'（）()")

    /// 原话在回答里的位置：评分引的原话可能和回答差几个标点。
    static func quoteIn(_ answer: String, _ quote: String?) -> String? {
        guard let text = quote?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if answer.contains(text) { return text }
        let isClean = { (c: Character) in !c.unicodeScalars.allSatisfy { clean.contains($0) } }
        let wanted = String(text.filter(isClean))
        guard wanted.count >= 4 else { return nil }
        let chars = Array(answer)
        let kept = chars.indices.filter { isClean(chars[$0]) }
        let joined = String(kept.map { chars[$0] })
        guard let range = joined.range(of: wanted) else { return nil }
        let start = joined.distance(from: joined.startIndex, to: range.lowerBound)
        return String(chars[kept[start]...kept[start + wanted.count - 1]])
    }

    static func turnLabel(_ position: Int) -> String { position == 0 ? "主问题" : "追问 \(position)" }

    /// 单题复盘右边的一条批注，挂在某一轮回答里的一句原话上（Web `commentsOf`）。
    struct Comment: Equatable, Identifiable { var id: String; var turnID: String; var quote: String; var title: String; var body: String?; var add: Bool }

    private static func trimEnd(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.last, "。；;，,. ".contains(last) { value.removeLast() }
        return value
    }

    private static func lastSentence(_ answer: String) -> String? {
        var parts: [String] = [], current = ""
        for char in answer.trimmingCharacters(in: .whitespacesAndNewlines) {
            current.append(char)
            if "。！？!?；;".contains(char) { parts.append(current); current = "" }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.last
    }

    /// 说了一半的要点、说错的地方、表达问题挂在原话上；没说到的要点没有原话，挂在主回答最后一句，提醒收尾补上。按在回答里的先后排。
    static func comments(_ q: Question) -> [Comment] {
        let answered = q.turns.filter { $0.answer != nil }
        var found: [(Comment, Double)] = []
        var taken = Set<String>()
        func add(_ key: String, _ quote: String?, _ title: String, _ body: String?, add: Bool = false) {
            for (position, turn) in answered.enumerated() {
                guard let answer = turn.answer, let at = quoteIn(answer, quote), !taken.contains("\(turn.id):\(at)") else { continue }
                taken.insert("\(turn.id):\(at)")
                let offset = answer.range(of: at).map { answer.distance(from: answer.startIndex, to: $0.lowerBound) } ?? 0
                found.append((Comment(id: key, turnID: turn.id, quote: at, title: title, body: body?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue, add: add), Double(position * 100_000 + offset)))
                return
            }
        }
        for (index, signal) in q.signals.enumerated() where signal.state == "partial" {
            add("s\(index)", signal.quote, signal.gap.map(trimEnd) ?? "只说了一半：\(signal.name ?? signal.label)", signal.explain)
        }
        for (index, slip) in q.slips.enumerated() {
            add("e\(index)", slip.quote, trimEnd(slip.description), slip.correction.map { "正确的说法：\($0)" })
        }
        if let expression = q.expression, expression.state != "hit", let note = expression.note { add("x", expression.quote, trimEnd(note), nil) }
        if let main = answered.first, let answer = main.answer, let tail = lastSentence(answer) {
            let at = answer.range(of: tail, options: .backwards).map { answer.distance(from: answer.startIndex, to: $0.lowerBound) } ?? 0
            for (index, signal) in q.signals.enumerated() where signal.state == "miss" {
                found.append((Comment(id: "m\(index)", turnID: main.id, quote: tail, title: "收尾可以补一句\(signal.name ?? signal.label)", body: signal.explain, add: true), Double(at) + 0.5))
            }
        }
        return found.sorted { $0.1 < $1.1 }.map(\.0)
    }

    // MARK: 模拟面试评估报告 → 统一结构

    static func view(_ detail: JSONValue, context: JSONValue?) -> View? {
        guard let report = detail["report"], report != .null else { return nil }
        let target = Int(MockMap.diffLevel[detail.text("difficulty")] ?? 3)
        let rounds = MockMap.rounds(detail).filter { !$0.intro }
        let fromReport = report["questions"]?.items ?? []
        let date = detail.text("finished_at").nonEmptyValue ?? detail.text("created_at")
        var questions: [Question] = rounds.enumerated().map { index, round in
            let sequence = round.main["sequence_no"]?.numberValue
            var evaluation = fromReport.first { $0["sequence_no"]?.numberValue == sequence }
            if case .object(var base)? = evaluation, case .object(let latest)? = round.main["evaluation"] {
                for (key, value) in latest where key != "topic" && key != "sequence_no" { base[key] = value }
                evaluation = .object(base)
            }
            return question(round, evaluation, no: index + 1, target: target, report: report)
        }
        questions = questions.map { withPrevious($0, context: context) }
        let type = MockMap.typeName(detail)
        let stage = detail.text("stage_label").nonEmptyValue ?? type
        let title = "\(detail.text("company_name").nonEmptyValue ?? "通用练习") \(stage)"
        let stats = MockMap.stats(detail)
        let follows = (detail["questions"]?.items ?? []).filter { $0.text("kind") == "follow_up" }.count
        let role = detail.text("job_title").nonEmptyValue ?? detail.text("target_role").nonEmptyValue
        // 练这几处 / 练这一处（Figma 10.23a / 10.23b）：标题下面写练了几处、日期、题数和时长
        let meta = MockPracticeResult.isPractice(detail)
            ? MockPracticeResult.meta(count: rounds.count, day: monthDay(date), minutes: stats.minutes)
            : [role, "模拟", type, follows > 0 ? "追问 \(follows) 次" : nil, monthDay(date)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let score = report["total_score"]?.numberValue.map { Int($0.rounded()) }
        let verdict = report["verdict"]?.text("level").nonEmptyValue
        let metrics = report["voice_metrics"].flatMap { $0 == .null ? nil : $0 }
        return View(
            title: title, meta: meta,
            recordTitle: "\(stage)的面试记录",
            recordMeta: [role, "模拟", type, "\(rounds.count) 题", follows > 0 ? "追问 \(follows) 次" : nil, stats.minutes.map { "\($0) 分钟" }, monthDay(date)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
            score: score,
            conclusion: verdict.flatMap { verdictName[$0] } ?? report.text("headline"),
            headline: report.text("headline").nonEmptyValue, summary: report.text("summary").nonEmptyValue,
            compare: compareLine(score, context?["previous"]?["score"]?.numberValue.map { Int($0.rounded()) }, questions),
            previous: context?["previous"]?["score"]?.numberValue.map { Int($0.rounded()) },
            questions: questions, target: target,
            abilities: abilities(report, context),
            voice: detail.text("answer_mode") == "voice" ? metrics.map { m in
                Voice(speed: "\(Int((m["chars_per_minute"]?.numberValue ?? 0).rounded())) 字/分", pauses: "\(m["long_pauses"]?.integer ?? 0) 次",
                      fillers: String(format: "%.1f%%", (m["filler_ratio"]?.numberValue ?? 0) * 100),
                      pace: pace(m["chars_per_minute"]?.numberValue ?? 0, m["reference"]?["chars_per_minute"]?.items.compactMap(\.numberValue)),
                      longPauses: m["long_pauses"]?.integer ?? 0)
            } : nil,
            pastCount: context?["past_count"]?.integer ?? 0)
    }

    private static func pace(_ speed: Double, _ range: [Double]?) -> String? {
        guard let range, range.count == 2 else { return nil }
        return speed > range[1] ? "偏快" : speed < range[0] ? "偏慢" : nil
    }

    private static func question(_ round: MockMap.Round, _ evaluation: JSONValue?, no: Int, target: Int, report: JSONValue) -> Question {
        let expected = evaluation?["target_depth"]?.integer.nonZero ?? target
        let skipped = evaluation?["skipped"]?.bool == true
        let aiLevel = evaluation.map { skipped ? 0 : max(0, min(5, $0["achieved_depth"]?.integer ?? 0)) }
        let userDepth = round.main["evaluation"]?["user_depth"].flatMap { $0 == .null ? nil : $0.integer }
        let outcome: Outcome = userDepth.map { outcomeAt($0, expected) } ?? {
            guard let evaluation else { return .unrecorded }
            if let given = evaluation.text("outcome").nonEmptyValue { return given == "not_judged" ? .unrecorded : Outcome(rawValue: given) ?? .unrecorded }
            if skipped { return .missed }
            let gap = target - max(0, min(5, evaluation["achieved_depth"]?.integer ?? 0))
            if gap <= 0 { return .reached }
            if evaluation.text("depth_status") == "not_probed" { return .oneShort }
            return gap == 1 ? .oneShort : .missed
        }()
        let weakness = evaluation?["weaknesses"]?.items.first?.stringValue
        let highlight = evaluation?["highlights"]?.items.first?.stringValue
        let weak = outcome == .missed || outcome == .oneShort
        let sequence = round.main["sequence_no"]?.integer ?? 0
        let expression = evaluation?["expression"].flatMap { $0 == .null ? nil : $0 }
        let basis = evaluation?["score_basis"].flatMap { $0 == .null ? nil : $0 }
        let belowStart = basis?["capped"]?.bool == true && userDepth == nil
        return Question(
            id: round.main.display("id"), no: no, ref: "\(sequence)", title: round.topic, outcome: outcome,
            level: belowStart ? 0 : userDepth ?? aiLevel, aiLevel: aiLevel, expected: expected,
            score: evaluation?["score"]?.numberValue.map { Int($0.rounded()) },
            follows: max(0, round.turns.count - 1),
            line: weak ? weakness ?? highlight : highlight ?? weakness,
            turns: round.turns.enumerated().map { position, turn in
                Turn(id: turn.display("id"), ask: turn.text("content"),
                     answer: turn.text("answer_status") == "answered" ? turn.text("answer_text") : nil,
                     missing: turn.text("answer_status") == "skipped" ? "跳过了这道题" : "这道题没有作答",
                     follow: position > 0, durationMs: turn["audio_duration_ms"]?.numberValue, hasRecording: turn["has_recording"]?.bool == true,
                     editable: turn.text("answer_source") == "voice" && turn.text("answer_status") == "answered")
            },
            signals: (evaluation?["signals"]?.items ?? []).compactMap { item in
                item.text("verdict") == "not_probed" ? nil : Signal(label: item.text("signal"), state: item.text("verdict"), quote: item.text("evidence").nonEmptyValue,
                                                                   name: item.text("name").nonEmptyValue, explain: item.text("explain").nonEmptyValue, gap: item.text("gap").nonEmptyValue)
            },
            better: evaluation?.text("reference_answer").nonEmptyValue ?? weakness,
            highlight: highlight,
            advice: (report["actions"]?.items ?? []).first { $0.text("kind") == "practice" && ($0["question_refs"]?.items ?? []).contains { $0.integer == sequence } }?.text("detail").nonEmptyValue,
            reEvaluated: round.main["re_evaluate_count"]?.integer ?? 3,
            start: basis?["start_depth"]?.integer, belowStart: belowStart,
            intent: evaluation?.text("intent").nonEmptyValue,
            delivery: [sentence(highlight), expression?.text("verdict") != "hit" ? sentence(expression?.text("note")) : nil, speed(round, report)].compactMap { $0 }.joined().nonEmptyValue,
            slips: (evaluation?["error_details"]?.items ?? []).map { Slip(quote: $0.text("evidence").nonEmptyValue, description: $0.text("description"), correction: $0.text("correction").nonEmptyValue) },
            expression: expression.map { Expression(state: $0.text("verdict"), quote: $0.text("evidence").nonEmptyValue, note: $0.text("note").nonEmptyValue) })
    }

    /// 重练同一道题时接上那题上次的分（复盘的「较练习前」、单题的「上次」）。
    private static func sentence(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return "。！？!?".contains(value.last!) ? value : value + "。"
    }

    /// 这一题语音回答的语速：字数 ÷ 录音时长；参考区间来自整场的 voice_metrics。
    private static func speed(_ round: MockMap.Round, _ report: JSONValue) -> String? {
        let voiced = round.turns.filter { $0.text("answer_source") == "voice" && ($0["audio_duration_ms"]?.numberValue ?? 0) > 0 && !$0.text("answer_text").isEmpty }
        let ms = voiced.reduce(0.0) { $0 + ($1["audio_duration_ms"]?.numberValue ?? 0) }
        guard !voiced.isEmpty, ms >= 5000 else { return nil }
        let chars = voiced.reduce(0) { $0 + $1.text("answer_text").filter { !$0.isWhitespace }.count }
        let speed = Int((Double(chars) / (ms / 60_000)).rounded())
        let range = report["voice_metrics"]?["reference"]?["chars_per_minute"]?.items.compactMap(\.numberValue) ?? []
        guard range.count == 2 else { return "语速 \(speed) 字/分。" }
        let pace = Double(speed) > range[1] ? "偏快，讲流程时可以放慢一点" : Double(speed) < range[0] ? "偏慢，可以说得更连贯一些" : "在合适的范围内"
        return "语速 \(speed) 字/分，\(pace)。"
    }

    private static func withPrevious(_ q: Question, context: JSONValue?) -> Question {
        guard let found = (context?["questions"]?.items ?? []).first(where: { $0.display("ref") == q.ref }),
              let previous = found["previous_score"]?.numberValue else { return q }
        var next = q
        next.previousScore = Int(previous.rounded())
        return next
    }

    private static func compareLine(_ score: Int?, _ previous: Int?, _ questions: [Question]) -> String {
        let judged = questions.filter { $0.outcome != .unrecorded }
        let tally = "\(judged.count) 题答到位 \(judged.filter { $0.outcome == .reached }.count) 题"
        guard let score, let previous else { return tally }
        let gap = score - previous
        return (gap > 0 ? "比上一场高 \(gap) 分" : gap < 0 ? "比上一场低 \(-gap) 分" : "和上一场同分") + "，" + tally
    }

    private static let outside: Set<String> = ["knowledge", "job_fit", "professional_depth", "resume_consistency"]

    private static func abilities(_ report: JSONValue, _ context: JSONValue?) -> [Ability] {
        let competencies = report["competencies"]?.items ?? []
        let items: [(String, Double)] = competencies.isEmpty
            ? (report["dimensions"]?.items ?? []).map { ($0.text("key"), ($0["score"]?.numberValue ?? 0) * 20) }
            : competencies.filter { $0["assessed"]?.bool == true && $0["score"]?.numberValue != nil }.map { ($0.text("key"), $0["score"]?.numberValue ?? 0) }
        return items.map { key, score in
            Ability(key: key, label: MockReview.dimensionLabels[key] ?? key, score: Int(score.rounded()), past: context?["competencies"]?[key]?["average"]?.numberValue)
        }
    }

    /// 2026-11-24 起每道答过的题都判这五项（有 adaptability 的报告），图上固定按这个顺序画满五个方向。
    private static let five = [("knowledge", "专业深度"), ("problem_solving", "分析与方案"), ("ownership", "实践与成果"), ("adaptability", "应变与学习"), ("communication", "表达与条理")]

    /// 通用能力：新报告固定五项；更早的报告只看怎么说，不含知识和岗位匹配，能评的太少时才把它们放回来，最多 6 项。
    static func generalAbilities(_ abilities: [Ability]) -> [Ability] {
        if abilities.contains(where: { $0.key == "adaptability" }) {
            return five.compactMap { key, label in abilities.first { $0.key == key }.map { var item = $0; item.label = label; return item } }
        }
        let general = abilities.filter { !outside.contains($0.key) }
        let shown = general.count >= 3 ? general : abilities
        return shown.prefix(6).map { item in var item = item; if item.key == "communication" { item.label = "表达水平" }; return item }
    }

    /// 复盘里「练这几题」「练这一处」带到配置页的内容（Web `practicePlan.ts`）。
    static func practiceItem(_ q: Question) -> MockPracticeItem { practiceItem(q, origin: nil) }

    /// origin 是这些题来自哪一场（mock|real:场次），带上后配置页按它比“上次”的分。
    static func practiceItem(_ q: Question, origin: String?) -> MockPracticeItem {
        let gaps = gaps(q)
        return MockPracticeItem(
            label: String(q.title.prefix(120)),
            question: String((q.turns.last?.ask ?? q.title).prefix(500)),
            signals: gaps.prefix(5).map { String($0.prefix(300)) },
            note: q.line, tag: nil,
            last: [depthLine(q, asReached: true), q.line].compactMap { $0 }.joined(separator: "，"),
            goal: ["答到「\(levelLabel(q.expected))」", gaps.isEmpty ? nil : "把\(gaps.prefix(2).joined(separator: "和"))讲清楚"].compactMap { $0 }.joined(separator: "，"),
            source: origin.flatMap { q.ref.isEmpty ? nil : "\($0):\(q.ref)" })
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
