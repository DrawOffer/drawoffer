import Foundation

/// 桌面 AI 助手白名单（与后端 `get_current_agent_user` 对齐）：用户侧 `/api/agent/*`。
public enum AgentRequest {
    public static func allowed(path: String, method: String) -> Bool {
        guard path.hasPrefix("/api/agent/"), !path.contains("//"), !path.hasSuffix("/"), !path.contains("?"), !path.contains("#"), !path.contains("..") else { return false }
        let parts = Array(path.split(separator: "/").map(String.init).dropFirst(2))
        let id = { (value: String) in !value.isEmpty && value.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
        switch parts.count {
        case 1: return ["readiness", "model", "models", "contexts", "proposals"].contains(parts[0]) && method == "GET"
            || parts[0] == "sessions" && ["GET", "POST"].contains(method)
        case 2:
            if parts[0] == "sessions" { return id(parts[1]) && ["GET", "PATCH", "DELETE"].contains(method) }
            // 对话里的额度卡与套餐卡、卡片按钮动作、支付票据（Web `ChatCard`）
            if parts[0] == "cards" { return ["credit", "plans"].contains(parts[1]) && method == "GET" }
            if parts[0] == "actions" { return id(parts[1]) && method == "POST" }
            if parts[0] == "tickets" { return id(parts[1]) && method == "GET" }
            return false
        case 3:
            if parts[0] == "sessions", id(parts[1]) {
                return parts[2] == "active-run" && method == "GET" || parts[2] == "messages" && method == "POST"
                    || parts[2] == "attachments" && ["GET", "POST"].contains(method)
                    || parts[2] == "compact" && method == "POST"
                    || parts[2] == "memory" && method == "GET"
            }
            if parts[0] == "runs", id(parts[1]) { return parts[2] == "events" && method == "GET" || ["cancel", "steer"].contains(parts[2]) && method == "POST" }
            if parts[0] == "proposals", id(parts[1]) { return ["confirm", "reject"].contains(parts[2]) && method == "POST" }
            return false
        case 4:
            if parts[0] == "sessions", id(parts[1]), parts[2] == "submissions" { return id(parts[3]) && method == "GET" }
            // 改任意一条提问（新版本，流式）：`messages/{seq}:edit`；切到提问的另一个版本：`messages/{seq}:switch`
            if parts[0] == "sessions", id(parts[1]), parts[2] == "messages" { return (seqAction(parts[3], "edit") || seqAction(parts[3], "switch")) && method == "POST" }
            if parts[0] == "sessions", id(parts[1]), parts[2] == "attachments" { return id(parts[3]) && method == "DELETE" }
            if parts[0] == "sessions", id(parts[1]), parts[2] == "memory" { return parts[3] == "recorded" && method == "GET" }
            if parts[0] == "runs", id(parts[1]), parts[2] == "steer" { return id(parts[3]) && method == "GET" }
            return false
        case 5:
            if parts[0] == "sessions", id(parts[1]), parts[2] == "attachments", id(parts[3]) {
                return parts[4] == "retry" && method == "POST" || parts[4] == "file" && method == "GET"
            }
            // 回复的有用 / 没用：`messages/{seq}/rating`
            if parts[0] == "sessions", id(parts[1]), parts[2] == "messages", seq(parts[3]) { return parts[4] == "rating" && method == "PUT" }
            return false
        case 6:
            // 确认卡处理结果（02B·08 B）：`messages/{seq}/cards/{card}:resolve`
            if parts[0] == "sessions", id(parts[1]), parts[2] == "messages", seq(parts[3]), parts[4] == "cards" {
                let pieces = parts[5].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                return pieces.count == 2 && id(pieces[0]) && pieces[1] == "resolve" && method == "POST"
            }
            return false
        default: return false
        }
    }

    private static func seq(_ value: String) -> Bool { !value.isEmpty && value.count <= 12 && value.allSatisfy { $0 >= "0" && $0 <= "9" } }
    private static func seqAction(_ value: String, _ action: String) -> Bool {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        return pieces.count == 2 && seq(pieces[0]) && pieces[1] == action
    }

    /// 流式接口：发送消息与重新接入进行中的运行。
    public static func streams(path: String, method: String) -> Bool {
        allowed(path: path, method: method) && (method == "POST" && (path.hasSuffix("/messages") || path.hasSuffix("/compact") || path.hasSuffix(":edit")) || method == "GET" && path.hasSuffix("/events"))
    }

    public static func errorMessage(_ error: Error) -> String {
        if case APIError.unauthorized = error { return "登录已失效，请重新登录。" }
        guard case APIError.server(let status, let code) = error else { return "连接中断，回复结果尚未确认。可以刷新对话查看。" }
        return [
            "AGENT_NOT_READY": "AI 助手暂未开放，请稍后再试。",
            "LLM_MODEL_NOT_CONFIGURED": "AI 模型尚未配置，请稍后再试。",
            "AGENT_SESSION_ARCHIVED": "这个对话已归档，请新建对话。",
            "AGENT_RUN_IN_PROGRESS": "上一条回复还在生成，请稍候。",
            "AGENT_STREAM_INCOMPLETE": "回复中断了，可以刷新对话查看结果。",
            "AGENT_PROPOSAL_CONFLICT": "简历已变化，这条修改建议无法直接应用。",
            "AGENT_PROPOSAL_EXPIRED": "修改建议已过期，请重新生成。",
            "AGENT_MESSAGE_NOT_EDITABLE": "这条消息现在不能编辑，可能已有新的回复。",
            "AGENT_MESSAGE_VERSION_UNAVAILABLE": "这个版本现在切换不了，请等回答结束后再试。",
            "AGENT_STEER_TARGET_FINISHED": "这次回答已经结束，消息会作为下一条发送。",
            "AGENT_STEER_BUSY": "上一条插入的消息还没接上，请稍后再插入。",
            "DESKTOP_ROUTE_FORBIDDEN": "当前服务尚未开放桌面端 AI 助手，请在 Web 使用。",
        ][code] ?? (status >= 500 ? "AI 助手暂时不可用，请稍后重试。" : "操作没有完成（\(code)）。")
    }
}

/// 一条 SSE 事件：`event:` 名称与 `data:` JSON。
public struct AgentEvent: Sendable {
    public let type: String
    public let data: JSONValue
    public var isTerminal: Bool { ["run.completed", "run.failed", "run.cancelled"].contains(type) }
    public static let known: Set<String> = [
        "user.message.accepted", "user.message.applied", "user.message.rejected", "assistant.message.completed",
        "run.started", "run.phase", "assistant.activity.delta", "assistant.activity.status", "assistant.activity.clear", "assistant.delta",
        "assistant.delta.reset", "clarification.requested", "tool.started", "tool.completed", "proposal.created", "run.completed", "run.failed", "run.cancelled",
    ]

    /// 解析一个以空行结尾的 SSE 帧；缺少字段、未知事件或 JSON 损坏时返回 nil（忽略单条，不中断整条流）。
    public static func parse(frame: String) -> AgentEvent? {
        var name: String?, payload: String?
        for line in frame.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("event: ") { name = String(line.dropFirst(7)) }
            else if line.hasPrefix("data: ") { payload = String(line.dropFirst(6)) }
        }
        guard let name, known.contains(name), let payload, let data = payload.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return AgentEvent(type: name, data: value)
    }
}
