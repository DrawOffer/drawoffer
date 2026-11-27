import DrawOfferCore
import SwiftUI

/// 单题复盘和完整记录的配色（Web `reviewQuestion.css` 的 `.rq`）。
enum RQC {
    static let ink = Color(hex: 0x1C1917), text = Color(hex: 0x37332F), sub = Color(hex: 0x57534E), mute = Color(hex: 0x8C8680), faint = Color(hex: 0xA8A29E)
    static let rule = Color(hex: 0xECEBE9), mark = Color(hex: 0xFCEFCB), markOn = Color(hex: 0xF7DC92), bar = Color(hex: 0xE8C66E)
}

/// 单题复盘（Figma 09 · 06.01；Web `interviews/report/ReviewQuestion.tsx`）：左边是一份连续的只读文档（问答回放 + 整题回顾），
/// 右边像文档批注，挂在被标黄的原话那一轮旁边；点一条展开全文并加深那句原话。窄时批注收进每一轮下面。
struct MockQuestionDetail<Crumb: View>: View {
    let question: MockRV.Question
    let total: Int
    let prev: MockRV.Question?
    let next: MockRV.Question?
    let open: (String) -> Void
    let practice: (MockRV.Question) -> Void
    let record: (MockRV.Question) -> Void
    var judge: ((MockRV.Question) -> Void)?
    var edit: ((MockRV.Question) -> Void)?
    var play: ((MockRV.Question) -> Void)?
    var playing = false
    /// 练这一处练完直接看这一题（Figma 10.23b）：右上是「再练一次」，不翻题
    var single = false
    @ViewBuilder var crumb: () -> Crumb
    @State private var active: String?


    var body: some View {
        let comments = MockRV.comments(question)
        let meta = ["第 \(question.no) 题", question.follows > 0 ? "主问题 + 追问 \(question.follows) 次" : "主问题",
                    question.previousScore.map { "上次 \($0) 分" }, question.score.map { _ in "达标 \(MockRV.passScore) 分" }].compactMap { $0 }
        GeometryReader { geometry in
            let page = min(968, geometry.size.width - 48)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 24) {
                        crumb()
                        Spacer(minLength: 0)
                        if !single {
                            HStack(spacing: 14) {
                                Button("‹ 上一题") { if let prev { open(prev.id) } }.disabled(prev == nil)
                                Text(verbatim: "\(question.no) / \(total)").font(V3.number(12.5, weight: .regular)).foregroundStyle(RQC.faint)
                                Button("下一题 ›") { if let next { open(next.id) } }.disabled(next == nil)
                            }.buttonStyle(MockLinkStyle(size: 13, color: RQC.sub)).fontWeight(.medium)
                        }
                    }
                    .frame(height: 20)
                    head(meta).padding(.top, 38)
                    let narrow = page < 900
                    VStack(alignment: .leading, spacing: 0) {
                        heading("问答回放", meta[1])
                        ForEach(Array(question.turns.enumerated()), id: \.element.id) { index, turn in
                            let notes = comments.filter { $0.turnID == turn.id }
                            if narrow {
                                VStack(alignment: .leading, spacing: 8) { self.turn(turn, index, notes); ForEach(notes) { note($0) } }.padding(.top, index > 0 ? 26 : 0)
                            } else {
                                HStack(alignment: .top, spacing: 48) {
                                    self.turn(turn, index, notes).frame(maxWidth: 640, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 0) { ForEach(notes) { note($0) } }
                                        .frame(width: 280, alignment: .leading).padding(.top, 34)
                                }
                                .padding(.top, index > 0 ? 26 : 0)
                            }
                        }
                        review.frame(maxWidth: 640, alignment: .leading)
                        HStack(spacing: 20) {
                            if let play { Button(playing ? "停止播放" : "播放录音") { play(question) } }
                            if let judge { Button("判得不对？") { judge(question) } }
                            if let edit { Button("修改识别稿") { edit(question) } }
                            Button("在完整面试记录中查看") { record(question) }
                        }
                        .buttonStyle(MockLinkStyle(size: 12.5, color: RQC.mute)).padding(.top, 24)
                    }
                    .padding(.top, 24)
                }
                .frame(width: page, alignment: .leading).frame(maxWidth: .infinity).padding(.top, 38).padding(.bottom, 60)
            }
        }
        .background(.white)
        .onChange(of: question.id) { _, _ in active = nil }
    }

    private func head(_ meta: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Text(verbatim: question.title).font(V3.serif(30)).fontWeight(.semibold).foregroundStyle(RQC.ink).lineHeight(30, 40, .serif)
                    .fixedSize(horizontal: false, vertical: true)
                if let score = question.score {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: "\(score)").font(V3.number(26)).foregroundStyle(RQC.ink)
                        Text("分").font(V3.sans(13)).foregroundStyle(RQC.mute)
                    }.padding(.top, 4)
                }
                Spacer(minLength: 0)
                Button(MockPracticeResult.practiceButton(single: single)) { practice(question) }.buttonStyle(MockPillStyle(kind: .ghost, height: 38, padding: 19)).padding(.top, 2)
            }
            Text(verbatim: meta.joined(separator: " · ")).font(V3.sans(12.5)).foregroundStyle(RQC.faint).lineHeight(12.5, 20).padding(.top, 6)
            if let line = question.line {
                Text(verbatim: line).font(V3.sans(15)).foregroundStyle(RQC.text).lineHeight(15, 28).frame(maxWidth: 640, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 20)
            }
            Rectangle().fill(RQC.rule).frame(height: 1).padding(.top, 20)
        }
    }

    private func heading(_ title: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: title).font(V3.serif(23)).fontWeight(.semibold).foregroundStyle(RQC.ink)
            Text(verbatim: note).font(V3.sans(12.5)).foregroundStyle(RQC.faint)
        }
        .padding(.leading, 15)
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(RQC.ink).frame(width: 3, height: 20) }
        .frame(height: 34).padding(.bottom, 18)
    }

    private func turn(_ turn: MockRV.Turn, _ index: Int, _ notes: [MockRV.Comment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text(verbatim: MockRV.turnLabel(index)).font(V3.sans(13)).foregroundStyle(RQC.faint) + Text(verbatim: "　" + turn.ask).font(V3.sans(16, weight: .bold)).foregroundStyle(RQC.ink))
                .lineHeight(16, 28).fixedSize(horizontal: false, vertical: true)
            Group {
                if let answer = turn.answer { Text(marked(answer, notes)) } else { Text(verbatim: turn.missing).foregroundStyle(RQC.faint) }
            }
            .font(V3.sans(15)).foregroundStyle(RQC.text).lineHeight(15, 28).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 批注的原话标黄，点开的那条加深。
    private func marked(_ answer: String, _ notes: [MockRV.Comment]) -> AttributedString {
        var text = AttributedString(answer)
        for note in notes {
            guard let range = text.range(of: note.quote) else { continue }
            if text[range].backgroundColor != nil && note.id != active { continue }
            text[range].backgroundColor = note.id == active ? RQC.markOn : RQC.mark
        }
        return text
    }

    @ViewBuilder private func note(_ note: MockRV.Comment) -> some View {
        let open = note.id == active
        Button { withAnimation(.easeOut(duration: 0.16)) { active = open ? nil : note.id } } label: {
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "“\(note.quote.count > 24 ? String(note.quote.prefix(24)) + "…" : note.quote)”").font(V3.sans(12.5)).foregroundStyle(RQC.faint)
                        .lineHeight(12.5, 18).padding(.leading, 10)
                        .overlay(alignment: .topLeading) { RoundedRectangle(cornerRadius: 1).fill(RQC.bar).frame(width: 2, height: 14).padding(.top, 2) }
                    Text(verbatim: note.title).font(V3.sans(14.5, weight: .bold)).foregroundStyle(RQC.ink).lineHeight(14.5, 22).fixedSize(horizontal: false, vertical: true)
                    if let body = note.body { Text(verbatim: body).font(V3.sans(13.5)).foregroundStyle(RQC.sub).lineHeight(13.5, 22).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(EdgeInsets(top: 15, leading: 17, bottom: 17, trailing: 15)).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xECEAE6)))
                .shadow(color: Color(hex: 0x1C1917).opacity(0.07), radius: 10, y: 6).padding(.vertical, 8)
            } else {
                Text(verbatim: note.title).font(V3.sans(13.5)).foregroundStyle(RQC.sub).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 14).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(RQC.bar).frame(width: 2, height: 14).padding(.leading, 2) }
            }
        }
        .buttonStyle(.plain).contentShape(Rectangle())
    }

    /// 整题回顾：这道题考什么、表现与表达、整题参考答案。
    @ViewBuilder private var review: some View {
        let names = question.signals.map { $0.name ?? $0.label }.filter { !$0.isEmpty }
        let intent = question.intent ?? (names.isEmpty ? nil : "面试官想听到：\(names.joined(separator: "、"))。")
        let delivery = question.delivery ?? question.highlight.map { $0 + "。" }
        let reference = (question.better ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if intent != nil || delivery != nil || !reference.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(RQC.rule).frame(height: 1).padding(.top, 26).padding(.bottom, 28)
                heading("整题回顾", "考点、表达和参考答案")
                if let intent { section("这道题考什么", [intent], first: true) }
                if let delivery { section("表现与表达", [delivery], first: intent == nil) }
                if !reference.isEmpty { section("整题参考答案", reference, first: intent == nil && delivery == nil) }
            }
        }
    }

    private func section(_ title: String, _ paragraphs: [String], first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).font(V3.sans(15, weight: .bold)).foregroundStyle(RQC.ink).lineHeight(15, 26).padding(.bottom, -4)
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, item in
                Text(verbatim: item).font(V3.sans(15)).foregroundStyle(RQC.text).lineHeight(15, 28).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, first ? 0 : 18)
    }
}

/// 判得不对（Figma 09 · 10.07）：选你觉得答到的那一层；选回 AI 判的那一层就是撤销。
struct MockJudgeDialog: View {
    let question: MockRV.Question
    let busy: Bool
    let save: (Int?) -> Void
    let close: () -> Void
    @State private var picked: Int?

    var body: some View {
        let options: [(value: Int, title: String, disabled: Bool)] = question.layered
            ? MockRV.levels.enumerated().map { ($0.offset + 1, $0.element, false) }
            : [(max(0, question.expected - 2), "没说清", false), (max(1, question.expected - 1), "说了一半", false), (question.expected, "说清了", false)]
        let current = picked ?? question.level ?? question.aiLevel ?? options[0].value
        let shown = options.contains { $0.value == current } ? current : options[0].value
        let ai = question.aiLevel
        let aiText: String? = ai.flatMap { $0 <= 0 ? "没到「了解」" : question.layered ? "「\(MockRV.levelLabel($0))」" : nil }
        MockConfirmCard(title: "这题判得不对？", desc: "选你觉得答到的那一层，这题会按你的判断显示。", confirm: "按这个算", busy: busy,
                        onConfirm: { save(shown == ai ? nil : shown) }, onCancel: close) {
            VStack(alignment: .leading, spacing: 12) {
                MockJudgeSeg(options: options.map { ($0.value, $0.title) }, current: shown) { picked = $0 }
                if let aiText { Text(verbatim: "AI 判的是\(aiText)").font(V3.sans(12)).foregroundStyle(MockPalette.fnt) }
            }.padding(.top, 22).padding(.bottom, -18)
        }
    }
}

/// 判得不对里选层的分段（Figma 09 · 10.06）：404 × 40 的浅灰底，每格等宽，选中的是 33 高的白底小圆角。
private struct MockJudgeSeg: View {
    let options: [(Int, String)]
    let current: Int
    let pick: (Int) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                let on = value == current
                Button { pick(value) } label: {
                    Text(verbatim: title).font(V3.sans(13, weight: on ? .medium : .regular)).foregroundStyle(on ? RRC.ink : RRC.sub)
                        .frame(maxWidth: .infinity).frame(height: 33)
                        .background {
                            if on { RoundedRectangle(cornerRadius: 5).fill(.white).shadow(color: .black.opacity(0.12), radius: 1, y: 1).shadow(color: .black.opacity(0.06), radius: 0.5) }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 5.5).padding(.vertical, 3.5).frame(height: 40)
        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain).accessibilityLabel("答到的层")
    }
}

/// 修改识别稿（Figma 09 · 10.08）：一轮回答一个输入框；还有重新评分次数时保存后这题重新评分。
struct MockEditDialog: View {
    let question: MockRV.Question
    let remaining: Int
    let busy: Bool
    let save: ([String: String]) -> Void
    let close: () -> Void
    @State private var drafts: [String: String] = [:]

    var body: some View {
        let turns = question.turns.filter(\.editable)
        MockConfirmCard(title: "修改识别稿", desc: remaining > 0 ? "只改听错的字，保存后这题会重新评分。" : "只改听错的字。这题的重新评分次数已用完，保存后只更新文字。",
                        confirm: remaining > 0 ? "保存并重新评分" : "保存", busy: busy, busyLabel: "正在保存…", onConfirm: { save(drafts) }, onCancel: close) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: 6) {
                            if turns.count > 1 { Text(verbatim: turn.ask).font(V3.sans(12)).foregroundStyle(MockPalette.fnt) }
                            TextEditor(text: Binding(get: { drafts[turn.id] ?? turn.answer ?? "" }, set: { drafts[turn.id] = $0 }))
                                .font(V3.sans(14)).lineSpacing(24 - 14 * 1.2).foregroundStyle(RRC.ink).scrollContentBackground(.hidden).padding(.horizontal, 9).padding(.vertical, 10)
                                .frame(minHeight: 150).background(MockPalette.chip, in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel("修改识别稿")
                        }
                    }
                }
            }
            .frame(maxHeight: 360).padding(.top, 22).padding(.bottom, -9)
        }
        .onAppear { drafts = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0.answer ?? "") }) }
    }
}
