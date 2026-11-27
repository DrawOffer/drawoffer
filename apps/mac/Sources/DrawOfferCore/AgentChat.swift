import Foundation

/// AI 回复的「有用 / 没用」（Web `agent/MessageRating.tsx`，`PUT /api/agent/sessions/{id}/messages/{seq}/rating`）。
/// 再选一次整条替换；没用的原因每点一下就保存一次，补充一句最多 500 字。
public struct AgentRating: Equatable, Sendable {
    public static let reasons: [(key: String, label: String)] = [
        ("wrong", "说得不对"), ("off_topic", "没答到点上"), ("not_me", "和我的情况不符"), ("too_long", "太长了"), ("other", "其他"),
    ]
    public var up: Bool
    public var reasons: [String]
    public var note: String

    public init(up: Bool, reasons: [String] = [], note: String = "") {
        self.up = up; self.reasons = reasons; self.note = String(note.prefix(500))
    }

    /// 消息上的 `rating`（`{rating, reasons, note}`）；没有或格式不对时为 nil。
    public init?(_ value: JSONValue?) {
        guard let value, let rating = value["rating"]?.stringValue, ["up", "down"].contains(rating) else { return nil }
        self.init(up: rating == "up", reasons: (value["reasons"]?.items ?? []).compactMap(\.stringValue).filter { key in Self.reasons.contains { $0.key == key } },
                  note: value.text("note"))
    }

    public var json: JSONValue {
        .object(["rating": .string(up ? "up" : "down"), "reasons": .array(reasons.map(JSONValue.string)), "note": .string(note)])
    }

    /// 点「没用」：已经是没用时保持原因不变，否则清空成一条新的没用。
    public static func down(from current: AgentRating?) -> AgentRating { current.map { $0.up ? AgentRating(up: false) : $0 } ?? AgentRating(up: false) }

    /// 点一个原因：选中的取消，没选的加到末尾（顺序同点选顺序，去重）。
    public func toggling(_ reason: String) -> AgentRating {
        var next = AgentRating(up: false, reasons: up ? [] : reasons, note: up ? "" : note)
        if let index = next.reasons.firstIndex(of: reason) { next.reasons.remove(at: index) } else { next.reasons.append(reason) }
        return next
    }

    public func withNote(_ text: String) -> AgentRating {
        AgentRating(up: false, reasons: up ? [] : reasons, note: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// 改过的提问有几个版本（Web `VersionSwitcher`；会话详情里用户消息的 `versions`）。
public struct AgentVersions: Equatable, Sendable {
    public let index: Int
    public let total: Int
    public let sequences: [Int]

    public init?(_ value: JSONValue?) {
        guard let value, case .object = value else { return nil }
        let sequences = (value["sequence_nos"]?.items ?? []).map(\.integer)
        let index = value["index"]?.integer ?? 0, total = value["total"]?.integer ?? sequences.count
        guard total > 1, index >= 1, index <= sequences.count else { return nil }
        self.index = index; self.total = total; self.sequences = sequences
    }

    public var previous: Int? { index >= 2 ? sequences[index - 2] : nil }
    public var next: Int? { index < sequences.count ? sequences[index] : nil }
    public var label: String { "\(index)/\(total)" }
}

/// 对话分支的规则（Web `AssistantPage` 的 `isEditableMessage` / `regenerableReplySequence`）：
/// 回答进行中不能改也不能切；任意一条已保存的文字提问可以改，带附件或回答追问的不行；重新生成就是原样重发最后一条可改的提问。
public enum AgentBranch {
    public static func sequence(_ message: JSONValue) -> Int { message["sequence_no"]?.integer ?? 0 }

    public static func isClarificationAnswer(_ message: JSONValue, in messages: [JSONValue]) -> Bool {
        guard message.text("role") == "user", let reply = message["reply_to_sequence_no"], reply != .null else { return false }
        return messages.contains { sequence($0) == reply.integer && $0.text("message_type") == "clarification" }
    }

    public static func editable(_ message: JSONValue, in messages: [JSONValue], busy: Bool) -> Bool {
        !busy && message.text("role") == "user" && sequence(message) > 0 && !isClarificationAnswer(message, in: messages)
            && (message["attachments"]?.items ?? []).isEmpty && message["knowledge_point"]?["kickoff"]?.bool != true
    }

    /// 能「重新生成」的那条回复的序号：最后一条提问可改时，它之后的最后一条正文回复。
    public static func regenerable(_ messages: [JSONValue], busy: Bool) -> (reply: Int, question: Int)? {
        guard !busy, let last = messages.last(where: { $0.text("role") == "user" && sequence($0) > 0 }),
              editable(last, in: messages, busy: busy) else { return nil }
        let question = sequence(last)
        guard let reply = messages.last(where: { $0.text("role") == "assistant" && !["compaction", "clarification"].contains($0.text("message_type"))
            && sequence($0) > question }) else { return nil }
        return (sequence(reply), question)
    }

    /// 能评价的回复：已保存的正文回复（不含停止或失败的半截）。
    public static func ratable(_ message: JSONValue) -> Bool {
        message.text("role") == "assistant" && (message.text("message_type").nonEmptyValue ?? "text") == "text"
            && message.text("status").isEmpty && sequence(message) > 0
    }
}

/// 回答进行中输入的消息（Web `QueuedMessages`）：先停在输入框上方，回答正常结束后按顺序发出，
/// 或「立即发送」插进当前回答（一次一条）；只在内存里，不持久化。
public struct AgentQueuedMessage: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case queued, inserting }
    public let id: String
    public var content: String
    public var contexts: [JSONValue]
    public var state: State = .queued
    public var runID: String?
    public var submissionKey: String?
    public var error: String?

    public init(id: String, content: String, contexts: [JSONValue], state: State = .queued, runID: String? = nil, submissionKey: String? = nil, error: String? = nil) {
        self.id = id; self.content = content; self.contexts = contexts; self.state = state; self.runID = runID; self.submissionKey = submissionKey; self.error = error
    }

    /// 卡片上的说明。
    public func caption(running: Bool) -> String {
        if state == .inserting { return "已插入，AI 做完这一步就接上" }
        return error ?? (running ? "回答结束后自动发送" : "待发送")
    }
}

public enum AgentQueue {
    public static let maximum = 5

    /// 加入一条；满了返回 nil。
    public static func adding(_ items: [AgentQueuedMessage], _ item: AgentQueuedMessage) -> [AgentQueuedMessage]? {
        items.count >= maximum ? nil : items + [item]
    }

    /// 已经有一条在插入时，其余的「立即发送」先不让点。
    public static func canInsert(_ items: [AgentQueuedMessage], running: Bool, runID: String?, compacting: Bool) -> Bool {
        !running || (runID != nil && !compacting && !items.contains { $0.state == .inserting })
    }

    public static func inserting(_ items: [AgentQueuedMessage], id: String, runID: String, key: String) -> [AgentQueuedMessage] {
        items.map { item in
            guard item.id == id else { return item }
            var next = item; next.state = .inserting; next.runID = runID; next.submissionKey = key; next.error = nil; return next
        }
    }

    /// 插入被接上（accepted / applied）：从卡片里移走，它随后作为用户消息出现在对话里。
    public static func accepted(_ items: [AgentQueuedMessage], key: String) -> [AgentQueuedMessage] { items.filter { $0.submissionKey != key } }

    /// 插入没成：退回待发送，带上原因。
    public static func returned(_ items: [AgentQueuedMessage], key: String, error: String?) -> [AgentQueuedMessage] {
        items.map { item in
            guard item.submissionKey == key else { return item }
            return AgentQueuedMessage(id: item.id, content: item.content, contexts: item.contexts, error: error)
        }
    }

    /// 回答正常结束后自动发出的下一条。
    public static func next(_ items: [AgentQueuedMessage]) -> AgentQueuedMessage? { items.first { $0.state == .queued } }
}

/// 回复正文的清理（Web `agent/agentMarkdown.ts`）：去掉写完的段落标记与记忆编号，流式时再藏起还没写完的半截语法。
public enum AgentReplyText {
    private static let blockRef = try! NSRegularExpression(pattern: #"[ \t]*\[\[[ \t]*linkresume-block(?:[ \t]*[:：][ \t]*\[[^\[\]\n]{0,80}\](?:[ \t,，、;；]*\[[^\[\]\n]{0,80}\]){0,7}\]\]?|[^\[\]\n]{0,160}\]\])"#)
    private static let partialBlockRef = try! NSRegularExpression(pattern: #"[ \t]*\[\[(?:[A-Za-z0-9_:\-]{0,120}\]?|[ \t]*linkresume-block[^\n]{0,110})?$"#)
    private static let memoryCitation = try! NSRegularExpression(pattern: #"[ \t]?\[M\d{1,4}\]"#)
    private static let partialCitation = try! NSRegularExpression(pattern: #"[ \t]?\[(?:M\d{0,4})?$"#)
    private static let fenceOpen = try! NSRegularExpression(pattern: #"^[ \t]{0,3}(`{3,}|~{3,})"#)
    private static let fenceClose = try! NSRegularExpression(pattern: #"^(`{3,}|~{3,})[ \t]*$"#)
    private static let trailingLink = try! NSRegularExpression(pattern: #"(!?)\[([^\]\n]{1,120})\]\(([^)\n]*)$"#)

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String = "") -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func match(_ regex: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    struct Segment { let code: Bool; let text: String }

    /// 按围栏代码块切段：代码里的内容不清理。
    static func segments(_ text: String) -> [Segment] {
        var result: [Segment] = [], buffer: [String] = []
        var fence: (char: Character, length: Int)?
        func flush(_ code: Bool) { if !buffer.isEmpty { result.append(Segment(code: code, text: buffer.joined(separator: "\n"))); buffer = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let open = fence {
                buffer.append(raw)
                let trimmed = line.replacingOccurrences(of: #"^[ \t]{0,3}"#, with: "", options: .regularExpression)
                if let close = match(fenceClose, trimmed), let range = Range(close.range(at: 1), in: trimmed),
                   trimmed[range].first == open.char, trimmed[range].count >= open.length {
                    flush(true); fence = nil
                }
                continue
            }
            if let open = match(fenceOpen, line), let range = Range(open.range(at: 1), in: line), let whole = Range(open.range, in: line) {
                let marker = line[range], info = line[whole.upperBound...]
                if marker.first != "`" || !info.contains("`") {
                    flush(false); fence = (marker.first!, marker.count); buffer.append(raw); continue
                }
            }
            buffer.append(raw)
        }
        flush(fence != nil)
        return result
    }

    private static func outsideCode(_ text: String, _ transform: (String, Bool) -> String) -> String {
        let parts = segments(text)
        return parts.enumerated().map { index, part in part.code ? part.text : transform(part.text, index == parts.count - 1) }.joined(separator: "\n")
    }

    public static func withoutBlockRefs(_ content: String, streaming: Bool = false) -> String {
        outsideCode(content) { segment, last in
            let cleaned = replace(blockRef, in: segment)
            return streaming && last ? replace(partialBlockRef, in: cleaned) : cleaned
        }
    }

    /// 回复引用求职记忆时带的 `[M1]` 编号先不显示，复制时也不带；流式末尾没写完的“[M1”一并去掉。
    public static func withoutMemoryCitations(_ content: String, streaming: Bool = true) -> String {
        outsideCode(content) { segment, last in
            let cleaned = replace(memoryCitation, in: segment)
            return streaming && last ? replace(partialCitation, in: cleaned) : cleaned
        }
    }

    /// 显示与复制用的回复正文。
    public static func clean(_ content: String, streaming: Bool? = nil) -> String {
        withoutMemoryCitations(withoutBlockRefs(content, streaming: streaming ?? false), streaming: streaming ?? true)
    }

    /// 流式中：没写完的链接只显示文字、没写完的代码围栏头先不显示、落单的 `*` / `**` 不外露。
    public static func stabilizeStreaming(_ content: String) -> String {
        guard !content.isEmpty else { return content }
        let parts = segments(content)
        guard let last = parts.last else { return content }
        let head = parts.dropLast().map(\.text)
        if last.code { return last.text.contains("\n") ? content : head.joined(separator: "\n") }
        var tail = last.text
        if let link = match(trailingLink, tail), let whole = Range(link.range, in: tail), let label = Range(link.range(at: 2), in: tail) {
            let image = link.range(at: 1).length > 0
            tail = String(tail[..<whole.lowerBound]) + (image ? "[图片：\(tail[label])]" : String(tail[label]))
        } else {
            let lastLine = tail.components(separatedBy: "\n").last ?? ""
            let stripCode = { (line: String) in line.replacingOccurrences(of: "`[^`\n]*`", with: "", options: .regularExpression) }
            let count = { (text: String, token: String) in text.components(separatedBy: token).count - 1 }
            let outside = stripCode(lastLine)
            if count(outside, "**") % 2 == 1 {
                if lastLine.hasSuffix("**"), count(stripCode(String(lastLine.dropLast(2))), "**") % 2 == 0 {
                    tail = String(tail.dropLast(2))
                } else if let range = tail.range(of: "**", options: .backwards) {
                    let after = tail[range.upperBound...]
                    if !after.isEmpty, !(after.first?.isWhitespace ?? false), count(String(after), "`") % 2 == 0 { tail += "**" }
                }
            } else if lastLine.hasSuffix("*"), !lastLine.hasSuffix("**") {
                if count(outside.replacingOccurrences(of: "**", with: ""), "*") % 2 == 1 { tail = String(tail.dropLast()) }
            }
        }
        return (head + [tail]).joined(separator: "\n")
    }
}

/// 回复下面的卡片（Web `dedupeActionCards`）：同一条回复里多次查到同一岗位或对象时只留第一次，后面带来的公司图标补给第一次。
public enum AgentCards {
    public static func dedupe(_ cards: [JSONValue]) -> [JSONValue] {
        var result: [JSONValue] = []
        var seen: [String: (card: Int, item: Int)] = [:]
        for card in cards {
            let type = card.text("type")
            guard ["objects", "jobs"].contains(type) else { result.append(card); continue }
            var kept: [JSONValue] = []
            for item in card["items"]?.items ?? [] {
                let key = (type == "jobs" ? "pool_job" : item.text("kind")) + ":" + item.text("id")
                if let place = seen[key] {
                    let logo = item.text("logo_url")
                    if !logo.isEmpty, case .object(var target) = result[place.card], var items = target["items"]?.items,
                       items.indices.contains(place.item), items[place.item].text("logo_url").isEmpty, case .object(var fields) = items[place.item] {
                        fields["logo_url"] = .string(logo); items[place.item] = .object(fields)
                        target["items"] = .array(items); result[place.card] = .object(target)
                    }
                    continue
                }
                seen[key] = (result.count, kept.count)
                kept.append(item)
            }
            if !kept.isEmpty, case .object(var fields) = card { fields["items"] = .array(kept); result.append(.object(fields)) }
        }
        return result
    }
}

/// 「按画像找岗位」还差什么（后端 `profile_match.missing_parts`）：目标岗位、至少一段教育、技能或实习/工作/项目任一。
/// `GET /api/account/career-profile/job-readiness` 没对桌面开放，桌面按读到的求职画像（`career-profile`）与求职意向（`user-profile`）自己算。
public enum JobReadiness {
    public static let labels = ["target_role": "目标岗位", "education": "教育经历", "skills": "技能"]

    public static func missing(profile: JSONValue?, intent: JSONValue?) -> [(key: String, label: String)] {
        let sections = profile?["experience"]?["sections"]?.items ?? []
        let filled = { (kinds: Set<String>) in
            sections.filter { kinds.contains($0.text("kind")) }.flatMap { $0["entries"]?.items ?? [] }.contains { entry in
                if !entry.text("description").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                guard case .object(let fields) = entry["fields"] ?? .null else { return false }
                return fields.values.contains { !($0.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            }
        }
        var keys: [String] = []
        if (intent?.text("target_role") ?? "").trimmingCharacters(in: .whitespaces).isEmpty { keys.append("target_role") }
        if !filled(["education"]) { keys.append("education") }
        if CareerProfileRules.skills(profile?["experience"]).isEmpty && !filled(["work", "internship", "project"]) { keys.append("skills") }
        return keys.map { ($0, labels[$0]!) }
    }
}

/// 「选择模型」的分段（Web `menuGroups`）：所有人都能用的基础模型在上，会员模型在下，当前点不了的放最后；段内保持原顺序。
public enum AgentModelSections {
    public static func split(_ models: [JSONValue]) -> [[JSONValue]] {
        let usable = models.filter { $0["available"]?.bool != false || $0["available"] == nil }
        let locked = models.filter { $0["available"] != nil && $0["available"]?.bool == false }
        return [usable.filter { $0["isFreeTier"]?.bool == true }, usable.filter { $0["isFreeTier"]?.bool != true }, locked].filter { !$0.isEmpty }
    }
}
