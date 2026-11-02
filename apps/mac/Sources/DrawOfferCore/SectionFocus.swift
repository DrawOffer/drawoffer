import Foundation

/// “聚焦这段”（Web `sectionFocus/sectionModel.ts` 的简化移植）：把一段经历（条目）或没有条目的模块
/// 转成 `section-review:analyze` 需要的 `{entry_id, heading, lines}`，并能把采用的改写写回对应行。
public enum SectionFocus {
    public static let maxLines = 20
    public static let lineChars = 500

    public struct Line: Equatable, Sendable { public let id: String; public let text: String }
    public struct Unit: Equatable, Sendable {
        public let id: String
        public let heading: String
        public let lines: [Line]
        public var payload: JSONValue {
            .object(["entry_id": .string(id), "heading": .string(String(heading.prefix(200))),
                     "lines": .array(lines.prefix(maxLines).map { .object(["id": .string($0.id), "text": .string(String($0.text.prefix(lineChars)))]) })])
        }
    }

    /// 一个块里可改写的行：段落本身，或列表的每一项。
    static func lines(_ blocks: JSONValue?) -> [Line] {
        (blocks?.items ?? []).flatMap { block -> [Line] in
            switch block.text("block_type") {
            case "paragraph":
                let text = ResumeDocument.runsText(block["runs"])
                return text.isEmpty ? [] : [Line(id: block.text("node_id"), text: text)]
            case "bullet_list", "ordered_list":
                return (block["items"]?.items ?? []).compactMap { item in
                    let text = ResumeDocument.runsText(item["runs"])
                    return text.isEmpty ? nil : Line(id: item.text("node_id"), text: text)
                }
            default: return []
            }
        }
    }

    /// 条目：标题取字段里的单位/职位/时间等短文本；行取条目下的段落与列表项。
    public static func unit(entry: JSONValue) -> Unit? {
        var heading: [String] = []
        if case .object(let fields)? = entry["fields"] {
            for key in fields.keys.sorted() {
                let value = ResumeDocument.value(fields[key])
                if !value.isEmpty { heading.append(value) }
            }
        }
        let found = lines(entry["blocks"])
        guard !found.isEmpty else { return nil }
        return Unit(id: entry.text("node_id"), heading: heading.joined(separator: " · "), lines: found)
    }

    /// 没有条目的模块（如技能）：整个模块作为一段。
    public static func unit(section: JSONValue) -> Unit? {
        let found = lines(section["blocks"])
        guard !found.isEmpty else { return nil }
        return Unit(id: section.text("node_id"), heading: ResumeDocument.value(section["title"]), lines: found)
    }

    /// 把某一行（段落或列表项）的文字替换为采用的改写；找不到这一行时返回 nil。
    public static func replacing(_ document: JSONValue, lineID: String, with text: String) -> JSONValue? {
        var found = false
        func visit(_ node: JSONValue) -> JSONValue {
            switch node {
            case .object(var fields):
                if fields["node_id"]?.stringValue == lineID, fields["runs"] != nil {
                    found = true
                    fields["runs"] = ResumeDocument.plainRuns(String(text.prefix(lineChars)))
                    return .object(fields)
                }
                for (key, value) in fields { fields[key] = visit(value) }
                return .object(fields)
            case .array(let items): return .array(items.map(visit))
            default: return node
            }
        }
        let next = visit(document)
        return found ? next : nil
    }

    public static func errorMessage(_ error: Error) -> String {
        guard case APIError.server(let status, let code) = error else { return "分析没有完成，请检查网络后重试。" }
        switch code {
        case "CREDIT_INSUFFICIENT": return "积分已用完，本次 AI 请求没有发出。"
        case "PAID_CREDIT_REQUIRED": return "当前额度只能使用基础模型，暂不能使用这项功能。"
        case "LLM_MODEL_NOT_CONFIGURED": return "AI 模型暂未配置，请稍后再试。"
        case "RESUME_NOT_FOUND": return "这份简历已不存在。"
        case "SECTION_REVIEW_ITEM_APPLIED": return "这条建议已经采用过了。"
        default: return status >= 500 ? "AI 服务暂时不可用，请稍后重试。" : "分析没有完成，请稍后重试。"
        }
    }
}
