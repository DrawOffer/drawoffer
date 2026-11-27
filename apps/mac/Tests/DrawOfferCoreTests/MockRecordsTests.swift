import Foundation
import Testing
@testable import DrawOfferCore

private func json(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

/// 虚构数据：示例科技一面（真实）和一面准备（模拟）挂在同一条投递下，另有一场通用练习和一场放弃的。
private let overview = json(#"""
{"records": [
  {"kind": "real", "id": "s1", "application_id": "a1", "at": "2026-10-28T10:00:00+08:00", "title": "示例科技一面", "round": "一面", "status": "completed", "score": 71, "question_count": 6,
   "stuck": {"topic": "缓存一致性", "detail": "删缓存的时机"}, "topics": [{"name": "缓存一致性", "outcome": "one_short"}]},
  {"kind": "mock", "id": "m1", "application_id": "a1", "at": "2026-10-25T10:00:00+08:00", "title": "一面准备", "type_label": "综合面", "status": "completed", "score": 58, "question_count": 8,
   "stuck": {"topic": "分库分表", "detail": ""}, "topics": []},
  {"kind": "mock", "id": "m2", "application_id": null, "at": "2026-11-20T10:00:00+08:00", "title": "通用练习", "type_label": "综合面", "status": "reviewing", "score": null, "question_count": 5, "stuck": null, "answered": true},
  {"kind": "mock", "id": "m3", "at": "2026-11-18T10:00:00+08:00", "title": "通用练习", "type_label": "综合面", "status": "abandoned", "score": null, "stuck": null}],
 "groups": [{"application_id": "a1", "title": "示例科技 · 后端工程师", "next": {"label": "二面", "at": "2026-11-29T14:00:00+08:00"}}]}
"""#)

@Test func mockRecordsGroupsAndRows() {
    let sections = MockRecords.sections(overview, filter: "all")
    #expect(sections.map(\.title) == ["示例科技 · 后端工程师", "专项与通用练习"])
    #expect(sections[0].rows.count == 2 && sections[1].rows.map { $0.text("id") } == ["m2"])
    #expect(MockRecords.sections(overview, filter: "real").map(\.rows.count) == [1])
    #expect(MockRecords.counts(overview) == ["all": 3, "real": 1, "mock": 2])
    #expect(MockRecords.abandoned(overview, filter: "mock").count == 1 && MockRecords.abandoned(overview, filter: "real").isEmpty)
    let real = sections[0].rows[0]
    #expect(MockRecords.rowTitle(real) == "一面")
    #expect(MockRecords.rowSub(real) == "10-28 · 技术面 · 6 题 · 缓存一致性待追问")
    #expect(MockRecords.rowSub(sections[0].rows[1]) == "10-25 · 综合面 · 8 题 · 分库分表待补齐")
    let now = CareerApplication.date("2026-11-26T09:00:00+08:00")!
    #expect(MockRecords.nextLabel(sections[0].next, now: now)! == (true, "3 天后 · 二面 11-29"))
    #expect(MockRecords.nextLabel(json(#"{"label": "三面", "at": "2026-12-20T10:00:00+08:00"}"#), now: now)! == (false, "三面 12-20"))
    #expect(MockRecords.splitTitle("示例科技 · 后端工程师") == ("示例科技", "后端工程师"))
}

@Test func mockImportTargetsAndBody() throws {
    let targets = json(#"""
    {"sessions": [{"session_id": "11", "application_id": "a1", "title": "示例科技一面", "job_title": "后端", "at": "2026-11-20T10:00:00+08:00", "has_record": true},
                  {"session_id": "12", "application_id": "a1", "title": "示例科技二面", "job_title": "后端", "at": "2026-11-24T10:00:00+08:00", "has_record": false}],
     "applications": [{"application_id": "21", "company_name": "示例数据", "job_title": "数据开发", "stage_hint": "已面到二面", "next_round": 4}]}
    """#)
    let picked = try #require(MockRecords.defaultTarget(targets, sessionID: "12"))
    #expect(picked.label == "示例科技二面 · 11-24 · 已结束")
    #expect(MockRecords.defaultTarget(targets, sessionID: nil)?.company == "示例科技一面")
    #expect(MockRecords.importBody(picked, replace: true, round: "1", day: "2026-11-26") == json(#"{"session_id": "12", "replace": true}"#))
    let application = targets["applications"]!.items[0]
    #expect(MockRecords.defaultRound(application) == "3")
    #expect(MockRecords.importBody(.application(application), replace: false, round: "2", day: "2026-11-25") == json(#"{"application_id": "21", "stage_type": "interview", "round_no": 2, "occurred_on": "2026-11-25"}"#))
    #expect(MockRecords.importBody(.application(application), replace: false, round: "hr", day: "2026-11-25")["stage_type"] == .string("hr"))
    #expect(MockRecords.defaultTarget(json(#"{"sessions": [], "applications": []}"#), sessionID: nil) == nil)
}

@Test func mockWaveCallsAvoidTheLine() {
    let calls = MockWave.calls([80, 88, 54, 84])
    #expect(MockWave.xs(4).first == 88 && MockWave.xs(4).last == 914)
    #expect(MockWave.y(60) == 104)
    // 54 是低谷：写在点下面；88 是峰：写在上面；开头比后一题低也算低谷
    #expect(calls[2] == MockWave.Call(x: MockWave.xs(4)[2], y: MockWave.y(54) + 24, anchor: .middle))
    #expect(calls[1].anchor == .middle && calls[1].y == MockWave.y(88) - 14)
    #expect(calls[0].y == MockWave.y(80) + 24)
    #expect(MockWave.tangents([(0, 10), (10, 0), (20, 10)])[1] == 0)
}
