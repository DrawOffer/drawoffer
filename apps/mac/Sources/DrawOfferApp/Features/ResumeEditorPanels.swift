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

    @State private var templates: [ResumeTemplate] = []
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkbenchPanelHeader(title: "简历模板", subtitle: "点击模板即可应用到当前简历", closeLabel: "关闭简历模板面板", close: close)
            let ready = !loading && !failed && !templates.isEmpty
            if ready {
                // `.workbench-template-filters`：56 高、左右 24；数量 11.5px fnt，筛选钮 28 高
                HStack {
                    Text("\(filtered.count) 套模板").font(V3.sans(11.5)).foregroundStyle(V3.fnt)
                    Spacer()
                    TemplateFilter(styles: $styles, uses: $uses, height: 28)
                }.padding(.horizontal, 24).frame(height: 56)
            }
            if let error { Text(error).font(V3.sans(12)).foregroundStyle(V3.red).padding(.horizontal, 24).padding(.bottom, 8) }
            if loading { ProgressView("正在加载简历模板…").font(V3.sans(12)).frame(maxWidth: .infinity, maxHeight: .infinity) }
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
                ScrollViewReader { proxy in
                    ScrollView {
                        // `.workbench-template-grid`：两列，行距 20、列距 12；body 内边距 1/24/24
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 20) {
                            ForEach(filtered) { template in card(template).id(template.id) }
                        }.frame(width: 332).padding(.top, 1).padding(.bottom, 24).frame(maxWidth: .infinity)
                    }.scrollIndicators(.never)
                    // Web 打开时把当前模板滚到可视区中间
                    .onAppear { if let current = filtered.first(where: { Self.key($0) == currentKey }) { proxy.scrollTo(current.id, anchor: .center) } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await load() }
    }

    /// `.workbench-template-state`：最少 190 高、居中；标题 13/500 txt，说明 12px fnt，间距 8。
    private func state<Action: View>(_ title: String, _ detail: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 8) {
            Text(title).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
            Text(detail).font(V3.sans(12)).foregroundStyle(V3.fnt).padding(.bottom, 6)
            action()
        }.frame(maxWidth: .infinity, minHeight: 190).padding(.horizontal, 24).padding(.top, 16)
    }

    /// `.workbench-template-card`：纸面 210:297、圆角 6、#d3d3ce 描边（悬停 #b9b9b3，选中蓝色 2 层）；名称 12px（选中 500）、间距 10；
    /// 选中右上 18 黑底白勾；应用中纸面上盖 70% 白与转圈。
    private func card(_ template: ResumeTemplate) -> some View {
        let current = Self.key(template) == currentKey
        return Button { Task { await choose(template) } } label: {
            VStack(alignment: .leading, spacing: 10) {
                TemplateThumbnail(template: template, guest: false)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(current ? V3.blue : .clear, lineWidth: 2))
                    .overlay(alignment: .topTrailing) {
                        if current {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 18, height: 18).background(V3.txt, in: Circle()).padding(8).accessibilityHidden(true)
                        }
                    }
                    .overlay { if applying == template.id { ZStack { Color.white.opacity(0.7); ProgressView().controlSize(.small) }.clipShape(RoundedRectangle(cornerRadius: 6)) } }
                Text(template.name).font(V3.sans(12, weight: current ? .medium : .regular)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 22)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled || applying != nil)
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
                option("智能一页", symbol: "sparkles", on: settings.smartOnePage) { settings.smartOnePage.toggle() }
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
    @State private var order: [JSONValue] = []

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
        let title = ResumeDocument.value(section["title"])
        return HStack {
            Image(systemName: "line.3.horizontal").foregroundStyle(V3.fnt)
            Text(title.isEmpty ? kind : title).font(V3.sans(13))
            Spacer()
            if !title.isEmpty && title != kind { Text(kind).font(V3.sans(11)).foregroundStyle(V3.fnt) }
        }
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
/// 按栏分组的两行模块行（拖动手柄、标题、摘要、待完善 / 空标签、悬停 ⋯ 菜单），虚线「添加模块」与底部 / 提示。
/// 个人信息固定在第一行，不能拖动。原生端没有分页信息，不显示 Web 的页面缩略图条。
struct OutlinePanel: View {
    let sections: [JSONValue]
    let identity: JSONValue?
    let label: (JSONValue) -> String
    let columns: [String: String]
    let flagged: Set<String>
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
        OutlineRow(title: "个人信息", summary: ResumeOutline.identitySummary(identity), flagged: flagged.contains("identity"), empty: false,
                   fixed: true, current: false, dragging: false, disabled: disabled, renaming: nil,
                   handle: { EmptyView() }, menu: { EmptyView() }, open: { jump("identity") })
    }

    private func sectionRow(_ index: Int) -> some View {
        let section = sections[index], title = label(section), key = section.nodeKey
        let empty = ResumeOutline.isEmpty(section)
        return OutlineRow(title: title, summary: ResumeOutline.summary(section), flagged: flagged.contains(section.text("semantic_kind")),
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
    let flagged: Bool
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
            if !(hover && !fixed) {
                if flagged { tag("待完善", fg: Color(hex: 0xB8661A), bg: Color(hex: 0xFBF1E6)) }
                else if empty && !fixed { tag("空", fg: V3.fnt, bg: V3.field) }
            } else if fixed && flagged { tag("待完善", fg: Color(hex: 0xB8661A), bg: Color(hex: 0xFBF1E6)) }
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

/// 简历检查（Web `ResumeCompletenessPanel`）：分数与等级、示例内容提示、优先完善与已通过。
struct CompletenessPanel: View {
    let result: ResumeCompleteness
    let close: () -> Void
    @State private var passedOpen = false

    var body: some View {
        let incomplete = result.checks.filter { $0.status != "passed" }
        let passed = result.checks.filter { $0.status == "passed" }
        VStack(alignment: .leading, spacing: 0) {
            WorkbenchPanelHeader(title: "简历检查", subtitle: "实时规则检查", closeLabel: "关闭简历检查", close: close)
            ScrollView {
                // `.wb3-check-content`：内边距 15/24/24
                VStack(alignment: .leading, spacing: 0) {
                    summary(incomplete.count)
                    if !result.caps.isEmpty { caps.padding(.top, 18) }
                    // `.wb3-check-section`：上 24；头 16 高、下 12；卡片间距 10
                    HStack {
                        Text("优先完善").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                        Spacer()
                        Text("\(incomplete.count) 项").font(V3.sans(12)).foregroundStyle(V3.fnt)
                    }.frame(height: 16).padding(.top, 24).padding(.bottom, 12)
                    if incomplete.isEmpty {
                        Text("基础内容已经齐全，可以继续优化表达质量。").font(V3.sans(12)).foregroundStyle(V3.green)
                            .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(V3.greenSoft, in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        VStack(spacing: 10) { ForEach(incomplete, id: \.id) { checkRow($0) } }
                    }
                    // `.wb3-check-passed`：上 16；40 高 #f4f4f2 圆角 10 的展开行，展开后下 10
                    Button { withAnimation(.easeOut(duration: 0.14)) { passedOpen.toggle() } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(V3.sub)
                                .rotationEffect(.degrees(passedOpen ? 90 : 0)).frame(width: 14)
                            Text("已通过").font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.txt)
                            Spacer()
                            Text("\(passed.count) 项").font(V3.sans(12)).foregroundStyle(V3.fnt)
                        }.padding(.horizontal, 14).frame(height: 40).background(V3.field, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.top, 16).accessibilityLabel("已通过 \(passed.count) 项").accessibilityAddTraits(passedOpen ? .isSelected : [])
                    if passedOpen { VStack(spacing: 10) { ForEach(passed, id: \.id) { checkRow($0) } }.padding(.top, 10) }
                    Text("完整度检查基础信息、结构及技能表达的具体程度，不代表岗位匹配度。").font(V3.sans(11)).foregroundStyle(V3.fnt)
                        .lineSpacing(5).padding(.vertical, 2.5).fixedSize(horizontal: false, vertical: true).padding(.top, 18)
                }.padding(.horizontal, 24).padding(.top, 15).padding(.bottom, 24)
            }.scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { passedOpen = incompleteCount == 0 }
    }

    private var incompleteCount: Int { result.checks.filter { $0.status != "passed" }.count }

    /// `.wb3-check-summary`：大号仪表盘（`gaugeGeometry(false, 18)`），弧心 34/600 分数与 11px「/ 100」，
    /// 两端 10px 的 0 / 100，开口处 24 高等级胶囊；下方 12px 说明，上距 6。
    private func summary(_ pending: Int) -> some View {
        let g = WorkbenchGaugeShape.geometry(mini: false, extra: 18)
        let angle = 150.0 * .pi / 180
        let endX = g.r * cos(angle), endY = g.cy + g.r * sin(angle)
        return VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                WorkbenchGaugeShape(score: result.score, extra: 18)
                VStack(spacing: 3) {
                    Text("\(result.score)").font(V3.number(34, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 41)
                    Text("/ 100").font(V3.number(11, weight: .medium)).foregroundStyle(V3.fnt)
                }.frame(width: g.width).offset(y: g.cy - 42).accessibilityElement(children: .ignore).accessibilityLabel("当前完整度 \(result.score) 分")
                Text("0").font(V3.number(10, weight: .medium)).foregroundStyle(V3.fnt2).frame(height: 12).fixedSize()
                    .position(x: g.cx + endX, y: endY + 16).accessibilityHidden(true)
                Text("100").font(V3.number(10, weight: .medium)).foregroundStyle(V3.fnt2).frame(height: 12).fixedSize()
                    .position(x: g.cx - endX, y: endY + 16).accessibilityHidden(true)
                Text(result.level).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.txt).padding(.horizontal, 12).frame(height: 24)
                    .background(V3.field, in: Capsule()).fixedSize().position(x: g.cx, y: g.cy + 42)
            }.frame(width: g.width, height: g.height)
            Text("当前完整度 · " + (pending > 0 ? "还有 \(pending) 项可以完善" : "所有基础检查均已通过")).font(V3.sans(12)).foregroundStyle(V3.sub).frame(height: 22)
        }.frame(maxWidth: .infinity)
    }

    /// `.wb3-check-caps`：#f1dfc8 描边、圆角 10、橙色浅底、12/14；标题 12.5/500，原因 11.5px 行高 18。
    private var caps: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(V3.orange).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("检测到示例内容").font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.txt)
                ForEach(result.caps, id: \.id) { Text($0.reason).font(V3.sans(11.5)).foregroundStyle(V3.sub).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14).padding(.vertical, 12).background(V3.orangeSoft, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xF1DFC8))).accessibilityElement(children: .contain).accessibilityLabel("分数限制说明")
    }

    /// `.wb3-check-check`：白底、#e4e4e0 描边、圆角 10、内边距 14；左 22 圆形状态标（橙 / 绿 / 红浅底）；
    /// 标题行 22 高（13/500 名称、11px 得分、右侧状态字）；问题 12px 行高 19，建议 11.5px 行高 18。
    private func checkRow(_ item: ResumeCompleteness.Check) -> some View {
        let tone = item.status == "passed" ? V3.green : item.status == "failed" ? V3.red : V3.orange
        let soft = item.status == "passed" ? V3.greenSoft : item.status == "failed" ? V3.redSoft : V3.orangeSoft
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.status == "passed" ? "checkmark" : item.status == "failed" ? "exclamationmark" : "minus")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(tone).frame(width: 22, height: 22).background(soft, in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.label).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                    Text("\(item.earned)/\(item.max) 分").font(V3.number(11, weight: .medium)).foregroundStyle(V3.fnt)
                    Spacer(minLength: 4)
                    Text(item.status == "passed" ? "已通过" : item.status == "partial" ? "需完善" : "待补充").font(V3.sans(11, weight: .medium)).foregroundStyle(tone)
                }.frame(height: 22)
                if let issue = item.issue { Text(issue).font(V3.sans(12)).foregroundStyle(V3.sub).lineSpacing(4).padding(.vertical, 2).frame(minHeight: 19).fixedSize(horizontal: false, vertical: true) }
                if let advice = item.recommendation { Text(advice).font(V3.sans(11.5)).foregroundStyle(V3.fnt).lineSpacing(4).padding(.vertical, 2).frame(minHeight: 18).fixedSize(horizontal: false, vertical: true) }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.cl))
            .accessibilityElement(children: .combine)
    }
}

/// 聚焦这段（Web `sectionFocus/FocusSheet.tsx` 的主要流程）：可写一句想怎么改，AI 按写作标准逐条给出建议；
/// 每条建议可选一个改写采用（写回对应行，留在编辑器里由自动保存提交）或跳过，结果记在服务端的分析记录里。
struct SectionFocusSheet: View {
    @Environment(SessionStore.self) private var session
    let resumeID: String
    let unit: SectionFocus.Unit
    let adopt: (String, String) -> Bool
    let close: () -> Void
    @State private var intent: String

    init(resumeID: String, unit: SectionFocus.Unit, intent: String = "", adopt: @escaping (String, String) -> Bool, close: @escaping () -> Void) {
        self.resumeID = resumeID; self.unit = unit; self.adopt = adopt; self.close = close
        _intent = State(initialValue: String(intent.prefix(300)))
    }
    @State private var loading = false
    @State private var error: String?
    @State private var result: JSONValue?
    @State private var handled: [String: String] = [:]

    private var notes: [JSONValue] { result?["notes"]?.items ?? [] }
    private var items: [JSONValue] { result?["review"]?["items"]?.items ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("聚焦这段").font(V3.serif(20))
                    Text(unit.heading.isEmpty ? "\(unit.lines.count) 行内容" : unit.heading).font(V3.sans(12)).foregroundStyle(V3.fnt).lineLimit(1)
                }
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
            if result == nil {
                Text("AI 会按写作标准逐行检查这段内容，给出可直接采用的改写；不会自动改你的简历。").font(V3.sans(12.5)).foregroundStyle(V3.sub)
                TextField("可选：想怎么改？比如“突出数据结果”“更简洁”", text: $intent).textFieldStyle(.roundedBorder)
                    .onChange(of: intent) { if intent.count > 300 { intent = String(intent.prefix(300)) } }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(unit.lines, id: \.id) { Text("· " + $0.text).font(V3.sans(12)).foregroundStyle(V3.sub).lineLimit(2) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(V3.stage, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    if let error { Text(error).font(V3.sans(12)).foregroundStyle(V3.red) }
                    Spacer()
                    Button(loading ? "正在分析…" : "开始分析") { Task { await analyze() } }.buttonStyle(V3ButtonStyle(kind: .dark)).disabled(loading)
                }
            } else {
                if result?["too_thin"]?.bool == true {
                    Text("这段内容太少，先补几句做了什么、结果如何，再来分析会更准。").font(V3.sans(12.5)).foregroundStyle(V3.orange)
                }
                if notes.isEmpty { Text("这段写得不错，没有需要修改的地方。").font(V3.sans(13)).foregroundStyle(V3.sub) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(notes, id: \.self) { note in noteCard(note) }
                    }
                }.frame(maxHeight: 460)
                HStack {
                    if let error { Text(error).font(V3.sans(12)).foregroundStyle(V3.red) }
                    Spacer()
                    Button("重新分析") { result = nil; handled = [:] }.buttonStyle(V3ButtonStyle(kind: .ghost))
                    Button("完成", action: close).buttonStyle(V3ButtonStyle(kind: .dark))
                }
            }
        }.padding(22).frame(width: 600)
    }

    private func noteCard(_ note: JSONValue) -> some View {
        let id = note.text("id")
        let variants = note["variants"]?.items ?? []
        let state = handled[id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(note.text("title")).font(V3.sans(13, weight: .semibold))
                Spacer()
                if let state { Text(state == "done" ? "已采用" : "已跳过").font(V3.sans(11.5)).foregroundStyle(state == "done" ? V3.green : V3.fnt) }
            }
            if !note.text("quote").isEmpty { Text("原文：" + note.text("quote")).font(V3.sans(12)).foregroundStyle(V3.fnt).strikethrough(state == "done") }
            if !note.text("detail").isEmpty { Text(note.text("detail")).font(V3.sans(12)).foregroundStyle(V3.sub).fixedSize(horizontal: false, vertical: true) }
            if let demo = note["demo"], case .object = demo {
                Text("补全示范：" + demo.text("text")).font(V3.sans(12)).foregroundStyle(V3.blue).fixedSize(horizontal: false, vertical: true)
                Text("〔〕里是只有你知道的数据，请在编辑器里补上。").font(V3.sans(11)).foregroundStyle(V3.fnt)
            }
            if state == nil {
                ForEach(variants, id: \.self) { variant in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            if !variant.text("label").isEmpty { Text(variant.text("label")).font(V3.sans(11)).foregroundStyle(V3.fnt) }
                            Text(variant.text("text")).font(V3.sans(12.5)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            let risky = (variant["risky_terms"]?.items ?? []).compactMap(\.stringValue)
                            if !risky.isEmpty { Text("「\(risky.joined(separator: "、"))」原句没有，请确认属实").font(V3.sans(11)).foregroundStyle(V3.orange) }
                        }
                        Spacer()
                        Button("采用") { Task { await decide(note, variant: variant) } }.buttonStyle(V3ButtonStyle(kind: .ghost)).disabled(note.text("line_id").isEmpty)
                    }.padding(8).background(V3.field, in: RoundedRectangle(cornerRadius: 7))
                }
                HStack { Spacer(); Button("跳过") { Task { await decide(note, variant: nil) } }.buttonStyle(.link).font(V3.sans(12)) }
            }
        }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.cl))
    }

    private func analyze() async {
        loading = true; error = nil
        defer { loading = false }
        var body: [String: JSONValue] = ["section": unit.payload, "reference": .object(["kind": .string("general")])]
        let text = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { body["intent"] = .string(text) }
        do {
            result = try await session.api.careerRequest(path: "/api/resumes/\(resumeID)/section-review:analyze", method: "POST", query: [:], body: .object(body))
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            self.error = SectionFocus.errorMessage(error)
        }
    }

    /// 采用：写回这一行并把服务端的建议项标为 done（附改写前后）；跳过：标为 skipped。
    private func decide(_ note: JSONValue, variant: JSONValue?) async {
        let noteID = note.text("id"), lineID = note.text("line_id")
        if let variant {
            let before = unit.lines.first { $0.id == lineID }?.text ?? note.text("quote")
            guard adopt(lineID, variant.text("text")) else { error = "这一行已经不在简历里，没能采用。"; return }
            handled[noteID] = "done"
            await patch(noteID, ["status": .string("done"), "edit": .object(["line_id": .string(lineID), "before": .string(before), "after": .string(variant.text("text"))])])
        } else {
            handled[noteID] = "skipped"
            await patch(noteID, ["status": .string("skipped")])
        }
    }

    private func patch(_ noteID: String, _ body: [String: JSONValue]) async {
        guard let reviewID = result?["review"]?.text("id"), let item = items.first(where: { $0.text("note_id") == noteID }) else { return }
        do { _ = try await session.api.careerRequest(path: "/api/resumes/\(resumeID)/section-reviews/\(reviewID)/items/\(item.text("id"))", method: "PATCH", query: [:], body: .object(body)) }
        catch { self.error = SectionFocus.errorMessage(error) }
    }
}
