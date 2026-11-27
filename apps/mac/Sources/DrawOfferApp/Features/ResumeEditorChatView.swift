import DrawOfferCore
import DrawOfferRender
import SwiftUI

/// 小绘停在段旁改一段（Web `workbench/EditorChat.tsx`，Figma 04 页 C2–C6；96117ada3 选方向后一步出稿）：
/// 纸右边一列，左上是停过来的小绘；每段各自一段对话（`GET /api/resumes/{id}/editor-chat?entry_id=`），
/// 新对话给几个方向（深化 / 诊断 / 精修），点了一步出稿：改好的句子写在纸上（浅蓝底 = 还没换上），白板只问换不换。
/// 改写中纸上这一段高亮、小绘外圈转、可以“停下”；一分钟没回音当没改成；改写中你自己改了这一段，这次改写作废。
/// 出错、积分不够只在白板说一句原因（再试一次 / 去充值 / 先不改了），不弹窗。
/// 注：editor-chat、experience/applied 在 c42dbeae9 还没有 `client_access(desktop=True)`，桌面端会收到 403，按“对话没有打开”显示。
struct ResumeEditorChatView: View {
    struct Unit: Equatable {
        let focus: SectionFocus.Unit
        let label: String
        let nonExperience: Bool
        var id: String { focus.id }
    }

    /// 外部带进来的一句（小绘白板“直接说”）：按 seq 只发一次。
    struct Request: Equatable {
        let entryID: String
        let prompt: String
        let seq: Int
    }

    private struct Live: Equatable { var said: String?; var text: String; var status: String }
    private struct Sent { let content: String; let shown: String?; let action: ResumeEditorChat.Action? }
    private enum Ended { case stopped, timeout }

    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let resumeID: String
    let units: [Unit]
    @Binding var entryID: String
    /// 纸面当前正文（读这一段现在的样子、核对换上）。
    let document: JSONValue
    var request: Request?
    let write: (JSONValue) -> Void
    /// 纸上高亮这一段 / 预览改好的几条（不改正文）。
    let decorate: ([String], [PaperLineChange]) -> Void
    /// 发话、换上前先保存（Web `saveCurrentResume`）；返回是否已存好。
    let saveFirst: () async -> Bool
    let notice: (String) -> Void
    let close: () -> Void

    @State private var chatSession: String?
    @State private var messages: [JSONValue] = []
    @State private var live: Live?
    @State private var failure: (text: String, credit: Bool)?
    @State private var failures = 0
    @State private var lastSend: Sent?
    @State private var loadFailed = false
    @State private var draft = ""
    @State private var typing = false
    @State private var busy = false
    /// 换上的回执：卡片 id → 换上的几条。
    @State private var receipts: [String: [ResumeEditorChat.ChangeLine]] = [:]
    @State private var dismissed: Set<String> = []
    @State private var runTask: Task<Void, Never>?
    @State private var runID: String?
    @State private var ended: Ended?
    @State private var lastEvent = Date()
    @State private var staleRun = false
    @State private var handledSeq = 0

    private var picking: Bool { entryID.isEmpty && !units.isEmpty }
    private var currentUnit: Unit? { units.first { $0.id == entryID } }
    private var visible: [JSONValue] { ResumeEditorChat.visible(messages) }
    private var lastAssistant: JSONValue? { visible.last { $0.text("role") == "assistant" } }
    private var pending: (card: ResumeEditorChat.ChangeCard, lines: [ResumeEditorChat.ChangeLine])? {
        ResumeEditorChat.latestPending(visible, dismissed: dismissed) { ResumeCheck.lineText(document, lineID: $0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // C2：小绘停在这一列左上，改写中外圈转（Web `.wbx-dock` / `.wbx-dock-ring`）
            ResumeTalkAvatar().scaleEffect(40 / 28).frame(width: 40, height: 40)
                .overlay { if live != nil { ResumeOrbRing() } }
            VStack(alignment: .leading, spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) { thread }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).padding(.bottom, 12)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .scrollIndicators(.never)
                    .onChange(of: visible.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: live) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                if !picking && !loadFailed { inputRow }
                if !picking && !visible.isEmpty && !loadFailed {
                    // 输入框下一行灰字，聊乱了可以从头来
                    Button("重新开始") { Task { await restart() } }.buttonStyle(.plain)
                        .font(V3.sans(12.5)).foregroundStyle(ResumeTalk.note)
                        .disabled(chatSession == nil || live != nil || busy).padding(.bottom, 24)
                }
            }
        }
        .task(id: entryID) { await open() }
        .onChange(of: request) { _, _ in Task { await takeRequest() } }
        .onChange(of: paperIntent, initial: true) { _, intent in decorate(intent.highlight, intent.preview) }
        .onExitCommand(perform: close)
        .onDisappear { runTask?.cancel(); decorate([], []) }
    }

    /// 纸上：正在改的这一段高亮，改好还没换上的几条直接显示在纸上（浅蓝底，橙色 = 待核实）。
    private var paperIntent: PaperIntent {
        if picking { return PaperIntent() }
        if let pending {
            return PaperIntent(preview: pending.lines.map { PaperLineChange(lineID: $0.lineID, before: $0.before, text: $0.text, risky: $0.risky) })
        }
        return PaperIntent(highlight: currentUnit?.focus.lines.map(\.id) ?? [])
    }

    private struct PaperIntent: Equatable {
        var highlight: [String] = []
        var preview: [PaperLineChange] = []
    }

    // MARK: Thread

    @ViewBuilder private var thread: some View {
        if loadFailed {
            ChatSay(text: ResumeEditorChat.loadFailed)
        } else if picking {
            ChatSay(text: ResumeEditorChat.pickSay, note: ResumeEditorChat.pickNote) {
                options(units.enumerated().map { index, unit in
                    Option(label: unit.label, hint: unit.focus.lines.isEmpty ? nil : "共 \(unit.focus.lines.count) 条内容", first: unit.id == entryID) {
                        entryID = unit.id
                    }
                })
            }
        } else {
            if chatSession == nil && live == nil {
                ChatSay(text: "正在打开之前的对话", thinking: true)
            }
            if chatSession != nil, visible.isEmpty, live == nil {
                ChatSay(text: ResumeEditorChat.welcome(unitLabel: currentUnit?.label), note: ResumeEditorChat.welcomeNote) {
                    options(ResumeEditorChat.directions(nonExperience: currentUnit?.nonExperience ?? false).enumerated().map { index, item in
                        Option(label: item.label, hint: item.hint, first: index == 0) { Task { await send(item.label, action: item.action) } }
                    })
                }
            }
            ForEach(Array(visible.enumerated()), id: \.offset) { index, message in
                if message.text("role") == "user" {
                    ResumeTalkUser(text: message.text("content").replacingOccurrences(of: #"（已换上[^）]*）$"#, with: "", options: .regularExpression))
                } else {
                    assistantMessage(message, index: index)
                }
            }
            if let said = live?.said { ResumeTalkUser(text: said) }
            if let live {
                // C3：白板只留一行“正在改”，可以停下，纸面不动
                ChatSay(text: live.text.isEmpty ? (live.status.isEmpty ? "正在想" : live.status) : AgentReplyText.clean(live.text, streaming: true),
                                    thinking: live.text.isEmpty) {
                    Button("停下") { endRun(.stopped) }.buttonStyle(.plain).font(V3.sans(12.5)).foregroundStyle(ResumeOrbNudge.blue)
                }
            }
            if staleRun && live == nil {
                ChatSay(text: ResumeEditorChat.staleSay) {
                    options([
                        Option(label: "按新的内容再改", first: true) { staleRun = false; if let lastSend { Task { await send(lastSend.content, shown: lastSend.shown, action: lastSend.action) } } },
                        Option(label: "先不改了") { staleRun = false },
                    ])
                }
            }
            if let failure {
                ChatSay(text: failure.text) {
                    options((failure.credit
                        ? [Option(label: "去充值", first: true) { router?.jump(.plans) }]
                        : lastSend.map { last in [Option(label: "再试一次", first: true) { Task { await send(last.content, shown: last.shown, action: last.action) } }] } ?? [])
                        + [Option(label: "先不改了") { self.failure = nil }])
                }
            }
        }
    }

    @ViewBuilder private func assistantMessage(_ message: JSONValue, index: Int) -> some View {
        let clarification = message["clarification"]
        let text = AgentReplyText.clean(message.text("content")).trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = text.isEmpty ? (clarification?["questions"]?.items ?? []).map { $0.text("question") }.joined(separator: "\n") : text
        ChatSay(text: shown) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ResumeEditorChat.changeCards(message), id: \.id) { card in cardView(card) }
                if let clarification { clarificationOptions(message, clarification, index: index) }
            }
        }
    }

    /// 改法卡片：一条“立即换上 / 放弃”，几条逐条“换上”+“全部换上 / 放弃”；换上后“已换上 · 撤销”。
    @ViewBuilder private func cardView(_ card: ResumeEditorChat.ChangeCard) -> some View {
        let lines = ResumeEditorChat.pendingLines(card, dismissed: dismissed) { ResumeCheck.lineText(document, lineID: $0) }
        let locked = busy || live != nil
        VStack(alignment: .leading, spacing: 6) {
            if lines.count == 1 {
                ResumeTalkChips(items: [("立即换上", { Task { await apply(card, lines) } }), ("放弃", { dismissed.insert(card.id) })], disabled: locked)
            } else if lines.count > 1 {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 8) {
                        Text("\(index + 1). \(ResumeEditorChat.snippet(line.text))").font(V3.sans(13)).foregroundStyle(V3.txt).lineLimit(1).help(line.text)
                        Spacer(minLength: 4)
                        ResumeTalkChip(title: "换上", disabled: locked) { Task { await apply(card, [line]) } }
                    }
                }
                ResumeTalkChips(items: [("全部换上", { Task { await apply(card, lines) } }), ("放弃", { dismissed.insert(card.id) })], disabled: locked)
            }
            if let receipt = receipts[card.id] {
                HStack(spacing: 6) {
                    Text("已换上").font(V3.sans(12.5)).foregroundStyle(ResumeTalk.note)
                    Button("撤销") { undo(card.id, receipt) }.buttonStyle(.plain).font(V3.sans(12.5)).foregroundStyle(ResumeOrbNudge.blue).disabled(locked)
                }
            }
        }
    }

    @ViewBuilder private func clarificationOptions(_ message: JSONValue, _ clarification: JSONValue, index: Int) -> some View {
        let next = visible.dropFirst(index + 1).first { $0.text("role") == "user" }
        let answered = next?.text("content").trimmingCharacters(in: .whitespacesAndNewlines)
        let open = AgentBranch.sequence(message) == AgentBranch.sequence(lastAssistant ?? .null) && live == nil && answered == nil
        ForEach(Array((clarification["questions"]?.items ?? []).enumerated()), id: \.offset) { _, question in
            options((question["options"]?.items ?? []).enumerated().map { order, option in
                let label = option.text("label")
                return Option(label: label, hint: option.text("description").isEmpty ? nil : option.text("description"),
                              first: open && order == 0, chosen: answered == label, faded: answered != nil && answered != label, disabled: !open || busy) {
                    Task { await send(label, shown: label, replyTo: AgentBranch.sequence(message), answers: [(question.text("id"), option.text("id"))]) }
                }
            })
        }
    }

    private struct Option {
        let label: String
        var hint: String? = nil
        var first = false
        var chosen = false
        var faded = false
        var disabled = false
        let action: () -> Void
    }

    /// Web `.wbx-option`：编号圆圈 + 文字（+ 灰色一行说明），第一项浅蓝底、蓝圈。
    private func options(_ items: [Option]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                ResumeEditorChatOption(number: index + 1, label: item.label, hint: item.hint, first: item.first, chosen: item.chosen,
                                       faded: item.faded, action: item.action)
                    .disabled(item.disabled || busy)
            }
        }.padding(.top, 10)
    }

    @ViewBuilder private var inputRow: some View {
        let asking = lastAssistant?["clarification"] != nil && live == nil
        if typing || !draft.isEmpty {
            ResumeTalkInput(placeholder: asking ? "或者告诉我哪里不对" : "想改哪里，直接说", text: $draft, disabled: chatSession == nil || live != nil || busy) {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                Task { await send(text) }
            }.padding(.top, 8).padding(.bottom, 8)
        } else {
            Button(asking ? "或者告诉我哪里不对…" : ResumeOrb.inputPlaceholder) { typing = true }
                .buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(ResumeTalk.hint)
                .disabled(chatSession == nil || live != nil || busy).padding(.top, 4).padding(.bottom, 12)
        }
    }

    // MARK: Actions

    /// 打开或换段：只读这一段的历史对话，不自动调模型（避免浏览时误扣费）；有进行中的一轮就接着听。
    private func open() async {
        runTask?.cancel(); runTask = nil
        chatSession = nil; messages = []; receipts = [:]; dismissed = []; failure = nil; loadFailed = false; live = nil
        guard !picking else { return }
        do {
            let path = ResumeEditorChat.chatPath(resumeID: resumeID, entryID: entryID)
            let chat = try await session.api.careerRequest(path: path.path, method: "GET", query: path.query, body: nil)
            guard !Task.isCancelled else { return }
            let id = chat.text("session_id")
            guard !id.isEmpty else { throw APIError.invalidResponse }
            try await loadMessages(id)
            chatSession = id
            if let active = try? await session.api.careerRequest(path: "/api/agent/sessions/\(id)/active-run", method: "GET", query: [:], body: nil),
               let run = active["run"]?.text("run_id"), !run.isEmpty {
                live = Live(said: nil, text: "", status: "")
                try? await session.api.streamAgent(path: "/api/agent/runs/\(run)/events", method: "GET", body: nil) { event in handle(event) }
                try? await loadMessages(id)
                live = nil
            }
            await takeRequest()
        } catch {
            guard !Task.isCancelled else { return }
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            loadFailed = true
        }
    }

    private func loadMessages(_ id: String) async throws {
        let result = try await session.api.careerRequest(path: "/api/agent/sessions/\(id)", method: "GET", query: [:], body: nil)
        messages = result["session"]?["messages"]?.items ?? []
    }

    /// 小绘白板“直接说”带进来的一句：等这一段的对话打开后发出去。
    private func takeRequest() async {
        guard let request, request.seq != handledSeq, chatSession != nil, live == nil else { return }
        guard request.entryID.isEmpty || request.entryID == entryID else { return }
        handledSeq = request.seq
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { await send(prompt) }
    }

    private func handle(_ event: AgentEvent) {
        lastEvent = Date()
        let data = event.data
        if runID == nil, !data.text("runId").isEmpty { runID = data.text("runId") }
        switch event.type {
        case "assistant.delta": live?.text += data.text("delta")
        case "assistant.delta.reset": live?.text = ""
        case "assistant.activity.status": if data.text("status") == "running" { live?.status = data.text("label") }
        case "run.failed": setFailure(APIError.server(status: 500, code: data.text("error").isEmpty ? "failed" : data.text("error")))
        case "assistant.message.completed": failures = 0
        default: break
        }
    }

    private func setFailure(_ error: Error) {
        if !ResumeEditorChat.failure(error, failures: 0).credit { failures += 1 }
        failure = ResumeEditorChat.failure(error, failures: failures)
    }

    /// 这一段现在纸上的正文（C3 比对用）。
    private func unitTextNow() -> String? {
        guard let unit = currentUnit else { return nil }
        return unit.focus.lines.map { (ResumeCheck.lineText(document, lineID: $0.id) ?? $0.text).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    /// 发一句：纸面有没保存的修改先保存（服务端才看得到最新正文）；一分钟没有任何回音当没改成。
    private func send(_ content: String, shown: String? = nil, action: ResumeEditorChat.Action? = nil,
                      replyTo: Int? = nil, answers: [(question: String, option: String)] = []) async {
        guard let id = chatSession, runTask == nil else { return }
        failure = nil; staleRun = false; ended = nil; runID = nil
        lastSend = Sent(content: content, shown: shown, action: action)
        live = Live(said: shown ?? content, text: "", status: "")
        let lastSeq = messages.map(AgentBranch.sequence).max() ?? 0
        if !(await saveFirst()) { notice("当前改动还没保存，AI 看到的可能是上次保存的内容") }
        let before = unitTextNow()
        let body = ResumeEditorChat.messageBody(content: content, idempotencyKey: UUID().uuidString, entryID: entryID,
                                                lineIDs: currentUnit?.focus.lines.map(\.id) ?? [], action: action,
                                                draftCardID: pending?.card.id, replyTo: replyTo, answers: answers)
        lastEvent = Date()
        let stream = Task {
            do {
                try await session.api.streamAgent(path: "/api/agent/sessions/\(id)/messages", method: "POST", body: body) { event in handle(event) }
            } catch {
                guard !Task.isCancelled else { return }
                if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
                setFailure(error)
            }
        }
        runTask = stream
        // H：一分钟没有任何回音就停下
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Date().timeIntervalSince(lastEvent) > 60 { endRun(.timeout); return }
            }
        }
        await stream.value
        watchdog.cancel()
        runTask = nil
        if ended == .timeout { setFailure(APIError.invalidResponse) }
        try? await loadMessages(id)
        // 停下、超时：这一轮写到一半的改法都不上纸；C3：这一轮里你自己改了这一段，这一轮的改法作废
        let changed = ended == nil && before != nil && unitTextNow() != before
        if ended != nil || changed {
            let fresh = messages.filter { AgentBranch.sequence($0) > lastSeq }.flatMap { ResumeEditorChat.changeCards($0).map(\.id) }
            dismissed.formUnion(fresh)
            if changed && !fresh.isEmpty { staleRun = true }
        }
        live = nil
    }

    /// 停下这一轮（C3 的“停下”、H 的超时）：断开流，并让服务端取消这次运行。
    private func endRun(_ reason: Ended) {
        guard let runTask else { return }
        ended = reason
        runTask.cancel()
        if let runID { Task { _ = try? await session.api.careerRequest(path: "/api/agent/runs/\(runID)/cancel", method: "POST", query: [:], body: nil) } }
    }

    /// 把这几条直接换到纸上、保存，再同步经历复习稿（Web `applyCard`）。
    private func apply(_ card: ResumeEditorChat.ChangeCard, _ lines: [ResumeEditorChat.ChangeLine]) async {
        guard !busy, live == nil else { return }
        busy = true
        defer { busy = false }
        var next = document
        var done: [ResumeEditorChat.ChangeLine] = []
        for line in lines {
            if case .success(let value) = ResumeCheck.replaceLine(next, lineID: line.lineID, before: line.before, with: line.text) { next = value; done.append(line) }
        }
        guard !done.isEmpty else { notice("这几条刚被改过，没有换上。重新说一次就好"); return }
        write(next)
        receipts[card.id] = done
        guard await saveFirst() else { notice("换上了，但简历还没保存，复习稿等保存后再同步"); return }
        _ = try? await session.api.careerRequest(path: "/api/resumes/\(resumeID)/experience/\(card.entryID)/applied", method: "POST", query: [:],
                                                 body: ResumeEditorChat.appliedBody(card, lines: done))
    }

    /// 把刚换上的几条还原回原句（Web `undoCard`）。
    private func undo(_ cardID: String, _ lines: [ResumeEditorChat.ChangeLine]) {
        guard !busy, live == nil else { return }
        var next = document
        var reverted = 0
        for line in lines {
            if case .success(let value) = ResumeCheck.replaceLine(next, lineID: line.lineID, before: line.text, with: line.before) { next = value; reverted += 1 }
        }
        guard reverted > 0 else { notice("换上后又改过，没法撤销了"); return }
        write(next)
        receipts[cardID] = nil
        Task { _ = await saveFirst() }
    }

    /// 这一段从头聊：清掉对话和纸上没换上的改法，已换上的不动。
    private func restart() async {
        guard live == nil, !busy else { return }
        do {
            let path = ResumeEditorChat.chatPath(resumeID: resumeID, entryID: entryID, restart: true)
            let chat = try await session.api.careerRequest(path: path.path, method: "POST", query: path.query, body: nil)
            messages = []; receipts = [:]; dismissed = []; failure = nil; failures = 0
            chatSession = chat.text("session_id").isEmpty ? chatSession : chat.text("session_id")
        } catch {
            setFailure(error)
        }
    }
}

/// 白板上的一句（Web `.wbx-chat` 里的 `TalkSay`）：没有卡片、没有底色，正文 15.5/26 墨黑，补充 12.5 灰；头像只在这一列左上停一朵。
private struct ChatSay<Extra: View>: View {
    let text: String
    var note: String? = nil
    var thinking = false
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(text).font(V3.sans(15.5)).foregroundStyle(V3.txt).lineSpacing(10)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if thinking { ProgressView().controlSize(.mini) }
            }
            if let note, !note.isEmpty {
                Text(note).font(V3.sans(12.5)).foregroundStyle(ResumeTalk.note).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            extra()
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ChatSay where Extra == EmptyView {
    init(text: String, note: String? = nil, thinking: Bool = false) {
        self.init(text: text, note: note, thinking: thinking) { EmptyView() }
    }
}

/// Web `.wbx-chat .wbx-option`：编号是 12.5 灰字（第一项与选中项 #3366d9），第一项文字蓝色，悬停 4% 黑底；选中后编号变 ✓、其余变淡。
private struct ResumeEditorChatOption: View {
    let number: Int
    let label: String
    let hint: String?
    let first: Bool
    var chosen = false
    var faded = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Text(chosen ? "✓" : "\(number)").font(V3.number(12.5, weight: .medium))
                    .foregroundStyle(first || chosen ? ResumeOrbNudge.blue : Color(hex: 0xA9A7A0)).frame(width: 12, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(V3.sans(14)).foregroundStyle(first && enabled ? ResumeOrbNudge.blue : V3.txt).fixedSize(horizontal: false, vertical: true)
                    if let hint { Text(hint).font(V3.sans(12.5)).foregroundStyle(ResumeTalk.note).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(hover && enabled ? Color.black.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).opacity(faded ? 0.4 : 1).padding(.leading, -6)
        .onHover { hover = $0 }
        .accessibilityLabel(label)
    }
}
