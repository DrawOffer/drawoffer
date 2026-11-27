import Foundation
public enum MockInterviewRequest {
    /// 回合 SSE 上限：语音面试的面试官语音以 base64 mp3 随流返回，比纯文字大得多。
    public static let maximumTurnBytes = 32 * 1024 * 1024
    /// 二进制音频接口：试听（mp3）与录音回放（wav）。
    public static func audio(path: String, method: String) -> Bool {
        allowed(path: path, method: method) && (path.hasSuffix("/speech/playback") || path.hasSuffix("/recording"))
    }
    public static func allowed(path: String, method: String) -> Bool {
        if path == "/api/mock-interviews" { return ["GET", "POST"].contains(method) }
        if path == "/api/datasets" { return method == "GET" }
        if path == "/api/mock-interviews/speech-capability" { return method == "GET" }
        // 首页 / 全部记录的概览、导入面试记录、复盘页的上下文（Figma 09 · 01、08、09、10）
        if ["/api/mock-interviews/overview", "/api/mock-interviews/review-context", "/api/mock-interviews/import-targets"].contains(path) { return method == "GET" }
        if path == "/api/mock-interviews/imports" { return method == "POST" }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (4...7).contains(parts.count), parts[0].isEmpty, parts[1] == "api", parts[2] == "mock-interviews",
              let id = UUID(uuidString: String(parts[3])), id.uuidString.lowercased() == parts[3] else { return false }
        if parts.count == 4 { return ["GET", "DELETE"].contains(method) }
        if parts.count == 5 {
            if parts[4] == "recordings" { return method == "DELETE" }
            return method == "POST" && ["answers", "skip", "reply:retry", "finish", "abandon", "retry", "repeat", "transcripts:correct", "answer-mode"].contains(parts[4])
        }
        if parts.count == 6 {
            // 报告「下一步」的勾选：/actions/{index}
            if parts[4] == "actions" { return method == "PUT" && (1...3).contains(parts[5].count) && parts[5].allSatisfy { $0.isASCII && $0.isNumber } }
            return parts[4] == "speech" && parts[5] == "playback" && method == "POST"
        }
        // /questions/{id}/transcript|re-evaluate|recording
        guard parts.count == 7, parts[4] == "questions", !parts[5].isEmpty, parts[5].allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        switch parts[6] {
        case "transcript": return method == "PUT"
        case "re-evaluate": return method == "POST"
        case "recording": return method == "GET"
        case "judgement": return method == "PUT"
        default: return false
        }
    }
    public static func decodeEvents(_ data: Data) throws -> JSONValue {
        guard data.count <= MockInterviewRequest.maximumTurnBytes, let source = String(data: data, encoding: .utf8) else { throw APIError.invalidResponse }
        var events: [JSONValue] = []
        for block in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            var kind = ""; var lines: [String] = []
            for line in block.components(separatedBy: "\n") {
                if line.hasPrefix("event:") { kind = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                if line.hasPrefix("data:") { lines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            }
            if lines.isEmpty { continue }
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(lines.joined(separator: "\n").utf8))
            if kind == "interviewer.failed" { throw APIError.server(status: 502, code: value.text("error")) }
            events.append(.object(["event": .string(kind), "data": value]))
        }
        guard !events.isEmpty else { throw APIError.invalidResponse }
        return .object(["events": .array(events)])
    }
}
