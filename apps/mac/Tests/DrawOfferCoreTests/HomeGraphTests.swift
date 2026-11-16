import Foundation
import Testing
@testable import DrawOfferCore

private func json(_ source: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
}

private let memory = """
{"enabled":true,"resume":{"id":"r1","title":"示例简历"},"groups":[{"kind":"project","label":"项目","items":[{"key":"e1","title":"示例订单系统"}]}],
 "graph":{"nodes":[{"key":"e1","kind":"experience","name":"示例科技 · 后端实习","status":"none","size":3},
                   {"key":"t1","kind":"technology","name":"Redis","status":"good","size":2},
                   {"key":"p1","kind":"point","name":"持久化（RDB/AOF）","status":"weak","size":1},
                   {"key":"p2","kind":"point","name":"过期策略","status":"none","size":1}],
          "edges":[{"src":"e1","dst":"t1","kind":"ET"},{"src":"t1","dst":"p1","kind":"TP"},{"src":"t1","dst":"p2","kind":"TP"}]},
 "has_conclusions":true,"points":2,"weak_points":1,"weakest":{"key":"p1","name":"持久化","status":"weak","experiences":2},
 "sources":{"resumes":1,"mocks":3,"interviews":0},"today":"2026-11-16",
 "timeline":[{"kind":"mock","date":"2026-11-15","source":"模拟面试 · 第 3 场","source_id":"m3","tone":"up","name":"MySQL 索引","before":"熟悉","after":"熟练","nodes":[],"asked":6,"missed":0,"practice":{"kind":"topic","ref":"p1","label":"持久化"}}],
 "entries":{"interview":{"count":2,"company":"示例公司","stage":"二面","start_at":"2026-11-20T02:00:00Z"},"mock":{"count":3,"last_score":82.4,"last_id":"m3"},"applications":{"open":3,"awaiting_result":1},"jobs":{"saved":5},"datasets":{"count":4}}}
"""

@Test func homeGraphParsesNodesAndHomeSubset() throws {
    let graph = HomeGraph(json: try json(memory))
    #expect(graph.resumeID == "r1")
    #expect(graph.topics == ["示例订单系统"])
    #expect(graph.nodes.filter(\.onHome).map(\.id) == ["e1", "t1", "p1"])
    #expect(graph.nodes[2].tone == .hot)
    #expect(graph.nodes[2].label == "持久化")
    #expect(graph.entries?.mockLastScore == 82.4)
    #expect(graph.timeline.first?.practiceRef == "p1")
}

@Test func homeStagePicksByResumeMocksAndConclusions() throws {
    let graph = HomeGraph(json: try json(memory))
    let none = HomeMockProgress(json: try json(#"{"items":[{"id":"x","status":"abandoned"}]}"#))
    let many = HomeMockProgress(json: try json(#"{"items":[{"id":"a","status":"completed"},{"id":"b","status":"completed"}]}"#))
    let ongoing = HomeMockProgress(json: try json(#"{"items":[{"id":"a","status":"in_progress"}]}"#))
    let fresh = HomeMockProgress(json: try json(#"{"items":[{"id":"a","status":"completed","finished_at":"2026-11-15T10:00:00Z"}]}"#))
    let old = HomeMockProgress(json: try json(#"{"items":[{"id":"a","status":"completed","finished_at":"2026-11-01T10:00:00Z"}]}"#))

    #expect(HomeStage.pick(graph: HomeGraph(json: try json(#"{"resume":null}"#)), mocks: nil, reportSeen: false) == .newUser)
    // 有结论但没练过：不再出“练第一场”，直接是有记忆的首页
    #expect(HomeStage.pick(graph: graph, mocks: none, reportSeen: false) == .feedback)
    #expect(HomeStage.pick(graph: graph, mocks: many, reportSeen: false) == .feedback)
    #expect(HomeStage.pick(graph: graph, mocks: ongoing, reportSeen: false) == .firstSteps(.ongoing))
    #expect(HomeStage.pick(graph: graph, mocks: fresh, reportSeen: false) == .firstSteps(.report))
    #expect(HomeStage.pick(graph: graph, mocks: fresh, reportSeen: true) == .feedback)
    #expect(HomeStage.pick(graph: graph, mocks: old, reportSeen: false) == .feedback)

    let bare = HomeGraph(json: try json(#"{"resume":{"id":"r1","title":"t"},"has_conclusions":false,"graph":{"nodes":[],"edges":[]}}"#))
    #expect(HomeStage.pick(graph: bare, mocks: none, reportSeen: false) == .firstSteps(.start))
    #expect(HomeStage.pick(graph: bare, mocks: many, reportSeen: false) == .resumeOnly)
}

@Test func homeProgressTextAndRelativeDates() throws {
    let graph = HomeGraph(json: try json(memory))
    let text = HomeProgressText.text(graph.timeline[0], weakPoints: 1)
    #expect(text.short == "MySQL 索引从熟悉练到了熟练")
    #expect(text.desc == "这一场问到 6 处。还有 1 个不牢。")
    #expect(HomeProgressText.when("2026-11-16", today: "2026-11-16") == "今天")
    #expect(HomeProgressText.when("2026-11-15", today: "2026-11-16") == "昨天")
    #expect(HomeProgressText.when("2026-11-12", today: "2026-11-16") == "4 天前")
    #expect(HomeProgressText.when("2026-11-02", today: "2026-11-16") == "11-02")
}

@Test func homeGraphLayoutIsDeterministicAndInBounds() throws {
    let graph = HomeGraph(json: try json(memory))
    let first = HomeGraphLayout.layout(nodes: graph.nodes, edges: graph.edges)
    let second = HomeGraphLayout.layout(nodes: graph.nodes, edges: graph.edges)
    #expect(first.count == 4)
    for (key, point) in first {
        #expect((0...1).contains(point.x) && (0...1).contains(point.y))
        #expect(second[key]!.x == point.x && second[key]!.y == point.y)
    }
}

@Test func homeGraphRouteIsAllowedForDesktop() {
    #expect(CareerRequest.allowed(path: "/api/memory/home/graph", method: "GET"))
}
