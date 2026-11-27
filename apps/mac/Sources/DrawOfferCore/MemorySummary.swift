import Foundation

/// 长期记忆摘要（Web `api/types.ts` 的 `MemorySummary`，`GET /api/memory/summary`）：值得现在处理的事（todo）和各目标的准备度（readiness）。
/// 带 `application_id` 时这个投递的目标排在 readiness 第一条；`value` 只在证据够时给（0–1）。读取不登记为已告知，
/// 页面把列出来的问题自己报给 `POST /api/memory/disclosures`。不进读缓存（Web 每次现读）。
public struct MemorySummary: Equatable, Sendable {
    public struct Target: Equatable, Sendable {
        /// topic / experience / resume_entry / resume_line
        public let kind: String
        public let ref: String
        public let label: String
    }

    public struct Todo: Equatable, Sendable {
        public let key: String
        public let kind: String
        public let state: String
        public let actionType: String
        public let target: Target?
        public let issues: [String]
    }

    public struct Readiness: Equatable, Sendable {
        public let key: String
        public let name: String
        /// graded / insufficient
        public let status: String
        public let level: String?
        public let value: Double?
        public let coverage: String
        public let statement: String
        public let thin: [String]
    }

    public let enabled: Bool
    public let todo: [Todo]
    public let readiness: [Readiness]

    public init(json: JSONValue) {
        enabled = json["enabled"]?.bool ?? false
        todo = (json["todo"]?.items ?? []).map { item in
            let action = item["action"]
            let target = action?["target"].flatMap { value -> Target? in
                guard case .object = value else { return nil }
                return Target(kind: value.text("kind"), ref: value.text("ref"), label: value.text("label"))
            }
            return Todo(key: item.text("key"), kind: item.text("kind"), state: item.text("state"), actionType: action?.text("type") ?? "",
                        target: target, issues: (item["issues"]?.items ?? []).compactMap(\.stringValue))
        }
        readiness = (json["readiness"]?.items ?? []).map { item in
            Readiness(key: item.text("key"), name: item.text("name"), status: item.text("status"), level: item["level"]?.stringValue,
                      value: item["value"]?.numberValue, coverage: item.text("coverage"), statement: item.text("statement"),
                      thin: (item["thin"]?.items ?? []).compactMap(\.stringValue))
        }
    }

    /// 台历上最多列几处（Web `journey.tsx` 的 `TOPIC_LIMIT`）。
    public static let topicLimit = 3
    /// 读摘要时要多少条 todo（Web `getMemorySummary(applicationId, 20)`），也是一次登记已告知的上限。
    public static let topicFetchLimit = 20

    public struct Topic: Equatable, Sendable {
        public let ref: String
        public let label: String
        public let issues: [String]
    }

    /// 台历上的考点（Web `useMemoryTopics`）：长期记忆里没答稳的知识点（`knowledge_gap` 且指向 topic、带名字），
    /// 按名字去重保留第一条，最多 `topicLimit` 处；关闭记忆时为空。
    public var topics: [Topic] {
        guard enabled else { return [] }
        var seen = Set<String>()
        var result: [Topic] = []
        for item in todo where item.kind == "knowledge_gap" {
            guard let target = item.target, target.kind == "topic", !target.label.isEmpty, seen.insert(target.label).inserted else { continue }
            result.append(Topic(ref: target.ref, label: target.label, issues: item.issues))
            if result.count == Self.topicLimit { break }
        }
        return result
    }

    /// 列出这几处时登记为已告知的问题（Web `discloseMemory("prep", …)`：各处的 issues 拼起来，最多 20 条）。
    public static func disclosed(_ topics: [Topic]) -> [String] {
        Array(topics.flatMap(\.issues).prefix(topicFetchLimit))
    }

    /// 这个投递的准备度（key `goal:app.{投递 id}`），证据不够时为 nil（Web `ReportV2` `useReadiness`）。
    public func readinessValue(applicationID: String) -> Double? {
        guard enabled else { return nil }
        return readiness.first { $0.key == "goal:app.\(applicationID)" }?.value
    }

    /// 准备度写成百分比：0.42 → 「42%」（Web `percent`）。
    public static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    /// 复盘分数下面那一行里的准备度：「准备度 40% → 55%」；练前或现在任一边没有就不写（Web `ReviewReport` `statsLine`）。
    public static func readinessLine(before: Double?, after: Double?) -> String? {
        guard let before, let after else { return nil }
        return "准备度 \(percent(before)) → \(percent(after))"
    }
}
