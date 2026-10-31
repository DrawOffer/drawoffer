import Foundation
import Testing
@testable import DrawOfferCore

/// 虚构数据；期望值由 Web `homeModel.ts` / `sessionLayout.ts` 对同一份数据算出（esbuild 打包后在 Node 里运行）。
private let fixture: JSONValue = try! JSONDecoder().decode(JSONValue.self, from: Data(#"""
{
 "atlas": {"enabled": true, "gaps": [], "nodes": [
  {"key":"cache","name":"缓存一致性","kind":"knowledge","domain":"后端","level":2,"previous_level":1,"real_count":2,"mock_count":1,"asks":[{"kind":"real","depth":2,"company":"示例科技","stage":"一面","date":"2026-10-01T10:00:00Z","source_id":"x"}]},
  {"key":"index","name":"数据库索引","kind":"knowledge","domain":"后端","level":3,"previous_level":null,"real_count":0,"mock_count":1,"asks":[]},
  {"key":"react","name":"React 渲染","kind":"knowledge","domain":"前端","level":1,"previous_level":null,"real_count":1,"mock_count":0,"asks":[]},
  {"key":"tcp","name":"TCP 拥塞控制","kind":"knowledge","domain":"网络","level":0,"previous_level":null,"real_count":0,"mock_count":0,"asks":[]},
  {"key":"talk","name":"结构化表达","kind":"competency","domain":null,"level":2,"previous_level":null,"real_count":0,"mock_count":2,"asks":[]}
 ]},
 "outline": {"enabled": true, "target": null, "basics": [], "hooks": [
  {"id":"h1","kind":"experience","experience":"青舟软件有限公司","text":"主导数据工作台重构","transfer":false,"held":{"status":"held","level":2,"statement":"讲清了分层"},"target_level":3,"asked":"高","follow_ups":[{"level":3,"question":"为什么这样分层","source":"model"}],"practice":{"kind":"experience","ref":"e1","label":"数据工作台"}},
  {"id":"h2","kind":"number","experience":"样例实验室","text":"把延迟降到 40ms","transfer":false,"held":{"status":"untested","level":null,"statement":""},"target_level":3,"asked":"中","follow_ups":[],"practice":null}
 ]},
 "match": {"enabled": true, "match_status": "ready", "requirements": [
  {"id":"r1","group":"skill","text":"熟悉后端消息队列","importance":"must","interview":{"status":"insufficient","skills":[{"name":"消息队列"}]},"nodes":[]},
  {"id":"r2","group":"qualification","text":"本科","importance":"must","interview":{"status":"insufficient","skills":[]},"nodes":[]}
 ]},
 "detail": {"status":"completed","has_intro":true,"questions":[
  {"id":10,"kind":"main","plan_index":0,"sequence_no":1,"depth_level":1,"topic":"自我介绍","content":"请介绍一下自己","anchor_kind":"intro","answer_status":"answered","evaluation":null,"parent_id":null},
  {"id":11,"kind":"main","plan_index":1,"sequence_no":2,"depth_level":2,"topic":"缓存一致性","content":"讲讲缓存","anchor_kind":"knowledge","answer_status":"answered","evaluation":{"achieved_depth":3,"probed_depth":3,"depth_status":"met"},"parent_id":null},
  {"id":12,"kind":"follow_up","sequence_no":3,"depth_level":3,"topic":"","content":"再深一点","answer_status":"answered","parent_id":11},
  {"id":13,"kind":"main","plan_index":2,"sequence_no":4,"depth_level":2,"topic":"数据工作台分层","content":"你在「主导数据工作台重构」里怎么分层","anchor_kind":"resume","anchor":"主导数据工作台重构","answer_status":"answered","evaluation":{"achieved_depth":2,"probed_depth":3,"depth_status":"below"},"parent_id":null},
  {"id":14,"kind":"main","plan_index":3,"sequence_no":5,"depth_level":1,"topic":"消息队列选型","content":"说说消息队列","anchor_kind":"job","answer_status":"skipped","evaluation":null,"parent_id":null}
 ]}
}
"""#.utf8))

private func r(_ value: Double) -> Double { (value * 100).rounded() / 100 }

@Test func mockHomePointsMatchWebModel() {
    let (points, sectors) = MockMap.homePoints(atlas: fixture["atlas"], outline: fixture["outline"], match: fixture["match"], type: "comprehensive")
    #expect(points.map { [$0.point.id, $0.point.name, $0.point.sector, "\(r($0.point.angle))", "\($0.point.level)", "\($0.point.ask)"] } == [
        ["j:r1", "消息队列", "后端", "-136.0", "0.0", "3"], ["n:cache", "缓存一致性", "后端", "-120.0", "2.0", "3"],
        ["n:index", "数据库索引", "后端", "-104.0", "3.0", "1"], ["n:react", "React 渲染", "前端", "-60.0", "1.0", "2"],
        ["n:tcp", "TCP 拥塞控制", "网络", "0.0", "0.0", "1"], ["e:青舟软件有限公司", "青舟软件有限公司", "项目经历", "108.0", "2.0", "3"],
        ["e:样例实验室", "样例实验室", "项目经历", "132.0", "0.0", "2"], ["n:talk", "结构化表达", "表达", "180.0", "2.0", "2"],
    ])
    #expect(sectors.map(\.name) == ["后端", "前端", "网络", "__empty_3", "项目经历", "表达"])
    #expect(MockMap.suggestFocus(points, targetLevel: 3)?.point.id == "n:react")
}

@Test func mockHomeLabelsAvoidCollisionsLikeWeb() {
    let (points, sectors) = MockMap.homePoints(atlas: fixture["atlas"], outline: fixture["outline"], match: fixture["match"], type: "comprehensive")
    let placed = MockMap.place(MockMap.Geo(cx: 770, cy: 316, k: 1), points.map(\.point))
    let layout = MockLayout.homeMap(points: placed, sectors: sectors, targetLevel: 3, targetLabel: "中级目标线 · 要答到「掌握」",
                                    subs: [points[0].point.id: "差 1 层"], strong: ["n:react"], gaps: true)
    let expected: [String: [Double]] = [
        "n:react": [886.81, 108.07], "j:r1": [531, 101.12], "n:cache": [619.14, 151.99], "e:青舟软件有限公司": [614.72, 476.4],
        "e:样例实验室": [531.95, 510.91], "n:talk": [536, 307.5], "n:index": [712.03, 174.84], "n:tcp": [1028.61, 326.61],
    ]
    #expect(layout.labels.mapValues { [r($0.box.l), r($0.box.t)] } == expected)
    #expect(layout.sectors.mapValues { [r($0.x), r($0.y)] } == ["后端": [628, 70.05], "前端": [912, 70.05], "网络": [1054, 316], "项目经历": [628, 561.95], "表达": [486, 316]])
}

@Test func mockSessionSlotsAndPathMatchWeb() throws {
    let (points, _) = MockMap.homePoints(atlas: fixture["atlas"], outline: fixture["outline"], match: fixture["match"], type: "comprehensive")
    let slots = try #require(MockLayout.slots(fixture["detail"]!, memory: points.map(\.point)))
    #expect(slots.points.map { [$0.id, $0.name, $0.sector, "\(r($0.angle))", "\($0.level)"] } == [
        ["q:11", "缓存一致性", "后端", "-150.0", "3.0"], ["q:13", "数据工作台分层", "项目经历", "90.0", "3.0"], ["q:14", "消息队列选型", "后端", "-30.0", "1.0"],
    ])
    #expect(slots.path == [MockMap.PathStep(id: "q:11", from: 2, to: 3, ok: true), MockMap.PathStep(id: "q:13", from: 2, to: 3, ok: false), MockMap.PathStep(id: "q:14", from: 1, to: 1, ok: false)])
    #expect(slots.bounds.map(r) == [-210, 30])
    let layout = MockLayout.homeSession(slots, targetLevel: 3, targetLabel: "中级目标线 · 要答到「掌握」")
    #expect(layout.labels.mapValues { [r($0.box.l), r($0.box.t)] } == ["q:11": [600.47, 270.36], "q:13": [780.61, 439.11], "q:14": [955.98, 225.36]])
}

/// 进行中的一场（虚构）：第 2 题「数据工作台分层」正在追问，面试官记了一条答到和一条疑问。
private let liveSession: JSONValue = try! JSONDecoder().decode(JSONValue.self, from: Data(#"""
{"status": "in_progress", "has_intro": true, "answer_mode": "text", "company_name": "示例科技", "stage_label": "一面", "resume_title": "后端简历", "interview_type": "technical", "difficulty": "intermediate", "question_count": 4, "practice_focus": {"label": "缓存一致性"}, "current_question_id": 15, "questions": [{"id": 10, "kind": "main", "plan_index": 0, "sequence_no": 1, "depth_level": 1, "topic": "自我介绍", "content": "请介绍一下自己", "anchor_kind": "intro", "answer_status": "answered", "parent_id": null}, {"id": 11, "kind": "main", "plan_index": 1, "sequence_no": 2, "depth_level": 2, "topic": "缓存一致性", "content": "讲讲缓存", "anchor_kind": "knowledge", "answer_status": "answered", "parent_id": null, "notes": [{"kind": "hit", "text": "先删缓存再写库，说清了时序问题"}]}, {"id": 12, "kind": "follow_up", "sequence_no": 3, "depth_level": 3, "topic": "", "content": "再深一点", "answer_status": "answered", "parent_id": 11}, {"id": 13, "kind": "main", "plan_index": 2, "sequence_no": 4, "depth_level": 2, "topic": "数据工作台分层", "content": "你在「主导数据工作台重构」里怎么分层", "anchor_kind": "resume", "anchor": "主导数据工作台重构", "answer_status": "answered", "parent_id": null, "notes": [{"kind": "hit", "text": "分了 ODS/DWD 两层，理由清楚"}]}, {"id": 15, "kind": "follow_up", "sequence_no": 5, "depth_level": 3, "topic": "", "content": "DWD 层的口径怎么统一", "source_quote": "DWD", "answer_status": "pending", "parent_id": 13, "notes": [{"kind": "question", "text": "口径统一靠什么机制：没讲到"}]}]}
"""#.utf8))

@Test func mockLiveSessionMatchesWeb() throws {
    let (points, sectors) = MockMap.homePoints(atlas: fixture["atlas"], outline: fixture["outline"], match: nil, type: "technical")
    let current = MockSession.current(liveSession)
    #expect(MockSession.heading(liveSession) == "示例科技 一面准备 · 文字面试")
    #expect(MockSession.subtitle(liveSession) == "专业面 · 中级 · 4 题 · 先问 缓存一致性")
    #expect(MockSession.progress(liveSession, current) == "第 2 / 4 题 · 追问 1 次")
    #expect(MockSession.beads(liveSession, current).map { "\($0.id) \($0.title) \($0.state) \($0.followUps)" } == ["11 缓存一致性 done 1", "13 数据工作台分层 now 1", "todo-2 … todo 0", "todo-3 … todo 0"])
    #expect(MockSession.shortNote("口径统一靠什么机制：没讲到", 10) == "口径统一靠什么机制")
    #expect(MockSession.shortNote("Redis Cluster 的 slot 迁移过程很长很长", 10) == "Redis Cluster 的…")
    for (phase, ann, box) in [(MockSession.Phase.thinking, "? 掌握 · 口径统一靠什么机制", [779.64, 339.21]), (.asking, "追问 · 掌握", [830.54, 339.21])] {
        let map = MockSession.map(liveSession, memory: points.map(\.point), memorySectors: sectors, experienceOf: nil, current: current, phase: phase)
        #expect(map.rotation == 150)
        #expect(map.now == "q:13")
        #expect(map.path == [MockMap.PathStep(id: "q:11", from: 2, to: 3, ok: true), MockMap.PathStep(id: "q:13", from: 2, to: 3, ok: nil)])
        #expect(map.annotations.map(\.text) == ["✓ 熟悉 · 分了 ODS/DWD 两层", ann])
        #expect(map.points.map { r($0.angle) } == [0, 180])
        let layout = try #require(MockSession.layout(map, targetLevel: 3, labelAll: false))
        #expect(layout.labels.mapValues { [r($0.box.l), r($0.box.t)] } == ["q:13": box])
        #expect(layout.sectors.mapValues { [r($0.x), r($0.y)] } == ["后端": [1284.24, 318], "项目经历": [795.76, 318]])
    }
}
