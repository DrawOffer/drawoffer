import AppKit
import DrawOfferCore
import SwiftUI
import UniformTypeIdentifiers

/// 03A · 导入岗位（Web `JobSmartImportDialog` unified）：固定 640×600，粘贴文字 / 上传截图 / 手工填写三种方式，
/// 识别后切到核对表单（03A-4），没识别到的字段用橙色虚线标出；确认后创建岗位并放进看板「待投递」。
struct CareerJobImportSheet: View {
    enum Tab: Hashable { case text, image, manual }
    let api: any APIClient
    let close: () -> Void
    let installPlugin: () -> Void
    /// 创建成功：返回新求职进程的 id（没有求职进程时为 nil）。
    let created: (String?) -> Void

    @State private var tab: Tab = .text
    @State private var text = ""
    @State private var image: (data: Data, name: String, type: String)?
    @State private var preview: NSImage?
    @State private var form: [String: String] = [:]
    @State private var recognized = Set<String>()
    @State private var reviewSource: Tab?
    @State private var warnings: [String] = []
    @State private var expanded = Set<String>()
    @State private var busy = false
    @State private var error: String?
    @State private var dropping = false
    @State private var task: Task<Void, Never>?

    private static let limit = 60_000
    private var reviewing: Bool { tab == .manual && reviewSource != nil }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                head
                if !reviewing { tabs.padding(.top, 20) }
                if reviewing { summary } else {
                    Text(hint).font(V3.sans(12)).foregroundStyle(V3.fnt).lineSpacing(3).padding(.top, 16).padding(.bottom, 10)
                }
                Group {
                    switch tab {
                    case .text: textPane
                    case .image: imagePane
                    case .manual: manualPane
                    }
                }.frame(maxHeight: .infinity, alignment: .top)
                if busy && tab != .manual { progress }
                if let error { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red).padding(.top, 10).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 24)
            .frame(maxHeight: .infinity, alignment: .top)
            Rectangle().fill(V3.line).frame(height: 1)
            foot.padding(.horizontal, 32).frame(height: 72)
        }
        .frame(width: 640, height: 600)
        .background(.white)
        .interactiveDismissDisabled(busy)
        .onDisappear { task?.cancel() }
    }

    // MARK: 头部与切换

    private var head: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("导入岗位").font(V3.serif(22)).foregroundStyle(V3.txt)
                Text(reviewing ? "识别完成，核对无误后创建岗位。" : "识别成岗位草稿，核对后放进看板「待投递」。")
                    .font(V3.sans(13)).foregroundStyle(V3.sub)
            }
            Spacer(minLength: 12)
            Button { cancel() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(V3.fnt).frame(width: 24, height: 24).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("关闭")
        }
    }

    private var tabs: some View {
        HStack(spacing: 3) {
            ForEach([(Tab.text, "text.alignleft", "粘贴岗位文字"), (.image, "photo", "上传岗位截图"), (.manual, "square.and.pencil", "手工填写")], id: \.0) { item in
                let on = tab == item.0
                Button { select(item.0) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.1).font(.system(size: 12)).foregroundStyle(on ? V3.txt : V3.fnt)
                        Text(item.2).font(V3.sans(13, weight: on ? .medium : .regular)).foregroundStyle(on ? V3.txt : V3.sub).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .background(on ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? V3.cl : .clear))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(busy).accessibilityAddTraits(on ? .isSelected : [])
            }
        }.padding(3).background(V3.field, in: RoundedRectangle(cornerRadius: 10))
    }

    private var hint: String {
        switch tab {
        case .text: "适合网页上能复制文字的岗位：职位、职责、要求和薪资一起粘进来，识别得更完整。"
        case .image: "适合 App 里不能复制的岗位：截一张包含职位名称和岗位要求的图，识别后逐项核对。"
        case .manual: "适合内推、线下招聘的岗位：只填职位名称和公司就能创建，其余之后在岗位详情里补。"
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(V3.green)
                    .frame(width: 22, height: 22).background(V3.greenSoft, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("已从\(reviewSource == .image ? "岗位截图" : "岗位文字")识别出 \(recognized.count) 个字段").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                    Text("没识别到的用橙色虚线标出，可以现在补，也可以之后改。").font(V3.sans(12)).foregroundStyle(V3.sub)
                }
                Spacer(minLength: 8)
                Button("查看原文") { select(reviewSource ?? .text) }.buttonStyle(.plain).font(V3.sans(12.5)).foregroundStyle(V3.link)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(V3.stage, in: RoundedRectangle(cornerRadius: 10))
            ForEach(warnings, id: \.self) { warning in
                Text(warning).font(V3.sans(12)).foregroundStyle(V3.orange).padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading).background(V3.orangeSoft, in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(.top, 20).padding(.bottom, 18)
    }

    // MARK: 粘贴文字

    private var textPane: some View {
        ZStack(alignment: .bottomTrailing) {
            TextEditor(text: $text)
                .font(V3.sans(13)).foregroundStyle(V3.txt).scrollContentBackground(.hidden)
                .lineSpacing(5).padding(.horizontal, 11).padding(.top, 10).padding(.bottom, 26)
                .disabled(busy).opacity(busy ? 0.55 : 1)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("粘贴职位名称、岗位职责、任职要求、薪资和公司信息…").font(V3.sans(13)).foregroundStyle(V3.fnt2)
                            .padding(.horizontal, 16).padding(.top, 10).allowsHitTesting(false)
                    }
                }
                .onChange(of: text) { _, _ in error = nil }
                .accessibilityLabel("岗位文字")
            Text("\(text.count) / \(Self.limit)").font(V3.number(11, weight: .regular))
                .foregroundStyle(text.count > Self.limit ? V3.red : V3.fnt2).padding(.trailing, 14).padding(.bottom, 10)
        }
        .frame(minHeight: 140, maxHeight: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.cl))
    }

    // MARK: 上传截图

    private var imagePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image {
                HStack(spacing: 14) {
                    Group {
                        if let preview { Image(nsImage: preview).resizable().aspectRatio(contentMode: .fill) } else { V3.field }
                    }.frame(width: 116, height: 96).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(image.name).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.middle)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(image.data.count), countStyle: .file)).font(V3.number(11, weight: .regular)).foregroundStyle(V3.fnt)
                    }
                    Spacer(minLength: 8)
                    Button("移除图片") { self.image = nil; preview = nil; error = nil }.buttonStyle(V3ButtonStyle(kind: .ghost, small: true)).disabled(busy)
                }
                .padding(16).frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.cl))
            } else {
                Button(action: chooseImage) {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.up.to.line").font(.system(size: 16, weight: .medium)).foregroundStyle(V3.txt)
                            .frame(width: 44, height: 44).background(.white, in: Circle()).overlay(Circle().stroke(V3.cl))
                        Text("点击上传，或把截图拖进来").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                        Text("PNG 或 JPEG · 最大 10 MB · 每次一张").font(V3.sans(12)).foregroundStyle(V3.fnt)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                    .background(dropping ? V3.field : Color(hex: 0xFAFAF8), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(dropping ? V3.txt : V3.sk2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(busy).accessibilityLabel("选择岗位截图")
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    load(url); return true
                } isTargeted: { dropping = $0 }
            }
            HStack(spacing: 18) {
                ForEach(["截图里要有职位名称和公司", "一屏放不下就截最关键的一屏"], id: \.self) { tip in
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(V3.green)
                        Text(tip).font(V3.sans(12)).foregroundStyle(V3.sub)
                    }
                }
            }
        }
    }

    // MARK: 手工填写 / 核对

    private var manualPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                grid([
                    field("job_title", "职位名称", "例如：后端开发工程师", required: true),
                    field("company_name", "公司名称", "例如：星河科技", required: true),
                    field("salary_text", "薪资范围", "例如：25-40K，或面议"),
                    field("work_city", "工作城市", "例如：杭州", icon: "mappin"),
                    choice("employment_type", "求职分类", [("internship", "实习"), ("campus", "校招"), ("full_time", "正式")]),
                    choice("work_mode", "工作方式", [("onsite", "现场"), ("hybrid", "混合"), ("remote", "远程")]),
                ])
                HStack(alignment: .firstTextBaseline) {
                    Text(reviewing ? "其余信息" : "更多信息").font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub)
                    Spacer()
                    Text("可选，之后在岗位详情也能改").font(V3.sans(11)).foregroundStyle(V3.fnt2)
                }.padding(.top, 22).padding(.bottom, 8)
                FlowLayout(spacing: 8) {
                    ForEach(groups, id: \.0) { group in
                        let open = expanded.contains(group.0)
                        Button {
                            if open { expanded.remove(group.0) } else { expanded.insert(group.0) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: open ? "minus" : "plus").font(.system(size: 10, weight: .medium)).foregroundStyle(V3.sub)
                                Text(group.1).font(V3.sans(12)).foregroundStyle(open ? V3.txt : V3.sub)
                            }
                            .padding(.leading, 10).padding(.trailing, 12).frame(height: 28)
                            .background(.white, in: Capsule()).overlay(Capsule().stroke(open ? V3.txt : V3.cl))
                            .contentShape(Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(open ? .isSelected : [])
                    }
                }
                if expanded.contains("requirements") {
                    section("任职要求", [
                        area("description", "职位描述", "填写岗位职责、工作内容和任职要求（可选）"),
                        field("skills", "技能", "使用逗号或换行分隔，例如：Java、SQL"),
                        field("education_requirement", "学历要求", "例如：本科及以上"),
                        field("experience_requirement", "经验要求", "例如：3-5年"),
                    ])
                }
                if expanded.contains("work") {
                    section("工作与薪酬", [field("work_address", "详细地址", "填写办公地点或详细地址"), field("work_schedule", "工作安排", "例如：双休、弹性打卡")])
                }
                if expanded.contains("company") {
                    section("公司与联系人", [
                        field("company_industry", "行业", "例如：互联网、金融"), field("company_size", "公司规模", "例如：100-499人"),
                        field("company_financing_stage", "融资阶段", "例如：A轮、上市公司"), field("recruiter_name", "招聘者姓名", "填写联系人姓名"),
                        field("recruiter_title", "招聘者职位", "填写联系人职位"), field("logo_url", "公司 Logo URL（可选）", "填写公开可访问的 HTTPS 图片地址", wide: true),
                    ])
                }
                if expanded.contains("source") {
                    section("来源与备注", [field("source_url", "来源链接（可选）", "粘贴岗位原始链接", icon: "link", wide: true), area("notes", "个人备注", "填写你对这个岗位的补充备注")])
                }
            }.padding(.trailing, 12)
        }
        .padding(.trailing, -12)
        .scrollIndicators(.automatic)
    }

    private var groups: [(String, String)] {
        let described = !(form["description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return [("requirements", reviewing ? "职位描述 · \(described ? "已识别" : "未识别")" : "任职要求"), ("work", "工作安排"), ("company", "公司与联系人"), ("source", "来源与备注")]
    }

    private struct Cell: Identifiable { let id: String; let wide: Bool; let view: AnyView }

    private func grid(_ cells: [Cell]) -> some View {
        var rows: [[Cell]] = []; var pending: [Cell] = []
        for cell in cells {
            if cell.wide { if !pending.isEmpty { rows.append(pending); pending = [] }; rows.append([cell]) }
            else { pending.append(cell); if pending.count == 2 { rows.append(pending); pending = [] } }
        }
        if !pending.isEmpty { rows.append(pending) }
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { row in
                HStack(alignment: .top, spacing: 16) {
                    ForEach(row.element) { cell in cell.view.frame(maxWidth: .infinity, alignment: .leading) }
                    if row.element.count == 1 && !row.element[0].wide { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }

    private func section(_ title: String, _ cells: [Cell]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
            grid(cells)
        }.padding(.top, 18)
    }

    private func missing(_ key: String) -> Bool {
        reviewing && !recognized.contains(key) && (form[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { form[key] ?? "" }, set: { form[key] = $0; error = nil })
    }

    private func label(_ key: String, _ title: String, required: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                Text(title).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub)
                if required { Text("*").font(V3.sans(12, weight: .bold)).foregroundStyle(V3.red) }
            }
            Spacer(minLength: 0)
            if missing(key) { Text("未识别").font(V3.sans(11)).foregroundStyle(V3.orange) }
        }
    }

    private func box(_ key: String) -> some View {
        RoundedRectangle(cornerRadius: 8).stroke(missing(key) ? V3.orange : V3.cl, style: StrokeStyle(lineWidth: 1, dash: missing(key) ? [4, 3] : []))
    }

    private func field(_ key: String, _ title: String, _ placeholder: String, required: Bool = false, icon: String? = nil, wide: Bool = false) -> Cell {
        let empty = missing(key)
        return Cell(id: key, wide: wide, view: AnyView(VStack(alignment: .leading, spacing: 6) {
            label(key, title, required: required)
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 12)).foregroundStyle(V3.fnt) }
                TextField("", text: binding(key), prompt: Text(empty ? "可以现在补充，也可以之后改" : placeholder).foregroundStyle(empty ? V3.orange : V3.fnt2))
                    .textFieldStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.txt).accessibilityLabel(title)
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(box(key))
        }))
    }

    private func area(_ key: String, _ title: String, _ placeholder: String) -> Cell {
        Cell(id: key, wide: true, view: AnyView(VStack(alignment: .leading, spacing: 6) {
            label(key, title, required: false)
            TextField("", text: binding(key), prompt: Text(placeholder).foregroundStyle(V3.fnt2), axis: .vertical)
                .textFieldStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.txt).lineLimit(4...10).lineSpacing(3)
                .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 88, alignment: .topLeading)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(box(key)).accessibilityLabel(title)
        }))
    }

    private func choice(_ key: String, _ title: String, _ options: [(String, String)]) -> Cell {
        let value = form[key] ?? ""
        return Cell(id: key, wide: false, view: AnyView(VStack(alignment: .leading, spacing: 6) {
            label(key, title, required: false)
            Menu {
                Button("未填写") { form[key] = "" }
                ForEach(options, id: \.0) { option in Button(option.1) { form[key] = option.0 } }
            } label: {
                HStack {
                    Text(options.first { $0.0 == value }?.1 ?? "未填写").font(V3.sans(13)).foregroundStyle(value.isEmpty ? (missing(key) ? V3.orange : V3.fnt2) : V3.txt)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(V3.fnt)
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(box(key)).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel(title)
        }))
    }

    // MARK: 进度与底部

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("正在提取职位、公司、薪资和任职要求").font(V3.sans(12)).foregroundStyle(V3.sub)
                Spacer()
                Text("约 5 秒").font(V3.number(11, weight: .medium)).foregroundStyle(V3.fnt)
            }
            CareerImportProgressTrack()
        }.padding(.top, 14).accessibilityElement(children: .combine).accessibilityLabel("正在识别")
    }

    private var foot: some View {
        HStack(spacing: 10) {
            if reviewing {
                Button { select(reviewSource ?? .text) } label: {
                    HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 11, weight: .medium)); Text("返回修改原文") }
                }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.link).disabled(busy)
            } else if busy {
                Text("关闭弹窗会取消识别").font(V3.sans(12)).foregroundStyle(V3.fnt)
            } else {
                Button { installPlugin() } label: {
                    HStack(spacing: 4) { Text("用浏览器插件一键保存"); Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium)) }
                }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.link).lineLimit(1)
            }
            Spacer(minLength: 8)
            if tab != .manual && !busy { Text("按实际用量消耗积分").font(V3.sans(12)).foregroundStyle(V3.fnt) }
            if !reviewing { Button("取消") { cancel() }.buttonStyle(V3ButtonStyle(kind: .ghost, height: 36)).keyboardShortcut(.cancelAction) }
            Button(primaryLabel) { submit() }
                .buttonStyle(V3ButtonStyle(kind: .dark, height: 36, width: 96)).disabled(busy)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryLabel: String {
        if busy { return tab == .manual ? "正在创建…" : "正在识别…" }
        return tab == .manual ? "创建岗位" : "确认导入"
    }

    // MARK: 行为

    private func select(_ next: Tab) {
        guard !busy else { return }
        tab = next
        if next != .manual { reviewSource = nil }
        error = nil
    }

    private func cancel() { task?.cancel(); close() }

    private func submit() {
        guard !busy else { return }
        if tab == .manual { task = Task { await create() } } else { task = Task { await parse() } }
    }

    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(ext) else { error = "仅支持 PNG 或 JPEG 图片。"; return }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 10 * 1024 * 1024 else { error = "图片不能超过 10 MiB。"; return }
        guard let data = try? Data(contentsOf: url) else { error = "截图读取失败，请重新选择。"; return }
        image = (data, url.lastPathComponent, ext == "png" ? "image/png" : "image/jpeg")
        preview = NSImage(data: data); error = nil
    }

    private func parse() async {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if tab == .image && image == nil { error = "请上传岗位截图。"; return }
        if tab == .text && normalized.isEmpty { error = "请输入岗位文字。"; return }
        if tab == .text && normalized.count > Self.limit { error = "岗位文字不能超过 60000 个字符。"; return }
        let source = tab
        busy = true; error = nil
        defer { busy = false }
        do {
            let body: JSONValue = source == .image
                ? .object(["image_base64": .string(image!.data.base64EncodedString()), "content_type": .string(image!.type)])
                : .object(["text": .string(normalized)])
            let result = try await api.careerRequest(path: "/api/job-descriptions/parse-draft", method: "POST", query: [:], body: body)
            try Task.checkCancellation()
            let draft = result["draft"] ?? .null
            var next: [String: String] = [:]
            for key in Self.keys { next[key] = Self.string(draft[key]) }
            if let skills = draft["skills"]?.items, !skills.isEmpty { next["skills"] = skills.compactMap(\.stringValue).joined(separator: ", ") }
            form = next
            recognized = Set(next.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.keys)
            warnings = (result["warnings"]?.items ?? []).compactMap { $0.stringValue ?? $0["message"]?.stringValue }
            reviewSource = source; tab = .manual
        } catch is CancellationError { return }
        catch { self.error = Self.parseError(error, image: source == .image) }
    }

    private func create() async {
        let required = [("job_title", "职位名称"), ("company_name", "公司名称")].filter { (form[$0.0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !required.isEmpty { error = "请先填写" + required.map(\.1).joined(separator: "、"); return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await api.careerRequest(path: "/api/job-descriptions", method: "POST", query: [:], body: payload)
            created(result["application"]?["id"]?.stringValue)
        } catch is CancellationError { return }
        catch { self.error = Self.saveError(error) }
    }

    /// 与 Web `jobPayloadFromForm` 相同的字段与空值规则。
    private var payload: JSONValue {
        func value(_ key: String) -> String { (form[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func nullable(_ key: String) -> JSONValue { value(key).isEmpty ? .null : .string(value(key)) }
        var fields: [String: JSONValue] = [:]
        for key in Self.keys where !["job_title", "company_name", "description", "salary_months_per_year"].contains(key) { fields[key] = nullable(key) }
        fields["job_title"] = .string(value("job_title"))
        fields["company_name"] = .string(value("company_name"))
        fields["description"] = .string(value("description"))
        fields["skills"] = .array((form["skills"] ?? "").split(whereSeparator: { [",", "，", "\n"].contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map(JSONValue.string))
        fields["salary_months_per_year"] = Double(value("salary_months_per_year")).map(JSONValue.number) ?? .null
        fields["source_type"] = .string("manual")
        return .object(fields)
    }

    private static let keys = ["job_title", "company_name", "logo_url", "employment_type", "description", "education_requirement",
                               "experience_requirement", "work_schedule", "work_city", "work_address", "work_mode", "salary_text", "salary_min",
                               "salary_max", "salary_currency", "salary_period", "salary_months_per_year", "company_legal_name", "company_industry",
                               "company_size", "company_financing_stage", "company_description", "recruiter_name", "recruiter_title", "source_url", "notes"]

    private static func string(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let text = value.stringValue { return text }
        if case .number(let number) = value { return number == number.rounded() ? String(Int(number)) : String(number) }
        return ""
    }

    private static func parseError(_ error: Error, image: Bool) -> String {
        guard case APIError.server(_, let code) = error else {
            if case APIError.unauthorized = error { return "登录状态已失效，请重新登录。" }
            return "暂时无法识别，请稍后重试。"
        }
        switch code {
        case "JD_IMPORT_MODEL_NOT_CONFIGURED": return "\(image ? "图片" : "文字")解析模型尚未配置，请联系管理员或改为填写。"
        case "JD_IMPORT_PARSE_TIMEOUT": return "识别超时，请重试或改为填写。"
        case "JD_IMPORT_IMAGE_TOO_LARGE": return "图片不能超过 10 MiB。"
        case "JD_IMPORT_IMAGE_UNSUPPORTED": return "仅支持 PNG 或 JPEG 图片。"
        case "JD_IMPORT_TEXT_TOO_LARGE": return "岗位文字不能超过 60000 个字符。"
        case "INSUFFICIENT_CREDITS", "CREDITS_INSUFFICIENT": return "积分不足，充值后再识别，或改为手工填写。"
        default: return "暂时无法识别，请稍后重试或改为填写。"
        }
    }

    private static func saveError(_ error: Error) -> String {
        if case APIError.unauthorized = error { return "登录状态已失效，请重新登录。" }
        guard case APIError.server(_, let code) = error else { return "保存岗位失败，请稍后重试。" }
        switch code {
        case "INVALID_JOB_DESCRIPTION": return "请检查必填字段、薪资组合和字段长度。"
        case "INVALID_JOB_SOURCE": return "来源链接无法识别，请检查后重试。"
        case "JD_SOURCE_DUPLICATE": return "这个来源链接的岗位已经保存过，可以在看板里找到它，或清空来源链接后再创建。"
        default: return "保存岗位失败，请稍后重试。"
        }
    }
}

/// `.job-import-progress-track`：4pt 细轨上来回滑动的墨黑短条。
private struct CareerImportProgressTrack: View {
    @State private var moving = false
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(V3.line)
                Capsule().fill(V3.txt).frame(width: geometry.size.width * 0.28)
                    .offset(x: moving ? geometry.size.width : -geometry.size.width * 0.28)
            }.clipShape(Capsule())
        }
        .frame(height: 4)
        .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { moving = true } }
    }
}

/// 03B · 安装 DrawOffer 求职助手（Web `PluginInstallDialog`）：下载行、三步安装和一句用法。
/// 客户端没有二进制下载通道，「下载 ZIP」在浏览器里打开 Web 岗位看板完成下载。
struct CareerPluginSheet: View {
    let api: any APIClient
    let close: () -> Void
    @State private var status: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("安装 DrawOffer 求职助手").font(V3.serif(22)).foregroundStyle(V3.txt)
                    Spacer(minLength: 12)
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(V3.fnt).frame(width: 24, height: 24).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("关闭插件安装说明")
                }
                Text("下载后解压，按下面三步装到浏览器。").font(V3.sans(13)).foregroundStyle(V3.sub).padding(.top, 8)
                HStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 16)).foregroundStyle(V3.txt)
                        .frame(width: 36, height: 36).background(V3.field, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DrawOffer 求职助手").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
                        Text(stateText).font(V3.sans(12)).foregroundStyle(failed ? V3.red : V3.fnt).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if status == "available" {
                        Button { openWeb() } label: { Image(systemName: "arrow.down.to.line").font(.system(size: 12, weight: .medium)); Text("下载 ZIP") }
                            .buttonStyle(V3ButtonStyle(kind: .dark, height: 36))
                    }
                }.padding(.top, 24)
                Rectangle().fill(V3.line).frame(height: 1).padding(.top, 16)
                Text("三步装好").font(V3.sans(12, weight: .medium)).foregroundStyle(V3.fnt).tracking(0.5).padding(.top, 24)
                VStack(alignment: .leading, spacing: 24) {
                    step("1", "解压到固定目录", Text("不能直接把 ZIP 拖进浏览器；解压后别移动。"))
                    step("2", "打开扩展管理页", Text("地址栏输入 ") + code("chrome://extensions") + Text("。\nEdge 用 ") + code("edge://extensions") + Text("。"))
                    step("3", "加载并固定到工具栏", Text("打开「开发者模式」→「加载已解压的扩展程序」→\n选择包含 ") + code("manifest.json") + Text(" 的目录，再把插件固定到工具栏。"))
                }.padding(.top, 16)
                Rectangle().fill(V3.line).frame(height: 1).padding(.top, 24)
                (Text("装好后：").foregroundStyle(V3.txt).fontWeight(.medium) + Text("登录后点工具栏图标打开侧栏：在 BOSS 岗位页把岗位加入我的岗位，在其他网申页用求职画像填写。插件不会自动投递或批量采集。").foregroundStyle(V3.fnt))
                    .font(V3.sans(12)).lineSpacing(3).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }.padding(.horizontal, 32).padding(.top, 28)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Text("更新时覆盖原解压目录，再在扩展页点「重新加载」").font(V3.sans(12)).foregroundStyle(V3.fnt).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Button("完成", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36)).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 32).frame(height: 64)
        }
        .frame(width: 640, height: 612)
        .background(.white)
        .task { await load() }
    }

    private var stateText: String {
        if failed { return "暂时无法获取插件安装包，请稍后重试。" }
        switch status {
        case nil: return "正在检查安装包…"
        case "unpublished": return "暂未提供插件安装包。"
        default: return "支持 Chrome / Edge · 在浏览器里下载"
        }
    }

    private func code(_ value: String) -> Text { Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(V3.txt) }

    private func step(_ index: String, _ title: String, _ body: Text) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(index).font(V3.number(12, weight: .medium)).foregroundStyle(V3.fnt).frame(width: 16, height: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(V3.sans(16, weight: .medium)).foregroundStyle(V3.txt).frame(height: 24)
                body.font(V3.sans(14)).foregroundStyle(V3.sub).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func load() async {
        do {
            let result = try await api.careerRequest(path: "/api/plugin-releases/current", method: "GET", query: [:], body: nil)
            status = result.text("status") == "available" && result["release"] != nil ? "available" : "unpublished"
        } catch { failed = true }
    }

    /// 下载要带登录态，客户端只能打开 Web 岗位看板，在那里的「安装浏览器插件」里下载。
    private func openWeb() {
        let origin = ProcessInfo.processInfo.environment["DRAWOFFER_API_ORIGIN"] ?? UserDefaults.standard.string(forKey: "DrawOfferAPIOrigin") ?? ""
        guard var components = URLComponents(string: origin), components.scheme == "https" || components.host == "localhost" || components.host == "127.0.0.1" else { failed = true; return }
        components.path = "/career/jobs"; components.query = nil; components.fragment = nil
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
