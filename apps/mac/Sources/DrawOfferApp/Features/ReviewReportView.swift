import AppKit
import DrawOfferCore
import SwiftUI

/// 复盘总览 08.03 的配色（Web `reviewReport.css` 的 `.ro`）。
enum ROC {
    static let ink = Color(hex: 0x1C1917)
    static let sub = Color(hex: 0x57534E)
    static let mute = Color(hex: 0x8C8680)
    static let faint = Color(hex: 0xA8A29E)
    static let gray = Color(hex: 0x78716C)
    static let line = Color(hex: 0xEAE8E3)
    static let thin = Color(hex: 0xF4F3F1)
    static let blue = Color(hex: 0x2563EB)
    static let low = Color(hex: 0xC27803)
    static let warn = Color(hex: 0xB45309)
    static let headBg = Color(hex: 0xFAFAF8)
    static let headLine = Color(hex: 0xF0EFEA)
}

/// 面试复盘总览（Figma 09 · 08.03 方案 C；Web `interviews/report/ReviewReport.tsx`）：标题和「针对弱项开练」、分数与结论、右侧通用能力雷达，
/// 本场知识点掌握度曲线（达标线 60）、个人能力档案的变化、优先强化的几项和逐题复盘。点曲线上的点或一行题进单题详情。
struct MockReviewOverview<Crumb: View, Actions: View, Memory: View, Footnote: View>: View {
    let view: MockRV.View
    /// 标题旁的小标签：真实面试
    var tag: String? = nil
    let open: (String) -> Void
    let practice: ([MockRV.Question]) -> Void
    /// 练这几处的结果（Figma 10.23a）：不列建议先补，改列这次练的几处和前后分数；给的是「完整模拟」开一场完整模拟
    var full: (() -> Void)? = nil
    @ViewBuilder var crumb: () -> Crumb
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var memory: () -> Memory
    @ViewBuilder var footnote: () -> Footnote

    var body: some View {
        let suggestions = full == nil ? MockRV.suggestions(view.questions) : []
        let abilities = MockRV.generalAbilities(view.abilities)
        let scored = view.questions.filter { $0.score != nil }
        GeometryReader { geometry in
            let bar = min(991, geometry.size.width - 160), page = min(968, bar - 16)
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 24) {
                        crumb()
                        Spacer(minLength: 0)
                        HStack(spacing: 20) { actions() }
                    }
                    .frame(width: bar, height: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        titleRow(suggestions)
                        hero(abilities, wide: page > 760).padding(.top, 22)
                        if scored.count > 1 {
                            sectionHead("本场知识点掌握度", "按作答顺序") {
                                HStack(spacing: 14) {
                                    legend(line: ROC.blue, "本场")
                                    HStack(spacing: 4) {
                                        RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0xF2FBF5)).overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color(hex: 0xB7DEC5)))
                                            .frame(width: 11, height: 9)
                                        Text(verbatim: "达标区 (≥\(MockRV.passScore))")
                                    }
                                }.font(V3.sans(11.5)).foregroundStyle(ROC.sub)
                            }
                            .padding(.top, 22)
                            RRWave(questions: scored, names: page > 760, open: open).padding(.top, 12)
                        }
                        memory().padding(.top, 22)
                        if !suggestions.isEmpty {
                            sectionHead("优先强化这 \(suggestions.count) 项", "分数低的排在前面") {
                                Button("专项练习 ›") { practice(suggestions) }.buttonStyle(MockLinkStyle(size: 12.5, color: ROC.blue)).fontWeight(.medium)
                            }
                            .padding(.top, 22)
                            focusGrid(suggestions, wide: page > 760).padding(.top, 12)
                        }
                        if let full { practiceList(full).padding(.top, 28) } else { questionCard.padding(.top, 22) }
                        HStack(spacing: 4) {
                            Text(verbatim: "总分来自这 \(view.questions.count) 道题，通用能力不计入总分。" + (view.pastCount > 0 ? "“以往”来自你之前的 \(view.pastCount) 场面试。" : ""))
                            footnote()
                        }
                        .font(V3.sans(12)).foregroundStyle(RRC.sub).padding(.top, 18)
                    }
                    .frame(width: page, alignment: .leading).padding(.top, 26)
                }
                .frame(maxWidth: .infinity).padding(.top, 38).padding(.bottom, 60)
            }
        }
        .background(.white)
    }

    private func titleRow(_ suggestions: [MockRV.Question]) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(verbatim: view.title).font(V3.serif(30)).fontWeight(.semibold).foregroundStyle(ROC.ink).lineHeight(30, 40, .serif)
                    if let tag {
                        Text(verbatim: tag).font(V3.sans(11, weight: .medium)).foregroundStyle(ROC.warn).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color(hex: 0xFEF7EC), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                Text(verbatim: view.meta).font(V3.sans(12.5)).foregroundStyle(ROC.mute).lineHeight(12.5, 18)
            }
            Spacer(minLength: 0)
            if !suggestions.isEmpty {
                Button("针对弱项开练") { practice(suggestions) }.buttonStyle(MockPillStyle(height: 38, padding: 20)).padding(.top, 10)
            }
        }
    }

    /// 分数和上次比的差；练这几处时是这几处平均比练习前
    private var gap: Int? {
        if full != nil { return MockPracticeResult.averageGain(view.questions.map { (before: $0.previousScore, after: $0.score) }) }
        guard let score = view.score, let previous = view.previous else { return nil }
        return score - previous
    }

    /// 分数旁的小标签：+5 较上次 / 和上次持平；练这几处时是「较练习前」。
    @ViewBuilder private var delta: some View {
        if let gap {
            let tone: (Color, Color) = gap < 0 ? (Color(hex: 0xFEF2F2), Color(hex: 0xDC2626)) : gap == 0 ? (Color(hex: 0xF4F3F0), ROC.sub) : (Color(hex: 0xECFDF3), Color(hex: 0x15803D))
            Text(verbatim: MockPracticeResult.deltaText(gap, practice: full != nil))
                .font(V3.sans(11.5, weight: .medium)).foregroundStyle(tone.1).padding(.horizontal, 9).padding(.vertical, 3.5)
                .background(tone.0, in: Capsule()).padding(.leading, 8).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] - 7 }
        }
    }

    /// 分数下面的灰色一行：答题达标 3/6 题 · 语速 · 长停顿。
    private var stats: [String] {
        let judged = view.questions.filter { $0.outcome != .unrecorded }
        let reached = judged.filter { $0.outcome == .reached }.count
        return [judged.isEmpty ? nil : "答题达标 \(reached)/\(judged.count) 题",
                view.voice.map { v in v.pace.map { "语速 \(v.speed)（\($0)）" } ?? "语速 \(v.speed)" },
                view.voice.flatMap { $0.longPauses > 0 ? "长停顿 \($0.pauses)" : nil }].compactMap { $0 }
    }

    @ViewBuilder private func hero(_ abilities: [MockRV.Ability], wide: Bool) -> some View {
        let verdict = VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: view.score.map(String.init) ?? "—").font(V3.number(46)).tracking(-0.5).foregroundStyle(ROC.ink)
                Text("分").font(V3.sans(14)).foregroundStyle(ROC.mute)
                delta
            }
            Text(verbatim: full != nil ? MockPracticeResult.headline(total: view.questions.count, reached: view.questions.filter { $0.outcome == .reached }.count)
                 : view.headline ?? view.conclusion).font(V3.sans(15.5, weight: .bold)).foregroundStyle(ROC.ink).lineHeight(15.5, 22)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            if full == nil, let summary = view.summary {
                Text(verbatim: summary).font(V3.sans(13)).foregroundStyle(ROC.gray).lineHeight(13, 20).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
            if !stats.isEmpty {
                Text(verbatim: stats.joined(separator: "  ·  ")).font(V3.sans(12)).foregroundStyle(ROC.faint).lineHeight(12, 18).padding(.top, 10)
            }
        }
        let radar = VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("通用能力分布").font(V3.sans(12, weight: .medium)).foregroundStyle(ROC.mute)
                Spacer(minLength: 0)
                HStack(spacing: 14) {
                    legend(line: ROC.blue, "本场")
                    if abilities.contains(where: { $0.past != nil }) {
                        legend(line: ROC.faint, view.pastCount > 0 ? "以往 \(view.pastCount) 场" : "以往").foregroundStyle(ROC.mute)
                    }
                }.font(V3.sans(11)).foregroundStyle(ROC.sub)
            }
            RRRadar(abilities: abilities)
        }.frame(maxWidth: 366)
        Group {
            if abilities.count < 3 {
                verdict.frame(maxWidth: .infinity, alignment: .leading)
            } else if wide {
                HStack(alignment: .center, spacing: 40) {
                    verdict.frame(maxWidth: 540, alignment: .leading)
                    Spacer(minLength: 0)
                    radar.frame(width: 366)
                }
            } else {
                VStack(alignment: .leading, spacing: 24) { verdict; radar }
            }
        }
        .frame(minHeight: 202).padding(.bottom, 22)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xECEBE9)).frame(height: 1) }
    }

    private func legend(line color: Color, _ text: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 2); Text(verbatim: text) }
    }

    private func sectionHead<Trailing: View>(_ title: String, _ note: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: title).font(V3.sans(15, weight: .bold)).foregroundStyle(ROC.ink)
            Text(verbatim: note).font(V3.sans(12.5)).foregroundStyle(ROC.mute).lineLimit(1)
            Spacer(minLength: 12)
            trailing()
        }
    }

    private func focusGrid(_ suggestions: [MockRV.Question], wide: Bool) -> some View {
        let columns = wide ? (suggestions.count >= 3 ? Array(repeating: GridItem(.flexible(), spacing: 16), count: 3) : Array(repeating: GridItem(.fixed(312), spacing: 16), count: suggestions.count))
            : [GridItem(.flexible())]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(suggestions) { q in RRFocusCard(question: q) { practice([q]) } }
        }
    }

    /// 这次练的几处（Figma 10.23a）：上次 → 这次的分数和一句话，右边答到哪层和查看详情；底部再练没达到的或完整模拟。
    private func practiceList(_ full: @escaping () -> Void) -> some View {
        let weak = view.questions.filter(\.weak)
        return VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "这次练的 \(view.questions.count) 处").font(V3.serif(20)).fontWeight(.semibold).foregroundStyle(ROC.ink).lineHeight(20, 30, .serif)
                .frame(minHeight: 44)
            VStack(spacing: 0) {
                ForEach(view.questions) { q in
                    HStack(alignment: .center, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: q.title).font(V3.sans(16, weight: .medium)).foregroundStyle(ROC.ink).lineHeight(16, 22).lineLimit(1)
                            Text(verbatim: [MockPracticeResult.scoreText(before: q.previousScore, after: q.score), q.line].compactMap { $0 }.joined(separator: " · "))
                                .font(V3.sans(14)).foregroundStyle(ROC.mute).lineHeight(14, 20).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: MockRV.reachLine(q)).font(V3.sans(14)).foregroundStyle(q.weak ? ROC.low : ROC.sub).lineHeight(14, 20).fixedSize()
                        Button("查看详情 ›") { open(q.id) }.buttonStyle(MockLinkStyle(size: 14, color: ROC.blue)).fixedSize()
                    }
                    .padding(.vertical, 10).frame(minHeight: 64)
                }
            }
            .padding(.top, 4)
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                switch MockPracticeResult.footer(weak: weak.count) {
                case .retryWeak(let count):
                    Button(action: full) {
                        HStack(spacing: 6) {
                            Text("完整模拟").font(V3.sans(14, weight: .medium)).foregroundStyle(ROC.ink)
                            Text(verbatim: "\(MockPracticeResult.fullMinutes) 分钟").font(V3.sans(13)).foregroundStyle(ROC.mute)
                        }
                        .padding(.horizontal, 18).frame(height: 36)
                        .background(.white, in: Capsule()).overlay(Capsule().strokeBorder(Color(hex: 0xE7E5E4))).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button(MockPracticeResult.retryTitle(count)) { practice(weak) }.buttonStyle(MockPillStyle(height: 44, padding: 24, size: 14))
                case .fullOnly:
                    Button("完整模拟 · \(MockPracticeResult.fullMinutes) 分钟", action: full).buttonStyle(MockPillStyle(height: 44, padding: 24, size: 14))
                }
            }
            .padding(.top, 36)
        }
        .accessibilityElement(children: .contain).accessibilityLabel("这次练的几处")
    }

    private var questionCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("逐题复盘").font(V3.sans(14.5, weight: .bold)).foregroundStyle(ROC.ink)
                Text(verbatim: "\(view.questions.count) 题").font(V3.sans(12.5)).foregroundStyle(ROC.mute)
                Spacer(minLength: 12)
                Text("点击题目查看完整问答与参考思路").font(V3.sans(12)).foregroundStyle(ROC.faint).lineLimit(1)
            }
            .padding(.horizontal, 20).padding(.vertical, 11).background(ROC.headBg)
            .overlay(alignment: .bottom) { Rectangle().fill(ROC.headLine).frame(height: 1) }
            ForEach(Array(view.questions.enumerated()), id: \.element.id) { index, q in
                RRQuestionLine(question: q) { open(q.id) }
                    .overlay(alignment: .top) { if index > 0 { Rectangle().fill(ROC.thin).frame(height: 1).padding(.horizontal, 20) } }
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ROC.line))
    }
}

/// 逐题复盘的一行：题号、题名和一句话、已达标 / 待提升、分数；悬停时题名变蓝。
private struct RRQuestionLine: View {
    let question: MockRV.Question
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        let low = (question.score ?? 100) < MockRV.passScore
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: String(format: "%02d", question.no)).font(V3.number(12.5, weight: .medium)).foregroundStyle(ROC.faint)
                    .frame(height: 20).frame(maxHeight: .infinity, alignment: .top)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: question.title).font(V3.sans(14, weight: .medium)).foregroundStyle(hover ? ROC.blue : ROC.ink).lineHeight(14, 20)
                    if let line = question.line { Text(verbatim: line).font(V3.sans(12.5)).foregroundStyle(ROC.mute).lineHeight(12.5, 18) }
                }
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                if question.outcome != .unrecorded {
                    let reached = question.outcome == .reached
                    Text(reached ? "已达标" : "待提升").font(V3.sans(11, weight: .medium)).foregroundStyle(reached ? Color(hex: 0x15803D) : ROC.warn)
                        .padding(.horizontal, 7).padding(.vertical, 2.5).background(reached ? Color(hex: 0xECFDF3) : Color(hex: 0xFEF7EC), in: RoundedRectangle(cornerRadius: 5))
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: question.score.map(String.init) ?? "—").font(V3.number(17)).foregroundStyle(low ? ROC.low : ROC.ink)
                    Text("›").font(V3.sans(14)).foregroundStyle(Color(hex: 0xC4C0BA))
                }.frame(minWidth: 30, alignment: .trailing)
            }
            .padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 65).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .accessibilityLabel("\(question.title) · \(MockRV.outcomeText(question))")
    }
}

/// 优先强化的一张卡：题名和分数、一句建议、缺失的两点、单题练习。
private struct RRFocusCard: View {
    let question: MockRV.Question
    let practice: () -> Void
    var body: some View {
        let gaps = MockRV.gaps(question).prefix(2)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: question.title).font(V3.sans(14.5, weight: .bold)).foregroundStyle(ROC.ink).lineHeight(14.5, 20).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let score = question.score {
                    Text(verbatim: "\(score) 分").font(V3.number(13.5)).foregroundStyle(score < MockRV.passScore ? ROC.low : ROC.ink).fixedSize()
                }
            }
            Text(verbatim: MockRV.advice(question)).font(V3.sans(12.5)).foregroundStyle(ROC.sub).lineHeight(12.5, 19).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8).padding(.bottom, 22)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(verbatim: gaps.isEmpty ? "" : "缺失：\(gaps.joined(separator: " · "))").font(V3.sans(11)).foregroundStyle(ROC.faint).lineLimit(1)
                Spacer(minLength: 0)
                Button("单题练习 ›", action: practice).buttonStyle(MockLinkStyle(size: 11.5, color: ROC.blue)).fontWeight(.medium)
            }
            .padding(.top, 9).overlay(alignment: .top) { Rectangle().fill(ROC.thin).frame(height: 1) }
        }
        .padding(EdgeInsets(top: 17, leading: 19, bottom: 14, trailing: 19))
        .frame(maxWidth: .infinity, minHeight: 144, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ROC.line))
    }
}

/// 完整面试记录（Figma 09 · 07.01；Web `ReviewRecord.tsx`）：和单题复盘同一套富文本，左边按题目顺序排完整问答，只放原话不放批注；
/// 每题标题行带分数（未达标橙色）、播放这段、看复盘。右边是固定的目录，当前题展开它的考点，点哪题跳到哪题。
struct MockReviewRecord<Crumb: View>: View {
    let view: MockRV.View
    var initial: String?
    var playing: String?
    var play: ((MockRV.Question) -> Void)?
    var open: ((String) -> Void)?
    /// 再练一场：开一场新的完整模拟
    var restart: (() -> Void)?
    @ViewBuilder var crumb: () -> Crumb
    @State private var visible: String?


    var body: some View {
        let active = view.questions.firstIndex { $0.id == visible } ?? 0
        GeometryReader { geometry in
            let page = min(968, geometry.size.width - 48), wide = page >= 900
            let left = (geometry.size.width - page) / 2
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    crumb().frame(height: 20)
                    HStack(alignment: .top, spacing: 14) {
                        Text("完整面试记录").font(V3.serif(30)).fontWeight(.semibold).foregroundStyle(RQC.ink).lineHeight(30, 40, .serif)
                        Spacer(minLength: 0)
                        if let restart { Button("再练一场", action: restart).buttonStyle(MockPillStyle(kind: .ghost, height: 38, padding: 19)).padding(.top, 2) }
                    }.padding(.top, 38)
                    if !view.recordMeta.isEmpty {
                        Text(verbatim: view.recordMeta).font(V3.sans(12.5)).foregroundStyle(RQC.faint).lineHeight(12.5, 20).padding(.top, 6)
                    }
                    Rectangle().fill(RQC.rule).frame(height: 1).padding(.top, 24)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(view.questions.enumerated()), id: \.element.id) { index, q in
                            block(q)
                                .padding(.top, 28).padding(.bottom, index == view.questions.count - 1 ? 40 : 32)
                                .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Color(hex: 0xF2F1EE)).frame(height: 1) } }
                                .id(q.id)
                        }
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: 640, alignment: .leading)
                }
                .frame(width: page, alignment: .leading).frame(maxWidth: .infinity).padding(.top, 38).padding(.bottom, 20)
            }
            .scrollPosition(id: $visible, anchor: .top)
            .overlay(alignment: .topLeading) {
                if wide { toc(active).frame(width: 196).offset(x: left + 640 + 72, y: 38 + 20 + 38 + 40 + 26 + 24 + 28) }
            }
        }
        .background(.white)
        .onAppear { if let initial { DispatchQueue.main.async { visible = initial } } }
    }

    private func block(_ q: MockRV.Question) -> some View {
        let low = (q.score ?? 100) < MockRV.passScore
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: String(format: "%02d", q.no)).font(V3.number(14, weight: .medium)).foregroundStyle(RQC.faint)
                Text(verbatim: q.title).font(V3.serif(21)).fontWeight(.semibold).foregroundStyle(RQC.ink).lineHeight(21, 30, .serif).fixedSize(horizontal: false, vertical: true)
                if let score = q.score {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(verbatim: "\(score)").font(V3.number(15)).foregroundStyle(low ? ROC.low : RQC.ink)
                        Text("分").font(V3.sans(12)).foregroundStyle(RQC.mute)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 16) {
                    if let play, q.turns.contains(where: \.hasRecording) { Button(playing == q.id ? "暂停" : "播放这段") { play(q) } }
                    if let open { Button("看复盘 ›") { open(q.id) } }
                }.buttonStyle(MockLinkStyle(size: 12.5, color: RQC.mute))
            }
            .frame(minHeight: 34).padding(.bottom, -6)
            ForEach(Array(q.turns.enumerated()), id: \.element.id) { position, turn in
                VStack(alignment: .leading, spacing: 6) {
                    (Text(verbatim: MockRV.turnLabel(position)).font(V3.sans(13)).foregroundStyle(RQC.faint) + Text(verbatim: "　" + turn.ask).font(V3.sans(16, weight: .bold)).foregroundStyle(RQC.ink))
                        .lineHeight(16, 28).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: turn.answer ?? turn.missing).font(V3.sans(15)).foregroundStyle(turn.answer == nil ? RQC.faint : RQC.text).lineHeight(15, 28)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func toc(_ active: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "本场 \(view.questions.count) 题").font(V3.sans(12)).foregroundStyle(RQC.faint).frame(height: 18).padding(.bottom, 8)
            ForEach(Array(view.questions.enumerated()), id: \.element.id) { index, q in
                let on = index == active
                let points = on ? q.signals.map { $0.name ?? $0.label }.filter { !$0.isEmpty } : []
                VStack(alignment: .leading, spacing: 0) {
                    Button { withAnimation { visible = q.id } } label: {
                        HStack(spacing: 10) {
                            Text(verbatim: String(format: "%02d", q.no)).font(V3.number(12, weight: .medium)).foregroundStyle(on ? RQC.ink : RQC.faint)
                            Text(verbatim: q.title).font(V3.sans(13.5, weight: on ? .medium : .regular)).foregroundStyle(on ? RQC.ink : RQC.mute).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let score = q.score {
                                Text(verbatim: "\(score)").font(V3.number(12.5, weight: .medium)).foregroundStyle(score < MockRV.passScore ? ROC.low : RQC.faint)
                            }
                        }
                        .padding(.vertical, 5).padding(.leading, on ? 11 : 12).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    ForEach(Array(points.enumerated()), id: \.offset) { _, name in
                        Text(verbatim: name).font(V3.sans(12.5)).foregroundStyle(Color(hex: 0x6B655F)).lineLimit(1).padding(.vertical, 3).padding(.leading, 38)
                    }
                    if !points.isEmpty { Color.clear.frame(height: 4) }
                }
                .overlay(alignment: .leading) { Rectangle().fill(on ? RQC.ink : RQC.rule).frame(width: on ? 2 : 1) }
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
