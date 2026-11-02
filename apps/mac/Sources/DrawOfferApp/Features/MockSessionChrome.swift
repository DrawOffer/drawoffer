import Foundation
import DrawOfferCore
import AppKit
import SwiftUI

/// 面试中全屏画面的共用部件（Web `mock-interview/v2/SessionChrome.tsx`）：顶栏、右侧「这一场」的图、地平线上的题目珠子、
/// 底栏、面试官在记、回答区、对话记录抽屉和确认弹窗。画面固定 1368 × 828，整体等比缩放。
enum MockFull {
    static let width: CGFloat = 1368
    static let height: CGFloat = 828
}

/// 场次画面的外框：没有侧栏，按设计尺寸缩放。
struct SessionFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        MockStage(width: MockFull.width, height: MockFull.height) {
            ZStack(alignment: .topLeading) { content() }.frame(width: MockFull.width, height: MockFull.height, alignment: .topLeading)
        }
    }
}

/// `.mi2-stop`：顶栏（左标题、中间进度、右计时与操作）。
struct SessionTop: View {
    let title: String
    let sub: String
    let center: String
    var started: Date? = nil
    var ended: Date? = nil
    var timerLive = true
    var onAbandon: (() -> Void)? = nil
    var onFinish: (() -> Void)? = nil
    var finishDisabled = false
    var busy = false
    var exit: (label: String, action: () -> Void)? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(V3.sans(13.5, weight: .medium)).foregroundStyle(MI.ink).frame(height: 13.5 * 1.3)
                Text(verbatim: sub).font(V3.sans(11.5)).foregroundStyle(MI.mute).frame(height: 11.5 * 1.3)
            }.offset(x: 36, y: 22)
            Text(verbatim: center).font(V3.sans(12)).foregroundStyle(MI.sub).frame(height: 12 * 1.4).pin(684, 30, align: .center)
                .accessibilityAddTraits(.updatesFrequently)
            HStack(spacing: 16) {
                if let started {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 6) {
                            Circle().fill(timerLive ? MI.orange : MI.gry).frame(width: 7, height: 7).modifier(MockPulse(on: timerLive))
                            Text(verbatim: MockSession.mmss((ended ?? context.date).timeIntervalSince(started)))
                                .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(MI.sub)
                        }
                    }
                }
                if let onAbandon { Button("放弃", action: onAbandon).buttonStyle(.plain).font(V3.sans(12.5)).foregroundStyle(MI.mute).disabled(busy) }
                if let onFinish { Button("结束并评估", action: onFinish).buttonStyle(MockButtonStyle()).disabled(finishDisabled || busy) }
                if let exit { Button(exit.label, action: exit.action).buttonStyle(.plain).font(V3.sans(12.5)).foregroundStyle(MI.sub) }
            }
            .frame(height: 29).fixedSize()
            .frame(width: 0, alignment: .trailing).offset(x: MockFull.width - 36, y: 22)
        }
        .frame(width: MockFull.width, height: 71, alignment: .topLeading)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xE8E5DE)).frame(height: 1) }
    }
}

/// `.mi2-pulse`：1.8 秒一呼一吸。
struct MockPulse: ViewModifier {
    var on = true
    @State private var dim = false
    func body(content: Content) -> some View {
        content.opacity(on && dim ? 0.35 : 1)
            .onAppear { guard on else { return }; withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true } }
    }
}

/// 作答时当前这题跟着你呼吸：说话时外圈按音量荡开，停顿时收回成一圈虚线，打字时每敲一阵跳一下。
enum MapListen: Equatable {
    case speaking(Double), paused, idle
    case typing(Int)
}

/// `SessionMapView`：「这一场」的图。当前这题转到左边；换题时整张图慢慢转过去。
struct SessionMapView: View {
    let map: MockSession.Map
    let targetLevel: Double
    var caption = true
    var center = "这一场"
    var labelAll = false
    var listen: MapListen? = nil

    @State private var shownRotation: Double?
    @State private var beatScale: CGFloat = 1
    @State private var beatOpacity: Double = 0

    @State private var tween: Task<Void, Never>?

    private var g: MockMap.Geo { MockLayout.session.at }

    static func turn(_ map: MockSession.Map, by delta: Double) -> MockSession.Map {
        guard delta != 0 else { return map }
        var turned = map
        turned.points = map.points.map { var p = $0; p.angle += delta; return p }
        turned.sectors = map.sectors.map { MockMap.Sector(name: $0.name, angle: $0.angle + delta) }
        turned.bounds = map.bounds?.map { $0 + delta }
        return turned
    }

    var body: some View {
        let turned = Self.turn(map, by: (shownRotation ?? map.rotation) - map.rotation)
        let layout = MockSession.layout(turned, targetLevel: targetLevel, labelAll: labelAll)
        let placed = MockMap.place(g, turned.points)
        let nowAt = placed.first { $0.point.id == map.now }
        let notes = map.bounds != nil ? Array(map.annotations.suffix(1)) : map.annotations
        let slotted = map.bounds != nil
        ZStack(alignment: .topLeading) {
            MasteryMapView(width: MockFull.width, height: MockFull.height, g: g, points: turned.points, sectors: turned.sectors, targetLevel: targetLevel, targetLabel: nil,
                           center: center, path: map.path, bounds: turned.bounds, labels: layout?.labels, sectorLabels: layout?.sectors,
                           labelOnly: slotted ? (labelAll ? nil : map.now.map { [$0] } ?? []) : labelAll ? nil : (map.hot.isEmpty ? [] : map.hot),
                           noGap: true, dashed: false, now: map.now, hot: !slotted && !map.hot.isEmpty ? map.hot : nil, noLinks: !slotted, badges: slotted)
            if let listen, let nowAt { breath(listen, nowAt.x, nowAt.y) }
            if let nowAt, let place = layout?.labels[nowAt.point.id] {
                let align: HorizontalAlignment = place.align == .right ? .trailing : place.align == .center ? .center : .leading
                ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                    MapLabel(text: note.text, size: 10, color: note.tone == .orange ? MI.orange : MI.blue, weight: .medium)
                        .pin(place.x, place.box.t + 17 * Double(place.lines) + 1 + Double(index) * MockLayout.noteLine, align: align)
                }
            }
            if caption { MapLabel(text: "这一场的图：当前这题转到左边，往圆心走一圈就是追问深一层", size: 10.5, color: MI.mute).pin(893, 590) }
        }
        .frame(width: MockFull.width, height: MockFull.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .onAppear { shownRotation = map.rotation }
        .onChange(of: map.rotation) { _, value in
            // 先加速再减速（三次缓动），1.1 秒转到新的一题；减少动态效果时直接到位
            tween?.cancel()
            let from = shownRotation ?? value
            guard from != value, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { shownRotation = value; return }
            let start = Date()
            tween = Task { @MainActor in
                while !Task.isCancelled {
                    let t = min(1, Date().timeIntervalSince(start) / 1.1)
                    let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
                    shownRotation = from + (value - from) * eased
                    if t >= 1 { break }
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        }
        .onDisappear { tween?.cancel() }
        .onChange(of: listen) { _, value in
            if case .typing(let beat) = value, beat > 0 {
                beatScale = 1; beatOpacity = 0.7
                withAnimation(.easeOut(duration: 0.6)) { beatScale = 1.3; beatOpacity = 0 }
            }
        }
    }

    @ViewBuilder private func breath(_ listen: MapListen, _ x: Double, _ y: Double) -> some View {
        switch listen {
        case .typing:
            Circle().stroke(MI.blue, lineWidth: 1.2).frame(width: 48, height: 48).scaleEffect(beatScale).opacity(beatOpacity).offset(x: x - 24, y: y - 24)
        case .speaking(let level):
            let amp = min(1, max(0, (level - 0.05) / 0.55))
            ForEach(0..<3, id: \.self) { index in
                let r = amp > 0 ? 24 + Double(index + 1) * (7 + 13 * amp) : 24
                Circle().stroke(MI.blue.opacity(amp > 0 ? (0.6 - Double(index) * 0.18) * (0.4 + 0.6 * amp) : 0), lineWidth: index == 0 ? 1.3 : 1)
                    .frame(width: r * 2, height: r * 2).offset(x: x - r, y: y - r).animation(.easeOut(duration: 0.18), value: r)
            }
        case .paused:
            Circle().stroke(MI.blue.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [2, 3])).frame(width: 42, height: 42).offset(x: x - 21, y: y - 21)
        case .idle: EmptyView()
        }
    }
}

/// 面试中的地平线：开场 → 每道主问题一颗珠子（上方的小点是追问）→ 结束。
struct SessionHorizonView: View {
    let beads: [MockSession.Bead]
    let introNow: Bool
    var ended = false
    private let top = 646.0
    private var arc: (Double) -> Double { MockMap.arcY(width: MockFull.width, top: top) }

    var body: some View {
        let xs = MockSession.beadXs(beads.count)
        ZStack(alignment: .topLeading) {
            HorizonBase(width: MockFull.width, top: top, height: MockFull.height)
            Canvas { context, _ in
                func dot(_ x: Double, _ y: Double, _ r: Double) -> Path { Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }
                context.fill(dot(200, arc(200), 5), with: .color(introNow ? MI.blue : MI.ink))
                context.fill(dot(1180, arc(1180), 5), with: .color(ended ? MI.ink : .white))
                if !ended { context.stroke(dot(1180, arc(1180), 5), with: .color(MI.gry), lineWidth: 1) }
                for (index, bead) in beads.enumerated() {
                    let x = xs[index], y = arc(x)
                    let color: Color = bead.state == .now ? MI.blue : bead.state == .done ? (bead.miss ? MI.orange : MI.ink) : MI.gry
                    for j in 0..<bead.followUps {
                        let last = bead.state == .now && j == bead.followUps - 1
                        context.fill(dot(x, y - 18 - Double(j) * 11, 3), with: .color((last ? MI.blue : color).opacity(bead.state == .todo ? 0.4 : 1)))
                    }
                    switch bead.state {
                    case .now:
                        context.fill(dot(x, y, 15), with: .color(MI.blue.opacity(0.12)))
                        context.fill(dot(x, y, 8), with: .color(MI.blue))
                    case .done: context.fill(dot(x, y, 7), with: .color(color))
                    case .skip:
                        context.fill(dot(x, y, 7), with: .color(.white)); context.stroke(dot(x, y, 7), with: .color(MI.gry), lineWidth: 1)
                        var cross = Path(); cross.move(to: CGPoint(x: x - 5, y: y + 5)); cross.addLine(to: CGPoint(x: x + 5, y: y - 5))
                        context.stroke(cross, with: .color(MI.gry), lineWidth: 1)
                    case .todo:
                        context.fill(dot(x, y, 6), with: .color(.white)); context.stroke(dot(x, y, 6), with: .color(MI.gry), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
            }.frame(width: MockFull.width, height: MockFull.height)
            MapLabel(text: "开场", size: 10.5, color: MI.mute).pin(200, arc(200) + 12, align: .center)
            MapLabel(text: "结束", size: 10.5, color: MI.mute).pin(1180, arc(1180) + 12, align: .center)
            ForEach(Array(beads.enumerated()), id: \.offset) { index, bead in
                MapLabel(text: "Q\(index + 1) \(bead.title)", size: 11, color: bead.state == .now ? MI.blue : bead.state == .todo ? MI.gry : MI.sub, weight: bead.state == .now ? .medium : .regular)
                    .pin(xs[index], arc(xs[index]) + 14, align: .center)
            }
        }
        .frame(width: MockFull.width, height: MockFull.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// `.mi2-sbottom`：底栏（左跳过此题 · 中间状态 · 右操作与对话记录）。
struct SessionBottom<Action: View>: View {
    var left: String? = nil
    var onLeft: () -> Void = {}
    var leftDisabled = false
    var status: String? = nil
    var statusTone: MockTone = .sub
    var dot: Color? = MI.blue
    var right: String? = nil
    var onRight: () -> Void = {}
    @ViewBuilder var action: () -> Action

    var body: some View {
        ZStack {
            HStack {
                if let left { Button(left, action: onLeft).buttonStyle(MockQuietStyle()).disabled(leftDisabled) }
                Spacer()
                HStack(spacing: 20) {
                    action()
                    if let right { Button(right, action: onRight).buttonStyle(MockQuietStyle()) }
                }
            }
            if let status {
                HStack(spacing: 7) {
                    if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                    Text(verbatim: status).font(V3.sans(12.5, weight: .medium)).foregroundStyle(statusTone == .sub ? MI.sub : statusTone.color).lineLimit(1)
                }
                .frame(height: 18).padding(.horizontal, 15).padding(.vertical, 8)
                .background(.white, in: Capsule()).overlay(Capsule().stroke(MI.line)).fixedSize()
                .accessibilityElement(children: .combine).accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(width: MockFull.width - 112, height: 36).offset(x: 56, y: 770)
    }
}

extension SessionBottom where Action == EmptyView {
    init(left: String? = nil, onLeft: @escaping () -> Void = {}, leftDisabled: Bool = false, status: String? = nil, statusTone: MockTone = .sub, dot: Color? = MI.blue, right: String? = nil, onRight: @escaping () -> Void = {}) {
        self.init(left: left, onLeft: onLeft, leftDisabled: leftDisabled, status: status, statusTone: statusTone, dot: dot, right: right, onRight: onRight, action: { EmptyView() })
    }
}

/// `.mi2-sbottom-side` / `.mi2-stop-quiet`：灰色小字按钮，不可用时更浅。
struct MockQuietStyle: ButtonStyle {
    var size: CGFloat = 12.5
    var color: Color = MI.sub
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(size)).foregroundStyle(enabled ? (configuration.isPressed ? MI.ink : color) : Color(hex: 0xC5C1B6)).contentShape(Rectangle())
    }
}

/// `Speaker`：「面试官 · 提问」一行，前面一个小圆点。
struct MockSpeaker: View {
    enum Tone { case blue, or, gry, ink }
    let you: Bool
    let text: String
    var tone: Tone = .blue
    var live = false
    var body: some View {
        let fg: Color = tone == .blue ? MI.blue : tone == .gry ? MI.gry : MI.ink
        let dot: Color = tone == .or ? MI.orange : tone == .gry ? Color(hex: 0xC5C1B6) : fg
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7).modifier(MockPulse(on: live))
            Text(verbatim: "\(you ? "你" : "面试官") · \(text)").font(V3.sans(12)).foregroundStyle(fg)
        }.frame(height: 12 * 1.4)
    }
}

/// `SourceChip`：题目从哪来（简历 / 岗位要求 / 资料）。
struct MockSourceChip: View {
    let label: String
    let quote: String
    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: label).font(V3.sans(10.5, weight: .medium)).foregroundStyle(MI.blue).padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color(hex: 0xEEF2FB), in: RoundedRectangle(cornerRadius: 4)).fixedSize()
            Text(verbatim: "「\(quote)」").font(V3.sans(12)).foregroundStyle(MI.sub).lineLimit(1).truncationMode(.tail)
        }.frame(height: 22)
    }
}

/// `.mi2-question`：题目正文，引用的原话蓝色，还没「打」出来的字浅灰。
struct MockQuestionText: View {
    let text: String
    var quote: String? = nil
    var shown: Int = .max
    var size: CGFloat = 23
    var line: CGFloat = 34
    var small = false
    var body: some View {
        let chars = Array(text)
        let visible = String(chars.prefix(min(shown, chars.count)))
        let rest = shown < chars.count ? String(chars[shown...]) : ""
        let parts = MockSession.splitQuoted(visible, quote)
        let base = small ? MI.sub : MI.ink
        let content = (parts.map { Text(verbatim: $0.before).foregroundColor(base) + Text(verbatim: $0.quote).foregroundColor(MI.blue) + Text(verbatim: $0.after).foregroundColor(base) }
                       ?? Text(verbatim: visible).foregroundColor(base)) + Text(verbatim: rest).foregroundColor(Color(hex: 0xC5C1B6))
        let lineHeight = small ? 22 : line, fontSize = small ? 14 : size
        // CSS 行高：行距之外，首行上、末行下各有半个行距
        content.font(small ? V3.sans(14) : V3.serif(size)).lineSpacing(max(0, lineHeight - fontSize * 1.2))
            .padding(.vertical, max(0, lineHeight - fontSize * 1.2) / 2)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `NotesBox`：面试官在记。放不下时收起最早的几条，留下最近记的。
struct MockNotesBox: View {
    let notes: [MockSession.Note]
    var width: CGFloat = 260
    /// 盒子顶在画布上的位置；最多画到 590（再往下是地平线）。
    var top: CGFloat = 400
    var body: some View {
        let rows = max(2, Int((590 - top - 27) / 26))
        let hidden = notes.count > rows ? notes.count - (rows - 1) : 0
        VStack(alignment: .leading, spacing: 0) {
            Text("面 试 官 在 记").font(V3.sans(11)).tracking(1.1).foregroundStyle(MI.mute).frame(height: 22).padding(.bottom, 8)
            if hidden > 0 {
                row(mark: "…", markColor: MI.gry, text: "更早记的 \(hidden) 条已收起", textColor: MI.gry, size: 11.5, level: nil)
            }
            ForEach(Array(notes.dropFirst(hidden).enumerated()), id: \.offset) { _, note in
                row(mark: note.kind == "hit" ? "✓" : note.kind == "question" ? "?" : "—",
                    markColor: note.kind == "hit" ? MI.blue : note.kind == "question" ? MI.orange : MI.mute,
                    text: note.text, textColor: note.kind == "miss" ? MI.mute : MI.ink, size: 12.5, level: MockMap.levelName(note.level))
            }
        }
        .frame(width: width + 90, alignment: .leading).padding(.top, 26)
    }

    private func row(mark: String, markColor: Color, text: String, textColor: Color, size: CGFloat, level: String?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: mark).font(V3.sans(size, weight: .medium)).foregroundStyle(markColor).frame(width: 12, alignment: .leading)
            Text(verbatim: text).font(V3.sans(size)).foregroundStyle(textColor).lineSpacing(max(0, 19 - size * 1.2)).fixedSize(horizontal: false, vertical: true).frame(width: width, alignment: .leading)
            if let level { Text(verbatim: level).font(V3.sans(10.5)).foregroundStyle(MI.gry).padding(.leading, 12) }
        }.frame(minHeight: 26, alignment: .topLeading)
    }
}

/// `TranscriptBox`：说过的话留着；高度固定，超出后自动滚到最新一句，往上拖可以翻看。
struct MockTranscript<Content: View>: View {
    var height: CGFloat = 196
    var follow = true
    var card = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content(); Color.clear.frame(height: 1).id("end") }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 18)
                    .onChange(of: "\(follow)") { if follow { proxy.scrollTo("end", anchor: .bottom) } }
            }
            .scrollIndicators(.never)
            .onAppear { if follow { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .padding(card ? EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 6) : EdgeInsets())
        .frame(width: 652, height: height, alignment: .topLeading)
        .overlay { if card { RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xE3E0D8)) } }
    }
}

/// `.mi2-said`：回答正文，15 / 28。
struct MockSaid: View {
    let text: String
    var past = false
    var body: some View {
        Text(verbatim: text).font(V3.sans(15)).foregroundStyle(past ? MI.gry : MI.ink).lineSpacing(28 - 15 * 1.2)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `.mi2-alert`：左边一根色条的提示，右边一个按钮。
struct MockAlert<Action: View>: View {
    let title: String
    let sub: String
    var blue = false
    @ViewBuilder var action: () -> Action
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(V3.sans(13, weight: .medium)).foregroundStyle(blue ? MI.ink : MI.orange)
                Text(verbatim: sub).font(V3.sans(12)).foregroundStyle(MI.sub)
            }.frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 16)).frame(width: 600)
        .background((blue ? MI.blue : MI.orange).opacity(0.06))
        .overlay(alignment: .leading) { Rectangle().fill(blue ? MI.blue : MI.orange).frame(width: 2) }
        .padding(.top, 16)
    }
}

/// `ConfirmDialog`：确认弹窗（430 宽）。
struct MockConfirm<Extra: View>: View {
    let title: String
    let desc: String
    let confirm: String
    var cancel = "取消"
    var danger = false
    var busy = false
    var busyLabel = "请稍候…"
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @ViewBuilder var extra: () -> Extra
    var body: some View {
        ZStack {
            Color(hex: 0x1D1D1B).opacity(0.22).onTapGesture { if !busy { onCancel() } }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title).font(V3.serif(19)).foregroundStyle(MI.ink).frame(height: 19 * 1.45)
                Text(verbatim: desc).font(V3.sans(13)).foregroundStyle(MI.sub).lineSpacing(13 * 0.5).padding(.vertical, 13 * 0.25).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                extra()
                HStack(spacing: 10) {
                    Button(cancel, action: onCancel).buttonStyle(MockButtonStyle()).disabled(busy)
                    Button(busy ? busyLabel : confirm, action: onConfirm).buttonStyle(MockButtonStyle(kind: .dark)).disabled(busy)
                }.frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 20)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 20).frame(width: 430)
            .background(.white, in: RoundedRectangle(cornerRadius: 14)).shadow(color: .black.opacity(0.14), radius: 20, y: 16)
            .onExitCommand { if !busy { onCancel() } }
        }
        .frame(width: MockFull.width, height: MockFull.height)
    }
}

extension MockConfirm where Extra == EmptyView {
    init(title: String, desc: String, confirm: String, cancel: String = "取消", danger: Bool = false, busy: Bool = false, busyLabel: String = "请稍候…", onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.init(title: title, desc: desc, confirm: confirm, cancel: cancel, danger: danger, busy: busy, busyLabel: busyLabel, onConfirm: onConfirm, onCancel: onCancel, extra: { EmptyView() })
    }
}

/// `FinishStats`：结束确认里的三个数。
struct MockFinishStats: View {
    let detail: JSONValue
    let elapsed: String
    var body: some View {
        let rounds = MockMap.rounds(detail).filter { !$0.intro }
        let answered = rounds.filter { $0.main.text("answer_status") != "pending" }.count
        let follows = (detail["questions"]?.items ?? []).filter { $0.text("kind") == "follow_up" }.count
        HStack(spacing: 52) {
            stat("\(answered) / \(detail["question_count"]?.integer ?? 0)", "题")
            stat("\(follows)", "次追问")
            stat(elapsed, "用时")
        }.padding(.top, 18)
    }
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value).font(.system(size: 22, weight: .medium).monospacedDigit()).foregroundStyle(MI.ink).frame(height: 22)
            Text(verbatim: label).font(V3.sans(11.5)).foregroundStyle(MI.mute).frame(height: 22)
        }
    }
}

/// `ConversationDrawer`：右侧对话记录抽屉。
struct MockConversationDrawer: View {
    let detail: JSONValue
    let currentID: String?
    let close: () -> Void
    var body: some View {
        let rounds = MockMap.rounds(detail)
        let body = rounds.filter { !$0.intro }
        let current = rounds.firstIndex { $0.main.display("id") == currentID || $0.turns.contains { $0.display("id") == currentID } }
        let position = current.flatMap { c in rounds[c].intro ? nil : body.firstIndex { $0.main.display("id") == rounds[c].main.display("id") }.map { $0 + 1 } } ?? 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("对话记录").font(V3.serif(18)).foregroundStyle(MI.ink)
                Text(verbatim: position > 0 ? "第 \(position) / \(detail["question_count"]?.integer ?? 0) 题" : "开场").font(V3.sans(12)).foregroundStyle(MI.mute)
                Spacer()
                Button("×", action: close).buttonStyle(.plain).font(.system(size: 16)).foregroundStyle(MI.mute).accessibilityLabel("关闭对话记录")
            }.frame(height: 23)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rounds.enumerated()), id: \.offset) { index, round in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: round.intro ? "开场 · 自我介绍" : "Q\((body.firstIndex { $0.main.display("id") == round.main.display("id") } ?? 0) + 1) \(round.topic)")
                                    .font(V3.sans(11)).foregroundStyle(MI.mute).frame(height: 22).padding(.bottom, 10)
                                ForEach(Array(round.turns.enumerated()), id: \.offset) { _, turn in
                                    line("面试官", turn.text("content"), blue: true)
                                    if turn.text("answer_status") == "answered", let answer = turn.text("answer_text").nonEmptyValue { line("你", answer) }
                                    if turn.text("answer_status") == "skipped" { line("你", "跳过了这道题", off: true) }
                                }
                            }
                            .padding(.bottom, 18).frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .bottom) { if index != current { Rectangle().fill(Color(hex: 0xF0EEE8)).frame(height: 1) } }
                            .padding(.bottom, 18)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                }.scrollIndicators(.never).padding(.top, 24).onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .padding(EdgeInsets(top: 28, leading: 24, bottom: 20, trailing: 28))
        .frame(width: 556, height: 680, alignment: .topLeading)
        .background(.white)
        .overlay(alignment: .leading) { Rectangle().fill(Color(hex: 0xE6E3DC)).frame(width: 1) }
        .shadow(color: .black.opacity(0.06), radius: 15, x: -12)
        .offset(x: 812, y: 71)
        .onExitCommand(perform: close)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
    private func line(_ who: String, _ text: String, blue: Bool = false, off: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(verbatim: who).font(V3.sans(11)).foregroundStyle(blue ? MI.blue : MI.mute).frame(width: 54, alignment: .leading)
            Text(verbatim: text).font(V3.sans(12.5)).foregroundStyle(off ? MI.mute : MI.ink).lineSpacing(19 - 12.5 * 1.2).padding(.vertical, (19 - 12.5 * 1.2) / 2).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 10)
    }
}

/// `.mi2-toast-slot`：右下角错误提示，5 秒后收起。
struct MockToast: View {
    @Binding var toast: (title: String, message: String)?
    var body: some View {
        if let value = toast {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: value.title).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.red)
                if !value.message.isEmpty { Text(verbatim: value.message).font(V3.sans(12)).foregroundStyle(MI.sub) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xE6E3DC))).shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            .frame(width: MockFull.width - 48, height: MockFull.height - 48, alignment: .bottomTrailing).offset(x: 24, y: 24)
            .task(id: value.title + value.message) { try? await Task.sleep(for: .seconds(5)); toast = nil }
        }
    }
}

/// `.mi2-prep`：准备题目、设备检测与结束的左栏（500 宽，顶在 108）。
struct MockPrepColumn<Content: View>: View {
    var width: CGFloat = 500
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }.frame(width: width, alignment: .leading).offset(x: 56, y: 108)
    }
}

struct MockPrepTitle: View {
    let title: String
    var size: CGFloat = 28
    let sub: String
    var body: some View {
        Text(verbatim: title).font(V3.serif(size)).foregroundStyle(MI.ink).frame(height: size * 1.3, alignment: .top)
        Text(verbatim: sub).font(V3.sans(13)).foregroundStyle(MI.sub).lineSpacing(13 * 0.3).padding(.vertical, 13 * 0.15).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
    }
}

/// `.mi2-actions .mi2-btn.is-dark`：步骤页的主按钮内边距 8 / 16。
struct MockBigButtonStyle: ButtonStyle {
    var kind: MockButtonStyle.Kind = .dark
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let dark = kind == .dark
        // 字号来自按钮行内的 12.5px（`.mi2-actions .mi2-btn.is-dark` 的 14px 被覆盖），只有内边距是 8 / 16
        return configuration.label.font(V3.sans(12.5, weight: .medium)).foregroundStyle(dark ? .white : kind == .off ? MI.gry : MI.ink).lineLimit(1)
            .frame(height: 12.5 * 1.45).padding(.horizontal, 17).padding(.vertical, 9)
            .background(dark ? (configuration.isPressed ? Color(hex: 0x33332F) : MI.ink) : kind == .off ? Color(hex: 0xE9E7E1) : .white, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(dark ? MI.ink : kind == .off ? Color(hex: 0xE9E7E1) : MI.line))
            .opacity(enabled || kind == .off ? 1 : 0.6).contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
