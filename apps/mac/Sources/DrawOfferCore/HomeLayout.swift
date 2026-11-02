import Foundation

// 首页星图摆放：移植 Web `homeImprove/layout.ts`（1151×828 设计稿坐标）。
// 主星落在右侧几处错开的位置，下面的点朝外散开；简历连到所有主星时放在中间当枢纽；最后推开太近的点并挑标签朝向。

public enum HomeSide: Sendable { case r, l, t, b }
public struct HomePlaced: Sendable {
    public var x: Double; public var y: Double; public var side: HomeSide
    public init(x: Double, y: Double, side: HomeSide) { self.x = x; self.y = y; self.side = side }
}
public struct HomeLayout: Sendable {
    public var at: [String: HomePlaced]
    public var region: (cx: Double, cy: Double, rx: Double, ry: Double, titleY: Double)?
}

public enum HomeCanvas {
    public static let width = 1151.0
    public static let height = 828.0
    public static let horizonTop = 668.0
    static let horizonR = 2397.0
    public static func horizonY(_ x: Double, top: Double = horizonTop) -> Double {
        top + horizonR - (horizonR * horizonR - pow(x - width / 2, 2)).squareRoot()
    }
}

public enum HomeLayouts {
    static let area = (l: 490.0, r: 1085.0, t: 112.0, b: 600.0)
    static let text = (l: 470.0, lowL: 385.0, lowT: 150.0, r: 1138.0, t: 70.0)
    static let center = (x: 800.0, y: 345.0)
    static let slots: [Int: [(Double, Double)]] = [
        1: [(760, 300)], 2: [(650, 235), (930, 430)], 3: [(640, 220), (965, 235), (815, 470)],
        4: [(610, 200), (925, 165), (665, 455), (995, 420)],
        5: [(600, 190), (880, 150), (1020, 330), (650, 450), (880, 505)],
        6: [(590, 180), (840, 140), (1030, 255), (640, 420), (870, 380), (1000, 520)],
    ]

    static func hash(_ text: String) -> Double {
        var value: UInt32 = 2166136261
        for unit in text.utf16 { value = (value ^ UInt32(unit)) &* 16777619 }
        return Double(value % 1000) / 1000
    }
    static func jitter(_ key: String, _ span: Double) -> Double { (hash(key) - 0.5) * 2 * span }

    static func clamp(_ x: inout Double, _ y: inout Double, top: Double) {
        x = min(area.r, max(area.l, x))
        y = min(min(area.b, HomeCanvas.horizonY(x) - 72), max(top, y))
    }

    struct Box { var l: Double, r: Double, t: Double, b: Double }
    static func overlap(_ a: Box, _ b: Box) -> Double {
        max(0, min(a.r, b.r) - max(a.l, b.l) + 6) * max(0, min(a.b, b.b) - max(a.t, b.t) + 6)
    }
    public static func textWidth(_ text: String, _ size: Double) -> Double {
        text.unicodeScalars.reduce(0) { $0 + (($1.value >= 0x2E80 && $1.value <= 0xFFEF) ? size : size * 0.6) }
    }
    static func labelBox(label: String, sub: String?, sym: HomeSym, badge: Int?, at: (Double, Double), side: HomeSide) -> Box {
        let big = sym == .anchor
        let gap = big ? 23.0 : sym == .planet ? 21 : 13
        let width = max(textWidth(label, big ? 20 : 12), sub.map { textWidth($0, big ? 11 : 10.5) } ?? 0) + (badge != nil ? 20 : 0)
        let height = (big ? 27.0 : 16) + (sub != nil ? 15 : 0)
        switch side {
        case .r: return Box(l: at.0 + gap, r: at.0 + gap + width, t: at.1 - 10, b: at.1 - 10 + height)
        case .l: return Box(l: at.0 - gap - width, r: at.0 - gap, t: at.1 - 10, b: at.1 - 10 + height)
        case .t: return Box(l: at.0 - width / 2, r: at.0 + width / 2, t: at.1 - gap - height, b: at.1 - gap)
        case .b: return Box(l: at.0 - width / 2, r: at.0 + width / 2, t: at.1 + gap, b: at.1 + gap + height)
        }
    }
    static func fits(_ box: Box) -> Bool {
        box.l >= (box.t >= text.lowT ? text.lowL : text.l) && box.r <= text.r && box.t >= text.t && box.b <= HomeCanvas.horizonY((box.l + box.r) / 2) - 40
    }
    static func sideAngle(_ side: HomeSide) -> Double { switch side { case .r: 0; case .b: .pi / 2; case .l: .pi; case .t: -.pi / 2 } }
    static func angleGap(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi); return d > .pi ? 2 * .pi - d : d }
    static func sideOf(_ dx: Double, _ dy: Double) -> HomeSide {
        let length = max(hypot(dx, dy), 1)
        if dx / length > 0.38 { return .r }
        if dx / length < -0.38 { return .l }
        return dy < 0 ? .t : .b
    }

    public static func layout(_ scene: HomeScene) -> HomeLayout {
        var at: [String: HomePlaced] = [:]
        let top = !scene.mapTitle.isEmpty || !scene.mapNote.isEmpty ? 165.0 : area.t
        func place(_ x: Double, _ y: Double) -> (Double, Double) { var x = x, y = y; clamp(&x, &y, top: top); return (x, y) }
        let anchors = scene.nodes.filter { $0.sym == .anchor }
        let hub = scene.planets.count == 1 && anchors.count >= 2 && anchors.allSatisfy { scene.planets[0].links.contains($0.id) }
        let count = min(6, max(1, anchors.count))
        for (index, anchor) in anchors.prefix(6).enumerated() {
            var x: Double, y: Double
            if hub {
                let angle = -Double.pi * 0.82 + Double(index) * 2 * .pi / Double(anchors.count) + jitter(anchor.id, 0.18)
                x = center.x + cos(angle) * 235; y = center.y + sin(angle) * 185
            } else {
                (x, y) = slots[count]![index]
                x += jitter(anchor.id, 16); y += jitter("\(anchor.id)y", 14)
            }
            let point = place(x, y)
            at[anchor.id] = HomePlaced(x: point.0, y: point.1, side: y < 175 ? .r : .t)
        }
        if hub { at[scene.planets[0].id] = HomePlaced(x: center.x, y: center.y, side: .b) }

        func fan(_ parent: HomeMapNode, origin: (Double, Double), from: (Double, Double), radius: Double) {
            let kids = scene.nodes.filter { $0.parent == parent.id && $0.sym != .anchor }
            guard !kids.isEmpty else { return }
            let base = atan2(origin.1 - from.1, origin.0 - from.0)
            let step = kids.count > 4 ? 0.72 : 0.92
            for (index, kid) in kids.enumerated() {
                let angle = base + (Double(index) - Double(kids.count - 1) / 2) * step + jitter(kid.id, 0.16)
                let r = radius + jitter("\(kid.id)r", 14) + (kid.sym == .topic ? -18 : 0)
                let point = place(origin.0 + cos(angle) * r, origin.1 + sin(angle) * r)
                at[kid.id] = HomePlaced(x: point.0, y: point.1, side: sideOf(point.0 - origin.0, point.1 - origin.1))
                if kid.sym == .topic { fan(kid, origin: point, from: origin, radius: 92) }
            }
        }
        for anchor in anchors {
            guard let origin = at[anchor.id] else { continue }
            if hub { fan(anchor, origin: (origin.x, origin.y), from: (center.x, center.y), radius: 108); continue }
            let dx = origin.x > center.x ? 1.0 : -1.0
            let dir = origin.y < center.y ? (dx * 0.7, 1.0) : (dx * 0.6, 0.8)
            fan(anchor, origin: (origin.x, origin.y), from: (origin.x - dir.0 * 50, origin.y - dir.1 * 50), radius: 108)
        }
        var corner = 0.0
        for planet in scene.planets where at[planet.id] == nil {
            if planet.near, let target = planet.links.first.flatMap({ at[$0] }) {
                let point = place(target.x - 115, target.y - 22)
                at[planet.id] = HomePlaced(x: point.0, y: point.1, side: .b)
                continue
            }
            let point = place(985 + jitter(planet.id, 10), 560 - corner * 56)
            at[planet.id] = HomePlaced(x: point.0, y: point.1, side: .r)
            corner += 1
        }
        relax(scene, &at, top: top)
        clearRegion(scene, &at, top: top)
        chooseSides(scene, &at)
        return HomeLayout(at: at, region: region(scene, at))
    }

    static func relax(_ scene: HomeScene, _ at: inout [String: HomePlaced], top: Double) {
        let ids = (scene.nodes.map(\.id) + scene.planets.map(\.id)).filter { at[$0] != nil }
        let anchors = Set(scene.nodes.filter { $0.sym == .anchor }.map(\.id))
        for _ in 0..<60 {
            var moved = false
            for i in ids.indices {
                for j in ids.indices where j > i {
                    var a = at[ids[i]]!, b = at[ids[j]]!
                    let need = anchors.contains(ids[i]) && anchors.contains(ids[j]) ? 190.0 : anchors.contains(ids[i]) || anchors.contains(ids[j]) ? 70 : 58
                    let dx = b.x - a.x, dy = (b.y - a.y) * 1.6
                    let distance = max(hypot(dx, dy), 0.01)
                    if distance >= need { continue }
                    let push = (need - distance) / 2, ux = dx / distance, uy = dy / distance / 1.6
                    let fixedA = anchors.contains(ids[i]) && !anchors.contains(ids[j])
                    let fixedB = anchors.contains(ids[j]) && !anchors.contains(ids[i])
                    if !fixedA { a.x -= ux * push * (fixedB ? 2 : 1); a.y -= uy * push * (fixedB ? 2 : 1); clamp(&a.x, &a.y, top: top); at[ids[i]] = a }
                    if !fixedB { b.x += ux * push * (fixedA ? 2 : 1); b.y += uy * push * (fixedA ? 2 : 1); clamp(&b.x, &b.y, top: top); at[ids[j]] = b }
                    moved = true
                }
            }
            if !moved { break }
        }
    }

    static func clearRegion(_ scene: HomeScene, _ at: inout [String: HomePlaced], top: Double) {
        let members = Set(scene.region?.members ?? [])
        let points = members.compactMap { at[$0] }
        guard points.count >= 2 else { return }
        let l = points.map(\.x).min()! - 70, r = points.map(\.x).max()! + 120
        let t = points.map(\.y).min()! - 50, b = points.map(\.y).max()! + 50
        let cx = (l + r) / 2, cy = (t + b) / 2, rx = (r - l) / 2, ry = (b - t) / 2
        func inside(_ x: Double, _ y: Double) -> Bool { pow((x - cx) / (rx + 40), 2) + pow((y - cy) / (ry + 40), 2) < 1 }
        for anchor in scene.nodes where anchor.sym == .anchor && !members.contains(anchor.id) {
            let group = scene.nodes.filter { $0.group == anchor.id && !members.contains($0.id) }
            guard let origin = at[anchor.id], !scene.nodes.contains(where: { $0.group == anchor.id && members.contains($0.id) }) else { continue }
            let dx = origin.x - cx == 0 ? 1 : origin.x - cx, dy = origin.y - cy == 0 ? 1 : origin.y - cy
            let length = hypot(dx, dy)
            var step = 0
            while step < 12, let now = at[anchor.id], inside(now.x, now.y) || inside(now.x, now.y - 40) {
                for item in group {
                    guard var point = at[item.id] else { continue }
                    point.x += dx / length * 18; point.y += dy / length * 18
                    clamp(&point.x, &point.y, top: top); at[item.id] = point
                }
                step += 1
            }
        }
    }

    static func chooseSides(_ scene: HomeScene, _ at: inout [String: HomePlaced]) {
        var taken: [Box] = scene.nodes.compactMap { at[$0.id] }.map { Box(l: $0.x - 7, r: $0.x + 7, t: $0.y - 7, b: $0.y + 7) }
            + scene.planets.compactMap { at[$0.id] }.map { Box(l: $0.x - 16, r: $0.x + 16, t: $0.y - 8, b: $0.y + 8) }
        for edge in scene.edges where edge.prereq {
            guard let a = at[edge.from], let b = at[edge.to] else { continue }
            let length = max(hypot(b.x - a.x, b.y - a.y), 1)
            let x = (a.x + b.x) / 2 - (b.y - a.y) / length * 12, y = (a.y + b.y) / 2 + (b.x - a.x) / length * 12
            taken.append(Box(l: x - 14, r: x + 14, t: y - 10, b: y + 4))
        }
        func choose(_ id: String, label: String, sub: String?, sym: HomeSym, badge: Int?, order: [HomeSide]) {
            guard var me = at[id] else { return }
            let own = Box(l: me.x - 17, r: me.x + 17, t: me.y - 9, b: me.y + 9)
            var best: (HomeSide, Box, Double)?
            var seen: [HomeSide] = []
            for side in order where !seen.contains(side) {
                seen.append(side)
                let box = labelBox(label: label, sub: sub, sym: sym, badge: badge, at: (me.x, me.y), side: side)
                let cost = (fits(box) ? 0 : 1e6) + taken.reduce(0) { $0 + (overlap($1, own) > 0 ? 0 : overlap(box, $1)) }
                if best == nil || cost < best!.2 { best = (side, box, cost) }
                if cost == 0 { break }
            }
            me.side = best!.0; at[id] = me; taken.append(best!.1)
        }
        let ordered = scene.nodes.filter { $0.sym == .anchor } + scene.nodes.filter { $0.sym != .anchor }
        for node in ordered {
            guard let me = at[node.id] else { continue }
            let lineIDs = scene.nodes.filter { $0.parent == node.id }.map(\.id) + (node.parent.map { [$0] } ?? [])
                + scene.planets.filter { $0.links.contains(node.id) }.map(\.id)
            let lines = lineIDs.compactMap { at[$0] }.map { atan2($0.y - me.y, $0.x - me.x) }
            let parent = node.parent.flatMap { at[$0] }
            func clearance(_ side: HomeSide) -> Double {
                (lines.isEmpty ? .pi : lines.map { angleGap($0, sideAngle(side)) }.min()!) + (side == .t ? 0.05 : 0)
            }
            let order: [HomeSide] = node.sym == .anchor
                ? [HomeSide.t, .b, .r, .l].sorted { clearance($0) > clearance($1) }
                : [parent.map { sideOf(me.x - $0.x, me.y - $0.y) } ?? me.side, .r, .l, .b, .t]
            choose(node.id, label: node.label, sub: node.sub, sym: node.sym, badge: node.badge, order: order)
        }
        for planet in scene.planets {
            guard let me = at[planet.id] else { continue }
            choose(planet.id, label: planet.label, sub: planet.sub, sym: .planet, badge: nil, order: [me.side, .r, .l, .b, .t])
        }
    }

    public static func region(_ scene: HomeScene, _ at: [String: HomePlaced]) -> (cx: Double, cy: Double, rx: Double, ry: Double, titleY: Double)? {
        guard let members = scene.region?.members else { return nil }
        let byId = Dictionary(scene.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let boxes: [Box] = members.compactMap { id in
            guard let point = at[id] else { return nil }
            let box = byId[id].map { labelBox(label: $0.label, sub: $0.sub, sym: $0.sym, badge: $0.badge, at: (point.x, point.y), side: point.side) }
                ?? Box(l: point.x, r: point.x, t: point.y, b: point.y)
            return Box(l: min(box.l, point.x - 10), r: max(box.r, point.x + 10), t: min(box.t, point.y - 10), b: max(box.b, point.y + 10))
        }
        guard boxes.count >= 2 else { return nil }
        let l = boxes.map(\.l).min()!, r = boxes.map(\.r).max()!, t = boxes.map(\.t).min()!, b = boxes.map(\.b).max()!
        let cy = (t + b) / 2, ry = max(70, (b - t) / 2 * 1.22 + 8)
        return ((l + r) / 2, cy, max(90, (r - l) / 2 * 1.22 + 8), ry, cy - ry - 9)
    }

    /// 时间轴：今天固定在 730，过去往左、之后往右（Web `placeMarks`）。
    public static let todayX = 730.0
    public static func placeMarks(_ marks: [HomeMark], now: Date) -> [(HomeMark, Double)] {
        let past = marks.filter { !$0.future }.sorted { $0.at > $1.at }
        let future = marks.filter(\.future).sorted { $0.at < $1.at }
        var placed: [(HomeMark, Double)] = []
        var edge = todayX - 40
        for mark in past {
            let days = now.timeIntervalSince(mark.at) / 86_400
            let x = max(260, min(edge, todayX - 30 - days * 12))
            placed.append((mark, x)); edge = x - 82
        }
        edge = todayX + 60
        for mark in future {
            let days = mark.at.timeIntervalSince(now) / 86_400
            let x = min(1060, max(edge, todayX + 50 + days * 26))
            placed.append((mark, x)); edge = x + 110
        }
        return placed.filter { $0.1 >= 250 }
    }
}
