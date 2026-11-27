import AppKit
import DrawOfferCore
import SwiftUI
import UniformTypeIdentifiers

/// 侧栏“最近对话”（`GET /api/agent/sessions`）。退出或换账号时清空。
@MainActor @Observable
final class AgentSessionsModel {
    enum Status { case idle, loading, ready, error }
    private(set) var sessions: [JSONValue] = []
    private(set) var status: Status = .idle
    /// 正在生成回答的会话：与 Web 一致，生成中不能删除。
    var runningIDs: Set<String> = []
    var loaded: Bool { status == .ready }
    private var owner = ""

    func load(api: any APIClient, account: String) async {
        if owner != account { sessions = []; status = .idle; owner = account }
        guard !account.isEmpty else { return }
        if sessions.isEmpty { status = .loading }
        do {
            let result = try await api.careerRequest(path: "/api/agent/sessions", method: "GET", query: [:], body: nil)
            guard owner == account else { return }
            sessions = Self.sorted((result["sessions"]?.items ?? []).filter { $0.text("status") != "archived" })
            status = .ready
        } catch {
            guard owner == account else { return }
            if sessions.isEmpty { status = .error }
        }
    }

    /// 与 Web `sortSessions` 相同：置顶优先，其余按最近消息时间倒序。
    static func sorted(_ items: [JSONValue]) -> [JSONValue] {
        items.sorted {
            ($0["pinned"]?.bool == true ? 1 : 0, $0.text("last_message_at").nonEmptyOr($0.text("updated_at")))
                > ($1["pinned"]?.bool == true ? 1 : 0, $1.text("last_message_at").nonEmptyOr($1.text("updated_at")))
        }
    }

    func setPinned(api: any APIClient, id: String, pinned: Bool) async throws {
        let result = try await api.careerRequest(path: "/api/agent/sessions/\(id)", method: "PATCH", query: [:], body: .object(["pinned": .bool(pinned)]))
        replace(result["session"] ?? result)
    }

    func rename(api: any APIClient, id: String, title: String) async throws {
        let result = try await api.careerRequest(path: "/api/agent/sessions/\(id)", method: "PATCH", query: [:], body: .object(["title": .string(title)]))
        replace(result["session"] ?? result)
    }

    func delete(api: any APIClient, id: String) async throws {
        _ = try await api.careerRequest(path: "/api/agent/sessions/\(id)", method: "DELETE", query: [:], body: nil)
        remove(id)
    }

    private func replace(_ session: JSONValue) {
        let id = session.text("id")
        guard !id.isEmpty else { return }
        sessions = Self.sorted([session] + sessions.filter { $0.text("id") != id })
    }

    func remove(_ id: String) { sessions.removeAll { $0.text("id") == id } }
}

/// AI 对话（Figma 02B · AI 对话；流程对齐 Web `features/assistant/AssistantPage.tsx`）：会话消息、流式回复与准备过程、追问选项、
/// 修改建议写在回复里、对话卡片、附加资料与附件、改任意一条提问并在版本间切换、回复的有用 / 没用、回答中先排队或插话的待发送消息、
/// 上下文用量与停止生成。消息带固定幂等键，中断后刷新即可确认结果。
struct AssistantChatView: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router
    /// nil 表示新对话：第一次发送时创建会话。
    let sessionID: String?
    /// 首页输入框带过来的第一条消息。
    let initialMessage: String?
    let created: (String) -> Void
    let deleted: () -> Void
    let sessionsChanged: () -> Void
    /// 首页选好的模型：新对话创建时带上。
    var initialModelID: String? = nil
    /// 只填进输入框、不替用户发（站内“带一句话去对话”）
    var initialDraft: String? = nil
    /// 生成状态回报给侧栏：生成中的对话不能删除（与 Web 一致）。
    var runningChanged: (String, Bool) -> Void = { _, _ in }
    /// 从首页知识图谱「聊一聊」打开（Web `openHomeChat`）：新对话的第一条带 knowledge_point，由 AI 先开口。
    var knowledge: HomeChatTopic? = nil
    /// 首页右侧对话栏：窄栏，不画问候和模型行，消息用 16/26。
    var panel = false

    /// 浮在输入框上方的弹层：同一时间只开一个。
    private enum Floating { case models, usage, materials }

    @State private var currentID: String?
    @State private var title = "新对话"
    @State private var messages: [JSONValue] = []
    @State private var proposals: [JSONValue] = []
    @State private var draft = ""
    @State private var streaming = ""
    @State private var status: String?
    @State private var runID: String?
    @State private var sending = false {
        didSet { if let currentID, oldValue != sending { runningChanged(currentID, sending) } }
    }
    @State private var error: String?
    @State private var ready: Bool?
    @State private var modelName: String?
    @State private var models: [JSONValue] = []
    @State private var hoveredMessage: Int?
    @State private var modelID: String?
    /// 回答进行中输入的消息（Web `QueuedMessages`），只在内存里。
    @State private var queue: [AgentQueuedMessage] = []
    @State private var compacting = false
    /// 这一轮怎么结束的（run.completed / failed / cancelled），正常结束才自动发出下一条待发送消息。
    @State private var runOutcome: String?
    @State private var switchingVersion = false
    /// 回复评价：本地刚选的（按序号）、展开原因的那条、刚提交后显示「已收到，谢谢」的那条。
    @State private var ratings: [Int: AgentRating] = [:]
    @State private var ratingOpen: Int?
    @State private var ratingNote = ""
    @State private var ratingThanks: Int?
    /// 找岗位还差的项（有「开始找岗位」卡片时才读画像算）。
    @State private var jobMissing: [(key: String, label: String)]?
    @State private var savingDocument: String?
    @State private var contexts: [JSONValue] = []
    @State private var contextGroups: [JSONValue] = []
    @State private var answers: [String: String] = [:]
    @State private var proposalBusy: String?
    @State private var consumedInitial = false
    @State private var previewTabs: [ChatPreviewTab] = []
    @State private var previewActive: String?
    @State private var previewOpen = false
    @State private var previewWidth: CGFloat = 520
    @State private var dragBase: CGFloat?
    @State private var unavailableFiles = Set<String>()
    @State private var savedDocuments = Set<String>()
    @State private var screenshots: [ChatScreenshot] = []
    @State private var contextUsage: JSONValue?
    @State private var floating: Floating?
    @State private var slashDismissed = false
    @State private var mentionDismissed = false
    @State private var clarificationPage = 0
    @State private var otherAnswers: [String: String] = [:]
    @State private var copiedMessage: Int?
    @State private var previewFullscreen = false
    /// 额度拦截（Web `CreditNotice`）：额度用完，或当前模型不可用于当前额度；保留原消息以便重发。
    @State private var creditBlock: (kind: String, content: String)?
    @State private var creditPlansTab: AccountPlansTab?
    @State private var notice: String?
    /// 每轮回复的准备过程，按 runId 保留（回复完成后折成回答上方一行）；`live` 是当前这一轮正在显示的步骤。
    @State private var processes: [String: AssistantProcessSnapshot] = [:]
    @State private var live = AssistantProcessSnapshot()
    @State private var processExpanded = false
    @State private var phaseStarted = Date()
    /// 编辑最后一条消息（02B·08 E）：正在编辑的消息位置与草稿。
    @State private var editingIndex: Int?
    @State private var editDraft = ""
    @State private var topicTagHidden = false
    /// 新建对话的标语与快捷输入（02B·02），按首页同一套场景规则挑选。
    @State private var greetingModel = HomeImproveModel()
    @State private var greetingTitle: String?
    @State private var greetingPrompts: [AssistantGreeting.Prompt] = []

    private var api: any APIClient { session.api }
    private var signedInUserID: String? { if case .signedIn(let user) = session.phase { return user.id }; return nil }
    private var pendingClarification: JSONValue? {
        guard !sending, let last = messages.last, last.text("role") == "assistant", let clarification = last["clarification"], clarification != .null,
              !(clarification["questions"]?.items ?? []).isEmpty else { return nil }
        return last
    }
    private var isBlank: Bool { currentID == nil && messages.isEmpty && !sending }
    /// 正文列宽（02B·06）：720，右侧打开预览时收到 560。
    private var columnWidth: CGFloat { panel ? .infinity : previewOpen && !previewTabs.isEmpty ? 560 : 720 }
    private var bodySize: CGFloat { panel ? 15 : 13.5 }
    private var bodyLine: CGFloat { panel ? 26 : 24 }

    /// 这段对话聊的知识点：从首页带来的，或打开旧对话时从第一条消息里读出。
    private var topic: HomeChatTopic? {
        if let knowledge { return knowledge }
        for message in messages where message.text("role") == "user" {
            if let point = message["knowledge_point"], !point.text("key").isEmpty {
                return HomeChatTopic(key: point.text("key"), name: point.text("name"), state: "", tone: .plain)
            }
        }
        return nil
    }
    private func isKickoff(_ message: JSONValue) -> Bool { message["knowledge_point"]?["kickoff"]?.bool == true }

    var body: some View {
        HStack(spacing: 0) {
            if !(previewFullscreen && previewOpen && !previewTabs.isEmpty) { chat.overlay(alignment: .topTrailing) { filesToggle } }
            if previewOpen, !previewTabs.isEmpty {
                resizeHandle
                ChatPreviewPanel(tabs: previewTabs.map { tab in var tab = tab; if tab.kind == .generated { tab.saved = savedDocuments.contains(tab.content) }; return tab },
                                 active: previewActive, unavailable: unavailableFiles,
                                 activate: { previewActive = $0 }, closeTab: closePreview, close: { previewOpen = false },
                                 save: { savingDocument = $0.content }, markUnavailable: { unavailableFiles.insert($0) },
                                 fullscreen: $previewFullscreen,
                                 profileChanged: { profile, intent in jobMissing = JobReadiness.missing(profile: profile, intent: intent) })
                    .frame(width: previewFullscreen ? nil : previewWidth)
                    .frame(maxWidth: previewFullscreen ? .infinity : previewWidth)
            }
        }
        .background(.white)
        .task(id: sessionID ?? "new") { await open() }
        .onChange(of: sending) { _, now in if now { floating = nil } }
        .centeredSheet(item: Binding(get: { savingDocument.map { DocumentDraft(content: $0) } }, set: { if $0 == nil { savingDocument = nil } })) { draft in
            SaveDocumentSheet(content: draft.content, title: Self.documentTitle(draft.content) ?? "AI 文档", close: { savingDocument = nil },
                              saved: { savedDocuments.insert(draft.content) })
        }
    }

    /// 预览面板左边缘（02B·06 面板规则）：默认 520，可拖拽 400–720。
    private var resizeHandle: some View {
        Rectangle().fill(V3.line).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 8).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        let base = dragBase ?? previewWidth
                        dragBase = base
                        previewWidth = min(720, max(400, base - value.translation.width))
                    }.onEnded { _ in dragBase = nil })
            }
            .opacity(previewFullscreen ? 0 : 1)
    }

    @ViewBuilder private var chat: some View {
        if isBlank && !panel { newChat } else { conversation }
    }

    /// 关掉浮层的点击区：铺在消息区，点空白处收起。
    @ViewBuilder private var dismissLayer: some View {
        if floating != nil {
            Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { floating = nil }.accessibilityHidden(true)
        }
    }

    // MARK: 02B·02 新建对话

    private var newChat: some View {
        ZStack {
            Color.white.contentShape(Rectangle()).onTapGesture { floating = nil }
            VStack(spacing: 0) {
                Spacer(minLength: 32)
                AssistantGreetingTitle(text: greetingTitle).padding(.bottom, 58)
                composer
                AssistantPromptList(prompts: greetingPrompts) { draft = $0 }.padding(.top, 21).frame(height: 156, alignment: .top)
                Spacer(minLength: 32)
            }.frame(maxWidth: 720).padding(.horizontal, 24).frame(maxWidth: .infinity)
        }
        .frame(minWidth: 420)
        .task(id: signedInUserID) { await loadGreeting() }
    }

    private func loadGreeting() async {
        guard let account = signedInUserID else { return }
        await greetingModel.load(api: api, account: account)
        if case .ready(let input) = greetingModel.state {
            let scene = HomeScenes.pick(input)
            greetingTitle = AssistantGreeting.title(scene)
            greetingPrompts = AssistantGreeting.prompts(scene)
        } else { greetingTitle = "有什么想问的？" }
    }

    // MARK: 02B·03 对话中

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                            if message.text("message_type") == "compaction" { compactionDivider(message) }
                            else if isKickoff(message) { EmptyView() }
                            else if message.text("message_type") != "clarification" || !message.text("content").isEmpty { row(message, index: index) }
                            if topicChoicesShown(after: index) { topicChoices }
                            ForEach(anchoredGroups[index] ?? [], id: \.key) { group in suggestionList(group.items) }
                        }
                        ForEach(looseGroups, id: \.key) { group in suggestionList(group.items) }
                        if sending { thinking }
                        if let pendingClarification { clarificationCard(pendingClarification) }
                        if let creditBlock, !sending { creditNotice(creditBlock) }
                        if let currentID, !sending { MemoryReceipt(sessionID: currentID, refresh: messages.count) }
                        if let error { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red) }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(maxWidth: columnWidth, alignment: .leading).padding(.horizontal, 24).padding(.top, panel ? 56 : 48).padding(.bottom, 24).frame(maxWidth: .infinity)
                }
                .overlay { dismissLayer }
                .onChange(of: messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: streaming) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: live) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            composer.frame(maxWidth: columnWidth).padding(.horizontal, panel ? 16 : 24).padding(.top, 8).padding(.bottom, panel ? 16 : 27).frame(maxWidth: .infinity)
        }.frame(minWidth: panel ? 0 : 420)
    }

    /// 等待回复（02B·03 / 04）：正文还没开始时是山茶花 + 当前一步 + 工具卡；正文开始后过程折成一行放在正文上方。
    @ViewBuilder private var thinking: some View {
        if streaming.isEmpty {
            AssistantThinking(phase: status ?? "AI 正在处理…", started: phaseStarted, steps: live.steps, expanded: $processExpanded,
                              compacting: status == "正在压缩上下文…")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let runID, let snapshot = processes[runID] { AssistantProcessFold(snapshot: snapshot) }
                NativeMarkdownView(source: AgentReplyText.stabilizeStreaming(AgentReplyText.clean(streaming, streaming: true)), size: bodySize, line: bodyLine).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Preview

    /// 本次对话涉及的全部文件：消息附加的简历与资料、AI 生成的文档。
    private var sessionFiles: [ChatPreviewTab] {
        var tabs: [ChatPreviewTab] = []
        for (index, message) in messages.enumerated() {
            for context in message["contexts"]?.items ?? [] { if let tab = ChatPreviewTab.forContext(context) { tabs = ChatPreviewTab.open(tabs, tab) } }
            if message.text("role") == "assistant", let tab = generatedTab(message, index: index) { tabs = ChatPreviewTab.open(tabs, tab) }
        }
        for shot in screenshots where shot.kind == "image" { tabs = ChatPreviewTab.open(tabs, shot.tab) }
        return tabs
    }

    private func generatedTab(_ message: JSONValue, index: Int) -> ChatPreviewTab? {
        guard let title = Self.documentTitle(message.text("content")) else { return nil }
        let id = message["sequence_no"]?.numberValue.map { String(Int($0)) } ?? "m\(index)"
        return ChatPreviewTab(kind: .generated, id: id, label: title + ".md", content: message.text("content"))
    }

    private func openPreview(_ tab: ChatPreviewTab) {
        guard !unavailableFiles.contains(tab.key) else { return }
        var tab = tab
        if tab.kind == .resume {
            tab.pending = proposals.filter { $0.text("status") == "pending" && $0.text("resume_id") == tab.id }
                .flatMap { ($0["preview"]?["changes"]?.items ?? []).map { $0.text("before") } }.filter { !$0.isEmpty }
        }
        previewTabs = ChatPreviewTab.open(previewTabs, tab)
        previewActive = tab.key
        previewOpen = true
    }

    private func openAllFiles() {
        var tabs = previewTabs
        for tab in sessionFiles { tabs = ChatPreviewTab.open(tabs, tab) }
        previewTabs = tabs
        if previewActive == nil { previewActive = tabs.first?.key }
        previewOpen = !tabs.isEmpty
    }

    private func closePreview(_ key: String) {
        previewTabs.removeAll { $0.key == key }
        if previewActive == key { previewActive = previewTabs.last?.key }
        if previewTabs.isEmpty { previewOpen = false }
    }

    private var activePreviewKey: String? { previewOpen ? previewActive : nil }

    // MARK: Pieces

    /// 右上角「N 个文件」（02B·06 · 59:11411）：86×28 白底细边圆角 7.5，预览面板打开时隐藏。
    @ViewBuilder private var filesToggle: some View {
        let files = sessionFiles.count
        if files > 0 && !previewOpen {
            Button { openAllFiles() } label: {
                HStack(spacing: 8) { Image(systemName: "sidebar.right").font(.system(size: 10.5)); Text("\(files) 个文件") }
                    .font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub)
                    .padding(.leading, 10).padding(.trailing, 10).frame(height: 28)
                    .background(.white, in: RoundedRectangle(cornerRadius: 7.5)).overlay(RoundedRectangle(cornerRadius: 7.5).stroke(V3.cl))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("查看本会话的 \(files) 个文件").padding(16)
        }
    }

    private func row(_ message: JSONValue, index: Int) -> some View {
        let user = message.text("role") == "user"
        return HStack(spacing: 0) {
            if user { Spacer(minLength: 0) }
            Group {
                if user { userMessage(message, index: index) } else { assistantMessage(message, index: index) }
            }
            .frame(maxWidth: user ? (editingIndex == index ? columnWidth : min(560, columnWidth * 0.82)) : .infinity, alignment: user ? .trailing : .leading)
            if !user { Spacer(minLength: 0) }
        }
        .contentShape(Rectangle()).accessibilityElement(children: .contain)
        .onHover { hoveredMessage = $0 ? index : (hoveredMessage == index ? nil : hoveredMessage) }
    }

    @ViewBuilder private func userMessage(_ message: JSONValue, index: Int) -> some View {
        let attached = (message["contexts"]?.items ?? []).filter { !$0.text("label").isEmpty }
        // 正文里没 @ 到的简历引用排在气泡上方（24 高小标签、靠右），其余引用作为正文内的蓝色字
        let resumes = attached.filter { ["resume", "resume_version"].contains($0.text("type")) && !message.text("content").contains("@" + $0.text("label")) }
        let inline = attached.filter { context in !resumes.contains(context) }
        VStack(alignment: .trailing, spacing: 0) {
            if !resumes.isEmpty {
                FlowLayout(spacing: 6, trailing: true) {
                    ForEach(resumes, id: \.self) { context in resumeTag(context) }
                }.padding(.bottom, 8)
            }
            let files = message["attachments"]?.items ?? []
            if !files.isEmpty { messageAttachments(files, trailing: true) }
            if editingIndex == index {
                editBox(message, index: index)
            } else {
                // 气泡（02B·03）：#F4F4F2、圆角 12、内边距 14/11，13 号字，单行高 38（多行补行距到 21）
                Text(Self.userSegments(message.text("content"), inline, active: activePreviewKey)).font(V3.sans(panel ? 15 : 13)).lineSpacing(panel ? 6 : 5.4).foregroundStyle(V3.txt).textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        if let context = inline.first(where: { "drawoffer-context:" + Self.encoded($0.text("label")) == url.absoluteString }),
                           let tab = ChatPreviewTab.forContext(context), !unavailableFiles.contains(tab.key) { openPreview(tab) }
                        return .handled
                    })
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(V3.field, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomTrailing) {
                        if !message.text("content").isEmpty {
                            // 改过的提问：版本切换 ‹ 2/3 › 一直露出，不必悬停
                            messageActions(message, index: index, editable: canEdit(index)).frame(height: 22).fixedSize().offset(y: 28)
                                .opacity(hoveredMessage == index || copiedMessage == index || AgentVersions(message["versions"]) != nil ? 1 : 0)
                        }
                    }
            }
        }
    }

    /// 简历引用小标签（02B·06）：24 高、12 号字，正在右侧预览的那张描蓝。
    private func resumeTag(_ context: JSONValue) -> some View {
        let tab = ChatPreviewTab.forContext(context)
        let gone = tab.map { unavailableFiles.contains($0.key) } ?? true
        let active = tab.map { activePreviewKey == $0.key } ?? false
        return Button { if let tab { openPreview(tab) } } label: {
            HStack(spacing: 5) {
                Image(systemName: "doc.text").font(.system(size: 9.5)).foregroundStyle(active ? V3.blue : V3.sub)
                Text(context.text("type") == "user_profile" ? "个人画像" : context.text("label")).lineLimit(1).truncationMode(.tail)
                Text("简历").font(V3.sans(11)).foregroundStyle(Color(hex: 0x96968F))
            }
            .font(V3.sans(12, weight: .medium)).foregroundStyle(active ? V3.blue : V3.txt)
            .padding(.horizontal, 7).frame(maxWidth: 260).frame(height: 24)
            .background(active ? V3.blue.opacity(0.08) : .white, in: RoundedRectangle(cornerRadius: 6.5))
            .overlay(RoundedRectangle(cornerRadius: 6.5).stroke(active ? V3.blue : V3.cl))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(gone).accessibilityLabel("引用文件 \(context.text("label"))")
    }

    @ViewBuilder private func assistantMessage(_ message: JSONValue, index: Int) -> some View {
        let cards = (message["cards"]?.items ?? []).filter { AssistantActionCards.actionTypes.contains($0.text("type")) }
        let document = generatedTab(message, index: index)
        VStack(alignment: .leading, spacing: 0) {
            if !message.text("run_id").isEmpty, let snapshot = processes[message.text("run_id")], firstReply(of: message.text("run_id")) == index {
                AssistantProcessFold(snapshot: snapshot).padding(.bottom, 12)
            }
            let files = message["attachments"]?.items ?? []
            if !files.isEmpty { messageAttachments(files) }
            NativeMarkdownView(source: AgentReplyText.clean(message.text("content")).nilIfEmpty ?? (message.text("message_type") == "clarification" ? "需要你补充一些信息。" : ""), size: bodySize, line: bodyLine)
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in openDrawOfferLink(url) })
            if message.text("status") == "stopped" { Text("已停止生成").font(V3.sans(11)).foregroundStyle(V3.fnt).padding(.top, 6) }
            if message.text("status") == "failed" { Text("生成未完成").font(V3.sans(11)).foregroundStyle(V3.fnt).padding(.top, 6) }
            if !cards.isEmpty || document != nil {
                AssistantActionCards(cards: cards, sessionID: currentID, sequenceNo: message["sequence_no"]?.numberValue.map { Int($0) },
                                     document: document, activeKey: activePreviewKey, openPreview: openPreview,
                                     changed: { replaceCard(at: index, $0) },
                                     jobMissing: jobMissing, send: sending ? nil : { text in Task { await send(text) } })
                    .padding(.top, 16)
            }
            // 选了没用：操作行回到正文下方常显，下面接暖纸色的原因区（02B-15 · 15.2）
            if ratingOpen == AgentBranch.sequence(message), AgentBranch.ratable(message) {
                replyActions(message, index: index).padding(.top, 8)
                ratingPanel(message).padding(.top, 10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !message.text("content").isEmpty, ratingOpen != AgentBranch.sequence(message) || !AgentBranch.ratable(message) {
                replyActions(message, index: index).fixedSize().offset(y: 30)
                    .opacity(hoveredMessage == index || copiedMessage == index || ratingThanks == AgentBranch.sequence(message) ? 1 : 0)
            }
        }
    }

    /// 回复下方（02B-15 · 15.1）：复制、重新生成 | 有用、没用，后面一行灰字「时间 · 内容由 AI 生成…」，评价后换成「已收到，谢谢」。
    private func replyActions(_ message: JSONValue, index: Int) -> some View {
        let seq = AgentBranch.sequence(message)
        let rating = ratings[seq] ?? AgentRating(message["rating"])
        let regenerable = AgentBranch.regenerable(messages, busy: sending || switchingVersion || editingIndex != nil)?.reply == seq && seq > 0
        return HStack(spacing: 4) {
            actionIcon(copiedMessage == index ? "checkmark" : "doc.on.doc", label: copiedMessage == index ? "已复制" : "复制消息") { copy(AgentReplyText.clean(message.text("content")), index: index) }
            if regenerable { actionIcon("arrow.clockwise", label: "重新生成") { Task { await regenerate() } } }
            if AgentBranch.ratable(message), currentID != nil {
                Rectangle().fill(V3.line).frame(width: 1, height: 14).padding(.horizontal, 4)
                actionIcon(rating?.up == true ? "hand.thumbsup.fill" : "hand.thumbsup", label: "有用", chosen: rating?.up == true) { rateUp(seq) }
                actionIcon(rating?.up == false ? "hand.thumbsdown.fill" : "hand.thumbsdown", label: "没用", chosen: rating?.up == false) { rateDown(seq) }
            }
            if ratingThanks == seq {
                Text("已收到，谢谢").font(V3.sans(12)).foregroundStyle(V3.sub).padding(.leading, 6)
            } else {
                let time = ResumeSummary.parseTimestamp(message.text("created_at")).map(Self.timeLabel)
                Text([time, "内容由 AI 生成，可能不准确，请核对重要信息"].compactMap { $0 }.joined(separator: " · "))
                    .font(V3.sans(12)).foregroundStyle(V3.fnt).lineLimit(1).padding(.leading, 6)
            }
        }.frame(height: 26)
    }

    private func actionIcon(_ symbol: String, label: String, chosen: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5)).frame(width: 24, height: 24)
                .background(chosen ? V3.field : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(chosen ? V3.txt : V3.fnt).help(label).accessibilityLabel(label)
            .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func copy(_ text: String, index: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedMessage = index
        Task { try? await Task.sleep(for: .seconds(2)); if copiedMessage == index { copiedMessage = nil } }
    }

    /// 「这条回复哪里不太好？」（02B-15 · 15.2）：原因每点一下就保存，可多选；补一句回车发送后收起并道谢。
    private func ratingPanel(_ message: JSONValue) -> some View {
        let seq = AgentBranch.sequence(message)
        let rating = ratings[seq] ?? AgentRating(message["rating"])
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("这条回复哪里不太好？").font(V3.sans(13)).foregroundStyle(V3.txt)
                Spacer()
                Button { ratingOpen = nil } label: { Image(systemName: "xmark").font(.system(size: 10.5)).foregroundStyle(Color(hex: 0x6C6C65)).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("收起")
            }
            FlowLayout(spacing: 8) {
                ForEach(AgentRating.reasons, id: \.key) { reason in
                    let on = rating?.up == false && rating?.reasons.contains(reason.key) == true
                    Button { rate(seq, (rating ?? AgentRating(up: false)).toggling(reason.key)) } label: {
                        HStack(spacing: 5) {
                            if on { Image(systemName: "checkmark").font(.system(size: 9.5, weight: .semibold)) }
                            Text(reason.label)
                        }
                        .font(V3.sans(12, weight: on ? .medium : .regular)).foregroundStyle(on ? V3.txt : Color(hex: 0x3D3D39))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(.white, in: Capsule()).overlay(Capsule().strokeBorder(on ? V3.txt : Color(hex: 0xE4E4E0)))
                        .contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            HStack(spacing: 6) {
                TextField("", text: Binding(get: { ratingNote }, set: { ratingNote = String($0.prefix(500)) }))
                    .textFieldStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.txt).accessibilityLabel("补充说明")
                    .background(alignment: .leading) {
                        if ratingNote.isEmpty { Text("还想补充一句？（选填）").font(V3.sans(13)).foregroundStyle(V3.fnt).allowsHitTesting(false) }
                    }
                    .onSubmit { sendRatingNote(seq) }
                Button { sendRatingNote(seq) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).frame(width: 28, height: 28).background(V3.txt, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("发送补充说明")
            }
            .padding(.leading, 16).padding([.trailing, .vertical], 4)
            .background(.white, in: Capsule()).overlay(Capsule().stroke(Color(hex: 0xE4E4E0)))
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
        .background(Color(hex: 0xFAF9F5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 同一轮回复里第一条助手消息才挂折叠行。
    private func firstReply(of run: String) -> Int? { messages.firstIndex { $0.text("role") == "assistant" && $0.text("run_id") == run } }

    private func replaceCard(at index: Int, _ card: JSONValue) {
        guard messages.indices.contains(index), case .object(var fields) = messages[index] else { return }
        fields["cards"] = .array((fields["cards"]?.items ?? []).map { $0.text("id") == card.text("id") ? card : $0 })
        messages[index] = .object(fields)
    }

    /// 悬停操作（02B·08 E）：时间、复制；最后一条自己发的消息、且没有运行中时多一个「编辑」。
    private func messageActions(_ message: JSONValue, index: Int, editable: Bool) -> some View {
        HStack(spacing: 4) {
            if let date = ResumeSummary.parseTimestamp(message.text("created_at")) {
                Text(Self.timeLabel(date)).font(V3.number(12, weight: .regular)).foregroundStyle(V3.fnt).frame(height: 18).padding(.trailing, 2)
            }
            Button { copy(message.text("content"), index: index) } label: { Image(systemName: copiedMessage == index ? "checkmark" : "doc.on.doc").font(.system(size: 11)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(V3.fnt).help(copiedMessage == index ? "已复制" : "复制消息")
                .accessibilityLabel(copiedMessage == index ? "已复制消息" : "复制消息")
            if editable {
                Button { editDraft = message.text("content"); editingIndex = index } label: {
                    Image(systemName: "pencil").font(.system(size: 11)).frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(V3.fnt).help("编辑").accessibilityLabel("编辑这条消息")
            }
            if let versions = AgentVersions(message["versions"]) { versionSwitch(versions) }
        }
    }

    /// 改过的提问（Web `VersionSwitcher`）：‹ 2/3 › 在各个版本之间切换，回答和后面的对话跟着换；回答进行中不能切。
    private func versionSwitch(_ versions: AgentVersions) -> some View {
        let disabled = sending || switchingVersion || editingIndex != nil
        return HStack(spacing: 2) {
            Button { if let previous = versions.previous { Task { await switchVersion(previous) } } } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(disabled || versions.previous == nil).opacity(disabled || versions.previous == nil ? 0.5 : 1)
                .help("上一个版本").accessibilityLabel("上一个版本")
            Text(versions.label).font(V3.number(12, weight: .regular)).foregroundStyle(V3.sub).frame(minWidth: 28)
            Button { if let next = versions.next { Task { await switchVersion(next) } } } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(disabled || versions.next == nil).opacity(disabled || versions.next == nil ? 0.5 : 1)
                .help("下一个版本").accessibilityLabel("下一个版本")
        }.foregroundStyle(V3.sub).accessibilityElement(children: .contain).accessibilityLabel("提问的版本")
    }

    /// 任意一条提问都能改（分支）：改出的新版本和原来那一版都保留；带附件、回答追问的不能改，回答进行中也不能改。
    private func canEdit(_ index: Int) -> Bool {
        currentID != nil && AgentBranch.editable(messages[index], in: messages, busy: sending || switchingVersion)
    }

    /// 编辑框（02B·08 E ②）：气泡被输入框原位替换，右对齐；Esc 或「取消」还原，内容没变时「发送」置灰。
    private func editBox(_ message: JSONValue, index: Int) -> some View {
        let changed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines) != message.text("content").trimmingCharacters(in: .whitespacesAndNewlines)
            && !editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .trailing, spacing: 8) {
            ChatInputField(text: $editDraft, placeholder: "改写这条消息", submit: { if changed { Task { await submitEdit(index) } } },
                           escape: { editingIndex = nil })
                .frame(minHeight: 50, maxHeight: 160)
                .frame(height: 50 + max(0, CGFloat(editDraft.split(separator: "\n", omittingEmptySubsequences: false).count - 1)) * 20)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xD6D6D0)))
            Text("发送后，这条消息之后的回复会被新的回复替换；已经采用的修改不会撤销。").font(V3.sans(12)).foregroundStyle(V3.fnt)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button("取消") { editingIndex = nil }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.sub)
                Button("发送") { Task { await submitEdit(index) } }.buttonStyle(AssistantSmallGhost()).disabled(!changed || sending)
            }
        }.frame(maxWidth: min(560, columnWidth))
    }

    /// Web `composerSegments`：正文里的 `@名称` 换成蓝色 500 字重的名称（正在右侧预览的加下划线）；正文没提到的引用排在最前，后接一个空格。
    static func userSegments(_ content: String, _ contexts: [JSONValue], active: String? = nil) -> AttributedString {
        func token(_ context: JSONValue) -> AttributedString {
            var piece = AttributedString(context.text("type") == "user_profile" ? "个人画像" : context.text("label"))
            piece.foregroundColor = V3.link
            piece.font = V3.sans(13, weight: .medium)
            piece.link = URL(string: "drawoffer-context:" + encoded(context.text("label")))
            if let active, ChatPreviewTab.forContext(context)?.key == active { piece.underlineStyle = .single }
            return piece
        }
        var result = AttributedString()
        let missing = contexts.filter { !content.contains("@" + $0.text("label")) }
        for context in missing { result += token(context) }
        if !missing.isEmpty && !content.isEmpty { result += AttributedString(" ") }
        var cursor = content.startIndex
        while cursor < content.endIndex {
            let next = contexts.compactMap { context in content.range(of: "@" + context.text("label"), range: cursor..<content.endIndex).map { (context, $0) } }
                .min { $0.1.lowerBound < $1.1.lowerBound }
            guard let (context, range) = next else { result += AttributedString(String(content[cursor...])); break }
            if range.lowerBound > cursor { result += AttributedString(String(content[cursor..<range.lowerBound])) }
            result += token(context)
            cursor = range.upperBound
        }
        return result
    }

    static func encoded(_ label: String) -> String { label.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }

    static func timeLabel(_ date: Date) -> String {
        let formatter = Beijing.formatter()
        formatter.dateFormat = "HH:mm"  // Web `formatTime`：始终只显示时分
        return formatter.string(from: date)
    }

    private func compactionDivider(_ message: JSONValue) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(V3.line).frame(height: 1)
            Text("较早的对话已压缩成摘要").font(V3.sans(11.5)).foregroundStyle(V3.fnt).fixedSize()
            Rectangle().fill(V3.line).frame(height: 1)
        }.help(message.text("content"))
    }

    /// 附件按类型显示图标（02B·08 F）：每个文件一张卡，22 号线性图标（#55554F），名称 12/500，下面一行类型与大小。
    private func messageAttachments(_ files: [JSONValue], trailing: Bool = false) -> some View {
        FlowLayout(spacing: 8, trailing: trailing) {
            ForEach(files, id: \.self) { file in
                let name = file.text("file_name")
                let kind = file.text("kind").nilIfEmpty ?? AgentAttachmentUpload.kind(name)
                let size = file["file_size"]?.numberValue.map { Self.fileSize(Int($0)) }
                attachmentCard(name: name, symbol: Self.fileSymbol(name, kind: kind),
                               detail: [kind == "audio" ? "录音" : (name.split(separator: ".").last.map { String($0).uppercased() } ?? ""), size].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                               failed: false)
            }
        }.padding(.bottom, 8)
    }

    private func attachmentCard(name: String, symbol: String, detail: String, failed: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15, weight: .light)).foregroundStyle(V3.sub).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.middle)
                if !detail.isEmpty { Text(detail).font(V3.sans(11)).foregroundStyle(failed ? V3.red : Color(hex: 0x96968F)).lineLimit(1) }
            }
        }
        .padding(.leading, 10).padding(.trailing, 16).padding(.vertical, 8)
        .frame(minWidth: 120, maxWidth: 240, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(failed ? V3.red : V3.cl))
    }

    static func fileSymbol(_ name: String, kind: String) -> String {
        if kind == "audio" { return "mic" }
        if kind == "image" { return "photo" }
        let ext = name.split(separator: ".").last.map { $0.lowercased() } ?? ""
        return ["md", "txt", "markdown"].contains(ext) ? "text.alignleft" : "doc"
    }

    static func fileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(Int((Double(bytes) / 1024).rounded())) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    /// 追问卡（Web `AgentPanel` 的澄清）：一次显示一题，上一题/下一题，最后一题提交；允许时有“其他”自由填写。
    private func clarificationCard(_ message: JSONValue) -> some View {
        let clarification = message["clarification"] ?? .null
        let questions = clarification["questions"]?.items ?? []
        let page = min(clarificationPage, max(0, questions.count - 1))
        let question = questions.isEmpty ? JSONValue.null : questions[page]
        let qid = question.text("id")
        let allowsCustom = question["allow_custom"].map { $0.bool } ?? clarification["allow_custom"].map { $0.bool } ?? true
        let answered = { (q: JSONValue) -> Bool in
            let answer = answers[q.text("id")]
            return answer != nil && (answer != "__other__" || !(otherAnswers[q.text("id")] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
        }
        let complete = questions.allSatisfy(answered)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(question.text("header")).font(V3.sans(11.5)).foregroundStyle(V3.fnt)
                Spacer()
                if questions.count > 1 { Text("\(page + 1)/\(questions.count)").font(V3.number(11)).foregroundStyle(V3.fnt) }
            }
            Text(question.text("question").nonEmptyOr(question.text("header"))).font(V3.sans(13.5, weight: .medium))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(question["options"]?.items ?? [], id: \.self) { option in
                    choice(option.text("label"), detail: option.text("description"), selected: answers[qid] == option.text("id")) { answers[qid] = option.text("id") }
                }
                if allowsCustom {
                    choice("其他", detail: "", selected: answers[qid] == "__other__") { answers[qid] = "__other__" }
                    if answers[qid] == "__other__" {
                        TextField("写下你的回答", text: Binding(get: { otherAnswers[qid] ?? "" }, set: { otherAnswers[qid] = String($0.prefix(500)) }))
                            .textFieldStyle(.roundedBorder).font(V3.sans(13))
                    }
                }
            }
            HStack {
                if page > 0 { Button("上一题") { clarificationPage = page - 1 }.buttonStyle(V3ButtonStyle(kind: .text)) }
                Spacer()
                if page < questions.count - 1 {
                    Button("下一题") { clarificationPage = page + 1 }.buttonStyle(V3ButtonStyle(kind: .ghost)).disabled(!answered(question))
                } else {
                    // 卡片里的确认用白底细边（02B·08：黑色只留给输入框发送）
                    Button("确认") { Task { await answerClarification(message, questions: questions) } }
                        .buttonStyle(V3ButtonStyle(kind: .ghost)).disabled(!complete || sending)
                }
            }
        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.cl))
    }

    private func choice(_ label: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.system(size: 13)).foregroundStyle(selected ? V3.txt : V3.fnt)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(V3.sans(13))
                    if !detail.isEmpty { Text(detail).font(V3.sans(11.5)).foregroundStyle(V3.fnt) }
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? V3.txt.opacity(0.5) : V3.cl)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 输入框里以 / 开头的快捷命令（Web `slashCommands.ts`），只列出当前对话能执行的。
    private var slashCommands: [(id: String, label: String, detail: String, symbol: String)] {
        let all: [(String, String, String, String)] = [
            ("compact", "压缩上下文", "把较早的对话压缩成摘要，腾出上下文", "clock.arrow.circlepath"),
            ("context", "查看上下文用量", "看看离自动压缩还有多远、用在了哪里", "gauge.with.dots.needle.33percent"),
            ("ref", "引用简历或资料", "从简历和资料库里选几份带进对话", "doc.text"),
            ("upload", "上传文件", "图片、文档和录音", "square.and.arrow.up"),
            ("new", "新对话", "从空白对话重新开始", "bubble.left"),
        ]
        return all.filter { id, _, _, _ in
            switch id {
            case "compact": currentID != nil && contextUsage?["tokens"]?.numberValue != nil && !sending
            case "context": contextUsage?["context_window"]?.numberValue != nil
            default: true
            }
        }.map { (id: $0.0, label: $0.1, detail: $0.2, symbol: $0.3) }
    }

    private var slashMatches: [(id: String, label: String, detail: String, symbol: String)] {
        guard !slashDismissed, draft.hasPrefix("/"), !draft.dropFirst().contains(where: { $0 == " " || $0 == "/" || $0 == "\n" }) else { return [] }
        let query = draft.dropFirst().lowercased()
        return slashCommands.filter { query.isEmpty || $0.id.hasPrefix(query) || $0.label.lowercased().contains(query) }
    }

    private func runSlash(_ id: String) {
        draft = ""
        switch id {
        case "compact": Task { await compact() }
        case "context": floating = .usage
        case "ref": floating = .materials; Task { await loadContexts() }
        case "upload": pickFiles()
        default: newConversation()
        }
    }

    /// 输入 @ 时（02B·06 ②）：光标前的 `@词` 用来筛选可引用的资料。
    private var mentionQuery: String? {
        guard !mentionDismissed, floating == nil, let range = draft.range(of: "@[^\\s@]{0,24}$", options: .regularExpression) else { return nil }
        return String(draft[range].dropFirst())
    }

    private func toggleContext(_ item: JSONValue) {
        let key = { (value: JSONValue) in value.text("type") + ":" + value.text("id") + ":" + value.text("version_id") }
        if let index = contexts.firstIndex(where: { key($0) == key(item) }) { contexts.remove(at: index) } else { contexts.append(item) }
    }

    private func pickMention(_ item: JSONValue) {
        if let range = draft.range(of: "@[^\\s@]{0,24}$", options: .regularExpression) {
            draft.replaceSubrange(range, with: "@" + (item.text("type") == "user_profile" ? "个人画像" : item.text("label")) + " ")
        }
        if !contexts.contains(where: { $0.text("type") == item.text("type") && $0.text("id") == item.text("id") }) { contexts.append(item) }
    }

    private var usageDetails: [String: String] {
        let shown = messages.filter { $0.text("message_type") != "compaction" }.count
        let refs = messages.flatMap { $0["contexts"]?.items ?? [] }
        var unique: [String: JSONValue] = [:]
        for ref in refs { unique[ref.text("type") + ":" + ref.text("id")] = ref }
        let resumes = unique.values.filter { ["resume", "resume_version"].contains($0.text("type")) }.count
        let others = unique.count - resumes
        let files = messages.reduce(0) { $0 + ($1["attachments"]?.items.count ?? 0) }
        var result: [String: String] = [:]
        if shown > 0 { result["conversation"] = "\(shown) 条消息" }
        let materials = [resumes > 0 ? "\(resumes) 份简历" : "", others > 0 ? "\(others) 份资料" : ""].filter { !$0.isEmpty }
        if !materials.isEmpty { result["materials"] = materials.joined(separator: " · ") }
        if files > 0 { result["attachments"] = "\(files) 个附件" }
        return result
    }

    // MARK: Composer（02B·03：输入框 57 高、圆角 17.5、#D6D6D0 描边；下方 12 处是「＋ 添加资料」与上下文圆环、模型）

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !slashMatches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(slashMatches, id: \.id) { command in
                        Button { runSlash(command.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: command.symbol).font(.system(size: 12, weight: .light)).frame(width: 16).foregroundStyle(V3.sub)
                                Text("/" + command.id).font(V3.number(12.5, weight: .regular)).foregroundStyle(V3.fnt)
                                Text(command.label).font(V3.sans(13))
                                Text(command.detail).font(V3.sans(11.5)).foregroundStyle(V3.fnt).lineLimit(1)
                                Spacer()
                            }.padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
                        }.buttonStyle(MenuRowStyle())
                    }
                }.padding(6).frame(maxWidth: 560).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.cl))
                    .shadow(color: .black.opacity(0.07), radius: 10, y: 6).padding(.bottom, 8)
            }
            if !screenshots.isEmpty { screenshotStrip(screenshots, removable: true).padding(.bottom, 8) }
            if !queue.isEmpty {
                VStack(spacing: 6) { ForEach(queue) { queueCard($0) } }.padding(.bottom, 8)
            }
            if let topic, !topicTagHidden { topicTag(topic).padding(.leading, 4).padding(.bottom, 8) }
            if !contexts.isEmpty {
                FlowLayout(spacing: 6) { ForEach(contexts, id: \.self) { contextChip($0) } }.padding(.leading, 4).padding(.bottom, 11)
            }
            inputBox
                .overlay(alignment: .topLeading) {
                    if floating == .materials {
                        AssistantContextPanel(groups: contextGroups, chosen: contexts, typeLabel: contextTypeLabel, toggle: toggleContext,
                                              upload: { floating = nil; pickFiles() })
                            .alignmentGuide(.top) { $0[.bottom] + 8 }
                    } else if let mention = mentionQuery {
                        AssistantContextPanel(groups: contextGroups, chosen: contexts, typeLabel: contextTypeLabel, mention: mention, toggle: pickMention,
                                              upload: { mentionDismissed = true; pickFiles() })
                            .alignmentGuide(.top) { $0[.bottom] + 8 }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if floating == .models {
                        ModelPickerPanel(models: models, selectedID: modelID, disabled: sending) { id in
                            floating = nil
                            if let model = models.first(where: { $0.text("id") == id }) { Task { await chooseModel(model) } }
                        }.alignmentGuide(.top) { $0[.bottom] + 8 }
                    } else if floating == .usage {
                        AssistantUsagePanel(usage: contextUsage, modelName: currentModelName, details: usageDetails,
                                            compactDisabled: sending || currentID == nil, compact: { floating = nil; Task { await compact() } })
                            .alignmentGuide(.top) { $0[.bottom] + 8 }
                    }
                }
                .zIndex(1)
            if !panel { HStack(spacing: 10) {
                Button { toggleFloating(.materials); Task { await loadContexts() } } label: {
                    HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 10, weight: .regular)); Text("添加资料") }
                        .font(V3.sans(12.5)).foregroundStyle(V3.sub).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(sending).accessibilityLabel("添加资料")
                if let notice { Text(notice).font(V3.sans(11.5)).foregroundStyle(V3.orange).lineLimit(2) }
                Spacer()
                HStack(spacing: 14) {
                    AssistantUsageRing(usage: contextUsage) { toggleFloating(.usage) }
                    ModelPicker(models: models, selectedID: modelID, disabled: sending, externalToggle: { toggleFloating(.models) }) { _ in }
                }
            }.frame(height: 16).padding(.leading, 12).padding(.trailing, 12).padding(.top, 12) }
        }.frame(maxWidth: panel ? .infinity : 720)
        .dropDestination(for: URL.self) { urls, _ in addFiles(urls); return !urls.isEmpty }
    }

    private func toggleFloating(_ value: Floating) { floating = floating == value ? nil : value }

    private var inputBox: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ChatInputField(text: $draft, placeholder: ready == false ? "AI 助手暂未开放" : topic.map { "问点和\($0.name)有关的…" } ?? (isBlank ? "有什么想问的？" : "继续提问或说明调整要求…"),
                           submit: {
                               if let first = slashMatches.first { runSlash(first.id) }
                               else if let mention = mentionQuery, let first = contextGroups.flatMap({ $0["items"]?.items ?? [] })
                                .first(where: { mention.isEmpty || $0.text("label").localizedCaseInsensitiveContains(mention) }) { pickMention(first) }
                               else if sending { queueDraft() }
                               else if canSend { Task { await send(draft) } }
                           },
                           escape: {
                               if floating != nil { floating = nil }
                               else if mentionQuery != nil { mentionDismissed = true }
                               else if !slashMatches.isEmpty { slashDismissed = true }
                           },
                           paste: { pasteImage() })
                .frame(minHeight: 32, maxHeight: 132).frame(height: 32 + max(0, CGFloat(draft.split(separator: "\n", omittingEmptySubsequences: false).count - 1)) * 22)
                .onChange(of: draft) {
                    if !draft.hasPrefix("/") { slashDismissed = false }
                    if !draft.contains("@") { mentionDismissed = false }
                    if draft.hasSuffix("@") { Task { await loadContexts() } }
                }
            if sending, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 回答中也能发：消息先进待发送卡片，回答结束后自动发出
                Button { queueDraft() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).frame(width: 32, height: 32).background(V3.txt, in: Circle())
                }.buttonStyle(.plain).help("回答结束后自动发送").accessibilityLabel("加入待发送").padding(.trailing, -4)
            }
            if sending, runID != nil {
                Button { Task { await cancel() } } label: {
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10).frame(width: 32, height: 32).background(V3.txt, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("停止生成")
            } else {
                Button { Task { await send(draft) } } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).frame(width: 32, height: 32)
                        .background(canSend ? V3.txt : Color(hex: 0xC9C9C3), in: Circle())
                }.buttonStyle(.plain).disabled(!canSend).accessibilityLabel("发送")
            }
        }.padding(.leading, 18).padding([.trailing, .vertical], 12).frame(minHeight: 57)
            .background(.white, in: RoundedRectangle(cornerRadius: 17.5)).overlay(RoundedRectangle(cornerRadius: 17.5).stroke(Color(hex: 0xD6D6D0)))
    }

    /// 待发送卡片（Web `QueuedMessages`）：一行正文 + 灰字说明，右侧「立即发送 / 发送」、编辑、删除；插入中的卡片虚线边。
    private func queueCard(_ item: AgentQueuedMessage) -> some View {
        let insertable = AgentQueue.canInsert(queue, running: sending, runID: runID, compacting: compacting)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(item.content).font(V3.sans(14)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.tail).frame(height: 20)
                Text(item.caption(running: sending)).font(V3.sans(12)).foregroundStyle(item.error != nil ? Color(hex: 0xC2410C) : V3.fnt).lineLimit(1).frame(height: 18)
            }.frame(maxWidth: .infinity, alignment: .leading).help(item.content)
            if item.state == .queued {
                HStack(spacing: 2) {
                    Button(sending ? "立即发送" : "发送") { sendQueuedNow(item) }
                        .buttonStyle(.plain).font(V3.sans(13, weight: .medium)).foregroundStyle(insertable ? V3.link : V3.fnt2)
                        .padding(.horizontal, 8).frame(height: 28).disabled(!insertable)
                    Button { editQueued(item) } label: { Image(systemName: "pencil").font(.system(size: 12)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                        .buttonStyle(.plain).foregroundStyle(V3.fnt).help("编辑").accessibilityLabel("编辑待发送消息")
                    Button { queue.removeAll { $0.id == item.id } } label: { Image(systemName: "trash").font(.system(size: 12)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                        .buttonStyle(.plain).foregroundStyle(V3.fnt).help("删除").accessibilityLabel("删除待发送消息")
                }
            }
        }
        .padding(.leading, 14).padding([.trailing, .vertical], 8)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: 0xE4E4DE), style: StrokeStyle(lineWidth: 1, dash: item.state == .inserting ? [4, 3] : [])))
    }

    /// 输入框上方的引用标签（02B·03 · Context/Resume）：白底细边圆角 6.5、23 高，图标 + 名称 + 灰色类型 + ×。
    private func contextChip(_ item: JSONValue) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ["resume", "resume_version"].contains(item.text("type")) ? "doc.text" : item.text("type") == "dataset" ? "folder" : "doc")
                .font(.system(size: 9)).foregroundStyle(V3.sub)
            Text(item.text("type") == "user_profile" ? "个人画像" : item.text("label")).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
            Text(contextTypeLabel(item.text("type")).replacingOccurrences(of: "版本", with: "")).font(V3.sans(11)).foregroundStyle(Color(hex: 0x96968F))
            Button { contexts.removeAll { $0 == item } } label: { Image(systemName: "xmark").font(.system(size: 7, weight: .semibold)).foregroundStyle(V3.fnt).frame(width: 12, height: 12).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("移除 \(item.text("label"))")
        }.padding(.leading, 9).padding(.trailing, 6).frame(height: 23).frame(maxWidth: 280)
            .background(.white, in: RoundedRectangle(cornerRadius: 6.5)).overlay(RoundedRectangle(cornerRadius: 6.5).stroke(V3.cl))
    }

    // MARK: Screenshots

    /// 输入框里待发送的附件（02B·06 / 08 F）：图片 56×56 缩略图，其余文件卡；失败时细边变红、说明里是「重试」。
    private func screenshotStrip(_ shots: [ChatScreenshot], removable: Bool) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(shots) { shot in
                ZStack(alignment: .topTrailing) {
                    Group {
                        if shot.kind == "image", let data = shot.data, let image = NSImage(data: data) {
                            Button { openPreview(shot.tab) } label: {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(shot.status == .failed ? V3.red : V3.cl))
                            }.buttonStyle(.plain).accessibilityLabel("预览 \(shot.label)")
                                .overlay { if shot.status == .uploading { ProgressView().controlSize(.small) } }
                        } else {
                            let detail = shot.status == .uploading ? "正在上传…" : shot.status == .failed ? "上传失败" :
                                [shot.kind == "audio" ? "录音" : (shot.label.split(separator: ".").last.map { String($0).uppercased() } ?? ""), Self.fileSize(shot.size)].joined(separator: " · ")
                            attachmentCard(name: shot.label, symbol: Self.fileSymbol(shot.label, kind: shot.kind), detail: detail, failed: shot.status == .failed)
                        }
                    }
                    if removable {
                        Button { removeAttachment(shot) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(V3.fnt).background(Circle().fill(.white))
                        }.buttonStyle(.plain).offset(x: 5, y: -5).accessibilityLabel("移除附件 \(shot.label)")
                    }
                }
            }
            ForEach(shots.filter { $0.error != nil }) { shot in
                HStack(spacing: 6) {
                    Text("\(shot.label)：\(shot.error ?? "")").font(V3.sans(11.5)).foregroundStyle(V3.red)
                    Button("重试") { Task { await upload(shot.id) } }.buttonStyle(.plain).font(V3.sans(11.5)).foregroundStyle(V3.red)
                }
            }
        }
    }

    /// 添加附件：与 Web 同样的类型与数量限制，选好就上传到当前对话（还没有会话时先建会话）。
    private func addFiles(_ urls: [URL]) {
        guard !sending else { notice = "请等待当前请求完成后添加附件。"; return }
        guard urls.allSatisfy({ AgentAttachmentUpload.extensions.contains($0.pathExtension.lowercased()) }) else {
            notice = "支持图片、PDF、DOCX、MD、TXT，以及 MP3、WAV、M4A、OGG、WebM 录音。"; return
        }
        let sizes = urls.map { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        let total = screenshots.map(\.size).reduce(0, +) + sizes.reduce(0, +)
        guard screenshots.count + urls.count <= AgentAttachmentUpload.maxFiles, sizes.allSatisfy({ $0 > 0 && $0 <= AgentAttachmentUpload.maxBytes }),
              total <= AgentAttachmentUpload.maxTotalBytes else {
            notice = "最多添加 10 个附件，单个不超过 10 MiB，合计不超过 30 MiB。"; return
        }
        notice = nil
        let drafts = urls.map { url in
            ChatScreenshot(id: UUID().uuidString.lowercased(), label: url.lastPathComponent, file: url,
                           data: AgentAttachmentUpload.kind(url.lastPathComponent) == "image" ? try? Data(contentsOf: url) : nil)
        }
        screenshots += drafts
        Task { for draft in drafts { await upload(draft.id) } }
    }

    private func upload(_ id: String) async {
        guard let index = screenshots.firstIndex(where: { $0.id == id }), let client = api as? HTTPAPIClient else { return }
        screenshots[index].status = .uploading; screenshots[index].error = nil
        do {
            let sessionID = try await ensureSession()
            let result = try await client.uploadAgentAttachment(AgentAttachmentUpload(session: sessionID, file: screenshots[index].file))
            let attachment = result["attachment"] ?? result
            guard let current = screenshots.firstIndex(where: { $0.id == id }) else {
                // 上传期间被移除：删掉服务端的附件
                _ = try? await api.careerRequest(path: "/api/agent/sessions/\(sessionID)/attachments/\(attachment.text("id"))", method: "DELETE", query: [:], body: nil)
                return
            }
            let uploaded = ["ready", "uploaded"].contains(attachment.text("status")) || attachment.text("status").isEmpty
            screenshots[current].attachmentID = attachment.text("id")
            screenshots[current].status = uploaded ? .ready : .failed
            screenshots[current].error = uploaded ? nil : "上传失败，请重试。"
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            if let current = screenshots.firstIndex(where: { $0.id == id }) {
                screenshots[current].status = .failed; screenshots[current].error = AgentAttachmentUpload.errorMessage(error)
            }
        }
    }

    private func removeAttachment(_ shot: ChatScreenshot) {
        screenshots.removeAll { $0.id == shot.id }
        closePreview(shot.tab.key)
        if let attachment = shot.attachmentID, let currentID {
            Task {
                do { _ = try await api.careerRequest(path: "/api/agent/sessions/\(currentID)/attachments/\(attachment)", method: "DELETE", query: [:], body: nil) }
                catch { notice = AgentRequest.errorMessage(error) }
            }
        }
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// 剪贴板或截图得到的图片先写成私有临时 PNG，再走同一条上传路径。
    private func addImageData(_ data: Data, label: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drawoffer-chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(UUID().uuidString + "-" + label)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { notice = "图片读取失败。"; return }
        addFiles([url])
    }

    private func pasteImage() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { addFiles(urls); return }
        if let data = board.data(forType: .png) { addImageData(data, label: "粘贴的截图.png"); return }
        if let image = NSImage(pasteboard: board), let data = Self.png(image) { addImageData(data, label: "粘贴的截图.png"); return }
        notice = "剪贴板里没有图片或文件。"
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AgentAttachmentUpload.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
    }

    /// Web `isDocumentRequest`：明确要求生成文档（且没有否定）的请求。
    static func isDocumentRequest(_ prompt: String) -> Bool {
        prompt.range(of: "(?:不要|不必|不用|不需要|无需|别).{0,8}(?:生成|整理|写|输出|制作|准备)", options: .regularExpression) == nil
            && prompt.range(of: "(?:生成|整理成|写|输出|制作|准备).{0,30}(?:文档|\\.md|markdown)", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 回答进行中按发送不打断 AI：消息进待发送卡片（`queueDraft`），可再点「立即发送」插进当前回答。
    private var canSend: Bool { !sending && ready != false && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var currentModelName: String? { models.first { $0.text("id") == modelID }?.text("name").nilIfEmpty ?? modelName }

    /// Web 文档生成规则：完整回复中有一级 Markdown 标题时视为可保存的文档。
    static func documentTitle(_ content: String) -> String? {
        content.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func contextTypeLabel(_ type: String) -> String {
        ["user_profile": "求职资料", "resume": "简历", "resume_version": "简历版本", "dataset": "资料", "job": "岗位", "application": "求职进程", "interview": "面试记录"][type] ?? type
    }

    // MARK: Actions

    private func open() async {
        currentID = sessionID; messages = []; proposals = []; streaming = ""; error = nil; title = "新对话"; answers = [:]
        previewTabs = []; previewActive = nil; previewOpen = false; unavailableFiles = []
        screenshots = []; notice = nil; contextUsage = nil; clarificationPage = 0; otherAnswers = [:]
        processes = [:]; live = AssistantProcessSnapshot(); editingIndex = nil; floating = nil
        queue = []; ratings = [:]; ratingOpen = nil; ratingThanks = nil; jobMissing = nil
        let api = self.api
        // 就绪状态、当前模型、模型列表与这条对话的内容互不依赖：一起读（Web 各自独立加载）；
        // 应用顺序不变——先按列表定默认模型，再由对话里选过的模型覆盖
        async let readiness = try? api.careerRequest(path: "/api/agent/readiness", method: "GET", query: [:], body: nil)
        async let model = try? api.careerRequest(path: "/api/agent/model", method: "GET", query: [:], body: nil)
        async let modelList = try? api.careerRequest(path: "/api/agent/models", method: "GET", query: [:], body: nil)
        async let conversation = Self.conversation(api: api, id: sessionID)
        let (readyValue, modelValue) = await (readiness, model)
        if case .bool(let flag) = readyValue?["ready"] { ready = flag } else { ready = readyValue == nil ? nil : false }
        modelName = modelValue?["model"]?.text("name").nilIfEmpty
        if let list = await modelList {
            models = list["models"]?.items ?? []
            modelID = (sessionID == nil ? initialModelID : nil) ?? list["defaultModelId"]?.stringValue ?? modelValue?["model"]?.text("id").nilIfEmpty
        }
        if let sessionID {
            await reload(sessionID, prefetched: await conversation)
            if let active = try? await api.careerRequest(path: "/api/agent/sessions/\(sessionID)/active-run", method: "GET", query: [:], body: nil),
               let run = active["run"]?.text("run_id"), !run.isEmpty {
                await stream(path: "/api/agent/runs/\(run)/events", method: "GET", body: nil, sessionID: sessionID)
            }
        }
        if let initialMessage, !consumedInitial, !initialMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            consumedInitial = true
            await send(initialMessage)
        } else if let knowledge, sessionID == nil, !consumedInitial {
            consumedInitial = true
            await send("聊聊\(knowledge.name)", kickoff: true)
        } else if let initialDraft, !consumedInitial, draft.isEmpty {
            consumedInitial = true
            draft = initialDraft
        }
        await loadContexts()
    }

    private static func conversation(api: any APIClient, id: String?) async -> Result<JSONValue, any Error>? {
        guard let id else { return nil }
        do { return .success(try await api.careerRequest(path: "/api/agent/sessions/\(id)", method: "GET", query: [:], body: nil)) }
        catch { return .failure(error) }
    }

    /// `prefetched`：打开对话时已经和其他读取一起发出的 `GET /api/agent/sessions/{id}` 结果（成功或失败都照常处理）。
    private func reload(_ id: String, prefetched: Result<JSONValue, any Error>? = nil) async {
        do {
            let result: JSONValue
            if let prefetched { result = try prefetched.get() }
            else { result = try await api.careerRequest(path: "/api/agent/sessions/\(id)", method: "GET", query: [:], body: nil) }
            guard currentID == id else { return }
            messages = result["session"]?["messages"]?.items ?? []
            title = result["session"]?.text("title").nilIfEmpty ?? "新对话"
            contextUsage = result["session"]?["context_usage"]
            if let selected = result["session"]?["selected_model_id"]?.stringValue { modelID = selected }
            if let list = try? await api.careerRequest(path: "/api/agent/proposals", method: "GET", query: ["session_id": id], body: nil), currentID == id {
                proposals = list["proposals"]?.items ?? []
            }
            await refreshJobReadiness()
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            if currentID == id { self.error = AgentRequest.errorMessage(error) }
        }
    }

    private func loadContexts() async {
        guard contextGroups.isEmpty, let result = try? await api.careerRequest(path: "/api/agent/contexts", method: "GET", query: ["limit": "50"], body: nil) else { return }
        if let groups = result["groups"]?.items, !groups.isEmpty { contextGroups = groups }
        else if let flat = result["contexts"]?.items {
            var types: [String] = []
            for item in flat where !types.contains(item.text("type")) { types.append(item.text("type")) }
            contextGroups = types.map { type in .object(["type": .string(type), "items": .array(flat.filter { $0.text("type") == type })]) }
        }
    }

    private func ensureSession(title: String? = nil) async throws -> String {
        if let currentID { return currentID }
        var fields: [String: JSONValue] = [:]
        if let modelID { fields["modelId"] = .string(modelID) }
        if let title { fields["title"] = .string(title) }
        let result = try await api.careerRequest(path: "/api/agent/sessions", method: "POST", query: [:], body: .object(fields))
        guard let id = result["session"]?.text("id").nilIfEmpty else { throw APIError.invalidResponse }
        currentID = id; self.title = result["session"]?.text("title").nilIfEmpty ?? "新对话"
        created(id)
        return id
    }

    /// `queued`：待发送卡片里的消息，带它自己的引用，不动输入框里的草稿、引用和附件。
    private func send(_ text: String, replyTo: Int? = nil, clarificationAnswers: [JSONValue]? = nil, kickoff: Bool = false, queued: [JSONValue]? = nil) async {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if replyTo == nil, queued == nil, screenshots.contains(where: { $0.status != .ready }) {
            notice = screenshots.contains { $0.status == .uploading } ? "附件还在上传，请稍候。" : "有附件没有上传成功，请重试或移除。"
            return
        }
        guard !content.isEmpty, !sending else { return }
        sending = true; error = nil; streaming = ""; status = nil; creditBlock = nil; floating = nil
        let attached = queued ?? contexts
        do {
            let id = try await ensureSession(title: knowledge?.name)
            // Web：明确要文档时在发出的内容后追加输出要求，本地气泡仍显示原话
            let sent = Self.isDocumentRequest(content) ? content + "\n\n请输出完整 Markdown 文档，以一级标题开头；如果资料不足，请先询问，不要编造经历或数据。" : content
            var body: [String: JSONValue] = ["content": .string(sent), "idempotency_key": .string(UUID().uuidString.lowercased())]
            // 图谱节点的对话：只有第一条带知识点；kickoff 是打开动作本身，不显示
            let knowledgeFirst = knowledge != nil && !messages.contains { $0.text("role") == "user" }
            if let knowledge, knowledgeFirst {
                body["knowledge_point"] = .string(knowledge.key)
                if kickoff { body["knowledge_kickoff"] = .bool(true) }
            }
            if !attached.isEmpty { body["contexts"] = Self.contextRefs(attached) }
            let files = replyTo == nil && queued == nil ? screenshots : []
            if !files.isEmpty { body["attachment_ids"] = .array(files.compactMap(\.attachmentID).map(JSONValue.string)) }
            if let replyTo { body["reply_to_sequence_no"] = .number(Double(replyTo)) }
            if let clarificationAnswers { body["clarification_answers"] = .array(clarificationAnswers) }
            if queued == nil { draft = ""; contexts = [] }
            answers = [:]
            if replyTo == nil, queued == nil { screenshots = [] }
            let sentFiles: [JSONValue] = files.map { .object(["file_name": .string($0.label), "kind": .string($0.kind), "file_size": .number(Double($0.size))]) }
            var local: [String: JSONValue] = ["role": .string("user"), "content": .string(content), "contexts": .array(attached), "attachments": .array(sentFiles)]
            if let knowledge, knowledgeFirst { local["knowledge_point"] = .object(["key": .string(knowledge.key), "name": .string(knowledge.name), "kickoff": .bool(kickoff)]) }
            messages.append(.object(local))
            await stream(path: "/api/agent/sessions/\(id)/messages", method: "POST", body: .object(body), sessionID: id)
        } catch {
            sending = false
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            if case APIError.server(_, let code) = error, ["CREDIT_INSUFFICIENT", "PAID_CREDIT_REQUIRED"].contains(code) {
                creditBlock = (code == "CREDIT_INSUFFICIENT" ? "exhausted" : "model", content)
                if messages.last?.text("role") == "user", messages.last?.text("content") == content { messages.removeLast() }
                return
            }
            self.error = AgentRequest.errorMessage(error)
        }
    }

    static func contextRefs(_ items: [JSONValue]) -> JSONValue {
        .array(items.map { item in
            var ref: [String: JSONValue] = ["type": .string(item.text("type")), "id": .string(item.text("id")), "presentation": .string("mention")]
            if !item.text("version_id").isEmpty { ref["version_id"] = .string(item.text("version_id")) }
            return .object(ref)
        })
    }

    // MARK: 待发送消息（Web `QueuedMessages`）

    /// 回答进行中按发送：消息不打断 AI，先放到输入框上方的待发送卡片里。
    private func queueDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !screenshots.isEmpty { notice = "带附件的消息请在回答结束后发送。"; return }
        guard let next = AgentQueue.adding(queue, AgentQueuedMessage(id: UUID().uuidString.lowercased(), content: text, contexts: contexts)) else {
            notice = "最多先排 \(AgentQueue.maximum) 条消息。"; return
        }
        queue = next; draft = ""; contexts = []; notice = nil
    }

    /// 立即发送：回答中插进当前这次回答（`POST /api/agent/runs/{id}/steer`，AI 做完手上这一步就接上）；没在回答时就是普通发送。
    private func sendQueuedNow(_ item: AgentQueuedMessage) {
        guard sending else {
            queue.removeAll { $0.id == item.id }
            Task { await send(item.content, queued: item.contexts) }
            return
        }
        guard let runID, AgentQueue.canInsert(queue, running: true, runID: runID, compacting: compacting) else { return }
        let key = UUID().uuidString.lowercased()
        queue = AgentQueue.inserting(queue, id: item.id, runID: runID, key: key)
        Task {
            var body: [String: JSONValue] = ["content": .string(item.content), "idempotency_key": .string(key)]
            if !item.contexts.isEmpty { body["contexts"] = Self.contextRefs(item.contexts) }
            do { _ = try await api.careerRequest(path: "/api/agent/runs/\(runID)/steer", method: "POST", query: [:], body: .object(body)) }
            catch {
                if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
                queue = AgentQueue.returned(queue, key: key, error: AgentRequest.errorMessage(error))
            }
        }
    }

    /// 编辑：放回输入框（输入框里已有内容时不覆盖）。
    private func editQueued(_ item: AgentQueuedMessage) {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, contexts.isEmpty else {
            notice = "先发送或清空输入框里的内容，再编辑这条消息。"; return
        }
        queue.removeAll { $0.id == item.id }
        draft = item.content; contexts = item.contexts
    }

    /// 回答结束：没接上的插入查一次回执，确实没用上的退回卡片；正常结束后自动发出第一条待发送消息。
    private func settleQueue(sessionID id: String, completed: Bool) async {
        for item in queue where item.state == .inserting {
            guard let run = item.runID, let key = item.submissionKey else { continue }
            let receipt = try? await api.careerRequest(path: "/api/agent/runs/\(run)/steer/\(key)", method: "GET", query: [:], body: nil)
            queue = ["accepted", "applied"].contains(receipt?.text("state") ?? "") ? AgentQueue.accepted(queue, key: key) : AgentQueue.returned(queue, key: key, error: nil)
        }
        guard completed, currentID == id, !sending, let next = AgentQueue.next(queue) else { return }
        queue.removeAll { $0.id == next.id }
        await send(next.content, queued: next.contexts)
    }

    // MARK: 回复评价（02B-15）

    private func rate(_ seq: Int, _ next: AgentRating) {
        guard let id = currentID, seq > 0 else { return }
        let previous = ratings[seq] ?? messages.first { AgentBranch.sequence($0) == seq }.flatMap { AgentRating($0["rating"]) }
        ratings[seq] = next
        Task {
            do { _ = try await api.careerRequest(path: "/api/agent/sessions/\(id)/messages/\(seq)/rating", method: "PUT", query: [:], body: next.json) }
            catch {
                if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
                if currentID == id { ratings[seq] = previous; if previous == nil { ratings.removeValue(forKey: seq) } }
            }
        }
    }

    private func currentRating(_ seq: Int) -> AgentRating? { ratings[seq] ?? messages.first { AgentBranch.sequence($0) == seq }.flatMap { AgentRating($0["rating"]) } }

    private func rateUp(_ seq: Int) {
        ratingOpen = nil
        rate(seq, AgentRating(up: true))
        thank(seq)
    }

    /// 点「没用」：还不是没用时记一条并展开原因；已经是没用时只收起 / 展开原因区。
    private func rateDown(_ seq: Int) {
        let current = currentRating(seq)
        if current?.up != false { rate(seq, AgentRating.down(from: current)); ratingNote = ""; ratingOpen = seq }
        else { ratingNote = current?.note ?? ""; ratingOpen = ratingOpen == seq ? nil : seq }
    }

    private func sendRatingNote(_ seq: Int) {
        rate(seq, (currentRating(seq) ?? AgentRating(up: false)).withNote(ratingNote))
        ratingOpen = nil
        thank(seq)
    }

    private func thank(_ seq: Int) {
        ratingThanks = seq
        Task { try? await Task.sleep(for: .seconds(2.4)); if ratingThanks == seq { ratingThanks = nil } }
    }

    // MARK: 找匹配岗位要先补画像（02B-16）

    /// 有「开始找岗位」卡片时读一次求职画像算还差什么；最后一条回复里的卡片、画像没填好时自动在右侧打开画像（每张卡只开一次）。
    private func refreshJobReadiness() async {
        let gates = messages.enumerated().flatMap { index, message in
            (message["cards"]?.items ?? []).filter { $0.text("type") == "profile_gate" }.map { (index, $0.text("id")) }
        }
        guard !gates.isEmpty else { return }
        if jobMissing == nil {
            async let career = try? api.careerRequest(path: "/api/account/career-profile", method: "GET", query: [:], body: nil)
            async let portrait = try? api.careerRequest(path: "/api/account/user-profile", method: "GET", query: [:], body: nil)
            let (profile, intent) = await (career, portrait)
            guard profile != nil || intent != nil else { return }
            jobMissing = JobReadiness.missing(profile: profile, intent: intent)
        }
        guard let last = gates.last, last.0 == messages.count - 1, jobMissing?.isEmpty == false, !Self.openedGates.contains(last.1) else { return }
        Self.openedGates.insert(last.1)
        openPreview(.careerProfile)
    }

    @MainActor private static var openedGates = Set<String>()

    // MARK: 首页知识图谱的对话（Figma 02A·10 ②–④）

    /// AI 开场白后面：先学还是去模拟面试练；用户回了一句之后不再出现（Web `assistant-knowledge-opening`）。
    private func topicChoicesShown(after index: Int) -> Bool {
        guard topic != nil, !sending, index == messages.count - 1, messages[index].text("role") == "assistant",
              messages[index].text("status").isEmpty,
              let user = messages[..<index].last(where: { $0.text("role") == "user" }) else { return false }
        return isKickoff(user)
    }

    private var topicChoices: some View {
        HStack(spacing: 8) {
            Button { Task { await send("先讲给我听") } } label: { Text("先讲给我听").padding(.horizontal, 18).frame(height: 36) }
                .buttonStyle(TopicChoiceStyle())
            Button { practiceTopic() } label: { Text("去模拟面试练 ↗").padding(.horizontal, 18).frame(height: 36) }
                .buttonStyle(TopicChoiceStyle())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「去模拟面试练 ↗」：带着这个知识点去模拟面试设置页（接着练）。
    private func practiceTopic() {
        guard let topic else { return }
        router.jump(.mock(PracticeFocus(kind: "topic", ref: topic.key, label: topic.name)))
    }

    /// 输入框上方的知识点标签：对话栏里是「● 名称 状态」，对话页是「名称 知识点 ×」，可以移除。
    private func topicTag(_ topic: HomeChatTopic) -> some View {
        HStack(spacing: 6) {
            if panel {
                Circle().fill(topic.tone == .hot ? V3.orange : topic.tone == .new ? V3.blue : V3.fnt).frame(width: 6, height: 6)
            } else {
                Image(systemName: "doc.text").font(.system(size: 9)).foregroundStyle(V3.sub)
            }
            Text(topic.name).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
            if panel, !topic.state.isEmpty { Text(topic.state).font(V3.sans(11)).foregroundStyle(Color(hex: 0x96968F)) }
            if !panel {
                Text("知识点").font(V3.sans(11)).foregroundStyle(Color(hex: 0x96968F))
                Button { topicTagHidden = true } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .medium)).foregroundStyle(V3.fnt) }
                    .buttonStyle(.plain).accessibilityLabel("移除知识点")
            }
        }
        .padding(.horizontal, 7).frame(height: 24)
        .background(.white, in: RoundedRectangle(cornerRadius: 6.5)).overlay(RoundedRectangle(cornerRadius: 6.5).stroke(V3.cl))
    }

    /// 回复里的 `drawoffer:mock/<id>`、`drawoffer:interview/<投递 id>/<场次 id>`：跳到那一场的报告或面试记录。
    private func openDrawOfferLink(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "drawoffer" else { return .systemAction }
        let parts = url.absoluteString.dropFirst("drawoffer:".count).split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "mock" { router.jump(.mockSession(parts[1])) }
        else if parts.count >= 2, parts[0] == "interview" { router.jump(.application(parts[1])) }
        return .handled
    }

    /// 改一条提问（02B·08 E）：`POST …/messages/{seq}:edit` 发出新版本，原来那一版及其后的对话保留可切回（‹ 1/2 ›）。
    private func submitEdit(_ index: Int, content raw: String? = nil) async {
        guard let id = currentID, messages.indices.contains(index), !sending,
              let seq = messages[index]["sequence_no"]?.numberValue.map({ Int($0) }) else { return }
        let content = (raw ?? editDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        let original = messages[index]
        editingIndex = nil; error = nil; streaming = ""; status = nil; creditBlock = nil
        messages = Array(messages.prefix(index)) + [.object(["role": .string("user"), "content": .string(content),
                                                               "contexts": original["contexts"] ?? .array([]), "attachments": original["attachments"] ?? .array([])])]
        await stream(path: "/api/agent/sessions/\(id)/messages/\(seq):edit", method: "POST",
                     body: .object(["content": .string(content), "idempotency_key": .string(UUID().uuidString.lowercased())]), sessionID: id)
    }

    /// 重新生成 = 原样重发最后一条提问：沿用编辑接口，它会替换这一轮的回复并保留引用的资料。
    private func regenerate() async {
        guard let target = AgentBranch.regenerable(messages, busy: sending || switchingVersion),
              let index = messages.firstIndex(where: { $0.text("role") == "user" && AgentBranch.sequence($0) == target.question }) else { return }
        ratingOpen = nil
        await submitEdit(index, content: messages[index].text("content"))
    }

    /// 切到提问的另一个版本：后端重排可见分支并让模型从那一版接着聊，这里换成返回的消息。
    private func switchVersion(_ seq: Int) async {
        guard let id = currentID, !sending, !switchingVersion else { return }
        switchingVersion = true
        defer { switchingVersion = false }
        do {
            let result = try await api.careerRequest(path: "/api/agent/sessions/\(id)/messages/\(seq):switch", method: "POST", query: [:], body: nil)
            guard currentID == id else { return }
            if let list = result["session"]?["messages"]?.items { messages = list }
            if let usage = result["session"]?["context_usage"], usage != .null { contextUsage = usage }
            ratingOpen = nil; error = nil
            if let list = try? await api.careerRequest(path: "/api/agent/proposals", method: "GET", query: ["session_id": id], body: nil), currentID == id {
                proposals = list["proposals"]?.items ?? []
            }
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            if currentID == id { self.error = AgentRequest.errorMessage(error) }
        }
    }

    private func stream(path: String, method: String, body: JSONValue?, sessionID id: String) async {
        sending = true; phaseStarted = Date(); live = AssistantProcessSnapshot(); processExpanded = false; runOutcome = nil
        defer {
            if let runID, processes[runID] != nil, processes[runID]?.ended == nil { processes[runID]?.ended = Date() }
            sending = false; runID = nil; status = nil
        }
        do {
            try await api.streamAgent(path: path, method: method, body: body) { event in
                guard currentID == id else { return }
                handle(event)
            }
        } catch is CancellationError {
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            if currentID == id { self.error = AgentRequest.errorMessage(error) }
        }
        streaming = ""
        if currentID == id { await reload(id) }
        sessionsChanged()
        // 等这一轮的 sending 收起后再处理待发送消息
        let completed = !["failed", "cancelled"].contains(runOutcome ?? "") && error == nil && creditBlock == nil
        Task { await settleQueue(sessionID: id, completed: completed) }
    }

    /// 准备过程：同一份改动同时记在当前显示（`live`）和按 runId 保留的快照里。
    private func updateProcess(_ change: (inout AssistantProcessSnapshot) -> Void) {
        change(&live)
        guard let runID else { return }
        var snapshot = processes[runID] ?? AssistantProcessSnapshot(started: phaseStarted)
        change(&snapshot)
        processes[runID] = snapshot
    }

    private func handle(_ event: AgentEvent) {
        let data = event.data
        if runID == nil, !data.text("runId").isEmpty { runID = data.text("runId") }
        switch event.type {
        case "run.phase": status = data.text("label").nilIfEmpty ?? status
        case "assistant.activity.status":
            let key = data.text("callKey")
            if key.isEmpty { status = data.text("label").nilIfEmpty ?? status; break }
            let activity = AssistantProcessSnapshot.Activity(callKey: key, label: data.text("label"), status: data.text("status").nilIfEmpty ?? "running", summary: data.text("summary"))
            updateProcess { snapshot in
                if let index = snapshot.activities.firstIndex(where: { $0.callKey == key }) { snapshot.activities[index] = activity }
                else { snapshot.activities.append(activity); snapshot.timeline.append(.tool(key)) }
            }
        case "assistant.activity.delta":
            let delta = data.text("delta")
            updateProcess { snapshot in
                if case .text(let text)? = snapshot.timeline.last { snapshot.timeline[snapshot.timeline.count - 1] = .text(text + delta) }
                else { snapshot.timeline.append(.text(delta)) }
            }
        case "assistant.activity.clear": live = AssistantProcessSnapshot(); processExpanded = false
        case "tool.started": if live.activities.isEmpty { status = "正在调用工具…" }
        case "assistant.delta": streaming += data.text("delta")
        case "assistant.delta.reset": streaming = ""
        case "user.message.accepted", "user.message.applied":
            // 插进当前回答的待发送消息被接上：从卡片里移走，作为一条用户消息出现在对话里
            let key = data.text("submissionKey")
            guard !key.isEmpty, let item = queue.first(where: { $0.submissionKey == key }) else { break }
            queue = AgentQueue.accepted(queue, key: key)
            let seq = data["userSequenceNo"]?.integer ?? 0
            if !messages.contains(where: { $0.text("role") == "user" && (seq > 0 && AgentBranch.sequence($0) == seq) }) {
                messages.append(.object(["role": .string("user"), "content": .string(data.text("content").nilIfEmpty ?? item.content),
                                         "contexts": data["contexts"] ?? .array(item.contexts), "sequence_no": .number(Double(seq))]))
            }
        case "run.completed": runOutcome = "completed"
        case "assistant.message.completed":
            var message: [String: JSONValue] = ["role": .string("assistant"), "content": .string(data.text("content")),
                                                "sequence_no": data["sequenceNo"] ?? .null, "run_id": .string(runID ?? "")]
            if let clarification = data["clarification"] { message["clarification"] = clarification }
            if let cards = data["cards"] { message["cards"] = cards }
            messages.append(.object(message)); streaming = ""
            if let runID { processes[runID]?.ended = Date() }
        case "clarification.requested":
            if let index = messages.lastIndex(where: { $0.text("role") == "assistant" }), case .object(var fields) = messages[index] {
                fields["clarification"] = data["clarification"]; messages[index] = .object(fields)
            }
        case "proposal.created": if let proposal = data["proposal"] { proposals.append(proposal) }
        case "context.usage", "context.compaction.completed":
            let window = data["contextWindow"] ?? contextUsage?["context_window"] ?? .null
            contextUsage = .object(["tokens": data["tokens"] ?? .null, "context_window": window, "breakdown": data["breakdown"] ?? contextUsage?["breakdown"] ?? .null])
        case "context.compaction.started": status = "正在压缩上下文…"
        case "user.message.rejected":
            let key = data.text("submissionKey")
            if !key.isEmpty, queue.contains(where: { $0.submissionKey == key }) { queue = AgentQueue.returned(queue, key: key, error: "没有插入成功，可以再试一次。") }
            else { error = AgentRequest.errorMessage(APIError.server(status: 409, code: data.text("error"))) }
        case "run.failed":
            runOutcome = "failed"
            let code = data.text("error")
            if ["CREDIT_INSUFFICIENT", "PAID_CREDIT_REQUIRED"].contains(code),
               let last = messages.last(where: { $0.text("role") == "user" }) {
                creditBlock = (code == "CREDIT_INSUFFICIENT" ? "exhausted" : "model", last.text("content"))
            } else { error = AgentRequest.errorMessage(APIError.server(status: 500, code: code)) }
        case "run.cancelled": runOutcome = "cancelled"; status = nil; if !streaming.isEmpty { messages.append(.object(["role": .string("assistant"), "content": .string(streaming + "\n\n（已停止生成）")])); streaming = "" }
        default: break
        }
    }

    private func answerClarification(_ message: JSONValue, questions: [JSONValue]) async {
        let text = questions.map { question in
            let id = question.text("id")
            let value = answers[id] == "__other__" ? (otherAnswers[id] ?? "").trimmingCharacters(in: .whitespaces)
                : (question["options"]?.items ?? []).first { $0.text("id") == answers[id] }?.text("label") ?? ""
            return "\(question.text("header"))：\(value)"
        }.joined(separator: "\n")
        let payload = questions.map { question -> JSONValue in
            let id = question.text("id")
            var item: [String: JSONValue] = ["question_id": .string(id), "option_id": .string(answers[id] ?? "")]
            if answers[id] == "__other__" { item["value"] = .string((otherAnswers[id] ?? "").trimmingCharacters(in: .whitespaces)) }
            return .object(item)
        }
        clarificationPage = 0; otherAnswers = [:]
        await send(text, replyTo: message["sequence_no"]?.integer, clarificationAnswers: payload)
    }

    private var freeModel: JSONValue? { models.first { $0["isFreeTier"]?.bool == true && $0.text("id") != modelID } }

    /// 05.01：积分不足的白卡；开通会员 / 购买积分打开会员与积分弹窗的对应标签。
    private func creditNotice(_ block: (kind: String, content: String)) -> some View {
        let title = block.kind == "exhausted" ? "积分已用完，这次回复没有完成"
            : currentModelName.map { "\($0) 暂不可用于当前额度" } ?? "这项功能暂不可用于当前额度"
        let body = block.kind == "exhausted" ? "你的消息已保留，充值后可以直接重新发送。" : "当前额度只能使用基础模型，可以改用基础模型重新发送。"
        var fallback: (label: String, action: () -> Void)?
        if block.kind == "model", let free = freeModel {
            fallback = (label: "改用 \(free.text("name")) 重新发送", action: { Task { await chooseModel(free); creditBlock = nil; await send(block.content) } })
        }
        return AccountCreditsShortCard(title: title, message: body,
                                       onPlans: { creditPlansTab = .init(id: "membership") },
                                       onCredits: { creditPlansTab = .init(id: "pack") },
                                       fallback: fallback,
                                       restore: { draft = block.content; creditBlock = nil })
            .centeredSheet(item: $creditPlansTab) { tab in PlansSheet(initialTab: tab.id) }
            .accessibilityLabel(title)
    }

    // MARK: 修改建议（02B·11）

    /// 同一轮提问产生的建议合在一块（Web `proposalGroup`）。
    private var proposalGroups: [(key: String, items: [JSONValue])] {
        let users = messages.filter { $0.text("role") == "user" }
        var order: [String] = [], groups: [String: [JSONValue]] = [:]
        for proposal in proposals {
            let source = proposal["source_user_sequence_no"]?.integer
            let owner = users.first { source != nil ? $0["sequence_no"]?.integer == source : (!proposal.text("run_id").isEmpty && $0.text("run_id") == proposal.text("run_id")) }
            let key = owner.map { String($0["sequence_no"]?.integer ?? 0) } ?? "history-\(proposal.text("run_id"))"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(proposal)
        }
        return order.map { ($0, groups[$0]!) }
    }

    /// 建议块挂在这一轮最后一条消息下面（下一条用户消息之前）。
    private var anchoredGroups: [Int: [(key: String, items: [JSONValue])]] {
        var result: [Int: [(key: String, items: [JSONValue])]] = [:]
        for group in proposalGroups {
            guard let owner = messages.firstIndex(where: { $0.text("role") == "user" && String($0["sequence_no"]?.integer ?? -1) == group.key }) else { continue }
            let next = messages[(owner + 1)...].firstIndex { $0.text("role") == "user" } ?? messages.count
            let anchor = next - 1
            // 这一轮还在生成时放到末尾（等待区之后）
            if anchor == messages.count - 1 && sending { continue }
            result[anchor, default: []].append(group)
        }
        return result
    }

    private var looseGroups: [(key: String, items: [JSONValue])] {
        let anchored = Set(anchoredGroups.values.flatMap { $0.map(\.key) })
        return proposalGroups.filter { !anchored.contains($0.key) }
    }

    private func suggestionList(_ items: [JSONValue]) -> some View {
        AssistantSuggestionList(proposals: items, busy: proposalBusy, running: sending,
                                apply: { await decide($0, confirm: true) }, reject: { await decide($0, confirm: false) },
                                rewrite: rewriteProposal)
    }

    /// 没能采用时「按现在的内容重写」（Web `rewriteProposal`）：输入框空就直接发，有草稿就接在草稿后面。
    private func rewriteProposal(_ place: String) {
        let text = "简历里「\(place)」这一处刚改过，请按现在的内容重新给这一处的修改建议。"
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && screenshots.isEmpty { Task { await send(text) } }
        else { draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : draft.trimmingCharacters(in: .whitespacesAndNewlines) + " " + text }
    }

    @discardableResult
    private func decide(_ proposal: JSONValue, confirm: Bool) async -> Bool {
        let id = proposal.text("id")
        guard proposalBusy == nil else { return false }
        proposalBusy = id; defer { proposalBusy = nil }
        do {
            _ = try await api.careerRequest(path: "/api/agent/proposals/\(id)/\(confirm ? "confirm" : "reject")", method: "POST", query: [:], body: nil)
            if let index = proposals.firstIndex(where: { $0.text("id") == id }), case .object(var fields) = proposals[index] {
                fields["status"] = .string(confirm ? "applied" : "rejected"); proposals[index] = .object(fields)
            }
            error = nil
            return true
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            // 简历刚被改过：这一处标“没能采用”，原位换成「按现在的内容重写」
            if case APIError.server(_, "AGENT_PROPOSAL_CONFLICT") = error,
               let index = proposals.firstIndex(where: { $0.text("id") == id }), case .object(var fields) = proposals[index] {
                fields["status"] = .string("conflicted"); proposals[index] = .object(fields)
                return false
            }
            self.error = AgentRequest.errorMessage(error)
            if let current = currentID { await reload(current) }
            return false
        }
    }

    private func chooseModel(_ model: JSONValue) async {
        let id = model.text("id")
        guard id != modelID else { return }
        let previous = modelID
        modelID = id
        guard let currentID else { return }
        do { _ = try await api.careerRequest(path: "/api/agent/sessions/\(currentID)", method: "PATCH", query: [:], body: .object(["modelId": .string(id)])) }
        catch { modelID = previous; self.error = AgentRequest.errorMessage(error) }
    }

    /// 压缩上下文（Web `compactConversation`）：流式执行，结束后刷新会话与用量。
    private func compact() async {
        guard let currentID, !sending else { return }
        error = nil
        compacting = true
        defer { compacting = false }
        await stream(path: "/api/agent/sessions/\(currentID)/compact", method: "POST",
                     body: .object(["idempotency_key": .string(UUID().uuidString.lowercased())]), sessionID: currentID)
    }

    private func newConversation() {
        currentID = nil; messages = []; proposals = []; streaming = ""; error = nil; title = "新对话"
        screenshots = []; contexts = []; contextUsage = nil; processes = [:]; live = AssistantProcessSnapshot(); editingIndex = nil
        queue = []; ratings = [:]; ratingOpen = nil; jobMissing = nil
    }

    private func cancel() async {
        guard let runID else { return }
        _ = try? await api.careerRequest(path: "/api/agent/runs/\(runID)/cancel", method: "POST", query: [:], body: nil)
    }
}

/// 开场白下面的白底细边胶囊按钮（`.v3-btn-ghost`）。
private struct TopicChoiceStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(13.5, weight: .medium)).foregroundStyle(V3.txt)
            .background(.white, in: Capsule()).overlay(Capsule().stroke(hovering || configuration.isPressed ? V3.txt : Color(hex: 0xDCDAD2)))
            .contentShape(Capsule()).onHover { hovering = $0 }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct DocumentDraft: Identifiable { let content: String; var id: String { content } }

/// 待发送的对话附件（Web `AttachmentDraft`）：选好后立即上传到当前对话，发送时带上 `attachment_ids`。
struct ChatScreenshot: Identifiable, Equatable {
    enum Status: Equatable { case pending, uploading, ready, failed }
    let id: String
    let label: String
    let file: URL
    var data: Data?
    var status: Status = .pending
    var attachmentID: String?
    var error: String?
    var kind: String { AgentAttachmentUpload.kind(label) }
    var size: Int { (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    var tab: ChatPreviewTab { ChatPreviewTab(kind: .image, id: id, label: label, imageData: data) }
}

/// 把 AI 生成的文档以 `.md` 保存到资料库所选文件夹（Web “保存到资料库”）。重名时加时间后缀保留两份；
/// 上传使用固定标识，网络结果不确定时重试不会重复保存。
private struct SaveDocumentSheet: View {
    @Environment(SessionStore.self) private var session
    let content: String
    let title: String
    let close: () -> Void
    var saved: () -> Void = {}
    @State private var folders: [JSONValue] = []
    @State private var folder = ""
    @State private var newFolder = ""
    @State private var busy = false
    @State private var error: String?
    @State private var upload: DatasetUpload?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("保存到资料库").font(V3.serif(20))
            Text("「\(title)」将以 Markdown 文件保存。").font(V3.sans(13)).foregroundStyle(V3.sub)
            Picker("文件夹", selection: $folder) {
                Text("选择文件夹").tag("")
                ForEach(folders, id: \.self) { Text($0.text("name")).tag($0.text("id")) }
            }.disabled(busy || upload != nil)
            HStack {
                TextField("或新建文件夹", text: $newFolder).textFieldStyle(.roundedBorder)
                Button("新建") { Task { await createFolder() } }.buttonStyle(V3ButtonStyle(kind: .ghost))
                    .disabled(busy || newFolder.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消") { upload?.discard(); close() }.buttonStyle(V3ButtonStyle(kind: .ghost)).disabled(busy)
                Button(busy ? "正在保存…" : "保存") { Task { await save() } }.buttonStyle(V3ButtonStyle(kind: .dark)).disabled(busy || folder.isEmpty)
            }
        }.padding(24).frame(width: 440)
            .task { await loadFolders() }
    }

    private func loadFolders() async {
        guard let result = try? await session.api.careerRequest(path: "/api/datasets/folders", method: "GET", query: [:], body: nil) else { error = "文件夹读取失败，请稍后重试。"; return }
        folders = (result["folders"]?.items ?? result["items"]?.items ?? []).filter { !$0.text("id").isEmpty }
        if folder.isEmpty { folder = folders.first?.text("id") ?? "" }
    }

    private func createFolder() async {
        busy = true; defer { busy = false }
        do {
            let result = try await session.api.careerRequest(path: "/api/datasets/folders", method: "POST", query: [:],
                                                             body: .object(["name": .string(newFolder.trimmingCharacters(in: .whitespacesAndNewlines))]))
            newFolder = ""
            await loadFolders()
            if let id = (result["folder"] ?? result)["id"]?.stringValue { folder = id }
        } catch { self.error = "新建文件夹失败，可能已有同名文件夹。" }
    }

    private func save() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            if upload == nil || upload?.folder != folder {
                upload?.discard()
                let safe = title.map { "/:\\\0".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }.prefix(80)
                let directory = try DatasetUpload.privateDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let source = directory.appendingPathComponent(String(safe) + ".md")
                try Data(content.utf8).write(to: source)
                upload = try DatasetUpload.snapshot(source, folder: folder, limit: 50 * 1024 * 1024)
            }
            guard var current = upload else { return }
            do { _ = try await session.api.uploadDataset(current) }
            catch APIError.server(_, let code) where ["DATASET_NAME_CONFLICT", "DATASET_FILENAME_CONFLICT"].contains(code) {
                let formatter = Beijing.formatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
                current = current.rekey(); current.name = title + "-" + formatter.string(from: Date()) + ".md"; upload = current
                _ = try await session.api.uploadDataset(current)
            }
            current.discard(); upload = nil
            saved()
            close()
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            self.error = "保存失败：结果尚未确认时可直接重试，不会重复保存。"
        }
    }
}


/// 对话输入框：回车发送、⇧ 回车换行、输入法组字时回车照常确认；⌘V 粘贴图片或文件时走附件。
struct ChatInputField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let submit: () -> Void
    var escape: () -> Void = {}
    var paste: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: 14)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = NSSize(width: 0, height: 6)
        view.setAccessibilityLabel("告诉助手你想完成什么")
        context.coordinator.view = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        context.coordinator.refresh()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputField
        weak var view: NSTextView?
        private var hint: NSTextField?
        init(parent: ChatInputField) { self.parent = parent }

        func refresh() {
            guard let view else { return }
            let label = hint ?? {
                let field = NSTextField(labelWithString: "")
                // Figma 02B 输入框占位 #A3A39C
                field.textColor = NSColor(srgbRed: 0xA3 / 255, green: 0xA3 / 255, blue: 0x9C / 255, alpha: 1)
                field.font = .systemFont(ofSize: 14)
                view.addSubview(field)
                hint = field
                return field
            }()
            label.stringValue = parent.placeholder
            label.isHidden = !view.string.isEmpty
            label.frame = NSRect(x: 5, y: 6, width: max(0, view.bounds.width - 10), height: 18)
        }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string
            refresh()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if textView.hasMarkedText() { return false }
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { textView.insertNewlineIgnoringFieldEditor(nil); return true }
                parent.submit(); return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) { parent.escape(); return true }
            return false
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool { true }
    }
}

/// 这次记下的记忆（Web `CitationCard` 的“这次记下”）：可逐条撤销（写入排除约束）或恢复；可收起、关闭。
struct MemoryReceipt: View {
    @Environment(SessionStore.self) private var session
    let sessionID: String
    let refresh: Int
    @State private var items: [JSONValue] = []
    @State private var undone: [String: String] = [:]
    @State private var folded = false
    @State private var closed = false

    var body: some View {
        Group {
            if !closed, !items.isEmpty {
                if folded {
                    Button { folded = false } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "brain").font(.system(size: 11))
                            Text("这次记下 \(items.count) 条").font(V3.sans(12))
                            Image(systemName: "chevron.down").font(.system(size: 9))
                        }.foregroundStyle(V3.sub).padding(.horizontal, 10).frame(height: 26).background(V3.field, in: Capsule())
                    }.buttonStyle(.plain)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("这次记下 \(items.count) 条").font(V3.sans(12.5, weight: .medium))
                            Spacer()
                            Button { folded = true } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).accessibilityLabel("收起记下的内容")
                            Button { closed = true } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭")
                        }.foregroundStyle(V3.sub)
                        ForEach(items, id: \.self) { item in
                            let key = item.text("key")
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(undone[key] == nil ? V3.blue : V3.fnt2).frame(width: 6, height: 6).padding(.top, 6)
                                Text(undone[key] != nil ? "已撤销，这条不会记下" : item.text("value").nilIfEmpty ?? item.text("quote").nilIfEmpty ?? item.text("label"))
                                    .font(V3.sans(12.5)).foregroundStyle(undone[key] != nil ? V3.fnt : V3.txt).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Button(undone[key] != nil ? "恢复" : "撤销") { Task { await toggle(item) } }.buttonStyle(.link).font(V3.sans(12))
                            }
                        }
                    }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.cl))
                }
            }
        }.task(id: "\(sessionID)|\(refresh)") { await load() }
    }

    private func load() async {
        guard let result = try? await session.api.careerRequest(path: "/api/agent/sessions/\(sessionID)/memory/recorded", method: "GET", query: [:], body: nil),
              result["enabled"]?.bool == true else { return }
        items = result["items"]?.items ?? []
    }

    private func toggle(_ item: JSONValue) async {
        let key = item.text("key")
        do {
            if let id = undone[key] {
                _ = try await session.api.careerRequest(path: "/api/memory/constraints/\(id)", method: "DELETE", query: [:], body: nil)
                undone.removeValue(forKey: key)
            } else {
                let created = try await session.api.careerRequest(path: "/api/memory/constraints", method: "POST", query: [:],
                    body: .object(["kind": .string("exclude"), "target": .object(["target": .string(item.text("delete"))])]))
                undone[key] = created.text("id")
            }
        } catch {}
    }
}
