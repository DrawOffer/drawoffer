import AppKit
import DrawOfferCore
import SwiftUI

/// 投递详情各块的画法（Figma 07N · 03–06，Web `progress/journey.tsx` + `journey.css`）。
/// 文案与状态在 Core `CareerJourney`；右侧图形在 `CareerStageFigures`；数据、弹窗和跳转在 `CareerApplicationDetailView`。
enum CareerJourneyStyle {
    static let ink = Color(hex: 0x1D1D1B)
    static let body = Color(hex: 0x55554F)
    static let sub = Color(hex: 0x6C6C65)
    static let mute = Color(hex: 0x96968F)
    static let rest = Color(hex: 0xA3A39C)
    static let line = Color(hex: 0xDEDEDA)
    static let track = Color(hex: 0xC9C9C3)
    static let blue = Color(hex: 0x3F6FD8)
    static let orange = Color(hex: 0xD9822B)
    static let check = Color(hex: 0xB9B9B3)
}

private typealias JS = CareerJourneyStyle

/// `.jy-top-link`：灰色文字按钮，悬停变墨色（不加底色）。
struct CareerJourneyTextButton: View {
    let title: String
    var size: CGFloat = 13
    var color: Color = JS.body
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(V3.sans(size)).foregroundStyle(hover ? JS.ink : color).lineLimit(1).fixedSize().contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}

// MARK: - 现在该做什么（左半）

/// `.jy-hero`：公司 · 岗位，两行大标题（第二行的颜色说轮到谁），一句说明，一黑一白两个按钮。
struct CareerJourneyHero: View {
    let job: String
    let step: CareerJourneyStep
    /// 内容区放不下「500 + 480」时标题缩到 48 / 66（`@container jy (max-width: 1010px)`）。
    let compact: Bool
    let disabled: Bool
    let act: (CareerJourneyAction) -> Void

    var body: some View {
        let size: CGFloat = compact ? 48 : 60, lead: CGFloat = compact ? 66 : 80
        VStack(alignment: .leading, spacing: 0) {
            Text(job).font(V3.sans(15)).foregroundStyle(JS.sub).lineLimit(1).truncationMode(.tail).frame(height: 22)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(step.title.enumerated()), id: \.offset) { index, line in
                    Text(line).font(V3.serif(size)).tracking(size * 0.01).foregroundStyle(index == 0 ? JS.ink : secondColor)
                        .lineHeight(size, lead, .serif).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 18).accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            if let desc = step.desc, !desc.isEmpty {
                Text(desc).font(V3.sans(compact ? 16 : 17)).foregroundStyle(JS.body).lineHeight(compact ? 16 : 17, 28)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520, alignment: .leading).padding(.top, 20)
            }
            if step.primary != nil || step.secondary != nil {
                HStack(spacing: 12) {
                    if let primary = step.primary {
                        Button { act(primary.action) } label: { Text(primary.label) }.buttonStyle(CareerJourneyButtonStyle(main: true)).disabled(disabled)
                    }
                    if let secondary = step.secondary {
                        Button { act(secondary.action) } label: { Text(secondary.label) }.buttonStyle(CareerJourneyButtonStyle(main: false)).disabled(disabled)
                    }
                }.padding(.top, 40)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var secondColor: Color {
        switch step.tone {
        case .turn: return JS.blue
        case .rest: return JS.rest
        case .plain: return JS.ink
        }
    }
}

/// `.jy-main-btn` / `.jy-side-btn`：48 高的胶囊；黑的那个带一支向右的箭头，悬停时往前挪 2pt。
struct CareerJourneyButtonStyle: ButtonStyle {
    let main: Bool
    func makeBody(configuration: Configuration) -> some View { Pill(configuration: configuration, main: main) }

    private struct Pill: View {
        let configuration: Configuration
        let main: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            HStack(spacing: 10) {
                configuration.label.lineLimit(1).fixedSize()
                if main {
                    Path { path in
                        path.move(to: CGPoint(x: 0.8, y: 5.5)); path.addLine(to: CGPoint(x: 13.8, y: 5.5))
                        path.move(to: CGPoint(x: 9.3, y: 1)); path.addLine(to: CGPoint(x: 13.8, y: 5.5)); path.addLine(to: CGPoint(x: 9.3, y: 10))
                    }
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 15, height: 11).offset(x: hover && enabled ? 2 : 0).animation(.easeOut(duration: 0.15), value: hover)
                    .accessibilityHidden(true)
                }
            }
            .font(V3.sans(16, weight: .medium)).foregroundStyle(main ? .white : JS.ink)
            .padding(.horizontal, 26).frame(minWidth: main ? 176 : 148, minHeight: 48, maxHeight: 48)
            .background {
                ZStack {
                    Capsule().fill(main ? (hover && enabled ? Color(hex: 0x2F2F2C) : JS.ink) : .white)
                    Capsule().strokeBorder(main ? .clear : hover && enabled ? JS.check : JS.line, lineWidth: 1)
                }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.55)
            .contentShape(Capsule())
            .onHover { hover = $0 }
        }
    }
}

// MARK: - 全程时间线（底部；点过去的节点回看那一轮）

struct CareerJourneyTimeline: View {
    let timeline: CareerJourney.Timeline
    /// 正在回看的站点。
    let picked: String?
    let pick: (String) -> Void
    /// 「更新进度 ›」：能往下走、且左边没有按钮在做这件事时才有。
    var onAdvance: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text(timeline.head).foregroundStyle(JS.sub)
                Spacer(minLength: 0)
                if let onAdvance { AdvanceLink(action: onAdvance) }
            }
            .font(V3.sans(13)).frame(height: 16)
            GeometryReader { geometry in
                let width = geometry.size.width
                let count = timeline.nodes.count
                let xs = (0..<max(1, count)).map { index -> CGFloat in count > 1 ? width * CGFloat(index) / CGFloat(count - 1) : 0 }
                ZStack(alignment: .topLeading) {
                    ForEach(Array(timeline.segments.enumerated()), id: \.offset) { index, segment in
                        if let today = timeline.today, today.segment == index {
                            let split = xs[index] + CGFloat(today.ratio) * (xs[index + 1] - xs[index])
                            segmentView(.current, days: today.days, from: xs[index], to: split)
                            segmentView(.future, days: nil, from: split, to: xs[index + 1])
                            todayDot.offset(x: split - 4, y: 27).zIndex(2)
                        } else {
                            segmentView(segment.style, days: segment.days, from: xs[index], to: xs[index + 1])
                        }
                    }
                    ForEach(Array(timeline.nodes.enumerated()), id: \.element.id) { index, node in
                        CareerJourneyNodeView(node: node, edge: index == 0 ? .first : index == count - 1 ? .last : .middle,
                                              picked: node.stationID != nil && node.stationID == picked, today: node.id == timeline.todayNode, pick: pick)
                            .alignmentGuide(.leading) { d in
                                // 首个节点左缘在 -15，末个右缘在 width + 15，中间的居中对齐节点
                                index == 0 ? 15 : index == count - 1 ? d.width - width - 15 : d.width / 2 - xs[index]
                            }
                            .alignmentGuide(.top) { _ in -16 }
                            .zIndex(1)
                    }
                }
            }
            .frame(height: 128).padding(.top, 30)
        }
        .accessibilityElement(children: .contain).accessibilityLabel("全程时间线")
    }

    /// `.jy-today`：蓝线走到这里的线头，上面写「今天」。
    private var todayDot: some View {
        Circle().fill(JS.blue).frame(width: 8, height: 8)
            .background(Circle().fill(JS.blue.opacity(0.16)).padding(-4))
            .overlay(alignment: .bottom) {
                Text("今天").font(V3.sans(12, weight: .medium)).foregroundStyle(JS.blue).fixedSize().frame(height: 14).offset(y: -13)
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    @ViewBuilder private func segmentView(_ style: CareerJourney.Segment.Style, days: Int?, from: CGFloat, to: CGFloat) -> some View {
        ZStack(alignment: .top) {
            switch style {
            case .future:
                Path { path in path.move(to: CGPoint(x: 0, y: 0.75)); path.addLine(to: CGPoint(x: max(0, to - from), y: 0.75)) }
                    .stroke(JS.track, style: StrokeStyle(lineWidth: 1.5, dash: [3, 5])).frame(height: 2)
            // 线段自身定高 2：ZStack 会把「N 天」文字撑出的高度再塞给可伸缩的 Rectangle，不定高就画成 12pt 粗条。
            case .current: Rectangle().fill(JS.blue).frame(height: 2)
            case .past: Rectangle().fill(JS.track).frame(height: 2)
            }
            if let days, days > 0 {
                Text("\(days) 天").font(V3.sans(12, weight: .medium)).foregroundStyle(JS.mute).fixedSize().frame(height: 14).offset(y: -24)
            }
        }
        .frame(width: max(0, to - from), height: 2)
        .offset(x: from, y: 30)
        .allowsHitTesting(false)
    }

    private struct AdvanceLink: View {
        let action: () -> Void
        @State private var hover = false
        var body: some View {
            Button(action: action) {
                HStack(spacing: 4) { Text("更新进度").underline(hover); Text("›") }
                    .font(V3.sans(13, weight: .medium)).foregroundStyle(JS.ink).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).onHover { hover = $0 }.padding(.vertical, -8)
        }
    }
}

private struct CareerJourneyNodeView: View {
    enum Edge { case first, middle, last }
    let node: CareerJourney.Node
    let edge: Edge
    let picked: Bool
    /// 这一轮就在今天：节点自己是今天的点。
    let today: Bool
    let pick: (String) -> Void
    @State private var hover = false

    var body: some View {
        let clickable = node.stationID != nil && node.kind != .future
        let alignment: HorizontalAlignment = edge == .first ? .leading : edge == .last ? .trailing : .center
        let content = VStack(alignment: alignment, spacing: 5) {
            Text(node.label).font(V3.sans(14, weight: picked ? .semibold : node.kind == .future ? .regular : .medium))
                .foregroundStyle(labelColor).frame(height: 17)
            if let line = node.line {
                Text(line).font(V3.sans(12.5)).foregroundStyle(node.kind == .current ? (today ? JS.blue : JS.body) : JS.sub).frame(height: 15)
            }
            if let note = node.note {
                HStack(spacing: 6) { Circle().fill(JS.orange).frame(width: 5, height: 5); Text(note) }
                    .font(V3.sans(12.5)).foregroundStyle(JS.body).frame(height: 15)
            }
        }
        .fixedSize()
        .padding(.top, 34).padding(.horizontal, 10).padding(.bottom, 8)
        .overlay(alignment: edge == .first ? .topLeading : edge == .last ? .topTrailing : .top) { dot.padding(.top, dotTop).padding(.horizontal, dotInset) }
        .contentShape(Rectangle())
        if clickable, let id = node.stationID {
            Button { pick(id) } label: { content }.buttonStyle(.plain)
                .onHover { hover = $0 }
                .help(picked || node.kind == .current ? "" : "查看\(node.label)")
                .accessibilityAddTraits(picked ? .isSelected : [])
                .accessibilityLabel([node.label, node.line, node.note].compactMap { $0 }.joined(separator: "，"))
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    private var todayDot: Bool { today && !picked && node.kind == .current }
    private var labelColor: Color {
        if picked { return JS.ink }
        switch node.kind {
        case .current: return JS.blue
        case .future: return JS.mute
        default: return JS.ink
        }
    }
    private var size: CGFloat { picked ? 12 : todayDot ? 10 : node.kind == .current ? 14 : 10 }
    private var dotTop: CGFloat { 10 - (size - 10) / 2 }
    private var dotInset: CGFloat { edge == .middle ? 0 : 10 - (size - 10) / 2 }

    @ViewBuilder private var dot: some View {
        if picked {
            Circle().fill(JS.ink).frame(width: 12, height: 12).background(Circle().fill(JS.ink.opacity(0.12)).padding(-5))
        } else if todayDot {
            Circle().fill(JS.blue).frame(width: 10, height: 10).background(Circle().fill(JS.blue.opacity(0.16)).padding(-7))
        } else {
            switch node.kind {
            case .current:
                Circle().fill(.white).overlay(Circle().stroke(JS.blue, lineWidth: 2)).frame(width: 14, height: 14)
                    .background(Circle().fill(JS.blue.opacity(hover ? 0.12 : 0)).padding(-4))
            case .future:
                Circle().fill(.white).overlay(Circle().stroke(JS.check, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))).frame(width: 10, height: 10)
            default:
                Circle().fill(JS.ink).frame(width: 10, height: 10).background(Circle().fill(JS.ink.opacity(hover ? 0.1 : 0)).padding(-4))
            }
        }
    }
}
