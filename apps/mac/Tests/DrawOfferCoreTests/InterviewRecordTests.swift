import Foundation
import Testing
@testable import DrawOfferCore

@Test func recordParsesTurnsFollowUpsAndReplies() {
    let markdown = "面试官：讲讲订单服务\n\n我：拆单和预占\n\n面试官（追问）：对账挂了怎么办\n\n我：重跑并告警\n\n面试官：团队多大？\n\n面试官（回答）：八个人"
    let questions = InterviewRecord.parse(markdown)
    try? #require(questions.count == 2)
    guard questions.count == 2 else { Issue.record("expected 2 questions"); return }
    #expect(questions[0].answer == "拆单和预占")
    #expect(questions[0].followUps == [.init(question: "对账挂了怎么办", answer: "重跑并告警")])
    #expect(questions[1].question == "团队多大？")
    #expect(questions[1].reply == "八个人")
    #expect(InterviewRecord.parse(InterviewRecord.serialize(questions)) == questions)
}

@Test func recordReadsNumberedListsAndUnnamedSpeakers() {
    #expect(InterviewRecord.parse("1. 自我介绍\n讲了项目\n2. 为什么换工作").map(\.question) == ["自我介绍", "为什么换工作"])
    let speakers = InterviewRecord.parse("说话人 1：你好，介绍一下\n\n说话人 2：我做前端")
    #expect(speakers.count == 1)
    #expect(speakers[0].answer == "我做前端")
}

@Test func careerDeckBuildsApplyAndScreeningStations() throws {
    let now = CareerApplication.date("2030-01-05T08:00:00Z")!
    let app = try JSONDecoder().decode(JSONValue.self, from: Data("""
    {"id":"9","status":"active","lifecycle_status":"active","phase":"applied","offer_status":"none","stage_state":"awaiting_result",
     "applied_at":"2030-01-02T08:00:00Z","created_at":"2030-01-01T08:00:00Z","updated_at":"2030-01-02T08:00:00Z","applied_channel":"官网",
     "current_stage":{"id":"s1","stage_type":"screening"},
     "stages":[{"id":"s1","stage_type":"screening","stage_label":"简历筛选","sequence_no":1,"stage_result":"pending","current_marker":1,"entered_at":"2030-01-02T08:00:00Z","updated_at":"2030-01-02T08:00:00Z"}]}
    """.utf8))
    let deck = CareerDeck(application: app, sessions: [], now: now)
    #expect(deck.stations.map(\.short) == ["投递", "筛选"])
    #expect(deck.current?.title == "简历筛选")
    #expect(deck.days == 3 && deck.daysLabel == "已投递")
    let timeline = CareerJourney.timeline(application: app, deck: deck, now: now)
    #expect(timeline.head == "从投递到现在 · 3 天")
    #expect(timeline.nodes.map(\.label) == ["投递", "筛选", "笔试 / 测评", "面试", "Offer"])
    #expect(timeline.nodes[1].line == "已等 3 天")
    // 筛选没有场次，不画「今天」
    #expect(timeline.today == nil && timeline.todayNode == nil)
    #expect(timeline.segments.map(\.style) == [.current, .future, .future, .future])
}
