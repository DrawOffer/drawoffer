import Foundation
import Testing
@testable import DrawOfferCore

private func json(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

/// 虚构数据：示例科技二面还有 1 天，题目挑到第 2 题。
private let detail = json(#"""
{"id": "x", "status": "preparing", "answer_mode": "voice", "company_name": "示例科技", "stage_label": "二面", "job_title": "Java 后端", "question_count": 5,
 "has_past_practice": true,
 "prep": {"stage": "select", "days_left": 1, "strategy": "quiet", "candidates": [], "first": null,
          "picks": [{"topic": "下单接口的幂等", "tag": "resume", "note": "", "source": "e1"},
                    {"topic": "缓存一致性", "tag": "retest", "note": "", "source": null},
                    {"topic": "Kafka", "tag": "job", "note": "简历里还没有写到", "source": null}],
          "sources": [{"id": "e1", "kind": "exp", "name": "订单系统重构", "nodes": [{"text": "设计了下单接口的幂等校验", "state": "new"}, {"text": "缓存一致性", "state": "weak"}]},
                      {"id": "job", "kind": "know", "name": "岗位要求", "nodes": [{"text": "消息队列", "state": "new"}]}]}}
"""#)

@Test func mockPrepWording() {
    #expect(MockPrep.daysLine(detail) == "离示例科技二面还有 1 天")
    #expect(MockPrep.pickingLines(detail).first == "离示例科技二面只剩 1 天：只挑最影响你通过的点，不再试探新内容")
    #expect(MockPrep.pickingLines(detail).count == 8)
    #expect(MockPrep.title(detail, picked: false) == "正在为这一场挑题")
    #expect(MockPrep.sessionLine(detail) == "示例科技 · 二面 · Java 后端 · 语音 · 5 道题")
    #expect(MockPrep.prepNote(detail) == "题目还在准备，已挑好 3 / 5 道")
    let general = json(#"{"status": "preparing", "question_count": 3, "prep": null}"#)
    #expect(MockPrep.daysLine(general) == "按你的经历和这个方向常考的点为你挑题")
    #expect(MockPrep.title(general, picked: false) == "面试官在读你的简历")
    #expect(MockPrep.readingLines(general).count == 3)
    #expect(MockPrep.title(json(#"{"status": "in_progress", "prep": null}"#), picked: false) == "题目已经准备好")
    #expect(abs(MockPrep.duration(picks: 3) - 18.8) < 0.001)
}

@Test func mockPrepPlanMatchesSourceLines() {
    let plan = MockPrep.plan(detail["prep"]!)
    #expect(plan.sources.map(\.name) == ["订单系统重构", "岗位要求"])
    // 简历题对上原句那一行；复测题没写来源，落到同序号的来源里上次没守住的那一行
    #expect(plan.rounds[0].source == 0 && plan.rounds[0].node == 0 && plan.rounds[0].why == "这一行还没练过，先问它" && plan.rounds[0].from == "出自你简历里的一行")
    #expect(plan.rounds[1].source == 1 % 2 && plan.rounds[1].why == "上次没答好，这次再问一次")
    #expect(plan.rounds[2].source == 1 && plan.rounds[2].why == "岗位要、简历里还没有写到：先问接触过没有" && plan.rounds[2].dot == "7FA98F")
    // 没有 sources 的旧数据按标签拼知识来源
    let old = MockPrep.plan(json(#"{"picks": [{"topic": "线程池", "tag": "basics", "note": ""}, {"topic": "限流", "tag": "retest", "note": ""}]}"#))
    #expect(old.sources.map(\.name) == ["这个方向常考", "上次没答好"])
    #expect(old.rounds[1].source == 1 && old.sources[1].nodes[0].state == "weak" && old.rounds[1].from == "上次没答好 · 复测")
}

@Test func mockPrepPhraseAndAnswers() {
    #expect(MockPrep.phraseHits("我准备好了") == [true, true, true, true, true, true, false, false, false, false, false])
    #expect(MockPrep.phraseHits("").allSatisfy { !$0 })
    let answered = json(#"{"has_intro": true, "questions": [{"plan_index": 0, "answer_status": "answered"}, {"plan_index": 1, "answer_status": "pending"}], "report": null}"#)
    #expect(!MockPrep.hasAnswers(answered))
    #expect(MockPrep.hasAnswers(json(#"{"report": {"questions": [{"is_intro": false, "skipped": false}]}}"#)))
    #expect(!MockPrep.hasAnswers(json(#"{"report": {"questions": [{"is_intro": true}, {"is_intro": false, "skipped": true}]}}"#)))
}
