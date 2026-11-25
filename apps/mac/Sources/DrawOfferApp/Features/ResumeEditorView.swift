import AppKit
import DrawOfferCore
import DrawOfferRender
import SwiftUI
import UniformTypeIdentifiers

/// 简历编辑（Web `ResumeWorkbench` 的对应页）：纸面即编辑器，与 Web 同一套 TipTap 编辑器、分页、斜杠菜单与选区工具栏
/// （`ResumeEditorPaperView`）；顶栏、右侧工具轨与大纲 / 模板 / 排版 / 引导面板由原生实现。
/// 保存提交 `PUT /api/resumes/{id}` 的 data、style 与 base_lock_version；冲突时提示重新载入，不覆盖他处的修改。
struct ResumeEditorView: View {
    @Environment(SessionStore.self) private var session
    let resumeID: String
    let close: () -> Void

    @State private var record: JSONValue?
    @State private var saved: JSONValue = .null
    @State private var doc: JSONValue = .null
    @State private var savedStyle: JSONValue = .null
    @State private var style: JSONValue = .null
    @State private var title = ""
    @State private var loading = true
    @State private var error: String?
    @State private var notice: String?
    @State private var saving = false
    @State private var conflict = false
    @State private var confirmLeave = false
    @State private var paperNote: String?
    /// 可编辑纸面：`paperSeed` 变化时重新载入（打开、换模板、重新载入）；版式在排版面板改动时按 `styleRevision` 下发。
    @State private var paperSeed: JSONValue?
    @State private var paperGeneration = 0
    @State private var styleRevision = 0
    /// 纸面最近一次回报的版式：与它相同的变化来自纸面本身，不再下发。
    @State private var paperStyle: JSONValue?
    @State private var channel = ResumeEditorChannel()
    @State private var canUndo = false
    @State private var canRedo = false
    /// 改这一条（分区 12.1–12.6）：选区工具栏「问 AI」传来的那一行，在纸右边开对话。
    @State private var lineTarget: ResumeLineChat.Target?
    /// 每次从纸面点一次就重开一轮对话。
    @State private var lineAsk = 0
    /// 排版卡片刚被点空白处收起的时刻：点规格行入口时系统先收起再触发按钮，据此不把它又打开。
    @State private var typeClosedAt = Date.distantPast
    @State private var zoom = 1.0
    @State private var zoomBadge: Double?
    @State private var uploading = false
    /// 右侧工具轨当前打开的面板（Web 大纲 / 模板 / 排版）。
    @State private var panel: String?
    /// 自动保存：停顿后串行保存；失败时显示横幅和重试。
    @State private var autosaveTask: Task<Void, Never>?
    @State private var saveFailed = false
    @State private var exporting = false
    @State private var importWarnings: [String] = []
    /// 这份简历的写作引导（Web：进入编辑器先读；没有引导时不显示入口，进行中时自动展开）。
    @State private var guide: JSONValue?
    /// 检查简历的结果：收起面板也留着，顶栏显示还剩几处；重新载入或换模板时清掉。
    @State private var check = ResumeCheckState()
    /// 纸面上报的光标所在行（12.1：行旁“改这一条 ⌘K”）；不在可改的行上或正在打字时为 nil。
    @State private var paperLine: PaperLine?
    /// 纸面实际页数（规格行“共 N 页”、检查简历的 page_count）。
    @State private var pageCount = 1
    /// 07.2 模板悬停预览：纸面临时换成的那套模板名；规格行换成灰字“预览：… · 点击换上”。
    @State private var templatePreviewName: String?
    @State private var templatePreviewTask: Task<Void, Never>?
    /// 同一份正文下各模板的预览结果；正文一改就作废。
    @State private var templatePreviewCache: [String: JSONValue] = [:]

    private var dirty: Bool { record != nil && (doc != saved || style != savedStyle || title != (record?.text("title") ?? "")) }
    private var sections: [JSONValue] { doc["sections"]?.items ?? [] }
    private var templateKey: String { style["template_snapshot"]?.text("template_key") ?? "" }
    private var busy: Bool { saving || uploading }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !importWarnings.isEmpty { importBanner }
            if loading && record == nil { V3Loading("正在读取简历…").frame(maxWidth: .infinity, maxHeight: .infinity).background(Self.canvas) }
            else if record == nil {
                VStack(spacing: 10) {
                    Text(error ?? "简历读取失败。").font(V3.sans(13)).foregroundStyle(V3.red)
                    Button("重试") { Task { await load() } }.buttonStyle(V3ButtonStyle(kind: .ghost))
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Self.canvas)
            } else {
                canvasArea
            }
        }
        .task { await load(); await loadGuide() }
        .onExitCommand { if panel != nil { panel = nil } }
        .onChange(of: doc) { _, _ in templatePreviewCache = [:]; scheduleAutosave() }
        .onChange(of: panel) { _, next in if next != "template" { previewTemplate(nil) } }
        // 检查简历：纸边小圆圈、当前这处的改法预览，跟着检查结果和面板开合走
        .onChange(of: checkMarks, initial: true) { _, marks in channel.send(.marks(marks)) }
        .onChange(of: checkDecor, initial: true) { _, decor in
            channel.send(.decorate(source: "check", highlight: decor.highlight, preview: decor.preview))
        }
        .onChange(of: checkCurrent) { _, current in
            if let current, checkOpen, let ids = checkNodeIDs(current) { channel.send(.reveal(ids)) }
        }
        .onChange(of: style) { _, _ in
            // 排版面板改的版式下发给纸面；纸面自己回报的（头像尺寸）不再回送
            if style != paperStyle { styleRevision += 1 }
            scheduleAutosave()
        }
        .onChange(of: title) { _, _ in scheduleAutosave() }
        .onDisappear { autosaveTask?.cancel() }
        .centeredConfirmation("放弃未保存的修改？", isPresented: $confirmLeave) {
            Button("放弃修改", role: .destructive, action: close)
            Button("继续编辑", role: .cancel) {}
        }
    }

    // MARK: Canvas

    /// Figma 03 页 07.0：编辑器整页铺满窗口，#f3f3f0 画布，顶栏与红绿灯同一行、和画布同底。
    static let canvas = Color(hex: 0xF3F3F0)
    /// 排版卡片（06.2）：规格行左边点开，320 宽 NSPopover，箭头指向规格行。
    /// 检查简历（12.7–12.11）与改这一条（12.1–12.6）：纸右边一列对话，和引导一样不加卡片。
    private var checkOpen: Bool { panel == "check" }
    private var lineOpen: Bool { panel == "line" && lineTarget != nil }
    private var columnOpen: Bool { guideOpen || checkOpen || lineOpen }
    /// 模板栏（07.1）：顶栏「模板」打开，贴编辑器右边一整列（跟 Web 分区 18 一样，和右上角“模板”按钮同侧），纸往左让开。
    private var templateOpen: Bool { panel == "template" }
    /// 07.1 模板栏宽 343（含左侧 1 的细线）；12.x 对话列 400、距纸 52。
    static let railWidth: CGFloat = 343
    static let columnGap: CGFloat = 52
    /// 编辑器里 100% 时纸面宽 560（稿 A4 Page 560、规格行 572 = 纸宽 + 12）。
    static let paperWidth: CGFloat = 560

    /// 纸与右边一列当成一组居中：纸面宽 560 × 缩放（渲染器 EDITOR_PAGE_BASE_SCALE = 560 / 794，稿 A4 Page 560）；放不下时对话列贴右 24。
    private func columnLayout(width: CGFloat) -> (paperTrailing: CGFloat, columnX: CGFloat) {
        let paper = Self.paperWidth * zoom
        let group = paper + Self.columnGap + ResumeTalk.columnWidth
        if width >= group + 80 {
            let left = (width - group) / 2
            return (max(0, width - 2 * left - paper), left + paper + Self.columnGap)
        }
        return (ResumeTalk.columnWidth + Self.columnGap, width - ResumeTalk.columnWidth - 24)
    }

    private var canvasArea: some View {
        GeometryReader { geometry in
            let layout = columnLayout(width: geometry.size.width - (templateOpen ? Self.railWidth : 0))
            VStack(spacing: 0) { specBar.padding(.top, 8); preview }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, (columnOpen ? layout.paperTrailing : 0) + (templateOpen ? Self.railWidth : 0))
                .animation(.timingCurve(0.2, 0, 0, 1, duration: 0.22), value: columnOpen || templateOpen)
                .overlay(alignment: .topLeading) {
                    Group {
                        if guideOpen, let guide {
                            ResumeGuidePanel(resumeID: resumeID, guide: Binding(get: { guide }, set: { self.guide = $0 }), data: doc,
                                             templateID: record?["template_id"]?.stringValue,
                                             saveFirst: { await saveBeforeWrite() },
                                             applied: { resume in Task { await apply(resume) } },
                                             undo: { before in doc = before; channel.replaceData(before) },
                                             exportPDF: { Task { await exportPDF() } },
                                             close: { panel = nil })
                        } else if checkOpen {
                            ResumeCheckPanel(resumeID: resumeID, document: doc, label: sectionLabel, pageCount: pages, state: $check,
                                             write: { next in doc = next; channel.replaceData(next) },
                                             close: { panel = nil })
                        } else if lineOpen, let current = lineTarget {
                            ResumeLineChat(resumeID: resumeID,
                                           target: Binding(get: { lineTarget ?? current }, set: { lineTarget = $0 }),
                                           document: doc, kind: lineKind, label: sectionLabel,
                                           write: { next in doc = next; channel.replaceData(next) },
                                           decorate: { highlight, preview in channel.send(.decorate(source: "line", highlight: highlight, preview: preview)) },
                                           close: { panel = nil; lineTarget = nil })
                                .id(lineAsk)
                        }
                    }
                    .frame(width: ResumeTalk.columnWidth).frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 44)
                    .offset(x: layout.columnX)
                }
        }
        .background(Self.canvas)
        .overlay(alignment: .trailing) {
            if templateOpen {
                // 稿：栏底色跟画布一样，不加白底；只有一条 #e4e4e0 竖线，从工具栏下 40 起一直到底
                VStack(spacing: 0) { panelView }.frame(width: Self.railWidth).frame(maxHeight: .infinity, alignment: .top)
                    .overlay(alignment: .leading) { Rectangle().fill(V3.cl).frame(width: 1).padding(.top, 40) }
                    .transition(.move(edge: .trailing)).accessibilityElement(children: .contain)
            }
        }
        .overlay(alignment: .top) { if saveFailed { saveNotice.padding(.top, 15) } }
        .overlay { if let zoomBadge { zoomFeedback(zoomBadge) } }
    }

    /// 改这一条所在的模块类型（技能不给 STAR）。
    private var lineKind: ResumeCheck.Kind {
        guard let id = lineTarget?.unit.id else { return .experience }
        let section = sections.first { $0.nodeKey == id || ($0["entries"]?.items ?? []).contains { $0.nodeKey == id } }
        guard let section else { return .experience }
        return ResumeCheck.kind(semantic: section.text("semantic_kind"), label: sectionLabel(section))
    }

    /// `.wb3-save-notice`：420×64 白卡，圆角 12，红色 16 圆圈「!」、标题与原因、重试保存。
    private var saveNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("!").font(V3.number(10, weight: .bold)).foregroundStyle(V3.red)
                .frame(width: 16, height: 16).overlay(Circle().stroke(V3.red, lineWidth: 1.4)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("保存失败").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                Text(error ?? "修改仍保留在本页，可以重试保存。").font(V3.sans(11.5)).foregroundStyle(V3.sub).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("重试保存") { Task { await save() } }.buttonStyle(V3ButtonStyle(kind: .ghost, height: 30)).disabled(saving)
        }
        .padding(.horizontal, 16).padding(.vertical, 13).frame(width: 420, height: 64, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.cl))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 8)
    }

    /// `.workbench-zoom-feedback`：居中 104×68 的深色半透明块，等宽数字百分比。
    private func zoomFeedback(_ value: Double) -> some View {
        Text("\(Int((value * 100).rounded()))%").font(.system(size: 20, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
            .padding(.horizontal, 18).frame(minWidth: 104, minHeight: 68)
            .background(Color(red: 15 / 255, green: 18 / 255, blue: 22 / 255).opacity(0.84), in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color(red: 15 / 255, green: 18 / 255, blue: 22 / 255).opacity(0.22), radius: 21, y: 16)
            .allowsHitTesting(false).accessibilityLabel("缩放 \(Int((value * 100).rounded()))%")
    }

    /// Web `previewScale`：0.5–1.6；按钮与快捷键按 0.1 取整，滚轮按页面给的步进。
    private func setZoom(_ value: Double, step: Bool = true) {
        zoom = min(1.6, max(0.5, step ? (value * 10).rounded() / 10 : value))
        zoomBadge = zoom
        Task { try? await Task.sleep(for: .milliseconds(900)); if zoomBadge == zoom { zoomBadge = nil } }
    }

    private var importBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(V3.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("请检查导入结果").font(V3.sans(12.5, weight: .semibold))
                Text(importWarnings.map(Self.importWarningText).joined(separator: "；")).font(V3.sans(12)).foregroundStyle(V3.sub).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { importWarnings = [] } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭导入质量提示")
        }.padding(12).background(V3.orangeSoft).accessibilityElement(children: .contain)
    }

    // MARK: Toolbar & preview

    /// Figma macOS 稿 03 页 07.0「Editor Toolbar · NSToolbar」：52 高，和画布同底、不画分隔线。
    /// 窗口是隐藏标题栏，红绿灯中线在顶上 16pt（与侧栏顶行一致）：整行控件放在顶上 32 高里与红绿灯同一中线，左让出 84，下面留 20 给画布上沿。
    /// 左：← 我的简历（同 Web `BackCrumb`：灰字常规、悬停转墨黑，无底色）、撤销 / 重做；中：简历标题居中（最宽 560，末尾省略）；右：无边框「模板」「导出 PDF」。
    /// 「检查简历」在纸面上沿右边。
    /// 不显示“已保存”，自动保存失败才在画布上方出提示卡。
    private var toolbar: some View {
        ZStack {
            HStack(spacing: 6) {
                Button { leave() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left").font(.system(size: 13))
                        Text("我的简历").font(V3.sans(14))
                    }.frame(height: 28).contentShape(Rectangle())
                }.buttonStyle(BackCrumbStyle()).help("返回我的简历").accessibilityLabel("返回我的简历")
                // 稿：返回与撤销 / 重做相隔 14，撤销 / 重做各 26×26、间距 4
                HStack(spacing: 4) {
                    Button { channel.send(.undo) } label: { toolbarIcon("arrow.uturn.backward") }
                        .buttonStyle(ToolbarPlainStyle()).disabled(!canUndo || busy).help("撤销（⌘Z）").accessibilityLabel("撤销")
                        .keyboardShortcut("z", modifiers: .command)
                    Button { channel.send(.redo) } label: { toolbarIcon("arrow.uturn.forward") }
                        .buttonStyle(ToolbarPlainStyle()).disabled(!canRedo || busy).help("重做（⇧⌘Z）").accessibilityLabel("重做")
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                }.padding(.leading, 8)
                Spacer(minLength: 16)
                if conflict { Button("重新载入") { Task { await load() } }.buttonStyle(ToolbarPlainStyle(strong: true)).padding(.trailing, 4) }
                Button { togglePanel("template") } label: { toolbarLabel("模板", "square.grid.2x2", weight: .regular) }
                    .buttonStyle(ToolbarPlainStyle(pressed: panel == "template")).disabled(busy || conflict || record == nil)
                    .accessibilityLabel("简历模板").accessibilityAddTraits(panel == "template" ? .isSelected : [])
                Button { Task { await exportPDF() } } label: { toolbarLabel(exporting ? "导出中…" : "导出 PDF", "square.and.arrow.up") }
                    .buttonStyle(ToolbarPlainStyle()).disabled(exporting || record == nil)
            }
            TitleField(title: $title).frame(maxWidth: 560)
        }
        .padding(.leading, 84).padding(.trailing, 14).frame(height: 32).padding(.bottom, 20)
        .background(Self.canvas)
    }

    private func toolbarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 14)).frame(width: 26, height: 26).contentShape(Rectangle())
    }

    private func toolbarLabel(_ title: String, _ symbol: String, weight: Font.Weight = .medium) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 13))
            Text(title).font(V3.sans(13, weight: weight))
        }.padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
    }

    /// Figma「Editor Spec Bar」（07.0）：纸面上沿一行，宽度跟纸一样。左：字体 · 字号 · 行距 ⌃⌄（无边框，点开排版卡片）；
    /// 右：「检查简历」（检查中显示第几处 / 还剩几处），有写作引导时它左边多一个「引导」。
    private var specBar: some View {
        let settings = ResumeTypeSettings.read(style)
        let open = panel == "type"
        return HStack(spacing: 4) {
            if let templatePreviewName {
                // 07.2：悬停预览时左边这一格临时换成灰字状态（不是按钮），移开恢复
                HStack(spacing: 5) {
                    Text("预览：\(templatePreviewName) · 点击换上").font(V3.sans(12.5)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .medium))
                }.foregroundStyle(V3.fnt).padding(.horizontal, 6).frame(height: 24)
                    .accessibilityElement(children: .combine).accessibilityAddTraits(.updatesFrequently)
            } else if let settings {
                Button {
                    // 点入口收起：系统在按下时已经把卡片收掉，这里不再重开
                    if Date().timeIntervalSince(typeClosedAt) > 0.3 { panel = open ? nil : "type" }
                } label: {
                    HStack(spacing: 4) {
                        Text(specSummary(settings)).font(V3.sans(12.5)).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .medium))
                    }.padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle())
                }.buttonStyle(ToolbarPlainStyle(pressed: open, ink: Self.specInk, radius: 5)).disabled(busy)
                    .popover(isPresented: typePopoverBinding, arrowEdge: .bottom) {
                        if ResumeTypeSettings.read(style) != nil {
                            TypeCard(settings: typeBinding, pageCount: pages, sections: sections,
                                     columns: ResumeLayout.columns(data: doc, style: style), label: sectionLabel, disabled: busy,
                                     reorder: { order in channel.send(.reorder(order.map(\.nodeKey))) },
                                     rename: { id, title in channel.send(.rename(id, title)) },
                                     remove: { id in channel.send(.remove(id)) })
                        } else {
                            Text("当前模板不支持调整排版").font(V3.sans(12.5)).foregroundStyle(V3.fnt).padding(24)
                        }
                    }
                    .accessibilityLabel("排版：\(specSummary(settings))").accessibilityAddTraits(open ? .isSelected : [])
            }
            Spacer(minLength: 0)
            if guide != nil && !guideOpen {
                Button { togglePanel("guide") } label: { specLabel("引导", "bubble.left") }
                    .buttonStyle(ToolbarPlainStyle(ink: Self.specInk, radius: 5)).disabled(busy).accessibilityLabel("引导创建简历")
            }
            Button { togglePanel("check") } label: {
                // 12.7–12.10：检查中蓝字浅蓝底“检查中… / 检查 · 第 n / m 处”
                checkTint(specLabel(checkLabel, "checkmark.circle"))
            }
                .buttonStyle(ToolbarPlainStyle(pressed: checkOpen && !checkActive, ink: Self.specInk, radius: 5)).disabled(busy || conflict || record == nil)
                .accessibilityLabel("检查简历").accessibilityAddTraits(checkOpen ? .isSelected : [])
        }
        .frame(width: Self.paperWidth * zoom + 12).frame(height: 32)
    }

    /// 规格行文字色（Figma Editor Spec Bar #3c3c3a）。
    private static let specInk = Color(hex: 0x3C3C3A)

    private var typePopoverBinding: Binding<Bool> {
        Binding(get: { panel == "type" },
                set: { if !$0, panel == "type" { panel = nil; typeClosedAt = Date() } })
    }

    @ViewBuilder private func checkTint<Label: View>(_ label: Label) -> some View {
        if checkActive { label.foregroundStyle(V3.blue).background(V3.blueSoft, in: RoundedRectangle(cornerRadius: 6)) } else { label }
    }

    /// 正在读或正在看某一处：入口变成蓝字浅蓝底。
    private var checkActive: Bool {
        guard checkOpen else { return false }
        if case .reading = check.phase { return true }
        if case .item = check.phase { return true }
        return false
    }

    /// 12.x：检查中显示“检查 · 第 n / m 处”，收起后显示还剩几处。
    private var checkLabel: String {
        if checkOpen, case .reading = check.phase { return "检查中…" }
        if case .item(let index) = check.phase { return "检查 · 第 \(index + 1) / \(check.findings.count) 处" }
        if let remaining = check.remaining, remaining > 0 { return "检查 · 剩 \(remaining) 处" }
        return "检查简历"
    }

    private func specLabel(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium))
            Text(title).font(V3.sans(12.5)).lineLimit(1)
        }.padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle())
    }

    private func specSummary(_ settings: ResumeTypeSettings) -> String {
        let font = ResumeTypeSettings.fonts.first { $0.value == settings.fontFamily }?.label ?? ResumeTypeSettings.fonts[0].label
        // Web `WorkbenchSpecRow`：字体 · 字号 · 行距 · 共 N 页（智能一页时为 1 页）
        return [font, "\(String(format: "%g", settings.fontSize))pt", "行距 \(String(format: "%.2f", settings.lineHeight))", "共 \(pages) 页"]
            .joined(separator: " · ")
    }

    private var guideOpen: Bool { panel == "guide" && guide != nil }

    /// 纸面实际页数；智能一页时为 1。
    private var pages: Int { ResumeTypeSettings.read(style)?.smartOnePage == true ? 1 : max(1, pageCount) }

    @ViewBuilder private var panelView: some View {
        switch panel {
        case "template":
            TemplateSwitchSheet(currentKey: templateKey, disabled: busy || conflict, apply: applyTemplate, close: { panel = nil },
                                preview: previewTemplate)
        default: EmptyView()
        }
    }

    private var typeBinding: Binding<ResumeTypeSettings> {
        Binding(get: { ResumeTypeSettings.read(style) ?? ResumeTypeSettings(fontFamily: ResumeTypeSettings.serifStack, fontSize: 10, lineHeight: 1.5, pageMargin: 16, verticalPageMargin: 14, smartOnePage: false) },
                set: { style = $0.apply(to: style) })
    }

    /// 可编辑纸面：`.workbench-paper-scroll` 与纸面缩放都在页面里按 Web 规则实现（⌘ + 滚轮缩放回报给原生）；
    /// ⌘+ / ⌘− / ⌘0 缩放并显示百分比。
    @ViewBuilder private var preview: some View {
        if let paperSeed, let record {
            ResumeEditorPaperView(resumeID: resumeID, data: paperSeed["data"] ?? .null, style: paperSeed["style"] ?? .null, layoutPlan: record["layout_plan"],
                                  liveStyle: style, styleRevision: styleRevision, zoom: zoom, horizontal: false,
                                  channel: channel, api: session.api, onEvent: handlePaper)
                .id(paperGeneration)
                .overlay(alignment: .topLeading) { lineTrigger }
                .clipped()
                .overlay(alignment: .bottom) {
                    if let paperNote { Text(paperNote).font(V3.sans(11.5)).foregroundStyle(V3.orange).padding(8).background(.white, in: Capsule()).padding(.bottom, 16) }
                }
                .background {
                    Group {
                        Button("") { setZoom(zoom + 0.1) }.keyboardShortcut("=", modifiers: .command)
                        Button("") { setZoom(zoom - 0.1) }.keyboardShortcut("-", modifiers: .command)
                        Button("") { setZoom(1) }.keyboardShortcut("0", modifiers: .command)
                        // 12.1：⌘K 打开“改这一条”（焦点在纸面里时由页面自己报 line-open）
                        Button("") { if let paperLine, showLineTrigger { openLine(paperLine) } }.keyboardShortcut("k", modifiers: .command)
                    }.opacity(0).accessibilityHidden(true)
                }
        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    /// 12.1：只在没开任何面板、没在预览模板时出现；正在打字时纸面不报行，入口自然收起。
    private var showLineTrigger: Bool { panel == nil && templatePreviewName == nil && !busy && !conflict }

    /// “改这一条 ⌘K”：纸右边 24、比这一行上沿高 20 的 33 高白色胶囊（职绘图标 14、文字 13、⌘K 灰字）。
    @ViewBuilder private var lineTrigger: some View {
        if let line = paperLine, showLineTrigger {
            GeometryReader { geometry in
                let y = line.rect.minY - 20
                if line.rect.maxY > 0, line.rect.minY < geometry.size.height, line.paper.maxX + 24 + 126 <= geometry.size.width {
                    LineChatTrigger { openLine(line) }
                        .offset(x: line.paper.maxX + 24, y: max(0, y))
                        .transition(.opacity)
                }
            }
        }
    }

    private func handlePaper(_ event: ResumeEditorEvent) {
        switch event {
        case .changed(let data, let next):
            paperNote = nil
            doc = data
            paperStyle = next
            if next != style { style = next }
        case .history(let undo, let redo): canUndo = undo; canRedo = redo
        case .zoom(let value): setZoom(value, step: false)
        case .ask(let unitID, let lineID, _, let instruction):
            guard let unit = focusUnit(unitID) else { paperNote = "这一行暂时不能聚焦修改"; return }
            let line = unit.lines.contains { $0.id == lineID } ? lineID : (unit.lines.first?.id ?? lineID)
            lineTarget = ResumeLineChat.Target(unit: unit, lineIDs: [line], instruction: instruction)
            lineAsk += 1
            panel = "line"
        case .error(let message): paperNote = message
        case .line(let line): paperLine = line
        case .lineOpen(let line): if showLineTrigger || panel == "line" { openLine(line) }
        case .pages(let count): pageCount = count
        case .mark(let key):
            guard let index = check.findings.firstIndex(where: { $0.id == key }), check.findings[index].status == .open else { return }
            check.phase = .item(index)
            panel = "check"
        }
    }

    /// 打开“改这一条”：光标所在的那一条，或选中的几条（12.6，同一段里）。
    private func openLine(_ line: PaperLine) {
        guard let unit = focusUnit(line.unitID) else { paperNote = "这一行暂时不能聚焦修改"; return }
        let ids = line.lineIDs.filter { id in unit.lines.contains { $0.id == id } }
        guard !ids.isEmpty else { paperNote = "这一行暂时不能聚焦修改"; return }
        // 同一处重复触发（纸面和原生同时响应 ⌘K）不重开对话
        if panel == "line", lineTarget?.unit.id == unit.id, lineTarget?.lineIDs == ids { return }
        lineTarget = ResumeLineChat.Target(unit: unit, lineIDs: ids, selection: ids.count == 1 ? line.selection : nil)
        lineAsk += 1
        panel = "line"
    }

    // MARK: Check marks

    /// 检查结果里每一处对应纸上的哪几行：一条就是这一行，整段是这一段（含条目标题）。
    private func checkNodeIDs(_ index: Int) -> [String]? {
        guard check.findings.indices.contains(index) else { return nil }
        let finding = check.findings[index]
        if let lineID = finding.lineID { return [lineID] }
        let lines = check.units.first { $0.id == finding.entryID }?.lines.map(\.id) ?? []
        return [finding.entryID] + lines
    }

    /// 正在看的那一处（面板打开时）。
    private var checkCurrent: Int? {
        guard checkOpen, case .item(let index) = check.phase, check.findings.indices.contains(index), check.findings[index].status == .open else { return nil }
        return index
    }

    /// 12.7–12.10 纸边小圆圈：空心 = 还没看，蓝 = 正在看，灰 = 看过；都处理完（12.11）就不画。收起面板后仍留着，点一下打开那一处。
    private var checkMarks: [PaperMark] {
        guard let remaining = check.remaining, remaining > 0 else { return [] }
        let current = checkCurrent
        return check.findings.indices.compactMap { index in
            guard let ids = checkNodeIDs(index) else { return nil }
            let finding = check.findings[index]
            let state: PaperMark.State = finding.status != .open ? .done : index == current ? .current : .pending
            return PaperMark(key: finding.id, nodeIDs: ids, state: state)
        }
    }

    private struct CheckDecor: Equatable {
        var highlight: [String] = []
        var preview: [PaperLineChange] = []
    }

    /// 12.8–12.10：正在看的那一处——能直接改的把改好的一句放在纸上，并进另一条的放在那一条上，其余高亮这一行 / 整段。
    private var checkDecor: CheckDecor {
        guard let index = checkCurrent, let ids = checkNodeIDs(index) else { return CheckDecor() }
        let finding = check.findings[index]
        guard let suggestion = finding.suggestion, let lineID = finding.lineID else { return CheckDecor(highlight: ids) }
        switch finding.fix {
        case "delete": return CheckDecor(highlight: ids)
        case "merge":
            guard let target = finding.mergeInto else { return CheckDecor(highlight: ids) }
            return CheckDecor(highlight: ids, preview: [PaperLineChange(lineID: target, before: finding.mergeBefore, text: suggestion, risky: finding.risky)])
        default:
            return CheckDecor(preview: [PaperLineChange(lineID: lineID, before: finding.before, text: suggestion, risky: finding.risky)])
        }
    }

    // MARK: Template preview

    /// 07.2：鼠标停在一套上，纸面临时换成这套（内容还是这份，`template-preview` 不保存）；nil 恢复原纸面。
    private func previewTemplate(_ template: ResumeTemplate?) {
        templatePreviewTask?.cancel()
        guard let template, panel == "template", !busy, TemplateSwitchSheet.key(template) != templateKey else {
            templatePreviewTask = nil
            if templatePreviewName != nil { templatePreviewName = nil; channel.previewTemplate(nil) }
            return
        }
        if let cached = templatePreviewCache[template.id] {
            templatePreviewName = template.name
            channel.previewTemplate(cached)
            return
        }
        let body: JSONValue = .object(["template_id": .string(template.id), "data": ResumeDocument.prepareForSave(doc, previous: saved)])
        templatePreviewTask = Task {
            // 预览失败就停在原纸面，不打扰；点卡片换模板时才报错
            guard let preview = try? await session.api.careerRequest(path: "/api/resumes/\(resumeID)/template-preview", method: "POST", query: [:], body: body)["preview"],
                  !Task.isCancelled, panel == "template" else { return }
            templatePreviewCache[template.id] = preview
            templatePreviewName = template.name
            channel.previewTemplate(preview)
        }
    }

    /// 选区所在的聚焦单元：条目或没有条目的模块。
    private func focusUnit(_ id: String) -> SectionFocus.Unit? {
        for section in sections {
            if section.nodeKey == id { return SectionFocus.unit(section: section) }
            if let entry = section["entries"]?.items.first(where: { $0.nodeKey == id }) { return SectionFocus.unit(entry: entry) }
        }
        return nil
    }

    /// 与 Web `importWarningMessage` 相同的导入质量提示文案。
    static func importWarningText(_ code: String) -> String {
        [
            "pdf_ocr_applied": "PDF 已使用 OCR，请核对姓名、日期和数字",
            "pdf_low_text_quality": "PDF 文本质量偏低，请重点核对遗漏和错字",
            "docx_embedded_images_omitted": "DOCX 中的图片未导入",
            "docx_textbox_order_may_change": "DOCX 文本框的阅读顺序可能发生变化",
            "document_heading_structure_missing": "原文缺少明确章节标题，已按全文识别",
            "source_quote_not_found": "部分结构化内容无法定位到原文短句",
            "unparsed_work_start_date": "部分工作开始日期未能识别",
            "unparsed_work_end_date": "部分工作结束日期未能识别",
            "unmapped_fragments_preserved": "部分原文已按自定义章节保留，请人工整理",
            "structure_enhancement_unavailable": "自动分段未完成，请检查板块和经历条目",
            "structure_needs_review": "部分经历可能识别有误，请检查板块和经历条目",
        ][code] ?? "部分内容需要人工核对"
    }

    private func sectionLabel(_ section: JSONValue) -> String {
        let title = ResumeDocument.value(section["title"])
        return title.isEmpty ? (ResumeDocument.sectionKinds.first { $0.key == section.text("semantic_kind") }?.label ?? "模块") : title
    }

    // MARK: Actions

    private func apply(_ resume: JSONValue) async {
        record = resume
        saved = resume["data"] ?? .null
        doc = saved
        savedStyle = resume["style"] ?? .null
        style = savedStyle
        title = resume.text("title")
        paperNote = nil
        // 换了正文来源（重新载入、换模板），上次检查的行号不再可靠
        check = ResumeCheckState()
        paperLine = nil
        templatePreviewTask?.cancel(); templatePreviewName = nil; templatePreviewCache = [:]
        if panel == "check" || panel == "line" { panel = nil; lineTarget = nil }
        importWarnings = (resume["import"]?["warnings"]?.items ?? resume["import_warnings"]?.items ?? []).compactMap(\.stringValue)
        saveFailed = false; canUndo = false; canRedo = false
        paperSeed = .object(["data": saved, "style": savedStyle])
        paperStyle = savedStyle
        paperGeneration += 1
    }

    /// 保存成功：更新已保存的基线与记录；保存期间用户继续编辑的内容保留，等下一次自动保存。
    private func applySaved(_ resume: JSONValue, keeping pending: (JSONValue, JSONValue, String)) async {
        let editedDuringSave = doc != pending.0 || style != pending.1 || title != pending.2
        let current = (doc, style, title)
        record = resume
        saved = resume["data"] ?? .null
        savedStyle = resume["style"] ?? .null
        if editedDuringSave {
            doc = current.0; style = current.1; title = current.2
            scheduleAutosave()
        } else {
            // 已保存的正文以服务端为准，但不重载纸面（保留光标与撤销历史）
            doc = saved; title = resume.text("title")
            if style != savedStyle { paperStyle = savedStyle; style = savedStyle }
        }
    }

    /// 自动保存（Web 串行保存队列）：停顿 1.5 秒后保存；正在保存时等这次完成再排下一次。
    private func scheduleAutosave() {
        guard record != nil, dirty, !conflict else { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            while saving { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled, dirty else { return }
            await save()
        }
    }

    /// 离开编辑器：有未保存修改时先保存，保存失败再询问是否放弃。
    private func leave() {
        guard dirty else { close(); return }
        Task {
            autosaveTask?.cancel()
            await save()
            if dirty { confirmLeave = true } else { close() }
        }
    }

    /// 编辑器顶栏“导出 PDF”：先保存当前修改，再按最新 lock_version 导出。
    private func exportPDF() async {
        if dirty { autosaveTask?.cancel(); await save() }
        guard !dirty, let record, let version = record["lock_version"]?.integer else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = ResumesView.fileName(title)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true; error = nil
        defer { exporting = false }
        do {
            let data = try await session.api.downloadResumePDF(id: resumeID, lockVersion: version)
            try data.write(to: destination, options: .atomic)
            notice = "已导出 PDF"
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure(); return }
            if case APIError.server(_, "RESUME_PDF_SNAPSHOT_STALE") = error { self.error = "简历已在其他设备更新，请重新载入后再导出。"; conflict = true }
            else if error is CocoaError { self.error = "PDF 已生成，但保存到所选位置失败，请换个位置重试。" }
            else { self.error = "导出 PDF 失败，请稍后重试。" }
        }
    }

    /// 引导写入前：有未保存修改先保存；保存失败不写。
    private func saveBeforeWrite() async -> Bool {
        if dirty { autosaveTask?.cancel(); await save() }
        return !dirty
    }

    /// Web `toggleGuide`：已结束的引导再次打开时请求重新开启；Esc 关闭当前面板。
    private func togglePanel(_ key: String) {
        if panel == key { panel = nil; return }
        panel = key
        if key == "guide", guide?.text("status") == "dismissed" {
            Task {
                if let reopened = try? await session.api.careerRequest(path: "/api/resumes/\(resumeID)/guide", method: "PUT", query: [:], body: nil)["guide"] { guide = reopened }
            }
        }
    }

    private func loadGuide() async {
        guard let loaded = try? await session.api.careerRequest(path: "/api/resumes/\(resumeID)/guide", method: "GET", query: [:], body: nil)["guide"] else { return }
        guide = loaded
        if loaded.text("status") == "active" { panel = "guide" }
    }

    private func load() async {
        loading = true; error = nil; conflict = false
        defer { loading = false }
        do {
            let result = try await session.api.careerRequest(path: "/api/resumes/\(resumeID)", method: "GET", query: [:], body: nil)
            guard let resume = result["resume"] else { throw APIError.invalidResponse }
            await apply(resume)
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            self.error = ResumeRequest.errorMessage(error, fallback: "简历读取失败，请稍后重试。")
        }
    }

    private func save() async {
        guard let record, dirty, !saving else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "简历名称不能为空。"; return }
        saving = true; error = nil; notice = nil
        defer { saving = false }
        var body: [String: JSONValue] = ["base_lock_version": record["lock_version"] ?? .number(1)]
        if doc != saved { body["data"] = ResumeDocument.prepareForSave(doc, previous: saved) }
        if style != savedStyle { body["style"] = style }
        if name != record.text("title") { body["title"] = .string(name) }
        do {
            let result = try await session.api.careerRequest(path: "/api/resumes/\(resumeID)", method: "PUT", query: [:], body: .object(body))
            guard let resume = result["resume"] else { throw APIError.invalidResponse }
            let pending = (doc, style, title)
            await applySaved(resume, keeping: pending)
            saveFailed = false; notice = nil
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            if case APIError.server(409, "RESUME_EDIT_CONFLICT") = error { conflict = true }
            self.error = ResumeDocument.saveError(error)
            saveFailed = true
        }
    }

    /// Web `applyTemplate`：随请求提交当前正文与名称；未保存的版式设置在新模板上重新套用，留待保存。
    private func applyTemplate(_ template: ResumeTemplate) async -> String? {
        guard let record, !busy else { return nil }
        previewTemplate(nil)
        saving = true; error = nil; notice = nil
        defer { saving = false }
        let pendingType = style != savedStyle ? ResumeTypeSettings.read(style) : nil
        var body: [String: JSONValue] = ["template_id": .string(template.id), "base_lock_version": record["lock_version"] ?? .number(1)]
        if doc != saved { body["data"] = ResumeDocument.prepareForSave(doc, previous: saved) }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != record.text("title") { body["title"] = .string(name) }
        do {
            let result = try await session.api.careerRequest(path: "/api/resumes/\(resumeID)/apply-template", method: "POST", query: [:], body: .object(body))
            guard let resume = result["resume"] else { throw APIError.invalidResponse }
            await apply(resume)
            if let pendingType { style = pendingType.apply(to: style) }
            notice = "已切换为「\(template.name)」"
            return nil
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            if case APIError.server(409, "RESUME_EDIT_CONFLICT") = error { conflict = true }
            let message = ResumeDocument.saveError(error)
            self.error = message
            return message
        }
    }

}




/// Figma 12.1「改这一条」：126×33 白色胶囊、#d6d4cc 细边；左 14.5 职绘图标 14，间距 6「改这一条」13 墨黑，再 6「⌘K」灰字。
/// 悬停只加深边线，不加灰底。
private struct LineChatTrigger: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ResumeTalkAvatar().scaleEffect(0.5).frame(width: 14, height: 14)
                Text("改这一条").font(V3.sans(13)).foregroundStyle(V3.txt)
                Text("⌘K").font(V3.sans(10.5)).foregroundStyle(Color(hex: 0xC4C3BD))
            }
            .padding(.leading, 14.5).padding(.trailing, 14).frame(height: 33)
            .background(.white, in: Capsule())
            .overlay(Capsule().stroke(hover ? V3.sub.opacity(0.6) : ResumeTalk.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help("改这一条（⌘K）").accessibilityLabel("改这一条")
    }
}

/// 统一工具栏里的无边框按钮（`.borderless`）：平时没有底色和描边，悬停或按下才出现 8% 黑底；`pressed` 是对应面板打开时的常亮态。
/// Web `.v3-crumb-back`：常态 `--v3-fnt`，悬停 `--v3-txt`，没有底色。
private struct BackCrumbStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hover || configuration.isPressed ? V3.txt : V3.fnt)
            .onHover { hover = $0 }
    }
}

private struct ToolbarPlainStyle: ButtonStyle {
    var strong = false
    var pressed = false
    /// 平时的文字色（规格行 #3c3c3a）；悬停 / 按下仍转墨黑。
    var ink: Color? = nil
    var radius: CGFloat = 6
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(!enabled ? V3.fnt2 : strong || pressed || hover ? V3.txt : (ink ?? V3.sub))
            .background(pressed || configuration.isPressed ? Color.black.opacity(0.08) : enabled && hover ? Color.black.opacity(0.05) : .clear,
                        in: RoundedRectangle(cornerRadius: radius))
            .onHover { hover = $0 }
    }
}

/// `.workbench-title`：标题随内容伸缩（最宽 420、最窄 40），28 高、内边距 6、14.5/500 居中；悬停灰底，编辑时白底描边。
private struct TitleField: View {
    @Binding var title: String
    @FocusState private var focused: Bool
    @State private var hover = false
    var body: some View {
        // 宽度按同一字体的隐藏文字量（系统字体量出来比随包字体窄，短标题也会被截成「我的…」）
        Text(verbatim: title.isEmpty ? " " : title).font(V3.sans(14, weight: .medium)).lineLimit(1).padding(.horizontal, 2).hidden()
            .overlay {
                TextField("", text: $title).textFieldStyle(.plain).font(V3.sans(14, weight: .medium)).lineLimit(1).truncationMode(.tail).foregroundStyle(V3.txt)
                    .multilineTextAlignment(.center).focused($focused).accessibilityLabel("简历标题")
            }
            .padding(.horizontal, 6).frame(minWidth: 40, maxWidth: 560).frame(height: 28).fixedSize(horizontal: true, vertical: false)
            .background(focused ? .white : hover ? V3.field : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? V3.cl : .clear))
            .onHover { hover = $0 }
    }
}
