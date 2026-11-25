import AppKit
import DrawOfferCore
import SwiftUI

/// 下一场面试：求职进度里这家公司下一场还没开始的面试。
struct NextInterview: Equatable { let label: String; let date: String; let days: Int }

/// 面试复盘总览（Figma 09 · 10.01 总览、10.02 只看没答好、10.03 建议先补；Web `interviews/report/ReviewReport.tsx`）：
/// 第一屏是总分和三张图，下面是记忆变化、一题一张同高的卡，再下面是建议先补的几处。点卡片进单题详情，点「练这一处」进配置页。
struct MockReviewOverview<Crumb: View, Actions: View, Memory: View, Footnote: View>: View {
    let view: MockRV.View
    var next: NextInterview?
    let open: (String) -> Void
    let practice: ([MockRV.Question]) -> Void
    @ViewBuilder var crumb: () -> Crumb
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var memory: () -> Memory
    @ViewBuilder var footnote: () -> Footnote
    @State private var onlyWeak = false

    var body: some View {
        let weak = view.questions.filter(\.weak)
        let reached = view.questions.filter { $0.outcome == .reached }
        let suggestions = MockRV.suggestions(view.questions)
        V3Page(top: 46) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 24) {
                    crumb().padding(.top, 6)
                    Spacer(minLength: 0)
                    HStack(spacing: 10) { actions() }
                }
                Text(verbatim: view.title).font(V3.serif(28)).foregroundStyle(RRC.ink).lineHeight(28, 36, .serif).padding(.top, 6)
                Text(verbatim: view.meta).font(V3.sans(14)).foregroundStyle(RRC.text).frame(height: 22).padding(.top, 4)
                GeometryReader { geometry in
                    let wide = geometry.size.width > 800
                    top(wide: wide, reached: reached.count, weak: weak.count).frame(width: geometry.size.width)
                }
                .frame(height: topHeight).padding(.top, 18)
                .background { GeometryReader { g in Color.clear.preference(key: RRWidth.self, value: g.size.width) } }
                memory()
                HStack {
                    Text("每道题").font(V3.serif(22)).foregroundStyle(RRC.ink)
                    Spacer()
                    if !weak.isEmpty {
                        MockSeg(label: "筛选题目", options: [(false, "全部 \(view.questions.count)", false), (true, "没答好 \(weak.count)", false)], current: onlyWeak) { onlyWeak = $0 }
                    }
                }
                .padding(.top, 44)
                VStack(spacing: 8) {
                    ForEach(onlyWeak ? weak : view.questions) { q in RRQuestionRow(question: q) { open(q.id) } }
                }.padding(.top, 12)
                if !suggestions.isEmpty {
                    Text(verbatim: "建议先补这 \(suggestions.count) 处知识").font(V3.serif(22)).foregroundStyle(RRC.ink).padding(.top, 44)
                    Text(verbatim: (view.questions.contains { !($0.history ?? []).isEmpty } ? "按这场答得差、以往也停过的排。" : "按这场答得差的排。")
                         + (next.map { $0.days <= 0 ? "\($0.label) \($0.date)，就是今天。" : "\($0.label) \($0.date)，还有 \($0.days) 天。" } ?? ""))
                        .font(V3.sans(13)).foregroundStyle(RRC.sub).frame(height: 20).padding(.top, 4)
                    HStack(alignment: .top, spacing: 11) {
                        ForEach(suggestions) { q in RRSuggestCard(question: q) { practice([q]) } }
                    }.padding(.top, 14)
                }
                HStack(spacing: 4) {
                    Text(verbatim: "总分来自这 \(view.questions.count) 道题，通用能力不计入总分。" + (view.pastCount > 0 ? "“以往”来自你之前的 \(view.pastCount) 场面试。" : ""))
                    footnote()
                }
                .font(V3.sans(12)).foregroundStyle(RRC.sub).padding(.top, 20)
            }
        }
        .onPreferenceChange(RRWidth.self) { width = $0 }
        .background(.white)
    }

    @State private var width: CGFloat = 1000
    /// 两栏时左边环形卡占两行（高度跟宽度等比），单栏时三张卡竖排。
    private var topHeight: CGFloat {
        let ringW = width > 800 ? (width - 12) * 520 / 1043 : width
        let ring = 20 + 30 + 22 + 16 + ringW * 420 / 520
        return width > 800 ? max(ring, 248 * 2 + 12) : ring + 12 + 248 + 12 + 248
    }

    @ViewBuilder private func top(wide: Bool, reached: Int, weak: Int) -> some View {
        let ring = box {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: view.conclusion).font(V3.serif(22)).foregroundStyle(RRC.ink).lineHeight(22, 30, .serif).padding(.horizontal, 24)
                Text(verbatim: view.compare).font(V3.sans(13)).foregroundStyle(RRC.sub).frame(height: 20).padding(.horizontal, 24).padding(.top, 2)
                RRScoreRing(questions: view.questions, target: view.target, score: view.score).padding(.top, 16)
                Spacer(minLength: 0)
            }.padding(.top, 20)
        }
        let bars = box {
            VStack(alignment: .leading, spacing: 0) {
                chartHead("每道题得分", small: nil) {
                    legend(RRC.blue, "\(reached) 道答到位")
                    if weak > 0 { legend(RRC.orange, "\(weak) 道没答好") }
                }
                RRScoreBars(questions: view.questions).padding(.horizontal, -20).padding(.top, 4)
                Spacer(minLength: 0)
            }.padding(EdgeInsets(top: 15, leading: 20, bottom: 12, trailing: 20))
        }
        if wide {
            HStack(alignment: .top, spacing: 12) {
                // 520 : 523 按宽度明确分（layoutPriority 只会让高优先级一边全占，环形卡被挤成一条）
                let ringWidth = max(0, (width - 12) * 520 / 1043)
                ring.frame(width: ringWidth).frame(maxHeight: .infinity)
                VStack(spacing: 12) { bars.frame(maxHeight: .infinity); abilityBox.frame(maxHeight: .infinity) }.frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 12) { ring; bars.frame(height: 248); abilityBox.frame(height: 248) }
        }
    }

    private var abilityBox: some View {
        let abilities = MockRV.generalAbilities(view.abilities)
        let ordered = abilities.sorted { $0.score > $1.score }
        let best = ordered.first, worst = ordered.last
        let weakest = worst.flatMap { w in best.map { $0.score > w.score } == true ? w.key : nil }
        let lines: [(String, String)] = view.voice.map { [("语速", $0.speed), ("长停顿", $0.pauses), ("口头禅占比", $0.fillers)] }
            ?? [("最稳", best.map { "\($0.label) \($0.score)" } ?? "—"), ("先补", worst.map { "\($0.label) \($0.score)" } ?? "—")]
        return box {
            VStack(alignment: .leading, spacing: 0) {
                chartHead("通用能力", small: "不看题目，看你怎么说") {
                    if abilities.count >= 3 {
                        legend(RRC.blue, "这场")
                        if abilities.contains(where: { $0.past != nil }) { legend(RRC.faint, "以往") }
                    }
                }
                if abilities.count >= 3 {
                    HStack(spacing: 16) {
                        RRAbilityRadar(abilities: abilities, weakest: weakest).frame(maxWidth: .infinity).layoutPriority(340)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(lines, id: \.0) { line in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(verbatim: line.0).font(V3.sans(12)).foregroundStyle(RRC.sub).frame(height: 18)
                                    Text(verbatim: line.1).font(V3.sans(13, weight: .medium)).foregroundStyle(RRC.ink).lineHeight(13, 20)
                                }
                            }
                        }.frame(width: 143, alignment: .leading)
                    }
                    .padding(.leading, -20).frame(maxHeight: .infinity)
                } else {
                    Text("这场能判断的能力太少，先不画这张图。").font(V3.sans(13)).foregroundStyle(RRC.sub).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.padding(EdgeInsets(top: 15, leading: 20, bottom: 12, trailing: 20))
        }
    }

    private func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RRC.line))
    }

    private func chartHead<Legend: View>(_ title: String, small: String?, @ViewBuilder legend: () -> Legend) -> some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: title).font(V3.sans(15, weight: .medium)).foregroundStyle(RRC.ink)
                if let small { Text(verbatim: small).font(V3.sans(12)).foregroundStyle(RRC.sub) }
            }.lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 0) { legend() }
        }.frame(height: 24)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 8, height: 8); Text(verbatim: text) }
            .font(V3.sans(12)).foregroundStyle(RRC.sub).padding(.leading, 12)
    }
}

private struct RRWidth: PreferenceKey {
    static let defaultValue: CGFloat = 1000
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 五格深度条：答到的几格深色，目标位置一根竖线。
struct RRDepth: View {
    let question: MockRV.Question
    var body: some View {
        let level = max(0, question.level ?? 0)
        ZStack(alignment: .leading) {
            HStack(spacing: 3) { ForEach(1...5, id: \.self) { step in RoundedRectangle(cornerRadius: 2).fill(step <= level ? RRC.text : RRC.thin).frame(width: 22, height: 4) } }
            Rectangle().fill(RRC.ink).frame(width: 2, height: 10).offset(x: CGFloat(max(1, min(5, question.expected))) * 25 - 3)
        }
        .frame(width: 122, height: 10, alignment: .leading).accessibilityHidden(true)
    }
}

/// `.rr-q`：76 高的一题，列宽 68 / 30 / 自适应 / 182 / 145 / 20；悬停只加深描边。
private struct RRQuestionRow: View {
    let question: MockRV.Question
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        let tag = MockRV.repeatTag(question)
        Button(action: action) {
            HStack(spacing: 0) {
                Text(verbatim: question.score.map(String.init) ?? "—").font(V3.serif(30)).foregroundStyle(RRC.ink).frame(width: 68, alignment: .leading)
                Text(verbatim: "\(question.no)").font(V3.sans(11, weight: .medium)).foregroundStyle(RRC.sub)
                    .frame(width: 20, height: 20).overlay(Circle().strokeBorder(RRC.faint)).frame(width: 30, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: question.title).font(V3.sans(15, weight: .medium)).foregroundStyle(RRC.ink).lineLimit(1)
                        if let tag { Text(verbatim: tag).font(V3.sans(12)).foregroundStyle(RRC.sub).fixedSize() }
                    }
                    if let line = question.line { Text(verbatim: line).font(V3.sans(13)).foregroundStyle(question.weak ? RRC.ink : RRC.sub).lineLimit(1) }
                }
                .padding(.trailing, 22).frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    RRDepth(question: question)
                    Text(verbatim: MockRV.depthLine(question)).font(V3.sans(12)).foregroundStyle(RRC.sub).lineLimit(1)
                }.frame(width: 182, alignment: .leading)
                Text(verbatim: MockRV.outcomeText(question)).font(V3.sans(13, weight: question.weak ? .medium : .regular)).foregroundStyle(question.weak ? RRC.orange : RRC.sub)
                    .frame(width: 145, alignment: .leading)
                Text("›").font(V3.sans(15)).foregroundStyle(RRC.faint).frame(width: 20)
            }
            .padding(.horizontal, 24).frame(minHeight: 76)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hover ? Color(hex: 0xC9C9C3) : RRC.line))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .accessibilityLabel("\(question.title) · \(MockRV.outcomeText(question))")
    }
}

/// 建议先补的一张卡：题名、要补的点、一句建议、来自第几题、练这一处。
private struct RRSuggestCard: View {
    let question: MockRV.Question
    let practice: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: question.title).font(V3.sans(15, weight: .medium)).foregroundStyle(RRC.ink).lineLimit(1)
                Spacer(minLength: 0)
                if let tag = MockRV.stopTag(question) { Text(verbatim: tag).font(V3.sans(12)).foregroundStyle(RRC.sub).fixedSize() }
            }
            MockFlow(spacing: 6, lineSpacing: 6) {
                ForEach(MockRV.gaps(question).prefix(3), id: \.self) { gap in
                    Text(verbatim: gap).font(V3.sans(12)).foregroundStyle(RRC.text).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 3)
                        .background(MockPalette.chip, in: RoundedRectangle(cornerRadius: 6))
                }
            }.padding(.top, 12)
            Text(verbatim: MockRV.advice(question)).font(V3.sans(13)).foregroundStyle(RRC.text).lineHeight(13, 21).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            Spacer(minLength: 14)
            HStack {
                Text(verbatim: "来自第 \(question.no) 题").font(V3.sans(12)).foregroundStyle(RRC.sub)
                Spacer()
                Button("练这一处 ›", action: practice).buttonStyle(MockLinkStyle(blue: true))
            }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        .frame(maxWidth: .infinity, minHeight: 186, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RRC.line))
    }
}

/// 原话里出问题的部分划橙色下划线。
func rrMarked(_ text: String, _ marks: [MockRV.Mark], base: Color, mark markColor: Color = RRC.orange) -> Text {
    var result = Text(verbatim: "")
    var cursor = text.startIndex
    for mark in marks.sorted(by: { (text.range(of: $0.quote)?.lowerBound ?? text.endIndex) < (text.range(of: $1.quote)?.lowerBound ?? text.endIndex) }) {
        guard let range = text.range(of: mark.quote, range: cursor..<text.endIndex) else { continue }
        result = result + Text(verbatim: String(text[cursor..<range.lowerBound])).foregroundColor(base)
        result = result + Text(verbatim: mark.quote).foregroundColor(markColor).underline(true, color: RRC.orange)
        cursor = range.upperBound
    }
    return result + Text(verbatim: String(text[cursor...])).foregroundColor(base)
}

/// 翻看面试记录（Figma 09 · 10.05；Web `ReviewRecord.tsx`）：顶上一条按用时分段的进度条，点哪段跳到哪题；
/// 左边题号、分数、播放，右边逐题问答，没答好的题在回答右侧加批注。
struct MockReviewRecord<Crumb: View>: View {
    let view: MockRV.View
    var initial: String?
    var playing: String?
    var play: ((MockRV.Question) -> Void)?
    @ViewBuilder var crumb: () -> Crumb
    @State private var active = 0

    var body: some View {
        ScrollViewReader { proxy in
            V3Page(top: 46) {
                VStack(alignment: .leading, spacing: 0) {
                    crumb().padding(.top, 6)
                    Text(verbatim: view.recordTitle).font(V3.serif(28)).foregroundStyle(RRC.ink).lineHeight(28, 36, .serif).padding(.top, 18)
                    if !view.recordMeta.isEmpty {
                        Text(verbatim: view.recordMeta).font(V3.sans(14)).foregroundStyle(RRC.text).frame(height: 22).padding(.top, 4)
                    }
                    RRRecordBar(questions: view.questions, active: active) { index in
                        withAnimation { proxy.scrollTo(view.questions[index].id, anchor: .top) }; active = index
                    }.padding(.top, view.recordMeta.isEmpty ? 26 : 22)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(view.questions.enumerated()), id: \.element.id) { index, q in
                            if index > 0 { Rectangle().fill(RRC.thin).frame(height: 1) }
                            block(q).id(q.id).onAppear { active = index }
                                .padding(.top, 36).padding(.bottom, 24)
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .onAppear { if let initial { DispatchQueue.main.async { proxy.scrollTo(initial, anchor: .top) } } }
        }
        .background(.white)
    }

    private func block(_ q: MockRV.Question) -> some View {
        let outcome = MockRV.outcomeText(q)
        let hasRecording = play != nil && q.turns.contains(where: \.hasRecording)
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: String(format: "%02d", q.no)).font(V3.serif(26)).foregroundStyle(q.weak ? RRC.ink : RRC.faint).lineHeight(26, 36, .serif)
                Text(verbatim: [q.score.map { "\($0) 分" }, outcome].compactMap { $0 }.joined(separator: " · "))
                    .font(V3.sans(12, weight: q.weak ? .medium : .regular)).foregroundStyle(q.weak ? RRC.orange : RRC.sub).frame(height: 18)
                if hasRecording, let play {
                    Button(playing == q.id ? "❚❚ 暂停" : "▶ 播放这段") { play(q) }.buttonStyle(MockLinkStyle(blue: true, size: 12))
                }
            }.frame(width: 142, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(q.turns) { turn in
                    let marks = MockRV.marks(q, turn.answer)
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: turn.follow ? 4 : 12) {
                            if turn.follow {
                                Text("追问").font(V3.sans(12)).foregroundStyle(RRC.faint).frame(height: 18)
                                Text(verbatim: turn.ask).font(V3.sans(15, weight: .medium)).foregroundStyle(RRC.ink).lineHeight(15, 26).fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(verbatim: turn.ask).font(V3.serif(20)).foregroundStyle(RRC.ink).lineHeight(20, 30, .serif).fixedSize(horizontal: false, vertical: true)
                            }
                            if let answer = turn.answer {
                                rrMarked(answer, marks, base: RRC.text, mark: RRC.ink).font(V3.sans(15)).lineHeight(15, 27).fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(verbatim: turn.missing).font(V3.sans(14)).foregroundStyle(RRC.faint)
                            }
                        }
                        .padding(.top, turn.follow ? 8 : 0)
                        .frame(maxWidth: 600, alignment: .leading)
                        Spacer(minLength: 13)
                        if !marks.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(marks, id: \.quote) { mark in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("问题在这").font(V3.sans(12, weight: .medium)).foregroundStyle(RRC.orange).frame(height: 18)
                                        Text(verbatim: MockRV.markText(mark)).font(V3.sans(13)).foregroundStyle(RRC.text).lineHeight(13, 21).fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
                                    .overlay(alignment: .leading) { Rectangle().fill(Color(hex: 0xE8B78F)).frame(width: 1.5) }
                                }
                            }
                            .frame(width: 235, alignment: .leading).padding(.top, turn.follow ? 8 : 0)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 面试记录顶上的分段条：一段一道题，宽度按这题用时；没答好的橙，当前的墨黑，其余浅灰。
private struct RRRecordBar: View {
    let questions: [MockRV.Question]
    let active: Int
    let jump: (Int) -> Void

    private var weights: [CGFloat] {
        let spent = questions.map { q in CGFloat(q.turns.reduce(0) { $0 + ($1.durationMs ?? 0) }) }
        if spent.allSatisfy({ $0 > 0 }) { return spent }
        let size = questions.map { q in CGFloat(max(1, q.turns.reduce(0) { $0 + ($1.ask.count + ($1.answer?.count ?? 0)) })) }
        return size
    }

    var body: some View {
        GeometryReader { geometry in
            let shares = weights
            let total = max(1, shares.reduce(0, +))
            let free = max(0, geometry.size.width - CGFloat(max(0, questions.count - 1)) * 4)
            let widths = shares.map { max(12, free * $0 / total) }
            let starts = widths.indices.map { index in widths[..<index].reduce(0, +) + CGFloat(index) * 4 }
            ZStack(alignment: .topLeading) {
                ForEach(Array(questions.enumerated()), id: \.element.id) { index, q in
                    let current = index == active
                    Button { jump(index) } label: {
                        RoundedRectangle(cornerRadius: 3).fill(current ? RRC.ink : q.weak ? Color(hex: 0xE8B78F) : Color(hex: 0xD8D8D3)).frame(width: widths[index], height: 6)
                            .frame(height: 24, alignment: .top).contentShape(Rectangle())
                    }.buttonStyle(.plain).offset(x: starts[index])
                    Text(verbatim: current ? "\(q.no)　\(q.title)" : "\(q.no)").lineLimit(1).fixedSize()
                        .font(V3.sans(12, weight: current ? .medium : .regular)).foregroundStyle(current ? RRC.ink : RRC.sub)
                        .offset(x: starts[index], y: 12).allowsHitTesting(false)
                }
            }
        }
        .frame(height: 32)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
