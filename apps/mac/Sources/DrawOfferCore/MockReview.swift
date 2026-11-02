import Foundation

/// 面试复盘的统一结构（Web `interviews/report/reviewView.ts`、`fromMock.ts`）：模拟面试的评估报告先转成这一份，
/// 再交给同一套四页复盘画（总览、没答到位的题、能力表现、下一步）。
public enum MockReview {
    public enum Outcome: String, Sendable { case reached, oneShort = "one_short", missed, unrecorded }

    public struct Question: Equatable, Sendable {
        public let id: String
        public let no: Int
        public let title: String
        public let outcome: Outcome
        public let layered: Bool
        public let level: Double?
        public let expected: Double
        public let score: Int?
        public let follows: Int
        public let sector: String
        public let ask: String
        public let answer: String?
        public let better: String?
        public let miss: String?
        public let note: String?
        public let followUp: Bool
        public let parentNo: Int?
    }

    public struct Dimension: Equatable, Sendable {
        public let key: String
        public let label: String
        public let assessed: Bool
        public let steps: Int?
        public let score: Int?
        public let max: Int
        public let average: Double?
        public let averageCount: Int
        public let comparison: (text: String, tone: String)?
        public let comment: String?
        public let evidence: String?
        public let evidenceNo: Int?
        public let offReason: String?
        public static func == (a: Dimension, b: Dimension) -> Bool { a.key == b.key && a.score == b.score && a.assessed == b.assessed && a.steps == b.steps }
    }

    public struct Action: Equatable, Sendable {
        public let title: String
        public let detail: String?
        public let key: Bool
        public let refs: [Int]
        public let kind: String
        public let done: Bool
    }

    public struct Stat: Equatable, Sendable { public let value: String; public let label: String; public let orange: Bool }

    public struct View: Sendable {
        public let title: String
        public let sub: String
        public let score: Int?
        public let verdict: (text: String, tone: MockMap.Tone)?
        public let headline: String
        public let summary: String
        public let stats: [Stat]
        public let questions: [Question]
        public let target: Double
        public let targetLabel: String
        public let dimensions: [Dimension]
        public let pastCount: Int
        public let actions: [Action]
    }

    public struct Row: Sendable {
        public let round: MockMap.Round
        public let evaluation: JSONValue?
        public let no: Int
    }

    public static let dimensionLabels = [
        "professional_depth": "专业深度", "structure": "表达结构", "job_fit": "岗位匹配", "resume_consistency": "简历一致性", "communication": "沟通表现",
        "knowledge": "知识与原理", "problem_solving": "方案与权衡", "ownership": "项目主导与成果", "motivation": "动机与稳定性",
        "structured_thinking": "结构化思考", "analysis": "分析判断", "planning": "计划组织协调", "resilience": "应变与抗压",
        "collaboration": "协作与影响", "learning": "学习能力", "professionalism": "职业素养",
    ]

    public static func levelLabel(_ level: Double) -> String { MockMap.levels[Swift.max(0, Swift.min(4, Int(level) - 1))] }

    /// 一道主问题连同它的追问算一题；报告里的单题评估和题目上最新的评估合并。
    public static func rows(_ detail: JSONValue, _ report: JSONValue) -> [Row] {
        let rounds = MockMap.rounds(detail).filter { !$0.intro }
        let fromReport = report["questions"]?.items ?? []
        return rounds.enumerated().map { index, round in
            let sequence = round.main["sequence_no"]?.numberValue
            let found = fromReport.first { $0["sequence_no"]?.numberValue == sequence }
            var evaluation = found
            if case .object(var merged)? = found, case .object(let latest)? = round.main["evaluation"] {
                for (key, value) in latest where key != "topic" && key != "sequence_no" { merged[key] = value }
                evaluation = .object(merged)
            }
            return Row(round: round, evaluation: evaluation, no: index + 1)
        }
    }

    static func depth(_ evaluation: JSONValue) -> Double { Swift.max(0, Swift.min(5, evaluation["achieved_depth"]?.numberValue ?? 0)) }

    static func outcome(_ row: Row, target: Double) -> Outcome {
        guard let evaluation = row.evaluation, evaluation != .null else { return .unrecorded }
        if let value = evaluation.text("outcome").nonEmptyValue { return value == "not_judged" ? .unrecorded : Outcome(rawValue: value) ?? .unrecorded }
        if evaluation["skipped"]?.bool == true { return .missed }
        let gap = target - depth(evaluation)
        if gap <= 0 { return .reached }
        if evaluation.text("depth_status") == "not_probed" { return .oneShort }
        return gap == 1 ? .oneShort : .missed
    }

    private static let sectorNames = ["resume": "讲项目", "job": "岗位要求", "material": "资料", "intro": "自我介绍"]

    public static func view(_ detail: JSONValue, _ report: JSONValue, rows: [Row], title: String, sub: String) -> View {
        let target = MockMap.diffLevel[detail.text("difficulty")] ?? 3
        let category = detail["category"]
        let fallback = category != nil && category != .null && category?.text("id") != "rd" ? "专业问答" : "技术问答"
        let noOf = { (sequence: Double) in rows.first { $0.round.main["sequence_no"]?.numberValue == sequence }?.no }
        let questions = rows.map { row -> Question in
            let evaluation = row.evaluation.flatMap { $0 == .null ? nil : $0 }
            let last = row.round.turns.last ?? row.round.main
            let miss = (evaluation?["signals"]?.items ?? []).first { ["miss", "partial"].contains($0.text("verdict")) }
            let skipped = evaluation?["skipped"]?.bool == true
            return Question(
                id: row.round.main.display("id"), no: row.no, title: row.round.topic, outcome: outcome(row, target: target), layered: true,
                level: evaluation.map { skipped ? 0 : depth($0) },
                expected: (evaluation?["target_depth"]?.numberValue).flatMap { $0 > 0 ? $0 : nil } ?? target,
                score: evaluation?["score"]?.numberValue.map { Int($0.rounded()) },
                follows: Swift.max(0, row.round.turns.count - 1),
                sector: sectorNames[row.round.main.text("anchor_kind")] ?? fallback,
                ask: last.text("content"),
                answer: last.text("answer_status") == "answered" ? last.text("answer_text") : nil,
                better: evaluation?.text("reference_answer").nonEmptyValue ?? evaluation?["weaknesses"]?.items.first?.stringValue,
                miss: miss?.text("signal"), note: skipped ? "跳过了这道题" : nil, followUp: false, parentNo: nil)
        }
        let competencies = report["competencies"]?.items ?? []
        let source = competencies.isEmpty ? (report["dimensions"]?.items ?? []) : competencies
        let dimensions = source.map { item -> Dimension in
            let score = item["score"]?.numberValue
            let assessed = competencies.isEmpty ? true : item["assessed"]?.bool == true && score != nil
            let refs = (item["question_refs"]?.items ?? []).compactMap(\.numberValue)
            return Dimension(
                key: item.text("key"), label: dimensionLabels[item.text("key")] ?? item.text("key"), assessed: assessed,
                steps: assessed ? score.map { Swift.max(1, Swift.min(5, Int(($0 / 20).rounded(.up)))) } : nil,
                score: assessed ? score.map { Int($0.rounded()) } : nil, max: 100, average: nil, averageCount: 0, comparison: nil,
                comment: item.text("comment").nonEmptyValue, evidence: nil, evidenceNo: refs.lazy.compactMap(noOf).first,
                offReason: assessed ? nil : "这场没考到")
        }
        let level = report["verdict"]?.text("level").nonEmptyValue
        let missed = questions.filter { $0.outcome == .missed }.count
        let follows = (detail["questions"]?.items ?? []).filter { $0.text("kind") == "follow_up" }.count
        let done = Set((detail["done_actions"]?.items ?? []).compactMap(\.integer))
        let actions = (report["actions"]?.items ?? []).prefix(3).enumerated().map { index, action in
            let quote = action.text("resume_quote")
            return Action(title: action.text("title"),
                          detail: quote.isEmpty ? action.text("detail").nonEmptyValue : "\(quote) → \(action.text("detail"))",
                          key: action.text("priority") == "high",
                          refs: (action["question_refs"]?.items ?? []).compactMap(\.numberValue).compactMap(noOf),
                          kind: action.text("kind").nonEmptyValue ?? "practice", done: done.contains(index))
        }
        return View(
            title: title, sub: sub, score: report["total_score"]?.numberValue.map { Int($0.rounded()) },
            verdict: level.map { (MockMap.verdictName[$0] ?? $0, MockMap.verdictTone($0)) },
            headline: report.text("headline"), summary: report.text("summary"),
            stats: [
                Stat(value: "\(questions.filter { $0.outcome == .reached }.count) / \(questions.count) 道", label: "答到位", orange: false),
                Stat(value: "\(missed) 道", label: "没答上", orange: missed > 0),
                Stat(value: "\(follows) 次", label: "追问", orange: false),
            ],
            questions: questions, target: target,
            targetLabel: "\(MockMap.diffName[detail.text("difficulty")] ?? "中级")目标线 · 要答进「\(levelLabel(target))」",
            dimensions: dimensions, pastCount: 0, actions: Array(actions))
    }

    public static func outcomeText(_ question: Question) -> String {
        if !question.layered { return [.reached: "说清了", .oneShort: "说了一半", .missed: "没说清", .unrecorded: "没记下"][question.outcome]! }
        return [.reached: "答到位", .oneShort: "差一点", .missed: "没答上", .unrecorded: "没记下"][question.outcome]!
    }

    /// 需要补的题：没答上在前，差一点在后，各自按提问顺序。
    public static func weak(_ view: View) -> [Question] {
        view.questions.filter { $0.outcome == .missed } + view.questions.filter { $0.outcome == .oneShort }
    }

    static func short(_ text: String, _ limit: Int) -> String {
        let chars = Array(text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        return chars.count > limit ? String(chars.prefix(limit)) + "…" : String(chars)
    }

    public struct OverviewMap: Sendable {
        public let points: [MockMap.Point]
        public let sectors: [MockMap.Sector]
        public let path: [MockMap.PathStep]
        public let bounds: [Double]
        public let hot: [String]
    }

    /// 总览的掌握程度图：一题一槽，同一分区挨着，半径是答到的级，没答到的停在下一级画 ×。
    public static func overviewMap(_ questions: [Question]) -> OverviewMap? {
        guard !questions.isEmpty else { return nil }
        var groups: [String] = []
        for question in questions where !groups.contains(question.sector) { groups.append(question.sector) }
        let ordered = groups.flatMap { name in questions.filter { $0.sector == name } }
        let step = 360 / Double(ordered.count)
        var angleOf: [String: Double] = [:]
        for (position, question) in ordered.enumerated() { angleOf[question.id] = -150 + Double(position) * step }
        let limit = questions.count >= 8 ? 8 : questions.count >= 6 ? 10 : 12
        let stop = { (q: Question) -> Double in
            guard let level = q.level else { return 0 }
            return q.outcome == .reached ? Swift.max(1, level) : Swift.min(5, level + 1)
        }
        let points = questions.map { q in
            MockMap.Point(id: q.id, name: short(q.title, limit), sector: q.sector, angle: angleOf[q.id] ?? 0, level: stop(q), ask: 2)
        }
        let sectors = groups.map { name -> MockMap.Sector in
            let angles = ordered.filter { $0.sector == name }.map { angleOf[$0.id] ?? 0 }
            return MockMap.Sector(name: name, angle: ((angles.min() ?? 0) + (angles.max() ?? 0)) / 2)
        }
        let bounds = groups.count > 1 ? groups.map { name in (angleOf[ordered.first { $0.sector == name }!.id] ?? 0) - step / 2 } : []
        let path = questions.filter { $0.level != nil }.map { MockMap.PathStep(id: $0.id, from: 1, to: stop($0), ok: $0.outcome == .reached) }
        return OverviewMap(points: points, sectors: sectors, path: path, bounds: bounds, hot: points.map(\.id))
    }

    /// 面试记录：主问题 + 回答，后面的追问依次跟上；跳过的题没有回答。
    public static func record(_ detail: JSONValue) -> [(question: String, answer: String, followUps: [(question: String, answer: String)])] {
        let said = { (turn: JSONValue) in turn.text("answer_status") == "answered" ? turn.text("answer_text") : "" }
        return MockMap.rounds(detail).map { round in
            (round.main.text("content"), said(round.main), round.turns.dropFirst().map { ($0.text("content"), said($0)) })
        }
    }

    /// 单题详情里原识别稿的截短（按字符，不按显示宽度）。
    public static func shortText(_ text: String, _ limit: Int = 14) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// 改动比例：编辑距离 ÷ 原文长度（Web `mockInterviewText.changeRatio`）。
    public static func changeRatio(_ original: String, _ next: String) -> Double {
        let a = Array(original.trimmingCharacters(in: .whitespacesAndNewlines).utf16), b = Array(next.trimmingCharacters(in: .whitespacesAndNewlines).utf16)
        if a.isEmpty { return b.isEmpty ? 0 : 1 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = previous[0]
            previous[0] = i
            if b.isEmpty { continue }
            for j in 1...b.count {
                let temp = previous[j]
                previous[j] = Swift.min(previous[j] + 1, previous[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
                diagonal = temp
            }
        }
        return Double(previous[b.count]) / Double(a.count)
    }
}
