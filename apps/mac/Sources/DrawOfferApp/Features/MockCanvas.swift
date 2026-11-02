import Foundation
import DrawOfferCore
import SwiftUI

/// 模拟面试 V2 的画布部件（Web `mock-interview/v2/MasteryMap.tsx`、`Horizon.tsx`、`ui.tsx`）：按设计稿坐标排版，
/// 外层 `MockStage` 整体等比缩放；1440 × 900 窗口下首页缩放约 1.04，与 Web `DesignStage` 一致。
enum MI {
    static let ink = Color(hex: 0x1D1D1B)
    static let blue = Color(hex: 0x3F6FD8)
    static let orange = Color(hex: 0xD9822B)
    static let mute = Color(hex: 0x9B978C)
    static let sub = Color(hex: 0x5F5D57)
    static let gry = Color(hex: 0xA9A59A)
    static let line = Color(hex: 0xD9D6CD)
    static let soft = Color(hex: 0xEFEDE7)
    static let paper = Color.white
}

/// 按设计尺寸排版、整体等比缩放并居中（Web `DesignStage`）。
struct MockStage<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / width, geometry.size.height / height)
            content().frame(width: width, height: height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .center)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(.white)
    }
}

extension View {
    /// 把视图钉在设计坐标上：`x` 是左边、中心或右边（按 `align`），`top` 是行框顶。
    func pin(_ x: CGFloat, _ top: CGFloat, align: HorizontalAlignment = .leading) -> some View {
        fixedSize()
            .frame(width: 0, alignment: Alignment(horizontal: align == .center ? .center : align == .trailing ? .trailing : .leading, vertical: .top))
            .offset(x: x, y: top)
    }
}

/// `.mi2-label`：一行文字，行高 1.45。
struct MapLabel: View {
    let text: String
    var size: CGFloat
    var color: Color = MI.sub
    var weight: Font.Weight = .regular
    var tracking: CGFloat = 0
    var serif = false
    var number = false
    var body: some View {
        Text(verbatim: text)
            .font(serif ? V3.serif(size) : number ? .system(size: size, weight: .medium).monospacedDigit() : V3.sans(size, weight: weight))
            .tracking(tracking).foregroundStyle(color).lineLimit(1)
            .frame(height: size * 1.45)
    }
}

// MARK: 掌握程度图

struct MasteryMapView: View {
    var width: CGFloat
    var height: CGFloat
    var g: MockMap.Geo
    var points: [MockMap.Point]
    var sectors: [MockMap.Sector]
    var targetLevel: Double
    var targetLabel: String?
    var center: String?
    var dim: [String] = []
    var path: [MockMap.PathStep]? = nil
    var bounds: [Double]? = nil
    var labels: [String: MockLayout.Label]? = nil
    var sectorLabels: [String: MockLayout.SectorLabel]? = nil
    var selected: String? = nil
    var focus: String? = nil
    var labelOnly: [String]? = nil
    var subs: [String: (String, MockMap.SubTone)] = [:]
    var noGap = false
    var dashed = true
    var empty = false
    var loading = false
    /// 作答页：正在问的这题（外加两圈）、这一场问到的点（其余变淡）、不画题与题之间的连线。
    var now: String? = nil
    var hot: [String]? = nil
    var noLinks = false
    var badges = true
    /// 复盘总览：圈不填色、点画成白边实心点、不画圆心星标，圆心写「专家」；点可点。
    var plain = false
    var bandLabels = true
    var onPoint: ((String) -> Void)? = nil

    private func dimmed(_ point: MockMap.Point) -> Bool { dim.contains(point.sector) || (hot.map { !$0.contains(point.id) } ?? false) }

    private func color(_ point: MockMap.Point) -> Color {
        if loading { return Color(hex: 0xD6D2C7) }
        if point.pending { return MI.gry }
        if point.level == 0 { return point.job ? MI.orange : MI.gry }
        return point.level >= targetLevel ? MI.blue : MI.orange
    }

    var body: some View {
        let placed = MockMap.place(g, points)
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in draw(&context, placed) }.frame(width: width, height: height)
            if !sectors.isEmpty {
                ForEach(sectors.filter { !$0.name.hasPrefix("__empty_") }, id: \.name) { sector in
                    let at = sectorLabels?[sector.name].map { (x: $0.x, y: $0.y) } ?? g.P(sector.angle, 284 * g.k)
                    MapLabel(text: sector.name, size: 11, color: dim.contains(sector.name) ? Color(hex: 0xCFCABD) : MI.mute, tracking: 11 * 0.18)
                        .pin(at.x, at.y - 8, align: .center)
                }
            }
            if bandLabels { ForEach(1...4, id: \.self) { level in
                MapLabel(text: MockMap.levels[level - 1], size: 10, color: MI.gry, tracking: 1)
                    .pin(dashed ? g.cx + 5 : g.cx - 6, g.cy - g.rOf(Double(level)) - 7, align: dashed ? .leading : .trailing)
            } }
            if let targetLabel {
                let t = g.P(28, g.ringOf(targetLevel))
                Text(verbatim: targetLabel).font(V3.sans(10.5, weight: .medium)).foregroundStyle(MI.blue)
                    .frame(height: 10.5 * 1.45).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.white, in: RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: 0xC9D6F3)))
                    .pin(t.x + 8, t.y - 22)
            }
            if let center { MapLabel(text: center, size: 13, color: MI.ink, serif: true).pin(g.cx, g.cy + 26 * g.k, align: .center) }
            if !empty && !loading { pointLabels(placed) }
            if plain && bandLabels { MapLabel(text: MockMap.levels[4], size: 10, color: MI.gry, tracking: 1).pin(g.cx, g.cy - 7, align: .center) }
            if let path, badges { badgeMarks(placed, path) }
            if let onPoint, !empty && !loading {
                ForEach(placed, id: \.point.id) { item in
                    Circle().fill(Color.white.opacity(0.001)).frame(width: 30, height: 30).contentShape(Circle())
                        .onTapGesture { onPoint(item.point.id) }.help(item.point.name)
                        .accessibilityElement().accessibilityLabel(item.point.name).accessibilityAddTraits(.isButton).accessibilityAction { onPoint(item.point.id) }
                        .position(x: item.x, y: item.y)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .allowsHitTesting(onPoint != nil)
    }

    @ViewBuilder private func pointLabels(_ placed: [MockMap.Placed]) -> some View {
        ForEach(placed, id: \.point.id) { item in
            let point = item.point
            if labels?[point.id] == nil, labelOnly == nil || labelOnly!.contains(point.id) {
                // 没有摆放结果时（作答页还没有题）：名字放在点的外侧，左半边右对齐
                let left = cos(point.angle * .pi / 180) < -0.2
                let strong = point.id == selected || point.id == focus || point.id == now
                let offset = point.id == now ? 30.0 : point.ask == 3 ? 18 : 15
                let sub = subs[point.id]
                Group {
                    MapLabel(text: point.name, size: strong ? 12.5 : 11.5, color: strong || point.ask == 3 ? MI.ink : MI.sub, weight: strong || point.ask == 3 ? .medium : .regular)
                        .pin(left ? item.x - offset : item.x + offset, item.y - 9, align: left ? .trailing : .leading)
                    if let sub {
                        MapLabel(text: sub.0, size: 10.5, color: sub.1 == .orange ? MI.orange : sub.1 == .blue ? MI.blue : MI.mute)
                            .pin(left ? item.x - offset : item.x + offset, item.y + 8, align: left ? .trailing : .leading)
                    }
                }.opacity(dimmed(point) ? 0.3 : 1)
            }
            if labelOnly == nil || labelOnly!.contains(point.id), let place = labels?[point.id] {
                let strong = point.id == selected || point.id == focus || point.id == now
                let heavy = strong || (path == nil && point.ask == 3)
                let sub = path == nil ? subs[point.id] : nil
                let align: HorizontalAlignment = place.align == .right ? .trailing : place.align == .center ? .center : .leading
                let opacity = dimmed(point) ? 0.3 : 1.0
                Group {
                    if place.lines == 2 {
                        Text(verbatim: point.name).font(V3.sans(strong ? MockLayout.nowSize : MockLayout.labelSize, weight: heavy ? .medium : .regular))
                            .foregroundStyle(heavy ? MI.ink : MI.sub).lineSpacing(17 - (strong ? MockLayout.nowSize : MockLayout.labelSize) * 1.2)
                            .multilineTextAlignment(place.align == .right ? .trailing : place.align == .center ? .center : .leading)
                            .frame(width: place.width, alignment: Alignment(horizontal: align, vertical: .top))
                            .pin(place.x, place.box.t, align: align)
                    } else {
                        MapLabel(text: point.name, size: strong ? MockLayout.nowSize : MockLayout.labelSize, color: heavy ? MI.ink : MI.sub, weight: heavy ? .medium : .regular)
                            .pin(place.x, place.box.t, align: align)
                    }
                    if let sub {
                        MapLabel(text: sub.0, size: MockLayout.subSize, color: sub.1 == .orange ? MI.orange : sub.1 == .blue ? MI.blue : MI.mute)
                            .pin(place.x, place.box.t + 17 * Double(place.lines), align: align)
                    }
                }.opacity(opacity)
            }
        }
    }

    @ViewBuilder private func badgeMarks(_ placed: [MockMap.Placed], _ path: [MockMap.PathStep]) -> some View {
        let byID = Dictionary(placed.map { ($0.point.id, $0) }, uniquingKeysWith: { a, _ in a })
        ForEach(Array(path.enumerated()), id: \.offset) { index, step in
            if let item = byID[step.id] {
                let b = g.P(item.point.angle, g.rOf(max(1, step.from)) + 17 * g.k)
                let color = step.ok == false ? MI.orange : MI.blue
                Text(verbatim: "\(index + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 16, height: 16).background(.white, in: Circle()).overlay(Circle().stroke(color, lineWidth: 1))
                    .offset(x: b.x - 8, y: b.y - 8)
            }
        }
    }

    private func circle(_ x: Double, _ y: Double, _ r: Double) -> Path { Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }
    private func line(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Path {
        var p = Path(); p.move(to: CGPoint(x: a.x, y: a.y)); p.addLine(to: CGPoint(x: b.x, y: b.y)); return p
    }
    private func sparkle(_ x: Double, _ y: Double, _ tip: Double) -> Path {
        let w = tip * 0.044
        var p = Path()
        p.move(to: CGPoint(x: x, y: y - tip)); p.addLine(to: CGPoint(x: x + w, y: y - w)); p.addLine(to: CGPoint(x: x + tip, y: y))
        p.addLine(to: CGPoint(x: x + w, y: y + w)); p.addLine(to: CGPoint(x: x, y: y + tip)); p.addLine(to: CGPoint(x: x - w, y: y + w))
        p.addLine(to: CGPoint(x: x - tip, y: y)); p.addLine(to: CGPoint(x: x - w, y: y - w)); p.closeSubpath()
        return p
    }
    static func star(_ x: Double, _ y: Double, _ k: Double) -> Path {
        let a = 14 * k, b = 2.6 * k
        var p = Path()
        p.move(to: CGPoint(x: x, y: y - a)); p.addLine(to: CGPoint(x: x + b, y: y - b)); p.addLine(to: CGPoint(x: x + a, y: y))
        p.addLine(to: CGPoint(x: x + b, y: y + b)); p.addLine(to: CGPoint(x: x, y: y + a)); p.addLine(to: CGPoint(x: x - b, y: y + b))
        p.addLine(to: CGPoint(x: x - a, y: y)); p.addLine(to: CGPoint(x: x - b, y: y - b)); p.closeSubpath()
        return p
    }

    private func draw(_ context: inout GraphicsContext, _ placed: [MockMap.Placed]) {
        let k = g.k
        context.stroke(circle(g.cx, g.cy, 258 * k), with: .color(MI.gry.opacity(0.5)), style: StrokeStyle(lineWidth: dashed ? 0.75 : 1, dash: dashed ? [4, 4] : [2, 5]))
        for (index, radius) in [225.0, 180, 135, 90, 45].enumerated() {
            let ring = circle(g.cx, g.cy, radius * k)
            if dashed { context.stroke(ring, with: .color(Color(hex: 0xC9C5BB)), style: StrokeStyle(lineWidth: 0.75, dash: [4, 4])) }
            else { if !plain { context.fill(ring, with: .color(index % 2 == 1 ? Color(hex: 0xF2F0EA) : .white)) }; context.stroke(ring, with: .color(Color(hex: 0xD6D2C7)), lineWidth: 1) }
        }
        let targetRadius = g.ringOf(targetLevel)
        let target = circle(g.cx, g.cy, targetRadius)
        context.fill(target, with: .color(MI.blue.opacity(0.05)))
        context.stroke(target, with: .color(MI.blue), style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
        for angle in bounds ?? [-150, -90, -30, 30, 90, 150] {
            let a = g.P(angle, (dashed ? 55 : 20) * k), b = g.P(angle, (dashed ? 225 - 12 : 258) * k)
            context.stroke(line(a, b), with: .color(Color(hex: dashed ? 0xD6D2C7 : 0xDEDAD0)), style: StrokeStyle(lineWidth: dashed ? 0.75 : 1, dash: dashed ? [6, 4] : [1, 3]))
        }
        for sector in sectors where dim.contains(sector.name) {
            var wedge = Path()
            wedge.move(to: CGPoint(x: g.cx, y: g.cy))
            wedge.addArc(center: CGPoint(x: g.cx, y: g.cy), radius: 275 * k, startAngle: .degrees(sector.angle - 30), endAngle: .degrees(sector.angle + 30), clockwise: false)
            wedge.closeSubpath()
            context.fill(wedge, with: .color(.white.opacity(0.78)))
        }
        if !empty {
            let scaleOf = [0.72, 0.72, 0.86, 1.05]
            for item in placed {
                let point = item.point, x = item.x, y = item.y
                let opacity = dimmed(point) ? 0.22 : 1
                let c = color(point)
                let scale = scaleOf[min(3, max(0, point.ask))] * max(k, 0.8)
                let unit = scale / 0.86
                if !loading && point.level > 0 && point.level < targetLevel && path == nil && !noGap && !point.pending {
                    let t = g.P(point.angle, targetRadius)
                    if dashed {
                        let length = max(hypot(t.x - x, t.y - y), 1)
                        let start = (point.id == focus ? 10 : 6) * unit
                        context.stroke(line((x + (t.x - x) / length * start, y + (t.y - y) / length * start), t), with: .color(MI.orange.opacity(0.8 * opacity)), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
                        context.fill(circle(t.x, t.y, 1.8), with: .color(.white))
                        context.stroke(circle(t.x, t.y, 1.8), with: .color(MI.orange.opacity(opacity)), lineWidth: 1)
                    } else {
                        context.stroke(line((x, y), t), with: .color(MI.orange.opacity(0.55 * opacity)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        context.fill(circle(t.x, t.y, 2.2), with: .color(MI.blue.opacity(opacity)))
                    }
                }
                if !loading, let prev = point.prev, path == nil, !noGap {
                    let p = g.P(point.angle, g.rOf(prev))
                    context.stroke(circle(p.x, p.y, 3), with: .color(MI.blue.opacity(0.6 * opacity)), lineWidth: 1)
                    context.stroke(line(p, (x + (p.x - x) * 0.25, y + (p.y - y) * 0.25)), with: .color(MI.blue.opacity(opacity)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                if dashed && !loading && (point.level == 0 || point.pending) {
                    let ring = circle(x, y, 5.5 * unit)
                    context.fill(ring, with: .color(.white))
                    context.stroke(ring, with: .color(c.opacity(opacity)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 2.6]))
                } else if dashed && !loading {
                    let big = point.id == focus
                    if big {
                        context.fill(circle(x, y, 15), with: .color(c.opacity(0.1 * opacity)))
                        context.stroke(circle(x, y, 10), with: .color(c.opacity(0.9 * opacity)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [0.1, 2.4]))
                    }
                    context.fill(circle(x, y, 5.5 * unit), with: .color(c.opacity(0.14 * opacity)))
                    context.fill(circle(x, y, 2.4 * unit), with: .color(c.opacity(opacity)))
                    let tip = big ? 9.75 : 7.3 * unit
                    context.fill(sparkle(x, y, tip), with: .color(c.opacity(0.9 * opacity)))
                    context.fill(sparkle(x, y, tip * 0.565), with: .color(c.opacity(0.55 * opacity)))
                } else if point.level == 0 || point.pending {
                    let ring = circle(x, y, 7 * scale)
                    context.fill(ring, with: .color(.white))
                    context.stroke(ring, with: .color(c.opacity(opacity)), style: StrokeStyle(lineWidth: 1.3, dash: [2, 2]))
                } else if plain {
                    context.fill(circle(x, y, 5.2 * scale), with: .color(c.opacity(opacity)))
                    context.stroke(circle(x, y, 5.2 * scale), with: .color(.white), lineWidth: 1.5)
                } else {
                    context.stroke(circle(x, y, 10.5 * scale), with: .color(c.opacity(0.35 * opacity)), lineWidth: 1)
                    context.fill(circle(x, y, 6.6 * scale), with: .color(.white))
                    context.stroke(circle(x, y, 6.6 * scale), with: .color(c.opacity(opacity)), lineWidth: 1)
                    context.fill(circle(x, y, 3.4 * scale), with: .color(c.opacity(opacity)))
                }
                if point.id == selected { context.stroke(circle(x, y, 19), with: .color(MI.ink), lineWidth: 1.2) }
                if point.id == focus && !dashed { context.stroke(circle(x, y, 17), with: .color(c), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])) }
                if point.id == now {
                    context.fill(circle(x, y, 24), with: .color(MI.blue.opacity(0.1)))
                    context.stroke(circle(x, y, 17), with: .color(MI.blue), lineWidth: 1.4)
                }
            }
        }
        if let path { drawPath(&context, placed, path) }
        if let labels {
            for item in placed {
                guard let place = labels[item.point.id], place.far else { continue }
                let ex = max(place.box.l, min(item.x, place.box.r)), ey = max(place.box.t, min(item.y, place.box.b))
                let length = max(hypot(ex - item.x, ey - item.y), 1)
                let inset = item.point.id == now ? 26.0 : 9
                context.stroke(line((item.x + (ex - item.x) / length * inset, item.y + (ey - item.y) / length * inset), (ex, ey)), with: .color(MI.gry.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [1.5, 2.5]))
            }
        }
        guard !plain else { return }
        context.fill(Self.star(g.cx, g.cy, k), with: .color(MI.ink))
        context.stroke(circle(g.cx, g.cy, 20 * k), with: .color(MI.ink.opacity(0.25)), lineWidth: 1)
    }

    private func drawPath(_ context: inout GraphicsContext, _ placed: [MockMap.Placed], _ path: [MockMap.PathStep]) {
        let byID = Dictionary(placed.map { ($0.point.id, $0) }, uniquingKeysWith: { a, _ in a })
        var previous: (x: Double, y: Double)?
        for step in path {
            guard let item = byID[step.id] else { continue }
            let a = g.P(item.point.angle, g.rOf(max(1, step.from))), b = g.P(item.point.angle, g.rOf(max(1, step.to)))
            if let previous, !noLinks {
                let q = CGPoint(x: g.cx + (previous.x + a.x - 2 * g.cx) * 0.15, y: g.cy + (previous.y + a.y - 2 * g.cy) * 0.15)
                var curve = Path(); curve.move(to: CGPoint(x: previous.x, y: previous.y)); curve.addQuadCurve(to: CGPoint(x: a.x, y: a.y), control: q)
                context.stroke(curve, with: .color(MI.ink.opacity(0.4)), lineWidth: 1)
            }
            var level = max(1, step.from)
            while level <= step.to {
                let s = g.P(item.point.angle, g.rOf(level))
                if level < step.to || step.ok == true { context.fill(circle(s.x, s.y, 2.2), with: .color(step.ok == false && level == step.to ? MI.orange : MI.blue)) }
                level += 1
            }
            context.stroke(line(a, b), with: .color(step.ok == false ? MI.orange : MI.blue), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: step.ok == nil ? [4, 3] : []))
            if step.ok == nil {
                let n = g.P(item.point.angle, g.rOf(min(5, step.to + 1)))
                context.stroke(line(b, n), with: .color(MI.blue.opacity(0.5)), style: StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
                context.fill(circle(n.x, n.y, 4), with: .color(.white))
                context.stroke(circle(n.x, n.y, 4), with: .color(MI.blue), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            } else if step.ok == true {
                context.fill(circle(b.x, b.y, 4), with: .color(MI.blue))
            } else {
                var cross = Path()
                cross.move(to: CGPoint(x: b.x - 4, y: b.y - 4)); cross.addLine(to: CGPoint(x: b.x + 4, y: b.y + 4))
                cross.move(to: CGPoint(x: b.x + 4, y: b.y - 4)); cross.addLine(to: CGPoint(x: b.x - 4, y: b.y + 4))
                context.stroke(cross, with: .color(MI.orange), lineWidth: 2)
            }
            previous = b
        }
    }
}

// MARK: 地平线

struct HorizonBase: View {
    var width: CGFloat
    var top: CGFloat
    var height: CGFloat
    var strata = false
    var body: some View {
        Canvas { context, _ in
            let arc = MockMap.arcY(width: width, top: top)
            func curve(_ offset: Double) -> Path {
                var p = Path()
                let steps = 240
                for i in 0...steps {
                    let x = Double(width) * Double(i) / Double(steps)
                    let point = CGPoint(x: x, y: arc(x) + offset)
                    if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                }
                return p
            }
            var ground = curve(0); ground.addLine(to: CGPoint(x: width, y: height)); ground.addLine(to: CGPoint(x: 0, y: height)); ground.closeSubpath()
            context.fill(ground, with: .color(MI.soft))
            context.stroke(curve(0), with: .color(MI.ink), lineWidth: 1.3)
            context.stroke(curve(7), with: .color(Color(hex: 0xCFCABD)), lineWidth: 1)
            if strata {
                for (index, offset) in [18.0, 32].enumerated() {
                    context.stroke(curve(offset), with: .color(Color(hex: 0xCFCABD).opacity(0.75 - Double(index) * 0.18)), lineWidth: 0.8)
                }
            }
            var x = 16.0, i = 0
            while x < Double(width) - 10 {
                var tick = Path(); let y = arc(x)
                tick.move(to: CGPoint(x: x, y: y)); tick.addLine(to: CGPoint(x: x, y: y - (i % 5 == 0 ? 6 : 3)))
                context.stroke(tick, with: .color(MI.gry), lineWidth: 0.7)
                x += 13; i += 1
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }
}

struct HomeHorizonView: View {
    var horizon: MockMap.Horizon?
    var selectedSession: String?
    var todayLabel: String
    var slots: Int
    var slotsLabel: String
    var focusSlot: (color: Color, from: CGPoint)?
    var dashSlots = false
    var hideSlots = false
    var dropActive = false
    var live: String?
    var evaluating = false
    var interviewLink: (() -> Void)?
    var onSession: (String) -> Void = { _ in }
    var onReport: (String) -> Void = { _ in }
    var onLive: () -> Void = {}
    @State private var hover: String?

    private let width = 1151.0, top = MockMap.homeHorizonTop
    private var arc: (Double) -> Double { MockMap.arcY(width: width, top: top) }
    private func nodeY(_ s: MockMap.HorizonSession) -> Double { s.score.map { MockMap.homeScoreY(arc, s.x, $0) } ?? arc(s.x) - 22 }

    var body: some View {
        let sessions = horizon?.sessions ?? []
        let today = horizon?.today ?? MockMap.todayX
        let latest = sessions.reversed().first { $0.score != nil }?.id
        let xs = MockMap.slotXs(slots)
        ZStack(alignment: .topLeading) {
            HorizonBase(width: width, top: top, height: 828, strata: true)
            Canvas { context, _ in
                let mine = sessions.filter { $0.mine && $0.score != nil }
                if mine.count > 1 {
                    var track = Path()
                    for (index, s) in mine.enumerated() { let p = CGPoint(x: s.x, y: nodeY(s)); if index == 0 { track.move(to: p) } else { track.addLine(to: p) } }
                    context.stroke(track, with: .color(MI.ink.opacity(0.35)), lineWidth: 1)
                }
                for s in sessions {
                    let y0 = arc(s.x), y = nodeY(s), abandoned = s.score == nil, r = abandoned ? 9.0 : 13
                    var stem = Path(); stem.move(to: CGPoint(x: s.x, y: y0)); stem.addLine(to: CGPoint(x: s.x, y: y + r))
                    context.stroke(stem, with: .color(s.mine ? MI.ink.opacity(0.7) : MI.gry.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: abandoned ? [2, 2] : []))
                    let node = Path(ellipseIn: CGRect(x: s.x - r, y: y - r, width: r * 2, height: r * 2))
                    let filled = s.id == latest
                    context.fill(node, with: .color(filled ? MI.ink : .white))
                    context.stroke(node, with: .color(filled || s.mine ? MI.ink : abandoned ? MI.gry : Color(hex: 0xCFCABD)), style: StrokeStyle(lineWidth: s.mine ? 1.2 : 1, dash: abandoned ? [2, 2] : []))
                    if selectedSession == s.id || hover == s.id {
                        context.stroke(Path(ellipseIn: CGRect(x: s.x - r - 5, y: y - r - 5, width: (r + 5) * 2, height: (r + 5) * 2)), with: .color(MI.ink.opacity(0.35)), lineWidth: 1)
                    }
                }
                var mark = Path(); mark.move(to: CGPoint(x: today, y: arc(today))); mark.addLine(to: CGPoint(x: today, y: arc(today) - 16))
                context.stroke(mark, with: .color(MI.ink), lineWidth: 1)
                for day in horizon?.days ?? [] {
                    var tick = Path(); tick.move(to: CGPoint(x: day.x, y: arc(day.x))); tick.addLine(to: CGPoint(x: day.x, y: arc(day.x) - 12))
                    context.stroke(tick, with: .color(MI.ink.opacity(0.6)), lineWidth: 1)
                }
                if live != nil || evaluating {
                    let color = live != nil ? MI.blue : MI.orange, y = arc(today)
                    context.fill(Path(ellipseIn: CGRect(x: today - 16, y: y - 16, width: 32, height: 32)), with: .color(color.opacity(0.12)))
                    context.fill(Path(ellipseIn: CGRect(x: today - 7, y: y - 7, width: 14, height: 14)), with: .color(color))
                    if evaluating { context.stroke(Path(ellipseIn: CGRect(x: today - 12, y: y - 12, width: 24, height: 24)), with: .color(MI.orange), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
                } else if !hideSlots {
                    for (index, x) in xs.enumerated() {
                        let y = arc(x)
                        if index == 0, let focusSlot {
                            context.fill(Path(ellipseIn: CGRect(x: x - 8.5, y: y - 8.5, width: 17, height: 17)), with: .color(.white))
                            context.stroke(Path(ellipseIn: CGRect(x: x - 8.5, y: y - 8.5, width: 17, height: 17)), with: .color(focusSlot.color), lineWidth: 1.3)
                            context.fill(Path(ellipseIn: CGRect(x: x - 3.4, y: y - 3.4, width: 6.8, height: 6.8)), with: .color(focusSlot.color))
                            var link = Path()
                            link.move(to: focusSlot.from)
                            link.addCurve(to: CGPoint(x: x, y: y - 10), control1: CGPoint(x: focusSlot.from.x, y: focusSlot.from.y + 140), control2: CGPoint(x: x, y: y - 160))
                            context.stroke(link, with: .color(focusSlot.color.opacity(0.65)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        } else {
                            let ring = Path(ellipseIn: CGRect(x: x - 8, y: y - 8, width: 16, height: 16))
                            context.fill(ring, with: .color(.white))
                            context.stroke(ring, with: .color(index == 0 && dropActive ? MI.blue : index == 0 ? MI.ink : MI.gry), style: StrokeStyle(lineWidth: index == 0 ? 1.2 : 1, dash: dashSlots ? [2, 2] : []))
                        }
                    }
                    if dropActive, let x = xs.first {
                        let drop = Path(ellipseIn: CGRect(x: x - 13, y: arc(x) - 13, width: 26, height: 26))
                        context.fill(drop, with: .color(MI.blue.opacity(0.12)))
                        context.stroke(drop, with: .color(MI.blue), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                if let interview = horizon?.interview {
                    context.fill(MasteryMapView.star(interview.x, arc(interview.x), 0.85), with: .color(interview.dash ? MI.gry : MI.ink))
                }
            }
            .frame(width: width, height: 828).allowsHitTesting(false)
            ForEach(sessions, id: \.id) { s in
                let y = nodeY(s), abandoned = s.score == nil
                MapLabel(text: s.date, size: 9.5, color: s.mine ? MI.sub : MI.gry, number: true).pin(s.x, arc(s.x) + 9, align: .center)
                if abandoned { MapLabel(text: "放弃", size: 10, color: MI.gry).pin(s.x, y - 26, align: .center) }
                Text(verbatim: abandoned ? "—" : "\(s.score!)").font(.system(size: abandoned ? 11 : 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(s.id == latest ? .white : s.mine ? MI.ink : abandoned ? MI.gry : MI.sub).frame(height: 17)
                    .pin(s.x, y - 8.5, align: .center).allowsHitTesting(false)
                Color.clear.frame(width: 30, height: 30).contentShape(Circle())
                    .onHover { hover = $0 ? s.id : (hover == s.id ? nil : hover) }
                    .onTapGesture { onSession(s.id) }
                    .accessibilityElement().accessibilityLabel("\(s.date) \(s.score.map(String.init) ?? "放弃")").accessibilityAddTraits(.isButton)
                    .accessibilityAction { onSession(s.id) }
                    .offset(x: s.x - 15, y: y - 15)
            }
            if let card = sessions.first(where: { $0.id == (hover ?? selectedSession) }) { nodeCard(card) }
            MapLabel(text: todayLabel, size: 10.5, color: MI.ink).pin(today, arc(today) - 34, align: .center)
            if let live {
                Button(action: onLive) { MapLabel(text: live, size: 10, color: MI.blue, weight: .medium) }.buttonStyle(.plain)
                    .pin(today, arc(today) + 14, align: .center)
            }
            if live == nil && !evaluating && !hideSlots && slots > 0, let first = xs.first, let last = xs.last {
                let mid = first + (last - first) / 2
                MapLabel(text: slotsLabel, size: 10.5, color: MI.sub).pin(mid, arc(mid) + 14, align: .center)
            }
            ForEach(horizon?.days ?? [], id: \.x) { day in MapLabel(text: day.label, size: 10, color: MI.mute).pin(day.x, arc(day.x) + 12, align: .center) }
            if let past = horizon?.past {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: past.title).font(V3.serif(14)).foregroundStyle(MI.ink).frame(height: 20)
                    if let sub = past.sub { Text(verbatim: sub).font(V3.sans(10.5)).foregroundStyle(MI.mute).frame(height: 15) }
                }.offset(x: 40, y: 760)
            }
            if let interview = horizon?.interview {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(verbatim: interview.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")).font(V3.serif(14)).foregroundStyle(interview.dash ? MI.gry : MI.ink).lineLimit(1).frame(height: 20)
                    HStack(spacing: 0) {
                        if let sub = interview.sub { Text(verbatim: sub).foregroundStyle(interview.subGray ? MI.gry : MI.mute) }
                        if let interviewLink {
                            if interview.sub != nil { Text(verbatim: " · ").foregroundStyle(MI.mute) }
                            Button("面试日程 ›", action: interviewLink).buttonStyle(.plain).foregroundStyle(MI.mute)
                        }
                    }.font(V3.sans(10.5)).frame(height: 15)
                }
                .frame(width: 300, alignment: .trailing).offset(x: width - 40 - 300, y: 760)
            }
        }
        .frame(width: width, height: 828, alignment: .topLeading)
    }

    private func nodeCard(_ card: MockMap.HorizonSession) -> some View {
        let y = nodeY(card)
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: card.title).font(V3.sans(11.5, weight: .medium)).foregroundStyle(MI.ink).frame(height: 17)
            if let score = card.score {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "\(score)").font(.system(size: 24, weight: .medium)).foregroundStyle(MI.ink)
                    Text(verbatim: "分" + (card.delta.map { " · 比上一场同岗位 \($0 >= 0 ? "+" : "")\($0)" } ?? "")).font(V3.sans(11)).foregroundStyle(MI.sub)
                }.frame(height: 28)
            }
            Text(verbatim: card.detail).font(V3.sans(11)).foregroundStyle(MI.sub).frame(height: 16)
            if card.score != nil {
                Button("查看这场报告 ›") { onReport(card.id) }.buttonStyle(.plain).font(V3.sans(11)).foregroundStyle(MI.blue).frame(height: 16)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12).frame(minWidth: 196, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xE6E3DC)))
        .shadow(color: .black.opacity(0.08), radius: 9, y: 6)
        .onHover { hover = $0 ? card.id : nil }
        .fixedSize()
        .alignmentGuide(.leading) { d in card.x < 260 ? d.width : 0 }
        .alignmentGuide(.top) { d in d.height }
        .offset(x: card.x < 260 ? card.x - 24 : card.x + 24, y: y - 23)
    }
}

// MARK: 面板与按钮

/// `.mi2-panel`：左上角信息面板，一根细竖线挂着。
struct MockPanel<Content: View>: View {
    let label: String
    var big: String?
    var bigSub: String?
    var bigSize: CGFloat = 26
    var rule: Color = MI.blue
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: label.map(String.init).joined(separator: " ")).font(V3.sans(10.5)).tracking(10.5 * 0.2).foregroundStyle(MI.mute).frame(height: 18, alignment: .top)
                .padding(.top, 1.5)
            if let big {
                HStack(alignment: .top, spacing: 10) {
                    Text(verbatim: big).font(V3.serif(bigSize)).foregroundStyle(MI.ink).lineLimit(1).frame(height: bigSize * 1.22)
                    if let bigSub { Text(verbatim: bigSub).font(V3.sans(12)).foregroundStyle(MI.sub).lineLimit(1).frame(height: 12 * 1.45).padding(.top, 14) }
                }.frame(minHeight: bigSize + 20, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 0) { content() }.padding(.bottom, 6)
        }
        .frame(width: 380, alignment: .leading)
        .overlay(alignment: .leading) { Rectangle().fill(rule).frame(width: 1.5).offset(x: -16) }
    }
}

enum MockTone { case sub, or, blue, ink, mute, gry, brown
    var color: Color {
        switch self {
        case .sub: return MI.sub
        case .or: return MI.orange
        case .blue: return MI.blue
        case .ink: return MI.ink
        case .mute: return MI.mute
        case .gry: return MI.gry
        case .brown: return Color(hex: 0x8A5216)
        }
    }
}

/// `.mi2-line`：最小高 22、行高 18、底边 4。
struct MockLine: View {
    let text: String
    var tone: MockTone = .sub
    var size: CGFloat = 12.5
    var weight: Font.Weight = .regular
    var body: some View {
        Text(verbatim: text).font(V3.sans(size, weight: weight)).foregroundStyle(tone.color)
            .lineSpacing(max(0, 18 - size * 1.2)).fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 18, alignment: .top).padding(.bottom, 4).frame(minHeight: 22, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MockChain: View {
    let items: [MockMap.ChainItem]
    var body: some View {
        items.enumerated().reduce(Text(verbatim: "")) { text, pair in
            let (index, item) = pair
            let color = item.tone == .done ? MI.ink : item.tone == .now ? MI.blue : MI.gry
            return text + (index > 0 ? Text(verbatim: " — ").foregroundColor(MI.gry) : Text(verbatim: "")) + Text(verbatim: item.label + (item.check ? " ✓" : "")).foregroundColor(color)
        }
        .font(V3.sans(11.5)).lineLimit(1).frame(height: 17, alignment: .top).frame(height: 24, alignment: .top)
    }
}

/// `.mi2-btn`。
struct MockButtonStyle: ButtonStyle {
    enum Kind { case dark, ghost, off, link, blue }
    var kind: Kind = .ghost
    var size: CGFloat = 12.5
    var go = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = kind == .dark ? (configuration.isPressed ? Color(hex: 0x33332F) : MI.ink) : kind == .blue ? MI.blue : kind == .off ? Color(hex: 0xE9E7E1) : kind == .ghost ? .white : .clear
        let stroke: Color = kind == .dark ? MI.ink : kind == .ghost ? MI.line : kind == .off ? Color(hex: 0xE9E7E1) : kind == .blue ? MI.blue : .clear
        let fg: Color = kind == .dark || kind == .blue ? .white : kind == .off ? MI.gry : kind == .link ? MI.blue : MI.ink
        let radius: CGFloat = go ? 20 : 7
        return configuration.label
            .font(V3.sans(size, weight: kind == .link ? .regular : .medium)).foregroundStyle(fg).lineLimit(1)
            .frame(height: size * 1.45)
            // CSS 是 border-box：1px 边框算在按钮尺寸里
            .padding(.horizontal, kind == .link ? 0 : go ? 21 : 13).padding(.vertical, kind == .link ? 0 : go ? 10 : 6)
            .background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(stroke, lineWidth: kind == .link ? 0 : 1))
            .opacity(enabled || kind == .off ? 1 : 0.6)
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }
}

/// 五层深度条：答到的几格着色（到目标为蓝、没到为橙），目标位置一根蓝色竖线。
struct DepthBars: View {
    let level: Double
    let target: Double
    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(Double(index) < level ? (level >= target ? MI.blue : MI.orange) : Color(hex: 0xE3E0D8)).frame(width: 44, height: 6)
                        Text(verbatim: MockMap.levels[index]).font(V3.sans(10.5)).foregroundStyle(Double(index) < level ? MI.sub : MI.gry)
                    }.frame(width: 48, alignment: .leading)
                }
            }.padding(.top, 14)
            VStack(spacing: 2) {
                Text(verbatim: "目标").font(V3.sans(10)).foregroundStyle(MI.blue)
                Rectangle().fill(MI.blue).frame(width: 1.5, height: 14)
            }.fixedSize().offset(x: target * 48 - 3 - 8, y: -2)
        }
        .frame(width: 240, height: 44, alignment: .topLeading).padding(.bottom, 8)
    }
}

/// `.mi2-menu`：浮层菜单。
struct MockMenuItem: Identifiable {
    let id: String
    var title: String
    var hint: String? = nil
    var checked = false
    var action: () -> Void
}

struct MockFloatMenu: View {
    let label: String
    let items: [MockMenuItem]
    var width: CGFloat = 260
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                Button(action: item.action) {
                    HStack(alignment: item.hint == nil ? .center : .top, spacing: 7) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: item.title).font(V3.sans(13)).foregroundStyle(MI.ink).lineLimit(1).frame(height: 13 * 1.45)
                            if let hint = item.hint { Text(verbatim: hint).font(V3.sans(11.5)).foregroundStyle(MI.mute).frame(height: 11.5 * 1.4) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if item.checked { Text(verbatim: "✓").font(V3.sans(13, weight: .medium)).foregroundStyle(MI.blue) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7).frame(minHeight: item.hint == nil ? 34 : 48, alignment: .top)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MockMenuRowStyle()).padding(.horizontal, 6)
            }
        }
        .padding(.vertical, 8).frame(width: width)
        .background(.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xE6E3DC)))
        .shadow(color: .black.opacity(0.1), radius: 15, y: 10)
        .accessibilityElement(children: .contain).accessibilityLabel(label)
    }
}

struct MockMenuRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(hover || configuration.isPressed ? Color(hex: 0xF3F1EC) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hover = $0 }
    }
}

/// `.mi2-seg`：分段选择（v2.css 后一条规则：间距 4、底色 #f3f1ec、选中描边 #d9d6cd）。
struct MockSegment<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String, disabled: Bool)]
    let current: Value
    let pick: (Value) -> Void
    var preview: ((Value?) -> Void)? = nil
    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                let on = option.value == current
                Button { pick(option.value) } label: {
                    Text(verbatim: option.title).font(V3.sans(13, weight: on ? .medium : .regular))
                        .foregroundStyle(option.disabled ? Color(hex: 0xC9C5BB) : on ? MI.ink : MI.sub)
                        .frame(height: 20).padding(.horizontal, 12).padding(.vertical, 4).frame(minWidth: 38)
                        .background(on ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? MI.line : .clear))
                        .padding(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(option.disabled)
                .onHover { inside in preview?(inside ? option.value : nil) }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3).background(Color(hex: 0xF3F1EC), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
        .accessibilityElement(children: .contain).accessibilityLabel(label)
    }
}

struct MockSwitch: View {
    @Binding var on: Bool
    var label: String
    var body: some View {
        Button { on.toggle() } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? MI.blue : Color(hex: 0xDCD9D1)).frame(width: 36, height: 20)
                Circle().fill(.white).frame(width: 16, height: 16).shadow(color: .black.opacity(0.2), radius: 1, y: 1).padding(2)
            }
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(on ? "开" : "关")
    }
}

/// `.mi2-dialog`：画布内居中的弹窗，背后压一层浅墨。
struct MockDialog<Content: View, Footer: View>: View {
    let title: String
    var sub: String?
    var width: CGFloat
    let close: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer
    var body: some View {
        ZStack {
            Color(hex: 0x1D1D1B).opacity(0.22).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title).font(V3.serif(18)).foregroundStyle(MI.ink).frame(height: 18 * 1.45)
                if let sub { Text(verbatim: sub).font(V3.sans(12)).foregroundStyle(MI.mute).lineSpacing(12 * 0.4).padding(.top, 6) }
                content()
                HStack(spacing: 10) { footer() }.frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 20)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 20).frame(width: width)
            .background(.white, in: RoundedRectangle(cornerRadius: 14)).shadow(color: .black.opacity(0.14), radius: 20, y: 16)
            .onExitCommand(perform: close)
        }
    }
}
