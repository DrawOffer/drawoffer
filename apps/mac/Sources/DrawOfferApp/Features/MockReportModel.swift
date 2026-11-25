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

    struct Signal: Equatable { var label: String; var state: String; var quote: String? }
    struct History: Equatable { var date: String; var title: String; var result: String; var current = false }

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
        var history: [History]?
        var stops: Int
        var recovered = false
        var reEvaluated: Int
        var weak: Bool { outcome == .missed || outcome == .oneShort }
    }

    struct Ability: Equatable { var key: String; var label: String; var score: Int; var past: Double? }
    struct Voice: Equatable { var speed: String; var pauses: String; var fillers: String }

    struct View {
        var title: String
        var meta: String
        var recordTitle: String
        var recordMeta = ""
        var score: Int?
        var conclusion: String
        var compare: String
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

    /// 单题详情深度上面的一句。
    static func depthSentence(_ q: Question) -> String {
        let wanted = levelLabel(q.expected)
        guard let level = q.level else { return "没记下回答，面试官想听到「\(wanted)」" }
        if level <= 0 { return "没到「了解」，面试官想听到「\(wanted)」" }
        return "答到「\(levelLabel(level))」，面试官想听到「\(wanted)」"
    }

    static func repeatTag(_ q: Question) -> String? {
        guard q.weak, let history = q.history else { return nil }
        if q.stops >= 2 { return "第 \(q.stops) 次停在这" }
        return history.isEmpty ? "第一次问到" : nil
    }

    static func stopTag(_ q: Question) -> String? {
        guard let history = q.history else { return nil }
        if q.stops >= 2 { return "停过 \(q.stops) 次" }
        return history.isEmpty ? "第一次问到" : nil
    }

    static func gaps(_ q: Question) -> [String] { q.signals.filter { $0.state != "hit" }.map(\.label) }

    static func suggestions(_ questions: [Question], limit: Int = 3) -> [Question] {
        Array(questions.filter(\.weak).sorted { a, b in
            if a.stops != b.stops { return a.stops > b.stops }
            if (a.score ?? 0) != (b.score ?? 0) { return (a.score ?? 0) < (b.score ?? 0) }
            return a.no < b.no
        }.prefix(limit))
    }

    static func advice(_ q: Question) -> String {
        if let advice = q.advice { return advice }
        if q.stops >= 2 { return "这里已经停过 \(q.stops) 次，先把这一段补上。" }
        return q.line ?? "先把这一段补上，再练一次。"
    }

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

    struct Mark: Equatable { var quote: String; var label: String; var state: String }

    static func marks(_ q: Question, _ answer: String?) -> [Mark] {
        guard let answer else { return [] }
        return q.signals.compactMap { signal in
            guard signal.state != "hit", let quote = quoteIn(answer, signal.quote) else { return nil }
            return Mark(quote: quote, label: signal.label, state: signal.state)
        }
    }

    static func markText(_ mark: Mark) -> String { mark.state == "miss" ? "没说到\(mark.label)" : "只说了一半：\(mark.label)" }

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
        questions = questions.map { withContext($0, date: date, context: context) }
        let type = MockMap.typeName(detail)
        let stage = detail.text("stage_label").nonEmptyValue ?? type
        let title = "\(detail.text("company_name").nonEmptyValue ?? "通用练习") \(stage)"
        let stats = MockMap.stats(detail)
        let follows = (detail["questions"]?.items ?? []).filter { $0.text("kind") == "follow_up" }.count
        let role = detail.text("job_title").nonEmptyValue ?? detail.text("target_role").nonEmptyValue
        let meta = [role, "模拟", type, follows > 0 ? "追问 \(follows) 次" : nil, monthDay(date)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
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
            compare: compareLine(score, context?["previous"]?["score"]?.numberValue.map { Int($0.rounded()) }, questions),
            questions: questions, target: target,
            abilities: abilities(report, context),
            voice: detail.text("answer_mode") == "voice" ? metrics.map { m in
                Voice(speed: "\(Int((m["chars_per_minute"]?.numberValue ?? 0).rounded())) 字/分", pauses: "\(m["long_pauses"]?.integer ?? 0) 次",
                      fillers: String(format: "%.1f%%", (m["filler_ratio"]?.numberValue ?? 0) * 100))
            } : nil,
            pastCount: context?["past_count"]?.integer ?? 0)
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
        return Question(
            id: round.main.display("id"), no: no, ref: "\(sequence)", title: round.topic, outcome: outcome,
            level: userDepth ?? aiLevel, aiLevel: aiLevel, expected: expected,
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
                item.text("verdict") == "not_probed" ? nil : Signal(label: item.text("signal"), state: item.text("verdict"), quote: item.text("evidence").nonEmptyValue)
            },
            better: evaluation?.text("reference_answer").nonEmptyValue ?? weakness,
            highlight: highlight,
            advice: (report["actions"]?.items ?? []).first { $0.text("kind") == "practice" && ($0["question_refs"]?.items ?? []).contains { $0.integer == sequence } }?.text("detail").nonEmptyValue,
            history: nil, stops: weak ? 1 : 0, reEvaluated: round.main["re_evaluate_count"]?.integer ?? 3)
    }

    private static func levelResult(_ level: Int?, _ outcome: String, layered: Bool) -> String {
        if layered, let level { return level <= 0 ? "没到「了解」" : levelLabel(level) }
        var q = Question(id: "", no: 0, ref: "", title: "", outcome: Outcome(rawValue: outcome) ?? .unrecorded, level: nil, expected: 0, follows: 0, turns: [], signals: [], stops: 0, reEvaluated: 0)
        q.layered = layered
        return outcomeText(q)
    }

    /// 把「和以往比」接到一道题上：history 第一行是这一场。
    private static func withContext(_ q: Question, date: String, context: JSONValue?) -> Question {
        guard let context, context != .null else { return q }
        let found = (context["questions"]?.items ?? []).first { $0.display("ref") == q.ref }
        var next = q
        let here = History(date: monthDay(date), title: "这场", result: levelResult(q.level, q.outcome.rawValue, layered: q.layered), current: true)
        let past = (found?["history"]?.items ?? []).map { History(date: monthDay($0.text("at")), title: $0.text("title"), result: levelResult($0["level"].flatMap { $0 == .null ? nil : $0.integer }, $0.text("outcome"), layered: q.layered)) }
        next.history = past.isEmpty ? [] : [here] + past
        next.stops = found?["stops"]?.integer ?? (q.weak ? 1 : 0)
        next.recovered = found?["recovered"]?.bool == true
        if next.recovered { next.line = "上次没过，这次答到了。" }
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

    /// 通用能力只看怎么说，不含知识和岗位匹配；能评的太少时才把它们放回来。最多 6 项。
    static func generalAbilities(_ abilities: [Ability]) -> [Ability] {
        let general = abilities.filter { !outside.contains($0.key) }
        let shown = general.count >= 3 ? general : abilities
        return shown.prefix(6).map { item in var item = item; if item.key == "communication" { item.label = "表达水平" }; return item }
    }

    /// 复盘里「练这几题」「练这一处」带到配置页的内容（Web `practicePlan.ts`）。
    static func practiceItem(_ q: Question) -> MockPracticeItem {
        let gaps = gaps(q)
        return MockPracticeItem(
            label: String(q.title.prefix(120)),
            question: String((q.turns.last?.ask ?? q.title).prefix(500)),
            signals: gaps.prefix(5).map { String($0.prefix(300)) },
            note: q.line, tag: repeatTag(q),
            last: [depthLine(q, asReached: true), q.line].compactMap { $0 }.joined(separator: "，"),
            goal: ["答到「\(levelLabel(q.expected))」", gaps.isEmpty ? nil : "把\(gaps.prefix(2).joined(separator: "和"))讲清楚"].compactMap { $0 }.joined(separator: "，"))
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
