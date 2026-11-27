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
    /// 已经在本机识别过的文字；同一段文字再点“确认导入”就交给 AI。
    @State private var locallyParsed: String?
    @State private var expanded = Set<String>()
    @State private var busy = false
    @State private var error: String?
    @State private var dropping = false
    @State private var task: Task<Void, Never>?
    /// 投递简历：nil 为还没读到列表；只有一份时直接选上，多份由用户自己选。岗位创建时同一事务绑定到待投递记录。
    @State private var resumes: [JSONValue]?
    @State private var resumeID = ""
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?

    private static let limit = 60_000
    private var reviewing: Bool { tab == .manual && reviewSource != nil }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                head
                if !reviewing { tabs.padding(.top, 27) }
                if reviewing { summary } else {
                    Text(hint).font(V3.sans(12)).foregroundStyle(ImportInk.hint).lineSpacing(3).padding(.top, 18).padding(.bottom, 10)
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
            Rectangle().fill(ImportInk.divider).frame(height: 1)
            foot.padding(.horizontal, 32).frame(height: 72)
        }
        .frame(width: 640, height: 600)
        .background(.white)
        .interactiveDismissDisabled(busy)
        .onDisappear { task?.cancel() }
        .task { await loadResumes() }
    }

    // MARK: 头部与切换

    private var head: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("导入岗位").font(V3.sans(20)).foregroundStyle(V3.txt).frame(height: 27)
                Text(reviewing ? "识别完成，核对无误后创建岗位。" : "识别成岗位草稿，核对后放进看板「待投递」。")
                    .font(V3.sans(13)).foregroundStyle(V3.fnt).frame(height: 18)
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
                        Image(systemName: item.1).font(.system(size: 13)).foregroundStyle(on ? V3.txt : V3.fnt)
                        Text(item.2).font(V3.sans(13, weight: on ? .medium : .regular)).foregroundStyle(on ? V3.txt : V3.fnt).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .background(on ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? V3.sk2 : .clear))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(busy).accessibilityAddTraits(on ? .isSelected : [])
            }
        }.padding(3).background(V3.field, in: RoundedRectangle(cornerRadius: 10))
    }

    private var hint: String {
        switch tab {
        case .text: "适合网页上能复制文字的岗位：职位、职责、要求和薪资一起粘进来，识别得更完整。"
        case .image: "适合 App 里不能复制的岗位：截一张包含职位名称和岗位要求的图，识别后逐项核对。"
        case .manual: "适合内推、线下招聘的岗位：填好带 * 的四项就能创建，其余之后在岗位详情里补。"
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(V3.green)
                    .frame(width: 22, height: 22).background(Color(hex: 0xE3F3E9), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("从\(reviewSource == .image ? "岗位截图" : "岗位文字")识别出 \(recognized.count) 个字段").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                    Text("没识别到的用橙色标出，带 * 的要补上，其余可以之后改。").font(V3.sans(12)).foregroundStyle(V3.fnt)
                }
                Spacer(minLength: 8)
                Button("查看原文") { select(reviewSource ?? .text) }.buttonStyle(.plain).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.blue)
            }
            .padding(.horizontal, 14).frame(height: 65)
            .background(Color(hex: 0xF6F6F4), in: RoundedRectangle(cornerRadius: 10))
            ForEach(warnings, id: \.self) { warning in
                Text(warning).font(V3.sans(12)).foregroundStyle(V3.orange).padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading).background(V3.orangeSoft, in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(.top, 27).padding(.bottom, 20)
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
                        Text("粘贴职位名称、岗位职责、任职要求、薪资和公司信息…").font(V3.sans(13)).foregroundStyle(ImportInk.placeholder)
                            .padding(.horizontal, 16).padding(.top, 10).allowsHitTesting(false)
                    }
                }
                .onChange(of: text) { _, _ in error = nil }
                .accessibilityLabel("岗位文字")
            Text("\(text.count) / \(Self.limit)").font(V3.number(11, weight: .regular))
                .foregroundStyle(text.count > Self.limit ? V3.red : ImportInk.placeholder).padding(.trailing, 14).padding(.bottom, 10)
        }
        .frame(minHeight: 140, maxHeight: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.sk2))
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
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.sk2))
            } else {
                Button(action: chooseImage) {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.up.to.line").font(.system(size: 16, weight: .medium)).foregroundStyle(V3.txt)
                            .frame(width: 43, height: 43).background(.white, in: Circle()).overlay(Circle().stroke(V3.cl))
                        Text("点击上传，或把截图拖进来、直接粘贴（⌘V）").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                        Text("PNG、JPEG 或 WebP · 最大 10 MB · 每次一张").font(V3.sans(12)).foregroundStyle(ImportInk.hint)
                    }
                    .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                    .background(dropping ? V3.field : Color(hex: 0xFAFAF8), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(dropping ? V3.txt : Color(hex: 0xCFCFCB), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
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
                        Text(tip).font(V3.sans(12)).foregroundStyle(V3.fnt)
                    }
                }
            }
        }
        .background {
            // ⌘V 直接粘贴剪贴板里的截图（与 Web 一致）；只在上传页挂载，不影响其他页的文字粘贴。
            Button("") { pasteImage() }.keyboardShortcut("v", modifiers: .command)
                .opacity(0).frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true).disabled(busy)
        }
    }

    // MARK: 手工填写 / 核对

    private var manualPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                grid([
                    field("job_title", "职位名称", "例如：后端开发工程师", required: true),
                    field("company_name", "公司名称", "例如：星河科技", required: true),
                    choice("employment_type", "求职分类", [("internship", "实习"), ("campus", "校招"), ("full_time", "正式")], required: true),
                    resumeCell,
                    field("salary_text", "薪资范围", "例如：25-40K，或面议"),
                    field("work_city", "工作城市", "例如：杭州", icon: "mappin"),
                ])
                HStack(alignment: .firstTextBaseline) {
                    Text(reviewing ? "其余信息" : "更多信息").font(V3.sans(12, weight: .medium)).foregroundStyle(V3.fnt)
                    Spacer()
                    Text("可选，之后在岗位详情也能改").font(V3.sans(11)).foregroundStyle(ImportInk.placeholder)
                }.padding(.top, 24).padding(.bottom, 8)
                FlowLayout(spacing: 8) {
                    ForEach(groups, id: \.0) { group in
                        let open = expanded.contains(group.0)
                        Button {
                            if open { expanded.remove(group.0) } else { expanded.insert(group.0) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: open ? "minus" : "plus").font(.system(size: 10, weight: .medium)).foregroundStyle(V3.sub)
                                Text(group.1).font(V3.sans(12)).foregroundStyle(Color(hex: 0x3A3A38))
                            }
                            .padding(.leading, 10).padding(.trailing, 12).frame(height: 28)
                            .background(.white, in: Capsule()).overlay(Capsule().stroke(open ? V3.txt : V3.sk2))
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
                    section("工作与薪酬", [choice("work_mode", "工作方式", [("onsite", "现场"), ("hybrid", "混合"), ("remote", "远程")]),
                                         field("work_address", "详细地址", "填写办公地点或详细地址"), field("work_schedule", "工作安排", "例如：双休、弹性打卡")])
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
        return VStack(alignment: .leading, spacing: 16) {
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
                Text(title).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.fnt)
                if required { Text("*").font(V3.sans(12, weight: .bold)).foregroundStyle(V3.red) }
            }
            Spacer(minLength: 0)
            if missing(key) { Text("未识别").font(V3.sans(11)).foregroundStyle(V3.orange) }
        }.frame(height: 17)
    }

    private func box(_ key: String) -> some View {
        RoundedRectangle(cornerRadius: 8).stroke(missing(key) ? V3.orange : V3.sk2, style: StrokeStyle(lineWidth: 1, dash: missing(key) ? [4, 3] : []))
    }

    private func field(_ key: String, _ title: String, _ placeholder: String, required: Bool = false, icon: String? = nil, wide: Bool = false) -> Cell {
        let empty = missing(key)
        return Cell(id: key, wide: wide, view: AnyView(VStack(alignment: .leading, spacing: 6) {
            label(key, title, required: required)
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 12)).foregroundStyle(V3.fnt) }
                TextField("", text: binding(key), prompt: Text(empty ? "可以现在补充，也可以之后改" : placeholder).foregroundStyle(empty ? V3.orange : ImportInk.placeholder))
                    .textFieldStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.txt).accessibilityLabel(title)
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(box(key))
        }))
    }

    private func area(_ key: String, _ title: String, _ placeholder: String) -> Cell {
        Cell(id: key, wide: true, view: AnyView(VStack(alignment: .leading, spacing: 6) {
            label(key, title, required: false)
            TextField("", text: binding(key), prompt: Text(placeholder).foregroundStyle(ImportInk.placeholder), axis: .vertical)
                .textFieldStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.txt).lineLimit(4...10).lineSpacing(3)
                .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 88, alignment: .topLeading)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(box(key)).accessibilityLabel(title)
        }))
    }

    /// 下拉字段：必填时不给「未填写」选项。
    private func choice(_ key: String, _ title: String, _ options: [(String, String)], required: Bool = false) -> Cell {
        let value = form[key] ?? ""
        return Cell(id: key, wide: false, view: AnyView(VStack(alignment: .leading, spacing: 6) {
            label(key, title, required: required)
            Menu {
                if !required { Button("未填写") { form[key] = "" } }
                ForEach(options, id: \.0) { option in Button(option.1) { form[key] = option.0; error = nil } }
            } label: {
                HStack {
                    Text(options.first { $0.0 == value }?.1 ?? (required ? "请选择" : "未填写")).font(V3.sans(13)).foregroundStyle(value.isEmpty ? (missing(key) ? V3.orange : ImportInk.placeholder) : V3.txt)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(V3.fnt)
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(box(key)).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel(title)
        }))
    }

    /// 投递简历（必填）：一份简历都没有时引导去新建。
    private var resumeCell: Cell {
        Cell(id: "resume_id", wide: false, view: AnyView(VStack(alignment: .leading, spacing: 6) {
            label("resume_id", "投递简历", required: true)
            if resumes?.isEmpty == true {
                HStack(spacing: 8) {
                    Text("还没有简历").font(V3.sans(13)).foregroundStyle(V3.fnt)
                    Button("去新建") { cancel(); router?.jump(.section(.resumes)) }.buttonStyle(.plain).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.blue)
                }.frame(height: 38)
            } else {
                Menu {
                    ForEach(resumes ?? [], id: \.self) { item in Button(item.text("title")) { resumeID = item.text("id"); error = nil } }
                } label: {
                    HStack {
                        Text(resumes?.first { $0.text("id") == resumeID }?.text("title") ?? "请选择").font(V3.sans(13))
                            .foregroundStyle(resumeID.isEmpty ? ImportInk.placeholder : V3.txt).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(V3.fnt)
                    }
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.sk2)).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).disabled(resumes == nil).accessibilityLabel("投递简历")
            }
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
        HStack(spacing: 12) {
            if reviewing {
                Button { select(reviewSource ?? .text) } label: {
                    HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 11, weight: .medium)); Text("返回修改原文") }
                }.buttonStyle(.plain).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.blue).disabled(busy)
            } else if busy {
                Text("关闭弹窗会取消识别").font(V3.sans(12)).foregroundStyle(V3.fnt)
            } else {
                Button { installPlugin() } label: {
                    HStack(spacing: 4) { Text("用浏览器插件一键保存"); Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium)) }
                }.buttonStyle(.plain).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.blue).lineLimit(1)
            }
            Spacer(minLength: 8)
            if tab != .manual && !busy { Text("按实际用量消耗积分").font(V3.sans(12)).foregroundStyle(ImportInk.hint) }
            if !reviewing { Button("取消") { cancel() }.buttonStyle(ImportPillStyle(dark: false)).keyboardShortcut(.cancelAction) }
            Button(primaryLabel) { submit() }
                .buttonStyle(ImportPillStyle(dark: true)).disabled(busy)
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
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .webP]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "webp"].contains(ext) else { error = "仅支持 PNG、JPEG 或 WebP 图片。"; return }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 10 * 1024 * 1024 else { error = "图片不能超过 10 MiB。"; return }
        guard let data = try? Data(contentsOf: url) else { error = "截图读取失败，请重新选择。"; return }
        image = (data, url.lastPathComponent, ext == "png" ? "image/png" : ext == "webp" ? "image/webp" : "image/jpeg")
        preview = NSImage(data: data); error = nil
    }

    /// ⌘V：剪贴板里是文件就按文件读，是截图就转成 PNG。
    private func pasteImage() {
        guard tab == .image, !busy else { return }
        let board = NSPasteboard.general
        if let url = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first { load(url); return }
        var data = board.data(forType: .png)
        if data == nil, let tiff = board.data(forType: .tiff) { data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) }
        guard let data else { error = "剪贴板里没有截图。"; return }
        guard data.count <= 10 * 1024 * 1024 else { error = "图片不能超过 10 MiB。"; return }
        image = (data, "粘贴的截图.png", "image/png")
        preview = NSImage(data: data); error = nil
    }

    @discardableResult private func loadResumes() async -> [JSONValue]? {
        guard let items = try? await api.careerRequest(path: "/api/resumes", method: "GET", query: [:], body: nil)["resumes"]?.items else { return nil }
        resumes = items
        if items.count == 1 && resumeID.isEmpty { resumeID = items[0].text("id") }
        return items
    }

    private func parse() async {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 没有简历就建不了岗位，识别前先拦下，不白扣积分
        if resumes?.isEmpty == true { error = "导入岗位要先选一份投递简历，你还没有简历，请先新建。"; return }
        if tab == .image && image == nil { error = "请上传岗位截图。"; return }
        if tab == .text && normalized.isEmpty { error = "请输入岗位文字。"; return }
        if tab == .text && normalized.count > Self.limit { error = "岗位文字不能超过 60000 个字符。"; return }
        let source = tab
        // 带“职位：”“公司：”这类标注的文字先在本机识别，不调 AI、不扣积分；用户回来再点一次才走 AI。
        if source == .text, locallyParsed != normalized, let local = JobDraftParser.parse(normalized) {
            locallyParsed = normalized
            form = local
            recognized = Set(local.filter { !$0.value.isEmpty }.keys)
            warnings = ["已按文字里的标注在本机识别，没有调用 AI，也没有消耗积分。识别不全时回到「粘贴岗位文字」再点一次「确认导入」，会改用 AI 识别。"]
            reviewSource = source; tab = .manual; error = nil
            return
        }
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
        var required = [("job_title", "职位名称"), ("company_name", "公司名称"), ("employment_type", "求职分类")]
            .filter { (form[$0.0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.1)
        if resumeID.isEmpty && resumes != nil { required.append("投递简历") }
        if !required.isEmpty { error = "请先填写" + required.joined(separator: "、"); return }
        if resumeID.isEmpty {
            // 列表没读到：重读一次让用户选，不放行没绑简历的岗位
            error = await loadResumes() != nil ? "请先填写投递简历" : "简历列表加载失败，请稍后重试。"
            return
        }
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
        fields["resume_id"] = .string(resumeID)
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
        case "JD_IMPORT_IMAGE_UNSUPPORTED": return "仅支持 PNG、JPEG 或 WebP 图片。"
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
                    Text("安装岗位采集插件").font(V3.sans(20)).foregroundStyle(V3.txt).frame(height: 27)
                    Spacer(minLength: 12)
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(V3.fnt).frame(width: 24, height: 24).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("关闭插件安装说明")
                }
                Text("在招聘网站上一键把岗位存进投递看板 · 支持 Chrome / Edge").font(V3.sans(13)).foregroundStyle(V3.fnt).frame(height: 18).padding(.top, 6)
                HStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 18)).foregroundStyle(V3.txt)
                        .frame(width: 40, height: 40).background(V3.field, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DrawOffer 岗位采集插件").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
                        Text(stateText).font(V3.sans(12)).foregroundStyle(failed ? V3.red : ImportInk.hint).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if status == "available" {
                        Button { openWeb() } label: { Image(systemName: "arrow.down.to.line").font(.system(size: 12, weight: .medium)); Text("下载 ZIP") }
                            .buttonStyle(ImportPillStyle(dark: true))
                    }
                }
                .padding(.horizontal, 14).frame(height: 72)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ImportInk.divider))
                .padding(.top, 21)
                Text("下载后三步装好").font(V3.sans(12, weight: .medium)).foregroundStyle(V3.fnt).padding(.top, 20)
                VStack(alignment: .leading, spacing: 16) {
                    step("1", "解压到一个固定目录", Text("浏览器不能直接安装 ZIP；解压后别移动或删除这个目录。"))
                    step("2", "打开扩展管理页", Text("地址栏输入 chrome://extensions，Edge 输入 edge://extensions。"))
                    step("3", "加载并固定到工具栏", Text("打开「开发者模式」→「加载已解压的扩展程序」→ 选含 manifest.json 的目录，再把插件固定到工具栏。"))
                }.padding(.top, 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text("装好后怎么用").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                    Text("登录 DrawOffer → 打开 BOSS 直聘岗位详情页 → 点工具栏的插件图标，核对后「确认导入」，岗位就进「待投递」。插件不会自动投递。")
                        .font(V3.sans(12.5)).foregroundStyle(V3.fnt).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: 0xF6F6F4), in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 20)
            }.padding(.horizontal, 32).padding(.top, 29)
            Spacer(minLength: 0)
            Rectangle().fill(ImportInk.divider).frame(height: 1)
            HStack(spacing: 12) {
                Text("更新时覆盖原目录，再在扩展页点「重新加载」").font(V3.sans(12)).foregroundStyle(ImportInk.hint).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Button("完成", action: close).buttonStyle(ImportPillStyle(dark: false)).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 32).frame(height: 72)
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

    private func step(_ index: String, _ title: String, _ body: Text) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(index).font(.system(size: 11)).foregroundStyle(V3.fnt).frame(width: 21, height: 21)
                .overlay(Circle().stroke(V3.sk2)).padding(.top, 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).frame(height: 21, alignment: .leading)
                body.font(V3.sans(12.5)).foregroundStyle(V3.fnt).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
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

/// 03 弹窗里 Figma 直接取值的灰阶与分隔线（V3 令牌里没有的几档）。
private enum ImportInk {
    static let hint = Color(hex: 0x8A8A86)
    static let placeholder = Color(hex: 0xA8A8A4)
    static let divider = Color(hex: 0xE6E6E3)
}

/// 03 弹窗底栏的胶囊按钮：36 高、圆角 18；深色为墨黑实底，浅色为白底细边。
private struct ImportPillStyle: ButtonStyle {
    let dark: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return HStack(spacing: 6) { configuration.label }
            .font(V3.sans(13, weight: .medium)).lineLimit(1).fixedSize()
            .foregroundStyle(dark ? Color.white : V3.txt)
            .padding(.horizontal, 16).frame(height: 36)
            .background {
                if dark { Capsule().fill(pressed ? Color(hex: 0x0E0E0D) : V3.txt) }
                else { Capsule().fill(pressed ? V3.field : .white).overlay(Capsule().stroke(V3.sk2)) }
            }
            .opacity(enabled ? 1 : 0.38)
            .contentShape(Capsule())
    }
}
