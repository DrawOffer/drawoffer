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

/// AI 对话（Web `features/assistant/AssistantPage.tsx` 的核心流程）：会话消息、流式回复、追问选项、
/// 简历修改建议的应用/不采用、附加资料、截图附件与停止生成。消息带固定幂等键，中断后刷新即可确认结果。
/// 截图与 Web 一致只在本机：带截图发送时不请求后端，在对话里留下本地消息并可在右侧预览。
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
    /// 生成状态回报给侧栏：生成中的对话不能删除（与 Web 一致）。
    var runningChanged: (String, Bool) -> Void = { _, _ in }

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
    @State private var addMenu = false
    @State private var modelID: String?
    @State private var steering = false
    @State private var savingDocument: String?
    @State private var contexts: [JSONValue] = []
    @State private var contextGroups: [JSONValue] = []
    @State private var answers: [String: String] = [:]
    @State private var proposalBusy: String?
    @State private var consumedInitial = false
    @State private var previewTabs: [ChatPreviewTab] = []
    @State private var previewActive: String?
    @State private var previewOpen = false
    @State private var unavailableFiles = Set<String>()
    @State private var savedDocuments = Set<String>()
    @State private var screenshots: [ChatScreenshot] = []
    @State private var contextUsage: JSONValue?
    @State private var usageOpen = false
    @State private var slashDismissed = false
    @State private var clarificationPage = 0
    @State private var otherAnswers: [String: String] = [:]
    @State private var copiedMessage: Int?
    @State private var referencePicker = false
    @State private var previewFullscreen = false
    /// 额度拦截（Web `CreditNotice`）：额度用完，或当前模型不可用于当前额度；保留原消息以便重发。
    @State private var creditBlock: (kind: String, content: String)?
    @State private var batchProgress: (key: String, completed: Int, total: Int)?
    /// “继续调整”：下一条消息带 `revision_proposal_id`，在该建议基础上修改。
    @State private var revisionProposalID: String?
    @State private var notice: String?

    private var api: any APIClient { session.api }
    private var pendingClarification: JSONValue? {
        guard !sending, let last = messages.last, last.text("role") == "assistant", let clarification = last["clarification"], clarification != .null,
              !(clarification["questions"]?.items ?? []).isEmpty else { return nil }
        return last
    }

    var body: some View {
        HStack(spacing: 0) {
            if !(previewFullscreen && previewOpen && !previewTabs.isEmpty) { chat.overlay(alignment: .topTrailing) { filesToggle } }
            if previewOpen, !previewTabs.isEmpty {
                Divider()
                ChatPreviewPanel(tabs: previewTabs.map { tab in var tab = tab; if tab.kind == .generated { tab.saved = savedDocuments.contains(tab.content) }; return tab },
                                 active: previewActive, unavailable: unavailableFiles,
                                 activate: { previewActive = $0 }, closeTab: closePreview, close: { previewOpen = false },
                                 save: { savingDocument = $0.content }, markUnavailable: { unavailableFiles.insert($0) },
                                 fullscreen: $previewFullscreen)
                    .frame(width: previewFullscreen ? nil : 460)
                    .frame(maxWidth: previewFullscreen ? .infinity : 460)
            }
        }
        .task(id: sessionID ?? "new") { await open() }
        .sheet(item: Binding(get: { savingDocument.map { DocumentDraft(content: $0) } }, set: { if $0 == nil { savingDocument = nil } })) { draft in
            SaveDocumentSheet(content: draft.content, title: Self.documentTitle(draft.content) ?? "AI 文档", close: { savingDocument = nil },
                              saved: { savedDocuments.insert(draft.content) })
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                            if message.text("message_type") == "compaction" { compactionDivider(message) }
                            else if message.text("message_type") != "clarification" || !message.text("content").isEmpty { bubble(message, index: index) }
                        }
                        ForEach(proposalGroups, id: \.key) { group in
                            SuggestionCard(proposals: group.items, historical: group.key != newestProposalGroup,
                                           resumeLabel: proposalResumeLabel(group.items.first?.text("resume_id") ?? ""),
                                           busy: proposalBusy, running: sending, progress: batchProgress?.key == group.key ? batchProgress : nil,
                                           locked: batchProgress != nil,
                                           apply: { await decide($0, confirm: true) }, reject: { await decide($0, confirm: false) },
                                           applyAll: { Task { await applyAll(group.key, group.items) } },
                                           continueEditing: { proposal in draft = "继续调整："; revisionProposalID = proposal.text("id") },
                                           preview: { proposal in
                                               openPreview(ChatPreviewTab(kind: .resume, id: proposal.text("resume_id"), label: proposal.text("resume_title").nilIfEmpty ?? "简历"))
                                           })
                        }
                        if sending {
                            VStack(alignment: .leading, spacing: 6) {
                                if !streaming.isEmpty { NativeMarkdownView(source: streaming).textSelection(.enabled) }
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(status ?? "正在思考…").font(V3.sans(12)).foregroundStyle(V3.fnt) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let pendingClarification { clarificationCard(pendingClarification) }
                        if let creditBlock, !sending { creditNotice(creditBlock) }
                        if let currentID, !sending { MemoryReceipt(sessionID: currentID, refresh: messages.count) }
                        if let error { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red) }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(maxWidth: 900, alignment: .leading).padding(.horizontal, 24).padding(.top, 48).padding(.bottom, 24).frame(maxWidth: .infinity)
                }
                .onChange(of: messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: streaming) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            composer.frame(maxWidth: 900).padding(.horizontal, 24).padding(.vertical, 8).frame(maxWidth: .infinity)
        }.frame(minWidth: 420)
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

    // MARK: Pieces

    /// Web `.assistant-files-toggle`：对话页右上角浮动的「N 个文件」，预览面板打开时隐藏（Web 对话页没有标题栏，重命名与删除在侧栏）。
    @ViewBuilder private var filesToggle: some View {
        let files = sessionFiles.count
        if files > 0 && !previewOpen {
            Button { openAllFiles() } label: {
                HStack(spacing: 6) { Image(systemName: "sidebar.right").font(.system(size: 12)); Text("\(files) 个文件") }
                    .font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub)
                    .padding(.leading, 9).padding(.trailing, 10).frame(height: 29)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("查看本会话的 \(files) 个文件").padding(16)
        }
    }

    private func bubble(_ message: JSONValue, index: Int) -> some View {
        let user = message.text("role") == "user"
        let attached = (message["contexts"]?.items ?? []).filter { !$0.text("label").isEmpty }
        return HStack(spacing: 0) {
            if user { Spacer(minLength: 0) }
            VStack(alignment: user ? .trailing : .leading, spacing: 0) {
                // Web `UserMessageContent`：正文里没 @ 到的简历引用排在气泡上方（24 高小标签、靠右），其余引用作为正文内的蓝色字
                let resumes = attached.filter { ["resume", "resume_version"].contains($0.text("type")) && !message.text("content").contains("@" + $0.text("label")) }
                if user && !resumes.isEmpty {
                    FlowLayout(spacing: 6, trailing: true) {
                        ForEach(resumes, id: \.self) { context in
                            let tab = ChatPreviewTab.forContext(context)
                            let gone = tab.map { unavailableFiles.contains($0.key) } ?? true
                            let active = tab.map { previewOpen && previewActive == $0.key } ?? false
                            Button { if let tab { openPreview(tab) } } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(active ? V3.blue : V3.sub)
                                    Text(context.text("type") == "user_profile" ? "个人画像" : context.text("label")).lineLimit(1).truncationMode(.tail)
                                    Text("简历").font(V3.sans(12)).foregroundStyle(V3.fnt)
                                }
                                .font(V3.sans(12, weight: .medium)).foregroundStyle(active ? V3.blue : V3.txt)
                                .padding(.horizontal, 7).frame(maxWidth: 260).frame(height: 24)
                                .background(active ? V3.blue.opacity(0.08) : .white, in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(active ? V3.blue : V3.cl))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(gone).accessibilityLabel("引用文件 \(context.text("label"))")
                        }
                    }.padding(.bottom, 8)
                }
                let inline = attached.filter { context in !resumes.contains(context) }
                if !inline.isEmpty && !user {
                    FlowLayout(spacing: 6) {
                        ForEach(inline, id: \.self) { context in
                            Text(context.text("label")).font(V3.sans(11.5)).foregroundStyle(V3.fnt).lineLimit(1)
                        }
                    }
                }
                let files = message["attachments"]?.items ?? []
                if !files.isEmpty { messageAttachments(files, trailing: user) }
                if user {
                    // `.assistant-message.is-user`：#F4F4F2 气泡，圆角 12、内边距 11/14、14px 行高 22，最宽 min(560, 82%)；上下内边距被覆盖为 9
                    Text(Self.userSegments(message.text("content"), inline)).font(V3.sans(14)).lineHeight(14, 22).foregroundStyle(V3.txt).textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            if let context = inline.first(where: { "drawoffer-context:" + $0.text("label").addingPercentEncoding(withAllowedCharacters: .alphanumerics)! == url.absoluteString }),
                               let tab = ChatPreviewTab.forContext(context), !unavailableFiles.contains(tab.key) { openPreview(tab) }
                            return .handled
                        })
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(V3.field, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    NativeMarkdownView(source: message.text("content").nilIfEmpty ?? (message.text("message_type") == "clarification" ? "需要你补充一些信息。" : ""), size: 16, line: 26).textSelection(.enabled)
                    if message.text("status") == "stopped" { Text("已停止生成").font(V3.sans(11)).foregroundStyle(V3.fnt) }
                    if message.text("status") == "failed" { Text("生成未完成").font(V3.sans(11)).foregroundStyle(V3.fnt) }
                    if let tab = generatedTab(message, index: index) {
                        HStack(spacing: 8) {
                            Button { openPreview(tab) } label: { Label("预览文档", systemImage: "sidebar.right") }.buttonStyle(V3ButtonStyle(kind: .ghost))
                            let saved = savedDocuments.contains(tab.content)
                            Button { savingDocument = message.text("content") } label: { Label(saved ? "已保存" : "保存到资料库", systemImage: "tray.and.arrow.down") }
                                .buttonStyle(V3ButtonStyle(kind: .ghost)).disabled(saved)
                        }
                    }
                }
            }
            // Web 覆盖规则：操作行绝对定位在正文下方 4px，不占高度，悬停才显示
            .overlay(alignment: user ? .bottomTrailing : .bottomLeading) {
                if !message.text("content").isEmpty {
                    messageActions(message, index: index).alignmentGuide(.bottom) { $0[.top] - 4 }
                        .opacity(hoveredMessage == index || copiedMessage == index ? 1 : 0)
                }
            }
            .frame(maxWidth: user ? 560 : .infinity, alignment: user ? .trailing : .leading)
            if !user { Spacer(minLength: 0) }
        }
        .contentShape(Rectangle()).accessibilityElement(children: .contain)
        .onHover { hoveredMessage = $0 ? index : (hoveredMessage == index ? nil : hoveredMessage) }
    }

    /// Web `MessageActions`：时间与复制按钮。
    private func messageActions(_ message: JSONValue, index: Int) -> some View {
        HStack(spacing: 6) {
            if let date = ResumeSummary.parseTimestamp(message.text("created_at")) {
                Text(Self.timeLabel(date)).font(V3.number(12, weight: .regular)).foregroundStyle(V3.fnt).frame(height: 18)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text("content"), forType: .string)
                copiedMessage = index
                Task { try? await Task.sleep(for: .seconds(2)); if copiedMessage == index { copiedMessage = nil } }
            } label: { Image(systemName: copiedMessage == index ? "checkmark" : "doc.on.doc").font(.system(size: 12)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(V3.fnt).help(copiedMessage == index ? "已复制" : "复制消息")
                .accessibilityLabel(copiedMessage == index ? "已复制消息" : "复制消息")
        }
    }

    /// Web `composerSegments`：正文里的 `@名称` 换成蓝色 500 字重的名称；正文没提到的引用排在最前，后接一个空格。
    static func userSegments(_ content: String, _ contexts: [JSONValue]) -> AttributedString {
        func token(_ context: JSONValue) -> AttributedString {
            var piece = AttributedString(context.text("type") == "user_profile" ? "个人画像" : context.text("label"))
            piece.foregroundColor = V3.link
            piece.font = V3.sans(14, weight: .medium)
            piece.link = URL(string: "drawoffer-context:" + context.text("label").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
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

    static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"  // Web `formatTime`：始终只显示时分
        return formatter.string(from: date)
    }

    private func compactionDivider(_ message: JSONValue) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(V3.line).frame(height: 1)
            Text("较早的对话已整理成摘要").font(V3.sans(11.5)).foregroundStyle(V3.fnt).fixedSize()
            Rectangle().fill(V3.line).frame(height: 1)
        }.help(message.text("content"))
    }

    /// Web `ChatAttachments`（已发送）：每个文件一张卡，边框、圆角 8、内边距 8/28/8/8，22 号文件夹或麦克风图标，名称 12/500，录音下注「录音」。
    private func messageAttachments(_ files: [JSONValue], trailing: Bool = false) -> some View {
        FlowLayout(spacing: 8, trailing: trailing) {
            ForEach(files, id: \.self) { file in
                let audio = file.text("kind") == "audio"
                HStack(spacing: 8) {
                    Image(systemName: audio ? "mic" : "folder").font(.system(size: 17)).frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.text("file_name")).font(V3.sans(12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        if audio { Text("录音").font(V3.sans(11)).foregroundStyle(V3.sub) }
                    }
                }
                .foregroundStyle(V3.txt)
                .padding(.leading, 8).padding(.trailing, 28).padding(.vertical, 8)
                .frame(minWidth: 120, maxWidth: 240, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
            }
        }.padding(.vertical, 8)
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
                if page > 0 { Button("上一题") { clarificationPage = page - 1 }.buttonStyle(V3ButtonStyle(kind: .ghost)) }
                Spacer()
                if page < questions.count - 1 {
                    Button("下一题") { clarificationPage = page + 1 }.buttonStyle(V3ButtonStyle(kind: .dark)).disabled(!answered(question))
                } else {
                    Button("提交回答") { Task { await answerClarification(message, questions: questions) } }
                        .buttonStyle(V3ButtonStyle(kind: .dark)).disabled(!complete || sending)
                }
            }
        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(V3.cl))
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
                .background(selected ? V3.field : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? V3.txt.opacity(0.4) : V3.cl)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 输入框里以 / 开头的快捷命令（Web `slashCommands.ts`），只列出当前对话能执行的。
    private var slashCommands: [(id: String, label: String, detail: String, symbol: String)] {
        let all: [(String, String, String, String)] = [
            ("compact", "整理较早对话", "把较早的对话整理成摘要，腾出上下文", "clock.arrow.circlepath"),
            ("context", "查看上下文用量", "看看离自动整理还有多远、用在了哪里", "gauge.with.dots.needle.33percent"),
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
        case "context": usageOpen = true
        case "ref": referencePicker = true
        case "upload": pickFiles()
        default: newConversation()
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !slashMatches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(slashMatches, id: \.id) { command in
                        Button { runSlash(command.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: command.symbol).frame(width: 16).foregroundStyle(V3.sub)
                                Text("/" + command.id).font(V3.number(12.5)).foregroundStyle(V3.fnt)
                                Text(command.label).font(V3.sans(13))
                                Text(command.detail).font(V3.sans(11.5)).foregroundStyle(V3.fnt).lineLimit(1)
                                Spacer()
                            }.padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
                        }.buttonStyle(MenuRowStyle())
                    }
                }.padding(4).background(.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.cl))
            }
            if !screenshots.isEmpty { screenshotStrip(screenshots, removable: true) }
            if !contexts.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(contexts, id: \.self) { item in
                        HStack(spacing: 4) {
                            Text(item.text("label")).font(V3.sans(12)).lineLimit(1)
                            Button { contexts.removeAll { $0 == item } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }.buttonStyle(.plain)
                                .accessibilityLabel("移除 \(item.text("label"))")
                        }.padding(.horizontal, 8).frame(height: 24).background(V3.blueSoft, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            // `.assistant-input`：最小 58 高、#d6d6d0 描边、圆角 18、内边距 12/12/12/18；32 的发送钮在输入框里，生成中换成停止
            HStack(alignment: .bottom, spacing: 12) {
                ChatInputField(text: $draft, placeholder: ready == false ? "AI 助手暂未开放" : "继续提问或说明调整要求…",
                               submit: { if let first = slashMatches.first { runSlash(first.id) } else if canSend { Task { await send(draft) } } },
                               escape: { if !slashMatches.isEmpty { slashDismissed = true } },
                               paste: { pasteImage() })
                    .frame(minHeight: 32, maxHeight: 132).frame(height: 32 + max(0, CGFloat(draft.split(separator: "\n", omittingEmptySubsequences: false).count - 1)) * 22)
                    .onChange(of: draft) { if !draft.hasPrefix("/") { slashDismissed = false } }
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
            }.padding(.leading, 18).padding([.trailing, .vertical], 12).frame(minHeight: 58)
                .background(.white, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: 0xD6D6D0)))
            // `.assistant-composer-foot`：距输入框 8、22 高；左「＋ 添加资料」12.5px，右侧上下文用量与模型，间距 16
            HStack(spacing: 10) {
                Button { addMenu.toggle() } label: {
                    HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 10, weight: .bold)); Text("添加资料") }
                        .font(V3.sans(12.5)).foregroundStyle(V3.sub).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(sending).accessibilityLabel("添加资料").task { await loadContexts() }
                    .popover(isPresented: $addMenu, arrowEdge: .top) {
                        VStack(spacing: 0) {
                            Button { addMenu = false; pickFiles() } label: {
                                HStack(spacing: 10) { Image(systemName: "plus").frame(width: 16); Text("上传文件"); Spacer(); Text("图片、文档和录音").font(V3.sans(11)).foregroundStyle(V3.sub) }
                                    .padding(10).contentShape(Rectangle())
                            }.buttonStyle(MenuRowStyle())
                            Button { addMenu = false; referencePicker = true } label: {
                                HStack(spacing: 10) { Image(systemName: "folder").frame(width: 16); Text("引用已有资料"); Spacer() }.padding(10).contentShape(Rectangle())
                            }.buttonStyle(MenuRowStyle())
                        }.font(V3.sans(14)).foregroundStyle(V3.txt).padding(6).frame(width: 260)
                    }
                if let notice { Text(notice).font(V3.sans(11.5)).foregroundStyle(V3.orange).lineLimit(2) }
                Spacer()
                HStack(spacing: 16) {
                    ContextUsageRing(usage: contextUsage, modelName: currentModelName, open: $usageOpen,
                                     compactDisabled: sending || currentID == nil, compact: { Task { await compact() } })
                    ModelPicker(models: models, selectedID: modelID, disabled: sending) { id in
                        if let model = models.first(where: { $0.text("id") == id }) { Task { await chooseModel(model) } }
                    }
                }
            }.frame(height: 22).padding(.leading, 12).padding(.trailing, 10).padding(.top, 8)
        }.frame(maxWidth: 900)
        .dropDestination(for: URL.self) { urls, _ in addFiles(urls); return !urls.isEmpty }
        .sheet(isPresented: $referencePicker) {
            ReferencePicker(groups: contextGroups, chosen: contexts, label: contextTypeLabel) { picked in
                for item in picked where !contexts.contains(item) { contexts.append(item) }
            }
        }
    }

    // MARK: Screenshots

    private func screenshotStrip(_ shots: [ChatScreenshot], removable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 6) {
                ForEach(shots) { shot in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if shot.kind == "image", let data = shot.data, let image = NSImage(data: data) {
                                Button { openPreview(shot.tab) } label: {
                                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 52, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(shot.status == .failed ? V3.red : V3.cl))
                                }.buttonStyle(.plain).accessibilityLabel("预览 \(shot.label)")
                            } else {
                                HStack(spacing: 6) {
                                    Image(systemName: shot.kind == "audio" ? "mic" : "folder").font(.system(size: 15)).foregroundStyle(V3.sub)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(shot.label).font(V3.sans(12)).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
                                        if shot.status == .uploading { Text("正在上传…").font(V3.sans(10.5)).foregroundStyle(V3.fnt) }
                                        else if shot.kind == "audio" { Text("录音").font(V3.sans(10.5)).foregroundStyle(V3.fnt) }
                                    }
                                }.padding(.horizontal, 10).frame(height: 52)
                                    .background(V3.field, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(shot.status == .failed ? V3.red : .clear))
                            }
                        }
                        .overlay { if shot.status == .uploading, shot.kind == "image" { ProgressView().controlSize(.small) } }
                        if removable {
                            Button { removeAttachment(shot) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(V3.fnt).background(Circle().fill(.white))
                            }.buttonStyle(.plain).offset(x: 5, y: -5).accessibilityLabel("移除附件 \(shot.label)")
                        }
                    }
                }
            }
            ForEach(shots.filter { $0.error != nil }) { shot in
                HStack(spacing: 6) {
                    Text("\(shot.label)：\(shot.error ?? "")").font(V3.sans(11.5)).foregroundStyle(V3.red)
                    Button("重试") { Task { await upload(shot.id) } }.buttonStyle(.link).font(V3.sans(11.5))
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

    /// 生成中也可插话（服务端开放 steering 时），消息会排进当前运行。
    private var canSend: Bool { (!sending || (steering && runID != nil)) && ready != false && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var currentModelName: String? { models.first { $0.text("id") == modelID }?.text("name").nilIfEmpty ?? modelName }

    /// Web 文档生成规则：完整回复中有一级 Markdown 标题时视为可保存的文档。
    static func documentTitle(_ content: String) -> String? {
        content.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func contextTypeLabel(_ type: String) -> String {
        ["user_profile": "求职资料", "resume": "简历", "resume_version": "简历版本", "dataset": "资料库", "job": "岗位", "application": "求职进程", "interview": "面试"][type] ?? type
    }

    // MARK: Actions

    private func open() async {
        currentID = sessionID; messages = []; proposals = []; streaming = ""; error = nil; title = "新对话"; answers = [:]
        previewTabs = []; previewActive = nil; previewOpen = false; unavailableFiles = []
        screenshots = []; notice = nil; contextUsage = nil; clarificationPage = 0; otherAnswers = [:]
        let api = self.api
        async let readiness = try? api.careerRequest(path: "/api/agent/readiness", method: "GET", query: [:], body: nil)
        async let model = try? api.careerRequest(path: "/api/agent/model", method: "GET", query: [:], body: nil)
        let (readyValue, modelValue) = await (readiness, model)
        if case .bool(let flag) = readyValue?["ready"] { ready = flag } else { ready = readyValue == nil ? nil : false }
        if case .bool(let flag) = readyValue?["steering"] { steering = flag }
        modelName = modelValue?["model"]?.text("name").nilIfEmpty
        if let list = try? await api.careerRequest(path: "/api/agent/models", method: "GET", query: [:], body: nil) {
            models = list["models"]?.items ?? []
            modelID = (sessionID == nil ? initialModelID : nil) ?? list["defaultModelId"]?.stringValue ?? modelValue?["model"]?.text("id").nilIfEmpty
        }
        if let sessionID {
            await reload(sessionID)
            if let active = try? await api.careerRequest(path: "/api/agent/sessions/\(sessionID)/active-run", method: "GET", query: [:], body: nil),
               let run = active["run"]?.text("run_id"), !run.isEmpty {
                await stream(path: "/api/agent/runs/\(run)/events", method: "GET", body: nil, sessionID: sessionID)
            }
        }
        if let initialMessage, !consumedInitial, !initialMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            consumedInitial = true
            await send(initialMessage)
        }
    }

    private func reload(_ id: String) async {
        do {
            let result = try await api.careerRequest(path: "/api/agent/sessions/\(id)", method: "GET", query: [:], body: nil)
            guard currentID == id else { return }
            messages = result["session"]?["messages"]?.items ?? []
            title = result["session"]?.text("title").nilIfEmpty ?? "新对话"
            contextUsage = result["session"]?["context_usage"]
            if let selected = result["session"]?["selected_model_id"]?.stringValue { modelID = selected }
            if let list = try? await api.careerRequest(path: "/api/agent/proposals", method: "GET", query: ["session_id": id], body: nil), currentID == id {
                proposals = list["proposals"]?.items ?? []
            }
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

    private func ensureSession() async throws -> String {
        if let currentID { return currentID }
        let result = try await api.careerRequest(path: "/api/agent/sessions", method: "POST", query: [:], body: modelID.map { .object(["modelId": .string($0)]) } ?? .object([:]))
        guard let id = result["session"]?.text("id").nilIfEmpty else { throw APIError.invalidResponse }
        currentID = id; title = result["session"]?.text("title").nilIfEmpty ?? "新对话"
        created(id)
        return id
    }

    private func send(_ text: String, replyTo: Int? = nil, clarificationAnswers: [JSONValue]? = nil) async {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if replyTo == nil, screenshots.contains(where: { $0.status != .ready }) {
            notice = screenshots.contains { $0.status == .uploading } ? "附件还在上传，请稍候。" : "有附件没有上传成功，请重试或移除。"
            return
        }
        if sending, steering, let runID, !content.isEmpty { await steer(content, runID: runID); return }
        guard !content.isEmpty, !sending else { return }
        sending = true; error = nil; streaming = ""; status = nil; creditBlock = nil
        let attached = contexts
        do {
            let id = try await ensureSession()
            var body: [String: JSONValue] = ["content": .string(content), "idempotency_key": .string(UUID().uuidString.lowercased())]
            if !attached.isEmpty {
                body["contexts"] = .array(attached.map { item in
                    var ref: [String: JSONValue] = ["type": .string(item.text("type")), "id": .string(item.text("id")), "presentation": .string("mention")]
                    if !item.text("version_id").isEmpty { ref["version_id"] = .string(item.text("version_id")) }
                    return .object(ref)
                })
            }
            let files = replyTo == nil ? screenshots : []
            if !files.isEmpty { body["attachment_ids"] = .array(files.compactMap(\.attachmentID).map(JSONValue.string)) }
            if let replyTo { body["reply_to_sequence_no"] = .number(Double(replyTo)) }
            if let revisionProposalID { body["revision_proposal_id"] = .string(revisionProposalID); self.revisionProposalID = nil }
            if let clarificationAnswers { body["clarification_answers"] = .array(clarificationAnswers) }
            draft = ""; contexts = []; answers = [:]
            if replyTo == nil { screenshots = [] }
            let sentFiles: [JSONValue] = files.map { .object(["file_name": .string($0.label), "kind": .string($0.kind)]) }
            messages.append(.object(["role": .string("user"), "content": .string(content), "contexts": .array(attached), "attachments": .array(sentFiles)]))
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

    private func stream(path: String, method: String, body: JSONValue?, sessionID id: String) async {
        sending = true
        defer { sending = false; runID = nil; status = nil }
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
    }

    private func handle(_ event: AgentEvent) {
        let data = event.data
        if runID == nil, !data.text("runId").isEmpty { runID = data.text("runId") }
        switch event.type {
        case "run.phase": status = data.text("label").nilIfEmpty ?? status
        case "assistant.activity.status": status = data.text("label").nilIfEmpty ?? status
        case "tool.started": status = "正在调用工具…"
        case "assistant.delta": streaming += data.text("delta")
        case "assistant.message.completed":
            var message: [String: JSONValue] = ["role": .string("assistant"), "content": .string(data.text("content")),
                                                "sequence_no": data["sequenceNo"] ?? .null]
            if let clarification = data["clarification"] { message["clarification"] = clarification }
            messages.append(.object(message)); streaming = ""
        case "clarification.requested":
            if let index = messages.lastIndex(where: { $0.text("role") == "assistant" }), case .object(var fields) = messages[index] {
                fields["clarification"] = data["clarification"]; messages[index] = .object(fields)
            }
        case "proposal.created": if let proposal = data["proposal"] { proposals.append(proposal) }
        case "context.usage", "context.compaction.completed":
            let window = data["contextWindow"] ?? contextUsage?["context_window"] ?? .null
            contextUsage = .object(["tokens": data["tokens"] ?? .null, "context_window": window, "breakdown": data["breakdown"] ?? contextUsage?["breakdown"] ?? .null])
        case "context.compaction.started": status = "正在整理较早对话…"
        case "user.message.rejected": error = AgentRequest.errorMessage(APIError.server(status: 409, code: data.text("error")))
        case "run.failed":
            let code = data.text("error")
            if ["CREDIT_INSUFFICIENT", "PAID_CREDIT_REQUIRED"].contains(code),
               let last = messages.last(where: { $0.text("role") == "user" }) {
                creditBlock = (code == "CREDIT_INSUFFICIENT" ? "exhausted" : "model", last.text("content"))
            } else { error = AgentRequest.errorMessage(APIError.server(status: 500, code: code)) }
        case "run.cancelled": status = nil; if !streaming.isEmpty { messages.append(.object(["role": .string("assistant"), "content": .string(streaming + "\n\n（已停止生成）")])); streaming = "" }
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

    private func creditNotice(_ block: (kind: String, content: String)) -> some View {
        let title = block.kind == "exhausted" ? "本月额度已用完，未能生成回复"
            : currentModelName.map { "\($0) 暂不可用于当前额度" } ?? "这项功能暂不可用于当前额度"
        let body = block.kind == "exhausted" ? "你的消息已保留，额度恢复后可以直接重新发送。" : "当前额度只能使用基础模型，可以改用基础模型重新发送。"
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(V3.sans(13.5, weight: .semibold))
            Text(body).font(V3.sans(12.5)).foregroundStyle(V3.sub)
            HStack(spacing: 8) {
                if block.kind == "model", let free = freeModel {
                    Button("改用 \(free.text("name")) 重新发送") {
                        Task { await chooseModel(free); creditBlock = nil; await send(block.content) }
                    }.buttonStyle(V3ButtonStyle(kind: .dark))
                }
                if block.kind == "exhausted" {
                    Button("我的额度") { router.jump(.section(.account)) }.buttonStyle(V3ButtonStyle(kind: .ghost))
                }
                Button("把消息放回输入框") { draft = block.content; creditBlock = nil }.buttonStyle(.link).font(V3.sans(12))
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(V3.orangeSoft, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }

    /// 与 Web `proposalResumeLabel` 相同：取对话里引用的那份简历的名字，否则“简历 #id”。
    private func proposalResumeLabel(_ resumeID: String) -> String {
        let referenced = (contexts + messages.flatMap { $0["contexts"]?.items ?? [] }).first { context in
            ["resume", "resume_version"].contains(context.text("type")) && (context.text("resume_id").nilIfEmpty ?? context.text("id")) == resumeID
        }
        return referenced?.text("label").nilIfEmpty ?? "简历 #\(resumeID)"
    }

    /// 同一轮提问产生的建议合并在一张卡里（Web `proposalGroup`）。
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

    private var newestProposalGroup: String {
        messages.last { $0.text("role") == "user" }.map { String($0["sequence_no"]?.integer ?? 0) } ?? "none"
    }

    private func applyAll(_ key: String, _ items: [JSONValue]) async {
        let pending = items.filter { $0.text("status") == "pending" }
        guard pending.count > 1, batchProgress == nil, proposalBusy == nil, !sending else { return }
        batchProgress = (key, 0, pending.count)
        defer { batchProgress = nil }
        for (index, proposal) in pending.enumerated() {
            guard await decide(proposal, confirm: true) else { break }
            batchProgress = (key, index + 1, pending.count)
        }
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
            self.error = AgentRequest.errorMessage(error)
            if let current = currentID { await reload(current) }
            return false
        }
    }

    /// 插话：`POST /api/agent/runs/{id}/steer`，回执的应用结果随当前流的 `user.message.applied/rejected` 返回。
    private func steer(_ content: String, runID: String) async {
        let key = UUID().uuidString.lowercased()
        do {
            _ = try await api.careerRequest(path: "/api/agent/runs/\(runID)/steer", method: "POST", query: [:],
                                            body: .object(["content": .string(content), "idempotency_key": .string(key)]))
            draft = ""
            messages.append(.object(["role": .string("user"), "content": .string(content)]))
            status = "已插入，将在当前步骤后处理"
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            self.error = AgentRequest.errorMessage(error)
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

    /// 整理较早对话（Web `compactConversation`）：流式执行，结束后刷新会话与用量。
    private func compact() async {
        guard let currentID, !sending else { return }
        status = "正在整理较早对话…"; error = nil
        await stream(path: "/api/agent/sessions/\(currentID)/compact", method: "POST",
                     body: .object(["idempotency_key": .string(UUID().uuidString.lowercased())]), sessionID: currentID)
    }

    private func newConversation() {
        currentID = nil; messages = []; proposals = []; streaming = ""; error = nil; title = "新对话"
        screenshots = []; contexts = []; contextUsage = nil
    }

    private func cancel() async {
        guard let runID else { return }
        _ = try? await api.careerRequest(path: "/api/agent/runs/\(runID)/cancel", method: "POST", query: [:], body: nil)
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
                let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
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
                field.textColor = .tertiaryLabelColor
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

/// 上下文用量圆环与浮层（Web `ContextUsage.tsx`）：离自动整理还有多远、各类占比、整理较早对话。
struct ContextUsageRing: View {
    let usage: JSONValue?
    let modelName: String?
    @Binding var open: Bool
    let compactDisabled: Bool
    let compact: () -> Void

    static let reserve = 16_384.0
    static let maxWindow = 200_000.0
    static let categories: [(String, String, Color)] = [
        ("conversation", "对话记录", V3.blue), ("materials", "引用资料", V3.green), ("memory", "求职记忆", V3.purple),
        ("attachments", "附件", V3.orange), ("system", "系统指令与工具", Color(hex: 0xA8A49A)),
    ]

    static func format(_ value: Double) -> String {
        if value < 1000 { return String(Int(value)) }
        if value < 1_000_000 { return value < 10_000 ? String(format: "%.1fk", value / 1000).replacingOccurrences(of: ".0k", with: "k") : "\(Int((value / 1000).rounded()))k" }
        return String(format: "%.1fM", value / 1_000_000)
    }

    var body: some View {
        if let window = usage?["context_window"]?.numberValue {
            let limit = min(window, Self.maxWindow)
            let compactAt = max(1, limit - Self.reserve)
            let tokens = usage?["tokens"]?.numberValue
            let percent = tokens.map { min(100, ($0 / compactAt * 1000).rounded() / 10) }
            let label = percent.map { "距自动压缩已用 \(Int($0.rounded()))%" } ?? "上下文已压缩，下次回复后更新用量"
            Button { open.toggle() } label: {
                ZStack {
                    Circle().stroke(V3.cl, lineWidth: 2)
                    if let percent, percent > 0 {
                        Circle().trim(from: 0, to: percent / 100).stroke(percent >= 80 ? V3.orange : V3.txt, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                    }
                }.padding(1).frame(width: 16, height: 16).contentShape(Rectangle())
            }.buttonStyle(.plain).help(label).accessibilityLabel(label)
                .popover(isPresented: $open, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let tokens, let percent {
                            Text(tokens >= compactAt ? "已用 \(Self.format(tokens))，即将自动整理" : "已用 \(Self.format(tokens))，离自动整理还有 \(Self.format(compactAt - tokens))")
                                .font(V3.sans(13, weight: .medium))
                            let breakdown = usage?["breakdown"]
                            GeometryReader { geometry in
                                HStack(spacing: 0) {
                                    if case .object = breakdown {
                                        ForEach(Self.categories, id: \.0) { key, _, color in
                                            let value = breakdown?[key]?.numberValue ?? 0
                                            if value > 0 { color.frame(width: geometry.size.width * min(1, value / compactAt)) }
                                        }
                                    } else { V3.blue.frame(width: geometry.size.width * min(1, tokens / compactAt)) }
                                    Spacer(minLength: 0)
                                }.background(V3.field).clipShape(Capsule())
                            }.frame(height: 6)
                            HStack { Text("\(Int(percent.rounded()))%"); Spacer(); Text(Self.format(compactAt)) }.font(V3.number(10.5)).foregroundStyle(V3.fnt)
                            if case .object = breakdown {
                                ForEach(Self.categories, id: \.0) { key, name, color in
                                    if let value = breakdown?[key]?.numberValue, value > 0 {
                                        HStack(spacing: 6) {
                                            Circle().fill(color).frame(width: 7, height: 7)
                                            Text(name).font(V3.sans(12))
                                            Spacer()
                                            Text(Self.format(value)).font(V3.number(11.5)).foregroundStyle(V3.sub)
                                        }
                                    }
                                }
                            }
                        } else {
                            Text("较早的对话已整理成摘要").font(V3.sans(13, weight: .medium))
                            Text("下次回复后重新计算用量；引用的资料、记忆和附件仍可随时读取。").font(V3.sans(12)).foregroundStyle(V3.sub).fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()
                        HStack {
                            Text([modelName, "上限 \(Self.format(limit))"].compactMap { $0 }.joined(separator: " · ")).font(V3.number(11)).foregroundStyle(V3.fnt)
                            Spacer()
                            if tokens != nil {
                                Button("整理较早对话") { open = false; compact() }.buttonStyle(.link).font(V3.sans(12)).disabled(compactDisabled)
                            }
                        }
                    }.padding(14).frame(width: 300)
                }
        }
    }
}

/// 引用已有资料（Web 添加资料 → 引用已有资料）：搜索、按类型筛选、多选后“添加 N 项”。
struct ReferencePicker: View {
    @Environment(\.dismiss) private var dismiss
    let groups: [JSONValue]
    let chosen: [JSONValue]
    let label: (String) -> String
    let add: ([JSONValue]) -> Void
    @State private var query = ""
    @State private var type = ""
    @State private var picked: [JSONValue] = []

    var body: some View {
        let items = groups.filter { type.isEmpty || $0.text("type") == type }.flatMap { $0["items"]?.items ?? [] }
            .filter { query.isEmpty || $0.text("label").localizedCaseInsensitiveContains(query) || $0.text("description").localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 12) {
            Text("引用已有资料").font(V3.serif(20))
            TextField("搜索简历、资料或岗位", text: $query).textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                tab("全部", "")
                ForEach(groups.map { $0.text("type") }, id: \.self) { tab(label($0), $0) }
            }
            List {
                if items.isEmpty { Text(groups.isEmpty ? "正在读取可引用的资料…" : "没有匹配的资料").foregroundStyle(V3.fnt) }
                ForEach(items, id: \.self) { item in
                    let already = chosen.contains(item)
                    let selected = picked.contains(item)
                    Button {
                        if selected { picked.removeAll { $0 == item } } else { picked.append(item) }
                    } label: {
                        HStack {
                            Image(systemName: already || selected ? "checkmark.square.fill" : "square").foregroundStyle(already ? V3.fnt : V3.txt)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.text("label")).font(V3.sans(13))
                                if !item.text("description").isEmpty { Text(item.text("description")).font(V3.sans(11.5)).foregroundStyle(V3.fnt).lineLimit(1) }
                            }
                            Spacer()
                            Text(label(item.text("type"))).font(V3.sans(11)).foregroundStyle(V3.fnt)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(already)
                }
            }.frame(height: 300)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(picked.isEmpty ? "添加" : "添加 \(picked.count) 项") { add(picked); dismiss() }
                    .buttonStyle(V3ButtonStyle(kind: .dark)).disabled(picked.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 480)
    }

    private func tab(_ title: String, _ value: String) -> some View {
        Button(title) { type = value }.buttonStyle(.plain).font(V3.sans(12)).padding(.horizontal, 10).frame(height: 26)
            .foregroundStyle(type == value ? .white : V3.sub).background(type == value ? V3.txt : V3.field, in: Capsule())
    }
}


/// 多项修改建议卡（Web `SuggestionCard.tsx`）：同一轮提问的建议合在一起，标签切换、‹ › 翻看，
/// 采用此项后自动跳到下一项待确认；“全部采用”逐项处理并显示进度；全部处理完收起成一行摘要，可展开回看。
struct SuggestionCard: View {
    let proposals: [JSONValue]
    let historical: Bool
    let resumeLabel: String
    let busy: String?
    let running: Bool
    let progress: (key: String, completed: Int, total: Int)?
    let locked: Bool
    let apply: (JSONValue) async -> Bool
    let reject: (JSONValue) async -> Bool
    let applyAll: () -> Void
    let continueEditing: (JSONValue) -> Void
    let preview: (JSONValue) -> Void
    @State private var selectedID: String?
    @State private var expanded: Bool?

    private var pending: [JSONValue] { proposals.filter { $0.text("status") == "pending" } }

    var body: some View {
        let allDone = pending.isEmpty
        let selected = proposals.first { $0.text("id") == selectedID } ?? pending.first ?? proposals.first
        let index = proposals.firstIndex { $0.text("id") == selected?.text("id") } ?? 0
        let applied = proposals.filter { $0.text("status") == "applied" }.count
        let rejected = proposals.filter { $0.text("status") == "rejected" }.count
        let progressText = applied + rejected == 0 ? "\(pending.count) 项待确认"
            : [applied > 0 ? "已采用 \(applied)" : "", rejected > 0 ? "已忽略 \(rejected)" : "", !pending.isEmpty ? "待确认 \(pending.count)" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        let isExpanded = expanded ?? !allDone
        if let selected {
            if !isExpanded && allDone && progress == nil {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).frame(width: 20, height: 20).background(V3.green, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(historical ? "历史修改建议 · " : "")已处理 \(proposals.count) 处修改建议").font(V3.sans(13, weight: .medium))
                        Text(progressText).font(V3.sans(11.5)).foregroundStyle(V3.fnt)
                    }
                    Spacer()
                    Button("查看详情") { expanded = true }.buttonStyle(.link).font(V3.sans(12))
                }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(V3.cl))
            } else {
                card(selected, index: index, progressText: progressText)
            }
        }
    }

    private func short(_ proposal: JSONValue, _ index: Int) -> String {
        let text = proposal.text("summary").trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return "第 \(index + 1) 项" }
        return text.count > 14 ? String(text.prefix(14)) + "…" : text
    }

    private func status(_ proposal: JSONValue) -> String? {
        switch proposal.text("status") {
        case "pending": return nil
        case "applied": return "已应用"
        case "rejected": return "已忽略"
        default: return proposal.text("superseded_by").isEmpty ? "无法应用" : "已被替代"
        }
    }

    private func changes(_ proposal: JSONValue) -> [(String, String)] {
        let preview = proposal["preview"]?["changes"]?.items ?? []
        if !preview.isEmpty { return preview.map { ($0.text("before"), $0.text("after")) } }
        let operations = proposal["operations"]?.items ?? []
        if !operations.isEmpty {
            return operations.map { operation in
                (operation["target"]?.text("selected_text").nilIfEmpty ?? "当前定位内容",
                 operation.text("op") == "delete_target" ? "删除该条目" : operation.text("new_text"))
            }
        }
        return [("当前简历内容", "候选简历内容")]
    }

    private func advance(from selected: JSONValue, index: Int) {
        let rest = proposals.filter { $0.text("status") == "pending" && $0.text("id") != selected.text("id") }
        let next = rest.first { (proposals.firstIndex(of: $0) ?? 0) > index } ?? rest.first
        if let next { selectedID = next.text("id") } else { expanded = false }
    }

    private func card(_ selected: JSONValue, index: Int, progressText: String) -> some View {
        let multi = proposals.count > 1
        let actionable = selected.text("status") == "pending"
        let disabled = busy != nil || locked
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(historical ? "历史修改建议 · " : "")\(multi ? "建议修改 · \(proposals.count) 处" : "建议修改 · \(short(selected, 0))")")
                    .font(V3.sans(13.5, weight: .semibold))
                if multi || !actionable { Text(multi ? progressText : status(selected) ?? "").font(V3.sans(11.5)).foregroundStyle(V3.fnt) }
                Spacer()
                Text("目标简历「\(resumeLabel)」").font(V3.sans(11.5)).foregroundStyle(V3.fnt).lineLimit(1)
            }
            if multi {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(proposals.enumerated()), id: \.offset) { tabIndex, proposal in
                            let active = proposal.text("id") == selected.text("id")
                            let tabStatus = proposal.text("status")
                            Button { selectedID = proposal.text("id") } label: {
                                HStack(spacing: 5) {
                                    if tabStatus == "applied" { Text("✓").foregroundStyle(V3.green) }
                                    else if tabStatus != "pending" { Text("–").foregroundStyle(V3.fnt) }
                                    else { Circle().fill(V3.orange).frame(width: 6, height: 6) }
                                    Text(short(proposal, tabIndex))
                                    if let label = status(proposal) { Text(label).font(V3.sans(10.5)).foregroundStyle(V3.fnt) }
                                }.font(V3.sans(12)).padding(.horizontal, 10).frame(height: 28)
                                    .background(active ? V3.field : .clear, in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(active ? V3.txt.opacity(0.35) : V3.cl))
                            }.buttonStyle(.plain).disabled(progress != nil).help(proposal.text("summary"))
                                .accessibilityAddTraits(active ? .isSelected : [])
                        }
                    }
                }
            }
            ForEach(Array(changes(selected).enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("原文").font(V3.sans(11)).foregroundStyle(V3.fnt).frame(width: 28, alignment: .leading)
                        Text(change.0).font(V3.sans(12.5)).strikethrough().foregroundStyle(V3.fnt).textSelection(.enabled)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Text("建议").font(V3.sans(11)).foregroundStyle(V3.green).frame(width: 28, alignment: .leading)
                        Text(change.1).font(V3.sans(12.5)).foregroundStyle(V3.txt).textSelection(.enabled)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(V3.stage, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                Button { if index > 0 { selectedID = proposals[index - 1].text("id") } } label: { Text("‹") }
                    .buttonStyle(.plain).disabled(index <= 0 || progress != nil).accessibilityLabel("上一项修改")
                Text("\(index + 1) / \(proposals.count)").font(V3.number(11.5)).foregroundStyle(V3.sub)
                Button { if index < proposals.count - 1 { selectedID = proposals[index + 1].text("id") } } label: { Text("›") }
                    .buttonStyle(.plain).disabled(index >= proposals.count - 1 || progress != nil).accessibilityLabel("下一项修改")
                if !selected.text("resume_id").isEmpty {
                    Button("在简历中预览") { preview(selected) }.buttonStyle(.link).font(V3.sans(12)).padding(.leading, 6)
                }
                Spacer()
                if actionable {
                    Button("继续调整") { continueEditing(selected) }.buttonStyle(V3ButtonStyle(kind: .ghost)).disabled(disabled || running)
                    Button("忽略") { Task { if await reject(selected) { advance(from: selected, index: index) } } }
                        .buttonStyle(V3ButtonStyle(kind: .ghost)).disabled(disabled)
                    Button(busy == selected.text("id") && progress == nil ? "处理中…" : pending.count > 1 ? "采用此项" : "采用") {
                        Task { if await apply(selected) { advance(from: selected, index: index) } }
                    }.buttonStyle(V3ButtonStyle(kind: pending.count > 1 ? .ghost : .dark)).disabled(disabled || running)
                    if pending.count > 1 || progress != nil {
                        Button(progress.map { "正在采用（\($0.completed)/\($0.total)）" } ?? "全部采用（\(pending.count)）", action: applyAll)
                            .buttonStyle(V3ButtonStyle(kind: .dark)).disabled(disabled || running)
                    }
                } else {
                    Text(selected.text("status") == "applied" ? "✓ 已写入简历" : status(selected) ?? "")
                        .font(V3.sans(12)).foregroundStyle(selected.text("status") == "applied" ? V3.green : V3.fnt)
                }
            }
        }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(V3.cl))
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
