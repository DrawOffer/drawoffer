import DrawOfferCore
import SwiftUI

/// 求职画像（macOS 稿 01 页「03 · 求职画像」03.02 / 03.03 / 03.04，对齐 Web `account/CareerProfilePage.tsx`）：
/// 账号唯一的一份，网申插件和 AI 都只用它。打开就是两列输入框，离开输入框自动保存；
/// 教育、实习、工作、项目各是一个分区，标题右边蓝字「＋ 添加」原地展开一段表单（不弹框）；不做「从简历导入」。
struct CareerProfileView: View {
    @Environment(SessionStore.self) private var session
    let back: () -> Void
    @State private var profile: JSONValue?
    @State private var intent: JSONValue?
    @State private var failed = false
    @State private var saving = 0
    @State private var toast: AccountToast?
    /// 刚点「添加」还没填的段只在页面上，第一次填写才保存，免得留下空段被插件填进表单。
    @State private var drafts: [AccountProfileDraft] = []
    @State private var queue: Task<Void, Never>?

    private var experience: JSONValue { profile?["experience"].flatMap { $0 == .null ? nil : $0 } ?? AccountProfileModel.emptyExperience }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    crumb
                    if failed && profile == nil {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("暂时无法读取求职画像").font(V3.serif(18)).foregroundStyle(V3.txt)
                            Button("重新加载") { Task { await load() } }.buttonStyle(V3ButtonStyle(kind: .ghost))
                        }.padding(.top, 40)
                    } else if let profile, let intent {
                        head(profile)
                        sections(profile, intent)
                    } else {
                        V3Loading("正在加载求职画像…").font(V3.sans(13)).frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .frame(width: min(900, max(480, geometry.size.width - 64)), alignment: .leading)
                .padding(.top, 33).padding(.bottom, 72).frame(maxWidth: .infinity)
            }.scrollIndicators(.never)
        }
        .background(Color.white)
        .overlay(alignment: .top) { if let toast { AccountToastView(toast: toast) { self.toast = nil } } }
        .task { await load() }
    }

    /// 从账号设置进来时左上角返回（13 号 fnt 小字）。
    private var crumb: some View {
        Button(action: back) {
            HStack(spacing: 5) { Image(systemName: "chevron.left").font(.system(size: 10, weight: .medium)); Text("账号设置") }.contentShape(Rectangle())
        }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.fnt).frame(height: 18).accessibilityLabel("返回账号设置")
    }

    /// 03.02 页头：宋体 28 标题、14 sub 说明；右侧「网申常问的还差 N 项 · 已保存」（N 项 #C9711C）；下边线距说明 30。
    private func head(_ profile: JSONValue) -> some View {
        let missing = CareerProfileRules.missing(profile)
        return HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("求职画像").font(V3.serif(28)).foregroundStyle(V3.txt).frame(height: 40)
                Text("网申插件和 AI 都用这一份。直接填写，离开输入框就自动保存。").font(V3.sans(14)).foregroundStyle(V3.sub).frame(height: 17)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                if missing.isEmpty { Text("网申常问的信息都填好了").foregroundStyle(V3.fnt) }
                else {
                    Text("网申常问的还差 ").foregroundStyle(V3.fnt)
                    Text("\(missing.count) 项").foregroundStyle(Color(hex: 0xC9711C)).fontWeight(.medium)
                }
                Text(saving > 0 ? " · 保存中…" : " · 已保存").foregroundStyle(Color(hex: 0x96968F))
            }.font(V3.sans(13)).fixedSize().frame(height: 17)
        }
        .padding(.top, 14).padding(.bottom, 30)
        .overlay(alignment: .bottom) { AccountHairline() }
    }

    @ViewBuilder private func sections(_ profile: JSONValue, _ intent: JSONValue) -> some View {
        AccountProfileSection(title: "基本信息") {
            AccountProfileGrid(cells: AccountProfileModel.basic.map { row in AccountProfileGrid.Cell(id: row.key) { personalField(row, profile) } })
        }
        AccountProfileSection(title: "身份与证件", desc: "网申常问，填一次所有公司通用。证件号加密保存，页面只显示首尾几位。") {
            AccountProfileGrid(cells: [
                AccountProfileGrid.Cell(id: "id_type") {
                    AccountProfileField(label: "证件类型") {
                        AccountProfileSelect(label: "证件类型", value: profile.text("id_type"), options: (profile["catalog"]?["id_types"]?.items ?? []).compactMap(\.stringValue)) { next in
                            save { _ in ["id_type": .string(next)] }
                        }
                    }
                },
                AccountProfileGrid.Cell(id: "id_number") { idNumber(profile) },
            ] + AccountProfileModel.identity.map { row in AccountProfileGrid.Cell(id: row.key) { personalField(row, profile) } })
        }
        AccountProfileSection(title: "求职意向", desc: "AI 出题和网申都会用。") { intentFields(intent) }
        AccountProfileExperience(experience: experience, drafts: $drafts,
                                 change: { id, update, create in save { current in ["experience": AccountProfileModel.applyEntry(AccountProfileModel.experience(of: current), id, update, create)] } },
                                 remove: { id in save { current in ["experience": AccountProfileModel.removeEntry(AccountProfileModel.experience(of: current), id)] } },
                                 invalid: { toast = .init(kind: .error, title: "没有保存", message: $0) })
        AccountProfileSection(title: "技能", desc: "写简历、模拟面试都按熟练度来，点一下切换熟练度。", last: true) {
            AccountProfileSkills(skills: CareerProfileRules.skills(experience)) { skills in
                save { current in
                    var next = AccountProfileModel.experience(of: current)
                    if case .object(var fields) = next {
                        fields["skills"] = .array(skills.map { .object(["name": .string($0.name), "level": $0.level.map(JSONValue.string) ?? .null]) })
                        next = .object(fields)
                    }
                    return ["experience": next]
                }
            }
        }
    }

    private func personalField(_ row: AccountProfileModel.Personal, _ profile: JSONValue) -> some View {
        let value = profile["personal"]?.text(row.key) ?? ""
        let title = profile["catalog"]?["fields"]?["profile.personal.\(row.key)"]?.text("label").nonEmptyValue ?? row.label
        let asked = CareerProfileRules.common.contains(row.key) && value.isEmpty
        return AccountProfileField(label: title, asked: asked) {
            if row.date { AccountBirthDateField(label: title, value: value) { savePersonal(row.key, $0) } }
            else if let options = row.options { AccountProfileSelect(label: title, value: value, options: options) { savePersonal(row.key, $0) } }
            else { AccountProfileInput(label: title, value: value, placeholder: row.placeholder) { savePersonal(row.key, $0) } }
        }
    }

    /// 证件号码：只写不读；已有时占位显示脱敏号码，标签右侧可删除。
    private func idNumber(_ profile: JSONValue) -> some View {
        let has = profile["has_id_number"]?.bool == true
        return AccountProfileField(label: "证件号码", asked: !has, action: has ? ("删除", { save { _ in ["id_number": .string("")] } }) : nil) {
            AccountProfileInput(label: "证件号码", value: "", placeholder: has ? profile.text("id_number_masked") : "证件号码", clearAfterCommit: true) { number in
                let trimmed = number.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                let type = profile.text("id_type").nonEmptyValue ?? (profile["catalog"]?["id_types"]?.items.first?.stringValue ?? "")
                save { _ in ["id_type": .string(type), "id_number": .string(trimmed)] }
            }
        }
    }

    /// 求职意向：期望城市（顿号分开）、期望薪资（K / 月，最低–最高）、工作性质。
    private func intentFields(_ intent: JSONValue) -> some View {
        let toK = { (key: String) -> String in intent[key]?.numberValue.map { String(Int(($0 / 1000).rounded())) } ?? "" }
        let types = (intent["employment_types"]?.items ?? []).compactMap(\.stringValue)
        let kind = types.count >= 2 ? "both" : types.first ?? ""
        let kinds = [("internship", "实习"), ("full_time", "全职"), ("both", "实习和全职都可以")]
        let cities = (intent["candidate_cities"]?.items ?? []).compactMap(\.stringValue).joined(separator: "、")
        return AccountProfileGrid(cells: [
            AccountProfileGrid.Cell(id: "cities") {
                AccountProfileField(label: "期望城市") {
                    AccountProfileInput(label: "期望城市", value: cities, placeholder: "用顿号分开，例如 杭州、上海") { text in
                        let list = text.components(separatedBy: CharacterSet(charactersIn: "、,， ")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        saveIntent(["candidate_cities": .array(Array(list.prefix(20)).map(JSONValue.string))])
                    }
                }
            },
            AccountProfileGrid.Cell(id: "salary") {
                AccountProfileField(label: "期望薪资（K / 月）") {
                    HStack(spacing: 10) {
                        AccountProfileInput(label: "最低", value: toK("salary_min"), placeholder: "最低", digits: true) { saveSalary($0, toK("salary_max")) }
                        Text("–").font(V3.sans(14)).foregroundStyle(V3.fnt)
                        AccountProfileInput(label: "最高", value: toK("salary_max"), placeholder: "最高", digits: true) { saveSalary(toK("salary_min"), $0) }
                    }
                }
            },
            AccountProfileGrid.Cell(id: "kind") {
                AccountProfileField(label: "工作性质") {
                    AccountProfileSelect(label: "工作性质", value: kinds.first { $0.0 == kind }?.1 ?? "", options: kinds.map(\.1)) { label in
                        guard let picked = kinds.first(where: { $0.1 == label })?.0 else { return }
                        saveIntent(["employment_types": .array((picked == "both" ? ["internship", "full_time"] : [picked]).map(JSONValue.string))])
                    }
                }
            },
        ])
    }

    // MARK: 动作

    private func load() async {
        do {
            async let career = session.api.careerRequest(path: "/api/account/career-profile", method: "GET", query: [:], body: nil)
            async let portrait = session.api.careerRequest(path: "/api/account/user-profile", method: "GET", query: [:], body: nil)
            let (a, b) = try await (career, portrait)
            profile = a; intent = b; failed = false
        } catch { failed = true }
    }

    private func fail(_ error: Error) async {
        var code = ""
        if case APIError.server(_, let value) = error { code = value }
        let messages = ["AUTOFILL_ID_STORAGE_UNAVAILABLE": "证件号码暂时无法保存，请稍后再试。",
                        "USER_PROFILE_VERSION_CONFLICT": "画像在别处改过了，已刷新为最新内容，请再改一次。", "RESUME_NOT_FOUND": "这份简历不存在或已删除。"]
        toast = .init(kind: .error, title: "没有保存", message: messages[code] ?? AccountRequest.errorMessage(error, fallback: "请检查填写内容后重试。"))
        if code == "USER_PROFILE_VERSION_CONFLICT" { await load() }
    }

    /// 连续失焦会各自保存一次：排队依次提交，每次都拿上一次保存后的最新画像（含版本号）算改动。
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            saving += 1
            await work()
            saving -= 1
        }
    }

    private func save(_ change: @escaping @MainActor (JSONValue) -> [String: JSONValue]) {
        enqueue {
            guard let current = profile else { return }
            var body = change(current)
            body["base_lock_version"] = current["lock_version"] ?? .number(1)
            do { profile = try await session.api.careerRequest(path: "/api/account/career-profile", method: "PUT", query: [:], body: .object(body)) }
            catch { await fail(error) }
        }
    }

    private func savePersonal(_ key: String, _ value: String) {
        save { current in
            guard case .object(var personal) = current["personal"] ?? .object([:]) else { return [:] }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { personal.removeValue(forKey: key) }
            else { personal[key] = .string(AccountProfileModel.urlKeys.contains(key) ? AccountProfileModel.withScheme(trimmed) : trimmed) }
            return ["personal": .object(personal)]
        }
    }

    private func saveSalary(_ low: String, _ high: String) {
        let min = Double(low).map { $0 * 1000 }, max = Double(high).map { $0 * 1000 }
        let has = min != nil || max != nil
        let top: Double? = if let max, let min, max < min { min } else { max }
        saveIntent(["salary_min": min.map(JSONValue.number) ?? .null, "salary_max": top.map(JSONValue.number) ?? .null,
                    "salary_currency": has ? .string("CNY") : .null, "salary_period": has ? .string("month") : .null])
    }

    /// 求职意向走 `/api/account/user-profile`：先读最新版本，合并改动后整体写回。
    private func saveIntent(_ change: [String: JSONValue]) {
        enqueue {
            do {
                let latest = try await session.api.careerRequest(path: "/api/account/user-profile", method: "GET", query: [:], body: nil)
                guard case .object(var fields) = latest else { return }
                let version = fields.removeValue(forKey: "lock_version") ?? .number(1)
                fields.removeValue(forKey: "created_at"); fields.removeValue(forKey: "updated_at")
                for (key, value) in change { fields[key] = value }
                fields["base_lock_version"] = version
                intent = try await session.api.careerRequest(path: "/api/account/user-profile", method: "PUT", query: [:], body: .object(fields))
            } catch { await fail(error) }
        }
    }
}

// MARK: - 数据规则

struct AccountProfileDraft: Equatable { let id: String; let group: String }

/// 一段经历的改动：字段、描述、网申补充；nil 表示不改这一项。
struct AccountProfileEntryChange { var fields: [String: JSONValue]?; var description: String?; var supplement: [String: JSONValue]? }

/// 求职画像的输入项与经历改写（对齐 Web `CareerProfilePage.tsx` 的 ENTRY_INPUTS / applyEntryChange / removeEntry）。
enum AccountProfileModel {
    struct Personal { let key: String; let label: String; var options: [String]? = nil; var placeholder: String? = nil; var date = false }
    static let basic = [
        Personal(key: "name", label: "姓名"), Personal(key: "gender", label: "性别", options: ["男", "女", "其他", "不愿透露"]),
        Personal(key: "birth_date", label: "出生日期", date: true), Personal(key: "phone", label: "手机号"),
        Personal(key: "email", label: "邮箱"), Personal(key: "github", label: "GitHub", placeholder: "主页地址或用户名"),
        Personal(key: "website", label: "个人网站", placeholder: "主页地址"), Personal(key: "portfolio_url", label: "作品链接", placeholder: "作品集或网盘链接"),
    ]
    static let identity = [
        Personal(key: "ethnicity", label: "民族", placeholder: "例如 汉族"),
        Personal(key: "political_status", label: "政治面貌", options: ["中共党员", "中共预备党员", "共青团员", "群众", "其他"]),
        Personal(key: "native_place", label: "籍贯", placeholder: "例如 江苏南京"), Personal(key: "home_city", label: "家庭所在城市"),
    ]
    static let urlKeys: Set<String> = ["website", "portfolio_url"]
    static func withScheme(_ value: String) -> String {
        if let range = value.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) { return value.replacingCharacters(in: range, with: value[range].lowercased()) }
        return "https://" + value
    }

    struct Input { let label: String; var field: String? = nil; var supplement: String? = nil; var placeholder: String? = nil
        var options: [String]? = nil; var wide = false; var gpa = false; var month: String? = nil }
    static let inputs: [String: [Input]] = [
        "education": [
            Input(label: "学校", field: "学校"), Input(label: "学院", field: "学院"),
            Input(label: "学历学位", field: "学历学位", options: ["博士", "硕士", "本科", "大专", "高中"]), Input(label: "专业", field: "专业"),
            Input(label: "开始时间", field: "开始时间", month: "start"), Input(label: "结束时间", field: "结束时间", month: "end"),
            Input(label: "GPA", supplement: "gpa", placeholder: "例如 3.6 / 4.0", gpa: true), Input(label: "专业排名", supplement: "major_rank", placeholder: "例如 5 / 120"),
        ],
        "work": [
            Input(label: "公司名称", field: "单位"), Input(label: "部门", field: "部门", supplement: "department", placeholder: "例如 交易平台部"),
            Input(label: "职位", field: "职位"), Input(label: "城市", field: "地点"),
            Input(label: "开始时间", field: "开始时间", month: "start"), Input(label: "结束时间", field: "结束时间", month: "end"),
        ],
        "project": [
            Input(label: "项目名称", field: "项目名称"), Input(label: "角色", field: "角色"),
            Input(label: "开始时间", field: "开始时间", month: "start"), Input(label: "结束时间", field: "结束时间", month: "end"),
            Input(label: "链接", field: "链接", placeholder: "作品或代码地址", wide: true),
        ],
        "other": [
            Input(label: "名称", field: "名称"), Input(label: "角色", field: "角色"),
            Input(label: "开始时间", field: "开始时间", month: "start"), Input(label: "结束时间", field: "结束时间", month: "end"),
        ],
    ]
    static let descriptionLabels = ["education": "在校经历", "work": "工作内容", "project": "项目描述", "other": "描述"]
    static let groupLabels: [(String, String)] = [("education", "教育经历"), ("internship", "实习经历"), ("work", "工作经历"), ("project", "项目经历"), ("campus", "校园经历"), ("other", "奖项与证书")]
    static let groupDescriptions = [
        "education": "从最高学历填起，网申插件按这里填学校、专业和在校时间。", "internship": "每段实习单独一份，网申插件逐段填表。",
        "work": "全职工作经历，应届生可以先空着。", "project": "课程、比赛、个人项目都可以，写清楚你负责的部分和结果。",
    ]
    static let emptyExperience: JSONValue = .object(["schema_version": .number(1), "extra_basics": .object([:]), "sections": .array([]),
                                                     "supplements": .object([:]), "records": .object([:]), "skills": .array([])])

    static func experience(of profile: JSONValue) -> JSONValue {
        guard let value = profile["experience"], value != .null else { return emptyExperience }
        return value
    }

    static func newID() -> String { "e_" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(UUID().uuidString.lowercased().prefix(6)) }

    struct Item { let entry: JSONValue; let kind: String; let draft: Bool; var id: String { entry.text("id") } }
    struct Group { let key: String; let label: String; let addable: Bool; var items: [Item] }

    static func groups(_ experience: JSONValue, drafts: [AccountProfileDraft]) -> [Group] {
        var result = groupLabels.map { Group(key: $0.0, label: $0.1, addable: !["campus", "other"].contains($0.0), items: []) }
        for section in experience["sections"]?.items ?? [] {
            let raw = section.text("kind")
            if CareerProfileRules.textKinds.contains(raw) { continue }
            let kind = CareerProfileRules.entryKind(raw)
            for entry in section["entries"]?.items ?? [] {
                let key = kind == "work" ? (entry["intern"]?.bool == true ? "internship" : "work") : raw == "activity" ? "campus" : kind
                if let index = result.firstIndex(where: { $0.key == key }) { result[index].items.append(Item(entry: entry, kind: kind, draft: false)) }
            }
        }
        for draft in drafts {
            let kind = ["internship", "work"].contains(draft.group) ? "work" : CareerProfileRules.entryKind(draft.group)
            let entry: JSONValue = .object(["id": .string(draft.id), "fields": .object([:]), "description": .string(""), "ambiguous": .array([]), "intern": .bool(draft.group == "internship")])
            if let index = result.firstIndex(where: { $0.key == draft.group }) { result[index].items.append(Item(entry: entry, kind: kind, draft: true)) }
        }
        return result.filter { $0.addable || !$0.items.isEmpty }
    }

    static func savedIDs(_ experience: JSONValue) -> Set<String> {
        Set((experience["sections"]?.items ?? []).flatMap { ($0["entries"]?.items ?? []).map { $0.text("id") } })
    }

    /// 把一段经历的改动写回整份经历；这段还不存在时（刚点了添加），第一次保存才放进对应分组。
    static func applyEntry(_ experience: JSONValue, _ id: String, _ update: (JSONValue, [String: JSONValue]) -> AccountProfileEntryChange?,
                           _ create: (group: String, label: String)?) -> JSONValue {
        guard case .object(var root) = experience else { return experience }
        var sections = root["sections"]?.items ?? []
        let current = sections.flatMap { $0["entries"]?.items ?? [] }.first { $0.text("id") == id }
        if current == nil && create == nil { return experience }
        let intern = create?.group == "internship"
        let base = current ?? .object(["id": .string(id), "fields": .object([:]), "description": .string(""), "ambiguous": .array([]), "intern": .bool(intern)])
        guard case .object(var supplements) = root["supplements"] ?? .object([:]) else { return experience }
        let existing: [String: JSONValue] = if case .object(let value) = supplements[id] ?? .null { value } else { [:] }
        guard let change = update(base, existing) else { return experience }
        if let next = change.supplement {
            if next.isEmpty { supplements.removeValue(forKey: id) } else { supplements[id] = .object(next) }
        }
        guard case .object(var entry) = base else { return experience }
        if let fields = change.fields {
            entry["fields"] = .object(fields)
            entry["ambiguous"] = .array((base["ambiguous"]?.items ?? []).filter { label in (fields[label.stringValue ?? ""]?.stringValue ?? "").isEmpty })
        }
        if let description = change.description { entry["description"] = .string(description) }
        let updated = JSONValue.object(entry)
        if current != nil {
            sections = sections.map { section in
                guard case .object(var value) = section else { return section }
                value["entries"] = .array((section["entries"]?.items ?? []).map { $0.text("id") == id ? updated : $0 })
                return .object(value)
            }
        } else if let create {
            let kind = intern ? "work" : create.group
            let same = sections.indices.filter { sections[$0].text("kind") == kind }
            // 实习和工作都在 work 分组里：优先放进标题对得上的那一组
            let target = (kind == "work" ? same.first { sections[$0].text("title").contains("实习") == intern } : nil) ?? same.first
            if let target, case .object(var value) = sections[target] {
                value["entries"] = .array((sections[target]["entries"]?.items ?? []) + [updated])
                sections[target] = .object(value)
            } else {
                sections.append(.object(["id": .string(""), "kind": .string(kind), "title": .string(create.label), "lines": .array([]), "entries": .array([updated])]))
            }
        }
        root["sections"] = .array(sections)
        root["supplements"] = .object(supplements)
        return .object(root)
    }

    static func removeEntry(_ experience: JSONValue, _ id: String) -> JSONValue {
        guard case .object(var root) = experience else { return experience }
        if case .object(var supplements) = root["supplements"] ?? .null { supplements.removeValue(forKey: id); root["supplements"] = .object(supplements) }
        root["sections"] = .array((root["sections"]?.items ?? []).map { section in
            guard case .object(var value) = section else { return section }
            value["entries"] = .array((section["entries"]?.items ?? []).filter { $0.text("id") != id })
            return .object(value)
        })
        return .object(root)
    }
}

// MARK: - 分区与表单件

/// 分区：标题 16/500，说明 13 fnt（距 9）；右侧可放「＋ 添加」；内容距标题 25 / 距说明 24；上 35、下 32，下边线。
struct AccountProfileSection<Content: View>: View {
    let title: String
    var desc: String? = nil
    var action: (String, () -> Void)? = nil
    var last = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(title).font(V3.sans(16, weight: .medium)).foregroundStyle(V3.txt).frame(height: 19)
                    if let desc { Text(desc).font(V3.sans(13)).foregroundStyle(V3.fnt).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let action {
                    Button(action: action.1) {
                        HStack(spacing: 4) { Image(systemName: "plus").font(.system(size: 10, weight: .medium)); Text("添加") }.contentShape(Rectangle())
                    }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.blue).accessibilityLabel(action.0)
                }
            }
            content().padding(.top, desc == nil ? 25 : 24)
        }
        .padding(.top, 35).padding(.bottom, 32)
        .overlay(alignment: .bottom) { if !last { AccountHairline() } }
    }
}

/// 两列网格：列宽相等、列距 40、行距 18；`wide` 的格子独占一行。
struct AccountProfileGrid: View {
    struct Cell: Identifiable {
        let id: String
        var wide = false
        let view: AnyView
        init<V: View>(id: String, wide: Bool = false, @ViewBuilder _ view: () -> V) { self.id = id; self.wide = wide; self.view = AnyView(view()) }
    }
    let cells: [Cell]

    private var rows: [[Cell]] {
        var rows: [[Cell]] = [], pending: [Cell] = []
        for cell in cells {
            if cell.wide { if !pending.isEmpty { rows.append(pending); pending = [] }; rows.append([cell]) }
            else { pending.append(cell); if pending.count == 2 { rows.append(pending); pending = [] } }
        }
        if !pending.isEmpty { rows.append(pending) }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 40) {
                    ForEach(row) { cell in cell.view.frame(maxWidth: .infinity, alignment: .leading) }
                    if row.count == 1 && !row[0].wide { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }
}

/// 标签在上的字段：14/500 sub 标签（网申常问且没填时 #C9711C），距输入框 10；标签右侧可放灰字动作。
struct AccountProfileField<Control: View>: View {
    let label: String
    var asked = false
    var action: (String, () -> Void)? = nil
    @ViewBuilder var control: () -> Control
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label).font(V3.sans(14, weight: .medium)).foregroundStyle(asked ? Color(hex: 0xC9711C) : V3.sub)
                Spacer(minLength: 0)
                if let action { Button(action.0, action: action.1).buttonStyle(.plain).font(V3.sans(12)).foregroundStyle(Color(hex: 0x96968F)) }
            }.frame(height: 17)
            control()
        }
    }
}

/// 输入框：40 高、白底、圆角 6、#E4E4E0 描边，14 号字、左右 15；离开输入框或回车时内容变了才保存，Esc 还原。
struct AccountProfileInput: View {
    let label: String
    let value: String
    var placeholder: String? = nil
    var digits = false
    /// 证件号这类只写字段：提交后清空。
    var clearAfterCommit = false
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft, prompt: placeholder.map { Text($0).foregroundStyle(V3.fnt2) })
            .textFieldStyle(.plain).font(V3.sans(14)).foregroundStyle(V3.txt).focused($focused)
            .padding(.horizontal, 15).frame(height: 40)
            .background(.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? V3.txt.opacity(0.5) : V3.cl))
            .accessibilityLabel(label)
            .onAppear { draft = value }
            .onChange(of: value) { if !focused { draft = value } }
            .onChange(of: draft) { if digits { let only = draft.filter(\.isNumber); if only != draft { draft = only } } }
            .onChange(of: focused) { if !focused { send() } }
            .onSubmit { focused = false }
            .onExitCommand { draft = value; focused = false }
    }

    private func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != value { commit(draft) }
        if clearAfterCommit { draft = "" }
    }
}

/// 多行输入：96 高，离开时内容变了才保存。
struct AccountProfileTextArea: View {
    let label: String
    let value: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextEditor(text: $draft).font(V3.sans(14)).foregroundStyle(V3.txt).scrollContentBackground(.hidden).focused($focused)
            .padding(.horizontal, 10).padding(.vertical, 10).frame(height: 96)
            .background(.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? V3.txt.opacity(0.5) : V3.cl))
            .accessibilityLabel(label)
            .onAppear { draft = value }
            .onChange(of: value) { if !focused { draft = value } }
            .onChange(of: focused) { if !focused && draft.trimmingCharacters(in: .whitespacesAndNewlines) != value { commit(draft.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    }
}

/// 下拉：外观同输入框，右侧小箭头；选项来自原生菜单。
struct AccountProfileSelect: View {
    let label: String
    let value: String
    let options: [String]
    let change: (String) -> Void
    var body: some View {
        Menu {
            ForEach(value.isEmpty || options.contains(value) ? options : [value] + options, id: \.self) { option in
                Button { if option != value { change(option) } } label: {
                    if option == value { Label(option, systemImage: "checkmark") } else { Text(option) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(value.isEmpty ? "请选择" : value).font(V3.sans(14)).foregroundStyle(value.isEmpty ? V3.fnt2 : V3.txt).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(V3.fnt)
            }
            .padding(.horizontal, 15).frame(height: 40)
            .background(.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(V3.cl))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.plain).accessibilityLabel(label)
    }
}

// MARK: - 经历

/// 教育、实习、工作、项目各一个分区（03.02 / 03.03 / 03.04）；校园经历、奖项这类以前从简历读进来的有内容才显示。
private struct AccountProfileExperience: View {
    let experience: JSONValue
    @Binding var drafts: [AccountProfileDraft]
    let change: (String, @escaping (JSONValue, [String: JSONValue]) -> AccountProfileEntryChange?, (group: String, label: String)?) -> Void
    let remove: (String) -> Void
    let invalid: (String) -> Void

    var body: some View {
        let supplements = experience["supplements"] ?? .null
        ForEach(AccountProfileModel.groups(experience, drafts: drafts), id: \.key) { group in
            AccountProfileSection(title: group.label, desc: AccountProfileModel.groupDescriptions[group.key],
                          action: group.addable ? ("添加\(group.label)", { drafts.append(AccountProfileDraft(id: AccountProfileModel.newID(), group: group.key)) }) : nil) {
                if !group.items.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(zip(group.items.indices, group.items)), id: \.1.id) { index, item in
                            let id = item.entry.text("id")
                            AccountProfileEntryForm(index: index, kind: item.kind, entry: item.entry,
                                            supplement: { if case .object(let value) = supplements[id] ?? .null { return value }; return [:] }(),
                                            invalid: invalid,
                                            change: { update in change(id, update, item.draft ? (group.key, group.label) : nil) },
                                            remove: { if item.draft { drafts.removeAll { $0.id == id } } else { remove(id) } })
                            .padding(.top, index > 0 ? 28 : 0)
                            .overlay(alignment: .top) {
                                if index > 0 { Line().stroke(V3.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(height: 1).offset(y: 0) }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: AccountProfileModel.savedIDs(experience)) { _, saved in drafts.removeAll { saved.contains($0.id) } }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path { var path = Path(); path.move(to: .zero); path.addLine(to: CGPoint(x: rect.width, y: 0)); return path }
    }
}

/// 一段经历：「第 N 段」+ 右侧「删除」（再点一次确认）；下面是两列输入框和描述。
private struct AccountProfileEntryForm: View {
    let index: Int
    let kind: String
    let entry: JSONValue
    let supplement: [String: JSONValue]
    let invalid: (String) -> Void
    let change: (@escaping (JSONValue, [String: JSONValue]) -> AccountProfileEntryChange?) -> Void
    let remove: () -> Void
    @State private var confirming = false

    private var inputs: [AccountProfileModel.Input] {
        let base = AccountProfileModel.inputs[kind] ?? []
        let known = Set(base.compactMap(\.field))
        // 简历里读进来、这里没有专门输入框的项（例如所属单位、导师）也照样能改
        guard case .object(let fields) = entry["fields"] ?? .null else { return base }
        return base + fields.keys.sorted().filter { !known.contains($0) && !(fields[$0]?.stringValue ?? "").isEmpty }.map { AccountProfileModel.Input(label: $0, field: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("第 \(index + 1) 段").font(V3.sans(12)).foregroundStyle(Color(hex: 0x96968F))
                Spacer()
                if confirming {
                    Button("确认删除") { confirming = false; remove() }.buttonStyle(.plain).font(V3.sans(12)).foregroundStyle(V3.red)
                    Button("取消") { confirming = false }.buttonStyle(.plain).font(V3.sans(12)).foregroundStyle(Color(hex: 0x96968F))
                } else {
                    Button("删除") { confirming = true }.buttonStyle(.plain).font(V3.sans(12)).foregroundStyle(Color(hex: 0x96968F))
                }
            }.frame(height: 14).padding(.top, 16)
            AccountProfileGrid(cells: inputs.map { input in AccountProfileGrid.Cell(id: input.label, wide: input.wide) { field(input) } } + description).padding(.top, 21)
        }
    }

    private var description: [AccountProfileGrid.Cell] {
        guard kind != "education" || !entry.text("description").isEmpty else { return [] }
        let label = AccountProfileModel.descriptionLabels[kind] ?? "描述"
        return [AccountProfileGrid.Cell(id: "__description", wide: true) {
            AccountProfileField(label: label) {
                AccountProfileTextArea(label: label, value: entry.text("description")) { next in change { _, _ in AccountProfileEntryChange(description: next) } }
            }
        }]
    }

    private func value(_ input: AccountProfileModel.Input) -> String {
        if input.gpa {
            let gpa = supplement["gpa"]?.stringValue ?? "", scale = supplement["gpa_scale"]?.stringValue ?? ""
            return gpa.isEmpty ? "" : scale.isEmpty ? gpa : "\(gpa) / \(scale)"
        }
        if let key = input.supplement, let value = supplement[key]?.stringValue, !value.isEmpty { return value }
        return input.field.map { entry["fields"]?.text($0) ?? "" } ?? ""
    }

    @ViewBuilder private func field(_ input: AccountProfileModel.Input) -> some View {
        let current = value(input)
        AccountProfileField(label: input.label) {
            if let month = input.month {
                AccountYearMonthField(label: input.label, value: current, allowPresent: month == "end") { commit(input, $0) }
            } else if let options = input.options {
                AccountProfileSelect(label: input.label, value: current, options: options) { commit(input, $0) }
            } else {
                AccountProfileInput(label: input.label, value: current, placeholder: input.placeholder) { commit(input, $0) }
            }
        }
    }

    private func commit(_ input: AccountProfileModel.Input, _ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var gpa: (String, String?)?
        if input.gpa, !value.isEmpty {
            guard let match = value.firstMatch(of: /^(\d{1,9}(?:\.\d{1,4})?)\s*(?:[\/／]\s*(\d{1,9}(?:\.\d{1,4})?))?$/) else { invalid("GPA 写成 3.6 或 3.6 / 4.0。"); return }
            gpa = (String(match.1), match.2.map(String.init))
        }
        change { current, currentSupplement in
            var result = AccountProfileEntryChange()
            if input.gpa {
                var next = currentSupplement
                next.removeValue(forKey: "gpa"); next.removeValue(forKey: "gpa_scale")
                if let gpa { next["gpa"] = .string(gpa.0); if let scale = gpa.1 { next["gpa_scale"] = .string(scale) } }
                result.supplement = next
                return result
            }
            if let key = input.supplement {
                var next = currentSupplement
                if value.isEmpty { next.removeValue(forKey: key) } else { next[key] = .string(value) }
                result.supplement = next
            }
            if let key = input.field, input.supplement == nil || current["fields"]?[key] != nil {
                var fields: [String: JSONValue] = if case .object(let value) = current["fields"] ?? .null { value } else { [:] }
                if value.isEmpty { fields.removeValue(forKey: key) } else { fields[key] = .string(value) }
                result.fields = fields
            }
            return result
        }
    }
}

// MARK: - 技能

/// 技能胶囊：34 高、#E4E4E0 描边；名字 14 + 熟练度 12 灰；点一下切换（了解 → 熟悉 → 熟练 → 未标注），悬停换出 ×；最后一格虚线「＋ 添加技能」。
private struct AccountProfileSkills: View {
    let skills: [(name: String, level: String?)]
    let save: ([(name: String, level: String?)]) -> Void
    @State private var adding: String?
    @State private var hover: String?
    @FocusState private var focused: Bool

    var body: some View {
        AccountProfileFlow(spacing: 8) {
            ForEach(Array(skills.enumerated()), id: \.offset) { _, skill in
                HStack(spacing: 6) {
                    Button { cycle(skill.name) } label: {
                        HStack(spacing: 7) {
                            Text(skill.name).font(V3.sans(14)).foregroundStyle(V3.txt)
                            Text(CareerProfileRules.skillLevels.first { $0.0 == skill.level }?.1 ?? "未标注").font(V3.sans(12)).foregroundStyle(V3.fnt)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help("点一下切换熟练度")
                    if hover == skill.name {
                        Button { save(skills.filter { $0.name != skill.name }) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).foregroundStyle(V3.fnt) }
                            .buttonStyle(.plain).accessibilityLabel("去掉 \(skill.name)")
                    }
                }
                .padding(.horizontal, 13).frame(height: 34)
                .overlay(Capsule().stroke(V3.cl))
                .onHover { hover = $0 ? skill.name : (hover == skill.name ? nil : hover) }
            }
            if let adding {
                TextField("", text: Binding(get: { adding }, set: { self.adding = $0 }), prompt: Text("用顿号分开，回车确定").foregroundStyle(V3.fnt2))
                    .textFieldStyle(.plain).font(V3.sans(14)).focused($focused).padding(.horizontal, 13).frame(width: 220, height: 34)
                    .overlay(Capsule().stroke(V3.txt.opacity(0.5)))
                    .onAppear { focused = true }
                    .onSubmit { add() }
                    .onExitCommand { self.adding = nil }
                    .onChange(of: focused) { if !focused { add() } }
            } else {
                Button { adding = "" } label: {
                    HStack(spacing: 4) { Image(systemName: "plus").font(.system(size: 11)); Text("添加技能") }
                        .font(V3.sans(14)).foregroundStyle(V3.sub).padding(.horizontal, 13).frame(height: 34)
                        .overlay(Capsule().stroke(V3.cl, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))).contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
    }

    private func cycle(_ name: String) {
        let levels = CareerProfileRules.skillLevels.map(\.0)
        save(skills.map { skill -> (name: String, level: String?) in
            guard skill.name == name else { return skill }
            let index = levels.firstIndex(of: skill.level ?? "") ?? -1
            return (skill.name, index == levels.count - 1 ? nil : levels[index + 1])
        })
    }

    private func add() {
        guard let text = adding else { return }
        adding = nil
        let known = Set(skills.map { $0.name.lowercased() })
        var seen = Set<String>()
        let added = text.components(separatedBy: CharacterSet(charactersIn: "、,，;；/\n")).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 60 && !known.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
        if !added.isEmpty { save(Array((skills + added.map { (name: $0, level: String?.some("familiar")) }).prefix(60))) }
    }
}

/// 自动换行的横排（技能胶囊）。
private struct AccountProfileFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing; line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}
