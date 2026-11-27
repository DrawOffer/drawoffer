import Foundation

/// 新建简历引导（Web `workbench/guide/GuideFlow.tsx` + `guideModel.ts` 的移植，Figma 5:10 分区 214:6470 A2）：
/// 独立的六步页——你的情况 · 资料 · 基本信息 · 经历 · 技能与优势 · 成稿。步骤由服务端记录（guide_service.GUIDE_STEPS），
/// 这里负责界面步骤与服务端步骤的对应、各步表单的预填，以及组 `guide/writes` 与各 compose 接口的请求体。
/// 文档都是后端 canonical 简历 JSON（identity / sections / entries / blocks）。
public enum ResumeGuideModel {
    // MARK: 步骤

    public enum Step: String, CaseIterable, Sendable {
        case situation, materials, basics, experience, skills, finish
        public var label: String {
            switch self {
            case .situation: "你的情况"
            case .materials: "资料"
            case .basics: "基本信息"
            case .experience: "经历"
            case .skills: "技能与优势"
            case .finish: "成稿"
            }
        }
        /// 服务端步骤（基本信息一屏写 basics 与 education 两步）。
        public var serverStep: String {
            switch self {
            case .situation: "job_profile"
            case .materials: "materials"
            case .basics: "basics"
            case .experience: "experience"
            case .skills: "skills"
            case .finish: "wrap_up"
            }
        }
    }

    /// 服务端当前步骤 → 界面步骤；wrap_up 前半是“个人优势”（算技能与优势），点“就这样”以后才是成稿。
    public static func step(current: String, finishing: Bool) -> Step {
        switch current {
        case "job_profile": .situation
        case "materials": .materials
        case "basics", "education": .basics
        case "experience": .experience
        case "skills": .skills
        default: finishing ? .finish : .skills
        }
    }

    static func status(_ guide: JSONValue, _ step: String) -> String { guide["steps"]?[step]?.text("status") ?? "pending" }

    /// 顶部进度里能点回去的步：前面的、写过或跳过的；到过成稿以后成稿也能回。
    public static func reached(_ target: Step, current: Step, guide: JSONValue, seenFinish: Bool) -> Bool {
        let all = Step.allCases
        guard let index = all.firstIndex(of: target), let at = all.firstIndex(of: current) else { return false }
        return index < at || status(guide, target.serverStep) != "pending" || (target == .finish && seenFinish)
    }

    /// 往某一步走的下一个动作（Web `reachStep` 的一次循环）：到了返回 nil。
    public static func reachAction(_ guide: JSONValue, target: String) -> (action: String, step: String?)? {
        let current = guide.text("current_step")
        guard current != target else { return nil }
        if current == "job_profile" { return ("confirm_profile", nil) }
        if status(guide, target) != "pending" { return ("goto_step", target) }
        return ("next", nil)
    }

    /// 还没开始写（还在第一步、哪一步都没写过）。
    public static func untouched(_ guide: JSONValue) -> Bool {
        guard guide.text("current_step") == "job_profile", case .object(let steps)? = guide["steps"] else { return false }
        return steps.values.allSatisfy { $0.text("status") == "pending" }
    }

    /// 中途离开再回来：第一步写过就先问“接着上次写？”。
    public static func resuming(_ guide: JSONValue) -> Bool { status(guide, "job_profile") != "pending" }

    public static func sampleIDs(_ guide: JSONValue?) -> Set<String> {
        Set((guide?["samples"]?.items ?? []).map { $0.text("node_id") })
    }

    /// 写入失败的说法（Web `failureText`）。
    public static func failureText(_ code: String) -> String {
        if code.range(of: "CREDIT|INSUFFICIENT|QUOTA", options: .regularExpression) != nil { return "积分不够了，充值后再试。" }
        if code == "RESUME_GUIDE_PORTRAIT_EMPTY" { return "求职画像里还没有能写进简历的内容，直接自己填吧。" }
        if code == "RESUME_EDIT_CONFLICT" || code == "TARGET_STALE" { return "简历刚被改过，请再试一次。" }
        if code.hasSuffix("_INVALID") { return "这次没写好，多说一两句再试。" }
        if code.range(of: "^LLM_(TIMEOUT|UNAVAILABLE|RATE_LIMITED|MODEL_NOT_CONFIGURED)$", options: .regularExpression) != nil {
            return "AI 这会儿没有回应，简历没有改动，过一会儿再试。"
        }
        return "没写上，简历没有改动，请重试。"
    }

    /// 引导里上传的资料统一放进这个资料夹，没有就建一个；一次最多读 10 份。
    public static let folderName = "简历资料"
    public static let maxMaterials = 10
    public static let materialExtensions = ["pdf", "docx", "md", "txt", "png", "jpg", "jpeg", "webp"]

    // MARK: 你的情况

    public enum Stage: String, CaseIterable, Sendable {
        case student, graduate, worked
        public var label: String {
            switch self {
            case .student: "在校"
            case .graduate: "应届"
            case .worked: "已经工作过"
            }
        }
    }

    /// 画像整体保存：在最新画像上覆盖改动，带版本号（Web `profileUpdate`）。
    public static func profileUpdate(_ profile: JSONValue, _ changes: [String: JSONValue]) -> JSONValue {
        guard case .object(var fields) = profile else { return profile }
        for key in ["lock_version", "created_at", "updated_at"] { fields.removeValue(forKey: key) }
        for (key, value) in changes { fields[key] = value }
        fields["base_lock_version"] = profile["lock_version"] ?? .number(1)
        return .object(fields)
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

    /// 一个节点下所有带 node_id 的节点的文字，按出现顺序。
    static func nodeTexts(_ value: JSONValue?) -> [String] {
        var result: [String] = []
        func visit(_ value: JSONValue?) {
            switch value {
            case .array(let items)?: items.forEach(visit)
            case .object(let fields)?:
                if fields["node_id"] != nil { result.append(textOf(value)) }
                for key in fields.keys.sorted() where !["runs", "prefix_runs", "source_refs"].contains(key) { visit(fields[key]) }
            default: break
            }
        }
        visit(value)
        return result
    }

    static func entryBullets(_ entry: JSONValue?, from start: Int = 0) -> [String] {
        (entry?["blocks"]?.items ?? []).dropFirst(start).flatMap { block -> [String] in
            switch block.text("block_type") {
            case "bullet_list", "ordered_list": return (block["items"]?.items ?? []).map { textOf($0) }
            case "paragraph": return [textOf(block)]
            default: return []
            }
        }.map { $0.trimmed }.filter { !$0.isEmpty }
    }

    static func sections(_ document: JSONValue?) -> [JSONValue] { document?["sections"]?.items ?? [] }

    /// 纸面上用户自己的条目（模板示例不算）。
    static func ownEntries(_ document: JSONValue?, kinds: [String], samples: Set<String>) -> [JSONValue] {
        sections(document).filter { kinds.contains($0.text("semantic_kind")) && !samples.contains($0.text("node_id")) }
            .flatMap { $0["entries"]?.items ?? [] }
            .filter { !samples.contains($0.text("node_id")) }
    }

    /// 模板示例里这一类栏目的标题（如“教育背景”），新建这一栏时沿用。
    public static func sectionTitle(_ documents: [JSONValue?], kind: String) -> String? {
        for document in documents {
            if let title = sections(document).first(where: { $0.text("semantic_kind") == kind }).map({ textOf($0["title"]).trimmed }), !title.isEmpty { return title }
        }
        return nil
    }

    public static func entryByID(_ document: JSONValue?, _ id: String?) -> JSONValue? {
        guard let id, !id.isEmpty else { return nil }
        return sections(document).flatMap { $0["entries"]?.items ?? [] }.first { $0.text("node_id") == id }
    }

    // MARK: 读纸面上已有的条目
    // 新写的条目只写字段，标题行由模板按字段画；旧写法的标题是手写文字（“示例大学｜2023.09—2027.06｜电子商务 · 本科”），
    // 或标题下一段说明，或第一行是一排格子。预填表单时从这些文字里读出名称、起止和说明；有字段的以字段为准。

    static let dateRange = try! NSRegularExpression(pattern: #"(\d{4}(?:[.\-/年]\d{1,2}月?)?)(\s*[—–\-~～至到]+\s*)(\d{4}(?:[.\-/年]\d{1,2}月?)?|至今|现在|今)"#)
    static let degreeWord = "专科|大专|本科|学士|硕士|研究生|博士"
    static let segmentDelimiter = try! NSRegularExpression(pattern: #"\s*[｜|]\s*"#)

    static func groups(_ regex: NSRegularExpression, _ text: String) -> [String]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    static func split(_ text: String, by regex: NSRegularExpression) -> [String] {
        var parts: [String] = [], last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            parts.append(String(text[last..<range.lowerBound])); last = range.upperBound
        }
        parts.append(String(text[last...]))
        return parts
    }

    struct EntryParts { var name = "", start = "", end = "", detail = "", tag = ""; var consumed = 0 }

    /// 一格里几项之间的分隔：竖线、换行、全角空格、两边带空格的横线（日期先认出来，不算分隔）。
    static func cellSegments(_ text: String) -> (segments: [String], delimiter: String) {
        let date = groups(dateRange, text)?[0]
        let masked = date.map { text.replacingOccurrences(of: $0, with: "\u{1}") } ?? text
        let patterns = [segmentDelimiter] + [#"\s*\n\s*"#, "\\s*\u{3000}\\s*", #"\s+[-—]\s+"#].map { try! NSRegularExpression(pattern: $0) }
        guard let pattern = patterns.first(where: { groups($0, masked) != nil }) else {
            return ([masked.replacingOccurrences(of: "\u{1}", with: date ?? "").trimmed].filter { !$0.isEmpty }, "")
        }
        let delimiter = groups(pattern, masked)?[0] ?? ""
        return (split(masked, by: pattern).map { $0.replacingOccurrences(of: "\u{1}", with: date ?? "").trimmed }.filter { !$0.isEmpty }, delimiter)
    }

    static func readRowEntry(_ row: JSONValue) -> EntryParts {
        var parts = EntryParts(consumed: 1)
        var dated = false
        for cell in row["cells"]?.items ?? [] {
            let (segments, delimiter) = cellSegments(textOf(cell["blocks"]?.items.first))
            var last: WritableKeyPath<EntryParts, String>?
            for segment in segments {
                if let match = groups(dateRange, segment), !dated {
                    dated = true; parts.start = match[1]; parts.end = match[3]
                } else if parts.name.isEmpty {
                    parts.name = segment
                } else if let key = last {
                    parts[keyPath: key] += delimiter + segment
                } else if parts.detail.isEmpty {
                    parts.detail = segment; last = \.detail
                } else if parts.tag.isEmpty {
                    parts.tag = segment; last = \.tag
                }
            }
        }
        return parts
    }

    static func leadingParagraphs(_ entry: JSONValue) -> [String] {
        var lines: [String] = []
        for block in entry["blocks"]?.items ?? [] {
            guard block.text("block_type") == "paragraph" else { break }
            lines.append(textOf(block).trimmed)
        }
        return lines
    }

    /// 一个条目的名称、起止和说明：有字段的读字段，旧写法从标题和标题下的说明段落里读。
    static func readEntry(_ entry: JSONValue) -> EntryParts {
        let heading = fieldText(entry, "name").nilIfBlank ?? fieldText(entry, "organization")
        if heading.isEmpty, let first = entry["blocks"]?.items.first, first.text("block_type") == "row" { return readRowEntry(first) }
        let texts = [heading] + leadingParagraphs(entry).prefix(2)
        var parts = EntryParts()
        var dated = false
        var previous: [String] = []
        for (index, text) in texts.enumerated() {
            if index > 0 {
                let dateOnly = previous == ["date"]
                if text.isEmpty || !((!dated && groups(dateRange, text) != nil) || (dateOnly && parts.detail.isEmpty)) { break }
            }
            let delimiter = groups(segmentDelimiter, text)?[0] ?? "｜"
            var slots: [String] = []
            for segment in split(text, by: segmentDelimiter).map(\.trimmed).filter({ !$0.isEmpty }) {
                if let match = groups(dateRange, segment), !dated {
                    dated = true; parts.start = match[1]; parts.end = match[3]; slots.append("date")
                } else if index == 0 && parts.name.isEmpty {
                    parts.name = segment; slots.append("name")
                } else if parts.detail.isEmpty {
                    parts.detail = segment; slots.append("detail")
                } else {
                    parts.detail += delimiter + segment
                }
            }
            previous = slots
            if index > 0 { parts.consumed = index }
        }
        if parts.name.isEmpty { parts.name = heading }
        if let start = fieldText(entry, "start_date").nilIfBlank { parts.start = start }
        if let end = fieldText(entry, "end_date").nilIfBlank { parts.end = end }
        return parts
    }

    /// 条目的名称（标题里合写了日期和说明时只取名称）。
    public static func entryName(_ entry: JSONValue?) -> String { entry.map { readEntry($0).name } ?? "" }

    /// 写好的经历只留“名称 + 时间”一行。
    public static func entryTime(_ entry: JSONValue) -> String {
        let parts = readEntry(entry)
        return [parts.start, parts.end].filter { !$0.isEmpty }.joined(separator: " – ")
    }

    // MARK: 基本信息

    public struct BasicInfo: Equatable, Sendable {
        public var name = "", phone = "", email = "", link = ""
        public init(name: String = "", phone: String = "", email: String = "", link: String = "") {
            self.name = name; self.phone = phone; self.email = email; self.link = link
        }
    }

    /// 表单的起始值：纸面上用户自己写的优先（模板示例不算），空的再用求职资料补。
    public static func basicInfo(_ document: JSONValue?, personal: [String: String] = [:], samples: Set<String>) -> BasicInfo {
        let identity = document?["identity"]
        func own(_ node: JSONValue?) -> String {
            guard let node, !samples.contains(node.text("node_id")) else { return "" }
            return node.text("value").trimmed
        }
        func contact(_ kinds: [String]) -> String { own((identity?["contacts"]?.items ?? []).first { kinds.contains($0.text("contact_kind")) }) }
        return BasicInfo(name: own(identity?["name"]).nilIfBlank ?? personal["name"] ?? "",
                         phone: contact(["phone"]).nilIfBlank ?? personal["phone"] ?? "",
                         email: contact(["email"]).nilIfBlank ?? personal["email"] ?? "",
                         link: contact(["github", "website"]).nilIfBlank ?? personal["github"] ?? personal["website"] ?? "")
    }

    /// own：纸面上原来写着的；表单里清空的手机、邮箱从纸面上拿掉。什么都没有时返回空列表。
    public static func basicInfoOperations(_ info: BasicInfo, own: BasicInfo? = nil) -> [JSONValue] {
        let link = info.link.trimmed
        let contacts: [(String, String)] = [("phone", info.phone.trimmed), ("email", info.email.trimmed),
                                            (link.range(of: "github\\.com", options: [.regularExpression, .caseInsensitive]) != nil ? "github" : "website", link)]
            .filter { !$0.1.isEmpty }
        let cleared = [("phone", own?.phone ?? "", info.phone), ("email", own?.email ?? "", info.email)]
            .filter { !$0.1.isEmpty && $0.2.trimmed.isEmpty }.map(\.0)
        let name = info.name.trimmed
        guard !name.isEmpty || !contacts.isEmpty || !cleared.isEmpty else { return [] }
        var op: [String: JSONValue] = ["op": .string("set_identity")]
        if !name.isEmpty { op["name"] = .string(name) }
        if !contacts.isEmpty { op["contacts"] = .array(contacts.map { .object(["kind": .string($0.0), "value": .string($0.1)]) }) }
        if !cleared.isEmpty { op["clear_contacts"] = .array(cleared.map(JSONValue.string)) }
        return [.object(op)]
    }

    // MARK: 教育

    public static let degrees = ["专科", "本科", "硕士", "博士"]
    public static let maxEducations = 8
    static let ordinals = ["一", "二", "三", "四", "五", "六", "七", "八"]

    public static func educationLabel(_ index: Int) -> String { index == 0 ? "教育" : "第\(ordinals[min(index, ordinals.count - 1)])段教育" }

    public struct EducationForm: Equatable, Sendable {
        public var entryID: String?
        public var school = "", major = "", degree = "", start = "", end = "", gpa = "", courses = ""
        public init(entryID: String? = nil, school: String = "", major: String = "", degree: String = "", start: String = "", end: String = "",
                    gpa: String = "", courses: String = "") {
            self.entryID = entryID; self.school = school; self.major = major; self.degree = degree
            self.start = start; self.end = end; self.gpa = gpa; self.courses = courses
        }
    }

    /// 简历上写的学历（“工学硕士”“大专”）对应的选项。
    static func degreeOption(_ text: String) -> String? {
        degrees.first { text.contains($0) } ?? (text.contains("大专") ? "专科" : text.contains("学士") ? "本科" : text.contains("研究生") ? "硕士" : nil)
    }

    static let levelDegree = ["junior_college": "专科", "bachelor": "本科", "master": "硕士", "doctor": "博士"]

    static func educationForm(_ entry: JSONValue?, profile: JSONValue?) -> EducationForm {
        let meta = entry.map(readEntry)
        let lines = (entryBullets(entry) + [meta?.detail ?? "", meta?.tag ?? ""]).joined(separator: "；")
        func capture(_ pattern: String) -> String? { groups(try! NSRegularExpression(pattern: pattern, options: .caseInsensitive), lines)?.dropFirst().first }
        let gpa = fieldText(entry, "gpa").nilIfBlank ?? capture(#"GPA\s*[：:]?\s*([^；;，,]*)"#)?.trimmed ?? ""
        let courses = fieldText(entry, "courses").nilIfBlank ?? capture(#"主修(?:课程)?[：:]?\s*([^；;]+)"#)?.trimmed ?? ""
        let head = meta?.detail.split(whereSeparator: { "；;".contains($0) }).first.map(String.init) ?? ""
        let headDegree = head.range(of: degreeWord, options: .regularExpression).map { String(head[$0]) }
            ?? meta?.tag.range(of: degreeWord, options: .regularExpression).map { String(meta!.tag[$0]) } ?? ""
        let headMajor = head.replacingOccurrences(of: degreeWord, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[（(]\s*[）)]"#, with: "", options: .regularExpression)
            .split(whereSeparator: { "·｜|/，,".contains($0) }).map { String($0).trimmed }
            .first { !$0.isEmpty && !$0.uppercased().hasPrefix("GPA") } ?? ""
        let year = profile?["graduation_year"]?.numberValue.map { String(Int($0)) } ?? ""
        return EducationForm(
            entryID: entry?.text("node_id"),
            school: meta?.name.nilIfBlank ?? profile?.text("school") ?? "",
            major: fieldText(entry, "major").nilIfBlank ?? headMajor.nilIfBlank ?? profile?.text("major") ?? "",
            degree: degreeOption(fieldText(entry, "degree"))
                ?? degrees.first { headDegree.contains($0) || ($0 == "专科" && headDegree == "大专") || ($0 == "硕士" && headDegree == "研究生") }
                ?? levelDegree[profile?.text("education_level") ?? ""] ?? "",
            start: meta?.start ?? "",
            end: meta?.end.nilIfBlank ?? (year.isEmpty ? "" : "\(year).06"),
            gpa: gpa, courses: courses)
    }

    /// 一屏里的几段教育：纸面上写着几段就是几段，没有时给一段（画像里的学校、学历带进来）。
    /// 画像里的学校只有一份：只补第一段，而且得是同一所学校。
    public static func educations(_ document: JSONValue?, profile: JSONValue?, samples: Set<String>) -> [EducationForm] {
        let own = ownEntries(document, kinds: ["education"], samples: samples)
        guard !own.isEmpty else { return [educationForm(nil, profile: profile)] }
        return own.enumerated().map { index, entry in
            let school = profile?.text("school") ?? ""
            let same = school.isEmpty || entryName(entry).isEmpty || nameCore(school) == nameCore(entryName(entry))
            var form = educationForm(entry, profile: index == 0 && same ? profile : nil)
            form.entryID = entry.text("node_id")
            return form
        }
    }

    static func present(_ values: [(String, String)]) -> JSONValue {
        .object(Dictionary(values.map { ($0.0, $0.1.trimmed) }.filter { !$0.1.isEmpty }, uniquingKeysWith: { _, last in last }).mapValues(JSONValue.string))
    }

    /// 表单里没有的标题字段（学院、排名、地点、链接…）照原样带上：写回去是整行标题，不带就被清掉。
    static func otherFields(_ entry: JSONValue?, _ keys: [String]) -> [(String, String)] {
        keys.map { ($0, fieldText(entry, $0)) }.filter { !$0.1.isEmpty }
    }

    /// 一段教育的写入：学校、专业、学历、GPA、课程、起止各是字段，标题怎么排由模板定。
    static func educationEntry(_ form: EducationForm, own: JSONValue?) -> JSONValue {
        let degree = fieldText(own, "degree")
        let fields = present(otherFields(own, ["college", "rank", "location", "url"]) + [
            ("organization", form.school), ("major", form.major), ("gpa", form.gpa), ("courses", form.courses),
            ("degree", !degree.isEmpty && (degreeOption(degree) ?? "") == form.degree ? degree : form.degree),
            ("start_date", form.start), ("end_date", form.end),
        ])
        return .object(["name": .string(form.school.trimmed), "fields": fields])
    }

    /// 写了内容却没写学校的那一段；都写了返回 nil。
    public static func educationMissingSchool(_ forms: [EducationForm]) -> Int? {
        forms.firstIndex { form in
            guard form.school.trimmed.isEmpty else { return false }
            return form.entryID != nil
                ? !(form.major.trimmed + form.degree + form.start.trimmed + form.end.trimmed + form.gpa.trimmed).isEmpty
                : !(form.major.trimmed + form.start.trimmed + form.gpa.trimmed).isEmpty
        }
    }

    /// 几段教育一次写上：纸上已有的各改各的，新加的写进同一栏，去掉的（removed 与清空了整段的）从纸上拿掉。
    public static func educationsOperations(_ forms: [EducationForm], removed: [String], title: String?, document: JSONValue?) -> [JSONValue] {
        let written = forms.filter { !$0.school.trimmed.isEmpty }
        let kept = written.filter { entryByID(document, $0.entryID) != nil }
        let added = written.filter { entryByID(document, $0.entryID) == nil }.map { educationEntry($0, own: nil) }
        let gone = (removed + forms.filter { $0.school.trimmed.isEmpty }.compactMap(\.entryID)).filter { entryByID(document, $0) != nil }
        var operations: [JSONValue] = kept.map { form in
            .object(["op": .string("fill_entry"), "entry_id": .string(form.entryID ?? ""), "entry": educationEntry(form, own: entryByID(document, form.entryID))])
        }
        if !added.isEmpty {
            var op: [String: JSONValue] = ["op": .string("write_section"), "semantic_kind": .string("education"), "entries": .array(added)]
            if let title { op["title"] = .string(title) }
            operations.append(.object(op))
        }
        if !gone.isEmpty { operations.append(.object(["op": .string("remove"), "node_ids": .array(gone.map(JSONValue.string))])) }
        return operations
    }

    // MARK: 经历

    public struct EntryLines: Equatable, Sendable {
        public var tech: String, intro: String
        public init(tech: String, intro: String) { self.tech = tech; self.intro = intro }
    }

    static let techLabel = #"^(技术(?:架构|环境|栈|选型|框架)|(?:开发|运行)环境|(?:所用|使用|主要|核心|相关)技术)\s*[：:]\s*"#
    static let introLabel = #"^((?:工作|职责|岗位|项目)(?:介绍|概述|描述|简介|背景)|公司(?:介绍|简介))\s*[：:]\s*"#

    /// 一段经历的文字行里，把说明行（“技术架构：…”“项目介绍：…”）和要点分开；labels 是它原来的叫法。
    public static func splitEntryLines(_ lines: [String]) -> (tech: String, intro: String, did: String, techLabel: String?, introLabel: String?) {
        var tech = "", intro = "", techName: String?, introName: String?
        var rest: [String] = []
        for line in lines {
            let text = line.trimmed
            if tech.isEmpty, let match = groups(try! NSRegularExpression(pattern: techLabel), text), text.count > match[0].count {
                techName = match[1]; tech = String(text.dropFirst(match[0].count)).trimmed
            } else if intro.isEmpty, let match = groups(try! NSRegularExpression(pattern: introLabel), text), text.count > match[0].count {
                introName = match[1]; intro = String(text.dropFirst(match[0].count)).trimmed
            } else { rest.append(line) }
        }
        return (tech, intro, rest.joined(separator: "\n").trimmed, techName, introName)
    }

    /// 说明行写在简历上的叫法：模板示例里同类经历的叫法，没有就按这一类默认的。
    public static func entryLineLabels(_ sample: JSONValue?, kind: String) -> EntryLines {
        let fallback = EntryLines(tech: "技术架构", intro: kind == "project" ? "项目介绍" : "工作介绍")
        guard let entry = ownEntries(sample, kinds: [kind], samples: []).first else { return fallback }
        let found = splitEntryLines(entryBullets(entry))
        return EntryLines(tech: found.techLabel ?? fallback.tech, intro: found.introLabel ?? fallback.intro)
    }

    public struct Category: Equatable, Sendable {
        public let key: String, label: String
        /// 写进哪一类栏目：work / project / activity
        public let kind: String
        /// 栏名：模板示例里有就用模板的叫法
        public let title: String
        /// 同一类里单独成栏（比赛、兼职志愿和校园经历都是 activity）
        public let own: Bool
        public let group: String
        public let question: String, note: String
        public let name: String, nameHint: String, role: String, roleHint: String
        /// 工作、实习、项目：要点上面还有技术和介绍两行
        public var lines: EntryLines?
    }

    public static func categories(stage: Stage, sample: JSONValue?) -> [Category] {
        let worked = stage == .worked
        var list = [
            Category(key: "work", label: "工作", kind: "work", title: "工作经历", own: true, group: "work", question: "做过哪些工作？",
                     note: "正式工作过的公司，一段一段填，写好的会出现在左边。", name: "公司", nameHint: "比如：某某科技公司", role: "职位", roleHint: "比如：数据分析师"),
            Category(key: "project", label: "项目", kind: "project", title: sectionTitle([sample], kind: "project") ?? "项目经历", own: false, group: "project",
                     question: "做过哪些项目？", note: "课程设计、毕设、科研、个人做的都算。一段一段填，写好的会出现在左边。",
                     name: "项目名称", nameHint: "比如：校园外卖分析", role: "你的角色", roleHint: "比如：负责人"),
            Category(key: "intern", label: "实习", kind: "work", title: worked ? "实习经历" : sectionTitle([sample], kind: "work") ?? "实习经历", own: worked,
                     group: "intern", question: "实习过吗？", note: "不管长短、公司大小都算。一段一段填，写好的会出现在左边。",
                     name: "公司", nameHint: "比如：某某科技公司", role: "岗位", roleHint: "比如：运营实习"),
            Category(key: "contest", label: "比赛", kind: "activity", title: "竞赛经历", own: true, group: "project", question: "参加过比赛吗？",
                     note: "学科竞赛、创新创业、技能大赛都算，没拿奖也能写。", name: "比赛名称", nameHint: "比如：数学建模竞赛", role: "获奖", roleHint: "没有可以空着"),
            Category(key: "campus", label: "校园", kind: "activity", title: sectionTitle([sample], kind: "activity") ?? "校园经历", own: true, group: "work",
                     question: "在学校里做过什么？", note: "社团、学生会、班干部都算。", name: "组织", nameHint: "比如：学院学生会", role: "职务", roleHint: "比如：宣传部部长"),
            Category(key: "parttime", label: "兼职志愿", kind: "activity", title: "兼职与志愿", own: true, group: "work", question: "做过兼职或志愿吗？",
                     note: "兼职、家教、志愿、社会实践都算。", name: "做的什么", nameHint: "比如：社区支教", role: "你的角色", roleHint: "比如：志愿者"),
            Category(key: "portfolio", label: "作品集", kind: "project", title: "", own: false, group: "project", question: "有作品集吗？",
                     note: "设计、摄影、视频、写作、代码都算。贴一个链接，简历上会写成一行作品链接。", name: "", nameHint: "", role: "", roleHint: ""),
        ]
        for index in list.indices {
            if ["work", "intern"].contains(list[index].key) { list[index].lines = entryLineLabels(sample, kind: "work") }
            else if list[index].key == "project" { list[index].lines = entryLineLabels(sample, kind: "project") }
        }
        return worked ? list : list.filter { $0.key != "work" }
    }

    /// 这一类已经在纸上的段（模板示例不算）：单独成栏的按栏名找，其他的取同类里不是单独栏的；栏名对不上的归到这一类的主类。
    public static func categoryEntries(_ document: JSONValue?, _ category: Category, all: [Category], samples: Set<String>) -> [JSONValue] {
        let sameKind = all.filter { $0.kind == category.kind && $0.key != "portfolio" }
        let ownTitles = Set(sameKind.filter(\.own).map(\.title))
        let main = sameKind.first { !$0.own } ?? sameKind.first { $0.key == "campus" || $0.key == "work" } ?? sameKind.first
        return sections(document)
            .filter { $0.text("semantic_kind") == category.kind && !samples.contains($0.text("node_id")) }
            .filter { section in
                let title = textOf(section["title"]).trimmed
                return (category.own && title == category.title) || (category.key == main?.key && !ownTitles.contains(title))
            }
            .flatMap { $0["entries"]?.items ?? [] }
            .filter { !samples.contains($0.text("node_id")) }
    }

    public struct Segment: Equatable, Sendable {
        public var entryID: String?
        public var name = "", role = "", start = "", end = "", did = "", tech = "", intro = ""
        /// 纸上这一段两行说明原来的叫法，改的时候保留
        public var techLabel: String?, introLabel: String?
        public init(entryID: String? = nil) { self.entryID = entryID }

        /// 和另一段比，这几项文字一样（去掉首尾空白）。
        public func same(_ other: Segment, keys: [KeyPath<Segment, String>] = [\.name, \.role, \.start, \.end, \.tech, \.intro, \.did]) -> Bool {
            keys.allSatisfy { self[keyPath: $0].trimmed == other[keyPath: $0].trimmed }
        }
    }

    /// 纸上的一段 → 表单（Web `segmentFromEntry` + `formFromEntry`）。
    public static func segment(_ category: Category, entry: JSONValue) -> Segment {
        let meta = readEntry(entry)
        var segment = Segment(entryID: entry.text("node_id"))
        segment.name = meta.name
        segment.role = fieldText(entry, "role").nilIfBlank ?? meta.tag.nilIfBlank ?? meta.detail
        segment.start = meta.start
        segment.end = meta.end
        let texts = entryBullets(entry, from: meta.consumed)
        if category.lines != nil {
            let lines = splitEntryLines(texts)
            segment.did = lines.did; segment.tech = lines.tech; segment.intro = lines.intro
            segment.techLabel = lines.techLabel; segment.introLabel = lines.introLabel
        } else { segment.did = texts.joined(separator: "\n") }
        return segment
    }

    /// 经历的标题字段：项目写项目名，实习、工作、校园写组织；职位和起止各是字段。
    public static func experienceFields(_ segment: Segment, kind: String, own: JSONValue?) -> JSONValue {
        let unit = kind == "project" && !fieldText(own, "name").isEmpty ? ["organization"] : []
        return present(otherFields(own, ["department", "location", "url"] + unit) + [
            (kind == "project" ? "name" : "organization", segment.name), ("role", segment.role), ("start_date", segment.start), ("end_date", segment.end),
        ])
    }

    /// `guide/experience:compose` 的请求体：表单的标题行和“做了什么”一次写成整段，改已有条目时带 entry_id。
    public static func experienceBody(_ category: Category, segment: Segment, document: JSONValue?) -> JSONValue {
        let own = entryByID(document, segment.entryID)
        var body: [String: JSONValue] = [
            "entry_id": segment.entryID.map(JSONValue.string) ?? .null, "kind": .string(category.kind), "name": .string(segment.name.trimmed),
            "fields": experienceFields(segment, kind: category.kind, own: own),
            "title": segment.entryID == nil ? .string(category.title) : .null, "own_section": .bool(category.own && segment.entryID == nil),
            "role": .string(segment.role.trimmed), "start": .string(segment.start.trimmed), "end": .string(segment.end.trimmed),
            "did": .string(segment.did.split(separator: "\n").map(String.init).filter { !$0.trimmed.isEmpty }.joined(separator: "\n").trimmed),
        ]
        if let lines = category.lines {
            body["lines"] = .array([
                .object(["label": .string(segment.techLabel ?? lines.tech), "text": .string(segment.tech.trimmed)]),
                .object(["label": .string(segment.introLabel ?? lines.intro), "text": .string(segment.intro.trimmed)]),
            ])
        }
        return .object(body)
    }

    /// 把删掉的一段放回现在的简历：回到删之前排在它前面的那段后面；整栏跟着没了的，连栏一起放回原来的位置。
    public static func withEntryBack(_ current: JSONValue, before: JSONValue, entryID: String) -> JSONValue {
        let old = sections(before)
        guard let from = old.firstIndex(where: { ($0["entries"]?.items ?? []).contains { $0.text("node_id") == entryID } }),
              entryByID(current, entryID) == nil, case .object(var document) = current else { return current }
        func place(_ ids: [String], _ earlier: [String]) -> Int {
            guard let anchor = earlier.reversed().first(where: ids.contains), let at = ids.firstIndex(of: anchor) else { return 0 }
            return at + 1
        }
        let source = old[from]
        let sourceEntries = source["entries"]?.items ?? []
        guard let at = sourceEntries.firstIndex(where: { $0.text("node_id") == entryID }) else { return current }
        var list = sections(current)
        if let index = list.firstIndex(where: { $0.text("node_id") == source.text("node_id") }), case .object(var section) = list[index] {
            var entries = section["entries"]?.items ?? []
            entries.insert(sourceEntries[at], at: place(entries.map { $0.text("node_id") }, sourceEntries.prefix(at).map { $0.text("node_id") }))
            section["entries"] = .array(entries)
            list[index] = .object(section)
        } else if case .object(var section) = source {
            section["entries"] = .array([sourceEntries[at]])
            list.insert(.object(section), at: place(list.map { $0.text("node_id") }, old.prefix(from).map { $0.text("node_id") }))
        }
        document["sections"] = .array(list)
        return .object(document)
    }

    static let orgSuffix = "(股份有限公司|有限责任公司|有限公司|集团|股份|科技|信息技术|网络技术|网络|技术|公司)$"

    /// 名称的核心：去掉空格、括号和“有限公司 / 科技”等后缀，用来认出同一家单位。
    public static func nameCore(_ name: String) -> String {
        var core = name.replacingOccurrences(of: #"[\s()（）·・]"#, with: "", options: .regularExpression).lowercased()
        var previous = ""
        while previous != core && core.count > 2 {
            previous = core
            core = core.replacingOccurrences(of: orgSuffix, with: "", options: .regularExpression)
        }
        return core
    }

    // MARK: 技能

    static let levelWords = ["了解": "basic", "熟悉": "familiar", "熟练": "proficient", "精通": "proficient", "掌握": "familiar"]

    public static func splitSkillNames(_ text: String) -> [String] {
        text.split(whereSeparator: { "、,，;；/|\n".contains($0) })
            .map { String($0).replacingOccurrences(of: #"^[·•\-\s]+"#, with: "", options: .regularExpression).trimmed }
            .filter { !$0.isEmpty && $0.count <= 40 }
    }

    /// 纸面技能栏里已有的技能；写过熟练度的（“熟练：Java、MySQL”）带上原来的等级。
    public static func skillsOnPaper(_ document: JSONValue?) -> [(name: String, level: String?)] {
        guard let section = sections(document).first(where: { $0.text("semantic_kind") == "skills" }) else { return [] }
        let lines = nodeTexts(.array([section["entries"] ?? .array([]), section["blocks"] ?? .array([])])).filter { !$0.isEmpty }
        var found: [(String, String?)] = []
        func add(_ name: String, _ level: String?) { if !found.contains(where: { $0.0 == name }) { found.append((name, level)) } }
        let verbs: [(String, String)] = [("^(熟练掌握|熟练|精通|掌握)", "proficient"), ("^熟悉", "familiar"), ("^了解", "basic")]
        for line in lines {
            let numbered = line.replacingOccurrences(of: #"^\s*\d+\s*[.、)）]\s*"#, with: "", options: .regularExpression)
            if let expanded = groups(try! NSRegularExpression(pattern: #"^\s*([^：:]{1,60})[：:]\s*(.*)$"#), numbered),
               let verb = verbs.first(where: { expanded[2].range(of: $0.0, options: .regularExpression) != nil })?.1 {
                for name in expanded[1].split(whereSeparator: { "、,，".contains($0) }).map({ String($0).trimmed }) where !name.isEmpty { add(name, verb) }
                continue
            }
            for part in numbered.split(whereSeparator: { "；;".contains($0) }).map(String.init) {
                let labelled = groups(try! NSRegularExpression(pattern: #"^\s*([^：:]{1,24})[：:](.*)$"#), part)
                let label = labelled?[1].trimmed ?? ""
                let level = levelWords[label]
                let text = labelled == nil ? part : (level != nil || label.range(of: "[A-Za-z]", options: .regularExpression) == nil) ? labelled![2] : label
                for name in splitSkillNames(text).map({ $0.replacingOccurrences(of: "[。.]+$", with: "", options: .regularExpression) })
                where !name.isEmpty && name.count <= 30 && !name.contains("。") { add(name, level) }
            }
        }
        return found.map { (name: $0.0, level: $0.1) }
    }

    static let notSkills: Set<String> = ["p0", "p1", "p99", "qps", "tps", "dau", "mau", "gpa", "cet-4", "cet-6", "it", "ai", "app", "kpi", "okr", "bug", "api", "ui"]

    /// 纸面上自己写的经历里出现的英文技术名，技能一栏没有来源时用它们起草。
    public static func techTermsOnPaper(_ document: JSONValue?, samples: Set<String>) -> [String] {
        let text = ownEntries(document, kinds: ["work", "project", "activity"], samples: samples).flatMap { nodeTexts($0) }.joined(separator: " ")
        let regex = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9.+#-]*[A-Za-z0-9+#]|[A-Za-z]{2,}"#)
        var seen = Set<String>(), terms: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let term = String(text[range]), key = term.lowercased()
            if term.count < 2 || notSkills.contains(key) || term.first?.isNumber == true || !seen.insert(key).inserted { continue }
            terms.append(term)
        }
        return Array(terms.prefix(12))
    }

    /// 去重（忽略大小写和空白），保持顺序。
    public static func uniqueNames(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.map(\.trimmed).filter { !$0.isEmpty && seen.insert($0.lowercased().replacingOccurrences(of: " ", with: "")).inserted }
    }

    /// 一次贴好几个（顿号、逗号隔开）就拆成几个，最多 30 个。
    public static func addingSkills(_ names: [String], _ text: String) -> [String] {
        Array(uniqueNames(names + text.split(whereSeparator: { "、，,；;".contains($0) }).map { String(String($0).trimmed.prefix(40)) }).prefix(30))
    }

    // MARK: 求职画像

    public struct Portrait: Equatable, Sendable {
        public var contacts = false, education = 0, experiences = 0, skills = 0, others = false
        public init() {}
        /// “基本信息、2 段教育、3 段经历、5 项技能”
        public var text: String {
            [contacts ? "基本信息" : "", education > 0 ? "\(education) 段教育" : "", experiences > 0 ? "\(experiences) 段经历" : "",
             skills > 0 ? "\(skills) 项技能" : "", others ? "获奖证书等内容" : ""].filter { !$0.isEmpty }.joined(separator: "、")
        }
    }

    static let formSections = ["网申基础资料", "网申补充资料", "个人基本资料"]

    /// 求职画像里有没有能填进简历的内容（Web `portraitSummary`）：姓名、联系方式、经历、技能、获奖证书、自我评价有一样就算；
    /// 只选过方向或学校不算。没有返回 nil。
    public static func portrait(career: JSONValue?, profile: JSONValue?) -> Portrait? {
        guard let career, case .object = career else { return nil }
        let list = career["experience"]?["sections"]?.items ?? []
        func count(_ kinds: [String]) -> Int { list.filter { kinds.contains($0.text("kind")) }.reduce(0) { $0 + ($1["entries"]?.items.count ?? 0) } }
        let records = ["competition", "club", "cadre", "activity", "research"].reduce(0) { $0 + (career["experience"]?["records"]?[$1]?.items.count ?? 0) }
        let personal = career["personal"]
        var summary = Portrait()
        summary.others = list.contains { section in
            !["education", "work", "project", "activity"].contains(section.text("kind")) && !formSections.contains(section.text("title").trimmed)
                && (!(section["entries"]?.items.isEmpty ?? true) || (section["lines"]?.items ?? []).contains { !($0.stringValue ?? "").trimmed.isEmpty })
        }
            || ["scholarship", "language"].contains { key in (career["experience"]?["records"]?[key]?.items ?? []).contains { !$0["values"].map { $0.text("name") }.map(\.trimmed).isNilOrEmpty } }
            || !(personal?.text("summary").trimmed.isEmpty ?? true) || !(profile?["honors"]?.items.isEmpty ?? true) || !(profile?["certifications"]?.items.isEmpty ?? true)
        summary.contacts = ["name", "phone", "email"].contains { !(personal?.text($0).trimmed.isEmpty ?? true) }
        summary.education = count(["education"])
        summary.experiences = count(["work", "project", "activity"]) + records
        let careerSkills = career["experience"]?["skills"]?.items.count ?? 0
        summary.skills = careerSkills > 0 ? careerSkills : profile?["skills"]?.items.count ?? 0
        return summary.contacts || summary.education > 0 || summary.experiences > 0 || summary.skills > 0 || summary.others ? summary : nil
    }

    // MARK: 个人优势

    /// 纸上用户自己写的个人简介一栏的文字；没有返回 nil。
    public static func ownProfileText(_ document: JSONValue?, samples: Set<String>) -> String? {
        guard let section = sections(document).first(where: { $0.text("semantic_kind") == "profile" && !samples.contains($0.text("node_id")) }) else { return nil }
        return String(nodeTexts(.array([section["entries"] ?? .array([]), section["blocks"] ?? .array([])])).map(\.trimmed).filter { !$0.isEmpty }
            .joined(separator: "\n").prefix(2000))
    }
}

extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

extension String {
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    public var nilIfBlank: String? { trimmed.isEmpty ? nil : self }
}
