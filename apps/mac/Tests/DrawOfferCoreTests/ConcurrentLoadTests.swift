import Foundation
import Testing
@testable import DrawOfferCore

/// 记下每页请求带的 query，按 cursor 回假数据。
private actor PageServer {
    private(set) var queries: [[String: String]] = []
    let pages: [String: JSONValue]
    init(pages: [String: JSONValue]) { self.pages = pages }
    func get(_ query: [String: String]) -> JSONValue {
        queries.append(query)
        return pages[query["cursor"] ?? ""] ?? .object([:])
    }
}

private func page(_ ids: [String], next: String?) -> JSONValue {
    .object(["items": .array(ids.map { .object(["id": .string($0)]) }), "next_cursor": next.map(JSONValue.string) ?? .null])
}

/// 所有请求都到齐才一起放行；串行时等不齐，超时后放行并记下没到齐。
private actor Barrier {
    let expected: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var allTogether = false
    init(expected: Int) { self.expected = expected }
    func arrive() async {
        arrived += 1
        if arrived == expected { allTogether = true; release(); return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { waiters.forEach { $0.resume() }; waiters = [] }
}

@Test func concurrentLoadReadsPagesInCursorOrder() async throws {
    let server = PageServer(pages: ["": page(["1", "2"], next: "c1"), "c1": page(["3"], next: "c2"), "c2": page(["4"], next: nil)])
    let items = try await ConcurrentLoad.pages(base: ["limit": "2", "scope": "all"]) { try await Task.sleep(for: .milliseconds(1)); return await server.get($0) }
    #expect(items.map { $0.text("id") } == ["1", "2", "3", "4"])
    let queries = await server.queries
    #expect(queries.map { $0["cursor"] } == [nil, "c1", "c2"])
    #expect(queries.allSatisfy { $0["limit"] == "2" && $0["scope"] == "all" })
}

@Test func concurrentLoadRejectsRepeatedCursor() async {
    let server = PageServer(pages: ["": page(["1"], next: "loop"), "loop": page(["2"], next: "loop")])
    await #expect(throws: APIError.invalidResponse) { _ = try await ConcurrentLoad.pages(base: [:]) { await server.get($0) } }
}

@Test func concurrentLoadPropagatesPageFailure() async {
    await #expect(throws: APIError.unauthorized) { _ = try await ConcurrentLoad.pages(base: [:]) { _ in throw APIError.unauthorized } }
}

@Test func concurrentLoadEachRunsTogetherAndSkipsFailures() async {
    let barrier = Barrier(expected: 3)
    let fallback = Task { try? await Task.sleep(for: .seconds(5)); await barrier.release() }
    let result = await ConcurrentLoad.each(["a", "b", "c"]) { id in
        await barrier.arrive()
        if id == "b" { throw APIError.server(status: 404, code: "NOT_FOUND") }
        return .object(["id": .string(id)])
    }
    fallback.cancel()
    #expect(await barrier.allTogether)
    #expect(result.keys.sorted() == ["a", "c"])
    #expect(result["a"]?.text("id") == "a")
}

@Test func concurrentLoadEachWithNoIDsIsEmpty() async {
    let result = await ConcurrentLoad.each([]) { _ in .null }
    #expect(result.isEmpty)
}
