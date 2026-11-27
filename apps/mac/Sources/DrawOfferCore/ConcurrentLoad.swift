import Foundation

/// 页面首屏读取的两个公共动作：
/// - `pages`：按 `next_cursor` 读完一个分页列表。页与页之间有 cursor 依赖，只能一页接一页读；
///   不同列表之间互不依赖，调用方用 `async let` 并发（Web `Promise.all([listAllInterviewSessions, listAllJobApplications])`）。
/// - `each`：并发读一组详情，单个失败只是少一条（Web `Promise.all(... try { getInterviewSession } catch { null })`）。
public enum ConcurrentLoad {
    /// 读完全部分页；cursor 重复视为服务端异常（`invalidResponse`），取消时抛 `CancellationError`。
    public static func pages(base: [String: String], fetch: @Sendable (_ query: [String: String]) async throws -> JSONValue) async throws -> [JSONValue] {
        var values: [JSONValue] = []
        var cursor = ""
        var seen = Set<String>()
        repeat {
            var query = base
            if !cursor.isEmpty { query["cursor"] = cursor }
            let page = try await fetch(query)
            try Task.checkCancellation()
            values += page["items"]?.items ?? []
            cursor = page.text("next_cursor")
            if !cursor.isEmpty && !seen.insert(cursor).inserted { throw APIError.invalidResponse }
        } while !cursor.isEmpty
        return values
    }

    /// 并发读 `ids` 各自的详情，读不到的不放进结果。
    public static func each(_ ids: [String], fetch: @escaping @Sendable (String) async throws -> JSONValue) async -> [String: JSONValue] {
        await withTaskGroup(of: (String, JSONValue?).self) { group in
            for id in ids { group.addTask { (id, try? await fetch(id)) } }
            var result: [String: JSONValue] = [:]
            for await (id, value) in group { if let value { result[id] = value } }
            return result
        }
    }
}
