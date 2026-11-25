import DrawOfferCore
import SwiftUI

/// 检查简历（Figma 03 页分区 12.7–12.11「检查简历：对话版」，Web `workbench/ResumeCheck.tsx`）：纸面上沿右边「检查简历」打开，
/// 摆在纸的右边、不加卡片，和修改对话同一种写法。职绘读完整份先说一句结论，再一处一处带着改：
/// 能直接改的放出改好的一句（补出来的说法标橙），缺事实的一次只问一件事，可以删的删掉或并进另一条，整段换这一段的标题。
/// 收起后结果保留，上沿入口显示还剩几处；下次打开接着看，点「再检查一遍」才重读。
struct ResumeCheckPanel: View {
    @Environment(SessionStore.self) private var session
    let resumeID: String
    /// 打开时的正文：拆段、核对写回都以它为准，换上后由 `write` 交给编辑器。
    let document: JSONValue
    let label: (JSONValue) -> String
    /// 纸面实际页数（智能一页时为 1），随请求发给服务端判断篇幅。
    let pageCount: Int
    @Binding var state: ResumeCheckState
    let write: (JSONValue) -> Void
    let close: () -> Void

    @State private var answer = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var task: Task<Void, Never>?
    /// 用户上一句（点的快捷回答或打的字），显示成右侧灰底小气泡。
    @State private var said: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12).padding(.bottom, 40)
        }
        .scrollIndicators(.never)
        .task { if state.phase == .idle { read() } }
        .onChange(of: document) { _, next in settle(next) }
        .onDisappear { if state.phase == .reading { task?.cancel(); state = ResumeCheckState() } }
    }

    // MARK: Screens

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .idle, .reading: reading
        case .failed(let credit): failed(credit)
        case .list: list
        case .item(let index): if state.findings.indices.contains(index) { item(state.findings[index], index: index) } else { list }
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 17) {
            ResumeTalkAssistant(text: "正在读这份简历", note: "一次读完，十几秒。", thinking: true)
            ResumeTalkChips(items: [("停止", { task?.cancel(); state = ResumeCheckState(); close() })])
        }
    }

    private func failed(_ credit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            ResumeTalkAssistant(text: credit ? "积分不够了，这次没读完。" : "这次没读完。",
                                note: credit ? "简历没有改动。在左下角账户里充值后点重试。" : "没连上或出错了，简历没有改动。")
            ResumeTalkChips(items: [("重试", { read() }), ("先收起", { state = ResumeCheckState(); close() })])
        }
    }

    /// 12.7 读完先说结论；12.11 都看过了交回正常编辑。
    private var list: some View {
        let open = state.findings.filter { $0.status == .open }.count
        let firstOpen = state.findings.firstIndex { $0.status == .open }
        let handled = state.findings.count - open
        let text: String
        let note: String?
        if state.findings.isEmpty {
            text = state.units.isEmpty ? "先写几条经历再来检查。" : "读完了，没发现要改的地方。"
            note = state.summary.isEmpty ? nil : state.summary
        } else if open == 0 {
            let applied = state.findings.filter { $0.status == .applied }.count
            text = "\(state.findings.count) 处都看完了" + (applied == state.findings.count ? "，全部换上了。" : "。")
            note = "改动都能撤销。想再看一遍，点纸面上沿的“检查简历”。"
        } else {
            text = handled > 0 ? "还有 \(open) 处值得改。" : "读完了。有 \(open) 处值得改。"
            let joined = [state.basis.isEmpty ? "" : "按\(state.basis)的眼光看的：", state.summary].joined()
            note = joined.isEmpty ? nil : joined
        }
        return VStack(alignment: .leading, spacing: 17) {
            if let said { ResumeTalkUser(text: said, faded: true) }
            ResumeTalkAssistant(text: text, note: note) {
                if !state.findings.isEmpty && open > 0 {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(state.findings.enumerated()), id: \.element.id) { position, finding in row(finding, position: position) }
                    }.padding(.top, 12)
                }
            }
            if let firstOpen {
                ResumeTalkChips(items: [("从第 \(firstOpen + 1) 处开始", { go(firstOpen, said: "从第 \(firstOpen + 1) 处开始") }),
                                        ("先不改，我自己看", close)])
            } else {
                ResumeTalkChips(items: [("好了", close), ("再检查一遍", { read() })])
            }
        }
    }

    /// 结论下面的几处：编号 + 一句话 + 位置；处理过的划掉。点一行直接看那一处。
    private func row(_ finding: ResumeCheck.Finding, position: Int) -> some View {
        let done = finding.status != .open
        return Button { go(position, said: "看第 \(position + 1) 处") } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(position + 1)").font(V3.number(12, weight: .medium)).foregroundStyle(ResumeTalk.note).frame(width: 14, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.label).font(V3.sans(13)).foregroundStyle(done ? V3.fnt2 : V3.txt).strikethrough(done).lineLimit(1)
                    Text(finding.where_).font(V3.sans(11.5)).foregroundStyle(ResumeTalk.note).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if done { Text(finding.status == .applied ? "已换上" : "不改").font(V3.sans(11.5)).foregroundStyle(ResumeTalk.note) }
            }.padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(done)
    }

    /// 12.8 改写 / 12.9 补全 / 12.10 整段：职绘说第几处、为什么，改好的一句放出来；快捷回答 + 一行输入。
    @ViewBuilder private func item(_ finding: ResumeCheck.Finding, index: Int) -> some View {
        let lead = "第 \(index + 1) 处：\(finding.title)" + (finding.detail.isEmpty ? "" : (finding.title.hasSuffix("。") ? "" : "。") + finding.detail)
        if let said { ResumeTalkUser(text: said, faded: busy) }
        if finding.fix == "delete" || finding.fix == "merge" {
            ResumeTalkAssistant(text: lead)
            ResumeTalkChips(items: removeChips(finding), disabled: busy)
            noticeLine
        } else {
            ResumeTalkAssistant(text: lead, note: itemNote(finding), thinking: busy) {
                // 12.8：改好的一句直接显示在纸上那一行（编辑器按当前这处下发预览），对话里不再贴一遍；
                // 整段换标题时纸上没有对应的行，标题建议仍写在这里
                if let suggestion = finding.suggestion, finding.fix == "entry" {
                    if !finding.caption.isEmpty {
                        Text(finding.caption).font(V3.sans(12)).foregroundStyle(ResumeTalk.note).padding(.top, 10)
                    }
                    ResumeTalkProposal(text: suggestion, risky: finding.risky)
                }
            }
            if finding.suggestion != nil {
                ResumeTalkChips(items: [("换上，看下一处", { apply(finding) }), ("这处不用改", { mark(.skipped, said: "这处不用改") })], disabled: busy)
            } else {
                ResumeTalkChips(items: [("跳过这处", { mark(.skipped, said: "跳过这处") })], disabled: busy)
            }
            noticeLine
            ResumeTalkInput(placeholder: placeholder(finding), text: $answer, disabled: busy) { send(finding) }.padding(.top, 8)
        }
    }

    // MARK: Pieces

    private func removeChips(_ finding: ResumeCheck.Finding) -> [(String, () -> Void)] {
        var chips: [(String, () -> Void)] = [("删掉这一条", { remove(finding, merge: false) })]
        if finding.fix == "merge", finding.mergeInto != nil, finding.suggestion != nil {
            chips.append((mergeLabel(finding), { remove(finding, merge: true) }))
        }
        chips.append(("留着，不用改", { mark(.skipped, said: "留着，不用改") }))
        return chips
    }

    private func itemNote(_ finding: ResumeCheck.Finding) -> String? {
        if busy { return finding.fix == "entry" ? "正在重看这一段…" : "正在重写这一句…" }
        if !finding.risky.isEmpty { return "橙色 \(finding.risky.count) 处是按这类工作的常见水平补的，换上前改成你的真实情况，面试会被追问。" }
        if finding.fix == "entry", !finding.ask.isEmpty { return finding.ask }
        if finding.suggestion == nil { return finding.example.isEmpty ? "写大白话就行，我来整理。" : "比如：\(finding.example)" }
        return nil
    }

    private func placeholder(_ finding: ResumeCheck.Finding) -> String {
        if finding.suggestion == nil || finding.fix == "entry" { return "或者直接打字回答" }
        return finding.risky.isEmpty ? "或者说说哪里不对，我重写" : "或者说说真实情况，我重写"
    }

    @ViewBuilder private var noticeLine: some View {
        if let notice {
            Text(notice).font(V3.sans(12.5)).foregroundStyle(V3.red).padding(.leading, ResumeTalk.indent)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func mergeLabel(_ finding: ResumeCheck.Finding) -> String {
        guard let unit = state.units.first(where: { $0.id == finding.entryID }),
              let at = unit.lines.firstIndex(where: { $0.id == finding.lineID }), at > 0 else { return "并进那一条" }
        return unit.lines[at - 1].id == finding.mergeInto ? "并进上一条" : "并进那一条"
    }

    // MARK: Actions

    private func read() {
        task?.cancel()
        let units = ResumeCheck.units(document, label: label)
        state = ResumeCheckState(phase: .reading, units: units)
        answer = ""; notice = nil; said = nil
        guard !units.isEmpty else {
            state = ResumeCheckState(phase: .list, units: [], summary: "先写几条经历再来检查。")
            return
        }
        task = Task {
            do {
                let response = try await session.api.careerRequest(path: "/api/resumes/\(resumeID)/review:check", method: "POST", query: [:],
                                                                   body: ResumeCheck.checkBody(units, pageCount: pageCount))
                guard !Task.isCancelled else { return }
                let result = ResumeCheck.result(response, units: units)
                state = ResumeCheckState(phase: .list, units: units, summary: result.summary, basis: result.basis, findings: result.findings)
            } catch {
                guard !Task.isCancelled else { return }
                if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
                state.phase = .failed(credit: ResumeCheck.errorMessage(error).credit)
            }
        }
    }

    private func go(_ index: Int, said: String? = nil) { answer = ""; notice = nil; self.said = said; state.phase = .item(index) }

    /// 结算一处，并按纸面现状把被顺带改掉的处（合并改了另一条、自己在纸上改了）标成已换上，然后去下一处。
    private func mark(_ status: ResumeCheck.Finding.Status, document next: JSONValue? = nil, said: String? = nil) {
        guard case .item(let index) = state.phase else { return }
        self.said = said
        state.findings[index].status = status
        settle(next ?? document)
        answer = ""; notice = nil
        let following = state.findings.indices.first { $0 > index && state.findings[$0].status == .open }
            ?? state.findings.indices.first { state.findings[$0].status == .open }
        state.phase = following.map { ResumeCheckState.Phase.item($0) } ?? .list
    }

    /// 纸面上这一行的文字变了就算处理过（Web：改过的那一行圆圈自动消失）。
    private func settle(_ next: JSONValue) {
        for index in state.findings.indices where state.findings[index].status == .open {
            guard let lineID = state.findings[index].lineID else { continue }
            let text = ResumeCheck.lineText(next, lineID: lineID)
            if text.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) != state.findings[index].before.trimmingCharacters(in: .whitespacesAndNewlines) {
                state.findings[index].status = .applied
            }
        }
    }

    private func failedWrite(_ error: ResumeCheck.WriteError) {
        notice = error == .conflict ? "这一处刚被改过，没换上。" : "纸面上找不到这一处了。"
    }

    private func apply(_ finding: ResumeCheck.Finding) {
        guard let suggestion = finding.suggestion else { return }
        let result: Result<JSONValue, ResumeCheck.WriteError>
        if finding.fix == "entry" {
            guard let field = state.units.first(where: { $0.id == finding.entryID })?.headingField else { failedWrite(.missing); return }
            result = ResumeCheck.replaceHeading(document, entryID: finding.entryID, field: field, before: finding.before, with: suggestion)
        } else {
            guard let lineID = finding.lineID else { return }
            result = ResumeCheck.replaceLine(document, lineID: lineID, before: finding.before, with: suggestion)
        }
        switch result {
        case .success(let next): mark(.applied, document: next, said: "换上，看下一处"); write(next)
        case .failure(let error): failedWrite(error)
        }
    }

    /// 17.5：删掉这一条；并进另一条时先把另一条换成并好的那句，再删这一条。
    private func remove(_ finding: ResumeCheck.Finding, merge: Bool) {
        guard let lineID = finding.lineID else { return }
        var base = document
        if merge, let target = finding.mergeInto, let suggestion = finding.suggestion {
            switch ResumeCheck.replaceLine(base, lineID: target, before: finding.mergeBefore, with: suggestion) {
            case .success(let next): base = next
            case .failure(let error): failedWrite(error); return
            }
        }
        switch ResumeCheck.deleteLine(base, lineID: lineID, before: finding.before) {
        case .success(let next): mark(.applied, document: next, said: merge ? mergeLabel(finding) : "删掉这一条"); write(next)
        case .failure(let error): failedWrite(error)
        }
    }

    private func send(_ finding: ResumeCheck.Finding) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        answer = ""; said = text
        Task { await revise(finding, instruction: text) }
    }

    /// 用户说了一句：整段带着这句只重看这一段；一条按这句重写（基于当前建议）。
    private func revise(_ finding: ResumeCheck.Finding, instruction: String) async {
        guard let unit = state.units.first(where: { $0.id == finding.entryID }) else { return }
        busy = true; notice = nil
        defer { busy = false }
        do {
            if finding.fix == "entry" || finding.lineID == nil {
                let response = try await session.api.careerRequest(path: "/api/resumes/\(resumeID)/review:check", method: "POST", query: [:],
                                                                   body: ResumeCheck.checkBody([unit], pageCount: pageCount, focus: (unit.id, instruction)))
                let next = (response["findings"]?.items ?? []).first {
                    $0.text("entry_id") == unit.id && $0.text("fix") == "entry" && !$0.text("suggestion").isEmpty
                }
                guard let next else { notice = "按你说的，这一段的标题不用再改。"; return }
                update(finding.id) {
                    $0.suggestion = next.text("suggestion")
                    if !next.text("caption").isEmpty { $0.caption = next.text("caption") }
                    if !next.text("detail").isEmpty { $0.detail = next.text("detail") }
                }
                return
            }
            var body: [String: JSONValue] = [
                "section": unit.sectionPayload,
                "context": ResumeCheck.context(state.units, excluding: unit.id),
                "reference": .object(["kind": .string("general")]),
                "line_id": .string(finding.lineID ?? ""),
                "instruction": .string(instruction),
                "answers": .array([]),
            ]
            if let current = finding.suggestion { body["current_text"] = .string(String(current.prefix(ResumeCheck.lineChars))) }
            let response = try await session.api.careerRequest(path: "/api/resumes/\(resumeID)/section-review:rewrite", method: "POST", query: [:], body: .object(body))
            guard let variant = response["variants"]?.items.first else {
                let missing = (response["missing"]?.items ?? []).compactMap(\.stringValue)
                notice = missing.isEmpty ? "这次没改出来，换个说法试试。" : "还差：\(missing.joined(separator: "、"))"
                return
            }
            update(finding.id) {
                $0.suggestion = variant.text("text")
                $0.risky = (variant["risky_terms"]?.items ?? []).compactMap(\.stringValue)
            }
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            notice = ResumeCheck.errorMessage(error).message
        }
    }

    private func update(_ id: String, _ change: (inout ResumeCheck.Finding) -> Void) {
        guard let index = state.findings.firstIndex(where: { $0.id == id }) else { return }
        change(&state.findings[index])
    }
}

/// 检查结果留在编辑器里：收起面板不丢，顶栏按它显示“检查 · 剩 N 处”。
struct ResumeCheckState: Equatable {
    enum Phase: Equatable { case idle, reading, list, item(Int), failed(credit: Bool) }
    var phase: Phase = .idle
    var units: [ResumeCheck.Unit] = []
    var summary = ""
    var basis = ""
    var findings: [ResumeCheck.Finding] = []

    /// 还剩几处没处理；没在检查（没读、正在读、失败）时为 nil。
    var remaining: Int? {
        switch phase {
        case .list, .item: findings.filter { $0.status == .open }.count
        default: nil
        }
    }
}
