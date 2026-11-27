import Foundation
import Testing
@testable import DrawOfferCore

/// 进行中的一场（虚构）：第 2 题「数据工作台分层」正在追问，面试官记了一条答到和一条疑问。
private let liveSession: JSONValue = try! JSONDecoder().decode(JSONValue.self, from: Data(#"""
{"status": "in_progress", "has_intro": true, "answer_mode": "text", "company_name": "示例科技", "stage_label": "一面", "resume_title": "后端简历", "interview_type": "technical", "difficulty": "intermediate", "question_count": 4, "practice_focus": {"label": "缓存一致性"}, "current_question_id": 15, "questions": [{"id": 10, "kind": "main", "plan_index": 0, "sequence_no": 1, "depth_level": 1, "topic": "自我介绍", "content": "请介绍一下自己", "anchor_kind": "intro", "answer_status": "answered", "parent_id": null}, {"id": 11, "kind": "main", "plan_index": 1, "sequence_no": 2, "depth_level": 2, "topic": "缓存一致性", "content": "讲讲缓存", "anchor_kind": "knowledge", "answer_status": "answered", "parent_id": null, "notes": [{"kind": "hit", "text": "先删缓存再写库，说清了时序问题"}]}, {"id": 12, "kind": "follow_up", "sequence_no": 3, "depth_level": 3, "topic": "", "content": "再深一点", "answer_status": "answered", "parent_id": 11}, {"id": 13, "kind": "main", "plan_index": 2, "sequence_no": 4, "depth_level": 2, "topic": "数据工作台分层", "content": "你在「主导数据工作台重构」里怎么分层", "anchor_kind": "resume", "anchor": "主导数据工作台重构", "answer_status": "answered", "parent_id": null, "notes": [{"kind": "hit", "text": "分了 ODS/DWD 两层，理由清楚"}]}, {"id": 15, "kind": "follow_up", "sequence_no": 5, "depth_level": 3, "topic": "", "content": "DWD 层的口径怎么统一", "source_quote": "DWD", "answer_status": "pending", "parent_id": 13, "notes": [{"kind": "question", "text": "口径统一靠什么机制：没讲到"}]}]}
"""#.utf8))

@Test func mockLiveSessionRoundsAndProgress() throws {
    let current = try #require(MockSession.current(liveSession))
    #expect(current.display("id") == "15")
    #expect(MockSession.lastAsked(liveSession)?.display("id") == "15")
    let round = try #require(MockSession.roundOf(liveSession, current))
    #expect(round.main.display("id") == "13" && round.turns.count == 2 && round.ok == nil)
    let intro = try #require(liveSession["questions"]?.items.first)
    #expect(MockMap.isIntro(liveSession, intro))
    let stats = MockMap.stats(liveSession)
    #expect(stats.rounds.map(\.topic) == ["缓存一致性", "数据工作台分层"])
    #expect(stats.follows == 2 && stats.answered == 2)
    #expect(MockSession.hasAnswered(liveSession))
    #expect(MockSession.mmss(75) == "01:15")
}
