import DrawOfferCore
import SwiftUI

/// 求职资料（Web `account/CareerProfilePage.tsx`，Figma 29.20–29.22）：账号唯一的一份，网申插件和 AI 都只用它。
/// 平时是“名称 — 值”的只读列表，点一行就地修改，改完立即保存；经历从一份简历读入，可以切换简历。
struct CareerProfileView: View {
    @Environment(SessionStore.self) private var session
    let back: () -> Void
    @State private var profile: JSONValue?
    @State private var intent: JSONValue?
    @State private var failed = false
    @State private var editing: String?
    @State private var saving = false
    @State private var moreOpen = false
    @State private var switchOpen = false
    @State private var consent: (idType: String, number: String)?
    @State private var toast: AccountToast?

    private var experience: JSONValue? { profile?["experience"].flatMap { $0 == .null ? nil : $0 } }

    var body: some View {
        GeometryReader { geometry in
            let width = min(900, geometry.size.width - 48)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    crumb
                    if failed && profile == nil {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("暂时无法读取求职资料").font(V3.serif(18))
                            Button("重新加载") { Task { await load() } }.buttonStyle(V3ButtonStyle(kind: .ghost))
                        }.padding(.top, 40)
                    } else {
                        head
                        if let profile, let intent { sections(profile, intent) }
                        else { ProgressView("正在加载求职资料…").font(V3.sans(13)).frame(maxWidth: .infinity, minHeight: 200) }
                    }
                }.frame(width: width, alignment: .leading).padding(.top, 51).padding(.bottom, 64).frame(maxWidth: .infinity)
            }.scrollIndicators(.never)
        }
        .background(Color.white)
        .overlay(alignment: .top) { if let toast { AccountToastView(toast: toast) { self.toast = nil } } }
        .task { await load() }
        .sheet(isPresented: $switchOpen) {
            if let profile {
                SwitchResumeSheet(current: profile["experience_resume"]?.display("id").nonEmptyValue, hasExperience: !(experience?["sections"]?.items ?? []).isEmpty,
                                  close: { switchOpen = false }) { resume in await readResume(resume) }
            }
        }
        .sheet(isPresented: Binding(get: { consent != nil }, set: { if !$0 { consent = nil } })) {
            ConsentSheet(version: profile?["catalog"]?.text("consent_version") ?? "", close: { consent = nil }) {
                guard let consent, let profile else { return }
                let ok = await save(["id_type": .string(consent.idType), "id_number": .string(consent.number),
                                     "id_number_consent": .object(["accepted": .bool(true), "version": .string(profile["catalog"]?.text("consent_version") ?? "")])])
                if ok { self.consent = nil }
            }
        }
    }

    /// `BackCrumb`：← 账号 / 求职资料（16px，行高 20）。
    private var crumb: some View {
        HStack(spacing: 12) {
            Button(action: back) { HStack(spacing: 6) { Image(systemName: "arrow.left").font(.system(size: 13)); Text("账号") }.contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("返回账号")
            Text("/").accessibilityHidden(true)
            Text("求职资料").foregroundStyle(V3.txt)
        }.font(V3.sans(16)).foregroundStyle(V3.fnt).frame(height: 20).padding(.bottom, 20)
    }

    /// `.cp-head`：标题与说明在左，“还差 N 项”在右下；下边线距内容 32。
    private var head: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("求职资料").font(V3.serif(28)).foregroundStyle(V3.txt).frame(height: 36)
                Text("网申插件和 AI 都只用这一份。点任意一行就能修改，改完自动保存。").font(V3.sans(14)).foregroundStyle(V3.sub).frame(height: 22)
            }
            Spacer(minLength: 0)
            if let profile {
                let missing = CareerProfileRules.missing(profile)
                if missing.isEmpty { Text("网申常问的信息都填好了").font(V3.sans(12)).foregroundStyle(V3.fnt) }
                else {
                    HStack(spacing: 0) {
                        Text("网申常问的信息 ").foregroundStyle(V3.fnt)
                        Text("还差 \(missing.count) 项").foregroundStyle(V3.orange).fontWeight(.medium)
                        Text(" · ").foregroundStyle(V3.fnt)
                        Button("去补") { editing = missing[0] == "id_number" ? "id" : missing[0] }.buttonStyle(.plain).foregroundStyle(V3.blue).fontWeight(.medium)
                    }.font(V3.sans(12)).fixedSize()
                }
            }
        }.padding(.bottom, 36).overlay(alignment: .bottom) { Rectangle().fill(V3.line).frame(height: 1) }
    }

    @ViewBuilder private func sections(_ profile: JSONValue, _ intent: JSONValue) -> some View {
        section("基本信息") {
            ForEach(Array((CareerProfileRules.basic + CareerProfileRules.links).enumerated()), id: \.offset) { index, row in personal(row, first: index == 0) }
        }
        section("身份与证件", desc: "网申常问，填一次所有公司通用") {
            identity(profile)
            ForEach(CareerProfileRules.identity, id: \.key) { personal($0, first: false) }
        }
        section("求职意向", desc: "AI 出题和网申都会用") { IntentLines(intent: intent, editing: $editing, saving: saving) { change in Task { await saveIntent(change) } } }
        let sections = experience?["sections"]?.items ?? []
        let resumeTitle = profile["experience_resume"].flatMap { $0 == .null ? nil : $0 }.map { $0.text("title").nonEmptyValue ?? "已删除的简历" }
        section("经历", desc: resumeTitle.map { "读自《\($0)》，改简历不会自动同步。" } ?? "从一份简历读进来，读进来后可以直接改。",
                action: (sections.isEmpty ? "选择简历" : "切换简历", { switchOpen = true })) {
            if let experience, !sections.isEmpty {
                ExperienceList(experience: experience, catalog: profile["catalog"] ?? .null, editing: $editing, saving: saving) { next, nextEditing in
                    Task { await save(["experience": next], nextEditing: nextEditing) }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("还没有读取简历。选一份简历，教育、实习、项目和技能会一起带进来。").font(V3.sans(13)).foregroundStyle(V3.sub)
                    Button("选择简历") { switchOpen = true }.buttonStyle(V3ButtonStyle(kind: .dark))
                }.padding(.vertical, 8)
            }
        }
        section("技能", desc: "写简历、模拟面试都按熟练度来；读简历时一起带进来") {
            SkillLines(skills: CareerProfileRules.skills(experience), editing: editing == "skills", saving: saving, edit: { editing = "skills" }, cancel: { editing = nil }) { skills in
                var base = experience ?? .object(["schema_version": .number(1), "extra_basics": .object([:]), "sections": .array([]), "supplements": .object([:]), "records": .object([:])])
                if case .object(var fields) = base {
                    fields["skills"] = .array(skills.map { .object(["name": .string($0.name), "level": $0.level.map(JSONValue.string) ?? .null]) }); base = .object(fields)
                }
                Task { await save(["experience": base]) }
            }
        }
        let more = CareerProfileRules.moreRows(profile)
        section("更多", desc: "偶尔会问") {
            if !moreOpen {
                Button { moreOpen = true } label: {
                    CPRow(label: "其他 \(more.count) 项", first: true) {
                        Text("身高、体重、微信、紧急联系人… 已填 \(more.filter { !(profile["personal"]?.text($0.key) ?? "").isEmpty }.count) 项").foregroundStyle(V3.sub)
                    } trailing: { CPChevron() }
                }.buttonStyle(CPRowStyle())
            } else {
                ForEach(Array(more.enumerated()), id: \.offset) { index, row in personal(.init(key: row.key, label: row.label, options: nil, hint: nil), first: index == 0) }
            }
        }
    }

    /// `.cp-section`：左 160 栏（标题 14/700，说明 12/19），右侧列表，间距 40；上下 28，下边线。
    private func section<Content: View>(_ title: String, desc: String? = nil, action: (String, () -> Void)? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(V3.sans(14, weight: .bold)).foregroundStyle(V3.txt).frame(height: 22)
                if let desc { Text(desc).font(V3.sans(12)).foregroundStyle(V3.fnt).lineHeight(12, 19).fixedSize(horizontal: false, vertical: true) }
                if let action { Button(action.0, action: action.1).buttonStyle(.plain).font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.blue) }
            }.frame(width: 160, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) { content() }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 28).overlay(alignment: .bottom) { Rectangle().fill(V3.line).frame(height: 1) }
    }

    private func label(_ key: String, _ fallback: String) -> String { profile?["catalog"]?["fields"]?["profile.personal.\(key)"]?.text("label").nonEmptyValue ?? fallback }

    @ViewBuilder private func personal(_ row: CareerProfileRules.Row, first: Bool) -> some View {
        let value = profile?["personal"]?.text(row.key) ?? ""
        let name = label(row.key, row.label)
        if editing == row.key {
            PersonalEditor(label: name, value: value, options: row.options, hint: row.hint, saving: saving, cancel: { editing = nil }) { draft in
                guard case .object(var personal) = profile?["personal"] ?? .object([:]) else { return }
                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { personal.removeValue(forKey: row.key) } else { personal[row.key] = .string(trimmed) }
                Task { await save(["personal": .object(personal)]) }
            }
        } else {
            Button { editing = row.key } label: { CPValueRow(label: name, value: value, first: first) }.buttonStyle(CPRowStyle())
        }
    }

    @ViewBuilder private func identity(_ profile: JSONValue) -> some View {
        let has = profile["has_id_number"]?.bool == true
        if editing == "id" {
            IdentityEditor(profile: profile, saving: saving, cancel: { editing = nil }, remove: { Task { await save(["id_number": .string("")]) } }) { type, number in
                consent = (type, number)
            }
        } else {
            Button { editing = "id" } label: {
                CPRow(label: "证件", first: true) {
                    if has {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(V3.fnt); Text("\(profile.text("id_type")) · \(profile.text("id_number_masked"))") }
                            Text("加密保存，只在网申时填进表单，不发给 AI").font(V3.sans(11.5)).foregroundStyle(V3.fnt2)
                        }
                    } else { Text("未填").foregroundStyle(V3.orange) }
                } trailing: { if has { CPChevron() } else { CPFill() } }
            }.buttonStyle(CPRowStyle())
        }
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
        let messages = ["AUTOFILL_ID_CONSENT_REQUIRED": "保存证件号码前需要你单独同意。", "AUTOFILL_ID_STORAGE_UNAVAILABLE": "证件号码暂时无法保存，请稍后再试。",
                        "USER_PROFILE_VERSION_CONFLICT": "资料在别处改过了，已刷新为最新内容，请再改一次。", "RESUME_NOT_FOUND": "这份简历不存在或已删除。"]
        toast = .init(kind: .error, title: "没有保存", message: messages[code] ?? "请检查填写内容后重试。")
        if code == "USER_PROFILE_VERSION_CONFLICT" { await load() }
    }

    @discardableResult
    private func save(_ change: [String: JSONValue], nextEditing: String? = nil) async -> Bool {
        guard let profile else { return false }
        saving = true
        defer { saving = false }
        var body = change
        body["base_lock_version"] = profile["lock_version"] ?? .number(1)
        do {
            self.profile = try await session.api.careerRequest(path: "/api/account/career-profile", method: "PUT", query: [:], body: .object(body))
            editing = nextEditing
            return true
        } catch { await fail(error); return false }
    }

    private func saveIntent(_ change: [String: JSONValue]) async {
        saving = true
        defer { saving = false }
        do {
            let latest = try await session.api.careerRequest(path: "/api/account/user-profile", method: "GET", query: [:], body: nil)
            guard case .object(var fields) = latest else { return }
            let version = fields.removeValue(forKey: "lock_version") ?? .number(1)
            fields.removeValue(forKey: "created_at"); fields.removeValue(forKey: "updated_at")
            for (key, value) in change { fields[key] = value }
            fields["base_lock_version"] = version
            _ = try await session.api.careerRequest(path: "/api/account/user-profile", method: "PUT", query: [:], body: .object(fields))
            editing = nil
            await load()
        } catch { await fail(error) }
    }

    private func readResume(_ resume: String) async {
        guard let profile else { return }
        do {
            self.profile = try await session.api.careerRequest(path: "/api/account/career-profile/read-resume", method: "POST", query: [:],
                                                               body: .object(["base_lock_version": profile["lock_version"] ?? .number(1), "resume_id": .string(resume)]))
            switchOpen = false
            toast = .init(kind: .success, title: "经历已读入")
        } catch { await fail(error) }
    }
}

// MARK: - 行

/// `.cp-row`：至少 44 高、上下 12，标签 112 宽 13px fnt 色，值 14px；行间 #f2f1ee 细线，悬停时值变蓝。
private struct CPRow<Value: View, Trailing: View>: View {
    let label: String
    let first: Bool
    @ViewBuilder var value: () -> Value
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 16) {
            Text(label).font(V3.sans(13)).foregroundStyle(V3.fnt).lineHeight(13, 22).frame(width: 112, alignment: .leading)
            value().font(V3.sans(14)).foregroundStyle(V3.txt).lineHeight(14, 22).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            trailing()
        }
        .padding(.vertical, 12).frame(minHeight: 46).padding(.top, first ? 0 : 1).contentShape(Rectangle())
        .overlay(alignment: .top) { if !first { Rectangle().fill(Color(hex: 0xF2F1EE)).frame(height: 1) } }
    }
}

private struct CPValueRow: View {
    let label: String
    let value: String
    let first: Bool
    var soft = false
    var body: some View {
        CPRow(label: label, first: first) {
            if value.isEmpty { Text("未填").foregroundStyle(V3.orange) } else { Text(value).foregroundStyle(soft ? V3.sub : V3.txt) }
        } trailing: { if value.isEmpty { CPFill() } else { CPChevron() } }
    }
}

private struct CPChevron: View { var body: some View { Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Color(hex: 0xC2C2BE)) } }
private struct CPFill: View { var body: some View { Text("填写").font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.blue) } }

private struct CPRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.7 : 1) }
}

/// `.cp-link`：12.5/500 蓝色文字按钮；`is-quiet` 为 sub 色常规字重。
private struct CPLink: View {
    let title: String
    var quiet = false
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(title, action: action).buttonStyle(.plain).font(V3.sans(12.5, weight: quiet ? .regular : .medium))
            .foregroundStyle(quiet ? V3.sub : V3.blue).disabled(disabled).opacity(disabled ? 0.5 : 1)
    }
}

/// `.cp-edit`：#f7f7f5 底、圆角 10、内边距 12/14/14 的就地编辑框；底部提示 + 取消 / 完成。
private struct EditBox<Fields: View, Extra: View>: View {
    let label: String
    var hint: String? = nil
    let saving: Bool
    let cancel: () -> Void
    let done: () -> Void
    @ViewBuilder var fields: () -> Fields
    @ViewBuilder var extra: () -> Extra
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Text(label).font(V3.sans(13)).foregroundStyle(V3.fnt).frame(width: 98, alignment: .leading)
                HStack(spacing: 8) { fields() }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 14) {
                if let hint { Text(hint).font(V3.sans(11.5)).foregroundStyle(V3.fnt) }
                Spacer(minLength: 0)
                extra()
                CPLink(title: "取消", quiet: true, disabled: saving, action: cancel)
                CPLink(title: saving ? "保存中…" : "完成", disabled: saving, action: done)
            }
        }.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14).background(Color(hex: 0xF7F7F5), in: RoundedRectangle(cornerRadius: 10)).padding(.vertical, 4)
    }
}

extension EditBox where Extra == EmptyView {
    init(label: String, hint: String? = nil, saving: Bool, cancel: @escaping () -> Void, done: @escaping () -> Void, @ViewBuilder fields: @escaping () -> Fields) {
        self.init(label: label, hint: hint, saving: saving, cancel: cancel, done: done, fields: fields, extra: { EmptyView() })
    }
}

/// 34 高的 `.v3-input`。
private struct CPInput: View {
    @Binding var text: String
    var placeholder = ""
    var width: CGFloat? = nil
    var focus = false
    var submit: () -> Void = {}
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(V3.fnt2)).textFieldStyle(.plain).font(V3.sans(14)).focused($focused)
            .padding(.horizontal, 14).frame(width: width, height: 34).frame(maxWidth: width == nil ? .infinity : nil)
            .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? V3.txt : V3.cl))
            .onSubmit(submit).onAppear { if focus { focused = true } }
    }
}

/// `.v3-seg.cp-seg`：选中项文字变深加粗。
private struct CPSeg: View {
    let options: [(String, String)]
    let active: (String) -> Bool
    let tap: (String) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { option in
                Button { tap(option.0) } label: {
                    Text(option.1).font(V3.sans(14, weight: .medium)).foregroundStyle(active(option.0) ? V3.txt : V3.sub).padding(.horizontal, 12).frame(height: 24)
                        .background { if active(option.0) { RoundedRectangle(cornerRadius: 6).fill(.white).shadow(color: .black.opacity(0.08), radius: 1.5, y: 1) } }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(active(option.0) ? .isSelected : [])
            }
        }.padding(3).frame(height: 30).background(V3.field, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PersonalEditor: View {
    let label: String
    let value: String
    let options: [String]?
    let hint: String?
    let saving: Bool
    let cancel: () -> Void
    let save: (String) -> Void
    @State private var draft = ""
    var body: some View {
        EditBox(label: label, hint: hint, saving: saving, cancel: cancel, done: { save(draft) }) {
            if let options { CPSeg(options: options.map { ($0, $0) }, active: { $0 == draft }) { draft = $0 } }
            else { CPInput(text: $draft, focus: true) { save(draft) }.onExitCommand(perform: cancel) }
        }.onAppear { draft = value }
    }
}

private struct IdentityEditor: View {
    let profile: JSONValue
    let saving: Bool
    let cancel: () -> Void
    let remove: () -> Void
    let submit: (String, String) -> Void
    @State private var type = ""
    @State private var number = ""
    private var types: [String] { (profile["catalog"]?["id_types"]?.items ?? []).compactMap(\.stringValue) }
    var body: some View {
        EditBox(label: "证件", hint: "加密保存，只在网申时填进表单，不发给 AI", saving: saving, cancel: cancel, done: {
            let trimmed = number.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { cancel() } else { submit(type, trimmed) }
        }) {
            Menu { ForEach(types, id: \.self) { item in Button(item) { type = item } } } label: {
                HStack { Text(type).font(V3.sans(14)).foregroundStyle(V3.txt); Spacer(); Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(V3.fnt) }
                    .padding(.horizontal, 12).frame(width: 180, height: 34).background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("证件类型")
            CPInput(text: $number, placeholder: profile["has_id_number"]?.bool == true ? "输入新的号码替换 \(profile.text("id_number_masked"))" : "证件号码", focus: true)
                .accessibilityLabel("证件号码")
        } extra: {
            if profile["has_id_number"]?.bool == true { CPLink(title: "删除证件号码", quiet: true, disabled: saving, action: remove) }
        }.onAppear { type = profile.text("id_type").nonEmptyValue ?? types.first ?? ""; number = "" }
    }
}

private struct IntentLines: View {
    let intent: JSONValue
    @Binding var editing: String?
    let saving: Bool
    let save: ([String: JSONValue]) -> Void
    @State private var cities = ""
    @State private var low = ""
    @State private var high = ""
    @State private var kinds: [String] = []

    private func kind(_ value: String) -> String { value == "internship" ? "实习" : "全职" }

    var body: some View {
        let types = (intent["employment_types"]?.items ?? []).compactMap(\.stringValue)
        let rows: [(String, String, String)] = [
            ("intent.cities", "期望城市", (intent["candidate_cities"]?.items ?? []).compactMap(\.stringValue).joined(separator: "、")),
            ("intent.salary", "期望薪资", CareerProfileRules.salaryText(intent)),
            ("intent.kinds", "工作性质", types.map(kind).joined(separator: "、")),
        ]
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            if editing == row.0 {
                EditBox(label: row.1, saving: saving, cancel: { editing = nil }, done: { done(row.0) }) { editor(row.0) }
            } else {
                Button { reset(); editing = row.0 } label: { CPValueRow(label: row.1, value: row.2, first: index == 0) }.buttonStyle(CPRowStyle())
            }
        }
    }

    @ViewBuilder private func editor(_ key: String) -> some View {
        switch key {
        case "intent.cities": CPInput(text: $cities, placeholder: "用顿号分开，例如 杭州、上海", focus: true)
        case "intent.salary":
            HStack(spacing: 8) {
                CPInput(text: $low, width: 96).accessibilityLabel("最低").onChange(of: low) { low = low.filter(\.isNumber) }
                Text("–")
                CPInput(text: $high, width: 96).accessibilityLabel("最高").onChange(of: high) { high = high.filter(\.isNumber) }
                Text("K / 月")
            }.font(V3.sans(13)).foregroundStyle(V3.sub)
        default:
            CPSeg(options: [("internship", "实习"), ("full_time", "全职")], active: { kinds.contains($0) }) { value in
                if kinds.contains(value) { kinds.removeAll { $0 == value } } else { kinds.append(value) }
            }
        }
    }

    private func reset() {
        cities = (intent["candidate_cities"]?.items ?? []).compactMap(\.stringValue).joined(separator: "、")
        low = intent["salary_min"]?.numberValue.map { String(Int(($0 / 1000).rounded())) } ?? ""
        high = intent["salary_max"]?.numberValue.map { String(Int(($0 / 1000).rounded())) } ?? ""
        kinds = (intent["employment_types"]?.items ?? []).compactMap(\.stringValue)
    }

    private func done(_ key: String) {
        switch key {
        case "intent.cities":
            let list = cities.components(separatedBy: CharacterSet(charactersIn: "、,， \n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            save(["candidate_cities": .array(list.prefix(20).map(JSONValue.string))])
        case "intent.salary":
            let min = Double(low).map { $0 * 1000 }, max = Double(high).map { $0 * 1000 }
            let has = min != nil || max != nil
            let fixedMax = (max != nil && min != nil && max! < min!) ? min : max
            save(["salary_min": min.map(JSONValue.number) ?? .null, "salary_max": fixedMax.map(JSONValue.number) ?? .null,
                  "salary_currency": has ? .string("CNY") : .null, "salary_period": has ? .string("month") : .null])
        default: save(["employment_types": .array(kinds.map(JSONValue.string))])
        }
    }
}

// MARK: - 经历

private struct ExperienceList: View {
    let experience: JSONValue
    let catalog: JSONValue
    @Binding var editing: String?
    let saving: Bool
    let save: (JSONValue, String?) -> Void

    private func supplementLabel(_ key: String) -> String { catalog["fields"]?["profile.entry.\(key)"]?.text("label").nonEmptyValue ?? key }
    private var sections: [JSONValue] { experience["sections"]?.items ?? [] }
    private func supplement(_ id: String) -> [String: String] {
        guard case .object(let fields) = experience["supplements"]?[id] ?? .null else { return [:] }
        return fields.compactMapValues(\.stringValue)
    }

    var body: some View {
        let groups = CareerProfileRules.groups(experience)
        let hasSkills = !(experience["skills"]?.items ?? []).isEmpty
        let texts = sections.enumerated().filter { CareerProfileRules.textKinds.contains($0.element.text("kind")) && !($0.element.text("kind") == "skills" && hasSkills) }
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.key) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.label).font(V3.sans(11.5, weight: .medium)).foregroundStyle(V3.fnt2).padding(.bottom, 2)
                    ForEach(Array(group.items.enumerated()), id: \.offset) { index, item in
                        let id = item.entry.display("id")
                        if editing == "entry:\(id)" {
                            EntryEditor(kind: item.kind, entry: item.entry, supplement: supplement(id), label: supplementLabel, saving: saving,
                                        cancel: { editing = nil }, remove: { replace(item.sectionIndex, id, nil, nil) }) { entry, extra in replace(item.sectionIndex, id, entry, extra) }
                        } else {
                            Button { editing = "entry:\(id)" } label: { entryLine(item, first: index == 0) }.buttonStyle(CPRowStyle())
                        }
                    }
                }
            }
            if !texts.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("技能与自我评价").font(V3.sans(11.5, weight: .medium)).foregroundStyle(V3.fnt2).padding(.bottom, 2)
                    ForEach(Array(texts.enumerated()), id: \.offset) { position, pair in
                        let key = "text:\(pair.offset)", value = text(pair.element), title = pair.element.text("title").nonEmptyValue ?? "技能"
                        if editing == key {
                            TextSectionEditor(label: title, value: value, saving: saving, cancel: { editing = nil }) { draft in
                                var next = sections
                                if case .object(var fields) = next[pair.offset] {
                                    fields["lines"] = .array(draft.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(JSONValue.string))
                                    fields["entries"] = .array([]); next[pair.offset] = .object(fields)
                                }
                                save(with(["sections": .array(next)]), nil)
                            }
                        } else {
                            Button { editing = key } label: {
                                CPRow(label: title, first: position == 0) { Text(value.isEmpty ? "未填" : value).lineLimit(1) } trailing: { CPChevron() }
                            }.buttonStyle(CPRowStyle())
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(V3.blue)
                Text("添加一段")
                ForEach([("education", false, "教育"), ("work", true, "实习"), ("work", false, "工作"), ("project", false, "项目"), ("activity", false, "校园")], id: \.2) { item in
                    CPLink(title: item.2) { add(item.0, intern: item.1) }
                }
            }.font(V3.sans(12.5)).foregroundStyle(V3.sub).padding(.top, -2)
        }
    }

    private func text(_ section: JSONValue) -> String {
        let lines = (section["lines"]?.items ?? []).compactMap(\.stringValue)
        let entries = (section["entries"]?.items ?? []).map { entry -> String in
            guard case .object(let fields) = entry["fields"] ?? .null else { return entry.text("description") }
            return [fields.keys.sorted().compactMap { fields[$0]?.stringValue }.joined(separator: " | "), entry.text("description")].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return (lines + entries).joined(separator: "\n")
    }

    private func entryLine(_ item: CareerProfileRules.Item, first: Bool) -> some View {
        let fields = item.entry["fields"] ?? .null, id = item.entry.display("id")
        let sub = ["职位", "角色", "专业", "学历学位"].map { fields.text($0) }.filter { !$0.isEmpty }.joined(separator: " · ")
        let period = ["开始时间", "结束时间"].map { fields.text($0) }.filter { !$0.isEmpty }.joined(separator: " – ")
        let extra = supplement(id)
        var meta = extra.keys.sorted().compactMap { key in extra[key].flatMap { $0.isEmpty ? nil : "\(supplementLabel(key)) \($0)" } }
        if item.kind == "work", !fields.text("部门").isEmpty { meta.insert(fields.text("部门"), at: 0) }
        let description = item.entry.text("description")
        if !description.isEmpty { meta.append("描述 \(description.count) 字") }
        let departmentMissing = item.kind == "work" && fields.text("部门").isEmpty && (extra["department"] ?? "").isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(CareerProfileRules.entryTitle(item.entry)).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                if !sub.isEmpty { Text(sub).font(V3.sans(12.5)).foregroundStyle(V3.sub).lineLimit(1) }
                Spacer(minLength: 0)
                if !period.isEmpty { Text(period).font(V3.sans(12)).foregroundStyle(V3.fnt2) }
            }
            if !meta.isEmpty || departmentMissing {
                (Text(meta.joined(separator: " · ")) + Text(departmentMissing ? (meta.isEmpty ? "" : " · ") : "") + Text(departmentMissing ? "部门未填" : "").foregroundColor(V3.orange))
                    .font(V3.sans(12)).foregroundStyle(V3.fnt)
            }
        }.padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .overlay(alignment: .top) { if !first { Rectangle().fill(Color(hex: 0xF2F1EE)).frame(height: 1) } }
    }

    private func with(_ change: [String: JSONValue]) -> JSONValue {
        guard case .object(var fields) = experience else { return experience }
        for (key, value) in change { fields[key] = value }
        return .object(fields)
    }

    private func replace(_ sectionIndex: Int, _ id: String, _ entry: JSONValue?, _ extra: [String: String]?) {
        var next = sections
        if case .object(var section) = next[sectionIndex] {
            let entries = section["entries"]?.items ?? []
            section["entries"] = .array(entry.map { e in entries.map { $0.display("id") == id ? e : $0 } } ?? entries.filter { $0.display("id") != id })
            next[sectionIndex] = .object(section)
        }
        var supplements: [String: JSONValue] = { if case .object(let s) = experience["supplements"] ?? .null { return s }; return [:] }()
        if entry == nil || extra?.isEmpty == true { supplements.removeValue(forKey: id) }
        else if let extra { supplements[id] = .object(extra.mapValues(JSONValue.string)) }
        save(with(["sections": .array(next), "supplements": .object(supplements)]), nil)
    }

    private func add(_ kind: String, intern: Bool) {
        let titles = ["education": "教育经历", "work": intern ? "实习经历" : "工作经历", "project": "项目经历", "activity": "校园经历"]
        let id = "e_" + (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let entry: JSONValue = .object(["id": .string(id), "fields": .object([:]), "description": .string(""), "ambiguous": .array([]), "intern": .bool(intern)])
        var next = sections
        if let index = next.firstIndex(where: { $0.text("kind") == kind }), case .object(var section) = next[index] {
            section["entries"] = .array((section["entries"]?.items ?? []) + [entry]); next[index] = .object(section)
        } else {
            next.append(.object(["id": .string(""), "kind": .string(kind), "title": .string(titles[kind] ?? ""), "lines": .array([]), "entries": .array([entry])]))
        }
        // 新加的一段存下后直接打开编辑。
        save(with(["sections": .array(next)]), "entry:\(id)")
    }
}

private struct EntryEditor: View {
    let kind: String
    let entry: JSONValue
    let supplement: [String: String]
    let label: (String) -> String
    let saving: Bool
    let cancel: () -> Void
    let remove: () -> Void
    let done: (JSONValue, [String: String]) -> Void
    @State private var fields: [String: String] = [:]
    @State private var description = ""
    @State private var extra: [String: String] = [:]

    private var shape: String { CareerProfileRules.entryKind(kind) }
    private var original: [String: String] { if case .object(let f) = entry["fields"] ?? .null { return f.compactMapValues(\.stringValue) }; return [:] }
    private var keys: [String] {
        var seen = Set<String>()
        return ((CareerProfileRules.entryFields[shape] ?? []) + original.keys.sorted()).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), alignment: .leading, spacing: 12) {
                ForEach(keys, id: \.self) { key in field(key, binding: Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })) }
                ForEach(CareerProfileRules.entrySupplements[shape] ?? [], id: \.self) { key in
                    field(label(key), asked: (extra[key] ?? "").isEmpty, binding: Binding(get: { extra[key] ?? "" }, set: { extra[key] = $0 }))
                }
            }
            if shape != "education" {
                VStack(alignment: .leading, spacing: 5) {
                    Text("内容").font(V3.sans(11.5, weight: .medium)).foregroundStyle(V3.fnt)
                    TextEditor(text: $description).font(V3.sans(14)).scrollContentBackground(.hidden).scrollIndicators(.never).padding(.horizontal, 8).padding(.vertical, 6)
                        .frame(height: 80).background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
                }
            }
            HStack(spacing: 14) {
                Text("只改这里，不影响简历").font(V3.sans(11.5)).foregroundStyle(V3.fnt)
                Spacer(minLength: 0)
                CPLink(title: "删除这段", quiet: true, disabled: saving, action: remove)
                // “添加一段”会先存下一段空经历再打开编辑；取消时一并删掉
                CPLink(title: "取消", quiet: true, disabled: saving, action: original.isEmpty && entry.text("description").isEmpty && supplement.isEmpty ? remove : cancel)
                CPLink(title: saving ? "保存中…" : "完成", disabled: saving, action: finish)
            }
        }.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14).background(Color(hex: 0xF7F7F5), in: RoundedRectangle(cornerRadius: 10)).padding(.vertical, 4)
            .onAppear { fields = original; description = entry.text("description"); extra = supplement }
    }

    private func field(_ title: String, asked: Bool = false, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) { Text(title).foregroundStyle(V3.fnt); if asked { Text("网申常问").foregroundStyle(V3.orange).fontWeight(.regular) } }.font(V3.sans(11.5, weight: .medium))
            TextField("", text: binding).textFieldStyle(.plain).font(V3.sans(14)).padding(.horizontal, 14).frame(height: 34)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(asked ? Color(hex: 0xE8C9A6) : V3.cl))
        }
    }

    private func finish() {
        let clean = fields.mapValues { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.value.isEmpty }
        let cleanExtra = extra.mapValues { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.value.isEmpty }
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        // 新加的一段一个字都没填就点完成：不留下“未命名”的空经历
        if clean.isEmpty && text.isEmpty && cleanExtra.isEmpty { remove(); return }
        guard case .object(var next) = entry else { return }
        next["fields"] = .object(clean.mapValues(JSONValue.string)); next["description"] = .string(text)
        next["ambiguous"] = .array((entry["ambiguous"]?.items ?? []).filter { clean[$0.stringValue ?? ""] == nil })
        done(.object(next), cleanExtra)
    }
}

private struct TextSectionEditor: View {
    let label: String
    let value: String
    let saving: Bool
    let cancel: () -> Void
    let done: (String) -> Void
    @State private var draft = ""
    var body: some View {
        EditBox(label: label, saving: saving, cancel: cancel, done: { done(draft) }) {
            TextEditor(text: $draft).font(V3.sans(14)).scrollContentBackground(.hidden).scrollIndicators(.never).padding(.horizontal, 8).padding(.vertical, 6)
                .frame(height: 100).background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
        }.onAppear { draft = value }
    }
}

// MARK: - 技能

private struct SkillLines: View {
    let skills: [(name: String, level: String?)]
    let editing: Bool
    let saving: Bool
    let edit: () -> Void
    let cancel: () -> Void
    let save: ([(name: String, level: String?)]) -> Void
    @State private var draft: [(name: String, level: String?)] = []
    @State private var adding = ""

    var body: some View {
        if editing {
            EditBox(label: "技能", saving: saving, cancel: cancel, done: { add(); save(draft) }) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(draft.enumerated()), id: \.offset) { index, skill in
                        HStack(spacing: 12) {
                            Text(skill.name).font(V3.sans(13.5)).foregroundStyle(V3.txt).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            CPSeg(options: CareerProfileRules.skillLevels.map { ($0.0, $0.1) } + [("unset", "未标注")], active: { ($0 == "unset" && skill.level == nil) || $0 == skill.level }) { level in
                                draft[index].level = level == "unset" ? nil : level
                            }.accessibilityLabel("\(skill.name) 的熟练度")
                            Button { draft.remove(at: index) } label: { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 24).contentShape(Rectangle()) }
                                .buttonStyle(.plain).foregroundStyle(V3.fnt).accessibilityLabel("去掉 \(skill.name)")
                        }
                    }
                    CPInput(text: $adding, placeholder: "添加技能，用顿号分开，回车确定") { add() }
                }
            }.onAppear { draft = skills; adding = "" }
        } else {
            let groups = (CareerProfileRules.skillLevels.reversed().map { ($0.0, $0.1) } + [("unset", "未标注")]).compactMap { level -> (String, String, [String])? in
                let names = skills.filter { level.0 == "unset" ? $0.level == nil : $0.level == level.0 }.map(\.name)
                return names.isEmpty ? nil : (level.0, level.1, names)
            }
            if groups.isEmpty {
                Button(action: edit) { CPValueRow(label: "技能", value: "", first: true) }.buttonStyle(CPRowStyle())
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    Button(action: edit) { CPValueRow(label: group.1, value: group.2.joined(separator: "、"), first: index == 0, soft: group.0 == "unset") }.buttonStyle(CPRowStyle())
                }
            }
        }
    }

    private func add() {
        var known = Set(draft.map { $0.name.lowercased() })
        let names = adding.components(separatedBy: CharacterSet(charactersIn: "、,，;；/\n")).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 60 && known.insert($0.lowercased()).inserted }
        draft = Array((draft + names.map { ($0, "familiar") }).prefix(60))
        adding = ""
    }
}

// MARK: - 弹窗

/// 从哪份简历读取经历（460 宽）：单选列表 + 说明。
private struct SwitchResumeSheet: View {
    @Environment(SessionStore.self) private var session
    let current: String?
    let hasExperience: Bool
    let close: () -> Void
    let read: (String) async -> Void
    @State private var resumes: [JSONValue]?
    @State private var choice: String?
    @State private var busy = false

    var body: some View {
        V3Dialog(width: 460, closable: !busy, close: close) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) { V3DialogHead(title: "从哪份简历读取经历", sub: "只换教育、实习、项目、奖项和技能；个人信息和求职意向不变。") }
                VStack(spacing: 0) {
                    if resumes == nil { Text("正在读取简历…").font(V3.sans(11.5)).foregroundStyle(V3.fnt).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
                    else if resumes?.isEmpty == true { Text("还没有简历，先去「我的简历」新建一份。").font(V3.sans(11.5)).foregroundStyle(V3.fnt).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
                    ForEach(Array((resumes ?? []).enumerated()), id: \.offset) { index, resume in
                        let id = resume.display("id"), on = choice == id
                        Button { choice = id } label: {
                            HStack(spacing: 12) {
                                Circle().strokeBorder(on ? V3.txt : Color(hex: 0xC8C8C4), lineWidth: on ? 5 : 1.5).frame(width: 16, height: 16)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(resume.text("title")).font(V3.sans(13.5, weight: .medium)).foregroundStyle(V3.txt)
                                    if id == current { Text("正在使用").font(V3.sans(11.5)).foregroundStyle(V3.fnt) }
                                }
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 14).padding(.vertical, 12).background(on ? Color(hex: 0xF6F6F4) : .white).contentShape(Rectangle())
                                .overlay(alignment: .top) { if index > 0 { Rectangle().fill(V3.cl).frame(height: 1) } }
                        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.cl))
                if hasExperience {
                    Notes(lines: ["同一所学校、同一家公司下补过的 GPA、部门等会保留", "新简历里没有的经历会被移除，这里只保存一份", "不用 AI，几秒完成；读进来后照样可以改"], size: 12.5)
                }
            }
        } foot: {
            Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36)).disabled(busy)
            Button(busy ? "读取中…" : hasExperience ? "换成这份" : "读取") {
                guard let choice else { return }
                busy = true
                Task { await read(choice); busy = false }
            }.buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).disabled(busy || choice == nil)
        }
        .task {
            let list = (try? await session.api.careerRequest(path: "/api/resumes", method: "GET", query: [:], body: nil))?["resumes"]?.items ?? []
            resumes = list
            choice = list.first { $0.display("id") != current }?.display("id") ?? list.first?.display("id")
        }
    }
}

/// 保存证件号码前的单独同意（460 宽）。
private struct ConsentSheet: View {
    let version: String
    let close: () -> Void
    let accept: () async -> Void
    @State private var agreed = false
    @State private var busy = false
    var body: some View {
        V3Dialog(width: 460, closable: !busy, close: close) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) { V3DialogHead(title: "保存证件号码", sub: "证件号码属于敏感个人信息，保存前需要你单独同意。") }
                Notes(lines: ["只在你使用网申插件时，填进招聘网站的表单", "加密保存；页面上只显示前 6 位和后 4 位", "不发给 AI，不用于其他任何用途", "随时可以在「求职资料」里删除，删除后不再保留"], size: 13)
                Toggle(isOn: $agreed) { Text("我同意 DrawOffer 按以上方式保存我的证件号码").font(V3.sans(13)).foregroundStyle(V3.txt) }.toggleStyle(.checkbox)
                Text("说明版本 \(version)").font(V3.sans(11.5)).foregroundStyle(V3.fnt)
            }
        } foot: {
            Button("暂不保存", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36)).disabled(busy)
            Button(busy ? "保存中…" : "同意并保存") { busy = true; Task { await accept(); busy = false } }.buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).disabled(!agreed || busy)
        }
    }
}

/// `.cp-notes`：#f6f6f4 底、圆角 10 的圆点列表。
private struct Notes: View {
    let lines: [String]
    let size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); Text(line).fixedSize(horizontal: false, vertical: true) }
            }
        }.font(V3.sans(size)).foregroundStyle(V3.txt).lineHeight(size, 19).padding(.leading, 18).padding(.trailing, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading).background(Color(hex: 0xF6F6F4), in: RoundedRectangle(cornerRadius: 10))
    }
}
