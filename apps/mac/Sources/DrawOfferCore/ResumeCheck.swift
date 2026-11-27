import Foundation

/// 把整份简历拆成可改写的段（Web `ResumeCheck.tsx` 的 units 规则，检查简历已在 Web 下线，改这一条仍沿用），
/// 组改写请求的上下文，并把改好的一句写回 canonical 正文（这一行没被改过才写）。
public enum ResumeCheck {
    public static let maxUnits = 16
    public static let maxLines = 20
    public static let lineChars = 500
    public static let unitChars = 4_000

    /// 不检查的模块（简介、证书、荣誉、兴趣……）；其中技能类按技能检查。与 Web `LIST_SECTION` / `SKILL_SECTION` 相同。
    static let skillWords = ["技能", "技术栈", "专长", "能力"]
    static let listWords = skillWords + ["评价", "简介", "总结", "兴趣", "爱好", "语言", "证书", "荣誉", "奖项", "获奖", "自我"]
    static let otherKinds: Set<String> = ["profile", "interests", "certificates", "awards", "languages"]
    /// 条目标题优先取名称，没有时取单位；其余字段（角色、时间、地点）只给模型看。
    static let headingFields = ["name", "organization"]

    public enum Kind: String, Sendable { case experience, skills, other }

    public struct Unit: Equatable, Sendable {
        public let id: String
        public let sectionLabel: String
        /// 条目时是名称 / 单位；整个模块作为一段时是模块标题。
        public let heading: String
        /// 换标题时写回的字段（条目的 name / organization）；整个模块时为 nil，标题不可改。
        public let headingField: String?
        public let meta: [String]
        public let kind: Kind
        public let isEntry: Bool
        public let lines: [SectionFocus.Line]

        var contextText: String { ([heading] + meta + lines.map(\.text)).filter { !$0.isEmpty }.joined(separator: "\n") }
    }

    // MARK: Units

    public static func kind(semantic: String, label: String) -> Kind {
        if semantic == "skills" || skillWords.contains(where: { label.contains($0) }) { return .skills }
        if otherKinds.contains(semantic) || listWords.contains(where: { label.contains($0) }) { return .other }
        return .experience
    }

    /// 可改写的行：只取前 20 行里没被截断的（截断的行写回前核对不过），整段不超过 4000 字。
    static func lines(_ blocks: JSONValue?) -> [SectionFocus.Line] {
        var budget = unitChars
        var result: [SectionFocus.Line] = []
        for line in SectionFocus.lines(blocks) where !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
            guard result.count < maxLines, line.text.count <= lineChars, line.text.count <= budget else { continue }
            budget -= line.text.count
            result.append(line)
        }
        return result
    }

    /// 整份简历拆成段：有条目的模块每个条目一段，没有条目的模块整个一段；不检查的模块和空段不发。
    public static func units(_ document: JSONValue, label: (JSONValue) -> String) -> [Unit] {
        var units: [Unit] = []
        for section in document["sections"]?.items ?? [] {
            let sectionLabel = label(section)
            let kind = kind(semantic: section.text("semantic_kind"), label: sectionLabel)
            guard kind != .other else { continue }
            let own = lines(section["blocks"])
            if !own.isEmpty {
                units.append(Unit(id: section.text("node_id"), sectionLabel: sectionLabel, heading: sectionLabel, headingField: nil,
                                  meta: [], kind: kind, isEntry: false, lines: own))
            }
            for entry in section["entries"]?.items ?? [] {
                let found = lines(entry["blocks"])
                guard !found.isEmpty else { continue }
                let headingField = headingFields.first { !ResumeDocument.value(entry["fields"]?[$0]).isEmpty }
                let heading = headingField.map { ResumeDocument.value(entry["fields"]?[$0]) } ?? ""
                let meta = ResumeDocument.entryFields.map(\.key).filter { $0 != headingField && $0 != "url" }
                    .map { ResumeDocument.value(entry["fields"]?[$0]) }.filter { !$0.isEmpty }
                units.append(Unit(id: entry.text("node_id"), sectionLabel: sectionLabel, heading: heading, headingField: headingField,
                                  meta: meta, kind: kind, isEntry: true, lines: found))
            }
        }
        return Array(units.prefix(maxUnits))
    }

    /// 改写一句时带上的其他段（Web `defaultContextIds` + `contextPayload`）：最多 6 段、每段 1500 字、合计 6000 字。
    public static func context(_ units: [Unit], excluding id: String) -> JSONValue {
        var budget = 6_000
        var items: [JSONValue] = []
        for unit in units where unit.id != id {
            guard items.count < 6, budget > 0 else { break }
            let text = String(unit.contextText.prefix(min(1_500, budget)))
            budget -= text.count
            let label = unit.isEntry && !unit.sectionLabel.isEmpty ? "\(unit.sectionLabel) · \(unit.heading)" : unit.heading
            items.append(.object(["id": .string(unit.id), "label": .string(String(label.prefix(120))), "text": .string(text)]))
        }
        return .array(items)
    }

    // MARK: Writing back

    public enum WriteError: Error, Equatable { case conflict, missing }

    /// 某一行（段落或列表项）当前的文字；找不到时为 nil。
    public static func lineText(_ document: JSONValue, lineID: String) -> String? {
        switch document {
        case .object(let fields):
            if fields["node_id"]?.stringValue == lineID, fields["runs"] != nil { return ResumeDocument.runsText(fields["runs"]) }
            for value in fields.values { if let found = lineText(value, lineID: lineID) { return found } }
            return nil
        case .array(let items):
            for item in items { if let found = lineText(item, lineID: lineID) { return found } }
            return nil
        default: return nil
        }
    }

    static func same(_ left: String, _ right: String) -> Bool {
        left.trimmingCharacters(in: .whitespacesAndNewlines) == right.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 换上一句：这一行还是检查时的文字才换，被改过就不动。
    public static func replaceLine(_ document: JSONValue, lineID: String, before: String, with text: String) -> Swift.Result<JSONValue, WriteError> {
        guard let current = lineText(document, lineID: lineID) else { return .failure(.missing) }
        guard same(current, before) else { return .failure(.conflict) }
        guard let next = SectionFocus.replacing(document, lineID: lineID, with: text) else { return .failure(.missing) }
        return .success(next)
    }

    public static func errorMessage(_ error: Error) -> (credit: Bool, message: String) {
        if case APIError.server(_, let code) = error, ["CREDIT_INSUFFICIENT", "PAID_CREDIT_REQUIRED"].contains(code) {
            return (true, "积分不够了，充值后再试。")
        }
        return (false, "没连上，稍后再试。")
    }
}
