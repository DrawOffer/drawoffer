import Foundation

/// 编辑器小绘的「智能排版」（Web `ResumeWorkbench.runAiLayout`）：纸面量出每段的行数、末行占比与末行文字，
/// 原生按 Web 的截断规则组 `POST /api/resumes/{id}/review:layout` 请求体；返回的收行 / 左右排布交回纸面核验并一次写进纸里，
/// 排完小绘说一句（压到几页 / 改了几处）并给“撤销”。这里只放请求体、结果文案与错误文案这些纯逻辑。
public enum ResumeSmartLayout {
    /// 与 Web `fresh.slice(0, 120)`、后端 `MAX_BLOCKS` 一致。
    public static let maxBlocks = 120

    /// 纸面回报的每段度量 → 请求体；没有可分析的正文段落时返回 nil（Web：“当前没有可分析的正文段落。”）。
    /// 字段长度按后端 `LayoutBlockInput` 的上限截断（按 Unicode 码点计，与 Python 一致），fill_ratio 保留三位小数。
    public static func requestBody(blocks: [JSONValue]) -> JSONValue? {
        let items = blocks.compactMap(block).prefix(maxBlocks)
        guard !items.isEmpty else { return nil }
        return .object(["blocks": .array(Array(items)), "mode": .string("all")])
    }

    static func block(_ raw: JSONValue) -> JSONValue? {
        let id = raw.text("node_id")
        let text = clip(raw.text("text"), 2000)
        guard !id.isEmpty, id.unicodeScalars.count <= 64, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let severity = raw.text("severity")
        let fill = min(1, max(0, raw["fill_ratio"]?.numberValue ?? 1))
        let lines = min(50, max(1, Int(raw["line_count"]?.numberValue ?? 1)))
        let kind = clip(raw.text("section_kind"), 32)
        return .object([
            "node_id": .string(id),
            "section": .string(clip(raw.text("section"), 60)),
            "section_kind": .string(kind.isEmpty ? "other" : kind),
            "text": .string(text),
            "is_list_item": .bool(raw["is_list_item"] == .bool(true)),
            "is_entry_head": .bool(raw["is_entry_head"] == .bool(true)),
            "is_in_resume_row": .bool(raw["is_in_resume_row"] == .bool(true)),
            "has_bold": .bool(raw["has_bold"] == .bool(true)),
            "line_count": .number(Double(lines)),
            "fill_ratio": .number((fill * 1000).rounded() / 1000),
            "last_line_text": .string(clip(raw.text("last_line_text"), 200)),
            "severity": .string(["widow", "short", "ok"].contains(severity) ? severity : "ok"),
        ])
    }

    static func clip(_ value: String, _ limit: Int) -> String {
        let scalars = value.unicodeScalars
        guard scalars.count > limit else { return value }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars.prefix(limit))
        return String(view)
    }

    /// 排完之后小绘说的一句。`undoable` 只在真的改了且纸面没再被改过时为 true（Web `layoutUndoDoc`）。
    public struct Outcome: Equatable, Sendable {
        public let message: String
        public let undoable: Bool
        /// 小绘旁边那句话停留多久（Web 改了几处 8 秒，其余 4 秒）。
        public let seconds: Double
    }

    /// Web `runAiLayout` 收尾：没有建议或一处都没换上就说 summary（或“挺整齐”）；换上了按页数说“压到 N 页”或“改了 N 处”。
    /// 智能一页时页数恒按 1 算。
    public static func outcome(total: Int, applied: Int, summary: String, pagesBefore: Int, pagesAfter: Int,
                               smartOnePage: Bool, undoable: Bool) -> Outcome {
        let said = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard total > 0, applied > 0 else {
            return Outcome(message: said.isEmpty ? "现在的排版已经挺整齐，没有要动的。" : said, undoable: false, seconds: 4)
        }
        let before = smartOnePage ? 1 : max(1, pagesBefore)
        let after = smartOnePage ? 1 : max(1, pagesAfter)
        let message = after < before ? "排好了，压到 \(after) 页。" : "排好了，改了 \(applied) 处。"
        return Outcome(message: message, undoable: undoable, seconds: 8)
    }

    public static let emptyMessage = "当前没有可分析的正文段落。"

    /// Web：积分不够单独说，其余一律“检查网络后再试”。桌面端多一种：服务端还没对桌面开放。
    public static func errorMessage(_ error: Error) -> String {
        if case APIError.unauthorized = error { return "登录已失效，请重新登录。" }
        if case APIError.server(_, let code) = error {
            if code == "CREDIT_INSUFFICIENT" || code == "PAID_CREDIT_REQUIRED" { return "积分不够了，充值后再试。" }
            if code == "DESKTOP_ROUTE_FORBIDDEN" { return "当前服务尚未开放桌面端智能排版，请更新服务端后重试。" }
        }
        return "小绘没能生成排版建议，检查网络后再试。"
    }
}
