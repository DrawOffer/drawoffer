import Foundation

/// canonical-resume.v1（`contracts/resume/canonical-resume.schema.json`）的原生辅助函数：读文字、换头像、
/// 保存前按 Web `canonicalV1SourceDispositions` 重算来源处置，删除的节点不留悬空引用。
public enum ResumeDocument {
    public static let entryFields: [(key: String, label: String)] = [
        ("name", "名称"), ("organization", "单位"), ("role", "角色/职位"), ("degree", "学位"), ("college", "学院"), ("major", "专业"),
        ("location", "地点"), ("start_date", "开始时间"), ("end_date", "结束时间"), ("url", "链接"),
    ]
    public static let sectionKinds: [(key: String, label: String)] = [
        ("profile", "个人简介"), ("work", "工作经历"), ("education", "教育经历"), ("project", "项目经历"), ("skills", "专业技能"),
        ("activity", "校园/社会活动"), ("interests", "兴趣爱好"), ("certificates", "证书"), ("awards", "荣誉奖项"), ("languages", "语言能力"), ("custom", "自定义"),
    ]

    public static func newNodeID() -> String {
        "node_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(24)
    }

    // MARK: Text values

    static let plainStyle: JSONValue = .object(["color": .null, "font_size_pt": .null, "highlight_color": .null])

    /// 文本 run 是否为无格式纯文本。
    static func isPlainRun(_ run: JSONValue) -> Bool {
        guard run.text("inline_type") == "text" else { return false }
        let marks = run["marks"]?.items ?? []
        let href = run["href"] ?? .null
        let style = run["style"] ?? .null
        let styleEmpty = style == .null || ["color", "font_size_pt", "highlight_color"].allSatisfy { (style[$0] ?? .null) == .null }
        return marks.isEmpty && href == .null && styleEmpty
    }

    public static func value(_ textValue: JSONValue?) -> String { textValue?["value"]?.stringValue ?? "" }

    // MARK: Paragraph & list item runs

    public static func runsEditable(_ runs: JSONValue?) -> Bool { (runs?.items ?? []).allSatisfy(isPlainRun) }

    public static func runsText(_ runs: JSONValue?) -> String {
        (runs?.items ?? []).map { run in
            switch run.text("inline_type") {
            case "text": run.text("text")
            case "icon": "[\(run.text("name"))]"
            default: "[图片]"
            }
        }.joined()
    }

    public static func plainRuns(_ text: String) -> JSONValue {
        text.isEmpty ? .array([]) : .array([.object([
            "inline_type": .string("text"), "text": .string(String(text.prefix(20_000))), "marks": .array([]), "href": .null, "style": plainStyle,
        ])])
    }

    /// 头像：保留原 node_id 与来源引用，只替换图片地址。
    public static func avatar(_ previous: JSONValue?, src: String, width: Double = 96) -> JSONValue {
        var fields: [String: JSONValue] = ["node_id": .string(newNodeID()), "source_refs": .array([])]
        if let previous, case .object(let existing) = previous { fields = existing }
        fields["media_kind"] = .string("avatar"); fields["src"] = .string(src); fields["alt"] = fields["alt"] ?? .null
        fields["width"] = fields["width"].flatMap { $0 == .null ? nil : $0 } ?? .number(width); fields["width_unit"] = .string("px")
        fields["height_px"] = .null; fields["align"] = .null; fields["system_fallback"] = .bool(false)
        return .object(fields)
    }

    // MARK: Validation & dispositions

    /// 提交前清理：空的列表项与列表移除；联系方式值不能为空；重算来源处置。
    public static func prepareForSave(_ document: JSONValue, previous: JSONValue) -> JSONValue {
        guard case .object(var fields) = document else { return document }
        if case .object(var identity) = fields["identity"] ?? .null {
            identity["contacts"] = .array((identity["contacts"]?.items ?? []).filter { !$0.text("value").trimmingCharacters(in: .whitespaces).isEmpty })
            fields["identity"] = .object(identity)
        }
        fields["sections"] = .array((fields["sections"]?.items ?? []).map(cleanSection))
        var next = JSONValue.object(fields)
        fields["source_dispositions"] = .array(sourceDispositions(previous: previous, next: next))
        next = .object(fields)
        return next
    }

    static func cleanBlocks(_ blocks: JSONValue?) -> JSONValue {
        .array((blocks?.items ?? []).compactMap { block in
            let type = block.text("block_type")
            guard type == "bullet_list" || type == "ordered_list", case .object(var list) = block else { return block }
            let items = (list["items"]?.items ?? []).filter { !runsText($0["runs"]).trimmingCharacters(in: .whitespaces).isEmpty || !runsEditable($0["runs"]) }
            guard !items.isEmpty else { return nil }
            list["items"] = .array(items)
            return .object(list)
        })
    }

    static func cleanSection(_ section: JSONValue) -> JSONValue {
        guard case .object(var fields) = section else { return section }
        fields["blocks"] = cleanBlocks(fields["blocks"])
        fields["entries"] = .array((fields["entries"]?.items ?? []).map { entry in
            guard case .object(var entryFields) = entry else { return entry }
            entryFields["blocks"] = cleanBlocks(entryFields["blocks"])
            return .object(entryFields)
        })
        return .object(fields)
    }

    /// Web `canonicalV1SourceDispositions`：按新文档里仍引用来源的节点重写目标；不再被引用的非 dropped 来源改为 `user_removed`。
    public static func sourceDispositions(previous: JSONValue, next: JSONValue) -> [JSONValue] {
        var targets: [String: [String]] = [:]
        func visit(_ value: JSONValue, key: String?) {
            switch value {
            case .array(let items): items.forEach { visit($0, key: key) }
            case .object(let object):
                if let id = object["node_id"]?.stringValue, id.hasPrefix("node_"), let refs = object["source_refs"]?.items {
                    for source in refs.compactMap(\.stringValue) where !(targets[source]?.contains(id) ?? false) { targets[source, default: []].append(id) }
                }
                for (childKey, child) in object where childKey != "source_dispositions" { visit(child, key: childKey) }
            default: break
            }
        }
        visit(next, key: nil)
        return (previous["source_dispositions"]?.items ?? []).map { disposition in
            guard case .object(var fields) = disposition else { return disposition }
            let outcome = disposition.text("outcome")
            if let found = targets[disposition.text("source_id")], !found.isEmpty {
                fields["outcome"] = .string(outcome == "transformed" ? "transformed" : "mapped")
                fields["target_node_ids"] = .array(found.map(JSONValue.string))
                fields["reason_code"] = outcome == "transformed" ? (disposition["reason_code"] ?? .null) : .null
                return .object(fields)
            }
            if outcome == "dropped" { return disposition }
            fields["outcome"] = .string("dropped"); fields["target_node_ids"] = .array([]); fields["reason_code"] = .string("user_removed")
            return .object(fields)
        }
    }

    public static func saveError(_ error: Error) -> String {
        if case APIError.unauthorized = error { return "登录已失效，请重新登录。修改尚未保存。" }
        guard case APIError.server(let status, let code) = error else { return "网络中断，修改可能尚未保存。请重试保存。" }
        return [
            "RESUME_EDIT_CONFLICT": "简历已在其他地方更新。请重新载入后再修改，当前未保存的内容会丢失。",
            "RESUME_SCHEMA_INVALID": "简历内容不符合格式要求，请检查后重试。",
            "TEMPLATE_COMPOSITION_INVALID": "当前模板无法容纳这些内容，请换一个模板或调整模块。",
            "TEMPLATE_INACTIVE": "这个模板已下线，请换一个模板。",
            "INVALID_RESUME_STYLE": "版式设置超出范围，请调整后重试。",
            "RESUME_WRITE_PENDING": "简历正在被 AI 修改，请稍后再试。",
            "INVALID_RESUME_TITLE": "名称无效，请输入 1–255 个字符且不含换行。",
            "RESUME_TITLE_CONFLICT": "已有同名简历，请换一个名称。",
            "DESKTOP_ROUTE_FORBIDDEN": "当前服务尚未开放桌面端编辑，请更新服务端后重试。",
        ][code] ?? (status == 422 ? "内容有字段超出限制，请检查长度后重试。" : "保存失败（\(code)），请稍后重试。")
    }
}

/// JSON 路径：对象键或数组下标。
public enum JSONPathPart: Hashable, Sendable { case key(String), index(Int) }

extension JSONValue {
    public subscript(path path: [JSONPathPart]) -> JSONValue? {
        var current: JSONValue? = self
        for part in path {
            switch part {
            case .key(let key): current = current?[key]
            case .index(let index):
                guard case .array(let items) = current ?? .null, items.indices.contains(index) else { return nil }
                current = items[index]
            }
        }
        return current
    }

    /// 返回在 path 处写入（nil 表示删除对象键或数组元素）后的新值；中间缺失的对象会被创建。
    public func setting(_ path: [JSONPathPart], to value: JSONValue?) -> JSONValue {
        guard let first = path.first else { return value ?? .null }
        let rest = Array(path.dropFirst())
        switch first {
        case .key(let key):
            var object: [String: JSONValue]
            if case .object(let existing) = self { object = existing } else { object = [:] }
            if rest.isEmpty {
                if let value { object[key] = value } else { object.removeValue(forKey: key) }
            } else {
                object[key] = (object[key] ?? .object([:])).setting(rest, to: value)
            }
            return .object(object)
        case .index(let index):
            guard case .array(var items) = self, items.indices.contains(index) else { return self }
            if rest.isEmpty {
                if let value { items[index] = value } else { items.remove(at: index) }
            } else { items[index] = items[index].setting(rest, to: value) }
            return .array(items)
        }
    }

    /// 在数组 path 末尾追加；path 指向的不是数组时新建数组。
    public func appending(_ path: [JSONPathPart], _ value: JSONValue) -> JSONValue {
        var items = self[path: path]?.items ?? []
        items.append(value)
        return setting(path, to: .array(items))
    }

    /// 交换数组 path 中两个元素。
    public func moving(_ path: [JSONPathPart], from: Int, to: Int) -> JSONValue {
        var items = self[path: path]?.items ?? []
        guard items.indices.contains(from), items.indices.contains(to) else { return self }
        items.swapAt(from, to)
        return setting(path, to: .array(items))
    }
}
