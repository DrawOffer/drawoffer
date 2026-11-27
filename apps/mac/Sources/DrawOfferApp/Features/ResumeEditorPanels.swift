import DrawOfferCore
import SwiftUI

/// 编辑器的面板：模板栏（Web `WorkbenchTemplateRail`）、排版卡片（`WorkbenchTypeCard`，含模块顺序）与大纲。

// MARK: - 切换模板


struct TemplateSwitchSheet: View {
    @Environment(SessionStore.self) private var session
    let currentKey: String
    var disabled = false
    let apply: (ResumeTemplate) async -> String?
    let close: () -> Void
    /// 07.2 悬停预览：鼠标在一套上停 150ms 交给编辑器在纸面临时换成这套；移出整列传 nil 恢复。当前那套不预览。
    var preview: (ResumeTemplate?) -> Void = { _ in }

    @State private var templates: [ResumeTemplate] = []
    @State private var hovered: String?
    @State private var loading = true
    @State private var failed = false
    @State private var applying: String?
    @State private var error: String?
    @State private var styles: [String] = []
    @State private var uses: [String] = []

    private var filtered: [ResumeTemplate] {
        templates.filter {
            (styles.isEmpty || !Set(styles).isDisjoint(with: $0.styleCategories)) && (uses.isEmpty || !Set(uses).isDisjoint(with: $0.useCases))
        }
    }

    static func key(_ template: ResumeTemplate) -> String { template.style["template_key"]?.stringValue ?? template.key }

    /// 一次显示几套（07.1：先 20 套，滚到底再加 20 套）。
    @State private var shown = 20

    /// Figma 03 页 07.1：贴编辑器右边一整列（跟 Web 一样放右侧；343 宽、与画布同底色、左侧一条细线，内边距按稿左右镜像）。标题「换模板」14/500 + 一句说明，
    /// 下面一行「场景 全部 / 风格 全部」两个浅灰胶囊和总数；两列缩略图（134 宽、间距 16，名称 12，当前那套黑框 +「当前」），底部一行已显示几套。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("换模板").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                    Text("鼠标停在哪套，左边就先看哪套；点一下才换上").font(V3.sans(12)).foregroundStyle(Color(hex: 0x8F8F8A))
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(V3.fnt).accessibilityLabel("收起模板栏").padding(.top, -3)
            }.padding(.leading, 23).padding(.trailing, 35).padding(.top, 54)
            let ready = !loading && !failed && !templates.isEmpty
            if ready {
                HStack(spacing: 8) {
                    filterMenu("场景", TemplateFilter.useOptions, $uses)
                    filterMenu("风格", TemplateFilter.styleOptions, $styles)
                    Spacer()
                    Text("\(filtered.count) 套").font(V3.sans(11.5)).foregroundStyle(Color(hex: 0x96968F))
                }.padding(.leading, 23).padding(.trailing, 36).frame(height: 24).padding(.top, 20)
            }
            if let error { Text(error).font(V3.sans(12)).foregroundStyle(V3.red).padding(.leading, 23).padding(.trailing, 36).padding(.top, 8) }
            if loading { V3Loading("正在加载简历模板…").font(V3.sans(12)).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if failed {
                state("模板暂时无法加载", "请检查网络后重试，当前简历不会受到影响。") {
                    Button { Task { await load() } } label: { Label("重新加载", systemImage: "arrow.clockwise") }.buttonStyle(V3ButtonStyle(kind: .ghost, height: 30))
                }
            } else if templates.isEmpty {
                state("当前没有可用模板", "模板启用后会显示在这里。") { EmptyView() }
            } else if filtered.isEmpty {
                state("没有符合条件的模板", "试试减少一个筛选条件。") {
                    Button("清除筛选") { styles = []; uses = [] }.buttonStyle(V3ButtonStyle(kind: .ghost, height: 30))
                }
            } else {
                let visible = Array(filtered.prefix(shown))
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.fixed(134), spacing: 16), GridItem(.fixed(134), spacing: 16)], alignment: .leading, spacing: 16) {
                            ForEach(visible) { template in
                                card(template).id(template.id)
                                    .onAppear { if template.id == visible.last?.id, shown < filtered.count { shown += 20 } }
                            }
                        }.padding(.leading, 23).padding(.top, 16).padding(.bottom, 16)
                        Text(visible.count < filtered.count ? "已显示 \(visible.count) / \(filtered.count) 套 · 滚到底自动加载下 20 套" : "共 \(filtered.count) 套")
                            .font(V3.sans(12)).foregroundStyle(Color(hex: 0x8F8F8A)).frame(maxWidth: .infinity).padding(.bottom, 24)
                    }.scrollIndicators(.never)
                    // 打开时把当前模板滚到可视区中间
                    .onAppear {
                        if let index = filtered.firstIndex(where: { Self.key($0) == currentKey }) {
                            shown = max(shown, index + 1)
                            proxy.scrollTo(filtered[index].id, anchor: .center)
                        }
                    }
                }
                .onChange(of: styles) { shown = 20 }
                .onChange(of: uses) { shown = 20 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        // 移出整列才恢复原纸面；在两张卡之间移动不闪回
        .onHover { inside in if !inside { hovered = nil; preview(nil) } }
        .task { await load() }
    }

    private func hover(_ template: ResumeTemplate, _ inside: Bool) {
        guard inside else { if hovered == template.id { hovered = nil }; return }
        hovered = template.id
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard hovered == template.id, applying == nil, !disabled else { return }
            preview(Self.key(template) == currentKey ? nil : template)
        }
    }

    /// 07.1 筛选：「场景 全部」「风格 全部」两个无边框下拉，单选；灰字标签 + 墨黑当前值。
    private func filterMenu(_ title: String, _ options: [String], _ values: Binding<[String]>) -> some View {
        Menu {
            Button("全部") { values.wrappedValue = [] }
            Divider()
            ForEach(options, id: \.self) { option in
                Button { values.wrappedValue = [option] } label: {
                    if values.wrappedValue == [option] { Label(option, systemImage: "checkmark") } else { Text(option) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(Color(hex: 0x96968F))
                Text(values.wrappedValue.first ?? "全部").fontWeight(.medium).foregroundStyle(V3.txt)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(V3.fnt)
            }.font(V3.sans(11.5)).padding(.leading, 10).padding(.trailing, 8).frame(height: 24)
                .background(V3.field, in: Capsule()).contentShape(Capsule())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel(title)
    }

    /// `.workbench-template-state`：最少 190 高、居中；标题 13/500 txt，说明 12px fnt，间距 8。
    private func state<Action: View>(_ title: String, _ detail: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 8) {
            Text(title).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
            Text(detail).font(V3.sans(12)).foregroundStyle(V3.fnt).padding(.bottom, 6)
            action()
        }.frame(maxWidth: .infinity, minHeight: 190).padding(.horizontal, 24).padding(.top, 16)
    }

    /// 07.1 模板卡：132 宽 A4 缩略图（当前那套 1.5 墨黑框），下方名称 12（当前 500）与灰字「当前」；应用中盖 70% 白与转圈。
    private func card(_ template: ResumeTemplate) -> some View {
        let current = Self.key(template) == currentKey
        return Button { Task { await choose(template) } } label: {
            VStack(alignment: .leading, spacing: 7) {
                TemplateThumbnail(template: template, radius: 4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(current ? V3.txt : hovered == template.id ? Color(hex: 0xC9C9C4) : .clear,
                                                                       lineWidth: current ? 1.5 : 1))
                    .overlay { if applying == template.id { ZStack { Color.white.opacity(0.7); ProgressView().controlSize(.small) }.clipShape(RoundedRectangle(cornerRadius: 4)) } }
                HStack(spacing: 6) {
                    Text(template.name).font(V3.sans(12, weight: current ? .medium : .regular)).foregroundStyle(current ? V3.txt : V3.sub).lineLimit(1)
                    if current { Text("当前").font(V3.sans(10.5)).foregroundStyle(Color(hex: 0x96968F)) }
                }.frame(height: 16)
            }.frame(width: 134).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled || applying != nil)
            .onHover { hover(template, $0) }
            .accessibilityLabel(current ? "\(template.name)（当前模板）" : "应用模板：\(template.name)")
            .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func choose(_ template: ResumeTemplate) async {
        guard Self.key(template) != currentKey else { return }
        applying = template.id; error = nil
        error = await apply(template)
        applying = nil
    }

    private func load() async {
        loading = true; failed = false
        defer { loading = false }
        do { templates = try await session.api.listResumeTemplates().filter { !ResumeRequest.retiredTemplateKeys.contains($0.key) } }
        catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            failed = true
        }
    }
}

// MARK: - 排版卡片

/// Figma 06.2「排版卡片 · NSPopover」：从纸面上沿左边的规格行点开，320 宽、圆角 10 的白色弹出层，箭头指向规格行。
/// 从上到下：页面（共 N 页 + 智能一页）→ 模块顺序（拖动 ⠿ 调整，悬停 ⋯ 重命名 / 删除）→ 文字（字体分组下拉、字号、行距滑块）→ 页边距（上下、左右滑块）。
/// 与 Web `WorkbenchTypeCard` 相同：没有页面排列，模块顺序收在这里。
struct TypeCard: View {
    @Binding var settings: ResumeTypeSettings
    let pageCount: Int
    let sections: [JSONValue]
    /// node_id → "sidebar" / "main"；单栏模板为空。
    let columns: [String: String]
    let label: (JSONValue) -> String
    let disabled: Bool
    let reorder: ([JSONValue]) -> Void
    let rename: (String, String) -> Void
    let remove: (String) -> Void

    @State private var dragging: String?
    @State private var hovered: String?
    @State private var renaming: String?
    @State private var renameText = ""
    /// 刚改过名的模块：列表里先显示新名字（纸面回报后正文同步）。
    @State private var titles: [String: String] = [:]
    @FocusState private var renameFocused: Bool

    private static let gray = Color(hex: 0x96968F)
    /// Web `FONT_GROUPS`：黑体 / 宋体 / 楷体；只列出本机字体表里已有的。
    private static let fontGroups: [(title: String, names: [String])] = [
        ("黑体", ["系统黑体", "思源黑体", "寒蝉端黑体", "霞鹜975黑体", "霞鹜975圆体", "未来荧黑"]),
        ("宋体", ["思源宋体", "寒蝉端黑宋", "寒蝉锦书宋", "朱雀仿宋"]),
        ("楷体", ["霞鹜文楷", "霞鹜文楷 GB", "霞鹜臻楷", "寒蝉正楷体", "霞鹜 Bright"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            pageSection
            if !sections.isEmpty { orderSection }
            textSection
            marginSection
        }
        // 06.2 `.wbs-card`：白底、#e4e4e0 细边、圆角 14、浅阴影，内边距上 18 左右下 20
        .padding(.top, 18).padding(.horizontal, 20).padding(.bottom, 20).frame(width: 320)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(V3.cl))
        .shadow(color: Color(hex: 0x1D1D1B).opacity(0.08), radius: 12, y: 6)
        .disabled(disabled)
    }

    private func head<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
            Spacer(minLength: 8)
            trailing()
        }.frame(height: 16)
    }

    // MARK: 页面

    private var pageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            head("页面") { Text("共 \(pageCount) 页").font(V3.sans(11.5)).foregroundStyle(Self.gray) }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("智能一页").font(V3.sans(12.5)).foregroundStyle(V3.sub)
                    Text(settings.smartOnePage ? "内容超出一页时自动收紧字号和间距" : "内容超出一页时收进一页")
                        .font(V3.sans(11.5)).foregroundStyle(Self.gray).lineLimit(1)
                }
                Spacer(minLength: 0)
                Toggle("智能一页", isOn: $settings.smartOnePage).toggleStyle(.switch).labelsHidden().tint(V3.txt)
            }
        }
    }

    // MARK: 模块顺序

    private var isDefaultOrder: Bool {
        ResumeSectionOrder.restoreDefault(sections).map(\.nodeKey) == sections.map(\.nodeKey)
    }

    private var orderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            head("模块顺序") {
                Button("恢复默认顺序") { reorder(ResumeSectionOrder.restoreDefault(sections)) }
                    .buttonStyle(.plain).font(V3.sans(11.5)).foregroundStyle(isDefaultOrder ? V3.fnt2 : Self.gray).disabled(isDefaultOrder)
            }
            VStack(alignment: .leading, spacing: 2) {
                if columns.isEmpty {
                    ForEach(sections, id: \.nodeKey) { row($0) }
                } else {
                    ForEach(["sidebar", "main"], id: \.self) { side in
                        let group = sections.filter { (columns[$0.nodeKey] ?? "main") == side }
                        if !group.isEmpty {
                            Text(side == "sidebar" ? "侧栏" : "主栏").font(V3.sans(11)).foregroundStyle(Self.gray)
                                .padding(.horizontal, 4).padding(.top, 4)
                            ForEach(group, id: \.nodeKey) { row($0) }
                        }
                    }
                }
            }
        }
    }

    /// 一行 32 高、圆角 8、悬停 #f4f4f1；左边 ⠿ 拖动手柄，文字 13（空模块灰字）。
    private func row(_ section: JSONValue) -> some View {
        let key = section.nodeKey
        let title = titles[key] ?? label(section)
        let hover = hovered == key
        return HStack(spacing: 10) {
            Image(systemName: "circle.grid.2x3.fill").font(.system(size: 8)).foregroundStyle(Color(hex: 0xBEBEB8))
                .frame(width: 14, height: 24)
            if renaming == key {
                TextField("模块名称", text: $renameText).textFieldStyle(.plain).font(V3.sans(13)).focused($renameFocused)
                    .onSubmit { commitRename(key) }
                    .onExitCommand { renaming = nil }
                    .onAppear { renameFocused = true }
                    .onChange(of: renameFocused) { _, focused in if !focused && renaming == key { commitRename(key) } }
            } else {
                Text(title).font(V3.sans(13)).foregroundStyle(ResumeOutline.isEmpty(section) ? Self.gray : V3.txt).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hover && renaming != key { rowMenu(key, title) }
        }
        .padding(.leading, 4).padding(.trailing, 6).frame(height: 32)
        .background(hover ? Color(hex: 0xF4F4F1) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { inside in if inside { hovered = key } else if hovered == key { hovered = nil } }
        .onDrag { dragging = key; return NSItemProvider(object: key as NSString) }
        .onDrop(of: [.text], isTargeted: nil) { _ in drop(onto: key) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)，拖动调整顺序")
    }

    private func rowMenu(_ key: String, _ title: String) -> some View {
        Menu {
            Button { renameText = title; renaming = key } label: { Label("重命名", systemImage: "pencil") }
            Button(role: .destructive) { remove(key) } label: { Label("删除模块", systemImage: "trash") }
            Text("连同内容一起删除，可 ⌘Z 撤销")
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .medium)).foregroundStyle(V3.fnt)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("「\(title)」更多操作")
    }

    private func commitRename(_ key: String) {
        let value = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !value.isEmpty else { return }
        titles[key] = value
        rename(key, value)
    }

    /// 放到哪一行就换到那一行的位置；双栏模板只能在同一栏内移动。
    private func drop(onto target: String) -> Bool {
        defer { dragging = nil }
        guard let from = dragging, from != target,
              let source = sections.firstIndex(where: { $0.nodeKey == from }),
              let destination = sections.firstIndex(where: { $0.nodeKey == target }) else { return false }
        if !columns.isEmpty, (columns[from] ?? "main") != (columns[target] ?? "main") { return false }
        var list = sections
        let moved = list.remove(at: source)
        list.insert(moved, at: destination)
        reorder(list)
        return true
    }

    // MARK: 文字

    private var fontLabel: String {
        ResumeTypeSettings.fonts.first { $0.value == settings.fontFamily }?.label ?? ResumeTypeSettings.fonts[0].label
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            head("文字") { EmptyView() }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("字体").font(V3.sans(12.5)).foregroundStyle(V3.txt)
                    Spacer()
                    fontMenu
                }.frame(height: 28)
                slider("字号", unit: "pt", value: $settings.fontSize, range: ResumeTypeSettings.fontSizeRange, digits: nil)
                slider("行距", unit: "", value: $settings.lineHeight, range: ResumeTypeSettings.lineHeightRange, digits: 2)
            }
        }
    }

    /// 只有字体名那么宽的分组列表（黑体 / 宋体 / 楷体），当前字体打勾。
    private var fontMenu: some View {
        Menu {
            ForEach(Self.fontGroups, id: \.title) { group in
                let items = group.names.compactMap { name in ResumeTypeSettings.fonts.first { $0.label == name } }
                if !items.isEmpty {
                    Section(group.title) {
                        ForEach(items, id: \.value) { font in
                            Button { settings.fontFamily = font.value } label: {
                                if font.value == settings.fontFamily { Label(font.label, systemImage: "checkmark") } else { Text(font.label) }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(fontLabel).font(V3.sans(12.5)).foregroundStyle(V3.txt).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(Self.gray)
            }.contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("字体")
    }

    // MARK: 页边距

    private var marginSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            head("页边距") { EmptyView() }
            VStack(alignment: .leading, spacing: 4) {
                slider("上下", unit: "mm", value: $settings.verticalPageMargin, range: ResumeTypeSettings.verticalMarginRange, digits: nil)
                slider("左右", unit: "mm", value: $settings.pageMargin, range: ResumeTypeSettings.horizontalMarginRange, digits: nil)
            }
        }
    }

    /// 一行 24 高：标签 12.5（灰）、系统滑块（墨黑）、右侧数值 12.5/500 + 单位 11 灰字，数值列 56 宽右对齐。
    private func slider(_ title: String, unit: String, value: Binding<Double>, range: (min: Double, max: Double, step: Double), digits: Int?) -> some View {
        let snapped = Binding<Double>(
            get: { value.wrappedValue },
            set: { raw in
                let next = ResumeTypeSettings.step(raw, by: 0, min: range.min, max: range.max, step: range.step)
                if next != value.wrappedValue { value.wrappedValue = next }
            })
        let text = digits.map { String(format: "%.\($0)f", value.wrappedValue) } ?? String(format: "%g", (value.wrappedValue * 100).rounded() / 100)
        return HStack(spacing: 8) {
            Text(title).font(V3.sans(12.5)).foregroundStyle(V3.sub).frame(width: 30, alignment: .leading)
            Slider(value: snapped, in: range.min...range.max, step: range.step).tint(V3.txt).controlSize(.small).accessibilityLabel(title)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(text).font(V3.number(12.5, weight: .medium)).foregroundStyle(V3.txt)
                if !unit.isEmpty { Text(unit).font(V3.sans(11)).foregroundStyle(Self.gray) }
            }.frame(width: 56, alignment: .trailing).accessibilityLabel("\(title)当前值")
        }.frame(height: 24)
    }
}

extension JSONValue {
    /// 列表标识：canonical 节点的 node_id。
    var nodeKey: String { text("node_id") }
}
