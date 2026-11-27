import AppKit
import DrawOfferCore
import DrawOfferRender
import SwiftUI
import UniformTypeIdentifiers

/// 简历编辑（Web `ResumeWorkbench` 的对应页）：纸面即编辑器，与 Web 同一套 TipTap 编辑器、分页、斜杠菜单与选区工具栏
/// （`ResumeEditorPaperView`）；顶栏、排版卡片、模板栏、引导、右上角小绘与右下角缩放由原生实现。
/// 保存（Web a667ae1ba 起）：只有点顶栏“保存”或 ⌘S 才提交 `PUT /api/resumes/{id}` 的 data、style 与 base_lock_version；
/// 没保存的修改每分钟写到这台电脑（`ResumeDraftKeeper`），下次打开时恢复；冲突时提示重新载入，不覆盖他处的修改。
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
    /// 右上角小绘的白板（C1）是否展开，以及选了某项后的一句回应。
    @State private var orbOpen = false
    @State private var orbReply: String?
    /// 智能排版（Web `runAiLayout`）：进行中这一轮的编号（量纸 → 调接口 → 交回纸面写入，晚到的旧回报按编号丢掉）。
    @State private var layoutRun: String?
    @State private var layoutTask: Task<Void, Never>?
    /// 小绘白板收着时左边说的一句（排好了 / 没要动的），带“撤销”时可整批撤回。
    @State private var orbSaid: OrbSaid?
    @State private var zoom = 1.0
    @State private var zoomBadge: Double?
    @State private var uploading = false
    /// 右侧工具轨当前打开的面板（Web 大纲 / 模板 / 排版）。
    @State private var panel: String?
    /// 保存失败：顶部常驻“简历没有保存”（Web `wb3-save-notice`），保存成功后消失。
    @State private var saveFailed = false
    @State private var saveErrorCode: String?
    /// Web `Toast kind="error" persistent`：标题“简历没有保存”、说明按错误码、动作“重试”（点了先收起，没存成再出来）。
    @State private var saveNotice: NoticeToastItem?
    /// 顶部提示（Web `Toast`）：导出、换模板、保存并离开没存成。
    @State private var toast: NoticeToastItem?
    /// 本地草稿：第一次改动起每分钟写一次，离开时立刻写；保存后删掉。
    @State private var draftKeeper = ResumeDraftKeeper(store: ResumeDraftStore.standard())
    @State private var draftTimer: Task<Void, Never>?
    /// K3：光标停在一段 0.8 秒后小绘左边说“想改「某段」这段？点我改”。
    @State private var orbHint: String?
    @State private var orbHintDismissed = false
    /// 小绘停在段旁改一段（Web `EditorChat`）：要改的段（空 = 先挑一段）与外部带进来的一句话。
    @State private var chatEntry = ""
    @State private var chatRequest: ResumeEditorChatView.Request?
    @State private var chatSeq = 0
    @State private var menuHover = false
    @State private var exporting = false
    @State private var importWarnings: [String] = []
    /// 新建引导（A2，Web `GuideFlow`）：引导进行中时整页换成引导——顶栏换成六步进度，纸右边一列一次问一件事。
    @State private var guideFlow: ResumeGuideFlow?
    /// 纸面上报的光标所在行（小绘按它说“想改「X」”，⌘K 改这一条）；不在可改的行上或正在打字时为 nil。
    @State private var paperLine: PaperLine?
    /// 纸面实际页数（排版卡片“共 N 页”）。
    @State private var pageCount = 1
    /// 07.2 模板悬停预览：纸面临时换成的那套模板名。
    @State private var templatePreviewName: String?
    @State private var templatePreviewTask: Task<Void, Never>?
    /// 同一份正文下各模板的预览结果；正文一改就作废。
    @State private var templatePreviewCache: [String: JSONValue] = [:]

    private var dirty: Bool { record != nil && (doc != saved || style != savedStyle || title != (record?.text("title") ?? "")) }
    private var sections: [JSONValue] { doc["sections"]?.items ?? [] }
    private var templateKey: String { style["template_snapshot"]?.text("template_key") ?? "" }
    private var busy: Bool { saving || uploading }
    private var saveStatus: ResumeSave.Status { saving ? .saving : saveFailed ? .error : .idle }
    private var userID: String { session.coachUser }

    var body: some View {
        VStack(spacing: 0) {
            if let guideFlow {
                ResumeGuideHead(flow: guideFlow, back: leave)
                    .padding(.leading, 84).padding(.trailing, 14).frame(height: 32).padding(.bottom, 20).background(Self.canvas)
            } else { toolbar }
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
        .onExitCommand { if orbOpen { orbOpen = false } else if panel != nil { panel = nil } else { orbHintDismissed = true } }
        .onChange(of: doc) { _, next in templatePreviewCache = [:]; guideFlow?.paper = next; noteDraft() }
        .onChange(of: panel) { _, next in
            if next != "template" { previewTemplate(nil) }
            if next != nil { orbOpen = false }
        }
        .onChange(of: paperLine?.unitID) { _, _ in orbReply = nil }
        .onChange(of: style) { _, _ in
            // 排版面板改的版式下发给纸面；纸面自己回报的（头像尺寸）不再回送
            if style != paperStyle { styleRevision += 1 }
            noteDraft()
        }
        .onChange(of: title) { _, _ in noteDraft() }
        .onDisappear { draftTimer?.cancel(); draftKeeper.flush(); layoutTask?.cancel() }
        // Web `ConfirmDialog`「修改还没保存」：暂不保存（修改留在这台电脑，下次打开时恢复）/ 保存并离开
        .centeredConfirmation(ResumeSave.leaveTitle, isPresented: $confirmLeave) {
            Button(ResumeSave.leaveConfirm) { Task { await saveAndLeave() } }.keyboardShortcut(.defaultAction)
            Button(ResumeSave.leaveDiscard) { leaveNow() }
            Button("取消", role: .cancel) {}
        } message: { Text(ResumeSave.leaveMessage) }
    }

    // MARK: Canvas

    /// Figma 03 页 07.0：编辑器整页铺满窗口，#f3f3f0 画布，顶栏与红绿灯同一行、和画布同底。
    static let canvas = Color(hex: 0xF3F3F0)
    /// 排版卡片（06.2）：顶栏「排版」打开，320 宽白卡贴在纸右边 28、和纸上沿对齐，纸不让开。
    /// 改这一条（12.1–12.6）：纸右边一列对话，和引导一样不加卡片。
    private var typeOpen: Bool { panel == "type" }
    private var lineOpen: Bool { panel == "line" && lineTarget != nil }
    private var guideOpen: Bool { guideFlow != nil }
    /// 小绘停在段旁改一段（Web `.wbx-chat`，C2–C6）：列宽 480、距纸 40。
    private var chatOpen: Bool { panel == "chat" && !guideOpen }
    private var columnOpen: Bool { guideOpen || lineOpen || chatOpen }
    static let chatWidth: CGFloat = 480
    static let chatGap: CGFloat = 40
    /// 模板栏（07.1）：顶栏「模板」打开，贴编辑器右边一整列（跟 Web 分区 18 一样，和右上角“模板”按钮同侧），纸往左让开。
    private var templateOpen: Bool { panel == "template" }
    /// 07.1 模板栏宽 343（含左侧 1 的细线）；12.x 对话列 400、距纸 52。
    static let railWidth: CGFloat = 343
    static let columnGap: CGFloat = 52
    /// 编辑器里 100% 时纸面宽 560（稿 A4 Page 560）。
    static let paperWidth: CGFloat = 560
    /// 纸面上沿离画布顶（稿 06.1：纸距顶栏下沿 57）；渲染器自己在纸上方留 8。
    static let paperTop: CGFloat = 49
    static let typeGap: CGFloat = 28
    static let zoomRange = 0.5...1.6

    /// 纸与右边一列当成一组居中：纸面宽 560 × 缩放（渲染器 EDITOR_PAGE_BASE_SCALE = 560 / 794，稿 A4 Page 560）；放不下时右列贴右 24。
    /// 引导列 440、距纸 64（`.gf-stage`），对话列 400、距纸 52。
    private func columnLayout(width: CGFloat) -> (paperTrailing: CGFloat, columnX: CGFloat) {
        let column = guideOpen ? ResumeGuideColumn.width : chatOpen ? Self.chatWidth : ResumeTalk.columnWidth
        let gap = guideOpen ? 64 : chatOpen ? Self.chatGap : Self.columnGap
        let paper = Self.paperWidth * zoom
        let group = paper + gap + column
        if width >= group + 80 {
            let left = (width - group) / 2
            return (max(0, width - 2 * left - paper), left + paper + gap)
        }
        return (column + gap, width - column - 24)
    }

    private var canvasArea: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - (templateOpen ? Self.railWidth : 0)
            let layout = columnLayout(width: width)
            ZStack(alignment: .topLeading) {
                preview.padding(.top, Self.paperTop).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, (columnOpen ? layout.paperTrailing : 0) + (templateOpen ? Self.railWidth : 0))
                    .animation(.timingCurve(0.2, 0, 0, 1, duration: 0.22), value: columnOpen || templateOpen)
                    .overlay(alignment: .topLeading) {
                        Group {
                            if !guideOpen, lineOpen, let current = lineTarget {
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
                    .overlay(alignment: .topLeading) {
                        if typeOpen && !guideOpen {
                            // 纸居中：纸右沿 = (宽 + 纸宽) / 2；放不下时贴右 24
                            let x = min((width + Self.paperWidth * zoom) / 2 + Self.typeGap, width - 320 - 24)
                            typeCard.offset(x: max(24, x), y: Self.paperTop + 8)
                                .transition(.opacity.combined(with: .offset(y: -4)))
                        }
                    }
                // 段旁对话同样不挂在纸面上（换上会重载纸面）
                if chatOpen {
                    ResumeEditorChatView(resumeID: resumeID, units: chatUnits, entryID: $chatEntry, document: doc, request: chatRequest,
                                         write: { next in doc = next; channel.replaceData(next) },
                                         decorate: { highlight, preview in channel.send(.decorate(source: "chat", highlight: highlight, preview: preview)) },
                                         saveFirst: { await saveBeforeWrite() },
                                         notice: { toast = .attention($0) },
                                         close: { panel = nil })
                        .frame(width: Self.chatWidth).frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 24).padding(.bottom, 76)
                        .offset(x: layout.columnX)
                        .transition(.opacity)
                }
                // 引导列不挂在纸面上：纸面换稿（paperGeneration）会连带重建挂在它上面的视图，各步写到一半的状态会丢
                if let guideFlow {
                    ResumeGuideColumn(flow: guideFlow).frame(maxHeight: .infinity, alignment: .top).offset(x: layout.columnX)
                }
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
        .overlay(alignment: .topTrailing) {
            // 小绘停在段旁（改这一条 / 改这一段）时，右上角这朵先隐去
            if record != nil, !lineOpen, !guideOpen, !chatOpen { orb.padding(.top, 20).padding(.trailing, 24 + (templateOpen ? Self.railWidth : 0)) }
        }
        .overlay(alignment: .bottomTrailing) {
            if record != nil, paperSeed != nil, !guideOpen {
                ResumeZoomBar(zoom: zoom, range: Self.zoomRange) { setZoom($0) }
                    .coachTarget(canvasCoach.open && panel == nil && !orbOpen, label: "编辑器画布引导",
                                 message: "按住纸外空白处可以拖动，双击回到中间。\n按住 ⌘ 滚动滚轮缩放，或点这里的 − 和 +。",
                                 actions: [CoachAction(label: "知道了")]) { canvasCoach.dismiss() }
                    .padding(.trailing, 24 + (templateOpen ? Self.railWidth : 0)).padding(.bottom, 22)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                // 保存失败：常驻顶部（Figma 21 · C3），不自动消失、不能关，保存成功后消失
                NoticeToast(item: $saveNotice) { _ in Task { await save() } }
                NoticeToast(item: $toast)
            }.padding(.top, 15)
        }
        .overlay { if let zoomBadge { zoomFeedback(zoomBadge) } }
        .animation(.easeOut(duration: 0.16), value: typeOpen)
    }

    /// 14.2：每份简历第一次打开时指一下缩放条（Web `useScenario("editor-canvas:<id>")`）。
    private var canvasCoach: CoachSlot { CoachSlot(id: "editor-canvas:\(resumeID)", user: session.coachUser) }

    @ViewBuilder private var typeCard: some View {
        if ResumeTypeSettings.read(style) != nil {
            TypeCard(settings: typeBinding, pageCount: pages, sections: sections,
                     columns: ResumeLayout.columns(data: doc, style: style), label: sectionLabel, disabled: busy,
                     reorder: { order in channel.send(.reorder(order.map(\.nodeKey))) },
                     rename: { id, title in channel.send(.rename(id, title)) },
                     remove: { id in channel.send(.remove(id)) })
        } else {
            Text("当前模板不支持调整排版").font(V3.sans(12.5)).foregroundStyle(V3.fnt).padding(24).frame(width: 320)
                .background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(V3.cl))
        }
    }

    // MARK: 小绘

    /// 光标所在段与它的名字（「项目经历 · 分布式任务调度平台」）。
    private var cursorUnit: (unit: SectionFocus.Unit, label: String)? {
        guard let id = paperLine?.unitID, let unit = focusUnit(id) else { return nil }
        let section = sections.first { $0.nodeKey == id || ($0["entries"]?.items ?? []).contains { $0.nodeKey == id } }
        let label = [section.map(sectionLabel) ?? "", section?.nodeKey == id ? "" : unit.heading].filter { !$0.isEmpty }.joined(separator: " · ")
        return (unit, label)
    }

    private var orb: some View {
        let cursor = cursorUnit
        return HStack(alignment: .top, spacing: 12) {
            if orbOpen {
                ResumeOrbBoard(dialogue: ResumeOrb.dialogue(unitID: cursor?.unit.id, unitLabel: cursor?.label, layoutBusy: layoutRun != nil),
                               pick: runOrb, say: { sayToOrb($0) }, close: { orbOpen = false }, reply: orbReply)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .offset(x: 8)))
            } else if layoutRun != nil {
                ResumeOrbNudge(kind: .busy, text: "正在排版…", actionLabel: "停下", action: cancelLayout)
                    .frame(height: 40).transition(.opacity.combined(with: .offset(x: 8)))
            } else if let orbSaid {
                ResumeOrbNudge(kind: .said, text: orbSaid.text, actionLabel: orbSaid.undo ? "撤销" : nil,
                               action: orbSaid.undo ? { channel.send(.layoutUndo) } : nil)
                    .frame(minHeight: 40).transition(.opacity.combined(with: .offset(x: 8)))
                    .accessibilityElement(children: .contain).accessibilityLabel(orbSaid.text)
            } else if let orbHint, let cursor, cursor.unit.id == orbHint {
                // K3：光标停在一段时一直写着“想改「某段」这段？点我改”
                ResumeOrbNudge(kind: .said, text: ResumeOrb.hint(cursor.label), actionLabel: ResumeOrb.hintAction,
                               action: { openChat(entry: orbHint) })
                    .frame(minHeight: 40).transition(.opacity.combined(with: .offset(x: 8)))
                    .accessibilityElement(children: .contain).accessibilityLabel(ResumeOrb.hint(cursor.label))
            }
            ResumeEditorOrb(open: orbOpen, busy: layoutRun != nil) {
                // K3：提示还在时点小绘，直接去改这一段（同 C2）
                if !orbOpen, let orbHint, cursor?.unit.id == orbHint { openChat(entry: orbHint); return }
                // 选中了文字再点小绘：直接去改这一句（Web `orbTakesSelection`）
                if !orbOpen, let paperLine, ResumeOrb.takesSelection(hasSelection: paperLine.selection != nil, lineID: paperLine.lineIDs.first,
                                                                     layoutBusy: layoutRun != nil), canAsk {
                    openLine(paperLine); return
                }
                orbReply = nil
                orbSaid = nil
                orbOpen.toggle()
            }
            .disabled(busy || conflict)
        }
        .task(id: hintCandidate) {
            // 停 0.8 秒才出现；打字、选字、换段时先收起
            orbHint = nil
            guard let hintCandidate else { return }
            try? await Task.sleep(for: ResumeOrb.hintDelay)
            if !Task.isCancelled { orbHint = hintCandidate }
        }
        .onChange(of: paperLine?.unitID) { _, _ in orbHintDismissed = false }
        .animation(.easeOut(duration: 0.16), value: orbOpen)
        .animation(.easeOut(duration: 0.18), value: layoutRun)
        .animation(.easeOut(duration: 0.18), value: orbSaid)
        .animation(.easeOut(duration: 0.16), value: orbHint)
    }

    /// K3 提示指向的段：光标停在能改写的一段（纸面在打字时不报光标行）、没选字、白板没开、没在排版或说别的话。
    private var hintCandidate: String? {
        let cursor = cursorUnit
        let allowed = ResumeOrb.hintAllowed(cursorUnit: cursor != nil, dismissed: orbHintDismissed, open: orbOpen, typing: false,
                                            away: lineOpen || chatOpen, disabled: busy || conflict || !canAsk, layoutBusy: layoutRun != nil,
                                            hasSelection: paperLine?.selection != nil, saying: orbSaid != nil)
        return allowed ? cursor?.unit.id : nil
    }

    /// 段旁的编辑单元（Web `editorUnits`：跳过基本信息、教育、证书、获奖、语言、兴趣）。
    private var chatUnits: [ResumeEditorChatView.Unit] {
        let skipped: Set<String> = ["identity", "basics", "education", "certificates", "awards", "languages", "interests"]
        return sections.flatMap { section -> [ResumeEditorChatView.Unit] in
            let kind = section.text("semantic_kind")
            guard !skipped.contains(kind) else { return [] }
            let label = sectionLabel(section)
            let other = ResumeEditorChat.isNonExperience(semanticKind: kind, label: label)
            let entries = section["entries"]?.items ?? []
            if entries.isEmpty {
                return SectionFocus.unit(section: section).map { [ResumeEditorChatView.Unit(focus: $0, label: label, nonExperience: other)] } ?? []
            }
            return entries.compactMap { entry in
                SectionFocus.unit(entry: entry).map { unit in
                    ResumeEditorChatView.Unit(focus: unit, label: unit.heading.isEmpty ? label : "\(label) · \(unit.heading)", nonExperience: other)
                }
            }
        }
    }

    /// 小绘去这一段旁边（Web `onOpenDeepen`）：空 = 先挑一段；`prompt` 是白板上直接说的那句。
    private func openChat(entry: String, prompt: String = "") {
        orbOpen = false
        orbHint = nil
        chatEntry = entry
        if !prompt.isEmpty { chatSeq += 1; chatRequest = .init(entryID: entry, prompt: prompt, seq: chatSeq) }
        panel = "chat"
    }

    private func runOrb(_ action: ResumeOrb.Action) {
        switch action {
        case .deepenAll:
            openChat(entry: "")
        case .deepenUnit(let id):
            // Web `onOpenDeepen({ unitId })`：小绘滑到这一段旁边（editor-chat；c42dbeae9 尚未对桌面开放，打不开时白板上说一句）
            openChat(entry: id)
        case .layout:
            runLayout()
        case .layoutCancel:
            orbOpen = false
            cancelLayout()
        }
    }

    // MARK: 智能排版

    struct OrbSaid: Equatable {
        let id = UUID()
        let text: String
        var undo: Bool
    }

    /// 小绘左边说一句，`seconds` 后自己收起（再说新的一句时旧的计时作废）。
    private func say(_ text: String, undo: Bool = false, seconds: Double = 4) {
        let said = OrbSaid(text: text, undo: undo)
        orbSaid = said
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if orbSaid?.id == said.id { orbSaid = nil }
        }
    }

    /// Web `runAiLayout`：先让纸面量每段（行数、末行占比、末行文字），回来后组请求体调 `review:layout`，
    /// 返回交回纸面核验并一次写进纸里；纸面照常能改，正在排版时小绘外圈转、左边可“停下”。
    private func runLayout() {
        guard layoutRun == nil, record != nil, !conflict else { return }
        orbOpen = false
        orbReply = nil
        orbSaid = nil
        let id = UUID().uuidString
        layoutRun = id
        channel.send(.layoutMeasure(requestID: id))
    }

    private func cancelLayout() {
        layoutTask?.cancel()
        layoutTask = nil
        layoutRun = nil
    }

    private func layoutMeasured(_ id: String, blocks: [JSONValue]) {
        guard layoutRun == id else { return }
        guard let body = ResumeSmartLayout.requestBody(blocks: blocks) else {
            layoutRun = nil
            paperNote = ResumeSmartLayout.emptyMessage
            return
        }
        layoutTask = Task {
            do {
                let response = try await session.api.careerRequest(path: "/api/resumes/\(resumeID)/review:layout", method: "POST", query: [:], body: body)
                guard !Task.isCancelled, layoutRun == id else { return }
                channel.send(.layoutApply(requestID: id, response: response))
            } catch {
                guard !Task.isCancelled, layoutRun == id else { return }
                layoutRun = nil
                if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
                paperNote = ResumeSmartLayout.errorMessage(error)
            }
        }
    }

    private func layoutApplied(_ result: LayoutApplied) {
        guard layoutRun == result.requestID else { return }
        layoutRun = nil
        let outcome = ResumeSmartLayout.outcome(total: result.total, applied: result.applied, summary: result.summary,
                                                pagesBefore: result.pagesBefore, pagesAfter: result.pagesAfter,
                                                smartOnePage: ResumeTypeSettings.read(style)?.smartOnePage == true, undoable: result.undoable)
        say(outcome.message, undo: outcome.undoable, seconds: outcome.seconds)
    }

    /// “或者直接说想改什么…”（Web `sendDraft`）：带着这句话去光标所在的那一段；没有光标所在段就先挑一段。
    private func sayToOrb(_ text: String) {
        openChat(entry: cursorUnit?.unit.id ?? "", prompt: text)
    }

    /// 改这一条所在的模块类型（技能不给 STAR）。
    private var lineKind: ResumeCheck.Kind {
        guard let id = lineTarget?.unit.id else { return .experience }
        let section = sections.first { $0.nodeKey == id || ($0["entries"]?.items ?? []).contains { $0.nodeKey == id } }
        guard let section else { return .experience }
        return ResumeCheck.kind(semantic: section.text("semantic_kind"), label: sectionLabel(section))
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

    /// 顶栏（Web DRAWOFFER2-157 I 区 `.wbs-head`，Figma 04 页 5870:2945；Mac 稿 03 页还没有这一版，照 Web）：
    /// 左上只有返回（28×28 圆形，平时透明、悬停浅灰底）；简历名在整个窗口正中、点了直接改名；
    /// 右上“保存”（无边框文字，没改动时置灰，⌘S）+ 最右“⋯”菜单（撤销 / 重做、排版 / 模板、导出 PDF）。
    /// 窗口是隐藏标题栏，红绿灯中线在顶上 16pt：整行放在顶上 32 高里与红绿灯同一中线，左让出 84，下面留 20 给画布上沿。
    private var toolbar: some View {
        ZStack {
            HStack(spacing: 6) {
                Button { leave() } label: {
                    Image(systemName: "arrow.left").font(.system(size: 14)).frame(width: 28, height: 28).contentShape(Circle())
                }.buttonStyle(HeadBackStyle()).help("返回我的简历").accessibilityLabel("返回我的简历")
                Spacer(minLength: 16)
                if conflict { Button("重新载入") { Task { await load() } }.buttonStyle(HeadSaveStyle(strong: true)) }
                Button(ResumeSave.buttonLabel(saveStatus)) { Task { await save() } }
                    .buttonStyle(HeadSaveStyle())
                    .disabled(!ResumeSave.buttonEnabled(loaded: record != nil, dirty: dirty, status: saveStatus, pending: uploading || conflict))
                    .keyboardShortcut("s", modifiers: .command)
                    .help("保存到云端（⌘S）")
                headMenu
            }
            .padding(.leading, 84).padding(.trailing, 14)
            // 简历名在整个窗口正中（Web `.wbs-head-title` left:50%，最宽 360），不随左边给红绿灯让出的 84 偏右
            TitleField(title: $title).frame(maxWidth: 360).disabled(saving && panel == "template")
        }
        .frame(height: 32).padding(.bottom, 20)
        .background(Self.canvas)
    }

    /// Web `WorkbenchHeadMenu`：系统下拉菜单，快捷键提示与勾选态由系统画。
    private var headMenu: some View {
        let open: ResumeEditorMenu.Command? = typeOpen ? .type : templateOpen ? .template : nil
        let items = ResumeEditorMenu.items(canUndo: canUndo && !busy, canRedo: canRedo && !busy, openCard: open, exporting: exporting,
                                           typeDisabled: busy || conflict || record == nil, templateDisabled: busy || conflict || record == nil,
                                           exportDisabled: exporting || record == nil)
        return Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if let command = item.command {
                    menuEntry(item, command)
                } else {
                    Divider()
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(width: 28, height: 28)
        .background(Circle().fill(Color.black.opacity(menuHover ? 0.06 : 0)))
        .onHover { menuHover = $0 }
        .help("编辑器操作").accessibilityLabel("编辑器操作")
    }

    @ViewBuilder private func menuEntry(_ item: ResumeEditorMenu.Item, _ command: ResumeEditorMenu.Command) -> some View {
        switch command {
        case .undo:
            Button(item.label) { perform(command) }.keyboardShortcut("z", modifiers: .command).disabled(!item.enabled)
        case .redo:
            Button(item.label) { perform(command) }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!item.enabled)
        case .type, .template:
            Toggle(item.label, isOn: Binding(get: { item.checked }, set: { _ in perform(command) })).disabled(!item.enabled)
        case .export:
            Button(item.label) { perform(command) }.disabled(!item.enabled)
        }
    }

    private func perform(_ command: ResumeEditorMenu.Command) {
        switch command {
        case .undo: channel.send(.undo)
        case .redo: channel.send(.redo)
        case .type: togglePanel("type")
        case .template: togglePanel("template")
        case .export: Task { await exportPDF() }
        }
    }

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
                .clipped()
                .overlay(alignment: .bottom) {
                    if let paperNote { Text(paperNote).font(V3.sans(11.5)).foregroundStyle(V3.orange).padding(8).background(.white, in: Capsule()).padding(.bottom, 16) }
                }
                .background {
                    Group {
                        Button("") { setZoom(zoom + 0.1) }.keyboardShortcut("=", modifiers: .command)
                        Button("") { setZoom(zoom - 0.1) }.keyboardShortcut("-", modifiers: .command)
                        Button("") { setZoom(1) }.keyboardShortcut("0", modifiers: .command)
                        // ⌘K 打开“改这一条”（焦点在纸面里时由页面自己报 line-open）
                        Button("") { if let paperLine, canAsk { openLine(paperLine) } }.keyboardShortcut("k", modifiers: .command)
                    }.opacity(0).accessibilityHidden(true)
                }
        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    /// 没开别的面板、没在预览模板、没在保存时才接 ⌘K 与小绘的“改这一句”。
    private var canAsk: Bool { (panel == nil || panel == "type") && guideFlow == nil && templatePreviewName == nil && !busy && !conflict }

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
            guard guideFlow == nil else { return }
            guard let unit = focusUnit(unitID) else { paperNote = "这一行暂时不能聚焦修改"; return }
            let line = unit.lines.contains { $0.id == lineID } ? lineID : (unit.lines.first?.id ?? lineID)
            lineTarget = ResumeLineChat.Target(unit: unit, lineIDs: [line], instruction: instruction)
            lineAsk += 1
            panel = "line"
        case .error(let message): paperNote = message
        case .line(let line): paperLine = line
        case .lineOpen(let line): if canAsk || panel == "line" { openLine(line) }
        case .pages(let count): pageCount = count
        // 纸边标记只给检查简历用，Web 已下线检查简历
        case .mark: break
        case .layoutMetrics(let id, let blocks, _): layoutMeasured(id, blocks: blocks)
        case .layoutApplied(let result): layoutApplied(result)
        // 撤回了就收起那句话；没撤（纸面又改过）只去掉“撤销”
        case .layoutUndo(let ok): if ok { orbSaid = nil } else { orbSaid?.undo = false }
        case .layoutUndoExpired: orbSaid?.undo = false
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

    /// `restoreDraft`：打开编辑器时，这台电脑上有这一版的没保存修改就换上（Web `applyResumeWithLocalDraft`）。
    private func apply(_ resume: JSONValue, restoreDraft: Bool = false) async {
        record = resume
        saved = resume["data"] ?? .null
        doc = saved
        savedStyle = resume["style"] ?? .null
        style = savedStyle
        title = resume.text("title")
        paperNote = nil
        // 换了正文来源（重新载入、换模板），光标所在行不再可靠；进行中的排版与“撤销”一并作废
        paperLine = nil
        cancelLayout(); orbSaid = nil
        templatePreviewTask?.cancel(); templatePreviewName = nil; templatePreviewCache = [:]
        if panel == "chat" { panel = nil }
        if panel == "check" || panel == "line" { panel = nil; lineTarget = nil }
        importWarnings = (resume["import"]?["warnings"]?.items ?? resume["import_warnings"]?.items ?? []).compactMap(\.stringValue)
        saveFailed = false; saveNotice = nil; canUndo = false; canRedo = false
        if restoreDraft, let draft = draftKeeper.store?.read(user: userID, resume: resumeID, lockVersion: resume["lock_version"]?.integer ?? 0) {
            doc = draft.data; style = draft.style; title = draft.title
        }
        paperSeed = .object(["data": doc, "style": style])
        paperStyle = style
        paperGeneration += 1
    }

    /// 保存成功：更新已保存的基线与记录；保存期间用户继续编辑的内容保留，等下一次点保存。
    private func applySaved(_ resume: JSONValue, keeping pending: (JSONValue, JSONValue, String)) async {
        let editedDuringSave = doc != pending.0 || style != pending.1 || title != pending.2
        let current = (doc, style, title)
        record = resume
        saved = resume["data"] ?? .null
        savedStyle = resume["style"] ?? .null
        if editedDuringSave {
            doc = current.0; style = current.1; title = current.2
        } else {
            // 已保存的正文以服务端为准，但不重载纸面（保留光标与撤销历史）
            doc = saved; title = resume.text("title")
            if style != savedStyle { paperStyle = savedStyle; style = savedStyle }
        }
        noteDraft()
    }

    /// 本地草稿（Web `scheduleLocalResumeDraft`）：有没保存的修改就记下，第一次改动起一分钟写一次；已保存就删掉。
    private func noteDraft() {
        guard let record, !userID.isEmpty else { return }
        guard dirty else {
            draftTimer?.cancel(); draftTimer = nil
            draftKeeper.clear(user: userID, resume: resumeID)
            return
        }
        let draft = ResumeLocalDraft(userID: userID, resumeID: resumeID, baseLockVersion: record["lock_version"]?.integer ?? 0,
                                     title: title, data: doc, style: style)
        if draftKeeper.note(draft) {
            let keeper = draftKeeper
            draftTimer = Task {
                try? await Task.sleep(for: ResumeSave.draftInterval)
                guard !Task.isCancelled else { return }
                keeper.flush()
            }
        }
    }

    /// 离开编辑器：有没保存的修改时先问（Web `leaveSafely`）。
    private func leave() {
        guard ResumeSave.needsLeaveConfirmation(dirty: dirty, uploading: uploading) else { leaveNow(); return }
        confirmLeave = true
    }

    /// 直接离开（暂不保存）：没保存的修改立刻写到这台电脑，下次打开时恢复。
    private func leaveNow() {
        draftTimer?.cancel()
        draftKeeper.flush()
        close()
    }

    /// 保存并离开：没存成就留在本页说一句（Web `saveAndLeave`）。
    private func saveAndLeave() async {
        await save()
        if saveFailed || dirty {
            toast = .failed(ResumeSave.leaveFailed)
            return
        }
        leaveNow()
    }

    /// 编辑器“导出 PDF”（Web `exportResumePdf`）：先把当前修改存到服务端，再按最新 lock_version 导出。
    private func exportPDF() async {
        guard !exporting else { return }
        if dirty { await save() }
        guard !dirty, !saveFailed else {
            toast = .failed(ResumeSave.imageContractMessage(saveErrorCode) ?? "简历保存失败，请修正后重试")
            return
        }
        guard let record, let version = record["lock_version"]?.integer, version > 0 else { toast = .failed("简历暂时无法导出，请稍后重试"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = ResumesView.fileName(title)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true; error = nil
        toast = .waiting("正在生成 PDF…")
        defer { exporting = false }
        do {
            let data = try await session.api.downloadResumePDF(id: resumeID, lockVersion: version)
            try data.write(to: destination, options: .atomic)
            toast = .done("PDF 已导出")
        } catch {
            if case APIError.unauthorized = error { toast = nil; session.reportAuthenticationFailure(); return }
            if error is CocoaError { toast = .failed("PDF 已生成，但保存到所选位置失败，请换个位置重试。"); return }
            let code: String? = if case APIError.server(_, let code) = error { code } else { nil }
            let status: Int? = if case APIError.server(let status, _) = error { status } else { nil }
            toast = .failed(ResumeSave.pdfExportError(code: code, status: status))
        }
    }

    /// 引导、小绘写入前：有未保存修改先保存；保存失败不写（Web `flushActiveDraft`）。
    private func saveBeforeWrite() async -> Bool {
        if dirty { await save() }
        return !dirty
    }

    private func togglePanel(_ key: String) {
        panel = panel == key ? nil : key
    }

    /// 进编辑器先读引导：进行中才换成引导页；已结束或没有引导时就是普通编辑器（Web 已去掉编辑器里的重新打开入口）。
    private func loadGuide() async {
        guard let loaded = try? await session.api.careerRequest(path: "/api/resumes/\(resumeID)/guide", method: "GET", query: [:], body: nil)["guide"],
              loaded.text("status") == "active" else { return }
        let flow = ResumeGuideFlow(resumeID: resumeID, guide: loaded, templateID: record?["template_id"]?.stringValue, api: session.api)
        flow.paper = doc
        flow.applied = { resume in Task { await apply(resume) } }
        flow.saveFirst = { await saveBeforeWrite() }
        flow.restore = { before in doc = before; channel.replaceData(before) }
        flow.applyTemplate = { template in
            let failed = await applyTemplate(template)
            if failed == nil { flow.templateID = template.id }
            return failed
        }
        flow.finished = { guideFlow = nil; panel = nil }
        panel = nil
        guideFlow = flow
    }

    private func load() async {
        loading = true; error = nil; conflict = false
        defer { loading = false }
        do {
            let result = try await session.api.careerRequest(path: "/api/resumes/\(resumeID)", method: "GET", query: [:], body: nil)
            guard let resume = result["resume"] else { throw APIError.invalidResponse }
            await apply(resume, restoreDraft: true)
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
            saveFailed = false; saveErrorCode = nil; saveNotice = nil
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            if case APIError.server(409, "RESUME_EDIT_CONFLICT") = error { conflict = true }
            self.error = ResumeDocument.saveError(error)
            saveErrorCode = if case APIError.server(_, let code) = error { code } else { nil }
            saveFailed = true
            saveNotice = .failed(ResumeSave.failureTitle, ResumeSave.failureMessage(code: saveErrorCode),
                                 actions: [.init(label: "重试", id: "retry")], persistent: true)
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
            toast = .done("已切换为“\(template.name)”，内容已按新模板重新排版")
            return nil
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            if case APIError.server(409, "RESUME_EDIT_CONFLICT") = error { conflict = true }
            let message = ResumeDocument.saveError(error)
            self.error = message
            if guideFlow == nil { toast = .failed("模板切换失败，当前简历未被替换") }
            return message
        }
    }

}




/// Web `.wbs-back`：28×28 圆形，#55554f；悬停 6% 黑底、墨黑。
private struct HeadBackStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hover || configuration.isPressed ? V3.txt : Color(hex: 0x55554F))
            .background(hover || configuration.isPressed ? Color.black.opacity(0.06) : .clear, in: Circle())
            .onHover { hover = $0 }
    }
}

/// Web `.wbs-save`：28 高胶囊、左右 16、12/500；平时 #55554f，悬停 4% 黑底墨黑，禁用 #b9b9b2。
private struct HeadSaveStyle: ButtonStyle {
    var strong = false
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(V3.sans(12, weight: .medium)).lineLimit(1)
            .foregroundStyle(!enabled ? Color(hex: 0xB9B9B2) : strong || hover ? V3.txt : Color(hex: 0x55554F))
            .padding(.horizontal, 16).frame(minWidth: 56, minHeight: 28)
            .background(enabled && (hover || configuration.isPressed) ? Color.black.opacity(0.04) : .clear, in: Capsule())
            .contentShape(Capsule())
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
