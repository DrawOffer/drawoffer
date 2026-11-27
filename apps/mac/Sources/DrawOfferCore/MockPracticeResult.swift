import Foundation

/// 练这几处 / 练这一处练完后的结果页（Figma 10.23a / 10.23b；Web `mock-interview/v2/ReportV2.tsx`、`interviews/report/ReviewReport.tsx` 的 `PracticeList`、
/// `ReviewQuestion.tsx` 的 `single`）：首页、报告里开的专项练习都按「只练这一处」建场（`practice_focus.mode == "single"`），
/// 练完不出完整复盘：几处时总览只列这次练的几处和前后分数（不列建议先补），只有一处时直接看这一题。
public enum MockPracticeResult {
    public enum Layout: Equatable {
        /// 普通复盘
        case report
        /// 10.23a：练这几处
        case set
        /// 10.23b：练这一处，直接看这一题
        case single
    }

    /// 专项练习（练这几处 / 练这一处）的那一场
    public static func isPractice(_ detail: JSONValue) -> Bool { detail["practice_focus"]?["mode"]?.stringValue == "single" }

    public static func layout(_ detail: JSONValue, count: Int) -> Layout {
        guard isPractice(detail) else { return .report }
        return count == 1 ? .single : .set
    }

    /// 标题下面一行：练这 3 处 · 11-20 · 3 题 · 14 分钟
    public static func meta(count: Int, day: String, minutes: Int?) -> String {
        [count == 1 ? "练这一处" : "练这 \(count) 处", day, "\(count) 题", minutes.map { "\($0) 分钟" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 分数旁的「较练习前」：这次练的几处里有上次分的，这次减上次取平均（四舍五入同 JS `Math.round`）；都没有上次分时不写。
    public static func averageGain(_ pairs: [(before: Int?, after: Int?)]) -> Int? {
        let gains = pairs.compactMap { pair -> Int? in
            guard let before = pair.before, let after = pair.after else { return nil }
            return after - before
        }
        guard !gains.isEmpty else { return nil }
        return Int((Double(gains.reduce(0, +)) / Double(gains.count) + 0.5).rounded(.down))
    }

    /// 分数旁的小标签：+5 较上次 / 和上次持平；练这几处时比的是练习前
    public static func deltaText(_ delta: Int, practice: Bool) -> String {
        if delta == 0 { return practice ? "和练习前持平" : "和上次持平" }
        return "\(delta > 0 ? "+\(delta)" : "\(delta)") \(practice ? "较练习前" : "较上次")"
    }

    /// 分数下面加粗的一句：3 处里 2 处达到要求
    public static func headline(total: Int, reached: Int) -> String { "\(total) 处里 \(reached) 处达到要求" }

    /// 每一处左边灰字开头：上次 → 这次分数，没有上次分时只写这次；这次没有分时为空
    public static func scoreText(before: Int?, after: Int?) -> String? {
        guard let after else { return nil }
        guard let before else { return "\(after) 分" }
        return "\(before) → \(after) 分"
    }

    static let levels = ["了解", "熟悉", "掌握", "精通", "专家"]
    public static func levelLabel(_ level: Int) -> String { levels[max(0, min(4, level - 1))] }

    /// 每一处右边、单题分数下面的一句：达到「熟悉」，要求「掌握」；核心要点全没说到时写还没达到起点（Web `reachLine`）。
    /// `outcome` 不分层时直接用（说清了 / 说了一半……）。
    public static func reachLine(layered: Bool, level: Int?, reached: Bool, expected: Int, start: Int?, belowStart: Bool, outcome: String) -> String {
        guard layered else { return outcome }
        guard let level else { return "没记下回答" }
        if belowStart, let start, start > 0 { return "还没达到「\(levelLabel(start))」" }
        let at = level <= 0 ? "没到「了解」" : "达到「\(levelLabel(level))」"
        return reached ? at : "\(at)，要求「\(levelLabel(expected))」"
    }

    /// 完整模拟要的分钟数（8 题 × 5 分钟）
    public static let fullMinutes = MockHome.fullCount * MockHome.minutesPerQuestion

    /// 底部按钮：有没达到的就「完整模拟」+「再练没达到要求的 N 处」，都达到了只剩「完整模拟 · 40 分钟」
    public enum Footer: Equatable {
        case retryWeak(count: Int)
        case fullOnly
    }

    public static func footer(weak: Int) -> Footer { weak > 0 ? .retryWeak(count: weak) : .fullOnly }

    public static func retryTitle(_ count: Int) -> String { "再练没达到要求的 \(count) 处" }

    /// 单题右上的按钮：练这一处练完是「再练一次」，普通复盘里是「练这一处」
    public static func practiceButton(single: Bool) -> String { single ? "再练一次" : "练这一处" }
}
