import Foundation

/// 检查简历（Web `workbench/ResumeCheck.tsx`，Figma 用户端稿 03 页分区 17）：把整份简历拆成段，
/// `POST /api/resumes/{id}/review:check` 一次读完，服务端给出最多 6 处；这里负责组请求、解析结果，
/// 以及把“换上 / 删掉 / 并进另一条 / 换标题”写回 canonical 正文。判定、排序、上限和总结论都在服务端。
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

        public var where_: String { [sectionLabel, isEntry ? heading : ""].filter { !$0.isEmpty }.joined(separator: " · ") }

        var checkPayload: JSONValue {
            .object([
                "entry_id": .string(id),
                "section": .string(String(sectionLabel.prefix(60))),
                "heading": .string(String(heading.prefix(200))),
                "meta": .array(meta.prefix(6).map { .string(String($0.prefix(200))) }),
                "kind": .string(kind == .skills ? "skills" : "experience"),
                "lines": .array(lines.map { .object(["id": .string($0.id), "text": .string($0.text)]) }),
            ])
        }

        /// `section-review:rewrite` 的 section（Web `sectionPayload`）。
        public var sectionPayload: JSONValue {
            .object([
                "entry_id": .string(id),
                "heading": .string(String(([heading] + meta).filter { !$0.isEmpty }.joined(separator: " · ").prefix(200))),
                "kind": .string(kind.rawValue),
                "lines": .array(lines.map { .object(["id": .string($0.id), "text": .string($0.text)]) }),
            ])
        }

        var contextText: String { ([heading] + meta + lines.map(\.text)).filter { !$0.isEmpty }.joined(separator: "\n") }
    }

    public struct Finding: Identifiable, Equatable, Sendable {
        public enum Status: Sendable { case open, applied, skipped }
        public let id: String
        public let type: String
        public let typeLabel: String
        public let entryID: String
        public let lineID: String?
        public let quote: String
        public let title: String
        public var detail: String
        /// rewrite / complete / delete / merge / entry
        public let fix: String
        public var suggestion: String?
        public var risky: [String]
        public let mergeInto: String?
        public var caption: String
        public let ask: String
        public let example: String
        /// 纸面上这一行原来的文字（整段时是标题），写回前核对。
        public let before: String
        public let mergeBefore: String
        public let label: String
        public let where_: String
        public var status: Status = .open
    }

    public struct Result: Equatable, Sendable {
        public let summary: String
        public let basis: String
        public let findings: [Finding]
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

    public static func checkBody(_ units: [Unit], pageCount: Int, focus: (entryID: String, answer: String)? = nil) -> JSONValue {
        var body: [String: JSONValue] = ["units": .array(units.map(\.checkPayload)), "page_count": .number(Double(min(10, max(1, pageCount))))]
        if let focus { body["focus"] = .object(["entry_id": .string(focus.entryID), "answer": .string(String(focus.answer.prefix(300)))]) }
        return .object(body)
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

    // MARK: Findings

    static func listLabel(type: String, quote: String, fix: String, title: String) -> String {
        let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !quote.isEmpty, ["empty", "overclaim", "vague"].contains(type) {
            let short = quote.count > 14 ? String(quote.prefix(14)) + "…" : quote
            switch type {
            case "empty": return "“\(short)”是空话"
            case "overclaim": return "“\(short)”说过头了"
            default: return "“\(short)”结果含糊"
            }
        }
        if type == "deletable" { return fix == "merge" ? "有两条说的是同一件事" : "有一条可以删" }
        return title
    }

    static func finding(_ item: JSONValue, units: [Unit]) -> Finding? {
        guard let unit = units.first(where: { $0.id == item.text("entry_id") }) else { return nil }
        let lineID = item.text("line_id").isEmpty ? nil : item.text("line_id")
        let line = lineID.flatMap { id in unit.lines.first { $0.id == id } }
        if lineID != nil && line == nil { return nil }
        let fix = item.text("fix")
        // 整段换标题只对有名称 / 单位字段的条目可写
        if fix == "entry" && unit.headingField == nil { return nil }
        let mergeInto = item.text("merge_into").isEmpty ? nil : item.text("merge_into")
        let type = item.text("type")
        return Finding(
            id: item.text("id"), type: type, typeLabel: item.text("type_label"), entryID: unit.id, lineID: lineID,
            quote: item.text("quote"), title: item.text("title"), detail: item.text("detail"), fix: fix,
            suggestion: item.text("suggestion").isEmpty ? nil : item.text("suggestion"),
            risky: (item["risky"]?.items ?? []).compactMap(\.stringValue), mergeInto: mergeInto,
            caption: item.text("caption"), ask: item.text("ask"), example: item.text("example"),
            before: line?.text ?? unit.heading,
            mergeBefore: mergeInto.flatMap { id in unit.lines.first { $0.id == id }?.text } ?? "",
            label: listLabel(type: type, quote: item.text("quote"), fix: fix, title: item.text("title")),
            where_: unit.where_)
    }

    public static func result(_ response: JSONValue, units: [Unit]) -> Result {
        Result(summary: response.text("summary"), basis: response.text("basis"),
               findings: (response["findings"]?.items ?? []).compactMap { finding($0, units: units) })
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

    /// 删掉一行：段落块或列表项；列表删空时整个列表一起删。
    public static func deleteLine(_ document: JSONValue, lineID: String, before: String) -> Swift.Result<JSONValue, WriteError> {
        guard let current = lineText(document, lineID: lineID) else { return .failure(.missing) }
        guard same(current, before) else { return .failure(.conflict) }
        var found = false
        func visit(_ node: JSONValue) -> JSONValue {
            switch node {
            case .object(var fields):
                for (key, value) in fields { fields[key] = visit(value) }
                return .object(fields)
            case .array(let items):
                var kept: [JSONValue] = []
                for item in items {
                    if item.text("node_id") == lineID, item["runs"] != nil { found = true; continue }
                    let next = visit(item)
                    let list = ["bullet_list", "ordered_list"].contains(next.text("block_type"))
                    if list, !(item["items"]?.items.isEmpty ?? true), next["items"]?.items.isEmpty ?? true { continue }
                    kept.append(next)
                }
                return .array(kept)
            default: return node
            }
        }
        let next = visit(document)
        return found ? .success(next) : .failure(.missing)
    }

    /// 换标题（整段）：把条目的名称 / 单位字段换成建议的标题。
    public static func replaceHeading(_ document: JSONValue, entryID: String, field: String, before: String, with text: String) -> Swift.Result<JSONValue, WriteError> {
        var result: Swift.Result<JSONValue, WriteError> = .failure(.missing)
        func visit(_ node: JSONValue) -> JSONValue {
            switch node {
            case .object(var fields):
                if fields["node_id"]?.stringValue == entryID, case .object(var entryFields)? = fields["fields"] {
                    guard same(ResumeDocument.value(entryFields[field]), before) else { result = .failure(.conflict); return node }
                    guard let value = ResumeDocument.setTextRuns(entryFields[field], ResumeDocument.plainRuns(String(text.prefix(200))).items) else { return node }
                    entryFields[field] = value
                    fields["fields"] = .object(entryFields)
                    result = .success(.null)
                    return .object(fields)
                }
                for (key, value) in fields { fields[key] = visit(value) }
                return .object(fields)
            case .array(let items): return .array(items.map(visit))
            default: return node
            }
        }
        let next = visit(document)
        if case .success = result { return .success(next) }
        return result
    }

    public static func errorMessage(_ error: Error) -> (credit: Bool, message: String) {
        if case APIError.server(_, let code) = error, ["CREDIT_INSUFFICIENT", "PAID_CREDIT_REQUIRED"].contains(code) {
            return (true, "积分不够了，充值后再试。")
        }
        return (false, "没连上，稍后再试。")
    }
}
