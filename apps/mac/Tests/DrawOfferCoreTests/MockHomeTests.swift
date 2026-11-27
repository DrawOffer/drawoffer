import Foundation
import Testing
@testable import DrawOfferCore

private func json(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

/// 虚构数据：示例科技二面在 3 天后，上一轮一面停在「缓存一致性」。
private let overview = json(#"""
{"counts": {"mock": 3, "real": 1},
 "stuck": {"topic": "缓存一致性", "times": 2, "detail": "删缓存的时机", "question": "你提到先删缓存。删完到写库之间来了读请求，怎么办？", "signals": ["延迟双删"],
           "records": [{"date": "2026-11-20T10:00:00+08:00", "title": "示例科技一面", "kind": "real", "quote": "先删缓存再写库。"}]},
 "tallies": {"cleared": {"count": 2}},
 "open_topics": [{"topic": "缓存一致性", "stops": 2, "detail": "删缓存的时机", "note": null, "question": "删完到写库之间来了读请求？", "signals": ["延迟双删"], "source": "real:s1:2", "quote": null, "latest": {"date": "2026-11-20T10:00:00+08:00", "title": "示例科技一面", "kind": "real"}, "level": 2, "target": 3},
                 {"topic": "线程池", "stops": 1, "detail": null, "note": "拒绝策略没讲。", "question": null, "quote": null, "latest": {"date": "2026-11-10T10:00:00+08:00", "title": "通用模拟", "kind": "mock"}, "level": null, "target": null}],
 "mastered": ["索引", "TCP 握手"],
 "records": [{"id": "s1", "kind": "real", "application_id": "a1", "title": "示例科技一面", "at": "2026-11-20T10:00:00+08:00", "status": "completed", "score": 71, "question_count": 4,
              "topics": [{"name": "缓存一致性", "outcome": "missed", "detail": "删缓存的时机", "note": null, "level": 2, "target": 3, "ref": "2", "question": "删完到写库之间来了读请求？", "signals": ["延迟双删"]},
                         {"name": "索引", "outcome": "one_short", "detail": null, "note": null, "level": 2, "target": 3, "ref": "3", "question": null, "signals": []},
                         {"name": "自我介绍", "outcome": "reached", "detail": null, "note": null, "level": 3, "target": 3, "ref": "1", "question": null, "signals": []}]},
             {"id": "m1", "kind": "mock", "title": "通用模拟", "at": "2026-11-10T10:00:00+08:00", "status": "completed", "score": 64,
              "topics": [{"name": "TCP 握手", "outcome": "reached", "detail": null, "note": null, "level": 3, "target": 3, "ref": "1", "question": null, "signals": []}]}]}
"""#)

private let now = CareerApplication.date("2026-11-23T09:00:00+08:00")!
private let applications = [json(#"{"id": "a1", "status": "active", "archived_at": null, "lifecycle_status": "active", "offer_status": "none", "current_stage_type": "interview", "resume_id": "r1"}"#),
                            json(#"{"id": "a2", "status": "active", "archived_at": null, "offer_status": "verbal", "current_stage_type": "offer"}"#)]
private let sessions = [json(#"{"id": "n2", "application_id": "a1", "status": "scheduled", "stage_type": "interview", "company_name": "示例科技", "stage_label": "二面", "job_title": "后端工程师", "start_at": "2026-11-26T14:00:00+08:00", "end_at": "2026-11-26T15:00:00+08:00"}"#),
                        json(#"{"id": "x", "application_id": "a2", "status": "scheduled", "stage_type": "interview", "company_name": "别家", "stage_label": "三面", "start_at": "2026-11-24T14:00:00+08:00", "end_at": "2026-11-24T15:00:00+08:00"}"#)]

@Test func mockHomeUpcomingSkipsOfferApplications() {
    let upcoming = MockHome.upcomingSessions(sessions, applications: applications, now: now)
    #expect(upcoming.map { $0.display("id") } == ["n2"])
    #expect(MockHome.switchLabel(upcoming[0], now: now) == "3 天后 · 示例科技 后端二面")
    #expect(MockHome.sessionLine(upcoming[0], records: overview["records"]?.items ?? [], now: now) == "3 天后 · 上一轮 71 分")
}

@Test func mockHomeRoundItemsAndHero() throws {
    let session = MockHome.upcomingSessions(sessions, applications: applications, now: now)[0]
    let model = MockHome.build(target: .session(session, application: applications[0]), overview: overview, now: now, outline: nil, match: nil)
    #expect(model.title == "示例科技二面")
    #expect(model.items.map(\.name) == ["缓存一致性", "索引"])
    #expect(model.items[0].source == "real:s1:2" && model.items[0].tone == "orange" && model.items[0].right == "达到「熟悉」，要求「掌握」")
    // 索引之后已经掌握：算练过，层级取要求与答到的较高者
    #expect(model.items[1].practised && model.items[1].sub == "之后已练到位" && model.items[1].level == 3)
    let hero = try #require(MockHome.hero(overview, model: model))
    #expect(hero.eyebrow == "接着上次卡住的第 1 题" && hero.tail == "缓存一致性 · 已停过 2 场" && hero.stuck)
    #expect(hero.sub == "11-20 示例科技一面你说到：“先删缓存再写库……”")
    #expect(MockHome.splitQuestion(hero.question) == ["你提到先删缓存。", "删完到写库之间来了读请求，怎么办？"])
    let primary = MockHome.primary(model: model, hero: hero, active: false, evaluating: false)
    #expect(primary.label == "接着练" && primary.minutes == 5 && primary.showSecondary)
    #expect(MockHome.settingsLine(target: .session(session, application: nil), resumeTitle: "后端简历") == "针对示例科技二面 · 专业面 · 中级 · 语音 · 后端简历")
}

@Test func mockHomeIdleAndFirstRound() throws {
    var plain = overview
    if case .object(var fields) = plain { fields["stuck"] = .null; fields["open_topics"] = .array([]); plain = .object(fields) }
    let idle = MockHome.idle(plain)
    #expect(idle.items.isEmpty && MockHome.hero(plain, model: idle) == nil)
    #expect(MockHome.primary(model: idle, hero: nil, active: false, evaluating: false).label == "完整模拟")
    // 第一次面这家：提纲里的经历先问，主按钮先练一场 3 题
    let outline = json(#"{"enabled": true, "hooks": [{"id": "h1", "experience": "订单中台", "text": "订单中台高并发", "held": {"status": "untested", "level": null}, "target_level": 3, "follow_ups": [{"question": "分库分表后怎么防超卖？"}]}], "basics": [{"name": "线程池", "node": "k1", "kind": "knowledge_gap"}]}"#)
    let fresh = json(#"{"id": "n9", "application_id": "a9", "status": "scheduled", "stage_type": "interview", "company_name": "新公司", "stage_label": "一面", "start_at": "2026-11-26T14:00:00+08:00", "end_at": "2026-11-26T15:00:00+08:00"}"#)
    let first = MockHome.build(target: .session(fresh, application: nil), overview: plain, now: now, outline: outline, match: nil)
    #expect(first.primary == "先练一场" && first.items.map(\.name) == ["订单中台", "线程池"])
    let hero = try #require(MockHome.hero(plain, model: first))
    #expect(hero.eyebrow == "上次 4 题已全部答稳" && hero.question == "分库分表后怎么防超卖？" && hero.sub == "已答稳的 2 处自动跳过 · 简历里的经历，面试通常从这里问起")
    #expect(MockHome.openLine(overview["open_topics"]!.items[1]) == "11-10 模拟 · 拒绝策略没讲")
    #expect(MockHome.reachedIn(overview["records"]!.items, name: "TCP 握手") == "11-10 模拟")
}

@Test func mockStartPlanWording() {
    let item = MockStart.Item(label: "缓存一致性", question: "删完到写库之间来了读请求？", signals: ["延迟双删"], source: "real:s1:2")
    #expect(MockStart.title(.full(count: nil, title: nil), hasSession: false) == "通用练习")
    #expect(MockStart.title(.set([item], title: "接着练"), hasSession: true) == "接着练")
    #expect(MockStart.subtitle(.set([item, item, item], title: nil), count: 3) == "3 题 · 约 15 分钟")
    #expect(MockStart.subtitle(.single(item, ref: nil, focusKind: nil, origin: nil), count: 1) == "单题练习 · 约 5 分钟")
    let experience = MockStart.Experience(ref: "e1", label: "订单中台")
    #expect(MockStart.count(.experience(experience)) == 6)
    #expect(MockStart.count(.experience(experience), packaged: 3, pending: 2, scope: "packaged") == 3)
    let focus = MockStart.practiceFocus(.set([item], title: nil), scope: "packaged", packaged: 0)
    #expect(focus?.text("ref") == "free:缓存一致性" && focus?.text("mode") == "single" && focus?["items"]?.items.first?.text("source") == "real:s1:2")
    #expect(MockStart.practiceFocus(.full(count: 3, title: nil), scope: "packaged", packaged: 0) == nil)
    #expect(MockStart.practiceFocus(.experience(experience), scope: "packaged", packaged: 0)?.text("scope") == "all")
    let text = json(#"{"priceMode": "fixed", "unitPoints": "2.5"}"#), voice = json(#"{"priceMode": "fixed", "unitPoints": "4"}"#)
    #expect(MockStart.cost(text: text, voice: voice, count: 3) == MockStart.Cost(label: "消耗 12 积分", points: 12))
    #expect(MockStart.cost(text: text, voice: nil, count: 3)?.label == "消耗 7.5 积分")
    #expect(MockStart.cost(text: json(#"{"priceMode": "free"}"#), voice: nil, count: 3)?.label == "本次免费")
}
