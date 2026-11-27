import DrawOfferCore
import DrawOfferRender
import SwiftUI

/// 改这一条（Figma 03 页分区 12.1–12.6，Web `workbench/LineChat.tsx`）：纸右边一列对话。
/// 光标停在哪一条，纸右边就有“改这一条 ⌘K”；点了以后职绘先问想怎么改（精简 / STAR 法则 / 润色一下，或直接说）。
/// 回复是一段话；改好的句子不在对话里重复，直接显示在纸上那一条（浅蓝底 = 还没换上，橙色 = 要核实），换上后才写进正文。
/// 选中几条时逐条改好一起放在纸上，可以都换上，也可以只换一条。
/// 一条走 `section-review:rewrite`，几条走 `section-review:rewrite-section`（mode=chat，带最近几轮对话）。
struct ResumeLineChat: View {
    struct Target: Equatable {
        let unit: SectionFocus.Unit
        /// 要改的几条（同一段里）；一条时就是光标所在的那一条。
        var lineIDs: [String]
        /// 只选了一行里的几个字时的字符范围（第一轮只改这几个字）。
        var selection: Range<Int>? = nil
        /// 选区工具栏里已经写好的一句要求：打开时直接发送。
        var instruction: String = ""
        var lineID: String { lineIDs.first ?? "" }
    }

    /// 改好的一条：`before` 是发请求时纸上的原句，换上前核对。
    struct Change: Equatable {
        let lineID: String
        let before: String
        let text: String
        let risky: [String]
    }

    private enum Phase {
        case ask
        case loading(said: String)
        case reply(said: String, reply: String, note: String, changes: [Change])
        case applied(before: JSONValue)
        case failed(said: String, instruction: String, message: String, credit: Bool)
    }

    /// 纸面上要显示什么：正在改的几条高亮，改好的直接显示在纸上。
    private struct PaperIntent: Equatable {
        var highlight: [String] = []
        var preview: [PaperLineChange] = []
    }

    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let resumeID: String
    @Binding var target: Target
    /// 纸面当前正文：拆上下文、核对写回都以它为准。
    let document: JSONValue
    /// 这一段属于哪类模块（技能不给 STAR）。
    let kind: ResumeCheck.Kind
    let label: (JSONValue) -> String
    let write: (JSONValue) -> Void
    /// 纸上临时高亮 / 预览（不改正文）；两项都空即清除。
    let decorate: ([String], [PaperLineChange]) -> Void
    let close: () -> Void

    @State private var phase: Phase = .ask
    @State private var draft = ""
    @State private var turns: [JSONValue] = []
    /// 上一版改好的句子：接着说时在它上面改（只改一条时）。
    @State private var lastText: String?
    @State private var task: Task<Void, Never>?
    @State private var notice: String?
    /// 连着没改成的次数：第二次换一句“现在有点忙”（a667ae1ba）。
    @State private var failures = 0

    private static let polish = "润色一下：先看这句话想表达什么、哪里写得单薄，在原句基础上补充让它更饱满的内容（具体做法、起的作用、带来的结果），站在 HR 筛简历的角度更有表现力、更容易通过筛选，可以写得有力；不改变原意，补出来的说法标出来请我核实。"
    private static let star = "按 STAR 法则重写这一句：一句带过背景和要解决的问题，重点写我采取的行动和做法，最后落到具体的结果。目标是让简历通过筛选：结果要写成具体数字（比例、数量、时长、覆盖范围等），原句没有就直接补上有说服力的数字，可以写得有力，补出来的说法标出来请我核实，不留空位。"
    private static let concise = "精简：去掉表述不准确、不到位的词和重复、铺垫、空泛的修饰，保留做了什么、用的技术和结果，不新增原句没有的内容，不影响整句的意思；“协助”“参与”“负责”这类说明我在其中角色的词不算修饰，要保留。"
    private static let shorter = "再短一点：在刚才这版的基础上再精简，保留做法和结果，不新增内容。"

    private var multi: Bool { target.lineIDs.count > 1 }
    /// 最后一条在这一段里的位置（接着改下一条从它后面接）。
    private var lineIndex: Int? { target.unit.lines.firstIndex { $0.id == target.lineIDs.last } }
    private var nextLine: SectionFocus.Line? {
        guard let lineIndex, lineIndex + 1 < target.unit.lines.count else { return nil }
        return target.unit.lines[lineIndex + 1]
    }

    private var paperIntent: PaperIntent {
        switch phase {
        case .reply(_, _, _, let changes) where !changes.isEmpty:
            return PaperIntent(preview: changes.map { PaperLineChange(lineID: $0.lineID, before: $0.before, text: $0.text, risky: $0.risky) })
        case .applied: return PaperIntent()
        default: return PaperIntent(highlight: target.lineIDs)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12).padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .task(id: target.lineIDs) {
            if !target.instruction.isEmpty {
                let instruction = target.instruction
                target.instruction = ""
                send(instruction, shown: instruction)
            }
        }
        .onChange(of: paperIntent, initial: true) { _, intent in decorate(intent.highlight, intent.preview) }
        .onExitCommand(perform: dismiss)
        .onDisappear { task?.cancel(); decorate([], []) }
    }

    @ViewBuilder private var content: some View {
        let question = multi ? "这几条想怎么改？" : "想怎么改这一条？"
        switch phase {
        case .ask:
            // 12.2：先问一句，三个常用说法，或者直接说
            ResumeTalkAssistant(text: lineLabel.isEmpty ? question : "想怎么改\(lineLabel)？", note: "选一个常用说法，或者直接说你的想法。")
            ResumeTalkChips(items: quickAsks)
            input("或者直接说想怎么改")
        case .loading(let said):
            ResumeTalkAssistant(text: question, faded: true)
            ResumeTalkUser(text: said)
            ResumeTalkAssistant(text: multi ? "正在改这几条" : "正在改这一条", thinking: true)
            ResumeTalkChips(items: [("停止", { task?.cancel(); phase = .ask })])
        case .reply(let said, let reply, let note, let changes):
            // 12.3 / 12.5 / 12.6：回复是一段话；改好的句子已经在纸上，这里只说改了什么、哪里要核实
            ResumeTalkAssistant(text: question, faded: true)
            ResumeTalkUser(text: said, faded: true)
            ResumeTalkAssistant(text: reply.isEmpty ? (changes.isEmpty ? "这一条不用改。" : "改好了，看左边。") : reply,
                                note: noteText(note, risky: changes.flatMap(\.risky)))
            if changes.count > 1 {
                ResumeTalkChips(items: multiChips(changes))
            } else if let change = changes.first {
                ResumeTalkChips(items: [("换上", { apply([change]) }), ("再短一点", { send(Self.shorter, shown: "再短一点") }), ("不用了", dismiss)])
            } else if kind != .skills {
                ResumeTalkChips(items: [("按 STAR 改一版", { send(Self.star, shown: "按 STAR 改一版") })])
            }
            noticeLine
            input(changes.isEmpty ? "或者接着问" : "或者接着说想怎么改")
        case .applied(let before):
            // 12.4：换上之后，问要不要接着改
            ResumeTalkUser(text: "换上")
            ResumeTalkAssistant(text: "换上了，随时可以撤销。",
                                note: nextLine == nil ? nil : "这一段还有 \(target.unit.lines.count - (lineIndex ?? 0) - 1) 条，要接着改吗？")
            ResumeTalkChips(items: (nextLine.map { line in [("接着改下一条", { next(line) })] } ?? [])
                            + [("撤销", { write(before); phase = .ask; notice = nil }), ("先这样", close)])
            input("或者直接说想怎么改")
        case .failed(let said, let instruction, let message, let credit):
            // 分区 C · G / H：不弹窗，白板说一句原因 + 能做的动作；纸面不动
            ResumeTalkUser(text: said, faded: true)
            ResumeTalkAssistant(text: message)
            ResumeTalkChips(items: [credit ? ("去充值", { router?.jump(.plans) }) : ("再试一次", { send(instruction, shown: said) }),
                                    ("先不改了", { phase = .ask })])
            input("或者换个说法")
        }
    }

    @ViewBuilder private var noticeLine: some View {
        if let notice { Text(notice).font(V3.sans(12.5)).foregroundStyle(V3.red).padding(.leading, ResumeTalk.indent) }
    }

    private func input(_ placeholder: String) -> some View {
        ResumeTalkInput(placeholder: placeholder, text: $draft) {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            draft = ""
            send(text, shown: text)
        }.padding(.top, 8)
    }

    /// 12.6：都换上，或只换其中一条。
    private func multiChips(_ changes: [Change]) -> [(String, () -> Void)] {
        var items: [(String, () -> Void)] = [(changes.count == 2 ? "两条都换上" : "\(changes.count) 条都换上", { apply(changes) })]
        for change in changes { items.append(("只换\(position(of: change.lineID))", { apply([change]) })) }
        return items
    }

    /// “第 n 条”：这一条在这一段里的位置。
    private func position(of lineID: String) -> String {
        guard let index = target.unit.lines.firstIndex(where: { $0.id == lineID }) else { return "这一条" }
        return "第 \(index + 1) 条"
    }

    /// 选中第几条（逐条改时用）；只有一条时不说。
    private var lineLabel: String {
        guard !multi, target.unit.lines.count > 1 else { return "" }
        return position(of: target.lineID)
    }

    private var quickAsks: [(String, () -> Void)] {
        var items: [(String, () -> Void)] = [("精简", { send(Self.concise, shown: "精简") })]
        if kind != .skills { items.append(("STAR 法则", { send(Self.star, shown: "STAR 法则") })) }
        items.append(("润色一下", { send(Self.polish, shown: "润色一下") }))
        return items
    }

    private func noteText(_ note: String, risky: [String]) -> String? {
        if !note.isEmpty { return note }
        let terms = Array(Set(risky.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
        return terms.isEmpty ? nil : "\(terms.joined(separator: "、")) 是补出来的，换上前确认一下。"
    }

    private static func clip(_ text: String) -> String { text.count > 300 ? String(text.prefix(299)) + "…" : text }

    // MARK: Actions

    private func send(_ instruction: String, shown: String) {
        let instruction = String(instruction.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard !instruction.isEmpty else { return }
        let picked = target.unit.lines.filter { target.lineIDs.contains($0.id) }
        guard !picked.isEmpty else { notice = "这一条已经不在简历里了"; return }
        task?.cancel(); notice = nil
        phase = .loading(said: shown)
        let units = ResumeCheck.units(document, label: label)
        // 以纸面现在的文字为准（换上过的行已经是新句子）
        let current = { (item: SectionFocus.Line) in ResumeCheck.lineText(document, lineID: item.id) ?? item.text }
        let befores = Dictionary(picked.map { ($0.id, current($0)) }, uniquingKeysWith: { first, _ in first })
        let context = ResumeCheck.context(units, excluding: target.unit.id)
        let recent = JSONValue.array(Array(turns.suffix(12)))
        let lineIDs = target.lineIDs
        let request: (path: String, body: JSONValue)
        if picked.count > 1 {
            // 12.6：选中的几条一起改，逐条给出改法
            let lines = picked.prefix(SectionFocus.maxLines).map { JSONValue.object(["id": .string($0.id), "text": .string(String(current($0).prefix(SectionFocus.lineChars)))]) }
            request = ("section-review:rewrite-section", .object([
                "section": sectionBody(Array(lines)),
                "context": context,
                "reference": .object(["kind": .string("general")]),
                "instruction": .string(instruction),
                "turns": recent,
                "mode": .string("chat"),
            ]))
        } else {
            let line = picked[0]
            var lines = target.unit.lines.prefix(SectionFocus.maxLines).map { ($0.id, String(current($0).prefix(SectionFocus.lineChars))) }
            // 整段不超过 4000 字：放不下时只带这一行
            if lines.reduce(0, { $0 + $1.1.count }) > 4_000 { lines = [(line.id, String(current(line).prefix(SectionFocus.lineChars)))] }
            var body: [String: JSONValue] = [
                "section": sectionBody(lines.map { .object(["id": .string($0.0), "text": .string($0.1)]) }),
                "context": context,
                "reference": .object(["kind": .string("general")]),
                "line_id": .string(line.id),
                "instruction": .string(instruction),
                "answers": .array([]),
                "turns": recent,
                "mode": .string("chat"),
            ]
            if let lastText { body["current_text"] = .string(String(lastText.prefix(SectionFocus.lineChars))) }
            else if let range = target.selection { body["selection"] = .object(["start": .number(Double(range.lowerBound)), "end": .number(Double(range.upperBound))]) }
            request = ("section-review:rewrite", .object(body))
        }
        // H：等了一分钟还没回来，就当没改成
        let api = session.api
        task = Task {
            do {
                let response = try await withThrowingTaskGroup(of: JSONValue?.self) { group in
                    group.addTask { try await api.careerRequest(path: "/api/resumes/\(resumeID)/\(request.path)", method: "POST", query: [:], body: request.body) }
                    group.addTask { try await Task.sleep(for: .seconds(60)); return nil }
                    defer { group.cancelAll() }
                    // 先回来的是计时：当没改成
                    guard let first = try await group.next(), let result = first else { throw APIError.invalidResponse }
                    return result
                }
                guard !Task.isCancelled, lineIDs == target.lineIDs else { return }
                let reply = response.text("reply"), note = response.text("note")
                let changes: [Change]
                if picked.count > 1 {
                    changes = (response["changes"]?.items ?? []).compactMap { item in
                        let id = item.text("line_id"), text = item["variant"]?.text("text") ?? ""
                        guard let before = befores[id], !text.isEmpty else { return nil }
                        return Change(lineID: id, before: before, text: text, risky: (item["variant"]?["risky_terms"]?.items ?? []).compactMap(\.stringValue))
                    }
                } else {
                    let variant = response["variants"]?.items.first
                    let text = variant?.text("text") ?? ""
                    changes = text.isEmpty ? [] : [Change(lineID: picked[0].id, before: befores[picked[0].id] ?? picked[0].text, text: text,
                                                          risky: (variant?["risky_terms"]?.items ?? []).compactMap(\.stringValue))]
                }
                if changes.count == 1 { lastText = changes[0].text }
                turns = Array((turns + [
                    JSONValue.object(["role": .string("user"), "text": .string(Self.clip(instruction))]),
                    JSONValue.object(["role": .string("ai"), "text": .string(Self.clip(([reply] + changes.map(\.text)).filter { !$0.isEmpty }.joined(separator: "\n")))]),
                ]).filter { !$0.text("text").isEmpty }.suffix(12))
                failures = 0
                phase = .reply(said: shown, reply: reply, note: note, changes: changes)
            } catch {
                guard !Task.isCancelled else { return }
                if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
                let credit = ResumeEditorChat.lineFailure(error, failures: 0).credit
                failures = credit ? 0 : failures + 1
                let failure = ResumeEditorChat.lineFailure(error, failures: failures)
                phase = .failed(said: shown, instruction: instruction, message: failure.text, credit: failure.credit)
            }
        }
    }

    private func sectionBody(_ lines: [JSONValue]) -> JSONValue {
        .object([
            "entry_id": .string(target.unit.id),
            "heading": .string(String(target.unit.heading.prefix(200))),
            "kind": .string(kind.rawValue),
            "lines": .array(lines),
        ])
    }

    /// 换上：每一条都核对纸上还是 AI 看到的原句，被改过的那条不动；一条都没换上时提示。
    private func apply(_ changes: [Change]) {
        var next = document
        var applied = 0
        var missing = false
        for change in changes {
            switch ResumeCheck.replaceLine(next, lineID: change.lineID, before: change.before, with: change.text) {
            case .success(let value): next = value; applied += 1
            case .failure(let error): if error == .missing { missing = true }
            }
        }
        guard applied > 0 else {
            notice = missing && changes.count == 1 ? "这一条已经不在简历里了" : "这一条刚被改过，没有换上。重新说一次就好"
            return
        }
        let snapshot = document
        write(next)
        phase = .applied(before: snapshot)
    }

    private func next(_ line: SectionFocus.Line) {
        target.lineIDs = [line.id]
        target.selection = nil
        turns = []; lastText = nil; notice = nil
        phase = .ask
    }

    private func dismiss() {
        task?.cancel()
        close()
    }
}
