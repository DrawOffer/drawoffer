import Foundation

/// 粘贴的岗位文字先在本机按“标签：值”抽字段，抽到职位名称和公司名称才算成功，否则交给 AI（`parse-draft`，按量计费）。
///
/// 只认带明确标签的行（如“职位：后端工程师”“【公司】某某科技”），不猜没有标签的句子；
/// 枚举类字段（雇佣类型、工作方式、薪资周期）和薪资上下限留空，由用户在确认页补，避免填进服务端不认的值。
/// 岗位描述直接用整段原文。
public enum JobDraftParser {
    static let labels: [(key: String, names: [String])] = [
        ("job_title", ["职位名称", "岗位名称", "招聘岗位", "招聘职位", "职位", "岗位", "job title", "position", "title"]),
        ("company_name", ["公司名称", "企业名称", "招聘单位", "招聘公司", "用人单位", "公司", "企业", "company"]),
        ("work_city", ["工作城市", "城市", "base", "location"]),
        ("work_address", ["工作地址", "详细地址", "办公地址", "地址"]),
        ("work_place", ["工作地点", "地点"]),
        ("salary_text", ["薪资范围", "薪资待遇", "薪资", "薪酬", "月薪", "年薪", "待遇", "salary"]),
        ("education_requirement", ["学历要求", "学历", "education"]),
        ("experience_requirement", ["经验要求", "工作经验", "工作年限", "经验", "experience"]),
        ("work_schedule", ["工作时间", "上班时间"]),
        ("recruiter_name", ["招聘人", "联系人", "招聘者", "hr"]),
        ("company_industry", ["所属行业", "行业"]),
        ("company_size", ["公司规模", "企业规模", "规模"]),
    ]

    /// 成功时返回表单字段（键与 `CareerJobImportSheet` 表单相同）；没抽到职位或公司时返回 nil。
    public static func parse(_ text: String) -> [String: String]? {
        var fields: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            guard let (key, value) = field(raw), fields[key] == nil else { continue }
            fields[key] = value
        }
        // “工作地点”短的当城市，长的（带门牌、路名）当地址
        if let place = fields.removeValue(forKey: "work_place") {
            let city = place.count <= 12 && !place.contains(where: \.isNumber) && !place.contains("路") && !place.contains("区")
            let key = city ? "work_city" : "work_address"
            if fields[key] == nil { fields[key] = place }
        }
        guard let title = fields["job_title"], !title.isEmpty, let company = fields["company_name"], !company.isEmpty else { return nil }
        fields["description"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return fields
    }

    /// 一行“标签：值”或“【标签】值”；值 1–80 字。
    static func field(_ line: String) -> (String, String)? {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        while let first = rest.first, "•·-*#>".contains(first) { rest = rest.dropFirst().drop(while: \.isWhitespace) }
        var bracketed = false
        if let first = rest.first, "【[".contains(first) { rest = rest.dropFirst(); bracketed = true }
        let lowered = rest.lowercased()
        for (key, names) in labels {
            for name in names where lowered.hasPrefix(name) {
                var value = rest.dropFirst(name.count)
                if bracketed {
                    guard let close = value.first, "】]".contains(close) else { continue }
                    value = value.dropFirst()
                }
                value = value.drop(while: \.isWhitespace)
                if let colon = value.first, ":：".contains(colon) { value = value.dropFirst() }
                else if !bracketed { continue }
                let text = value.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, text.count <= 80 else { return nil }
                return (key, text)
            }
        }
        return nil
    }
}
