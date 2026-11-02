import Foundation

/// 新建简历的写作引导（Web `workbench/guide/guideModel.ts` 的移植）：步骤文案、各步表单的预填、
/// 结构化写入（`guide/writes`）、条目写法推断，以及收尾写回求职画像与求职资料的清单。
/// 文档都是后端 canonical 简历 JSON（identity / sections / entries / blocks）。
public enum ResumeGuideModel {
    public static let steps = ["materials", "job_profile", "basics", "education", "skills", "experience", "wrap_up"]
    public static let labels: [String: String] = [
        "materials": "资料", "job_profile": "求职意向", "basics": "基本信息", "education": "教育",
        "skills": "技能", "experience": "经历", "wrap_up": "完成",
    ]
    /// Pi 用同一句话识别“面板打开了这一步、请先开口”。
    public static let kickoff = "（引导面板打开了这一步）"
    /// 引导里上传的资料统一放进这个资料夹，没有就建一个。
    public static let folderName = "简历资料"

    /// 只往下走的主按钮写明去哪：“下一步：求职意向”。
    public static func nextLabel(_ step: String) -> String {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return "下一步" }
        return "下一步：\(labels[steps[index + 1]] ?? "")"
    }

    public static func stepState(_ guide: JSONValue, _ step: String) -> String {
        if guide.text("status") == "completed" { return "done" }
        if guide.text("current_step") == step { return "current" }
        return (guide["steps"]?[step]?.text("status") ?? "pending") == "pending" ? "pending" : "done"
    }

    public static func remainingSteps(_ guide: JSONValue) -> [String] {
        steps.filter { $0 != "wrap_up" && (guide["steps"]?[$0]?.text("status") ?? "pending") == "pending" }
    }

    /// “欢迎回来，还差 n 步”的已写好与还差两组。
    public static func welcome(_ guide: JSONValue) -> (done: [String], left: [String]) {
        var remaining = remainingSteps(guide)
        let current = guide.text("current_step")
        if !remaining.contains(current) && current != "wrap_up" { remaining.insert(current, at: 0) }
        let left = remaining.map { labels[$0] ?? $0 } + ["完成"]
        let done = steps.filter { $0 != "wrap_up" && !remaining.contains($0) && (guide["steps"]?[$0]?.text("status") ?? "pending") != "pending" }
        return (done.map { labels[$0] ?? $0 }, left)
    }

    public static func sampleIDs(_ guide: JSONValue?) -> Set<String> {
        Set((guide?["samples"]?.items ?? []).map { $0.text("node_id") })
    }

    public static func failureKind(_ code: String) -> String {
        if ["CREDIT_INSUFFICIENT", "PAID_CREDIT_REQUIRED"].contains(code) { return "credit" }
        return ["SKILLS_COMPOSE_INVALID", "EXPERIENCE_COMPOSE_INVALID"].contains(code) ? "invalid" : "failed"
    }

    // MARK: 文字

    /// 一个 textValue / 块 / 列表项上的纯文字。
    public static func textOf(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let text = value["value"]?.stringValue { return text }
        if value["runs"] != nil { return ResumeDocument.runsText(value["runs"]) }
        return ""
    }

    static func fieldText(_ entry: JSONValue?, _ key: String) -> String {
        textOf(entry?["fields"]?[key]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一个节点下所有带 node_id 的节点及其文字。
    static func nodeTexts(_ value: JSONValue?, into result: inout [String: String]) {
        guard let value else { return }
        switch value {
        case .array(let items): items.forEach { nodeTexts($0, into: &result) }
        case .object(let fields):
            if let id = fields["node_id"]?.stringValue { result[id] = textOf(value) }
            for (key, child) in fields where !["runs", "prefix_runs", "source_refs"].contains(key) { nodeTexts(child, into: &result) }
        default: break
        }
    }

    static func entryBullets(_ entry: JSONValue?) -> [String] {
        (entry?["blocks"]?.items ?? []).flatMap { block -> [String] in
            switch block.text("block_type") {
            case "bullet_list", "ordered_list": return (block["items"]?.items ?? []).map { textOf($0) }
            case "paragraph": return [textOf(block)]
            default: return []
            }
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func sections(_ document: JSONValue?) -> [JSONValue] { document?["sections"]?.items ?? [] }
    public static func sectionKinds(_ document: JSONValue?) -> [String] { sections(document).map { $0.text("semantic_kind") } }

    /// 纸面上用户自己的条目（模板示例不算）。
    static func ownEntries(_ document: JSONValue?, kinds: [String], samples: Set<String>) -> [(kind: String, entry: JSONValue)] {
        sections(document).filter { kinds.contains($0.text("semantic_kind")) && !samples.contains($0.text("node_id")) }
            .flatMap { section in (section["entries"]?.items ?? []).map { (section.text("semantic_kind"), $0) } }
            .filter { !samples.contains($0.1.text("node_id")) }
            .map { (kind: $0.0, entry: $0.1) }
    }

    // MARK: 条目写法：新写的条目照同类条目的写法来

    static let dateRange = try! NSRegularExpression(pattern: #"(\d{4}(?:[.\-/年]\d{1,2}月?)?)(\s*[—–\-~～至到]+\s*)(\d{4}(?:[.\-/年]\d{1,2}月?)?|至今|现在|今)"#)
    static let degreeWord = try! NSRegularExpression(pattern: "专科|大专|本科|学士|硕士|研究生|博士")
    static let segmentDelimiter = try! NSRegularExpression(pattern: #"\s*[｜|]\s*"#)
    static let entrySections = ["education", "work", "project", "activity"]

    public struct DateStyle: Equatable, Sendable { public var sep: String; public var pad: Bool; public init(sep: String, pad: Bool) { self.sep = sep; self.pad = pad } }
    public struct EntryFormat: Equatable, Sendable {
        public var lines: [(slots: [String], delimiter: String)]
        public var dash: String
        public var date: DateStyle
        public var joiner: String
        public var degreeFirst: Bool
        public var inlineExtra: Bool
        public static func == (lhs: EntryFormat, rhs: EntryFormat) -> Bool {
            lhs.lines.map { $0.slots } == rhs.lines.map { $0.slots } && lhs.lines.map { $0.delimiter } == rhs.lines.map { $0.delimiter }
                && lhs.dash == rhs.dash && lhs.date == rhs.date && lhs.joiner == rhs.joiner && lhs.degreeFirst == rhs.degreeFirst && lhs.inlineExtra == rhs.inlineExtra
        }
    }
    public static let defaultFormat = EntryFormat(lines: [(["name"], "｜"), (["date", "detail"], "｜")], dash: "—",
                                                 date: DateStyle(sep: ".", pad: true), joiner: " · ", degreeFirst: false, inlineExtra: false)

    static func groups(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func matches(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

    static func split(_ text: String, by regex: NSRegularExpression) -> [String] {
        var parts: [String] = [], last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            parts.append(String(text[last..<range.lowerBound])); last = range.upperBound
        }
        parts.append(String(text[last...]))
        return parts
    }

    static func dateStyle(_ text: String) -> DateStyle? {
        guard let match = groups(try! NSRegularExpression(pattern: #"\d{4}\s*([.\-/年])\s*(\d{1,2})"#), text) else { return nil }
        return DateStyle(sep: match[1], pad: match[2].count == 2)
    }

    /// 随手填的年月（2024.3、2024-03、2024年3月、202403）按模板写法统一；认不出的原样留着。
    public static func normalizeDate(_ value: String, _ style: DateStyle) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["至今", "现在", "今"].contains(text) { return "至今" }
        guard let match = groups(try! NSRegularExpression(pattern: #"^((?:19|20)\d{2})\s*(?:[.\-/年]\s*(\d{1,2})\s*月?|(\d{2}))?$"#), text) else { return text }
        let month = Int(match[2].isEmpty ? match[3] : match[2]) ?? 0
        if month == 0 { return match[1] }
        if month > 12 { return text }
        let mm = style.pad && month < 10 ? "0\(month)" : "\(month)"
        return style.sep == "年" ? "\(match[1])年\(month)月" : "\(match[1])\(style.sep)\(mm)"
    }

    struct EntryParts { var name = "", start = "", end = "", detail = ""; var consumed = 0; var format: EntryFormat? }

    static func leadingParagraphs(_ entry: JSONValue) -> [String] {
        var lines: [String] = []
        for block in entry["blocks"]?.items ?? [] {
            guard block.text("block_type") == "paragraph" else { break }
            lines.append(textOf(block).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return lines
    }

    /// 拆开一个条目的标题和标题下的说明段落：名称、起止、说明各在哪一行、用什么分隔。
    static func readEntry(_ entry: JSONValue) -> EntryParts {
        let heading = fieldText(entry, "name").nilIfBlank ?? fieldText(entry, "organization")
        let texts = [heading] + leadingParagraphs(entry).prefix(2)
        var parts = EntryParts()
        var lines: [(slots: [String], delimiter: String)] = []
        var dash = defaultFormat.dash, date = defaultFormat.date, dated = false
        for (index, text) in texts.enumerated() {
            if index > 0 {
                let previous = lines.count >= index ? lines[index - 1] : nil
                let dateOnly = previous?.slots == ["date"]
                let hasRange = groups(dateRange, text) != nil
                if text.isEmpty || !((!dated && hasRange) || (dateOnly && parts.detail.isEmpty)) { break }
            }
            let delimiter = groups(segmentDelimiter, text)?[0] ?? defaultFormat.lines[1].delimiter
            var slots: [String] = []
            for segment in split(text, by: segmentDelimiter).map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
                if !dated, let match = groups(dateRange, segment) {
                    dated = true
                    parts.start = match[1]; dash = match[2]
                    date = dateStyle(match[1]) ?? dateStyle(match[3]) ?? date
                    parts.end = match[3]
                    slots.append("date")
                } else if index == 0 && parts.name.isEmpty {
                    parts.name = segment; slots.append("name")
                } else if parts.detail.isEmpty {
                    parts.detail = segment; slots.append("detail")
                } else {
                    parts.detail += delimiter + segment
                }
            }
            lines.append((slots, delimiter))
            if index > 0 { parts.consumed = index }
        }
        if !(lines.first?.slots.contains("name") ?? false) {
            lines = [(["name"] + (lines.first?.slots ?? []), lines.first?.delimiter ?? "｜")] + lines.dropFirst()
        }
        if dated {
            let detail = parts.detail
            parts.format = EntryFormat(lines: lines, dash: dash, date: date,
                                       joiner: detail.contains(" · ") ? " · " : detail.contains("·") ? "·" : detail.contains(" / ") ? " / " : " · ",
                                       degreeFirst: detail.trimmed.range(of: "^(专科|大专|本科|学士|硕士|研究生|博士)", options: .regularExpression) != nil,
                                       inlineExtra: detail.contains("；"))
        }
        if parts.name.isEmpty { parts.name = heading }
        if let start = fieldText(entry, "start_date").nilIfBlank { parts.start = start }
        if let end = fieldText(entry, "end_date").nilIfBlank { parts.end = end }
        return parts
    }

    public static func entryName(_ entry: JSONValue?) -> String { entry.map { readEntry($0).name } ?? "" }

    /// 新条目照哪种写法：纸面上同一栏 → 模板示例同一栏 → 纸面其他经历栏 → 模板示例其他经历栏 → 默认。
    public static func entryFormat(_ documents: [JSONValue?], kinds: [String]) -> EntryFormat {
        func pick(_ document: JSONValue?, same: Bool) -> EntryFormat? {
            for section in sections(document) {
                let kind = section.text("semantic_kind")
                if same ? !kinds.contains(kind) : kinds.contains(kind) || !entrySections.contains(kind) { continue }
                for entry in section["entries"]?.items ?? [] {
                    if var format = readEntry(entry).format {
                        if !same { format.inlineExtra = false }
                        return format
                    }
                }
            }
            return nil
        }
        let first = documents.first ?? nil, second = documents.count > 1 ? documents[1] : nil
        return pick(first, same: true) ?? pick(second, same: true) ?? pick(first, same: false) ?? pick(second, same: false) ?? defaultFormat
    }

    /// 模板示例里这一类栏目的标题（如“教育背景”），新建这一栏时沿用。
    public static func sectionTitle(_ documents: [JSONValue?], kind: String) -> String? {
        for document in documents {
            if let title = sections(document).first(where: { $0.text("semantic_kind") == kind }).map({ ResumeDocument.value($0["title"]).trimmingCharacters(in: .whitespaces) }), !title.isEmpty { return title }
        }
        return nil
    }

    /// 按写法排出条目：标题（名称字段）和标题下的段落。模板没给说明留位置时，说明接在日期那一行。
    public static func entryLines(_ format: EntryFormat, name: String, start: String, end: String, detail: String) -> (name: String, paragraphs: [String]) {
        let start = normalizeDate(start, format.date), end = normalizeDate(end, format.date)
        let values = ["name": name.trimmingCharacters(in: .whitespaces),
                      "date": !start.isEmpty && !end.isEmpty ? start + format.dash + end : start.isEmpty ? end : start,
                      "detail": detail.trimmingCharacters(in: .whitespaces)]
        var slots = format.lines.map(\.slots)
        if !slots.contains(where: { $0.contains("detail") }) { slots[max(0, slots.firstIndex { $0.contains("date") } ?? 0)].append("detail") }
        let texts = format.lines.indices.map { index in slots[index].compactMap { values[$0].flatMap { $0.isEmpty ? nil : $0 } }.joined(separator: format.lines[index].delimiter) }
        return (texts.first.flatMap { $0.isEmpty ? nil : $0 } ?? values["name"]!, Array(texts.dropFirst()).filter { !$0.isEmpty })
    }

    static func entrySpec(_ lines: (name: String, paragraphs: [String]), bullets: [String] = []) -> JSONValue {
        var spec: [String: JSONValue] = ["name": .string(lines.name)]
        if !lines.paragraphs.isEmpty { spec["paragraphs"] = .array(lines.paragraphs.map(JSONValue.string)) }
        if !bullets.isEmpty { spec["bullets"] = .array(bullets.map(JSONValue.string)) }
        return .object(spec)
    }

    // MARK: 资料：读到的只用来预填

    /// 资料一步最近一次读出来的整份简历（AI 的资料提案，不确认写入）。
    public static func materialsDocument(_ proposals: [JSONValue]) -> JSONValue? {
        proposals.filter { $0.text("proposal_mode") == "guided_fill" && $0["preview"]?.text("step") == "materials" && ($0["data"].map { $0 != .null } ?? false) }
            .max { $0.text("created_at") < $1.text("created_at") }?["data"]
    }

    static let foundLabels = ["set_identity": "基本信息", "education": "教育", "skills": "技能", "work": "实习", "project": "项目",
                              "activity": "校园", "awards": "获奖", "certificates": "证书", "languages": "语言", "profile": "总结"]

    /// 资料读完后的清单行数（“读到了 n 项”）。
    public static func foundRows(_ proposal: JSONValue) -> [(label: String, text: String)] {
        (proposal["preview"]?["changes"]?.items ?? []).compactMap { change in
            let identity = change.text("op") == "set_identity"
            let kind = identity ? "set_identity" : change.text("section")
            let lines = change.text("after").split(separator: "\n").map { $0.replacingOccurrences(of: #"^·\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let text = String((identity ? lines.joined(separator: " · ") : lines.first ?? "").prefix(80))
            return text.isEmpty ? nil : (foundLabels[kind] ?? change.text("label").nilIfBlank ?? kind, text)
        }
    }

    /// 引导对话里属于这一步的最后一条 AI 回复（没读出内容时的说明）。开场消息只用来让 AI 先开口。
    public static func stepQuestion(_ messages: [JSONValue], step: String) -> String? {
        var runSteps: [String: (step: String, kickoff: Bool)] = [:]
        for message in messages where message.text("role") == "user" {
            if let guide = message["guide"], !guide.text("step").isEmpty, !message.text("run_id").isEmpty {
                runSteps[message.text("run_id")] = (guide.text("step"), guide["kickoff"]?.bool ?? false)
            }
        }
        var question: String?
        for message in messages.sorted(by: { ($0["sequence_no"]?.numberValue ?? 0) < ($1["sequence_no"]?.numberValue ?? 0) })
        where message.text("message_type") != "compaction" && runSteps[message.text("run_id")]?.step == step {
            if message.text("role") == "assistant" {
                let text = message.text("content").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { question = text }
            } else if runSteps[message.text("run_id")]?.kickoff != true {
                question = nil
            }
        }
        return question
    }

    // MARK: 求职意向

    public struct JobIntent: Equatable, Sendable {
        public var role = "", cities: [String] = [], type = "campus", graduationYear = ""
        public var yearFromResume = false
        public init() {}
    }

    public static func jobIntent(profile: JSONValue?, document: JSONValue?) -> JobIntent {
        var intent = JobIntent()
        let types = (profile?["employment_types"]?.items ?? []).compactMap(\.stringValue)
        intent.type = types.contains("internship") && types.contains("full_time") ? "any" : types.contains("internship") ? "internship" : "campus"
        let fromProfile = profile?["graduation_year"]?.numberValue.map { String(Int($0)) } ?? ""
        let fromResume = fromProfile.isEmpty ? graduationYearOnPaper(document) : ""
        intent.role = profile?.text("target_role") ?? ""
        intent.cities = (profile?["candidate_cities"]?.items ?? []).compactMap(\.stringValue)
        intent.graduationYear = fromProfile.isEmpty ? fromResume : fromProfile
        intent.yearFromResume = !fromResume.isEmpty
        return intent
    }

    public static func graduationYearOnPaper(_ document: JSONValue?) -> String {
        let education = sections(document).first { $0.text("semantic_kind") == "education" }
        let years = (education?["entries"]?.items ?? []).flatMap { entry -> [Int] in
            let end = readEntry(entry).end
            return (try! NSRegularExpression(pattern: "(19|20)\\d{2}")).matches(in: end, range: NSRange(end.startIndex..., in: end))
                .compactMap { Range($0.range, in: end).flatMap { Int(end[$0]) } }
        }
        return years.max().map(String.init) ?? ""
    }

    public static func jobIntentHeadline(_ intent: JobIntent) -> String {
        let year = intent.graduationYear.trimmingCharacters(in: .whitespaces)
        return [intent.role.trimmingCharacters(in: .whitespaces),
                year.count == 4 && Int(year) != nil ? "\(year) 届" : "",
                intent.cities.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " / ")]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public static func employmentTypes(_ type: String) -> [String] {
        type == "internship" ? ["internship"] : type == "any" ? ["full_time", "internship"] : ["full_time"]
    }

    /// 毕业年份连带的画像字段：只有应届生能填，且工作年限为 0。
    public static func graduationChanges(_ profile: JSONValue, year: Int?) -> [String: JSONValue] {
        guard let year, profile.text("candidate_status") != "experienced", (profile["years_experience"]?.numberValue ?? 0) == 0 else { return [:] }
        return ["graduation_year": .number(Double(year)), "candidate_status": .string("fresh_graduate"), "years_experience": .number(0)]
    }

    /// 画像整体保存：在最新画像上覆盖改动，带版本号（Web `profileUpdate`）。
    public static func profileUpdate(_ profile: JSONValue, _ changes: [String: JSONValue]) -> JSONValue {
        guard case .object(var fields) = profile else { return profile }
        for key in ["lock_version", "created_at", "updated_at", "id", "user_id"] { fields.removeValue(forKey: key) }
        for (key, value) in changes { fields[key] = value }
        fields["base_lock_version"] = profile["lock_version"] ?? .number(1)
        return .object(fields)
    }

    public static func jobIntentChanges(_ intent: JobIntent, latest: JSONValue) -> [String: JSONValue] {
        var seen = Set<String>()
        let cities = intent.cities.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        var changes: [String: JSONValue] = ["target_role": .string(intent.role.trimmingCharacters(in: .whitespaces)),
                                            "candidate_cities": .array(cities.map(JSONValue.string)),
                                            "employment_types": .array(employmentTypes(intent.type).map(JSONValue.string))]
        let year = Int(intent.graduationYear)
        changes.merge(graduationChanges(latest, year: year.flatMap { $0 > 1900 ? $0 : nil })) { $1 }
        return changes
    }

    // MARK: 基本信息

    public struct BasicInfo: Equatable, Sendable { public var name = "", phone = "", email = "", link = ""; public init() {} }

    public static func basicInfo(_ document: JSONValue?, personal: [String: String], samples: Set<String>) -> BasicInfo {
        let identity = document?["identity"]
        func own(_ node: JSONValue?) -> String {
            guard let node, node != .null, !samples.contains(node.text("node_id")) else { return "" }
            return (node["value"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        }
        func contact(_ kinds: [String]) -> String { own((identity?["contacts"]?.items ?? []).first { kinds.contains($0.text("contact_kind")) }) }
        var info = BasicInfo()
        info.name = own(identity?["name"]).nilIfBlank ?? personal["name"] ?? ""
        info.phone = contact(["phone"]).nilIfBlank ?? personal["phone"] ?? ""
        info.email = contact(["email"]).nilIfBlank ?? personal["email"] ?? ""
        info.link = contact(["github", "website"]).nilIfBlank ?? personal["github"] ?? personal["website"] ?? ""
        return info
    }

    /// 姓名必填，手机和邮箱至少一项。
    public static func basicInfoReady(_ info: BasicInfo) -> Bool {
        !info.name.trimmed.isEmpty && (!info.phone.trimmed.isEmpty || !info.email.trimmed.isEmpty)
    }

    static func basicContacts(_ info: BasicInfo) -> [(kind: String, value: String)] {
        let link = info.link.trimmed
        return [("phone", info.phone.trimmed), ("email", info.email.trimmed),
                (link.range(of: "github\\.com", options: [.regularExpression, .caseInsensitive]) != nil ? "github" : "website", link)]
            .filter { !$0.1.isEmpty }.map { (kind: $0.0, value: $0.1) }
    }

    public static func basicInfoOperations(_ info: BasicInfo) -> [JSONValue] {
        var op: [String: JSONValue] = ["op": .string("set_identity")]
        if !info.name.trimmed.isEmpty { op["name"] = .string(info.name.trimmed) }
        let contacts = basicContacts(info)
        if !contacts.isEmpty { op["contacts"] = .array(contacts.map { .object(["kind": .string($0.kind), "value": .string($0.value)]) }) }
        return [.object(op)]
    }

    public static func basicInfoCareerChanges(_ info: BasicInfo) -> [String: String] {
        var changes: [String: String] = [:]
        if !info.name.trimmed.isEmpty { changes["name"] = String(info.name.trimmed.prefix(60)) }
        for contact in basicContacts(info) { changes[contact.kind] = String(contact.value.prefix(300)) }
        return changes
    }

    // MARK: 教育

    public static let degrees = ["专科", "本科", "硕士", "博士"]
    static let levelDegree = ["junior_college": "专科", "bachelor": "本科", "master": "硕士", "doctor": "博士"]
    static let degreeLevels: [(String, String)] = [("博士", "doctor"), ("硕士|研究生", "master"), ("本科|学士", "bachelor"), ("专科|大专", "junior_college")]

    public struct EducationForm: Equatable, Sendable {
        public var entryID: String?
        public var school = "", major = "", degree = "", start = "", end = "", gpa = "", courses = ""
        public init() {}
    }

    public static func education(_ document: JSONValue?, materials: JSONValue?, profile: JSONValue?, samples: Set<String>) -> EducationForm {
        let own = ownEntries(document, kinds: ["education"], samples: samples).first?.entry
        let read = ownEntries(materials, kinds: ["education"], samples: []).first?.entry
        let entry = own ?? read
        let joined = entryBullets(entry).joined(separator: "；")
        var form = EducationForm()
        form.entryID = own?.text("node_id")
        if let match = groups(try! NSRegularExpression(pattern: "GPA[^；;，,]*", options: .caseInsensitive), joined) {
            form.gpa = match[0].replacingOccurrences(of: #"^GPA\s*[：:]?\s*"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmed
        }
        form.courses = groups(try! NSRegularExpression(pattern: "主修(?:课程)?[：:]?\\s*([^；;]+)"), joined)?[1].trimmed ?? ""
        let meta = entry.map(readEntry)
        let head = meta?.detail.split(whereSeparator: { "；;".contains($0) }).first.map(String.init) ?? ""
        let headDegree = groups(degreeWord, head)?[0] ?? ""
        let headMajor = head.replacingOccurrences(of: "专科|大专|本科|学士|硕士|研究生|博士", with: "", options: .regularExpression)
            .split(whereSeparator: { "·｜|/，,".contains($0) }).map { String($0).trimmed }.first { !$0.isEmpty } ?? ""
        let year = profile?["graduation_year"]?.numberValue.map { String(Int($0)) } ?? ""
        form.school = meta?.name.nilIfBlank ?? profile?.text("school") ?? ""
        form.major = fieldText(entry, "major").nilIfBlank ?? headMajor.nilIfBlank ?? profile?.text("major") ?? ""
        let degreeField = fieldText(entry, "degree")
        form.degree = degrees.first { degreeField.contains($0) }
            ?? degrees.first { !headDegree.isEmpty && (headDegree.contains($0) || ($0 == "专科" && headDegree == "大专") || ($0 == "硕士" && headDegree == "研究生")) }
            ?? levelDegree[profile?.text("education_level") ?? ""] ?? ""
        form.start = meta?.start ?? ""
        form.end = meta?.end.nilIfBlank ?? (year.isEmpty ? "" : "\(year).06")
        return form
    }

    public static func educationReady(_ form: EducationForm) -> Bool { !form.school.trimmed.isEmpty && !form.major.trimmed.isEmpty && !form.degree.isEmpty }

    public static func educationOperations(_ form: EducationForm, format: EntryFormat = defaultFormat, title: String? = nil) -> [JSONValue] {
        let extra = [form.gpa.trimmed.isEmpty ? "" : "GPA \(form.gpa.trimmed)", form.courses.trimmed.isEmpty ? "" : "主修课程：\(form.courses.trimmed)"].filter { !$0.isEmpty }.joined(separator: "；")
        let parts = format.degreeFirst ? [form.degree, form.major.trimmed] : [form.major.trimmed, form.degree]
        let head = parts.filter { !$0.isEmpty }.joined(separator: format.joiner)
        let inline = format.inlineExtra && !extra.isEmpty
        let detail = inline ? [head, extra].filter { !$0.isEmpty }.joined(separator: "；") : head
        let entry = entrySpec(entryLines(format, name: form.school, start: form.start, end: form.end, detail: detail), bullets: !extra.isEmpty && !inline ? [extra] : [])
        if let id = form.entryID { return [.object(["op": .string("fill_entry"), "entry_id": .string(id), "entry": entry])] }
        var op: [String: JSONValue] = ["op": .string("write_section"), "semantic_kind": .string("education"), "entries": .array([entry])]
        if let title { op["title"] = .string(title) }
        return [.object(op)]
    }

    public static func educationProfileChanges(_ profile: JSONValue, _ form: EducationForm) -> [String: JSONValue] {
        var changes: [String: JSONValue] = [:]
        if !form.school.trimmed.isEmpty { changes["school"] = .string(form.school.trimmed) }
        if !form.major.trimmed.isEmpty { changes["major"] = .string(form.major.trimmed) }
        if let level = degreeLevels.first(where: { matches($0.0, form.degree) })?.1 { changes["education_level"] = .string(level) }
        let year = groups(try! NSRegularExpression(pattern: "(19|20)\\d{2}"), form.end).flatMap { Int($0[0]) }
        changes.merge(graduationChanges(profile, year: year)) { $1 }
        return changes
    }

    // MARK: 技能

    public static let skillLevels = [("basic", "了解"), ("familiar", "熟悉"), ("proficient", "熟练")]
    static let levelWords = ["了解": "basic", "熟悉": "familiar", "熟练": "proficient", "精通": "proficient", "掌握": "familiar"]

    public static func splitSkillNames(_ text: String) -> [String] {
        text.split(whereSeparator: { "、,，;；/|\n".contains($0) })
            .map { $0.replacingOccurrences(of: #"^[·•\-\s]+"#, with: "", options: .regularExpression).trimmed }
            .filter { !$0.isEmpty && $0.count <= 40 }
    }

    /// 纸面技能栏里已有的技能；写过熟练度的（“熟练：Java、MySQL”）带上原来的等级。
    public static func skillsOnPaper(_ document: JSONValue?) -> [(name: String, level: String?)] {
        guard let section = sections(document).first(where: { $0.text("semantic_kind") == "skills" }) else { return [] }
        var texts: [String: String] = [:]
        nodeTexts(.array([section["entries"] ?? .array([]), section["blocks"] ?? .array([])]), into: &texts)
        // 节点文字按出现顺序读：遍历时记录顺序
        var ordered: [String] = []
        func visit(_ value: JSONValue?) {
            switch value {
            case .array(let items)?: items.forEach(visit)
            case .object(let fields)?:
                if fields["node_id"] != nil { let text = textOf(value); if !text.isEmpty { ordered.append(text) } }
                for key in fields.keys.sorted() where !["runs", "prefix_runs", "source_refs"].contains(key) { visit(fields[key]) }
            default: break
            }
        }
        visit(section["entries"]); visit(section["blocks"])
        var found: [(String, String?)] = []
        func add(_ name: String, _ level: String?) { if !found.contains(where: { $0.0 == name }) { found.append((name, level)) } }
        let verbs: [(String, String)] = [("^(熟练掌握|熟练|精通|掌握)", "proficient"), ("^熟悉", "familiar"), ("^了解", "basic")]
        for line in ordered {
            let numbered = line.replacingOccurrences(of: #"^\s*\d+\s*[.、)）]\s*"#, with: "", options: .regularExpression)
            if let expanded = groups(try! NSRegularExpression(pattern: #"^\s*([^：:]{1,24})[：:]\s*(.*)$"#), numbered),
               let verb = verbs.first(where: { matches($0.0, expanded[2]) })?.1 {
                add(expanded[1].trimmed, verb); continue
            }
            for part in numbered.split(whereSeparator: { "；;".contains($0) }).map(String.init) {
                let labelled = groups(try! NSRegularExpression(pattern: #"^\s*([^：:]{1,24})[：:](.*)$"#), part)
                let label = labelled?[1].trimmed ?? ""
                let level = levelWords[label]
                let text = labelled == nil ? part : (level != nil || !matches("[A-Za-z]", label)) ? labelled![2] : label
                for name in splitSkillNames(text).map({ $0.replacingOccurrences(of: "[。.]+$", with: "", options: .regularExpression) })
                where !name.isEmpty && name.count <= 30 && !name.contains("。") { add(name, level) }
            }
        }
        return found.map { (name: $0.0, level: $0.1) }
    }

    /// 系统补充的知识点（知识目录或模型给的），面试里没答好的排在最前。
    public static func addedPoints(_ lines: [JSONValue]) -> [(line: Int, text: String, weak: Bool)] {
        var points: [(line: Int, text: String, weak: Bool)] = []
        for (index, line) in lines.enumerated() {
            for layer in line["layers"]?.items ?? [] {
                for point in layer["points"]?.items ?? [] where point.text("source") != "user" {
                    points.append((index, point.text("text"), point["weak"]?.bool ?? false))
                }
            }
        }
        return points.filter(\.weak) + points.filter { !$0.weak }
    }

    static let levelWord = ["basic": "了解", "familiar": "熟悉", "proficient": "熟练掌握"]

    /// 一条专业技能排成一行：“方向：熟悉 A、B，熟练掌握 C”，与后端 skills.line_text 一致。
    public static func skillLineText(_ line: JSONValue) -> String {
        let layers = (line["layers"]?.items ?? []).filter { !($0["points"]?.items ?? []).isEmpty }
            .map { layer in (levelWord[layer.text("level")] ?? "") + (layer["points"]?.items ?? []).map { $0.text("text").trimmed }.joined(separator: "、") }
        return "\(line.text("direction").trimmed)：\(layers.joined(separator: "，"))"
    }

    /// 去掉某条里的一个补充点：层空了去掉这一层，条里不剩点了去掉这一条。
    public static func withoutPoint(_ lines: [JSONValue], line target: Int, text: String) -> [JSONValue] {
        lines.enumerated().compactMap { index, line in
            guard index == target, case .object(var fields) = line else { return line }
            let layers = (line["layers"]?.items ?? []).compactMap { layer -> JSONValue? in
                guard case .object(var layerFields) = layer else { return nil }
                let points = (layer["points"]?.items ?? []).filter { $0.text("text") != text }
                guard !points.isEmpty else { return nil }
                layerFields["points"] = .array(points)
                return .object(layerFields)
            }
            guard !layers.isEmpty else { return nil }
            fields["layers"] = .array(layers)
            let next = JSONValue.object(fields)
            fields["text"] = .string(skillLineText(next))
            return .object(fields)
        }
    }

    // MARK: 经历

    public static let experienceKinds = [("intern", "实习", "work"), ("project", "项目", "project"), ("campus", "校园", "activity"), ("work", "工作", "work")]

    public struct ExperienceForm: Equatable, Sendable {
        public var entryID: String?
        public var kind = "intern", name = "", role = "", start = "", end = "", did = "", result = ""
        public init() {}
        public var ready: Bool { !name.trimmed.isEmpty && !did.trimmed.isEmpty }
        public var section: String { experienceKinds.first { $0.0 == kind }?.2 ?? "work" }
        public var kindLabel: String { experienceKinds.first { $0.0 == kind }?.1 ?? "经历" }
        public var summary: String {
            [name.trimmed, role.trimmed, [start.trimmed, end.trimmed].filter { !$0.isEmpty }.joined(separator: " – ")].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        public var meta: String {
            ([kindLabel, role.trimmed, [start.trimmed, end.trimmed].filter { !$0.isEmpty }.joined(separator: " – ")]).filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    static func experienceForm(kind: String, entry: JSONValue, entryID: String?) -> ExperienceForm {
        let meta = readEntry(entry)
        var form = ExperienceForm()
        form.entryID = entryID
        form.kind = kind == "project" ? "project" : kind == "activity" ? "campus" : "intern"
        form.name = meta.name
        form.role = fieldText(entry, "role").nilIfBlank ?? meta.detail
        form.start = meta.start; form.end = meta.end
        var rest = entry
        if case .object(var fields) = entry { fields["blocks"] = .array(Array((entry["blocks"]?.items ?? []).dropFirst(meta.consumed))); rest = .object(fields) }
        form.did = entryBullets(rest).joined(separator: "；")
        return form
    }

    public struct ExperienceItem: Equatable, Sendable, Identifiable { public let id: String; public let status: String; public let form: ExperienceForm }

    /// 经历清单：纸面上写好的、资料里待写的、选了这份简历不用的。
    public static func experienceList(_ document: JSONValue?, materials: JSONValue?, samples: Set<String>, unused: Set<String>) -> [ExperienceItem] {
        let kinds = ["work", "project", "activity"]
        let written = ownEntries(document, kinds: kinds, samples: samples)
            .map { ExperienceItem(id: $0.entry.text("node_id"), status: "written", form: experienceForm(kind: $0.kind, entry: $0.entry, entryID: $0.entry.text("node_id"))) }
        let onPaper = { (form: ExperienceForm) in written.contains { nameCore($0.form.name) == nameCore(form.name) && overlaps($0.form, form) } }
        let read = ownEntries(materials, kinds: kinds, samples: [])
            .map { experienceForm(kind: $0.kind, entry: $0.entry, entryID: nil) }
            .filter { !$0.name.isEmpty && !onPaper($0) }
            .map { ExperienceItem(id: "read:\($0.name):\($0.start)", status: unused.contains($0.name) ? "unused" : "pending", form: $0) }
        return written + read
    }

    public static func nextExperience(_ document: JSONValue?, materials: JSONValue?, unused: Set<String>) -> ExperienceForm {
        experienceList(document, materials: materials, samples: [], unused: unused).first { $0.status == "pending" }?.form ?? ExperienceForm()
    }

    public static func nameCore(_ name: String) -> String {
        var core = name.replacingOccurrences(of: "[\\s()（）·・]", with: "", options: .regularExpression).lowercased()
        var previous = ""
        while previous != core && core.count > 2 {
            previous = core
            core = core.replacingOccurrences(of: "(股份有限公司|有限责任公司|有限公司|集团|股份|科技|信息技术|网络技术|网络|技术|公司)$", with: "", options: .regularExpression)
        }
        return core
    }

    static func month(_ value: String, open: Bool) -> Double? {
        if matches("至今|现在|今", value) { return .infinity }
        guard let match = groups(try! NSRegularExpression(pattern: "(\\d{4})(?:[.\\-/年](\\d{1,2}))?"), value), let year = Double(match[1]) else { return nil }
        return year * 12 + (Double(match[2]) ?? (open ? 12 : 1))
    }

    static func overlaps(_ left: ExperienceForm, _ right: ExperienceForm) -> Bool {
        overlaps(left.start, left.end, right.start, right.end)
    }

    static func overlaps(_ s1: String, _ e1: String, _ s2: String, _ e2: String) -> Bool {
        guard let a1 = month(s1, open: false), let b1 = month(s2, open: false) else { return true }
        let a2 = month(e1, open: true), b2 = month(e2, open: true)
        return a1 <= (b2 ?? b1) && b1 <= (a2 ?? a1)
    }

    /// 简历上和表单是同一段的条目：名称核心相同，且时间有重叠。
    public static func matchingEntry(_ document: JSONValue?, form: ExperienceForm, samples: Set<String>) -> String? {
        let core = nameCore(form.name)
        guard core.count >= 2 else { return nil }
        return ownEntries(document, kinds: ["work", "project", "activity"], samples: samples).first { item in
            let parts = readEntry(item.entry)
            return nameCore(parts.name) == core && overlaps(form.start, form.end, parts.start, parts.end)
        }?.entry.text("node_id")
    }

    // MARK: 收尾：证书与获奖

    public struct HonorsForm: Equatable, Sendable { public var certificates = "", awards = ""; public init() {} }

    static func sectionLines(_ document: JSONValue?, kind: String, samples: Set<String> = []) -> [String] {
        sections(document).filter { $0.text("semantic_kind") == kind && !samples.contains($0.text("node_id")) }.flatMap { section -> [String] in
            let entries = (section["entries"]?.items ?? []).filter { !samples.contains($0.text("node_id")) }
                .map { ([entryName($0)] + entryBullets($0)).joined(separator: " ") }
            let blocks = (section["blocks"]?.items ?? []).filter { !samples.contains($0.text("node_id")) }
                .flatMap { entryBullets(.object(["blocks": .array([$0])])) }
            return entries + blocks
        }.map(\.trimmed).filter { !$0.isEmpty }
    }

    public static func honorsForm(_ document: JSONValue?, materials: JSONValue?, profile: JSONValue?, samples: Set<String>) -> HonorsForm {
        func pick(_ kinds: [String], _ remembered: [String]) -> String {
            let onPaper = kinds.flatMap { sectionLines(document, kind: $0, samples: samples) }
            let lines = onPaper.isEmpty ? kinds.flatMap { sectionLines(materials, kind: $0) } + remembered : onPaper
            var seen = Set<String>()
            return lines.map(\.trimmed).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(12).joined(separator: "\n")
        }
        var form = HonorsForm()
        form.certificates = pick(["certificates", "languages"], (profile?["certifications"]?.items ?? []).compactMap(\.stringValue))
        form.awards = pick(["awards"], (profile?["honors"]?.items ?? []).compactMap(\.stringValue))
        return form
    }

    static func honorLines(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: "\n").map { $0.replacingOccurrences(of: #"^[\s•·\-–—*]+"#, with: "", options: .regularExpression).trimmed }
            .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(12).map { $0 }
    }

    /// 模板只有其中一栏时两样都写进那一栏；都没有或都有时各写一栏。
    public static func honorsOperations(_ form: HonorsForm, templateKinds: Set<String>) -> [JSONValue] {
        let certificates = honorLines(form.certificates), awards = honorLines(form.awards)
        let hasCertificates = templateKinds.contains("certificates"), hasAwards = templateKinds.contains("awards")
        func op(_ kind: String, _ lines: [String]) -> JSONValue {
            .object(["op": .string("replace_section"), "semantic_kind": .string(kind), "bullets": .array(lines.map(JSONValue.string))])
        }
        if hasCertificates != hasAwards {
            let lines = hasAwards ? awards + certificates : certificates + awards
            return lines.isEmpty ? [] : [op(hasAwards ? "awards" : "certificates", lines)]
        }
        return (awards.isEmpty ? [] : [op("awards", awards)]) + (certificates.isEmpty ? [] : [op("certificates", certificates)])
    }

    // MARK: 收尾：记进求职画像与求职资料

    /// 简历里出现、画像里还没有的事实；列表字段只追加，单值字段只填空位。返回合并后的整份画像更新。
    public static func profileWrite(_ document: JSONValue, profile: JSONValue) -> JSONValue? {
        var changes: [String: JSONValue] = [:]
        let list = { (key: String) in (profile[key]?.items ?? []).compactMap(\.stringValue) }
        func empty(_ key: String) -> Bool { (profile[key]?.stringValue ?? "").isEmpty && profile[key]?.numberValue == nil }
        let entries = { (kind: String) in sections(document).filter { $0.text("semantic_kind") == kind }.flatMap { $0["entries"]?.items ?? [] } }
        if let school = entries("education").first {
            let name = entryName(school), major = fieldText(school, "major"), degree = fieldText(school, "degree")
            if !name.isEmpty && empty("school") { changes["school"] = .string(name) }
            if !major.isEmpty && empty("major") { changes["major"] = .string(major) }
            if let level = degreeLevels.first(where: { matches($0.0, degree) })?.1, empty("education_level") { changes["education_level"] = .string(level) }
            if let year = Int(graduationYearOnPaper(document)), profile["graduation_year"]?.numberValue == nil {
                changes.merge(graduationChanges(profile, year: year)) { $1 }
            }
        }
        func append(_ key: String, _ values: [String]) {
            let current = list(key)
            let added = values.filter { !$0.isEmpty && !current.contains($0) }
            guard !added.isEmpty else { return }
            var seen = Set<String>()
            changes[key] = .array((current + added).filter { seen.insert($0).inserted }.prefix(50).map(JSONValue.string))
        }
        append("skills", skillsOnPaper(document).map(\.name))
        append("certifications", sectionLines(document, kind: "certificates"))
        var awardTexts: [String: String] = [:]
        let awardSections = sections(document).filter { $0.text("semantic_kind") == "awards" }
        nodeTexts(.array(awardSections.map { $0["blocks"] ?? .array([]) }), into: &awardTexts)
        append("honors", entries("awards").map { fieldText($0, "name") } + awardTexts.values.map(\.trimmed))
        append("campus_experiences", entries("activity").map { entry in
            [entryName(entry), fieldText(entry, "role").nilIfBlank ?? readEntry(entry).detail].filter { !$0.isEmpty }.joined(separator: " · ")
        })
        return changes.isEmpty ? nil : profileUpdate(profile, changes)
    }

    /// 简历抬头里有、求职资料还空着的联系方式；只填空位。
    public static func careerContactChanges(_ document: JSONValue, personal: [String: String]) -> [String: String] {
        var changes: [String: String] = [:]
        let name = ResumeDocument.value(document["identity"]?["name"]).trimmed
        if !name.isEmpty && (personal["name"] ?? "").isEmpty { changes["name"] = String(name.prefix(60)) }
        let keys = ["phone": "phone", "email": "email", "github": "github", "website": "website"]
        for contact in document["identity"]?["contacts"]?.items ?? [] {
            guard let key = keys[contact.text("contact_kind")] else { continue }
            let value = contact.text("value").trimmed
            if value.isEmpty || !(personal[key] ?? "").isEmpty || changes[key] != nil { continue }
            if key == "website" && !matches("^https?://\\S+$", value) { continue }
            changes[key] = String(value.prefix(300))
        }
        return changes
    }

    public static func careerHasExperience(_ career: JSONValue?) -> Bool {
        (career?["experience"]?["sections"]?.items ?? []).contains { !($0["entries"]?.items ?? []).isEmpty }
    }

    public static func personal(_ career: JSONValue?) -> [String: String] {
        guard case .object(let fields)? = career?["personal"] else { return [:] }
        return fields.compactMapValues(\.stringValue)
    }

    /// 纸面上已经有用户自己的个人简介（不是模板示例）。
    public static func profileWritten(_ document: JSONValue?, samples: Set<String>) -> Bool {
        sections(document).contains { section in
            section.text("semantic_kind") == "profile" && !samples.contains(section.text("node_id"))
                && (section["blocks"]?.items ?? []).contains { !samples.contains($0.text("node_id")) }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfBlank: String? { trimmed.isEmpty ? nil : self }
}
