import Foundation
import Testing
@testable import DrawOfferCore

private func json(_ source: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)) }
private func at(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

private let application = #"""
{"id":"7","status":"active","lifecycle_status":"active","phase":"applied","archived_at":null,"stage_state":"scheduled",
 "offer_status":"none","company_name_snapshot":"示例科技","job_title_snapshot":"后端工程师",
 "applied_at":"2030-09-28T02:00:00Z","applied_channel":"官网","resume_title_snapshot":"后端简历","created_at":"2030-09-27T02:00:00Z","updated_at":"2030-10-05T02:00:00Z",
 "current_stage":{"id":"13","stage_type":"interview","stage_label":"一面"},
 "stages":[
  {"id":"11","sequence_no":1,"stage_type":"screening","stage_label":"筛选中","stage_result":"passed","entered_at":"2030-09-28T02:00:00Z","completed_at":"2030-09-30T02:00:00Z"},
  {"id":"12","sequence_no":2,"stage_type":"written_test","stage_label":"笔试","stage_result":"passed","entered_at":"2030-09-30T02:00:00Z","completed_at":"2030-10-05T02:00:00Z"},
  {"id":"13","sequence_no":3,"stage_type":"interview","stage_label":"一面","stage_result":"pending","current_marker":1,"entered_at":"2030-10-05T02:00:00Z"}]}
"""#
private let sessions = #"""
[{"id":"31","application_id":"7","application_stage_id":"13","status":"scheduled","stage_type":"interview","stage_label":"一面","round_no":1,
  "start_at":"2030-10-08T06:00:00Z","end_at":"2030-10-08T07:00:00Z","mode":"video","schedule_kind":"fixed_slot"},
 {"id":"30","application_id":"7","application_stage_id":"12","status":"completed","stage_type":"written_test","stage_label":"笔试",
  "start_at":"2030-10-04T12:10:00Z","end_at":"2030-10-04T13:25:00Z","mode":"other","schedule_kind":"fixed_slot"}]
"""#

private func step(_ now: Date) throws -> (CareerJourneyStep, CareerJourney.Timeline) {
    let app = try json(application)
    let deck = CareerDeck(application: app, sessions: try json(sessions).items, now: now)
    let current = try #require(deck.current)
    let previous = deck.stations[deck.stations.firstIndex { $0.id == current.id }! - 1]
    return (CareerJourney.step(application: app, deck: deck, station: current, viewing: false, now: now, detail: nil, previous: previous, reviewCost: nil),
            CareerJourney.timeline(application: app, deck: deck, now: now))
}

@Test func journeyBeforeInterviewShowsDeskCalendarAndTodayOnTheWay() throws {
    let (step, timeline) = try step(at("2030-10-06T02:00:00Z"))
    #expect(step.title == ["后天一面", "先练一场"])
    #expect(step.tone == .turn && step.figure == .day)
    #expect(step.primary?.action == .mock)
    #expect(timeline.nodes.map(\.label) == ["投递", "筛选", "笔试", "一面", "Offer"])
    #expect(timeline.nodes[3].line == "10.08 · 后天")
    // 笔试到一面这段走了不到一半：今天落在这段上，但写不下天数
    #expect(timeline.today?.segment == 2 && timeline.today?.days == nil)
    #expect(timeline.todayNode == nil)
    #expect(timeline.segments.map(\.style) == [.past, .past, .current, .future])
    #expect(CareerJourney.canAdvance(CareerDeck(application: try json(application), sessions: [], now: Date()), viewing: false))
}

@Test func journeyOnInterviewDayMarksTheNodeItself() throws {
    let (step, timeline) = try step(at("2030-10-08T03:00:00Z"))
    #expect(step.title == ["今天一面", "还有 3 小时"])
    #expect(step.figure == .clock)
    #expect(timeline.todayNode == "13" && timeline.today == nil)
}

@Test func journeyAfterInterviewAsksForRecordAndWaitsPastTheNode() throws {
    let (step, timeline) = try step(at("2030-10-09T02:00:00Z"))
    #expect(step.title == ["一面面完了", "趁热记下来"])
    #expect(step.figure == .recordEmpty && step.primary?.action == .upload && step.secondary?.action == .paste)
    #expect(timeline.nodes.map(\.label) == ["投递", "筛选", "笔试", "一面", "下一面", "Offer"])
    #expect(timeline.today == CareerJourney.Today(segment: 3, ratio: 0.5, days: 1))
    #expect(timeline.segments[2].style == .past)
}

@Test func journeyPendingAndEndedStates() throws {
    let pending = try json(#"{"id":"1","status":"active","lifecycle_status":"active","phase":"pending","offer_status":"none","created_at":"2030-10-01T02:00:00Z","stages":[]}"#)
    let now = at("2030-10-03T02:00:00Z")
    let deck = CareerDeck(application: pending, sessions: [], now: now)
    let first = CareerJourney.step(application: pending, deck: deck, station: deck.stations[0], viewing: false, now: now, detail: nil, previous: nil, reviewCost: nil)
    #expect(first.title == ["选一份简历", "投出去"] && first.primary?.action == .recordApplied && first.figure == .resume)
    #expect(!CareerJourney.canAdvance(deck, viewing: false))
    #expect(CareerJourney.timeline(application: pending, deck: deck, now: now).head == "导入 2 天，还没投递")

    var raw = try json(application)
    if case .object(var object) = raw {
        object["lifecycle_status"] = .string("terminated"); object["status"] = .string("withdrawn"); object["termination_reason"] = .string("withdrawn")
        raw = .object(object)
    }
    let ended = CareerDeck(application: raw, sessions: [], now: now)
    let last = CareerJourney.step(application: raw, deck: ended, station: ended.stations[ended.stations.count - 1], viewing: false, now: now, detail: nil, previous: nil, reviewCost: nil)
    #expect(last.title == ["这个岗位", "先不继续了"] && last.primary?.action == .reopen && last.figure == .archiveOpen)
}

@Test func journeyOfferTextAndSalaryUnit() throws {
    #expect(CareerJourney.offerSalaryUnit("30K", currency: "", period: "month") == "/ 月")
    #expect(CareerJourney.offerSalaryUnit("300000", currency: "", period: "year") == "元 / 年")
    #expect(CareerJourney.offerSalaryUnit("5000", currency: "usd", period: "month") == "USD / 月")
    let offer = try json(#"{"company_name_snapshot":"示例科技","job_title_snapshot":"后端工程师","offer_salary":"30000","offer_salary_period":"month","offer_benefits_description":"15 薪","offer_start_on":"2031-07-01","offer_base_location":"杭州","offer_reply_due_on":"2030-10-20"}"#)
    let text = CareerJourney.offerText(offer)
    #expect(text.job == "示例科技 · 后端工程师")
    #expect(text.salary == "30K × 15")
    #expect(text.detail == "2031.07.01 入职 · 杭州")
    #expect(text.due == "10.20 前答复")
}

@Test func journeyPaperRowsSkipReverseQuestionsAndFollowTopics() {
    let questions = [RecordQuestion(question: "讲讲订单服务"), RecordQuestion(question: "团队多大？", reply: "八个人"),
                     RecordQuestion(question: "反问：转正流程"), RecordQuestion(question: "缓存一致性")]
    #expect(CareerJourney.paperRows(questions, groups: nil).map(\.title) == ["讲讲订单服务", "缓存一致性"])
    #expect(CareerJourney.topicQuestions(questions) == ["讲讲订单服务", "缓存一致性"])
    let groups: [JSONValue] = [.object(["topic": .string("系统设计"), "questions": .array([.number(1), .number(2)])])]
    let rows = CareerJourney.paperRows(questions, groups: groups)
    #expect(rows.map(\.title) == ["系统设计"] && rows[0].position == 0)
}

@Test func journeyResumeSketchReadsNameSectionsAndSkills() throws {
    let doc = try json(#"""
    {"identity":{"name":{"value":"林一"},"headline":{"value":"后端工程师"}},
     "sections":[{"semantic_kind":"profile","title":{"value":"个人简介"},"entries":[{"fields":{}}]},
      {"semantic_kind":"experience","title":{"value":"工作经历"},"entries":[{"fields":{"organization":{"value":"示例公司"},"role":{"value":"后端"},"start_date":{"value":"2028.07"},"end_date":{"value":"至今"}}}]},
      {"semantic_kind":"skills","title":{"value":"技能"},"entries":[{"fields":{}}]}]}
    """#)
    let sketch = try #require(CareerJourney.resumeSketch(doc))
    #expect(sketch.name == "林一" && sketch.headline == "后端工程师" && sketch.skillsTitle == "技能")
    #expect(sketch.sections == [.init(title: "工作经历", entries: [.init(title: "示例公司 · 后端", period: "2028.07 – 至今")])])
    #expect(CareerJourney.resumeSketch(.object([:])) == nil)
}

// MARK: - 回看过去一轮（07N · 07）

/// 一面已通过、现在在等二面结果；一面这场的记录、复盘按用例填。
private func pastInterview(_ extra: String) throws -> (JSONValue, CareerDeck, CareerStation, Date) {
    let raw = #"""
    {"id":"8","status":"active","lifecycle_status":"active","phase":"applied","archived_at":null,"stage_state":"awaiting_result",
     "offer_status":"none","company_name_snapshot":"示例科技","job_title_snapshot":"后端工程师","resume_id":"r1",
     "applied_at":"2030-09-20T02:00:00Z","applied_channel":"官网","resume_title_snapshot":"后端简历","created_at":"2030-09-19T02:00:00Z","updated_at":"2030-10-20T02:00:00Z",
     "current_stage":{"id":"23","stage_type":"interview","stage_label":"二面"},
     "stages":[
      {"id":"21","sequence_no":1,"stage_type":"screening","stage_label":"筛选中","stage_result":"passed","entered_at":"2030-09-20T02:00:00Z","completed_at":"2030-09-28T02:00:00Z"},
      {"id":"22","sequence_no":2,"stage_type":"interview","stage_label":"一面","stage_result":"passed","entered_at":"2030-09-28T02:00:00Z","completed_at":"2030-10-12T02:00:00Z"},
      {"id":"23","sequence_no":3,"stage_type":"interview","stage_label":"二面","stage_result":"pending","current_marker":1,"entered_at":"2030-10-12T02:00:00Z"}]}
    """#
    let sessions = #"[{"id":"41","application_id":"8","application_stage_id":"22","status":"completed","stage_type":"interview","stage_label":"一面","round_no":1,"start_at":"2030-10-10T06:00:00Z","end_at":"2030-10-10T07:00:00Z","mode":"video","schedule_kind":"fixed_slot""# + extra + "}]"
    let app = try json(raw)
    let now = at("2030-10-20T02:00:00Z")
    let deck = CareerDeck(application: app, sessions: try json(sessions).items, now: now)
    return (app, deck, try #require(deck.stations.first { $0.id == "22" }), now)
}

private func pastStep(_ extra: String, cost: String? = nil) throws -> CareerJourneyStep {
    let (app, deck, station, now) = try pastInterview(extra)
    return CareerJourney.step(application: app, deck: deck, station: station, viewing: true, now: now, detail: nil, previous: deck.stations[0], reviewCost: cost)
}

@Test func journeyPastRoundWithRecordButNoReviewOffersReviewAndAnswers() throws {
    let step = try pastStep(#","questions_markdown":"面试官：讲讲订单服务\n\n我：按领域拆成三块\n\n面试官：缓存一致性\n\n我：先写库再删缓存""#, cost: "6 积分")
    #expect(step.title == ["一面通过了", "记了 2 道题"] && step.tone == .rest)
    #expect(step.desc == "还没复盘。复盘会逐题标出哪里没答好。")
    #expect(step.primary == CareerJourneyButton(.generateReview, "复盘这一轮 · 6 积分") && step.secondary?.action == .openRecord)
    #expect(step.figure == .questionsPast)
    #expect(step.stamp == CareerJourneyStamp(label: "通过", date: "10.10"))
    // 不再有「回到…」按钮
    #expect(step.primary?.action != .backToNow && step.secondary?.action != .backToNow)
    let rows = CareerJourney.paperRows(InterviewRecord.parse("面试官：讲讲订单服务\n\n我：按领域拆成三块\n\n面试官：缓存一致性"), groups: nil)
    #expect(rows.map(\.answer) == ["按领域拆成三块", nil])

    let failed = try pastStep(#","review_status":"failed","questions_markdown":"面试官：讲讲订单服务\n\n我：按领域拆""#)
    #expect(failed.primary?.label == "再试一次" && failed.desc == "复盘没生成，记录都还在，再试一次就行。")
}

@Test func journeyPastRoundReviewedWithWeakQuestionsTurnsOrange() throws {
    let report = #"{"schema_version":2,"headline":"基础扎实","summary":"基础扎实","questions":[{"index":1,"key":"q1","kind":"main","title":"订单拆分","question":"讲讲订单服务？","category":"technical","depth_scored":true,"achieved_depth":3,"target_depth":3},{"index":2,"key":"q2","kind":"main","title":"缓存一致性","question":"缓存怎么一致？","category":"technical","depth_scored":true,"achieved_depth":1,"target_depth":3,"improvement":"补上延迟双删"}]}"#
    let weak = try pastStep(#","review_status":"ready","review_report":"# + report + #","questions_markdown":"面试官：讲讲订单服务？\n\n我：按领域拆""#)
    #expect(weak.title == ["一面通过了", "1 题没答到位"] && weak.tone == .warn)
    #expect(weak.desc == "下一轮前把这几题再练一遍。")
    #expect(weak.primary == CareerJourneyButton(.practiceWeak, "练这 1 题") && weak.secondary == CareerJourneyButton(.openReview, "查看复盘"))
    #expect(weak.figure == .review && weak.stamp?.date == "10.10")

    let good = try pastStep(#","review_status":"ready","review_report":"# + report.replacingOccurrences(of: #""achieved_depth":1"#, with: #""achieved_depth":3"#) + "")
    #expect(good.title == ["一面通过了", "都答到位了"] && good.tone == .rest)
    #expect(good.primary?.action == .openReview && good.secondary == nil)
}

@Test func journeyPastRoundWithoutRecordAndRejectedRound() throws {
    let empty = try pastStep("")
    #expect(empty.title == ["一面通过了", "这一轮没留记录"] && empty.desc == "现在补也来得及，录音或文字稿都行。")
    #expect(empty.primary?.action == .upload && empty.secondary?.action == .paste && empty.more.map(\.action) == [.pickLibrary])
    #expect(empty.figure == .recordEmpty && empty.stamp != nil)

    // 没通过的一轮：结论写没通过，不盖邮戳
    let (app, deck, _, now) = try pastInterview("")
    var raw = app
    if case .object(var object) = raw, case .array(var stages)? = object["stages"], case .object(var first)? = stages.first {
        first["stage_result"] = .string("rejected"); stages[0] = .object(first); object["stages"] = .array(stages); raw = .object(object)
    }
    let rejectedDeck = CareerDeck(application: raw, sessions: deck.stations.compactMap(\.session), now: now)
    let screening = try #require(rejectedDeck.stations.first { $0.kind == .screening })
    let step = CareerJourney.step(application: raw, deck: rejectedDeck, station: screening, viewing: true, now: now, detail: nil, previous: nil, reviewCost: nil)
    #expect(step.title == ["简历筛选没通过", "8 天后有了回音"] && step.stamp == nil)
}

@Test func journeyPastScreeningShowsResumeWithStampAndTimelineHead() throws {
    let (app, deck, _, now) = try pastInterview("")
    let screening = try #require(deck.stations.first { $0.kind == .screening })
    let step = CareerJourney.step(application: app, deck: deck, station: screening, viewing: true, now: now, detail: nil, previous: deck.stations[0], reviewCost: nil)
    #expect(step.title == ["简历筛选通过了", "8 天后有了回音"] && step.tone == .rest)
    #expect(step.desc == "投的是「后端简历」这份简历。")
    #expect(step.primary?.action == .openResume && step.secondary == nil)
    #expect(step.figure == .resume && step.stamp == CareerJourneyStamp(label: "通过", date: "09.28"))
    // 回看不能更新进度
    #expect(!CareerJourney.canAdvance(deck, viewing: true))
}
