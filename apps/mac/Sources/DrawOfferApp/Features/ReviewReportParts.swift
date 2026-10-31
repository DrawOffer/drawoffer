import DrawOfferCore
import SwiftUI

// 面试复盘四页里的各块（Web `ReviewReport.tsx` 的 OverviewPage、QuestionCard、RestCard、AbilityPage、NextPage）。

/// 第 1 页：左边说明面板（真实字号），右边掌握度图，底下一条地平线；图和地平线按设计稿坐标（1151 × 828）裁出来等比缩放。
struct OverviewPage: View {
    let view: MockReview.View
    let page: CGFloat
    let cardW: CGFloat
    let cardH: CGFloat
    let height: CGFloat
    let open: (String) -> Void

    private static let W = 1151.0, H = 828.0
    private static let mapBox = CGRect(x: 450, y: 0, width: 701, height: 660)
    private static let lineBox = CGRect(x: 0, y: 640, width: 1151, height: 188)

    var body: some View {
        let lineH = min(188, cardH * 0.22)
        let lineW = min(cardW, page * 1151 / 1039)
        let mainH = max(0, height - lineH)
        let mapW = max(0, page - 380 - 32)
        let missed = view.questions.contains { $0.outcome == .missed || $0.outcome == .oneShort }
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 32) {
                panel.frame(width: 380, alignment: .leading)
                    .overlay(alignment: .leading) { Rectangle().fill(missed ? RR.or : RR.blue).frame(width: 1.5).offset(x: -16) }
                if let map = MockReview.overviewMap(view.questions) {
                    figure(Self.mapBox, width: mapW, height: max(0, mainH - 16)) { mapView(map) }
                } else {
                    Text(view.questions.isEmpty ? "这场没有作答的题" : "").font(V3.sans(14)).foregroundStyle(RR.mute).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.top, 16).frame(width: page, height: mainH, alignment: .topLeading)
            figure(Self.lineBox, width: lineW, height: lineH) { QuestionLine(questions: view.questions, open: open) }
        }
        .frame(width: cardW, height: height, alignment: .top)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: view.title).font(V3.serif(26)).frame(height: 31.7, alignment: .leading)
            Text(verbatim: view.sub).font(V3.sans(12)).foregroundStyle(RR.mute).frame(height: 22, alignment: .leading).padding(.top, 4)
            if let score = view.score {
                HStack(alignment: .bottom, spacing: 8) {
                    Text("\(score)").font(V3.serif(64)).frame(height: 67.2)
                    Text("/ 100").font(V3.sans(13)).foregroundStyle(RR.mute).frame(height: 22).padding(.bottom, 12)
                    if let verdict = view.verdict {
                        let (fg, bg): (Color, Color) = verdict.tone == .blue ? (RR.blue, Color(hex: 0xEEF2FB)) : verdict.tone == .orange ? (RR.or, Color(hex: 0xFBEFE2)) : (RR.sub, Color(hex: 0xEFEDE7))
                        Text(verbatim: verdict.text).font(V3.sans(12, weight: .medium)).foregroundStyle(fg).frame(height: 22).padding(.horizontal, 7).padding(.vertical, 1)
                            .background(bg, in: RoundedRectangle(cornerRadius: 4)).padding(.leading, 8).padding(.bottom, 12)
                    }
                }.padding(.top, 8)
            }
            Text(verbatim: view.headline).font(V3.serif(17)).lineLimit(2).lineHeight(17, 25.5).padding(.top, 12).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: view.summary).font(V3.sans(12.5)).foregroundStyle(RR.sub).lineLimit(3).lineHeight(12.5, 21).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                ForEach(view.stats, id: \.label) { stat in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: stat.value).font(.system(size: 20, weight: .medium)).foregroundStyle(stat.orange ? RR.or : RR.ink).frame(height: 22)
                        Text(verbatim: stat.label).font(V3.sans(11)).foregroundStyle(RR.mute).frame(height: 22)
                    }.frame(width: 118, alignment: .leading)
                }
            }.padding(.top, 24).padding(.bottom, 12)
        }
    }

    private func mapView(_ map: MockReview.OverviewMap) -> some View {
        let layout = MockLayout.overviewLayout(points: map.points, sectors: map.sectors, path: map.path, rotation: 0, targetLevel: view.target, targetLabel: view.targetLabel)
        return MasteryMapView(width: Self.W, height: Self.H, g: MockLayout.overview.at, points: map.points, sectors: map.sectors, targetLevel: view.target, targetLabel: view.targetLabel,
                              center: nil, path: map.path, bounds: map.bounds, labels: layout.labels, sectorLabels: layout.sectors, labelOnly: map.hot,
                              noGap: true, dashed: false, plain: true, onPoint: open)
    }

    /// 设计稿坐标里的一块：裁出 box 这一块，按留给它的格子等比缩放并居中。
    private func figure<Content: View>(_ box: CGRect, width: CGFloat, height: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        let scale = max(0.01, min(width / box.width, height / box.height))
        return content()
            .frame(width: Self.W, height: Self.H, alignment: .topLeading)
            .offset(x: -box.minX, y: -box.minY)
            .frame(width: box.width, height: box.height, alignment: .topLeading)
            .clipped()
            .scaleEffect(scale, anchor: .center)
            .frame(width: width, height: height)
    }
}

/// 总览下方的地平线：按提问顺序一颗珠子一道题，追问是小一号的珠子；点珠子看这一题。
struct QuestionLine: View {
    let questions: [MockReview.Question]
    let open: (String) -> Void
    private let width = 1151.0, top = 690.0

    var body: some View {
        let arc = MockMap.arcY(width: width, top: top)
        let x0 = 120.0, x1 = 1030.0
        let xs = questions.indices.map { x0 + (x1 - x0) * (Double($0) + 0.5) / Double(max(1, questions.count)) }
        let limit = questions.count > 10 ? 4 : questions.count > 7 ? 6 : 8
        ZStack(alignment: .topLeading) {
            HorizonBase(width: width, top: top, height: 828)
            Canvas { context, _ in
                for (index, q) in questions.enumerated() {
                    let x = xs[index], y = arc(x), small = q.followUp, color = RR.tone(q)
                    if q.outcome == .unrecorded {
                        let r = small ? 4.5 : 6.5, c = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                        context.fill(c, with: .color(.white)); context.stroke(c, with: .color(MI.gry), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    } else {
                        let r = small ? 4.5 : 7.0, c = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                        context.fill(c, with: .color(q.outcome == .oneShort ? .white : color))
                        if q.outcome == .oneShort { context.stroke(c, with: .color(color), lineWidth: 2) }
                    }
                }
            }.frame(width: width, height: 828).allowsHitTesting(false)
            ForEach(Array(questions.enumerated()), id: \.element.id) { index, q in
                let x = xs[index], y = arc(x)
                let name = Array(q.title)
                let color = q.outcome == .missed || q.outcome == .oneShort ? RR.or : q.outcome == .unrecorded ? MI.gry : RR.sub
                Button { open(q.id) } label: {
                    Text(verbatim: name.count > limit ? String(name.prefix(limit)) + "…" : q.title).font(V3.sans(11)).foregroundStyle(color).frame(height: 22)
                        .frame(height: 40, alignment: .top).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("\(q.title) · \(MockReview.outcomeText(q))")
                .pin(x, y - 32, align: .center)
            }
            MapLabel(text: "← 按提问顺序 · 小珠子是追问", size: 10.5, color: MI.mute).pin(56, arc(56) + 22)
        }
        .frame(width: width, height: 828, alignment: .topLeading)
    }
}

/// 卡片上半部的五级台阶：“你”站在答到的那一级，下一级虚线是没接住，蓝旗是面试官想听到的那一级。
struct ReviewSteps: View {
    let question: MockReview.Question
    var body: some View {
        let level = Int(question.level ?? 0), color = RR.tone(question)
        let stuck = question.outcome != .reached && question.level != nil ? min(5, level + 1) : nil
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(0..<5, id: \.self) { index in
                let step = index + 1, filled = step <= level, isStuck = step == stuck
                let shape = RoundedRectangle(cornerRadius: 10)
                ZStack(alignment: .topLeading) {
                    shape.fill(filled ? color : .white.opacity(isStuck ? 0.55 : 0.72))
                    if isStuck { shape.strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])) }
                    if isStuck { Text("✕ 没接住").font(V3.sans(12)).foregroundStyle(color).frame(height: 22).offset(x: 10, y: 8 - 9) }
                    Text(verbatim: MockMap.levels[index]).font(V3.sans(13, weight: .medium)).foregroundStyle(filled ? .white : isStuck ? color : RR.mute)
                        .frame(height: 22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(.leading, 12).padding(.bottom, 8 - 4)
                }
                .frame(height: CGFloat(32 + index * 20))
                .overlay(alignment: .top) {
                    ZStack(alignment: .top) {
                        if step == level {
                            Text("你").font(V3.sans(12, weight: .medium)).foregroundStyle(.white).frame(width: 24, height: 24).background(RR.ink, in: Circle()).offset(y: -32)
                        }
                        if step == Int(question.expected) {
                            GeometryReader { g in
                                ZStack(alignment: .topLeading) {
                                    Rectangle().fill(RR.blue).frame(width: 2, height: 46)
                                    UnevenRoundedRectangle(topLeadingRadius: 1, bottomLeadingRadius: 1, bottomTrailingRadius: 3, topTrailingRadius: 3).fill(RR.blue).frame(width: 16, height: 11).offset(x: 2)
                                    Text("面试官想听到").font(V3.sans(12)).foregroundStyle(RR.blue).frame(height: 22).fixedSize().frame(width: 0, alignment: .trailing).offset(x: -8, y: -3)
                                }.offset(x: g.size.width * 0.22, y: -46)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct QuestionCard: View {
    let question: MockReview.Question
    /// 气泡最宽占卡片正文的 80%。
    var bubbleMax: CGFloat = 544
    let open: (String) -> Void
    let practice: ([MockReview.Question]) -> Void

    var body: some View {
        let color = RR.tone(question)
        let meta = ["第 \(question.no) 题", question.followUp ? question.parentNo.map { "第 \($0) 题的追问" } ?? "追问" : "主问题",
                    question.follows > 0 ? "被追问 \(question.follows) 次" : nil].compactMap { $0 }.joined(separator: "  ·  ")
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                (question.outcome == .oneShort ? Color(hex: 0xFBF5E3) : Color(hex: 0xFBF1E6))
                HStack(spacing: 10) {
                    Text(verbatim: MockReview.outcomeText(question)).font(V3.sans(13, weight: .medium)).foregroundStyle(.white).frame(height: 22).padding(.horizontal, 10).padding(.vertical, 2).background(color, in: RoundedRectangle(cornerRadius: 10))
                    Text(verbatim: meta).font(V3.sans(13)).foregroundStyle(RR.sub)
                }.padding(.leading, 40).padding(.top, 28)
                if let score = question.score {
                    HStack(alignment: .bottom, spacing: 6) {
                        Text("\(score)").font(.system(size: 52, weight: .semibold)).foregroundStyle(color).frame(height: 52)
                        Text("/ 100").font(V3.sans(14)).foregroundStyle(RR.mute).frame(height: 22).padding(.bottom, 4)
                    }.frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 40).padding(.top, 18)
                }
                ReviewSteps(question: question).padding(.horizontal, 40).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 24)
            }.frame(height: 224)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: question.title).font(V3.sans(24, weight: .bold)).lineLimit(1).frame(height: 34).padding(.bottom, 10)
                    Text("面试官").font(V3.sans(12)).foregroundStyle(RR.mute).frame(height: 22).padding(.leading, 8).padding(.bottom, 4)
                    bubble(question.ask, fg: RR.ink, bg: Color(hex: 0xF2F1EE), trailing: false)
                    if let answer = question.answer, !answer.isEmpty {
                        bubble(answer, fg: .white, bg: RR.blue, trailing: true, limit: 4).padding(.top, 10)
                    } else {
                        bubble(question.note ?? "没记下回答", fg: RR.mute, bg: .clear, trailing: true, dashed: Color(hex: 0xCFCABD)).padding(.top, 10)
                    }
                    if let better = question.better {
                        Text("换个说法 · 该说到这").font(V3.sans(12)).foregroundStyle(RR.blue).frame(height: 22).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 8).padding(.top, 10).padding(.bottom, 4)
                        bubble(better, fg: RR.ink, bg: Color(hex: 0xF3F6FD), trailing: true, dashed: RR.blue)
                    }
                }.padding(.horizontal, 40).padding(.top, 22).padding(.bottom, 16)
            }.scrollIndicators(.automatic)
            HStack {
                Button("看完整问答 ›") { open(question.id) }.buttonStyle(RRLinkStyle())
                Spacer()
                Button("练这一题") { practice([question]) }.buttonStyle(RRButtonStyle())
            }.padding(.horizontal, 40).frame(height: 70)
        }
    }

    private func bubble(_ text: String, fg: Color, bg: Color, trailing: Bool, limit: Int? = nil, dashed: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        return HStack {
            if trailing { Spacer(minLength: 0) }
            Text(verbatim: text).font(V3.sans(14.5)).foregroundStyle(fg).lineLimit(limit).lineSpacing(22 - 14.5 * 1.2).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 9 + (22 - 14.5 * 1.2) / 2)
                .background(bg, in: shape)
                .overlay { if let dashed { shape.strokeBorder(dashed, style: StrokeStyle(lineWidth: bg == .clear ? 1 : 1.5, dash: [5, 3])) } }
                .frame(maxWidth: bubbleMax, alignment: trailing ? .trailing : .leading)
            if !trailing { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}

struct MiniSteps: View {
    let level: Double?
    let color: Color
    var expected: Double? = nil
    var dashed = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1...5, id: \.self) { step in
                let on = level.map { Double(step) <= $0 } ?? false
                let goal = expected.map { Double(step) == $0 && (level == nil || Double(step) > level!) } ?? false
                let shape = RoundedRectangle(cornerRadius: 2)
                shape.fill(dashed ? .clear : on ? color : goal ? .clear : Color(hex: 0xE4E2DC))
                    .overlay { if dashed { shape.strokeBorder(Color(hex: 0xCFCABD), style: StrokeStyle(lineWidth: 1, dash: [2, 2])) } else if goal { shape.strokeBorder(RR.blue, lineWidth: 1.5) } }
                    .frame(width: 10, height: CGFloat(6 + (step - 1) * 5))
            }
        }.accessibilityHidden(true)
    }
}

struct RestCard: View {
    let questions: [MockReview.Question]
    let open: (String) -> Void
    let next: () -> Void

    var body: some View {
        let reached = questions.filter { $0.outcome == .reached }
        let parts = [reached.filter(\.layered).isEmpty ? nil : "\(reached.filter(\.layered).count) 道答到位",
                     reached.filter { !$0.layered }.isEmpty ? nil : "\(reached.filter { !$0.layered }.count) 道说清了",
                     questions.contains { $0.outcome == .unrecorded } ? "\(questions.filter { $0.outcome == .unrecorded }.count) 道没记下" : nil].compactMap { $0 }.joined(separator: "  ·  ")
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(hex: 0xF1F5FD)
                VStack(alignment: .leading, spacing: 10) {
                    Text("其余 \(questions.count) 道").font(V3.sans(26, weight: .bold)).frame(height: 22)
                    Text(verbatim: parts).font(V3.sans(13.5)).foregroundStyle(RR.sub).frame(height: 22)
                }.padding(.leading, 40).padding(.top, 32)
                HStack(alignment: .bottom, spacing: 6) {
                    Text("\(reached.count)").font(.system(size: 52, weight: .semibold)).frame(height: 52)
                    Text("道答到位").font(V3.sans(13.5, weight: .medium)).frame(height: 22).padding(.bottom, 4)
                }.foregroundStyle(RR.blue).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 40).padding(.top, 42)
            }.frame(height: 132)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(questions, id: \.id) { item in
                        Button { open(item.id) } label: { cell(item) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 16)
            }
            HStack {
                Text("点一格进那道题").font(V3.sans(13)).foregroundStyle(RR.mute).frame(height: 22)
                Spacer()
                Button("往下看能力表现 ↓", action: next).buttonStyle(RRButtonStyle(blue: true))
            }.padding(.horizontal, 40).frame(height: 70)
        }
    }

    private func cell(_ item: MockReview.Question) -> some View {
        let empty = item.outcome == .unrecorded
        let shape = RoundedRectangle(cornerRadius: 14)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(RR.pad(item.no)).font(V3.sans(12.5)).foregroundStyle(RR.mute).frame(height: 22)
                Spacer()
                MiniSteps(level: item.level, color: item.layered ? RR.blue : Color(hex: 0xCDDCF5), dashed: empty).padding(.top, -2)
            }
            Text(verbatim: empty ? "没记下" : !item.layered || item.score == nil ? MockReview.outcomeText(item) : "\(item.score!)")
                .font(.system(size: empty ? 20 : 30, weight: .semibold)).foregroundStyle(empty ? RR.mute : RR.ink).frame(height: 36).padding(.top, 30)
            Text(verbatim: item.title).font(V3.sans(13)).foregroundStyle(RR.sub).lineLimit(2).lineHeight(13, 19).padding(.top, 12)
            Spacer(minLength: 0)
        }
        .padding(16).frame(height: 160).frame(maxWidth: .infinity, alignment: .leading)
        .background(empty ? .white : Color(hex: 0xF5F5F2), in: shape)
        .overlay { if empty { shape.strokeBorder(Color(hex: 0xD9D6CD), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) } }
        .contentShape(shape)
        .accessibilityElement().accessibilityLabel("\(RR.pad(item.no)) \(item.title) · \(MockReview.outcomeText(item))")
    }
}

/// 第 3 页的能力台阶：5 级 × 45，横向每项一列、平分页面宽度（最宽 172）。
struct AbilityChart: View {
    let rows: [MockReview.Dimension]
    let selected: String?
    let page: CGFloat
    let pick: (String) -> Void
    private let base: CGFloat = 433, pitch: CGFloat = 45

    var body: some View {
        let colW = min(page / CGFloat(max(1, rows.count)), 172)
        ZStack(alignment: .top) {
            ZStack(alignment: .topLeading) {
                ForEach(1...5, id: \.self) { step in Rectangle().fill(Color(hex: 0xECEBE6)).frame(height: 1).offset(y: base - CGFloat(step) * pitch) }
                Rectangle().fill(Color(hex: 0xC9C5BB)).frame(height: 1.5).offset(y: 434 - 1.5)
            }.frame(width: page, height: 434, alignment: .topLeading).allowsHitTesting(false)
            HStack(spacing: 0) {
                ForEach(rows, id: \.key) { item in column(item, width: colW) }
            }
        }.frame(width: page, height: 520, alignment: .top)
    }

    private func column(_ item: MockReview.Dimension, width: CGFloat) -> some View {
        let on = item.key == selected, weak = (item.steps ?? 5) <= 2
        let fill = weak ? RR.or : on ? RR.blue : Color(hex: 0xA9BDF0)
        let steps = item.steps ?? 0, blockW = min(112, width - 16)
        return Button { pick(item.key) } label: {
            ZStack(alignment: .top) {
                Color.white.opacity(0.001)
                if item.assessed {
                    ForEach(0..<steps, id: \.self) { step in
                        RoundedRectangle(cornerRadius: 9).fill(fill).frame(width: blockW, height: 40).offset(y: base - CGFloat(step + 1) * pitch + 5)
                    }
                    if let score = item.score {
                        (Text("\(score)").font(.system(size: 30, weight: .semibold)) + Text("/\(item.max)").font(V3.sans(13)).foregroundColor(RR.mute))
                            .foregroundStyle(weak ? RR.or : RR.blue).frame(height: 29).offset(y: base - CGFloat(steps) * pitch - 44)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(Color(hex: 0xD9D6CD), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])).frame(width: blockW, height: 40).offset(y: base - pitch + 5)
                }
                if on { Rectangle().fill(RR.ink).frame(width: blockW, height: 3).offset(y: 432) }
                Text(verbatim: item.label).font(V3.sans(15, weight: on ? .semibold : .regular)).foregroundStyle(on ? RR.ink : item.assessed ? RR.sub : RR.mute)
                    .lineLimit(1).frame(width: width, height: 22).offset(y: 448)
                if !item.assessed {
                    Text("不评").font(V3.sans(12)).foregroundStyle(RR.mute).frame(height: 22).padding(.horizontal, 8).padding(.vertical, 1).background(Color(hex: 0xF2F1EE), in: Capsule()).offset(y: 478)
                }
                if on { Rectangle().fill(Color(hex: 0xB9B5AA)).frame(width: 1, height: 14).offset(y: 506) }
            }.frame(width: width, height: 520, alignment: .top).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.score.map { "\($0)/\(item.max) \(item.label)" } ?? "\(item.label) 不评")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 第 4 页的路线：几站平分宽度、终点一列固定；每站从自己的圆点画线到下一列，最后一站画蓝色虚线到终点旗。
struct NextRoute: View {
    let items: [MockReview.Action]
    let next: NextInterview?
    let open: (Int) -> Void
    let action: (MockReview.Action) -> Void
    let toggleDone: ((Int) -> Void)?

    var body: some View {
        GeometryReader { g in
            let gap: CGFloat = 40, goal: CGFloat = 150
            let stopW = (g.size.width - goal - gap * CGFloat(items.count)) / CGFloat(max(1, items.count))
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let x = CGFloat(index) * (stopW + gap)
                    let last = index == items.count - 1
                    Path { p in p.move(to: CGPoint(x: x + 36, y: 18)); p.addLine(to: CGPoint(x: x + stopW + gap, y: 18)) }
                        .stroke(last ? RR.blue : Color(hex: 0xD9D6CD), style: StrokeStyle(lineWidth: last ? 2 : 1.5, dash: last ? [6, 4] : []))
                    stop(item, index: index).frame(width: stopW, alignment: .leading).offset(x: x)
                }
                let gx = CGFloat(items.count) * (stopW + gap)
                Path { p in p.move(to: CGPoint(x: gx, y: 18)); p.addLine(to: CGPoint(x: gx + goal, y: 18)) }.stroke(RR.blue, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                ZStack(alignment: .topTrailing) {
                    Rectangle().fill(RR.blue).frame(width: 2, height: 56).offset(y: -38)
                    UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4, bottomTrailingRadius: 1, topTrailingRadius: 1).fill(RR.blue).frame(width: 24, height: 16).offset(x: -2, y: -38)
                    Circle().fill(RR.blue).frame(width: 8, height: 8).offset(x: 3, y: 14)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(verbatim: next?.label ?? "下一场面试").font(V3.sans(20, weight: .bold)).frame(height: 28)
                        Text(verbatim: next?.date ?? "还没安排").font(V3.sans(13)).foregroundStyle(RR.sub).frame(height: 22).padding(.top, 4)
                        if let next { Text(verbatim: next.days <= 0 ? "就是今天" : "还有 \(next.days) 天").font(V3.sans(13)).foregroundStyle(RR.blue).padding(.top, 2) }
                    }.padding(.top, 66)
                }.frame(width: goal, alignment: .topTrailing).offset(x: gx)
            }
        }.frame(height: 290)
    }

    private func stop(_ item: MockReview.Action, index: Int) -> some View {
        let label = item.kind == "resume" ? "打开简历去改" : item.kind == "material" ? "去资料库" : item.refs.isEmpty ? "再练一场" : "练这 \(item.refs.count) 题"
        let dotFill: Color = item.done ? Color(hex: 0xB9B5AA) : item.key ? RR.or : .white
        let dotStroke: Color = item.done ? Color(hex: 0xB9B5AA) : item.key ? RR.or : RR.blue
        return VStack(alignment: .leading, spacing: 0) {
            Text(item.done ? "✓" : "\(index + 1)").font(V3.sans(15, weight: .semibold)).foregroundStyle(item.done || item.key ? .white : RR.blue)
                .frame(width: 36, height: 36).background(dotFill, in: Circle()).overlay(Circle().strokeBorder(dotStroke, lineWidth: 2))
            Text(item.key ? "优先建议" : "可以试试").font(V3.sans(12)).foregroundStyle(item.key ? RR.or : RR.blue).frame(height: 22).padding(.horizontal, 8).padding(.vertical, 1)
                .background(item.key ? Color(hex: 0xFBEFE2) : Color(hex: 0xEEF2FB), in: RoundedRectangle(cornerRadius: 8)).padding(.top, 30)
            Text(verbatim: item.title).font(V3.sans(20, weight: .bold)).foregroundStyle(item.done ? RR.mute : RR.ink).strikethrough(item.done, color: RR.mute)
                .lineHeight(20, 30).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            if let detail = item.detail {
                Text(verbatim: detail).font(V3.sans(14.5)).foregroundStyle(RR.sub).lineLimit(6).lineHeight(14.5, 25).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text("来源").font(V3.sans(12.5)).foregroundStyle(RR.mute)
                if item.refs.isEmpty { Text("整场").font(V3.sans(12.5)).foregroundStyle(RR.mute).padding(.horizontal, 6).background(Color(hex: 0xF2F1EE), in: Capsule()) }
                ForEach(item.refs, id: \.self) { no in
                    Button { open(no) } label: {
                        Text(RR.pad(no)).font(V3.sans(12.5, weight: .medium)).foregroundStyle(RR.or).frame(height: 20).padding(.horizontal, 8).background(Color(hex: 0xFBEFE2), in: Capsule())
                    }.buttonStyle(.plain)
                }
            }.frame(height: 22).padding(.top, 12)
            HStack(spacing: 16) {
                Button("\(label) ›") { action(item) }.buttonStyle(RRLinkStyle())
                if let toggleDone {
                    Button(item.done ? "已做完" : "标记做完") { toggleDone(index) }.buttonStyle(RRLinkStyle(sub: true))
                        .accessibilityAddTraits(item.done ? .isSelected : [])
                }
            }.padding(.top, 14)
        }
    }
}
