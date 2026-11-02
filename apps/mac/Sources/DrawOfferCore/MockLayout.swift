import Foundation

/// 「这一场」的图怎么摆与题名防撞（Web `mock-interview/v2/sessionLayout.ts`）：作答页、结束页、报告总览、
/// 首页点开一场共用一题一槽；首页默认的图用同一套候选位置给长期记忆的点名摆位。
public enum MockLayout {
    public struct Box: Equatable, Sendable {
        public var l: Double, t: Double, r: Double, b: Double
        public init(l: Double, t: Double, r: Double, b: Double) { self.l = l; self.t = t; self.r = r; self.b = b }
    }
    public enum Align: Sendable { case left, right, center }
    public struct Label: Equatable, Sendable {
        public let x: Double, y: Double
        public let align: Align
        public let box: Box
        public let lines: Int
        public let width: Double
        public let far: Bool
    }
    public struct SectorLabel: Equatable, Sendable { public let x: Double, y: Double; public let box: Box }

    public static let jobSector = "岗位要求"
    public static let materialSector = "资料"
    static let otherSector = "其他"
    static let firstAngle = -150.0

    static func clean(_ text: String) -> String { String(text.filter { !"「」…".contains($0) && !$0.isWhitespace }).lowercased() }
    static func similar(_ a: String, _ b: String) -> Bool {
        let x = clean(a), y = clean(b)
        return !x.isEmpty && !y.isEmpty && (x.contains(y) || y.contains(x))
    }
    static func short(_ text: String, _ limit: Int) -> String {
        let chars = Array(text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        return chars.count > limit ? String(chars.prefix(limit)) + "…" : String(chars)
    }

    /// 这道题归哪一组：简历题按出自哪段经历；技术题按长期记忆里同名考点所在的领域；对不上的按来源。
    public static func group(_ round: MockMap.Round, memory: [MockMap.Point], experienceOf: ((String?) -> String?)?) -> String {
        let main = round.main
        switch main.text("anchor_kind") {
        case "resume":
            let content = main.text("content")
            var quoted: String?
            if let open = content.range(of: "「"), let close = content.range(of: "」", range: open.upperBound..<content.endIndex) {
                let inner = String(content[open.upperBound..<close.lowerBound])
                if inner.count >= 4 && !inner.contains("」") { quoted = inner }
            }
            return experienceOf.flatMap { $0(main.text("anchor")) ?? $0(quoted) ?? $0(main.text("topic")) } ?? MockMap.projectSector
        case "intro": return MockMap.expressSector
        default: break
        }
        if let known = memory.first(where: { similar($0.name, round.topic) }), !known.sector.hasPrefix("__empty_"), known.sector != MockMap.projectSector { return known.sector }
        if main.text("anchor_kind") == "job" { return jobSector }
        if main.text("anchor_kind") == "material" { return materialSector }
        return otherSector
    }

    public struct Slots: Sendable {
        public let points: [MockMap.Point]
        public let sectors: [MockMap.Sector]
        public let path: [MockMap.PathStep]
        public let bounds: [Double]
        public let rounds: [MockMap.Round]
    }

    /// 一题一槽：只要这一场有题，就用这套摆法。
    public static func slots(_ detail: JSONValue, memory: [MockMap.Point], experienceOf: ((String?) -> String?)? = nil) -> Slots? {
        let rounds = MockMap.rounds(detail).filter { !$0.intro }
        guard !rounds.isEmpty else { return nil }
        var groups: [String] = []
        var groupBy: [String: String] = [:]
        for round in rounds {
            let name = short(group(round, memory: memory, experienceOf: experienceOf), 8)
            groupBy[round.main.display("id")] = name
            if !groups.contains(name) { groups.append(name) }
        }
        let ordered = groups.flatMap { name in rounds.filter { groupBy[$0.main.display("id")] == name } }
        let step = 360 / Double(ordered.count)
        var angleOf: [String: Double] = [:]
        for (index, round) in ordered.enumerated() { angleOf[round.main.display("id")] = firstAngle + Double(index) * step }
        let limit = rounds.count >= 8 ? 8 : rounds.count >= 6 ? 10 : 12
        let points = rounds.map { round in
            let id = round.main.display("id")
            return MockMap.Point(id: "q:\(id)", name: short(round.topic, limit), sector: groupBy[id] ?? otherSector, angle: angleOf[id] ?? 0, level: max(1, round.to), ask: 2)
        }
        let sectors = groups.map { name -> MockMap.Sector in
            let angles = ordered.filter { groupBy[$0.main.display("id")] == name }.map { angleOf[$0.main.display("id")] ?? 0 }
            return MockMap.Sector(name: name, angle: ((angles.min() ?? 0) + (angles.max() ?? 0)) / 2)
        }
        let bounds = groups.count > 1 ? groups.map { name in (angleOf[ordered.first { groupBy[$0.main.display("id")] == name }!.main.display("id")] ?? 0) - step / 2 } : []
        let path = rounds.map { MockMap.PathStep(id: "q:\($0.main.display("id"))", from: $0.from, to: $0.to, ok: $0.ok) }
        return Slots(points: points, sectors: sectors, path: path, bounds: bounds, rounds: rounds)
    }

    // MARK: 防撞

    public static let sectorRadius = 284.0
    public static let labelSize = 11.5
    public static let nowSize = 12.5
    public static let noteLine = 15.0
    public static let sectorSize = 11.0
    public static let subSize = 10.5
    static let labelH = 17.0
    static let pointR = 12.0
    static let nowR = 26.0
    static let strongR = 20.0

    static func charWidth(_ scalar: Character, _ size: Double) -> Double {
        (scalar.unicodeScalars.count == 1 && (0x20...0x7e).contains(scalar.unicodeScalars.first!.value) ? 0.56 : 1) * size
    }
    public static func textWidth(_ text: String, _ size: Double) -> Double { text.reduce(0) { $0 + charWidth($1, size) } }

    enum Shape { case box(Box), circle(x: Double, y: Double, r: Double) }

    static func overlap(_ box: Box, _ shape: Shape) -> Double {
        switch shape {
        case .box(let other):
            return max(0, min(box.r, other.r) - max(box.l, other.l)) * max(0, min(box.b, other.b) - max(box.t, other.t))
        case .circle(let x, let y, let r):
            let dx = max(box.l - x, 0, x - box.r), dy = max(box.t - y, 0, y - box.b)
            let distance = (dx * dx + dy * dy).squareRoot()
            return distance < r ? (r - distance) * r * 2 : 0
        }
    }

    public struct Input {
        public var g: MockMap.Geo
        public var points: [MockMap.Placed]
        public var path: [MockMap.PathStep]
        public var sectors: [MockMap.Sector]
        public var now: String? = nil
        public var nowLines = 0
        public var nowLineWidth = 0.0
        public var frame: Box
        public var sectorFrame: Box? = nil
        public var obstacles: [Box] = []
        public var labelIDs: [String]? = nil
        public var bandLabels = true
        public var subs: [String: String] = [:]
        public var strong: [String] = []
        public var gapTo: Double? = nil
    }

    static func markShapes(_ input: Input) -> [Shape] {
        let g = input.g
        var shapes: [Shape] = []
        let byID = Dictionary(input.points.map { ($0.point.id, $0) }, uniquingKeysWith: { a, _ in a })
        for placed in input.points {
            let r = placed.point.id == input.now ? nowR : input.strong.contains(placed.point.id) ? strongR : pointR
            shapes.append(.circle(x: placed.x, y: placed.y, r: r))
        }
        if let gapTo = input.gapTo {
            let target = g.ringOf(gapTo)
            for placed in input.points where placed.point.level > 0 && placed.point.level < gapTo && !placed.point.pending {
                let own = hypot(placed.x - g.cx, placed.y - g.cy)
                var radius = target
                while radius < own { let p = g.P(placed.point.angle, radius); shapes.append(.circle(x: p.x, y: p.y, r: 3)); radius += 6 }
            }
        }
        var previous: (x: Double, y: Double)?
        for step in input.path {
            guard let placed = byID[step.id] else { continue }
            let from = g.rOf(max(1, step.from)), to = g.rOf(max(1, step.to))
            let badge = g.P(placed.point.angle, from + 17 * g.k)
            shapes.append(.circle(x: badge.x, y: badge.y, r: 10))
            var radius = min(from, to)
            while radius <= max(from, to) { let p = g.P(placed.point.angle, radius); shapes.append(.circle(x: p.x, y: p.y, r: 3)); radius += 6 }
            let start = g.P(placed.point.angle, from)
            if let previous {
                let qx = g.cx + (previous.x + start.x - 2 * g.cx) * 0.15, qy = g.cy + (previous.y + start.y - 2 * g.cy) * 0.15
                let steps = max(1, Int((hypot(start.x - previous.x, start.y - previous.y) / 7).rounded(.up)))
                for index in 1..<max(steps, 1) where steps > 1 {
                    let t = Double(index) / Double(steps)
                    shapes.append(.circle(x: pow(1 - t, 2) * previous.x + 2 * (1 - t) * t * qx + t * t * start.x,
                                          y: pow(1 - t, 2) * previous.y + 2 * (1 - t) * t * qy + t * t * start.y, r: 3))
                }
            }
            previous = g.P(placed.point.angle, to)
        }
        if input.bandLabels {
            for level in 1...4 {
                let r = g.rOf(Double(level))
                shapes.append(.box(Box(l: g.cx - 32, t: g.cy - r - 7, r: g.cx - 4, b: g.cy - r + 8)))
            }
        }
        shapes.append(.box(Box(l: g.cx - 26 * g.k - 16, t: g.cy - 26 * g.k, r: g.cx + 26 * g.k + 16, b: g.cy + 26 * g.k + 22)))
        return shapes
    }

    static func outside(_ box: Box, _ frame: Box) -> Double {
        max(0, frame.l - box.l) + max(0, box.r - frame.r) + max(0, frame.t - box.t) + max(0, box.b - frame.b)
    }
    static func cost(_ box: Box, _ frame: Box, _ taken: [Shape]) -> Double {
        outside(box, frame) * 50 + taken.reduce(0) { $0 + overlap(box, $1) }
    }

    static func placeSectors(_ input: Input, _ taken: inout [Shape]) -> [String: SectorLabel] {
        let g = input.g
        let frame = input.sectorFrame ?? input.frame
        var result: [String: SectorLabel] = [:]
        for sector in input.sectors {
            let own = input.points.filter { $0.point.sector == sector.name }.map(\.point.angle)
            let reach = max(10, own.count > 1 ? ((own.max() ?? 0) - (own.min() ?? 0)) / 2 + 10 : 14)
            let width = textWidth(sector.name, sectorSize) * 1.18 + 4
            var best: (SectorLabel, Double)?
            outer: for radius in [sectorRadius, sectorRadius + 12, sectorRadius - 14, sectorRadius + 24] {
                for shift in [0, 0.35, -0.35, 0.7, -0.7, 1, -1, 1.5, -1.5] {
                    let p = g.P(sector.angle + shift * reach, radius * g.k)
                    let box = Box(l: p.x - width / 2, t: p.y - 8, r: p.x + width / 2, b: p.y + 9)
                    let value = cost(box, frame, taken)
                    if best == nil || value < best!.1 { best = (SectorLabel(x: p.x, y: p.y, box: box), value) }
                    if value == 0 { break }
                }
                if let best, best.1 == 0 { break outer }
            }
            if let best { result[sector.name] = best.0; taken.append(.box(best.0.box)) }
        }
        return result
    }

    struct Candidate { let x: Double, y: Double; let align: Align; let vertical: Int; let far: Bool; let order: Double }

    static func candidates(_ g: MockMap.Geo, _ placed: MockMap.Placed, _ gap: Double) -> [Candidate] {
        let out = atan2(placed.y - g.cy, placed.x - g.cx)
        var list: [(Candidate, Int)] = []
        var serial = 0
        for (ring, extra) in [0.0, 12, 26, 44, 66, 92, 122, 156].enumerated() {
            let count = ring < 3 ? 8 : 16
            for index in 0..<count {
                let angle = Double(index) * 2 * .pi / Double(count)
                let c = cos(angle), s = sin(angle)
                let align: Align = c > 0.3 ? .left : c < -0.3 ? .right : .center
                let vertical = s < -0.3 ? -1 : s > 0.3 ? 1 : 0
                let distance = gap + extra
                let facing = cos(angle - out)
                list.append((Candidate(x: placed.x + c * distance, y: placed.y + s * distance, align: align, vertical: vertical, far: extra >= 26,
                                       order: Double(ring) * 10 - facing * 6 + (align == .center ? 0.5 : 0)), serial))
                serial += 1
            }
        }
        return list.sorted { $0.0.order != $1.0.order ? $0.0.order < $1.0.order : $0.1 < $1.1 }.map(\.0)
    }

    static func box(_ option: Candidate, _ width: Double, _ height: Double) -> Box {
        let l = option.align == .right ? option.x - width : option.align == .center ? option.x - width / 2 : option.x
        let t = option.vertical < 0 ? option.y - height : option.vertical > 0 ? option.y : option.y - labelH / 2
        return Box(l: l, t: t, r: l + width, b: t + height)
    }

    public struct Layout: Sendable {
        public let labels: [String: Label]
        public let sectors: [String: SectorLabel]
    }

    /// 先摆组名，再逐个摆题名：当前这题先摆（连同标注列），其余按提问顺序。
    public static func layout(_ input: Input) -> Layout {
        var taken = markShapes(input) + input.obstacles.map { Shape.box($0) }
        let sectors = placeSectors(input, &taken)
        var labels: [String: Label] = [:]
        let pathIndex = { (id: String) in input.path.firstIndex { $0.id == id } ?? -1 }
        let order = input.points.enumerated().sorted { a, b in
            let x = a.element.point.id == input.now, y = b.element.point.id == input.now
            if x != y { return x }
            let i = pathIndex(a.element.point.id), j = pathIndex(b.element.point.id)
            return i != j ? i < j : a.offset < b.offset
        }.map(\.element)
        for placed in order {
            let point = placed.point
            if let ids = input.labelIDs, !ids.contains(point.id) { continue }
            let isNow = point.id == input.now
            let strong = isNow || input.strong.contains(point.id)
            let size = strong ? nowSize : labelSize
            let sub = input.subs[point.id]
            let lines = isNow ? input.nowLines : sub != nil ? 1 : 0
            let lineWidth = isNow ? input.nowLineWidth : sub.map { textWidth($0, subSize) + 4 } ?? 0
            let chars = Array(point.name)
            let shapes: [(rows: Int, width: Double)] = [
                (1, textWidth(point.name, size) + 4),
                (2, textWidth(String(chars.prefix(Int((Double(chars.count) / 2).rounded(.up)))), size) + 6),
            ]
            var best: (Label, Double)?
            for shape in shapes {
                let width = max(shape.width, lines > 0 ? lineWidth : 0)
                let height = labelH * Double(shape.rows) + Double(lines) * noteLine
                for option in candidates(input.g, placed, isNow ? nowR + 4 : strong ? strongR + 2 : pointR + 3) {
                    let candidate = box(option, width, height)
                    let value = cost(candidate, input.frame, taken)
                    if best == nil || value < best!.1 {
                        best = (Label(x: option.x, y: option.y, align: option.align, box: candidate, lines: shape.rows, width: shape.width, far: option.far), value)
                    }
                    if value == 0 { break }
                }
                if let best, best.1 == 0 { break }
            }
            if let best { labels[point.id] = best.0; taken.append(.box(best.0.box)) }
        }
        return Layout(labels: labels, sectors: sectors)
    }

    /// 这一场的点画在哪：角度是槽位，半径是答到的层。
    public static func placeOnMap(_ g: MockMap.Geo, _ points: [MockMap.Point]) -> [MockMap.Placed] {
        points.map { point in
            let p = g.P(point.angle, point.level == 0 ? 248 * g.k : g.rOf(point.level))
            return MockMap.Placed(point: point, x: p.x, y: p.y)
        }
    }

    // MARK: 各画面的范围

    public struct Stage: Sendable {
        public let at: MockMap.Geo
        public let frame: Box
        public let sectorFrame: Box
        public let obstacles: [Box]
    }

    public static let overview = Stage(at: MockMap.Geo(cx: 790, cy: 300, k: 0.95), frame: Box(l: 470, t: 72, r: 1140, b: 640),
                                       sectorFrame: Box(l: 470, t: 8, r: 1145, b: 650), obstacles: [Box(l: 860, t: 0, r: 1151, b: 72)])
    public static let home = Stage(at: MockMap.Geo(cx: 770, cy: 316, k: 1), frame: Box(l: 450, t: 64, r: 1140, b: 650),
                                   sectorFrame: Box(l: 450, t: 8, r: 1145, b: 660), obstacles: [Box(l: 680, t: 20, r: 1151, b: 60)])
    public static let session = Stage(at: MockMap.Geo(cx: 1040, cy: 318, k: 0.86), frame: Box(l: 752, t: 84, r: 1356, b: 584),
                                      sectorFrame: Box(l: 742, t: 72, r: 1362, b: 586), obstacles: [])

    static func input(on stage: Stage, points: [MockMap.Point], sectors: [MockMap.Sector], path: [MockMap.PathStep], rotation: Double, targetLevel: Double, targetLabel: String) -> Input {
        let g = stage.at
        let placed = placeOnMap(g, points.map { var p = $0; p.angle -= rotation; return p })
        let rotated = sectors.map { MockMap.Sector(name: $0.name, angle: $0.angle - rotation) }
        let t = g.P(28, g.ringOf(targetLevel))
        let pill = Box(l: t.x + 8, t: t.y - 22, r: t.x + 8 + textWidth(targetLabel, 10.5) + 18, b: t.y)
        return Input(g: g, points: placed, path: path, sectors: rotated, frame: stage.frame, sectorFrame: stage.sectorFrame, obstacles: stage.obstacles + [pill])
    }

    public static func homeSession(_ slots: Slots, targetLevel: Double, targetLabel: String) -> Layout {
        layout(input(on: home, points: slots.points, sectors: slots.sectors, path: slots.path, rotation: 0, targetLevel: targetLevel, targetLabel: targetLabel))
    }

    /// 首页默认的图（长期记忆里的点）：名字连同下面一行说明一起防撞；先摆先问、选中、带说明的点，再按被问概率。
    public static func homeMap(points: [MockMap.Placed], sectors: [MockMap.Sector], targetLevel: Double, targetLabel: String, subs: [String: String], strong: [String], gaps: Bool) -> Layout {
        let rank = { (p: MockMap.Point) in (strong.contains(p.id) ? 2 : 0) + (subs[p.id] != nil ? 1 : 0) }
        let sorted = points.enumerated().sorted { a, b in
            let x = rank(a.element.point), y = rank(b.element.point)
            if x != y { return x > y }
            return a.element.point.ask != b.element.point.ask ? a.element.point.ask > b.element.point.ask : a.offset < b.offset
        }.map(\.element)
        var base = input(on: home, points: [], sectors: sectors.filter { !$0.name.hasPrefix("__empty_") }, path: [], rotation: 0, targetLevel: targetLevel, targetLabel: targetLabel)
        base.points = sorted; base.subs = subs; base.strong = strong; base.gapTo = gaps ? targetLevel : nil
        return layout(base)
    }

    public static func overviewLayout(points: [MockMap.Point], sectors: [MockMap.Sector], path: [MockMap.PathStep], rotation: Double, targetLevel: Double, targetLabel: String) -> Layout {
        layout(input(on: overview, points: points, sectors: sectors, path: path, rotation: rotation, targetLevel: targetLevel, targetLabel: targetLabel))
    }
}
