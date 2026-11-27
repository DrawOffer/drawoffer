import Foundation

/// 简历模块是否为空（Web `outlineSectionSummary` 的 `empty` 判断）。
public enum ResumeOutline {
    /// 模块正文是否为空（Web `empty` 摘要：行尾「空」标签）。
    public static func isEmpty(_ section: JSONValue) -> Bool { text(section).isEmpty }

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
}
