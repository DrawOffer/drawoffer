import Foundation

/// 大纲 V2 每行的一行摘要（Web `outlineSectionSummary` + `outlineSummaryText`）：
/// 个人信息列出已填的联系方式；经历按条目数（段）与要点数；教育没有要点时列学历；只有列表时按条数；否则按字数。
public enum ResumeOutline {
    static let degrees = ["博士", "硕士", "本科", "大专", "专科"]
    static let contactLabels = ["avatar": "头像", "phone": "电话", "email": "邮箱", "github": "GitHub", "linkedin": "LinkedIn", "website": "主页", "location": "城市"]

    public static func identitySummary(_ identity: JSONValue?) -> String {
        guard let identity else { return "还没有联系方式" }
        var kinds = Set((identity["contacts"]?.items ?? []).filter { !$0.text("value").trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.text("kind") })
        let content = (identity["contacts"]?.items ?? []).map { $0.text("value") }.joined(separator: "\n")
            + "\n" + ResumeDocument.value(identity["headline"])
        if content.range(of: #"1\d{2}[\s-]?\d{4}[\s-]?\d{4}|\d{3,4}-\d{7,8}"#, options: .regularExpression) != nil { kinds.insert("phone") }
        if content.range(of: #"[\w.+-]+@[\w-]+\.[\w.]+"#, options: .regularExpression) != nil { kinds.insert("email") }
        if content.range(of: "github.com", options: .caseInsensitive) != nil { kinds.insert("github") }
        if content.range(of: "linkedin.com", options: .caseInsensitive) != nil { kinds.insert("linkedin") }
        let avatar = (identity["avatar"] ?? .null) != .null
        let ordered = (avatar ? ["avatar"] : []) + ["phone", "email", "github", "linkedin", "website", "location"].filter(kinds.contains)
        return ordered.isEmpty ? "还没有联系方式" : ordered.map { contactLabels[$0] ?? $0 }.joined(separator: " · ")
    }

    /// 模块正文是否为空（Web `empty` 摘要：行尾「空」标签）。
    public static func isEmpty(_ section: JSONValue) -> Bool { text(section).isEmpty }

    public static func summary(_ section: JSONValue) -> String {
        let body = text(section)
        if body.isEmpty { return "还没有内容" }
        let entries = section["entries"]?.items.count ?? 0
        var bullets = 0
        func visit(_ blocks: [JSONValue]) {
            for block in blocks {
                let type = block.text("block_type")
                if type == "bullet_list" || type == "ordered_list" { bullets += block["items"]?.items.count ?? 0 }
                if type == "row" { for cell in block["cells"]?.items ?? [] { visit(cell["blocks"]?.items ?? []) } }
            }
        }
        visit(section["blocks"]?.items ?? [])
        for entry in section["entries"]?.items ?? [] { visit(entry["blocks"]?.items ?? []) }
        if entries > 0 {
            let found = section.text("semantic_kind") == "education" && bullets == 0 ? degrees.filter(body.contains) : []
            return ["\(entries) 段", bullets > 0 ? "\(bullets) 条要点" : nil, found.isEmpty ? nil : found.joined(separator: " / ")].compactMap { $0 }.joined(separator: " · ")
        }
        if bullets > 0 { return "\(bullets) 条" }
        return "\(body.filter { !$0.isWhitespace }.count) 字"
    }

    /// 模块标题以外的全部可见文字。
    static func text(_ section: JSONValue) -> String {
        var parts: [String] = []
        func blocks(_ list: [JSONValue]) {
            for block in list {
                parts.append(ResumeDocument.runsText(block["runs"]))
                for item in block["items"]?.items ?? [] { parts.append(ResumeDocument.runsText(item["runs"])) }
                for cell in block["cells"]?.items ?? [] { blocks(cell["blocks"]?.items ?? []) }
            }
        }
        blocks(section["blocks"]?.items ?? [])
        for entry in section["entries"]?.items ?? [] {
            if case .object(let fields) = entry["fields"] ?? .null {
                for key in fields.keys.sorted() { parts.append(ResumeDocument.value(fields[key])) }
            }
            blocks(entry["blocks"]?.items ?? [])
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Web `OUTLINE_MODULE_OPTIONS`：添加模块弹层的候选，已有的类型不再列出。
    public static let moduleOptions: [(kind: String, title: String, hint: String)] = [
        ("profile", "个人总结", "用 2–3 句话概括定位与优势"),
        ("work", "工作经历", "公司、职位与主要成果"),
        ("project", "项目经历", "项目背景、职责与结果"),
        ("education", "教育经历", "学校、专业与学历"),
        ("skills", "专业技能", "技术栈与熟练程度"),
        ("activity", "校园经历", "社团、学生工作、竞赛"),
        ("certificates", "证书资质", "语言、职业或技术认证"),
        ("awards", "获奖荣誉", "奖项名称、级别与时间"),
        ("languages", "语言能力", "语种与熟练程度"),
        ("interests", "兴趣爱好", "与岗位相关的个人特长"),
    ]
}
