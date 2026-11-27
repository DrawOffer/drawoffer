import Foundation

// 首页知识图谱的排布（Web `assistant/home/knowledgeGraph.ts`）：图摆在一块随节点数长大的白板上，首页小图和展开大图各算一份。
// 多段经历共用的技术放在正中间当核心；每段经历和每场面试是外圈的一段，从外往里：经历 → 业务 → 做成的事 → 共用技术，
// 只这段经历用到的技术挂在它外侧。外圈的顺序按共用关系排（共用越多越挨着），连向核心的线短、交叉少。
// 知识点跟着技术展开，最后按实际占地把叠着的推开、给标签选方向。同一份图每次算出来都一样。
public enum KnowledgeGraph {
    public enum Side: String, Sendable, CaseIterable { case right, left, top, bottom }

    public struct World: Sendable, Equatable { public let width: Double; public let height: Double }

    public struct Spot: Sendable, Equatable {
        public let key: String
        public let x: Double
        public let y: Double
        public let side: Side
    }

    public struct Layout: Sendable {
        public let spots: [Spot]
        public let world: World
        public var at: [String: Spot] { Dictionary(spots.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }) }
    }

    struct Rings {
        var experience = 0.96, business = 0.76, work = 0.56, own = 0.84, session = 0.9, core = 0.14, coreStep = 0.05, coreMax = 0.4
    }

    static let ring = Rings()
    // 首页小图节点少、没有做成的事：业务离经历远一些免得字压在一起，核心圈再撑开一点
    static let homeRing: Rings = {
        var ring = Rings()
        ring.business = 0.62; ring.session = 0.92; ring.core = 0.2; ring.coreStep = 0.06; ring.coreMax = 0.42
        return ring
    }()

    static let pointSize: [Double] = [13, 18, 24]
    // 白板至少这么大，节点多了按每个节点占的地方往外长
    static let minWorld = (width: 1151.0, height: 640.0)
    static let nodeRoom = 36000.0
    static let worldRatio = 1.8
    static let worldEdge = 16.0
    static let fanRadius = 72.0
    static let fanStep = 0.62
    // 超过这么多点的簇排成弧
    static let arcFrom = 7
    static let arc = (depth: 200.0, pitch: 34.0)
    static let groupGap = 14.0
    static let spreadPasses = 120
    // 场次在外圈占的角度比经历小
    static func armWeight(_ kind: HomeGraph.Kind) -> Double { kind == .session ? 0.55 : 1 }
    static let orderRounds = 40
    static let down: Set<String> = ["EH", "HH", "HT", "ET"]
    static let tau = Double.pi * 2

    public static func worldOf(_ count: Int) -> World {
        let width = max(minWorld.width, (Double(count) * nodeRoom * worldRatio).squareRoot().rounded())
        return World(width: width, height: max(minWorld.height, (width / worldRatio).rounded()))
    }

    /// 图上写的名字：括号里的举例不上图。
    public static func shortName(_ name: String) -> String {
        let head = name.components(separatedBy: CharacterSet(charactersIn: "（("))[0].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? name : head
    }

    /// 经历写成“公司 · 岗位”时分两行。
    public static func experienceLines(_ name: String) -> [String] {
        guard let range = name.range(of: " · ") else { return [name] }
        return [String(name[..<range.lowerBound]), String(name[range.upperBound...])]
    }

    // MARK: 排布用的节点

    final class Item {
        let key: String
        let kind: HomeGraph.Kind
        let size: Double
        var x: Double, y: Double
        var side: Side
        var labelX = 0.0, labelY = 0.0
        let labelWidth: Double, labelHeight: Double
        init(_ node: HomeGraph.Node, x: Double, y: Double, side: Side) {
            key = node.id; kind = node.kind; self.x = x; self.y = y; self.side = side
            switch node.kind {
            case .technology: size = 32
            case .highlight: size = 13
            case .experience: size = 0
            default: size = pointSize[min(max(Int(node.size), 0), 2)]
            }
            let label = KnowledgeGraph.labelSize(node)
            labelWidth = label.width; labelHeight = label.height
        }
    }

    struct Box { var left, right, top, bottom: Double }
    typealias Line = (Item, Item)

    static func textWidth(_ text: String, _ size: Double) -> Double {
        var width = 0.0
        for char in text {
            let value = char.unicodeScalars.first?.value ?? 0
            if (0x3000...0x9FFF).contains(value) || (0xFF00...0xFFEF).contains(value) { width += size }
            else if char == " " { width += size * 0.3 }
            else if char == "·" { width += size * 0.45 }
            else { width += size * 0.6 }
        }
        return width.rounded(.up)
    }

    static func labelSize(_ node: HomeGraph.Node) -> (width: Double, height: Double) {
        if node.kind == .experience {
            let lines = experienceLines(node.name)
            return (max(textWidth(lines[0], 15), lines.count > 1 ? textWidth(lines[1], 12.5) : 0) + 16, lines.count > 1 ? 44 : 28)
        }
        let font = node.kind == .technology ? 14 : node.kind == .point && node.status == .weak ? 13 : 12.5
        return (textWidth(shortName(node.name), font), node.kind == .technology ? 18 : 17)
    }

    static func labelBox(_ node: Item) -> Box {
        if node.kind == .experience {
            return Box(left: node.x - node.labelWidth / 2, right: node.x + node.labelWidth / 2, top: node.y - node.labelHeight / 2, bottom: node.y + node.labelHeight / 2)
        }
        return Box(left: node.labelX, right: node.labelX + node.labelWidth, top: node.labelY, bottom: node.labelY + node.labelHeight)
    }

    // 圆点和标签合起来占的范围
    static func extent(_ node: Item) -> Box {
        let box = labelBox(node), radius = node.size / 2
        return Box(left: min(box.left, node.x - radius), right: max(box.right, node.x + radius), top: min(box.top, node.y - radius), bottom: max(box.bottom, node.y + radius))
    }

    static func placeLabel(_ node: Item) {
        guard node.kind != .experience else { return }
        let radius = node.size / 2, gap = 7.0
        node.labelX = node.side == .right ? node.x + radius + gap : node.side == .left ? node.x - radius - gap - node.labelWidth : node.x - node.labelWidth / 2
        node.labelY = node.side == .top ? node.y - radius - 5 - node.labelHeight : node.side == .bottom ? node.y + radius + 5 : node.y - node.labelHeight / 2
    }

    // 硬边界：polish 只是尽量不撞，这里保证圆点和标签都在画布里
    static func contain(_ node: Item, _ field: Box) {
        let box = extent(node)
        node.x += max(0, field.left - box.left) + min(0, field.right - box.right)
        node.y += max(0, field.top - box.top) + min(0, field.bottom - box.bottom)
        placeLabel(node)
    }

    static func overlaps(_ a: Box, _ b: Box) -> Bool {
        a.left < b.right + 5 && b.left < a.right + 5 && a.top < b.bottom + 2 && b.top < a.bottom + 2
    }

    // 线段穿没穿过这个方框
    static func through(_ a: Item, _ b: Item, _ box: Box) -> Bool {
        let dx = b.x - a.x, dy = b.y - a.y
        var from = 0.0, to = 1.0
        func clip(_ step: Double, _ room: Double) -> Bool {
            if step == 0 { return room >= 0 }
            if step < 0 { from = max(from, room / step) } else { to = min(to, room / step) }
            return from <= to
        }
        return clip(-dx, a.x - box.left + 3) && clip(dx, box.right + 3 - a.x) && clip(-dy, a.y - box.top + 3) && clip(dy, box.bottom + 3 - a.y)
    }

    // 这个节点现在的位置和标签方向碰到多少东西；只看它自己
    static func cost(_ node: Item, _ nodes: [Item], _ lines: [Line], _ field: Box) -> Double {
        var total = 0.0
        let box = labelBox(node), reach = extent(node)
        if reach.left < field.left || reach.right > field.right || reach.top < field.top || reach.bottom > field.bottom { total += 1000 }
        for other in nodes where other !== node {
            let theirs = labelBox(other)
            if overlaps(box, theirs) { total += 1000 }
            let radius = other.size / 2
            if other.x + radius > box.left - 3 && other.x - radius < box.right + 3 && other.y + radius > box.top - 2 && other.y - radius < box.bottom + 2 { total += 1000 }
            let own = node.size / 2
            if node.x + own > theirs.left - 3 && node.x - own < theirs.right + 3 && node.y + own > theirs.top - 2 && node.y - own < theirs.bottom + 2 { total += 1000 }
            if other.kind != .experience && node.kind != .experience && hypot(node.x - other.x, node.y - other.y) < (node.size + other.size) / 2 + 12 { total += 500 }
        }
        // 自己的线也不穿自己的字
        for (a, b) in lines where (node.kind != .experience || (a !== node && b !== node)) && through(a, b, box) { total += 300 }
        return total
    }

    static func polish(_ nodes: [Item], _ lines: [Line], _ field: Box) {
        for step in [18.0, 9.0] {
            for node in nodes {
                let origin = (x: node.x, y: node.y, side: node.side)
                var best = (x: origin.x, y: origin.y, side: origin.side, score: cost(node, nodes, lines, field))
                for side in node.kind == .experience ? [origin.side] : Side.allCases {
                    for dx in [-1.0, 0, 1] {
                        for dy in [-1.0, 0, 1] {
                            node.x = origin.x + dx * step
                            node.y = origin.y + dy * step
                            node.side = side
                            placeLabel(node)
                            // 挪动要有代价，没撞到东西就留在原来算出来的位置
                            let score = cost(node, nodes, lines, field) + (abs(dx) + abs(dy)) * 4
                            if score < best.score { best = (node.x, node.y, side, score) }
                        }
                    }
                }
                node.x = best.x; node.y = best.y; node.side = best.side
                placeLabel(node)
            }
        }
    }

    static func sideOf(_ angle: Double) -> Side {
        cos(angle) > 0.3 ? .right : cos(angle) < -0.3 ? .left : sin(angle) < 0 ? .top : .bottom
    }

    // 点很多的簇排成一道弧，字都在弧外，线不会穿过别的字
    static func arcOut(_ parent: Item, _ children: [Item], _ facing: Double, _ field: Box) {
        let across: Double = cos(facing) < 0 ? -1 : 1
        let tall = min(field.bottom - field.top - 20, Double(children.count) * arc.pitch)
        for (index, child) in children.enumerated() {
            let rise = (Double(index) / Double(children.count - 1) - 0.5) * 2
            child.x = parent.x + across * arc.depth * (1 - rise * rise * 0.9).squareRoot()
            child.y = parent.y + rise * tall / 2
            child.side = across < 0 ? .left : .right
            placeLabel(child)
        }
    }

    // 扇形朝远离中心的方向打开
    static func fan(_ parent: Item, _ children: [Item], _ facing: Double, _ field: Box) {
        if children.count > arcFrom { arcOut(parent, children, facing, field); return }
        let span = Double(max(0, children.count - 1)) * fanStep
        for (index, child) in children.enumerated() {
            let angle = facing + (children.count > 1 ? Double(index) / Double(children.count - 1) - 0.5 : 0) * span
            let radius = fanRadius + parent.size / 2
            child.x = parent.x + cos(angle) * radius
            child.y = parent.y + sin(angle) * radius * 0.86
            child.side = sideOf(angle)
            placeLabel(child)
        }
    }

    static func reach(_ group: [Item]) -> Box {
        let boxes = group.map(extent)
        return Box(left: boxes.map(\.left).min()!, right: boxes.map(\.right).max()!, top: boxes.map(\.top).min()!, bottom: boxes.map(\.bottom).max()!)
    }

    static func nudge(_ group: [Item], _ box: inout Box, _ dx: Double, _ dy: Double) {
        for node in group {
            node.x += dx; node.y += dy
            if node.kind != .experience { node.labelX += dx; node.labelY += dy }
        }
        box.left += dx; box.right += dx; box.top += dy; box.bottom += dy
    }

    // 一组（上级和它的扇形）当一整块，互相让开，都留在画布里；占地算一次，之后跟着平移
    static func spread(_ groups: [[Item]], _ field: Box) {
        var boxes = groups.map(reach)
        for _ in 0..<spreadPasses {
            var settled = true
            for i in groups.indices {
                for j in groups.indices where j > i {
                    let a = boxes[i], b = boxes[j]
                    let wide = min(a.right, b.right) - max(a.left, b.left) + groupGap
                    let tall = min(a.bottom, b.bottom) - max(a.top, b.top) + groupGap
                    if wide <= 0 || tall <= 0 { continue }
                    settled = false
                    let across = wide < tall
                    let sign: Double = (across ? a.left + a.right - b.left - b.right : a.top + a.bottom - b.top - b.bottom) >= 0 ? 1 : -1
                    let push = ((across ? wide : tall) / 2) * sign
                    nudge(groups[i], &boxes[i], across ? push : 0, across ? 0 : push)
                    nudge(groups[j], &boxes[j], across ? -push : 0, across ? 0 : -push)
                }
            }
            for index in groups.indices {
                let box = boxes[index]
                nudge(groups[index], &boxes[index], max(0, field.left - box.left) + min(0, field.right - box.right), max(0, field.top - box.top) + min(0, field.bottom - box.bottom))
            }
            if settled { return }
        }
    }

    // MARK: 结构：知识点跟谁、外圈的每一段、共用技术

    /// 知识点跟着第一个上级（技术，或问到它的那一场）；保持先后顺序。
    static func leavesOf(_ nodes: [HomeGraph.Node], _ edges: [HomeGraph.Edge]) -> (owner: [String: String], leaves: [(String, [String])]) {
        let kinds = Dictionary(nodes.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        var owner: [String: String] = [:]
        var order: [String] = []
        for edge in edges where kinds[edge.dst] == .point && (edge.kind == "TP" || edge.kind == "SN") && kinds[edge.src] != nil && owner[edge.dst] == nil {
            owner[edge.dst] = edge.src
            order.append(edge.dst)
        }
        var leaves: [(String, [String])] = []
        var at: [String: Int] = [:]
        for leaf in order {
            let parent = owner[leaf]!
            if let index = at[parent] { leaves[index].1.append(leaf) } else { at[parent] = leaves.count; leaves.append((parent, [leaf])) }
        }
        return (owner, leaves)
    }

    // 外圈的一段：一段经历（连同它的业务、做成的事和只它用到的技术），或一场面试
    struct Arm { let key: String; let kind: HomeGraph.Kind; let members: [String]; var core: [String] = []; var angle = 0.0 }

    static func downMap(_ edges: [HomeGraph.Edge]) -> [String: [HomeGraph.Edge]] {
        var map: [String: [HomeGraph.Edge]] = [:]
        for edge in edges where down.contains(edge.kind) || edge.kind == "SN" { map[edge.src, default: []].append(edge) }
        return map
    }

    // 每段经历往下走到的技术（经过业务、做成的事），每场面试连着的技术和知识点
    static func armsOf(_ nodes: [HomeGraph.Node], _ edges: [HomeGraph.Edge]) -> [Arm] {
        let kinds = Dictionary(nodes.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        let next = downMap(edges)
        return nodes.filter { $0.kind == .experience || $0.kind == .session }.map { node in
            var seen: Set<String> = [], order: [String] = []
            func walk(_ key: String) {
                for edge in next[key] ?? [] where !seen.contains(edge.dst) && kinds[edge.dst] != .experience && kinds[edge.dst] != .session {
                    seen.insert(edge.dst); order.append(edge.dst)
                    if kinds[edge.dst] == .highlight { walk(edge.dst) }
                }
            }
            walk(node.id)
            return Arm(key: node.id, kind: node.kind, members: order)
        }
    }

    /// 两段及以上经历都用到的技术是核心，每个只画一次；没有这样的技术时，退一步看经历和场次一起。按出现先后排。
    public static func sharedTechnologies(nodes: [HomeGraph.Node], edges: [HomeGraph.Edge]) -> [String] {
        let technologies = Set(nodes.filter { $0.kind == .technology }.map(\.id))
        let arms = armsOf(nodes, edges)
        func count(_ kinds: Set<HomeGraph.Kind>) -> [String] {
            var found: [String: Int] = [:], order: [String] = []
            for arm in arms where kinds.contains(arm.kind) {
                for key in arm.members where technologies.contains(key) {
                    if found[key] == nil { order.append(key) }
                    found[key, default: 0] += 1
                }
            }
            return order.filter { found[$0]! >= 2 }
        }
        let shared = count([.experience])
        return shared.isEmpty ? count([.experience, .session]) : shared
    }

    static func norm(_ angle: Double) -> Double { (angle.truncatingRemainder(dividingBy: tau) + tau).truncatingRemainder(dividingBy: tau) }
    static func circularMean(_ angles: [Double]) -> Double { atan2(angles.reduce(0) { $0 + sin($1) }, angles.reduce(0) { $0 + cos($1) }) }

    /// 稳定排序：值一样时保持原来的先后。
    static func stable<T>(_ items: [T], by value: (T) -> Double) -> [T] {
        items.enumerated().map { ($0.offset, $0.element, value($0.element)) }
            .sorted { $0.2 != $1.2 ? $0.2 < $1.2 : $0.0 < $1.0 }.map(\.1)
    }

    // 外圈顺序：经历挨着它用到的核心技术，核心技术挨着用到它的经历，来回调几轮，连向中间的线就短、交叉少
    static func orderArms(_ arms: inout [Arm], _ core: [String]) -> [String: Double] {
        var coreAngle = Dictionary(core.enumerated().map { ($1, Double($0) / Double(max(1, core.count)) * tau) }, uniquingKeysWith: { a, _ in a })
        let total = arms.reduce(0) { $0 + armWeight($1.kind) }
        let weightTotal = total == 0 ? 1 : total
        for index in arms.indices { arms[index].angle = Double(index) / Double(max(1, arms.count)) * tau }
        for _ in 0..<orderRounds {
            for index in arms.indices where !arms[index].core.isEmpty {
                arms[index].angle = circularMean(arms[index].core.map { coreAngle[$0]! })
            }
            let sorted = stable(Array(arms.indices)) { norm(arms[$0].angle) }
            let start = sorted.first.map { norm(arms[$0].angle) } ?? 0
            var used = 0.0
            for index in sorted {
                arms[index].angle = start + (used + armWeight(arms[index].kind) / 2) / weightTotal * tau
                used += armWeight(arms[index].kind)
            }
            for key in core {
                let near = arms.filter { $0.core.contains(key) }.map(\.angle)
                if !near.isEmpty { coreAngle[key] = circularMean(near) }
            }
        }
        // 几个核心技术被同样几段经历用到时算出来的角度几乎一样，会叠成一团：保留先后顺序，在圈上等分摆开
        if core.count > 1 {
            let step = tau / Double(core.count)
            let sorted = stable(core) { norm(coreAngle[$0]!) }
            let turn = circularMean(sorted.enumerated().map { coreAngle[$1]! - Double($0) * step })
            for (index, key) in sorted.enumerated() { coreAngle[key] = turn + Double(index) * step }
        }
        return coreAngle
    }

    // MARK: 排布

    public static func layout(nodes: [HomeGraph.Node], edges: [HomeGraph.Edge], home: Bool = false) -> Layout {
        let ring = home ? homeRing : self.ring
        let world = worldOf(nodes.count)
        guard !nodes.isEmpty else { return Layout(spots: [], world: world) }
        let field = Box(left: worldEdge, right: world.width - worldEdge, top: worldEdge, bottom: world.height - worldEdge)
        let center = (x: (field.left + field.right) / 2, y: (field.top + field.bottom) / 2)
        let radius = (x: (field.right - field.left) / 2 - 90, y: (field.bottom - field.top) / 2 - 36)
        func at(_ angle: Double, _ ring: Double) -> (x: Double, y: Double) { (center.x + cos(angle) * radius.x * ring, center.y + sin(angle) * radius.y * ring) }
        let (owner, leaves) = leavesOf(nodes, edges)
        let placed = nodes.map { Item($0, x: center.x, y: center.y, side: .right) }
        let byKey = Dictionary(placed.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let raw = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func put(_ key: String, _ point: (x: Double, y: Double)) { byKey[key]?.x = point.x; byKey[key]?.y = point.y }

        let core = sharedTechnologies(nodes: nodes, edges: edges)
        let shared = Set(core)
        var arms = armsOf(nodes, edges)
        for index in arms.indices { arms[index].core = arms[index].members.filter { shared.contains($0) } }
        let coreAngle = orderArms(&arms, core)
        let coreRing = min(ring.coreMax, ring.core + ring.coreStep * Double(core.count))
        for key in core { put(key, core.count == 1 ? center : at(coreAngle[key]!, coreRing)) }

        var placedKeys = shared
        let sum = arms.reduce(0) { $0 + armWeight($1.kind) }
        let total = sum == 0 ? 1 : sum
        var upOf: [String: String] = [:]
        for edge in edges where down.contains(edge.kind) && upOf[edge.dst] == nil { upOf[edge.dst] = edge.src }
        for arm in arms {
            // 这一段在外圈占的角度，里面的节点在这个扇面里摆开
            let span = armWeight(arm.kind) / total * tau
            put(arm.key, at(arm.angle, arm.kind == .session ? ring.session : ring.experience))
            placedKeys.insert(arm.key)
            func lay(_ keys: [String], _ ring: Double, _ width: Double, _ angleOf: (String) -> Double) {
                let ordered = stable(keys, by: angleOf)
                for (index, key) in ordered.enumerated() {
                    let offset = ordered.count > 1 ? (Double(index) / Double(ordered.count - 1) - 0.5) * width : 0
                    put(key, at(arm.angle + offset, ring))
                    placedKeys.insert(key)
                }
            }
            let mine = arm.members.filter { !placedKeys.contains($0) && owner[$0] == nil }
            let business = mine.filter { raw[$0]?.kind == .highlight && raw[$0]?.facet == "business" }
            let work = mine.filter { raw[$0]?.kind == .highlight && raw[$0]?.facet != "business" }
            let own = mine.filter { raw[$0]?.kind != .highlight }
            // 同一段里朝哪个核心技术就往哪边排：业务、做成的事按各自连向的核心技术在扇面里的方向排，线就不交叉
            func toward(_ key: String) -> Double {
                let targets = edges.filter { $0.src == key && shared.contains($0.dst) }.map { coreAngle[$0.dst]! }
                let below = edges.filter { $0.src == key && $0.kind == "HH" }.flatMap { edge in
                    edges.filter { $0.src == edge.dst && shared.contains($0.dst) }.map { coreAngle[$0.dst]! }
                }
                let all = targets + below
                guard !all.isEmpty else { return 0 }
                let mean = circularMean(all)
                return atan2(sin(mean - arm.angle), cos(mean - arm.angle))
            }
            lay(business, ring.business, span * 0.45, toward)
            let businessRank = Dictionary(stable(business, by: toward).enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            lay(work, ring.work, span * 0.6) { Double(businessRank[upOf[$0] ?? ""] ?? 0) * 10 + toward($0) }
            // 只这一段用到的技术挂在外侧，左右交替
            for (index, key) in own.enumerated() {
                let side: Double = index % 2 == 1 ? -1 : 1
                put(key, at(arm.angle + side * span * (0.32 + 0.1 * Double(index / 2)), arm.kind == .session ? ring.experience : ring.own))
                placedKeys.insert(key)
            }
        }
        // 没有落到任何一段里的节点放在中间附近
        for (index, node) in placed.enumerated() where !placedKeys.contains(node.key) && owner[node.key] == nil {
            put(node.key, at(Double(index) / Double(placed.count) * tau, 0.4))
        }
        // 知识点围着上级展开，朝离开中心的方向
        for (parentKey, kids) in leaves {
            guard let parent = byKey[parentKey] else { continue }
            fan(parent, kids.compactMap { byKey[$0] }, atan2(parent.y - center.y, parent.x - center.x), field)
        }
        let lines: [Line] = edges.compactMap { edge in
            guard let a = byKey[edge.src], let b = byKey[edge.dst] else { return nil }
            return (a, b)
        }
        for node in placed {
            node.side = node.kind == .experience ? .top : sideOf(atan2(node.y - center.y, node.x - center.x))
            placeLabel(node)
        }
        let kidsOf = Dictionary(leaves.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        let groups = placed.filter { owner[$0.key] == nil }.map { node in [node] + (kidsOf[node.key] ?? []).compactMap { byKey[$0] } }
        spread(groups, field)
        polish(placed, lines, field)
        for node in placed { contain(node, field) }
        return Layout(spots: placed.map { Spot(key: $0.key, x: $0.x, y: $0.y, side: $0.side) }, world: world)
    }

    // MARK: 首页小图

    // 首页小图只画骨架：经历、它服务的业务、多段经历共用的技术和最近几场面试。中间藏掉的一层（做成的事）不单画，
    // 线从上一层直接连到它下面露出来的那一层；每个节点最多连 3 个技术，挑被最多经历和场次用到的。
    // 一条线都连不上的技术和场次不上小图，免得飘着看不出是什么。
    static let homeLinks = 3

    public static func homeSkeleton(nodes: [HomeGraph.Node], edges: [HomeGraph.Edge]) -> (nodes: [HomeGraph.Node], edges: [HomeGraph.Edge]) {
        let byKey = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let arms = armsOf(nodes, edges)
        var reach: [String: Int] = [:]
        for arm in arms { for key in arm.members where byKey[key]?.kind == .technology { reach[key, default: 0] += 1 } }
        var core = Set(sharedTechnologies(nodes: nodes, edges: edges))
        // 只有一段经历时没有共用技术：取这段经历用到的技术，后面照样每个节点最多连几个
        if core.isEmpty { core = Set(arms.filter { $0.kind == .experience }.flatMap { $0.members.filter { byKey[$0]?.kind == .technology } }) }
        func byReach(_ a: String, _ b: String) -> Bool { (reach[a] ?? 0) != (reach[b] ?? 0) ? (reach[a] ?? 0) > (reach[b] ?? 0) : a < b }
        // 一场面试问到的技术都不在核心里时，带上它问得最多的那个技术，场次才有线连着
        for arm in arms where arm.kind == .session {
            let technologies = arm.members.filter { byKey[$0]?.kind == .technology }
            if !technologies.isEmpty, !technologies.contains(where: core.contains) { core.insert(technologies.sorted(by: byReach)[0]) }
        }
        func shown(_ key: String) -> Bool {
            guard let node = byKey[key] else { return false }
            switch node.kind {
            case .experience, .session: return true
            case .highlight: return node.facet == "business"
            case .technology: return core.contains(key)
            case .point: return false
            }
        }
        let next = downMap(edges)
        var linked: [HomeGraph.Edge] = []
        for node in nodes where shown(node.id) && node.kind != .technology {
            // 往下走，穿过没上小图的业务和做成的事，碰到上小图的节点就停
            var found: [String] = [], seen: Set<String> = [node.id]
            func walk(_ key: String) {
                for edge in next[key] ?? [] where !seen.contains(edge.dst) {
                    seen.insert(edge.dst)
                    if shown(edge.dst) { if !found.contains(edge.dst) { found.append(edge.dst) } }
                    else if byKey[edge.dst]?.kind == .highlight { walk(edge.dst) }
                }
            }
            walk(node.id)
            for dst in found where byKey[dst]?.kind != .technology { linked.append(HomeGraph.Edge(src: node.id, dst: dst, kind: "EH")) }
            let kind = node.kind == .session ? "SN" : node.kind == .highlight ? "HT" : "ET"
            for dst in found.filter({ byKey[$0]?.kind == .technology }).sorted(by: byReach).prefix(homeLinks) {
                linked.append(HomeGraph.Edge(src: node.id, dst: dst, kind: kind))
            }
        }
        let touched = Set(linked.flatMap { [$0.src, $0.dst] })
        let kept = nodes.filter { shown($0.id) && ($0.kind == .experience || touched.contains($0.id)) }
        let keys = Set(kept.map(\.id))
        return (kept, linked.filter { keys.contains($0.src) && keys.contains($0.dst) })
    }
}

/// 首页图谱的一张画（Web `feedbackStage.ts` 里与界面无关的部分）：首页小图和展开大图各一份坐标（都摊成 -0.5…0.5），
/// 哪些线平时收着、每个节点收着几个下级。
public struct HomeGraphStage: Sendable {
    public struct Line: Sendable, Equatable {
        public let a: String
        public let b: String
        public let dashed: Bool
        /// 全图里平时不画，选中相关节点时才画
        public var soft: Bool
    }

    public let nodes: [HomeGraph.Node]
    /// 多段经历共用的技术，放在中间、字更大
    public let core: Set<String>
    /// 首页小图：骨架节点的位置（-0.37…0.37 × -0.43…0.43，四周给标签留地方）
    public let home: [String: KnowledgeGraph.Spot]
    public let homeLines: [HomeGraph.Edge]
    /// 展开大图：全部节点的位置（-0.5…0.5）
    public let full: [String: KnowledgeGraph.Spot]
    public let lines: [Line]
    public let up: [String: [String]]
    public let down: [String: [String]]
    /// 展开后平时摆出来的节点：知识点都收着
    public let skeleton: Set<String>

    public init(graph: HomeGraph) { self.init(nodes: graph.nodes, edges: graph.edges) }

    public init(nodes: [HomeGraph.Node], edges: [HomeGraph.Edge]) {
        self.nodes = nodes
        let byKey = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        core = Set(KnowledgeGraph.sharedTechnologies(nodes: nodes, edges: edges))
        let skeletonGraph = KnowledgeGraph.homeSkeleton(nodes: nodes, edges: edges)
        home = Self.spread(KnowledgeGraph.layout(nodes: skeletonGraph.nodes, edges: skeletonGraph.edges, home: true), fill: (0.74, 0.86))
        homeLines = skeletonGraph.edges
        let full = Self.spread(KnowledgeGraph.layout(nodes: nodes, edges: edges), fill: (1, 1))
        self.full = full
        skeleton = Set(nodes.filter { $0.kind != .point }.map(\.id))

        var up: [String: [String]] = [:], down: [String: [String]] = [:]
        var lines: [Line] = []
        for edge in edges where edge.kind != "EE" {
            guard let a = byKey[edge.src], let b = byKey[edge.dst] else { continue }
            if edge.kind == "PP" { lines.append(Line(a: a.id, b: b.id, dashed: true, soft: false)); continue }
            down[a.id, default: []].append(b.id)
            up[b.id, default: []].append(a.id)
            // 场次连向技术的线全图里照画；连向没答好之外的知识点（只在选中时露出）才收着
            lines.append(Line(a: a.id, b: b.id, dashed: false, soft: edge.kind == "SN" && b.kind == .point && b.tone != .hot))
        }
        // 没拆出业务的经历会直接连一大把共用技术：全图里每段经历只画连向 3 个共用技术的线（挑用到的经历最多的），
        // 只这段用到的技术照画；其余收着，选中这段经历时才画。每个技术至少留一条线，不会飘着
        let direct = lines.indices.filter { !lines[$0].soft && byKey[lines[$0].a]?.kind == .experience && byKey[lines[$0].b]?.kind == .technology }
        var users: [String: Int] = [:]
        for index in direct { users[lines[index].b, default: 0] += 1 }
        for hub in nodes where hub.kind == .experience {
            let shared = direct.filter { lines[$0].a == hub.id && (users[lines[$0].b] ?? 0) > 1 }
                .sorted { (users[lines[$0].b] ?? 0) != (users[lines[$1].b] ?? 0) ? (users[lines[$0].b] ?? 0) > (users[lines[$1].b] ?? 0) : lines[$0].b < lines[$1].b }
            for index in shared.dropFirst(3) { lines[index].soft = true }
        }
        // 因此一条线都不剩的技术，留下离它最近的那段经历连过来的线
        func far(_ line: Line) -> Double {
            guard let a = full[line.a], let b = full[line.b] else { return .infinity }
            return hypot(a.x - b.x, a.y - b.y)
        }
        var techs: [String] = []
        for index in direct where !techs.contains(lines[index].b) { techs.append(lines[index].b) }
        for tech in techs {
            if lines.contains(where: { ($0.a == tech || $0.b == tech) && !$0.soft }) { continue }
            if let nearest = direct.filter({ lines[$0].b == tech }).min(by: { far(lines[$0]) < far(lines[$1]) }) { lines[nearest].soft = false }
        }
        self.lines = lines
        self.up = up
        self.down = down
    }

    /// 坐标摊到 -0.5…0.5 再乘 fill：横竖各自铺满（Web 摊到设计稿大小）。
    static func spread(_ layout: KnowledgeGraph.Layout, fill: (Double, Double)) -> [String: KnowledgeGraph.Spot] {
        guard !layout.spots.isEmpty else { return [:] }
        let xs = layout.spots.map(\.x), ys = layout.spots.map(\.y)
        let x0 = xs.min()!, x1 = xs.max()!, y0 = ys.min()!, y1 = ys.max()!
        let spanX = max(1, x1 - x0), spanY = max(1, y1 - y0)
        return Dictionary(layout.spots.map { spot in
            (spot.key, KnowledgeGraph.Spot(key: spot.key, x: (spot.x - (x0 + x1) / 2) * fill.0 / spanX, y: (spot.y - (y0 + y1) / 2) * fill.1 / spanY, side: spot.side))
        }, uniquingKeysWith: { a, _ in a })
    }

    /// 展开后看得到的节点：骨架，加上选中节点的直接下级（点技术展开考点）。
    public func shown(selected: String?) -> Set<String> {
        var out = skeleton
        if let selected { out.insert(selected); out.formUnion(down[selected] ?? []) }
        return out
    }

    /// 选中节点时亮着的：它自己和直接相连的上下级；其余压淡。
    public func lit(_ key: String) -> Set<String> {
        Set([key] + (up[key] ?? []) + (down[key] ?? []))
    }

    /// 收着的下级有几个，标在节点右上角（选中的那个已经展开，不标）。
    public func hidden(_ key: String, shown: Set<String>, selected: String?) -> Int {
        guard key != selected else { return 0 }
        return (down[key] ?? []).filter { !shown.contains($0) }.count
    }

    /// 展开后要画的线：两头都看得到；平时收着的线只在连着选中节点时画。
    public func visibleLines(shown: Set<String>, selected: String?) -> [Line] {
        lines.filter { line in
            shown.contains(line.a) && shown.contains(line.b) && (!line.soft || line.a == selected || line.b == selected)
        }
    }
}

// MARK: 展开大图按实际字宽让开（Web `feedbackStage` 的 spread）

extension HomeGraphStage {
    /// 一个节点在画布上占的框：中心和半宽半高（已含四周留白）
    public struct Footprint: Sendable, Equatable {
        public let key: String
        public let kind: HomeGraph.Kind
        public var x: Double
        public var y: Double
        public let halfWidth: Double
        public let halfHeight: Double
        public init(key: String, kind: HomeGraph.Kind, x: Double, y: Double, halfWidth: Double, halfHeight: Double) {
            self.key = key; self.kind = kind; self.x = x; self.y = y; self.halfWidth = halfWidth; self.halfHeight = halfHeight
        }
    }

    public struct Rect: Sendable, Equatable {
        public let left: Double, top: Double, right: Double, bottom: Double
        public init(left: Double, top: Double, right: Double, bottom: Double) { self.left = left; self.top = top; self.right = right; self.bottom = bottom }
    }

    /// 展开大图上节点名大约多宽多高（与界面字号一致：经历 19 衬线、共用技术 20、其他技术 14、其余 13；业务多一个小方块，场次多一个话筒）。
    /// 返回的是半宽半高，四周按 Web 再留 10 / 6。
    public static func footprintSize(_ node: HomeGraph.Node, core: Bool, scale: Double = 1, picked: Bool = false) -> (halfWidth: Double, halfHeight: Double) {
        let k = scale * (picked ? 1.15 : 1)
        let font: Double = switch node.kind {
        case .experience: 19
        case .technology: core ? 20 : 14
        default: 13
        }
        let size = font * k
        var width = KnowledgeGraph.textWidth(node.short, size)
        if node.business { width += 12 * scale }
        if node.kind == .session { width += 15 * scale }
        // 节点四周的内边距 4 / 3
        let box = (width: width + 8, height: size * 1.3 + 6)
        return (box.width / 2 + 10, box.height / 2 + 6)
    }

    /// 按实际占地把叠着的节点推开、避开标题和收起按钮、留在画布里；经历、技术这类大节点少动，让小的让路。
    /// 窄的时候（右边开着对话栏）知识点不会再压在技术的名字上。同样的输入得到同样的结果。
    public static func untangle(_ items: [Footprint], bounds: Rect, blocks: [Rect], rounds: Int = 160) -> [String: (x: Double, y: Double)] {
        var nodes = items
        func heavy(_ kind: HomeGraph.Kind) -> Double { kind == .experience ? 3 : kind == .technology ? 1.6 : 1 }
        func clamp(_ index: Int) {
            let w = nodes[index].halfWidth, h = nodes[index].halfHeight
            nodes[index].x = max(bounds.left + w, min(bounds.right - w, nodes[index].x))
            nodes[index].y = max(bounds.top + h, min(bounds.bottom - h, nodes[index].y))
        }
        for index in nodes.indices { clamp(index) }
        for _ in 0..<rounds {
            var clash = 0
            for i in nodes.indices {
                for j in nodes.indices where j > i {
                    let a = nodes[i], b = nodes[j]
                    let ox = a.halfWidth + b.halfWidth - abs(a.x - b.x), oy = a.halfHeight + b.halfHeight - abs(a.y - b.y)
                    if ox <= 0 || oy <= 0 { continue }
                    clash += 1
                    let sa = heavy(b.kind) / (heavy(a.kind) + heavy(b.kind)), sb = 1 - sa
                    if ox < oy {
                        let sign: Double = a.x <= b.x ? -1 : 1
                        nodes[i].x += sign * ox * sa; nodes[j].x -= sign * ox * sb
                    } else {
                        let sign: Double = a.y <= b.y ? -1 : 1
                        nodes[i].y += sign * oy * sa; nodes[j].y -= sign * oy * sb
                    }
                }
                let a = nodes[i], w = a.halfWidth, h = a.halfHeight
                for block in blocks {
                    let ox = min(a.x + w, block.right) - max(a.x - w, block.left), oy = min(a.y + h, block.bottom) - max(a.y - h, block.top)
                    if ox <= 0 || oy <= 0 { continue }
                    clash += 1
                    // 从最近的一边挪出去，挪不出画布的方向不选
                    let exits = [(block.left - w, a.y), (block.right + w, a.y), (a.x, block.top - h), (a.x, block.bottom + h)]
                        .filter { $0.0 - w >= bounds.left - 0.5 && $0.0 + w <= bounds.right + 0.5 && $0.1 - h >= bounds.top - 0.5 && $0.1 + h <= bounds.bottom + 0.5 }
                    if let best = exits.min(by: { hypot($0.0 - a.x, $0.1 - a.y) < hypot($1.0 - a.x, $1.1 - a.y) }) {
                        nodes[i].x = best.0; nodes[i].y = best.1
                    }
                }
                clamp(i)
            }
            if clash == 0 { break }
        }
        return Dictionary(nodes.map { ($0.key, (x: $0.x, y: $0.y)) }, uniquingKeysWith: { a, _ in a })
    }
}
