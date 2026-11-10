import AppKit
import DrawOfferCore
import DrawOfferRender
import SwiftUI
import UniformTypeIdentifiers

/// 简历编辑（Web `ResumeWorkbench` 的对应页）：纸面即编辑器，与 Web 同一套 TipTap 编辑器、分页、斜杠菜单与选区工具栏
/// （`ResumeEditorPaperView`）；顶栏、右侧工具轨与大纲 / 模板 / 排版 / 检查 / 引导面板由原生实现。
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
    @State private var completeness: ResumeCompleteness?
    /// 可编辑纸面：`paperSeed` 变化时重新载入（打开、换模板、重新载入）；版式在排版面板改动时按 `styleRevision` 下发。
    @State private var paperSeed: JSONValue?
    @State private var paperGeneration = 0
    @State private var styleRevision = 0
    /// 纸面最近一次回报的版式：与它相同的变化来自纸面本身，不再下发。
    @State private var paperStyle: JSONValue?
    @State private var channel = ResumeEditorChannel()
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var askIntent = ""
    @State private var showType = false
    @State private var showOrder = false
    @State private var zoom = 1.0
    @State private var zoomBadge: Double?
    /// Web 存在 localStorage 的「页面排列」，只影响编辑时浏览方向。
    @AppStorage("workbench.pageArrangement") private var pageArrangement = "vertical"
    @State private var uploading = false
    /// 右侧工具轨当前打开的面板（Web 大纲 / 模板 / 排版 / 检查）。
    @State private var panel: String?
    /// 自动保存：停顿后串行保存；失败时显示横幅和重试。
    @State private var autosaveTask: Task<Void, Never>?
    @State private var saveFailed = false
    @State private var exporting = false
    @State private var focusUnit: SectionFocus.Unit?
    @State private var importWarnings: [String] = []
    /// 这份简历的写作引导（Web：进入编辑器先读；没有引导时不显示入口，进行中时自动展开）。
    @State private var guide: JSONValue?

    private var dirty: Bool { record != nil && (doc != saved || style != savedStyle || title != (record?.text("title") ?? "")) }
    private var sections: [JSONValue] { doc["sections"]?.items ?? [] }
    private var templateKey: String { style["template_snapshot"]?.text("template_key") ?? "" }
    private var busy: Bool { saving || uploading }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !importWarnings.isEmpty { importBanner }
            if loading && record == nil { ProgressView("正在读取简历…").frame(maxWidth: .infinity, maxHeight: .infinity).background(Self.canvas) }
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
        .onChange(of: doc) { _, _ in scheduleAutosave(); completeness = ResumeCompleteness.evaluate(doc) ?? completeness }
        .onChange(of: style) { _, _ in
            // 排版面板改的版式下发给纸面；纸面自己回报的（头像尺寸）不再回送
            if style != paperStyle { styleRevision += 1 }
            scheduleAutosave()
        }
        .onChange(of: title) { _, _ in scheduleAutosave() }
        .onDisappear { autosaveTask?.cancel() }
        .confirmationDialog("放弃未保存的修改？", isPresented: $confirmLeave) {
            Button("放弃修改", role: .destructive, action: close)
            Button("继续编辑", role: .cancel) {}
        }
        .sheet(item: Binding(get: { focusUnit.map { FocusTarget(unit: $0) } }, set: { if $0 == nil { focusUnit = nil } })) { target in
            SectionFocusSheet(resumeID: resumeID, unit: target.unit, intent: askIntent, adopt: { lineID, text in
                guard let next = SectionFocus.replacing(doc, lineID: lineID, with: text) else { return false }
                doc = next
                channel.replaceData(next)
                return true
            }, close: { focusUnit = nil; askIntent = "" })
        }
        .sheet(isPresented: $showOrder) {
            SectionOrderSheet(sections: sections, columns: ResumeLayout.columns(data: doc, style: style),
                              apply: { order in channel.send(.reorder(order.map(\.nodeKey))) }, close: { showOrder = false })
        }
    }

    // MARK: Canvas

    /// `.workbench-canvas`：#f3f3f0 灰底；右侧工具卡片 56 宽（top 15 / right 16）浮在画布上，
    /// 面板卡片在它左边 12（right 84、top 15、bottom 16、380 宽）；面板打开时画布右侧让出 464，否则 72。
    static let canvas = Color(hex: 0xF3F3F0)
    private var drawerOpen: Bool { panel != nil && panel != "guide" }

    private var canvasArea: some View {
        preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.trailing, guideOpen ? 560 : drawerOpen ? 464 : 72)
            .animation(.timingCurve(0.2, 0, 0, 1, duration: 0.22), value: drawerOpen || guideOpen)
        .background(Self.canvas)
        .overlay(alignment: .topLeading) {
            // `.has-guide`：纸面与引导当成一组居中，引导从画布 50% + 120 开始（>1280 宽）；1101–1280 贴右 380 宽
            if guideOpen, let guide {
                GeometryReader { geometry in
                    let wide = geometry.size.width > 1280
                    ResumeGuidePanel(resumeID: resumeID, guide: Binding(get: { guide }, set: { self.guide = $0 }), data: doc,
                                     templateID: record?["template_id"]?.stringValue,
                                     saveFirst: { await saveBeforeWrite() },
                                     applied: { resume in Task { await apply(resume) } },
                                     undo: { before in doc = before; channel.replaceData(before) },
                                     exportPDF: { Task { await exportPDF() } },
                                     close: { panel = nil })
                        .frame(width: wide ? 440 : 380)
                        .padding(.top, 15)
                        .offset(x: wide ? geometry.size.width / 2 + 120 : geometry.size.width - 88 - 380)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 12) {
                if drawerOpen && !guideOpen {
                    drawerCard { panelView }
                }
                toolRail
            }.padding(.top, 15).padding(.trailing, 16).padding(.bottom, 16)
        }
        .overlay(alignment: .top) { if saveFailed { saveNotice.padding(.top, 15).padding(.trailing, guideOpen ? 560 : drawerOpen ? 464 : 72) } }
        .overlay { if let zoomBadge { zoomFeedback(zoomBadge) } }
    }

    /// `.wb3-drawer`：380 宽、圆角 14、#e4e4e0 描边、白底、0 8 24 rgba(0,0,0,.08)。
    private func drawerCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .frame(width: 380).frame(maxHeight: .infinity, alignment: .top)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(V3.cl))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 8)
            .accessibilityElement(children: .contain)
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

    /// Web 顶栏的保存状态：编辑中 / 保存中 / 已保存 / 保存失败。
    private var saveStatus: (text: String, color: Color) {
        if saving { return ("保存中…", V3.fnt) }
        if saveFailed { return ("保存失败", V3.red) }
        if dirty { return ("编辑中", V3.fnt) }
        return ("已保存", V3.green)
    }

    /// `.wb3-head`：57 高（含 1px 下边线）、左右 16、三栏网格。左：32 圆角 8 的主页钮、13/500「简历编辑」、
    /// 1×16 分隔（左 20 右 6）、28×28 撤销/重做；中：14.5/500 居中标题（随内容伸缩，最宽 420）与保存状态；
    /// 右：32 高完整度胶囊（迷你仪表盘 + 分数 + 等级）与 104 宽「导出 PDF」。
    private var toolbar: some View {
        ZStack {
            HStack(spacing: 0) {
                Button { leave() } label: {
                    Image(systemName: "house").font(.system(size: 13)).foregroundStyle(V3.sub).frame(width: 32, height: 32).contentShape(Rectangle())
                }.buttonStyle(HeadIconStyle(radius: 8)).help("返回全部简历").accessibilityLabel("返回全部简历")
                Text("简历编辑").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.sub).padding(.leading, 8)
                Rectangle().fill(V3.line).frame(width: 1, height: 16).padding(.leading, 20).padding(.trailing, 6)
                HStack(spacing: 2) {
                    Button { channel.send(.undo) } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 12)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                        .buttonStyle(HeadIconStyle(radius: 7)).disabled(!canUndo || busy).help("撤销（⌘Z）").accessibilityLabel("撤销（⌘Z）")
                        .keyboardShortcut("z", modifiers: .command)
                    Button { channel.send(.redo) } label: { Image(systemName: "arrow.uturn.forward").font(.system(size: 12)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                        .buttonStyle(HeadIconStyle(radius: 7)).disabled(!canRedo || busy).help("重做（⌘Y）").accessibilityLabel("重做（⌘Y）")
                        .keyboardShortcut("y", modifiers: .command)
                }
                Spacer(minLength: 16)
                if conflict { Button("重新载入") { Task { await load() } }.buttonStyle(V3ButtonStyle(kind: .ghost)).padding(.trailing, 8) }
                if let completeness {
                    Button { togglePanel("check") } label: {
                        HStack(spacing: 0) {
                            MiniGauge(score: completeness.score).padding(.trailing, 7)
                            Text("\(completeness.score)").font(V3.number(12.5, weight: .semibold)).foregroundStyle(V3.txt)
                            Text(completeness.level).font(V3.sans(11.5)).foregroundStyle(V3.sub).padding(.leading, 6)
                        }
                        .padding(.leading, 10).padding(.trailing, 14).frame(height: 32)
                        .background(panel == "check" ? V3.field : .white, in: Capsule())
                        .overlay(Capsule().stroke(panel == "check" ? Color(hex: 0xDCDCD8) : V3.cl)).contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityLabel("简历完整度 \(completeness.score) 分，\(completeness.level)，打开简历检查")
                        .accessibilityAddTraits(panel == "check" ? .isSelected : [])
                }
                Button(exporting ? "导出中…" : "导出 PDF") { Task { await exportPDF() } }
                    .buttonStyle(V3ButtonStyle(kind: .dark, height: 32, width: 104)).disabled(exporting || record == nil).padding(.leading, 8)
            }
            HStack(spacing: 14) {
                TitleField(title: $title)
                saveStatusView
            }.frame(maxWidth: 560)
        }
        .padding(.horizontal, 16).frame(height: 56)
        .background(.white).overlay(alignment: .bottom) { Rectangle().fill(V3.line).frame(height: 1) }.frame(height: 57, alignment: .top)
    }

    /// `WorkbenchSaveStatus`：已保存 绿色勾 / 编辑中 橙点 / 保存中… 转圈 / 保存失败 · 原因 红点；11.5px #6c6c65。
    private var saveStatusView: some View {
        HStack(spacing: 5) {
            if saving { ProgressView().controlSize(.mini).frame(width: 13, height: 13) }
            else if saveFailed { Circle().fill(V3.red).frame(width: 7, height: 7).padding(.horizontal, 3) }
            else if dirty { Circle().fill(V3.orange).frame(width: 7, height: 7).padding(.horizontal, 3) }
            else { Image(systemName: "checkmark.circle").font(.system(size: 11)).foregroundStyle(V3.green) }
            Text(saving ? "保存中…" : saveFailed ? "保存失败 · \(conflict ? "简历已在其他地方修改" : "请重试")" : dirty ? "编辑中" : "已保存")
        }
        .font(V3.sans(11.5)).foregroundStyle(saveFailed ? V3.red : V3.fnt).fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// `.wb3-rail`：56 宽白卡、圆角 14、内边距 5/3、间距 2、0 6 20 rgba(0,0,0,.06)；每项 48×52、圆角 10、上 9，
    /// 18 号图标与 10.5px 文字间距 4，选中 #f4f4f2 底与 500 字重；「检查」右上 16 高橙色待完善数角标。
    private var toolRail: some View {
        VStack(spacing: 2) {
            railButton("outline", "大纲", "list.bullet.indent")
            railButton("template", "模板", "rectangle.on.rectangle", label: "简历模板")
            railButton("type", "排版", "textformat", label: "排版")
            railButton("check", "检查", "checkmark.circle", label: "简历检查", badge: completeness.map { $0.pendingCount } ?? 0)
            if guide != nil { railButton("guide", "引导", "bubble.left", label: "引导创建简历") }
        }
        .padding(.vertical, 5).padding(.horizontal, 3).frame(width: 56)
        .background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(V3.cl))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 6)
        .accessibilityElement(children: .contain).accessibilityLabel("编辑工具")
    }

    private var guideOpen: Bool { panel == "guide" && guide != nil }

    private func railButton(_ key: String, _ label: String, _ symbol: String, label accessibility: String? = nil, badge: Int = 0) -> some View {
        let active = panel == key
        return Button { togglePanel(key) } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 18, height: 18)
                Text(label).font(V3.sans(10.5, weight: active ? .medium : .regular)).frame(height: 13)
            }
            .padding(.top, 9).frame(width: 48, height: 52, alignment: .top)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                if badge > 0 {
                    Text("\(badge)").font(V3.number(9.5, weight: .bold)).foregroundStyle(.white).padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16).background(V3.orange, in: Capsule()).offset(x: 30, y: 4).accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(RailItemStyle(active: active))
        .accessibilityLabel(accessibility ?? label).accessibilityAddTraits(active ? .isSelected : [])
        .disabled(key == "template" && (busy || conflict))
    }

    @ViewBuilder private var panelView: some View {
        switch panel {
        case "outline":
            OutlinePanel(sections: sections, identity: doc["identity"], label: sectionLabel, columns: ResumeLayout.columns(data: doc, style: style),
                         flagged: completeness?.flaggedKinds ?? [], disabled: busy,
                         jump: { channel.send(.jump($0 == "identity" ? nil : $0)) },
                         move: { from, to in channel.send(.reorder(doc.moving([.key("sections")], from: from, to: to)["sections"]?.items.map(\.nodeKey) ?? [])) },
                         reorder: { order in channel.send(.reorder(order.map(\.nodeKey))) },
                         rename: { index, value in if let id = (sections.indices.contains(index) ? sections[index].nodeKey : nil) { channel.send(.rename(id, value)) } },
                         remove: { index in if let id = (sections.indices.contains(index) ? sections[index].nodeKey : nil) { channel.send(.remove(id)) } },
                         add: { kind in channel.send(.add(kind: kind.key, title: kind.label)) },
                         close: { panel = nil })
        case "type":
            VStack(alignment: .leading, spacing: 0) {
                WorkbenchPanelHeader(title: "设置", closeLabel: "关闭排版面板") { panel = nil }
                if ResumeTypeSettings.read(style) != nil { ScrollView { TypeSettingsPanel(settings: typeBinding, arrangement: $pageArrangement, disabled: busy) } }
                else { Text("当前模板不支持调整排版").font(V3.sans(12.5)).foregroundStyle(V3.fnt).padding(24) }
            }
        case "template":
            TemplateSwitchSheet(currentKey: templateKey, disabled: busy || conflict, apply: applyTemplate, close: { panel = nil })
        case "check":
            if let completeness { CompletenessPanel(result: completeness, close: { panel = nil }) }
        default: EmptyView()
        }
    }

    private func panelHeader(_ title: String, subtitle: String) -> some View {
        WorkbenchPanelHeader(title: title, subtitle: subtitle, closeLabel: "关闭\(title)") { panel = nil }
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
                                  liveStyle: style, styleRevision: styleRevision, zoom: zoom, horizontal: pageArrangement == "horizontal",
                                  channel: channel, api: session.api, onEvent: handlePaper)
                .id(paperGeneration)
                .overlay(alignment: .bottom) {
                    if let paperNote { Text(paperNote).font(V3.sans(11.5)).foregroundStyle(V3.orange).padding(8).background(.white, in: Capsule()).padding(.bottom, 16) }
                }
                .background {
                    Group {
                        Button("") { setZoom(zoom + 0.1) }.keyboardShortcut("=", modifiers: .command)
                        Button("") { setZoom(zoom - 0.1) }.keyboardShortcut("-", modifiers: .command)
                        Button("") { setZoom(1) }.keyboardShortcut("0", modifiers: .command)
                    }.opacity(0).accessibilityHidden(true)
                }
        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
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
        case .ask(let unitID, _, _, let instruction):
            guard let unit = focusUnit(unitID) else { paperNote = "这一行暂时不能聚焦修改"; return }
            askIntent = instruction
            focusUnit = unit
        case .error(let message): paperNote = message
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
        importWarnings = (resume["import"]?["warnings"]?.items ?? resume["import_warnings"]?.items ?? []).compactMap(\.stringValue)
        completeness = ResumeCompleteness.evaluate(saved)
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
        completeness = ResumeCompleteness.evaluate(saved)
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


private struct FocusTarget: Identifiable { let unit: SectionFocus.Unit; var id: String { unit.id } }


/// 顶栏 32 / 28 的图标钮：悬停 #f4f4f2 底、文字转 txt；禁用时 fnt2。
private struct HeadIconStyle: ButtonStyle {
    var radius: CGFloat
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(!enabled ? V3.fnt2 : hover ? V3.txt : V3.sub)
            .background(enabled && (hover || configuration.isPressed) ? V3.field : .clear, in: RoundedRectangle(cornerRadius: radius))
            .onHover { hover = $0 }
    }
}

/// 工具卡片的一项：悬停与选中 #f4f4f2 底、文字 txt；默认 sub、禁用 fnt2。
private struct RailItemStyle: ButtonStyle {
    let active: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(!enabled ? V3.fnt2 : active || hover ? V3.txt : V3.sub)
            .background(active || (enabled && hover) ? V3.field : .clear, in: RoundedRectangle(cornerRadius: 10))
            .onHover { hover = $0 }
    }
}

/// `.workbench-title`：标题随内容伸缩（最宽 420、最窄 40），28 高、内边距 6、14.5/500 居中；悬停灰底，编辑时白底描边。
private struct TitleField: View {
    @Binding var title: String
    @FocusState private var focused: Bool
    @State private var hover = false
    var body: some View {
        TextField("", text: $title).textFieldStyle(.plain).font(V3.sans(14.5, weight: .medium)).foregroundStyle(V3.txt)
            .multilineTextAlignment(.center).focused($focused).accessibilityLabel("简历标题")
            .padding(.horizontal, 6).frame(height: 28)
            .frame(width: min(420, max(40, (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14.5, weight: .medium)]).width + 14)))
            .background(focused ? .white : hover ? V3.field : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? V3.cl : .clear))
            .onHover { hover = $0 }
    }
}

/// `WorkbenchGauge mini`：18×16，半径 7、线宽 3 的 240° 圆弧，浅灰轨道 + 灰到黑渐变弧 + 末端白色旋钮。
struct MiniGauge: View {
    let score: Int
    var body: some View { WorkbenchGaugeShape(score: score, mini: true) }
}

/// Web `WorkbenchGauge`：起点 150°、扫过 240°；大号半径 78、线宽 10，带每 5 分一格的刻度（20 的倍数与 40/70/90 加长）。
struct WorkbenchGaugeShape: View {
    let score: Int
    var mini = false
    var extra: CGFloat = 0
    static func geometry(mini: Bool, extra: CGFloat = 0) -> (r: CGFloat, sw: CGFloat, width: CGFloat, height: CGFloat, cx: CGFloat, cy: CGFloat) {
        let r: CGFloat = mini ? 7 : 78, sw: CGFloat = mini ? 3 : 10, pad: CGFloat = mini ? 2 : 18
        let width = ceil(2 * (r + pad)), cy = r + pad
        return (r, sw, width, ceil(cy + r * 0.5 + sw / 2 + 2 + extra), width / 2, cy)
    }
    var body: some View {
        let g = Self.geometry(mini: mini, extra: extra)
        Canvas { context, _ in
            func point(_ angle: Double, _ radius: CGFloat) -> CGPoint {
                CGPoint(x: g.cx + radius * cos(angle * .pi / 180), y: g.cy + radius * sin(angle * .pi / 180))
            }
            func arc(_ from: Double, _ to: Double) -> Path {
                var path = Path()
                path.addArc(center: CGPoint(x: g.cx, y: g.cy), radius: g.r, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
                return path
            }
            let end = 150 + 240 * max(0.5, min(100, Double(score))) / 100
            context.stroke(arc(150, 390), with: .color(Color(hex: 0xECECEA)), style: StrokeStyle(lineWidth: g.sw, lineCap: .round))
            context.stroke(arc(150, end), with: .linearGradient(Gradient(colors: [Color(hex: 0xA3A39C), Color(hex: 0x1D1D1B)]),
                                                                startPoint: .zero, endPoint: CGPoint(x: g.width, y: 0)),
                           style: StrokeStyle(lineWidth: g.sw, lineCap: .round))
            if !mini {
                for index in 0...20 {
                    let value = index * 5, angle = 150 + 240 * Double(value) / 100
                    let level = value == 40 || value == 70 || value == 90, major = value % 20 == 0 || level
                    let r1 = g.r + g.sw / 2 + 5
                    var tick = Path(); tick.move(to: point(angle, r1)); tick.addLine(to: point(angle, r1 + (major ? 6 : 3)))
                    context.stroke(tick, with: .color(Color(hex: level ? 0x96968F : major ? 0xC4C4BE : 0xDCDCD8)),
                                   style: StrokeStyle(lineWidth: level ? 1.4 : 1, lineCap: .round))
                }
                let halo = g.sw * 1.05, knob = point(end, g.r)
                context.fill(Path(ellipseIn: CGRect(x: knob.x - halo, y: knob.y - halo, width: halo * 2, height: halo * 2)), with: .color(Color(hex: 0x1D1D1B).opacity(0.08)))
            }
            let knob = point(end, g.r), kr = g.sw * (mini ? 0.62 : 0.78)
            let circle = Path(ellipseIn: CGRect(x: knob.x - kr, y: knob.y - kr, width: kr * 2, height: kr * 2))
            context.fill(circle, with: .color(.white))
            context.stroke(circle, with: .color(Color(hex: 0x1D1D1B)), lineWidth: g.sw * (mini ? 0.34 : 0.3))
        }
        .frame(width: g.width, height: g.height).accessibilityHidden(true)
    }
}

/// `WorkbenchPanelHeader`：73 高（含 1px 下边线）、内边距 20/24；标题 16/500 行高 19、说明 11.5 行高 14、间距 6；右上 28 关闭钮（-4/-6）。
struct WorkbenchPanelHeader: View {
    let title: String
    var subtitle: String? = nil
    var closeLabel: String
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(V3.sans(16, weight: .medium)).foregroundStyle(V3.txt).frame(height: 19)
                if let subtitle { Text(subtitle).font(V3.sans(11.5)).foregroundStyle(V3.fnt).frame(height: 14) }
            }
            Spacer()
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                .buttonStyle(HeadIconStyle(radius: 7)).accessibilityLabel(closeLabel).padding(.top, -4).padding(.trailing, -6)
        }
        .padding(.horizontal, 24).padding(.top, 20).frame(height: 72, alignment: .top)
        .overlay(alignment: .bottom) { Rectangle().fill(V3.line).frame(height: 1) }.frame(height: 73, alignment: .top)
    }
}
