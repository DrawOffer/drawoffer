import DrawOfferCore
import SwiftUI

/// 单题详情（Figma 09 · 10.05 没答好、10.06 答到位；Web `interviews/report/ReviewQuestion.tsx`）：
/// 左边完整问答（原话里出问题的地方划线），右边面试官想听到什么、可以这样说 / 亮点、这道题的几次；可以回放录音、修改识别稿、判得不对。
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
    @ViewBuilder var crumb: () -> Crumb


    var body: some View {
        let level = question.level ?? 0
        let tag = question.recovered ? "上次没过，这次答到了" : MockRV.repeatTag(question)
        let meta = ["第 \(question.no) 题", MockRV.outcomeText(question), question.score.map { "\($0) 分" }, tag].compactMap { $0 }.joined(separator: " · ")
        let history = question.history ?? []
        V3Page(top: 46) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 24) {
                    crumb().padding(.top, 6)
                    Spacer(minLength: 0)
                    HStack(spacing: 12) {
                        Button("‹ 上一题") { if let prev { open(prev.id) } }.buttonStyle(MockLinkStyle()).disabled(prev == nil)
                        Text(verbatim: "\(question.no) / \(total)").font(V3.sans(13)).foregroundStyle(RRC.sub)
                        Button("下一题 ›") { if let next { open(next.id) } }.buttonStyle(MockLinkStyle()).disabled(next == nil)
                    }.frame(height: 40)
                    if question.weak { Button("练这一处") { practice(question) }.buttonStyle(MockPillStyle(height: 40, padding: 20)) }
                }
                Text(verbatim: question.title).font(V3.serif(28)).foregroundStyle(RRC.ink).lineHeight(28, 36).padding(.top, 6)
                Text(verbatim: meta).font(V3.sans(14)).foregroundStyle(RRC.text).frame(height: 22).padding(.top, 4)
                Text(verbatim: MockRV.depthSentence(question)).font(V3.sans(13, weight: .medium)).foregroundStyle(RRC.ink).frame(height: 20).padding(.top, 22)
                depth(level)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 40) {
                        talk.frame(minWidth: 480, maxWidth: .infinity, alignment: .leading).layoutPriority(620)
                        side(history).frame(minWidth: 300, maxWidth: .infinity, alignment: .leading).layoutPriority(395)
                    }
                    VStack(alignment: .leading, spacing: 32) { talk; side(history) }
                }
                .padding(.top, 20)
            }
        }
        .background(.white)
    }

    /// 五层深度：答到的几层深色，当前层加粗，目标层一根竖线。
    private func depth(_ level: Int) -> some View {
        GeometryReader { geometry in
            let cell = (geometry.size.width - 32) / 5
            ZStack(alignment: .topLeading) {
                HStack(spacing: 8) {
                    ForEach(Array(MockRV.levels.enumerated()), id: \.offset) { index, name in
                        VStack(alignment: .leading, spacing: 7) {
                            RoundedRectangle(cornerRadius: 2.5).fill(index < level ? RRC.text : RRC.thin).frame(height: 5)
                            Text(verbatim: name).font(V3.sans(12, weight: index + 1 == level ? .medium : .regular)).foregroundStyle(index + 1 == level ? RRC.ink : RRC.faint)
                        }.frame(width: cell)
                    }
                }
                Rectangle().fill(RRC.ink).frame(width: 2, height: 13).offset(x: (cell + 8) * CGFloat(max(1, min(5, question.expected))) - 13, y: -4)
            }
        }
        .frame(height: 30).padding(.top, 10).padding(.bottom, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(RRC.thin).frame(height: 1) }
    }

    private var talk: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("完整问答").font(V3.sans(12)).foregroundStyle(RRC.sub).frame(height: 18).padding(.bottom, 10)
            ForEach(question.turns) { turn in
                let marks = MockRV.marks(question, turn.answer)
                say("面试官") { Text(verbatim: turn.ask).fontWeight(.medium).foregroundStyle(RRC.ink) }
                say("你") {
                    if let answer = turn.answer { rrMarked(answer, marks, base: RRC.text) } else { Text(verbatim: turn.missing).foregroundStyle(RRC.faint) }
                }
                ForEach(marks, id: \.quote) { mark in
                    Text(verbatim: "问题在这：\(MockRV.markText(mark))").font(V3.sans(12)).foregroundStyle(RRC.orange).lineHeight(12, 18).padding(.leading, 64).padding(.top, -8).padding(.bottom, 14)
                }
            }
            HStack(spacing: 24) {
                if let play { Button(playing ? "暂停播放" : "播放这段录音") { play(question) }.buttonStyle(MockLinkStyle(blue: true)) }
                if let edit { Button("修改识别稿") { edit(question) }.buttonStyle(MockLinkStyle(blue: true)) }
                Button("在面试记录里打开") { record(question) }.buttonStyle(MockLinkStyle(blue: true))
            }.padding(.leading, 64).padding(.top, 6)
        }
    }

    private func say<Content: View>(_ who: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(verbatim: who).font(V3.sans(13)).foregroundStyle(RRC.sub).frame(width: 64, height: 22, alignment: .leading)
            content().font(V3.sans(14)).lineHeight(14, 24).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.bottom, 14)
    }

    private func side(_ history: [MockRV.History]) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if !question.signals.isEmpty {
                section("面试官想听到什么") {
                    ForEach(Array(question.signals.enumerated()), id: \.offset) { _, signal in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(verbatim: signal.label).foregroundStyle(signal.state == "miss" ? RRC.ink : RRC.text).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Text(verbatim: ["hit": "说到了", "partial": "说了一半", "miss": "没说到"][signal.state] ?? "").font(V3.sans(12, weight: signal.state == "miss" ? .medium : .regular))
                                .foregroundStyle(signal.state == "miss" ? RRC.orange : RRC.sub).fixedSize()
                        }.font(V3.sans(13)).padding(.bottom, 10)
                    }
                }
            }
            if question.weak, let better = question.better {
                section("可以这样说") { Text(verbatim: better).font(V3.sans(13)).foregroundStyle(RRC.text).lineHeight(13, 22).fixedSize(horizontal: false, vertical: true) }
            } else if !question.weak, let highlight = question.highlight {
                section("亮点") { Text(verbatim: highlight).font(V3.sans(13)).foregroundStyle(RRC.text).lineHeight(13, 22).fixedSize(horizontal: false, vertical: true) }
            }
            if history.count > 1 {
                section("这道题的 \(history.count) 次") {
                    ForEach(Array(history.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Text(verbatim: item.date).fontWeight(item.current ? .medium : .regular).frame(width: 60, alignment: .leading)
                            Text(verbatim: item.title).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(verbatim: item.result)
                        }
                        .font(V3.sans(13)).foregroundStyle(item.current ? RRC.ink : RRC.sub).frame(height: 22).padding(.bottom, 8)
                    }
                }
            }
            if let judge { Button("判得不对？") { judge(question) }.buttonStyle(MockLinkStyle(blue: true)) }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title).font(V3.sans(12)).foregroundStyle(RRC.sub).frame(height: 18).padding(.bottom, 10)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
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
            VStack(alignment: .leading, spacing: 10) {
                MockSeg(label: "答到的层", options: options, current: shown) { picked = $0 }
                if let aiText { Text(verbatim: "AI 判的是\(aiText)").font(V3.sans(12)).foregroundStyle(MockPalette.fnt) }
            }.padding(.top, 16)
        }
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
                                .font(V3.sans(14)).lineSpacing(24 - 14 * 1.2).scrollContentBackground(.hidden).padding(.horizontal, 12).padding(.vertical, 10)
                                .frame(minHeight: 148).background(MockPalette.chip, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("修改识别稿")
                        }
                    }
                }
            }
            .frame(maxHeight: 360).padding(.top, 16)
        }
        .onAppear { drafts = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0.answer ?? "") }) }
    }
}
