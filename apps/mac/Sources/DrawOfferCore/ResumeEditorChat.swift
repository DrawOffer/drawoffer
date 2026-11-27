import Foundation

/// 小绘停在段旁改一段（Web `workbench/EditorChat.tsx`，Figma 04 页 C2–C6；96117ada3 起选方向后一步出稿）：
/// 每段各自一段对话（`GET /api/resumes/{id}/editor-chat?entry_id=`），话写在白板上，改好的句子写在纸上（浅蓝底 = 还没换上）。
/// 方向由服务端按 `editor_action` 定：深化 / 诊断 / 精修（技能、自我评价这类栏是检查写法 / 精修）。
public enum ResumeEditorChat {
    /// 打开对话时服务端替用户发的一句，不显示。
    public static let kickoff = "（编辑器打开了对话）"
    /// H：等了这么久还没有任何回音，就当没改成（Web `RUN_SILENCE_MS`）。
    public static let silence: Duration = .seconds(60)
    /// 这一段最多带这么多行给服务端（Web `unitLineIds` 的 60）。
    public static let maxLineIDs = 60

    /// 点的是哪个方向（Web `EditorChatAction`）。
    public enum Action: String, Sendable { case deepen, polish, diagnose, preset }

    public struct Direction: Equatable, Sendable {
        public let label: String
        public let hint: String
        public let action: Action
    }

    /// Web `isNonExperience`：技能、个人总结这类栏不深化。
    public static func isNonExperience(semanticKind: String?, label: String) -> Bool {
        if semanticKind == "skills" || semanticKind == "profile" { return true }
        return ["技能", "技术栈", "专长", "优势", "自我评价", "个人总结", "个人简介"].contains { label.contains($0) }
    }

    /// 新对话里给的方向（Web 欢迎语下的编号选项）。
    public static func directions(nonExperience: Bool) -> [Direction] {
        nonExperience ? [
            Direction(label: "检查这一栏写法", hint: "说出最该改的几处，点一处就改", action: .diagnose),
            Direction(label: "精修这一栏", hint: "排好顺序、去掉套话，不加内容", action: .polish),
        ] : [
            Direction(label: "深化这一段", hint: "补上做法、规模和结果，直接改好", action: .deepen),
            Direction(label: "诊断这一段", hint: "说出最该改的几处，点一处就改", action: .diagnose),
            Direction(label: "直接精修", hint: "只改不顺的句子，不加内容", action: .polish),
        ]
    }

    public static func welcome(unitLabel: String?) -> String {
        guard let unitLabel, !unitLabel.isEmpty else { return "选一段开始" }
        return "正在看「\(unitLabel)」"
    }
    public static let welcomeNote = "只看并只改这一段，不跨模块关联。点下面一个方向，或直接在底下输入你的要求。"
    public static let pickSay = "想先改哪一段？"
    public static let pickNote = "每段独立聊，不串段；也可以直接点左边简历里的任意一段。"
    public static let loadFailed = "对话没有打开，检查网络后再试一次。"
    public static let staleSay = "你改了这段，这次改写就不用了。我按新的内容再看看？"

    /// 分区 C · G / H：积分不够、出错都只在白板说一句原因，不弹窗（Web `chatError`）。
    public static func failure(_ error: Error, failures: Int) -> (text: String, credit: Bool) {
        if let credit = creditMessage(error, fallback: "积分不够，这段没改，简历还是原样。") { return (credit, true) }
        return (failures > 1 ? "现在有点忙，还是没改成，过一会儿再试。" : "刚才没连上，这段没改成，简历还是原样。", false)
    }

    /// 改这一条（LineChat）出错时的一句（a667ae1ba）。
    public static func lineFailure(_ error: Error, failures: Int) -> (text: String, credit: Bool) {
        if let credit = creditMessage(error, fallback: "积分不够，这句没改，简历还是原样。") { return (credit, true) }
        return (failures > 1 ? "现在有点忙，这句还是没改成，过一会儿再试。" : "刚才没连上，这句没改成，简历还是原样。", false)
    }

    /// Web `creditShortfallText`：402 余额不足说兜底句（桌面端拿不到 required / available）；403 会员限定沿用 `creditErrorMessage`。
    static func creditMessage(_ error: Error, fallback: String) -> String? {
        guard case APIError.server(_, let code) = error else { return nil }
        if code == "CREDIT_INSUFFICIENT" { return fallback }
        if code == "PAID_CREDIT_REQUIRED" { return "当前额度不能使用这项功能。" }
        return nil
    }

    // MARK: 消息与改法卡片

    /// 不显示压缩记录和打开对话时那一句。
    public static func visible(_ messages: [JSONValue]) -> [JSONValue] {
        messages.filter { message in
            if message.text("message_type") == "compaction" { return false }
            let kickoff = message["guide"]?["kickoff"] == .bool(true) || message.text("content").trimmingCharacters(in: .whitespacesAndNewlines) == kickoff
            return !(message.text("role") == "user" && kickoff)
        }
    }

    public struct ChangeLine: Equatable, Sendable {
        public let lineID: String
        public let before: String
        public let text: String
        /// 橙色 = 待核实（mark.origin == verify）。
        public let risky: [String]
        public let marks: [JSONValue]
    }

    public struct ChangeCard: Equatable, Sendable {
        public let id: String
        public let type: String
        public let entryID: String
        public let resumeID: String
        public let lines: [ChangeLine]
        public let scene: [String]
        public let facts: [String]
    }

    /// `resume_package` / `resume_rewrite` 是写到纸上的改法。
    public static func changeCard(_ card: JSONValue) -> ChangeCard? {
        let type = card.text("type")
        guard type == "resume_package" || type == "resume_rewrite", !card.text("id").isEmpty else { return nil }
        let lines = (card["lines"]?.items ?? []).compactMap { line -> ChangeLine? in
            let id = line.text("line_id")
            guard !id.isEmpty else { return nil }
            let marks = line["marks"]?.items ?? []
            return ChangeLine(lineID: id, before: line.text("before"), text: line.text("text"),
                              risky: marks.filter { $0.text("origin") == "verify" }.map { $0.text("text") }, marks: marks)
        }
        return ChangeCard(id: card.text("id"), type: type, entryID: card.text("entry_id"), resumeID: card.text("resume_id"), lines: lines,
                          scene: (card["scene"]?.items ?? []).compactMap(\.stringValue), facts: (card["facts"]?.items ?? []).compactMap(\.stringValue))
    }

    public static func changeCards(_ message: JSONValue) -> [ChangeCard] { (message["cards"]?.items ?? []).compactMap(changeCard) }

    /// 还没换上的几条：纸上还是原句、且确实改了；放弃过的卡片不算。
    public static func pendingLines(_ card: ChangeCard, dismissed: Set<String>, current: (String) -> String?) -> [ChangeLine] {
        guard !dismissed.contains(card.id) else { return [] }
        return card.lines.filter { line in
            let before = line.before.trimmingCharacters(in: .whitespacesAndNewlines)
            return (current(line.lineID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == before
                && before != line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 最近一次纸面改法里还没换上的几条（Web `pending`）：从最新的消息往回找第一张改法卡片，一条都不剩就是 nil。
    public static func latestPending(_ visible: [JSONValue], dismissed: Set<String>, current: (String) -> String?) -> (card: ChangeCard, lines: [ChangeLine])? {
        for message in visible.reversed() {
            guard let card = changeCards(message).last else { continue }
            let lines = pendingLines(card, dismissed: dismissed, current: current)
            return lines.isEmpty ? nil : (card, lines)
        }
        return nil
    }

    /// 发一句（Web `api.streamAgentMessage` 的 body）。
    public static func messageBody(content: String, idempotencyKey: String, entryID: String, lineIDs: [String], action: Action?,
                                   draftCardID: String?, replyTo: Int? = nil, answers: [(question: String, option: String)] = []) -> JSONValue {
        var body: [String: JSONValue] = ["content": .string(content), "idempotency_key": .string(idempotencyKey)]
        if !entryID.isEmpty { body["editor_entry_id"] = .string(entryID) }
        if !lineIDs.isEmpty { body["editor_line_ids"] = .array(lineIDs.prefix(maxLineIDs).map(JSONValue.string)) }
        if let action { body["editor_action"] = .string(action.rawValue) }
        if let draftCardID { body["editor_draft_card_id"] = .string(draftCardID) }
        if let replyTo, !answers.isEmpty {
            body["reply_to_sequence_no"] = .number(Double(replyTo))
            body["clarification_answers"] = .array(answers.map { .object(["question_id": .string($0.question), "option_id": .string($0.option)]) })
        }
        return .object(body)
    }

    /// 换上后同步标记与经历复习稿（Web `api.experienceApplied`）。
    public static func appliedBody(_ card: ChangeCard, lines: [ChangeLine]) -> JSONValue {
        .object([
            "marks": .array(Array(lines.flatMap(\.marks).prefix(40))),
            "scene": .array(card.scene.prefix(12).map(JSONValue.string)),
            "facts": .array(card.facts.prefix(12).map(JSONValue.string)),
        ])
    }

    /// 多条时列表里的一句摘要（Web `previewSnippet`，超过 42 字截断）。
    public static func snippet(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > 42 ? String(clean.prefix(42)) + "…" : clean
    }

    public static func chatPath(resumeID: String, entryID: String, restart: Bool = false) -> (path: String, query: [String: String]) {
        ("/api/resumes/\(resumeID)/editor-chat\(restart ? "/restart" : "")", entryID.isEmpty ? [:] : ["entry_id": entryID])
    }
}
