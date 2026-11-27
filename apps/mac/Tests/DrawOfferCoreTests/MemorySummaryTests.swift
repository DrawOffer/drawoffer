import Foundation
import Testing
@testable import DrawOfferCore

private func json(_ source: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)) }

private let fixture = #"""
{"enabled":true,
 "todo":[
  {"key":"t1","kind":"knowledge_gap","state":"open","action":{"type":"practice","target":{"kind":"topic","ref":"redis.aof","label":"Redis：AOF 重写"}},"issues":["i1","i2"]},
  {"key":"t2","kind":"knowledge_gap","state":"open","action":{"type":"practice","target":{"kind":"topic","ref":"redis.aof2","label":"Redis：AOF 重写"}},"issues":["i3"]},
  {"key":"t3","kind":"experience_gap","state":"open","action":{"type":"practice","target":{"kind":"topic","ref":"x","label":"不是知识缺口"}},"issues":["i4"]},
  {"key":"t4","kind":"knowledge_gap","state":"open","action":{"type":"practice","target":{"kind":"experience","ref":"e","label":"经历"}},"issues":["i5"]},
  {"key":"t5","kind":"knowledge_gap","state":"open","action":{"type":"none","target":null},"issues":["i6"]},
  {"key":"t6","kind":"knowledge_gap","state":"open","action":{"type":"practice","target":{"kind":"topic","ref":"mq","label":""}},"issues":["i7"]},
  {"key":"t7","kind":"knowledge_gap","state":"open","action":{"type":"practice","target":{"kind":"topic","ref":"tcp","label":"TCP 握手"}},"issues":["i8"]},
  {"key":"t8","kind":"knowledge_gap","state":"open","action":{"type":"practice","target":{"kind":"topic","ref":"jvm","label":"JVM（垃圾回收）"}},"issues":[]},
  {"key":"t9","kind":"knowledge_gap","state":"open","action":{"type":"practice","target":{"kind":"topic","ref":"sql","label":"SQL 索引"}},"issues":["i9"]}],
 "readiness":[
  {"key":"goal:app.7","name":"示例科技 · 后端","status":"graded","level":"ok","value":0.552,"coverage":"8/10","statement":"大部分答稳了","thin":["消息队列"]},
  {"key":"goal:app.8","name":"另一家","status":"insufficient","level":null,"coverage":"1/10","statement":"证据还不够","thin":[]}]}
"""#

@Test func memorySummaryDecodesWebFields() throws {
    let summary = MemorySummary(json: try json(fixture))
    #expect(summary.enabled && summary.todo.count == 9 && summary.readiness.count == 2)
    let first = try #require(summary.todo.first)
    #expect(first.key == "t1" && first.kind == "knowledge_gap" && first.state == "open" && first.actionType == "practice")
    #expect(first.target == .init(kind: "topic", ref: "redis.aof", label: "Redis：AOF 重写") && first.issues == ["i1", "i2"])
    #expect(summary.todo[4].target == nil)
    let ready = summary.readiness[0]
    #expect(ready.name == "示例科技 · 后端" && ready.status == "graded" && ready.level == "ok" && ready.value == 0.552 && ready.coverage == "8/10" && ready.thin == ["消息队列"])
    #expect(summary.readiness[1].level == nil && summary.readiness[1].value == nil)
    let off = MemorySummary(json: try json(#"{"enabled":false}"#))
    #expect(!off.enabled && off.todo.isEmpty && off.readiness.isEmpty)
}

/// 台历考点与 Web `useMemoryTopics` 一致：只要指向 topic、带名字的知识缺口，按名字去重，最多 3 处；登记已告知的是这几处的 issues。
@Test func memoryTopicsFilterAndDeduplicateLikeWeb() throws {
    let summary = MemorySummary(json: try json(fixture))
    #expect(summary.topics.map(\.ref) == ["redis.aof", "tcp", "jvm"])
    #expect(summary.topics.map(\.label) == ["Redis：AOF 重写", "TCP 握手", "JVM（垃圾回收）"])
    #expect(MemorySummary.disclosed(summary.topics) == ["i1", "i2", "i8"])
    let many = (0..<25).map { MemorySummary.Topic(ref: "r\($0)", label: "l\($0)", issues: ["a\($0)"]) }
    #expect(MemorySummary.disclosed(many).count == 20)
    var off = try json(fixture)
    if case .object(var fields) = off { fields["enabled"] = .bool(false); off = .object(fields) }
    #expect(MemorySummary(json: off).topics.isEmpty)
}

/// 复盘里的准备度：取 `goal:app.{投递}` 这一条的 value，证据不够或记忆关闭时没有；任一边没有就不写那一段。
@Test func readinessComesFromTheApplicationGoal() throws {
    let summary = MemorySummary(json: try json(fixture))
    #expect(summary.readinessValue(applicationID: "7") == 0.552)
    #expect(summary.readinessValue(applicationID: "8") == nil)
    #expect(summary.readinessValue(applicationID: "9") == nil)
    #expect(MemorySummary.readinessLine(before: 0.4, after: 0.552) == "准备度 40% → 55%")
    #expect(MemorySummary.readinessLine(before: nil, after: 0.5) == nil)
    #expect(MemorySummary.readinessLine(before: 0.5, after: nil) == nil)
    #expect(MemorySummary.percent(0.005) == "1%")
}

@Test func memorySummaryRoutesAreOpenAndInterviewAssetDeleteStaysClosed() {
    #expect(CareerRequest.allowed(path: "/api/memory/summary", method: "GET"))
    #expect(CareerRequest.allowed(path: "/api/memory/disclosures", method: "POST"))
    #expect(!CareerRequest.allowed(path: "/api/memory/summary", method: "POST"))
    #expect(!CareerRequest.allowed(path: "/api/memory/disclosures", method: "GET"))
    // Web 现在不调用删除面试素材（资料改由资料库删除、场次里只解除关联）
    #expect(!CareerRequest.allowed(path: "/api/interview-assets/4", method: "DELETE"))
    // 摘要每次现读；登记已告知不作废别的读
    #expect(ReadCache.lifetime(path: "/api/memory/summary", query: ["application_id": "7", "limit": "20"]) == nil)
    #expect(!ReadCache.affected(byWriteTo: "/api/memory/disclosures", key: "/api/job-applications?scope=all"))
}
