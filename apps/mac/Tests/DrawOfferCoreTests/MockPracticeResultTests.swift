import Foundation
import Testing
@testable import DrawOfferCore

private func detail(_ json: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }

@Test func practiceResultLayoutFollowsPracticeFocusMode() {
    let set = detail(#"{"practice_focus": {"kind": "topic", "ref": "free:订单中台", "label": "订单中台", "mode": "single", "items": []}}"#)
    #expect(MockPracticeResult.isPractice(set))
    #expect(MockPracticeResult.layout(set, count: 3) == .set)
    #expect(MockPracticeResult.layout(set, count: 1) == .single)
    // 完整模拟、练经历、没有 practice_focus 的都是普通复盘
    #expect(MockPracticeResult.layout(detail(#"{"practice_focus": null}"#), count: 1) == .report)
    #expect(MockPracticeResult.layout(detail(#"{}"#), count: 3) == .report)
    #expect(MockPracticeResult.layout(detail(#"{"practice_focus": {"mode": "experience"}}"#), count: 1) == .report)
}

@Test func practiceResultMetaAndHeadline() {
    #expect(MockPracticeResult.meta(count: 3, day: "11-20", minutes: 14) == "练这 3 处 · 11-20 · 3 题 · 14 分钟")
    #expect(MockPracticeResult.meta(count: 1, day: "11-20", minutes: nil) == "练这一处 · 11-20 · 1 题")
    #expect(MockPracticeResult.headline(total: 3, reached: 2) == "3 处里 2 处达到要求")
}

@Test func practiceResultScoreChange() {
    // 只有重练同一道题的才有上次分；平均按 JS Math.round（.5 往上）
    #expect(MockPracticeResult.averageGain([(before: 54, after: 78), (before: 40, after: 62), (before: nil, after: 74)]) == 23)
    #expect(MockPracticeResult.averageGain([(before: nil, after: 74), (before: 60, after: nil)]) == nil)
    #expect(MockPracticeResult.averageGain([(before: 50, after: 53), (before: 50, after: 52)]) == 3)
    #expect(MockPracticeResult.averageGain([(before: 50, after: 47), (before: 50, after: 48)]) == -2)
    #expect(MockPracticeResult.deltaText(23, practice: true) == "+23 较练习前")
    #expect(MockPracticeResult.deltaText(-4, practice: true) == "-4 较练习前")
    #expect(MockPracticeResult.deltaText(0, practice: true) == "和练习前持平")
    #expect(MockPracticeResult.deltaText(5, practice: false) == "+5 较上次")
    #expect(MockPracticeResult.deltaText(0, practice: false) == "和上次持平")
    #expect(MockPracticeResult.scoreText(before: 54, after: 78) == "54 → 78 分")
    #expect(MockPracticeResult.scoreText(before: nil, after: 74) == "74 分")
    #expect(MockPracticeResult.scoreText(before: 40, after: nil) == nil)
}

@Test func practiceResultReachLine() {
    #expect(MockPracticeResult.reachLine(layered: true, level: 3, reached: true, expected: 3, start: nil, belowStart: false, outcome: "答到位") == "达到「掌握」")
    #expect(MockPracticeResult.reachLine(layered: true, level: 2, reached: false, expected: 3, start: nil, belowStart: false, outcome: "差一点") == "达到「熟悉」，要求「掌握」")
    #expect(MockPracticeResult.reachLine(layered: true, level: 0, reached: false, expected: 2, start: nil, belowStart: false, outcome: "没答上") == "没到「了解」，要求「熟悉」")
    #expect(MockPracticeResult.reachLine(layered: true, level: 0, reached: false, expected: 3, start: 2, belowStart: true, outcome: "没答上") == "还没达到「熟悉」")
    #expect(MockPracticeResult.reachLine(layered: true, level: nil, reached: false, expected: 3, start: nil, belowStart: false, outcome: "没记下") == "没记下回答")
    #expect(MockPracticeResult.reachLine(layered: false, level: 2, reached: false, expected: 3, start: nil, belowStart: false, outcome: "说了一半") == "说了一半")
}

@Test func practiceResultFooterAndButtons() {
    #expect(MockPracticeResult.footer(weak: 1) == .retryWeak(count: 1))
    #expect(MockPracticeResult.footer(weak: 0) == .fullOnly)
    #expect(MockPracticeResult.retryTitle(2) == "再练没达到要求的 2 处")
    #expect(MockPracticeResult.fullMinutes == 40)
    #expect(MockPracticeResult.practiceButton(single: true) == "再练一次")
    #expect(MockPracticeResult.practiceButton(single: false) == "练这一处")
}
