import DrawOfferCore
import SwiftUI

/// 编辑器的三个面板，对应 Web 的 `WorkbenchTemplatePanel`、`WorkbenchTypePanel` 与 `WorkbenchSectionOrderControl`。

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

    /// Figma 03 页 07.1：贴编辑器左边一整列（356 宽、白底、右侧细线）。标题「换模板」14/500 + 一句说明，
    /// 下面一行「场景 全部 / 风格 全部」下拉和总数；两列缩略图（名称 12，当前那套黑框 +「当前」），底部一行已显示几套。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("换模板").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                    Text("鼠标停在哪套，右边就先看哪套；点一下才换上").font(V3.sans(12)).foregroundStyle(Color(hex: 0x8F8F8A))
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(V3.fnt).accessibilityLabel("收起模板栏").padding(.top, -3)
            }.padding(.horizontal, 36).padding(.top, 54)
            let ready = !loading && !failed && !templates.isEmpty
            if ready {
                HStack(spacing: 18) {
                    filterMenu("场景", TemplateFilter.useOptions, $uses)
                    filterMenu("风格", TemplateFilter.styleOptions, $styles)
                    Spacer()
                    Text("\(filtered.count) 套").font(V3.sans(11.5)).foregroundStyle(Color(hex: 0x96968F))
                }.padding(.leading, 46).padding(.trailing, 36).frame(height: 30).padding(.top, 20)
            }
            if let error { Text(error).font(V3.sans(12)).foregroundStyle(V3.red).padding(.horizontal, 36).padding(.top, 8) }
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
                        LazyVGrid(columns: [GridItem(.fixed(132), spacing: 18), GridItem(.fixed(132), spacing: 18)], alignment: .leading, spacing: 18) {
                            ForEach(visible) { template in
                                card(template).id(template.id)
                                    .onAppear { if template.id == visible.last?.id, shown < filtered.count { shown += 20 } }
                            }
                        }.padding(.horizontal, 36).padding(.top, 14).padding(.bottom, 16)
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
            }.font(V3.sans(11.5)).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(title)
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
            VStack(alignment: .leading, spacing: 8) {
                TemplateThumbnail(template: template, guest: false)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(current ? V3.txt : hovered == template.id ? Color(hex: 0xB9B9B2) : .clear,
                                                                       lineWidth: current ? 1.5 : 1))
                    .overlay { if applying == template.id { ZStack { Color.white.opacity(0.7); ProgressView().controlSize(.small) }.clipShape(RoundedRectangle(cornerRadius: 6)) } }
                HStack(spacing: 6) {
                    Text(template.name).font(V3.sans(12, weight: current ? .medium : .regular)).foregroundStyle(current ? V3.txt : V3.sub).lineLimit(1)
                    if current { Text("当前").font(V3.sans(10.5)).foregroundStyle(Color(hex: 0x96968F)) }
                }.frame(height: 16)
            }.frame(width: 132).contentShape(Rectangle())
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

// MARK: - 版式设置

/// Web `WorkbenchTypePanel` + `WorkbenchPageBar`：页面排列（上下 / 左右 / 智能一页）、页边距（两个整行步进器）、
/// 排版（字体下拉、正文字号、正文行距）。步进器控件 116 宽，28×28 描边按钮，数字 12/500。
struct TypeSettingsPanel: View {
    @Binding var settings: ResumeTypeSettings
    @Binding var arrangement: String
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("页面排列", "选择多页简历在编辑区中的浏览方式。")
            HStack(spacing: 8) {
                option("上下排列", symbol: "rectangle.split.1x2", on: !settings.smartOnePage && arrangement == "vertical") {
                    if settings.smartOnePage { settings.smartOnePage = false }; arrangement = "vertical"
                }
                option("左右排列", symbol: "rectangle.split.2x1", on: !settings.smartOnePage && arrangement == "horizontal") {
                    if settings.smartOnePage { settings.smartOnePage = false }; arrangement = "horizontal"
                }
                option("智能一页", symbol: "doc.text", on: settings.smartOnePage) { settings.smartOnePage.toggle() }
                    .accessibilityAddTraits(.isToggle)
            }
            Text("排列只影响编辑时的浏览方向。").font(V3.sans(11)).foregroundStyle(V3.fnt).frame(height: 22).padding(.top, 10)
            divider
            section("页边距", "分别调整上下和左右留白，单位为毫米。")
            VStack(spacing: 16) {
                stepper("上下边距", unit: "mm", value: $settings.verticalPageMargin, range: ResumeTypeSettings.verticalMarginRange)
                stepper("左右边距", unit: "mm", value: $settings.pageMargin, range: ResumeTypeSettings.horizontalMarginRange)
            }
            divider
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) { Image(systemName: "textformat").font(.system(size: 13)).foregroundStyle(V3.blue); Text("排版").font(V3.sans(13, weight: .medium)) }.frame(height: 22)
                Text("统一调整简历正文的字体、字号和行距。").font(V3.sans(11)).foregroundStyle(V3.fnt).frame(height: 22)
            }.padding(.bottom, 13)
            HStack(spacing: 16) {
                Text("字体").font(V3.sans(11, weight: .medium)).foregroundStyle(V3.sub)
                Spacer()
                Menu {
                    ForEach(ResumeTypeSettings.fonts, id: \.value) { font in Button(font.label) { settings.fontFamily = font.value } }
                } label: {
                    HStack { Spacer(); Text(fontLabel).font(V3.sans(13)).foregroundStyle(V3.txt).lineLimit(1); Spacer() }
                        .overlay(alignment: .trailing) { Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(V3.sub).padding(.trailing, 8) }
                        .frame(width: 116, height: 40).background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
                        .contentShape(Rectangle())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("字体")
            }.frame(height: 40).padding(.top, 15).padding(.bottom, 20)
            VStack(spacing: 16) {
                stepper("正文字号", unit: "pt", value: $settings.fontSize, range: ResumeTypeSettings.fontSizeRange)
                stepper("正文行距", unit: "", value: $settings.lineHeight, range: ResumeTypeSettings.lineHeightRange)
            }
        }
        .padding(.horizontal, 24).padding(.top, 23).padding(.bottom, 24).disabled(disabled)
    }

    private var fontLabel: String { ResumeTypeSettings.fonts.first { $0.value == settings.fontFamily }?.label ?? ResumeTypeSettings.fonts[0].label }
    private var divider: some View { Rectangle().fill(V3.line).frame(height: 1).padding(.top, 21).padding(.bottom, 23) }

    private func section(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).frame(height: 22)
            Text(detail).font(V3.sans(11)).foregroundStyle(V3.fnt).frame(height: 22)
        }.padding(.bottom, 13)
    }

    /// `.wb3-arrangement-options button`：描边 #ececea、圆角 8、内边距 12/4、12/500；图标 46×44 小框；选中蓝边蓝底蓝字。
    private func option(_ label: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18)).frame(width: 46, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? V3.blue.opacity(0.4) : V3.line))
                Text(label).font(V3.sans(12, weight: .medium)).frame(height: 19)
            }
            .foregroundStyle(on ? V3.blue : V3.sub).padding(.horizontal, 4).padding(.vertical, 12).frame(maxWidth: .infinity).frame(height: 99)
            .background(on ? V3.blueSoft : .white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? V3.blue : V3.line))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(on ? .isSelected : [])
    }

    private func stepper(_ label: String, unit: String, value: Binding<Double>, range: (min: Double, max: Double, step: Double)) -> some View {
        HStack(spacing: 8) {
            Text(label).font(V3.sans(12)).foregroundStyle(V3.sub)
            Spacer()
            HStack(spacing: 6) {
                stepButton("minus", "减小\(label)", value.wrappedValue <= range.min) {
                    value.wrappedValue = ResumeTypeSettings.step(value.wrappedValue, by: -1, min: range.min, max: range.max, step: range.step)
                }
                Text("\(String(format: "%g", (value.wrappedValue * 100).rounded() / 100))\(unit.isEmpty ? "" : " \(unit)")")
                    .font(V3.number(12, weight: .medium)).foregroundStyle(V3.txt).frame(minWidth: 48).frame(maxWidth: .infinity)
                    .accessibilityLabel("\(label)当前值")
                stepButton("plus", "增大\(label)", value.wrappedValue >= range.max) {
                    value.wrappedValue = ResumeTypeSettings.step(value.wrappedValue, by: 1, min: range.min, max: range.max, step: range.step)
                }
            }.frame(width: 116)
        }.frame(height: 28)
    }

    private func stepButton(_ symbol: String, _ label: String, _ off: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(V3.sub)
                .frame(width: 28, height: 28).background(.white, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(V3.line))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(off).opacity(off ? 0.4 : 1).accessibilityLabel(label)
    }
}

// MARK: - 板块顺序

struct SectionOrderSheet: View {
    let sections: [JSONValue]
    /// node_id → "sidebar" / "main"；单栏模板为空。
    let columns: [String: String]
    let apply: ([JSONValue]) -> Void
    let close: () -> Void
    /// 重命名 / 删除整个模块（Web 排版卡片“模块顺序”每行的 ⋯ 菜单）：立即改在纸上，可 ⌘Z 撤销。
    var rename: (String, String) -> Void = { _, _ in }
    var remove: (String) -> Void = { _ in }
    @State private var order: [JSONValue] = []
    /// 改过名的模块：列表里先显示新名字（纸面回报后正文同步）。
    @State private var titles: [String: String] = [:]
    @State private var renaming: String?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("调整板块顺序").font(V3.sans(16, weight: .medium))
                    Text(columns.isEmpty ? "拖动排序，个人信息固定在最前" : "拖动排序；双栏模板中各栏分别排序，个人信息固定在最前").font(V3.sans(12)).foregroundStyle(V3.sub)
                }
                Spacer()
            }.padding(20)
            List {
                Label("个人信息", systemImage: "lock").foregroundStyle(V3.fnt)
                if columns.isEmpty {
                    ForEach(order, id: \.nodeKey) { row($0) }
                        .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                } else {
                    ForEach(["sidebar", "main"], id: \.self) { side in
                        let group = order.filter { (columns[$0.text("node_id")] ?? "main") == side }
                        if !group.isEmpty {
                            Section(side == "sidebar" ? "侧栏" : "主栏") {
                                ForEach(group, id: \.nodeKey) { row($0) }
                                    .onMove { move(side, from: $0, to: $1) }
                            }
                        }
                    }
                }
            }.frame(minHeight: 300)
            HStack {
                Button("恢复默认顺序") { order = ResumeSectionOrder.restoreDefault(order) }.buttonStyle(.link)
                Spacer()
                Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost))
                Button("应用") { apply(order); close() }.buttonStyle(V3ButtonStyle(kind: .dark)).keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 440, height: 520).onAppear { order = sections }
    }

    private func row(_ section: JSONValue) -> some View {
        let kind = ResumeDocument.sectionKinds.first { $0.key == section.text("semantic_kind") }?.label ?? "模块"
        let key = section.nodeKey
        let title = titles[key] ?? ResumeDocument.value(section["title"])
        let shown = title.isEmpty ? kind : title
        return HStack {
            Image(systemName: "line.3.horizontal").foregroundStyle(V3.fnt)
            if renaming == key {
                TextField("模块名称", text: $renameText).textFieldStyle(.plain).font(V3.sans(13)).focused($renameFocused)
                    .onSubmit { commitRename(key) }
                    .onExitCommand { renaming = nil }
                    .onAppear { renameFocused = true }
                    .onChange(of: renameFocused) { _, focused in if !focused && renaming == key { commitRename(key) } }
            } else {
                Text(shown).font(V3.sans(13))
            }
            Spacer()
            if !title.isEmpty && title != kind && renaming != key { Text(kind).font(V3.sans(11)).foregroundStyle(V3.fnt) }
            Menu {
                Button { renameText = shown; renaming = key } label: { Label("重命名", systemImage: "pencil") }
                Button(role: .destructive) {
                    order.removeAll { $0.nodeKey == key }
                    remove(key)
                } label: { Label("删除模块", systemImage: "trash") }
                Text("连同内容一起删除，可 ⌘Z 撤销")
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).foregroundStyle(V3.fnt).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("「\(shown)」更多操作")
        }
    }

    private func commitRename(_ key: String) {
        let value = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !value.isEmpty else { return }
        titles[key] = value
        rename(key, value)
    }

    /// 只在同一栏内移动：把该栏的新顺序写回它原来占据的位置。
    private func move(_ side: String, from: IndexSet, to: Int) {
        let positions = order.indices.filter { (columns[order[$0].text("node_id")] ?? "main") == side }
        var group = positions.map { order[$0] }
        group.move(fromOffsets: from, toOffset: to)
        for (position, section) in zip(positions, group) { order[position] = section }
    }
}

extension JSONValue {
    /// 列表标识：canonical 节点的 node_id。
    var nodeKey: String { text("node_id") }
}


/// 大纲面板（Web `WorkbenchOutlinePanel`）：模块列表，点击跳转，上下移动，删除（可撤销），添加模块；
/// 双栏模板按左栏在上、右栏在下分组。
/// 大纲 V2（Web `WorkbenchOutlinePanel` + `WorkbenchSectionOrderControl`）：头部、「N 个模块 / 恢复默认顺序」、
/// 按栏分组的两行模块行（拖动手柄、标题、摘要、空标签、悬停 ⋯ 菜单），虚线「添加模块」与底部 / 提示。
/// 个人信息固定在第一行，不能拖动。原生端没有分页信息，不显示 Web 的页面缩略图条。
struct OutlinePanel: View {
    let sections: [JSONValue]
    let identity: JSONValue?
    let label: (JSONValue) -> String
    let columns: [String: String]
    let disabled: Bool
    let jump: (String) -> Void
    let move: (Int, Int) -> Void
    let reorder: ([JSONValue]) -> Void
    let rename: (Int, String) -> Void
    let remove: (Int) -> Void
    let add: ((key: String, label: String)) -> Void
    let close: () -> Void
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var adding = false
    @State private var dragging: String?

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchPanelHeader(title: "大纲", subtitle: "拖动调整顺序，点击定位到正文", closeLabel: "关闭大纲", close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("\(sections.count + 1) 个模块")
                        Spacer()
                        Button("恢复默认顺序") { reorder(ResumeSectionOrder.restoreDefault(sections)) }
                            .buttonStyle(.plain).font(V3.sans(11.5, weight: .medium)).foregroundStyle(disabled ? V3.fnt2 : V3.sub).disabled(disabled)
                    }
                    .font(V3.sans(11.5)).foregroundStyle(V3.fnt).frame(height: 14).padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 6)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                if !group.title.isEmpty {
                                    HStack(spacing: 6) {
                                        ColumnGlyph(left: group.title == "侧栏")
                                        Text(group.title).font(V3.sans(11.5, weight: .medium)).foregroundStyle(V3.sub)
                                    }.padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
                                }
                                VStack(spacing: 2) {
                                    if group.first { identityRow }
                                    ForEach(group.indices, id: \.self) { index in sectionRow(index) }
                                }
                            }
                        }
                    }
                    addButton.padding(.top, 10)
                }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 20)
            }
            HStack(spacing: 6) {
                Text("也可在正文空行输入")
                Text("/").font(V3.number(11, weight: .semibold)).foregroundStyle(V3.txt).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.white, in: RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).stroke(V3.cl))
                Text("选「标题 2」新建模块")
            }
            .font(V3.sans(11)).foregroundStyle(V3.fnt).lineLimit(1).padding(.horizontal, 24).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
        }
    }

    private var groups: [(title: String, indices: [Int], first: Bool)] {
        guard !columns.isEmpty else { return [("", Array(sections.indices), true)] }
        let side = sections.indices.filter { columns[sections[$0].nodeKey] == "sidebar" }
        let main = sections.indices.filter { columns[sections[$0].nodeKey] != "sidebar" }
        return [("侧栏", side, true), ("主栏", main, false)].filter { !$0.1.isEmpty || $0.2 }
    }

    /// 个人信息：锁图标、「固定」，摘要是已填的联系方式。
    private var identityRow: some View {
        OutlineRow(title: "个人信息", summary: ResumeOutline.identitySummary(identity), empty: false,
                   fixed: true, current: false, dragging: false, disabled: disabled, renaming: nil,
                   handle: { EmptyView() }, menu: { EmptyView() }, open: { jump("identity") })
    }

    private func sectionRow(_ index: Int) -> some View {
        let section = sections[index], title = label(section), key = section.nodeKey
        let empty = ResumeOutline.isEmpty(section)
        return OutlineRow(title: title, summary: ResumeOutline.summary(section),
                          empty: empty, fixed: false, current: false, dragging: dragging == key, disabled: disabled,
                          renaming: renaming == key ? $renameText : nil,
                          handle: {
                              Image(systemName: "line.3.horizontal").font(.system(size: 11)).frame(width: 20, height: 34).contentShape(Rectangle())
                                  .accessibilityLabel("调整「\(title)」顺序，可用上下方向键移动")
                                  .accessibilityAction(named: "上移") { if index > 0 { move(index, index - 1) } }
                                  .accessibilityAction(named: "下移") { if index < sections.count - 1 { move(index, index + 1) } }
                                  .onDrag { dragging = key; return NSItemProvider(object: key as NSString) }
                          },
                          menu: {
                              Menu {
                                  Button { renameText = title; renaming = key } label: { Label("重命名", systemImage: "pencil") }
                                  Button { jump(key) } label: { Label("定位到正文", systemImage: "scope") }
                                  Divider()
                                  Button(role: .destructive) { remove(index) } label: { Label("删除模块", systemImage: "trash") }
                                  Text("连同内容一起删除，可 ⌘Z 撤销")
                              } label: { Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 22, height: 22) }
                                  .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("「\(title)」更多操作")
                          },
                          open: { jump(key) }, commitRename: { value in
                              renaming = nil
                              if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty { rename(index, value.trimmingCharacters(in: .whitespaces)) }
                          })
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let from = sections.firstIndex(where: { $0.nodeKey == dragging }), from != index else { dragging = nil; return false }
            move(from, index); dragging = nil; return true
        }
    }

    /// `.wb3-outline-add`：37 高虚线框、圆角 10、12.5/500；弹层 332 宽，「还可以添加」与未出现的常用模块、自定义模块与说明。
    private var addButton: some View {
        Button { adding = true } label: {
            HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 11, weight: .medium)); Text("添加模块") }
                .font(V3.sans(12.5, weight: .medium)).foregroundStyle(disabled ? V3.fnt2 : adding ? V3.txt : V3.sub)
                .frame(maxWidth: .infinity).frame(height: 37)
                .background(adding ? Color(hex: 0xFAFAF9) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(adding ? V3.fnt : V3.fnt2, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled || sections.count >= 100)
        .popover(isPresented: $adding, arrowEdge: .top) {
            let present = Set(sections.map { $0.text("semantic_kind") })
            let options = ResumeOutline.moduleOptions.filter { !present.contains($0.kind) }
            VStack(alignment: .leading, spacing: 0) {
                if !options.isEmpty {
                    Text("还可以添加").font(V3.sans(11)).foregroundStyle(V3.fnt).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
                    ForEach(options, id: \.kind) { option in
                        Button { adding = false; add((option.kind, option.title)) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.title).font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.txt).frame(height: 17)
                                Text(option.hint).font(V3.sans(11)).foregroundStyle(V3.fnt).frame(height: 14)
                            }.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(MenuRowStyle())
                    }
                    Rectangle().fill(V3.line).frame(height: 1).padding(.vertical, 2)
                }
                Button { adding = false; add(("custom", "新模块")) } label: {
                    HStack(spacing: 8) { Image(systemName: "plus").font(.system(size: 11)); Text("自定义模块") }
                        .font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.sub)
                        .padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(MenuRowStyle())
                Text("新模块插入到光标所在模块之后，可再拖动调整").font(V3.sans(10.5)).foregroundStyle(V3.fnt).lineHeight(10.5, 15)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }.padding(6).frame(width: 332)
        }
    }
}

/// 一行模块：最小 52 高、圆角 10、内边距 9/10/9/8、间距 8；标题 13 行高 16，摘要 11 行高 13；悬停 #fafaf9，⋯ 只在悬停时出现并替换标签。
private struct OutlineRow<Handle: View, MenuView: View>: View {
    let title: String
    let summary: String
    let empty: Bool
    let fixed: Bool
    let current: Bool
    let dragging: Bool
    let disabled: Bool
    let renaming: Binding<String>?
    @ViewBuilder let handle: () -> Handle
    @ViewBuilder let menu: () -> MenuView
    let open: () -> Void
    var commitRename: (String?) -> Void = { _ in }
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if fixed { Image(systemName: "lock").font(.system(size: 11)).frame(width: 20, height: 34) }
                else { handle() }
            }.foregroundStyle(hover && !fixed && !disabled ? V3.fnt : V3.fnt2)
            VStack(alignment: .leading, spacing: 2) {
                if let renaming {
                    TextField("", text: renaming).textFieldStyle(.plain).font(V3.sans(13)).focused($focused)
                        .padding(.horizontal, 6).frame(height: 22)
                        .background(.white, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(V3.blue)).shadow(color: V3.blue.opacity(0.14), radius: 0, x: 0, y: 0)
                        .padding(.leading, -6).padding(.vertical, -3)
                        .onSubmit { commitRename(renaming.wrappedValue) }.onExitCommand { commitRename(nil) }
                        .onAppear { focused = true }
                } else {
                    Text(title).font(V3.sans(13, weight: current ? .medium : .regular)).foregroundStyle(empty ? V3.fnt : V3.txt).lineLimit(1).frame(height: 16)
                }
                Text(summary).font(V3.sans(11)).foregroundStyle(V3.fnt).lineLimit(1).frame(height: 13)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !(hover && !fixed), empty && !fixed { tag("空", fg: V3.fnt, bg: V3.field) }
            if fixed { Text("固定").font(V3.sans(11)).foregroundStyle(V3.fnt2) }
            if hover && !fixed && !disabled { menu().foregroundStyle(V3.sub).padding(.trailing, -3) }
        }
        .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 9).frame(minHeight: 52)
        .background(current ? V3.field : hover ? Color(hex: 0xFAFAF9) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .opacity(dragging ? 0.35 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if renaming == nil { open() } }
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction { open() }
        .help("跳到「\(title)」")
    }

    private func tag(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text).font(V3.sans(10.5, weight: .medium)).foregroundStyle(fg).padding(.horizontal, 6).padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// `.workbench-section-order-column`：12×10 小框，左或右 4 宽实心表示侧栏 / 主栏。
private struct ColumnGlyph: View {
    let left: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 2).stroke(V3.fnt, lineWidth: 1.5).frame(width: 12, height: 10)
            .overlay(alignment: left ? .leading : .trailing) { Rectangle().fill(V3.fnt).frame(width: 4, height: 10) }
            .clipShape(RoundedRectangle(cornerRadius: 2)).accessibilityHidden(true)
    }
}
