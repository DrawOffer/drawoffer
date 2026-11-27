import Foundation
import Testing
@testable import DrawOfferCore

// 三段经历：示例物流（业务“运单调度”→ 做成的事“调度接口提速”）、示例教育、示例二手；Java、Redis、MySQL 各被两段用到。
private let source = """
{"enabled":true,"resume":{"id":"r1","title":"示例简历"},"has_conclusions":true,"points":3,"weak_points":1,
 "strongest":{"key":"t:java","name":"Java","status":"top","experiences":2},"weakest":{"key":"p:lock","name":"分布式锁（Redisson）","status":"weak","experiences":2},
 "sources":{"resumes":1,"mocks":4,"interviews":1},"timeline":[],"today":"2026-11-26",
 "graph":{"nodes":[
  {"key":"e:a","kind":"experience","name":"示例物流 · 后端实习","status":"none"},
  {"key":"e:b","kind":"experience","name":"示例教育 · 后端实习","status":"none"},
  {"key":"e:c","kind":"experience","name":"示例二手 · 课程设计","status":"none"},
  {"key":"h:a1","kind":"highlight","name":"运单调度","status":"none","facet":"business"},
  {"key":"h:a2","kind":"highlight","name":"调度接口提速","status":"ok","facet":"work"},
  {"key":"h:b1","kind":"highlight","name":"在线题库","status":"none","facet":"business"},
  {"key":"t:java","kind":"technology","name":"Java","status":"top"},
  {"key":"t:redis","kind":"technology","name":"Redis","status":"weak"},
  {"key":"t:mysql","kind":"technology","name":"MySQL","status":"good"},
  {"key":"t:mq","kind":"technology","name":"RabbitMQ（消息队列）","status":"none"},
  {"key":"p:lock","kind":"point","name":"分布式锁（Redisson）","status":"weak","size":2,"asked":true},
  {"key":"p:aof","kind":"point","name":"持久化","status":"none","size":1,"asked":true},
  {"key":"p:idx","kind":"point","name":"索引","status":"good","size":1,"changed":"up"},
  {"key":"s:1","kind":"session","name":"10/23 模拟面试","status":"weak","size":2}],
 "edges":[
  {"src":"e:a","dst":"h:a1","kind":"EH"},{"src":"h:a1","dst":"h:a2","kind":"HH"},{"src":"h:a2","dst":"t:java","kind":"HT"},{"src":"h:a2","dst":"t:redis","kind":"HT"},
  {"src":"e:a","dst":"t:mq","kind":"ET"},
  {"src":"e:b","dst":"h:b1","kind":"EH"},{"src":"h:b1","dst":"t:java","kind":"HT"},{"src":"h:b1","dst":"t:mysql","kind":"HT"},
  {"src":"e:c","dst":"t:mysql","kind":"ET"},{"src":"e:c","dst":"t:redis","kind":"ET"},
  {"src":"t:redis","dst":"p:lock","kind":"TP"},{"src":"t:redis","dst":"p:aof","kind":"TP"},{"src":"t:mysql","dst":"p:idx","kind":"TP"},
  {"src":"s:1","dst":"t:redis","kind":"SN"},{"src":"s:1","dst":"p:aof","kind":"SN"}]}}
"""

private func graph() throws -> HomeGraph {
    HomeGraph(json: try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)))
}

@Test func knowledgeGraphFindsSharedTechnologiesAndSkeleton() throws {
    let graph = try graph()
    #expect(graph.nodes.first { $0.id == "h:a1" }?.business == true)
    #expect(graph.nodes.first { $0.id == "p:aof" }?.held == "问过，还说不准")
    #expect(graph.nodes.first { $0.id == "p:idx" }?.chatState == "刚练稳")
    #expect(graph.nodes.first { $0.id == "h:a2" }?.chatState == "做成的事")
    #expect(KnowledgeGraph.sharedTechnologies(nodes: graph.nodes, edges: graph.edges) == ["t:java", "t:redis", "t:mysql"])
    let skeleton = KnowledgeGraph.homeSkeleton(nodes: graph.nodes, edges: graph.edges)
    // 小图不画做成的事、只这段用到的技术和知识点；场次留着，连向它问到的共用技术
    #expect(Set(skeleton.nodes.map(\.id)) == ["e:a", "e:b", "e:c", "h:a1", "h:b1", "t:java", "t:redis", "t:mysql", "s:1"])
    // 藏掉的“调度接口提速”不单画：线从业务直接连到它下面的技术
    #expect(skeleton.edges.contains(HomeGraph.Edge(src: "h:a1", dst: "t:java", kind: "HT")))
    #expect(skeleton.edges.contains(HomeGraph.Edge(src: "s:1", dst: "t:redis", kind: "SN")))
    #expect(!skeleton.edges.contains { $0.dst == "t:mq" || $0.dst == "h:a2" })
}

@Test func knowledgeGraphLayoutIsDeterministicInsideTheBoardAndCoreInMiddle() throws {
    let graph = try graph()
    let first = KnowledgeGraph.layout(nodes: graph.nodes, edges: graph.edges)
    let second = KnowledgeGraph.layout(nodes: graph.nodes, edges: graph.edges)
    #expect(first.spots == second.spots)
    #expect(first.spots.count == graph.nodes.count)
    #expect(first.world == KnowledgeGraph.World(width: 1151, height: 640))
    for spot in first.spots {
        #expect((0...first.world.width).contains(spot.x) && (0...first.world.height).contains(spot.y))
    }
    // 共用技术离中心比经历近
    let at = first.at
    let mid = (x: first.world.width / 2, y: first.world.height / 2)
    func far(_ key: String) -> Double { hypot((at[key]!.x - mid.x) / first.world.width, (at[key]!.y - mid.y) / first.world.height) }
    #expect(["t:java", "t:redis", "t:mysql"].allSatisfy { tech in ["e:a", "e:b", "e:c"].allSatisfy { far(tech) < far($0) } })
}

@Test func homeGraphStageFoldsPointsAndCountsHiddenKids() throws {
    let stage = HomeGraphStage(graph: try graph())
    #expect(stage.core == ["t:java", "t:redis", "t:mysql"])
    #expect(!stage.home.keys.contains("t:mq") && stage.home.keys.contains("s:1"))
    #expect(stage.home.values.allSatisfy { abs($0.x) <= 0.371 && abs($0.y) <= 0.431 })
    #expect(stage.full.values.allSatisfy { abs($0.x) <= 0.5001 && abs($0.y) <= 0.5001 })
    let plain = stage.shown(selected: nil)
    #expect(!plain.contains("p:lock"))
    #expect(stage.hidden("t:redis", shown: plain, selected: nil) == 2)
    // 点 Redis 展开它的考点；它自己不再标 +N
    let open = stage.shown(selected: "t:redis")
    #expect(open.isSuperset(of: ["p:lock", "p:aof"]))
    #expect(stage.hidden("t:redis", shown: open, selected: "t:redis") == 0)
    #expect(stage.lit("t:redis") == ["t:redis", "h:a2", "e:c", "s:1", "p:lock", "p:aof"])
    // 场次连向答得还行的知识点平时收着，选中场次时才画
    #expect(!stage.visibleLines(shown: stage.shown(selected: nil), selected: nil).contains { $0.b == "p:aof" })
    #expect(stage.visibleLines(shown: stage.shown(selected: "s:1"), selected: "s:1").contains { $0.a == "s:1" && $0.b == "p:aof" })
}

@Test func homeSummarySaysStrongestAndWeakest() throws {
    let graph = try graph()
    let summary = HomeSummary.of(graph)
    #expect(summary.eyebrow == "最近 4 场模拟面试的结论")
    #expect(summary.title == ["Java 答得很稳", "分布式锁 还要再练"])
    #expect(summary.desc == "2 段经历都用到 分布式锁，先补它最划算。")
    let bare = HomeGraph(json: try JSONDecoder().decode(JSONValue.self, from: Data(#"{"resume":{"id":"r1","title":"t"},"has_conclusions":false,"sources":{"mocks":0}}"#.utf8)))
    #expect(HomeSummary.of(bare).title == ["练一场模拟面试", "记忆从这里开始"])
}

@Test func untanglePushesLabelsApartAndKeepsThemOnCanvas() throws {
    let graph = try graph()
    let redis = graph.nodes.first { $0.id == "t:redis" }!, cache = graph.nodes.first { $0.id == "p:lock" }!
    let big = HomeGraphStage.footprintSize(redis, core: true), small = HomeGraphStage.footprintSize(cache, core: false)
    #expect(big.halfHeight > small.halfHeight)
    // 窄画布里知识点几乎压在技术名上，左上角还有一块标题
    let items = [
        HomeGraphStage.Footprint(key: "t:redis", kind: .technology, x: 200, y: 200, halfWidth: big.halfWidth, halfHeight: big.halfHeight),
        HomeGraphStage.Footprint(key: "p:lock", kind: .point, x: 190, y: 204, halfWidth: small.halfWidth, halfHeight: small.halfHeight),
        HomeGraphStage.Footprint(key: "e:a", kind: .experience, x: 40, y: 30, halfWidth: 60, halfHeight: 20),
    ]
    let bounds = HomeGraphStage.Rect(left: 16, top: 16, right: 420, bottom: 380)
    let title = HomeGraphStage.Rect(left: 0, top: 0, right: 200, bottom: 80)
    let placed = HomeGraphStage.untangle(items, bounds: bounds, blocks: [title])
    #expect(HomeGraphStage.untangle(items, bounds: bounds, blocks: [title]).mapValues { [$0.x, $0.y] } == placed.mapValues { [$0.x, $0.y] })
    for (i, a) in items.enumerated() {
        let p = placed[a.key]!
        #expect(p.x - a.halfWidth >= bounds.left - 0.01 && p.x + a.halfWidth <= bounds.right + 0.01)
        #expect(p.y - a.halfHeight >= bounds.top - 0.01 && p.y + a.halfHeight <= bounds.bottom + 0.01)
        for b in items.dropFirst(i + 1) {
            let q = placed[b.key]!
            #expect(abs(p.x - q.x) >= a.halfWidth + b.halfWidth - 0.01 || abs(p.y - q.y) >= a.halfHeight + b.halfHeight - 0.01)
        }
    }
    // 技术比知识点重，挪得少
    let moved = { (key: String) in let p = placed[key]!, o = items.first { $0.key == key }!; return hypot(p.x - o.x, p.y - o.y) }
    #expect(moved("t:redis") < moved("p:lock"))
    // 经历被挪出了标题那块
    let hub = placed["e:a"]!
    #expect(hub.x - 60 >= title.right - 0.01 || hub.y - 20 >= title.bottom - 0.01)
}
