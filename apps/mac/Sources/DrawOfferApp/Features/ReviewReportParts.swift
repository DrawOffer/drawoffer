import DrawOfferCore
import SwiftUI

// 面试复盘第一屏的三张图（Figma 09 · 10.01 总览；Web `interviews/report/ReviewCharts.tsx`）：环形图、每道题得分、通用能力，
// 都按设计稿坐标画，随卡片等比缩放；以及「这场之后，记忆里变了什么」（Figma 09 · 11 记忆变化状态 11.01–11.04，Web `ReviewMemory.tsx`）。

enum RRC {
    static let blue = Color(hex: 0x3F6FD8)
    static let orange = Color(hex: 0xC9651B)
    static let ink = Color(hex: 0x1D1D1B)
    static let text = Color(hex: 0x55554F)
    static let sub = Color(hex: 0x6C6C65)
    static let faint = Color(hex: 0xA9A9A3)
    static let line = Color(hex: 0xE4E4E0)
    static let thin = Color(hex: 0xECECEA)
    static let targetLine = Color(hex: 0xCFDCF5)
}

/// 设计稿坐标里的一张图：按宽度等比缩放，`viewBox` 的左上角是 (x, y)。
private struct RRChart: View {
    let box: CGRect
    let draw: (inout GraphicsContext) -> Void
    var body: some View {
        Canvas { context, size in
            let scale = size.width / box.width
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            draw(&context)
        }
        .aspectRatio(box.width / box.height, contentMode: .fit)
    }
}

private func label(_ context: inout GraphicsContext, _ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 11, weight: Font.Weight = .regular,
                   color: Color, anchor: UnitPoint = .center, serif: Bool = false) {
    let font = serif ? V3.serif(size) : V3.sans(size, weight: weight)
    // y 是基线：中文字体的基线约在字号的 0.8 处
    context.draw(Text(verbatim: text).font(font).foregroundColor(color), at: CGPoint(x: x, y: y - size * 0.35), anchor: anchor)
}

/// 环形图：每层一圈（了解在最外），每道题一根线落在它答到的那一层，没到目标打叉；中间总分。
struct RRScoreRing: View {
    let questions: [MockRV.Question]
    let target: Int
    let score: Int?
    private static let cx: CGFloat = 260, cy: CGFloat = 272
    private static let bands: [CGFloat] = [164, 144.5, 125, 105, 85.5], stops: [CGFloat] = [154, 134.6, 115, 95, 76]

    var body: some View {
        RRChart(box: CGRect(x: 0, y: 88, width: 520, height: 420)) { context in
            let total = questions.count
            let step = total > 0 ? 360.0 / Double(total) : 0
            let targetRadius = Self.bands[max(0, min(4, target - 1))]
            func polar(_ r: CGFloat, _ degree: Double) -> CGPoint {
                let a = degree * .pi / 180
                return CGPoint(x: Self.cx + r * CGFloat(sin(a)), y: Self.cy - r * CGFloat(cos(a)))
            }
            func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: Self.cx - r, y: Self.cy - r, width: r * 2, height: r * 2)) }
            for r in Self.bands { context.stroke(circle(r), with: .color(r <= targetRadius ? RRC.targetLine : RRC.thin)) }
            context.fill(circle(targetRadius), with: .color(Color(hex: 0xEAF0FB).opacity(0.55)))
            context.stroke(circle(targetRadius), with: .color(RRC.blue), style: StrokeStyle(lineWidth: 1.25, dash: [5, 4]))
            for r in Self.bands where r < targetRadius { context.stroke(circle(r), with: .color(RRC.targetLine)) }
            for (index, name) in MockRV.levels.enumerated() {
                label(&context, name, Self.cx, Self.cy - Self.stops[index] + 3.5, size: 10, color: Self.bands[index] <= targetRadius ? Color(hex: 0x8EA6DC) : RRC.faint)
            }
            let placed = questions.enumerated().map { index, q -> (MockRV.Question, Double, CGPoint) in
                let degree = step / 2 + Double(index) * step
                let r = (q.level ?? 0) <= 0 ? Self.bands[0] : Self.stops[min(5, q.level ?? 1) - 1]
                return (q, degree, polar(r, degree))
            }
            if placed.count >= 3 {
                var curve = Path()
                let points = placed.map(\.2)
                let at = { (i: Int) in points[(i + points.count) % points.count] }
                curve.move(to: points[0])
                for i in 0..<points.count {
                    let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
                    curve.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                                   control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
                }
                context.stroke(curve, with: .color(Color(hex: 0xC9C9C3)))
            }
            for (q, degree, stop) in placed {
                let color = q.outcome == .unrecorded ? RRC.faint : q.weak ? RRC.orange : RRC.blue
                let start = polar(168, degree), badge = polar(179, degree)
                context.stroke(Path { $0.move(to: start); $0.addLine(to: stop) }, with: .color(color), lineWidth: 2)
                if q.weak {
                    context.stroke(Path { p in
                        p.move(to: CGPoint(x: stop.x - 4, y: stop.y - 4)); p.addLine(to: CGPoint(x: stop.x + 4, y: stop.y + 4))
                        p.move(to: CGPoint(x: stop.x + 4, y: stop.y - 4)); p.addLine(to: CGPoint(x: stop.x - 4, y: stop.y + 4))
                    }, with: .color(color), lineWidth: 2)
                } else {
                    context.fill(Path(ellipseIn: CGRect(x: stop.x - 4.5, y: stop.y - 4.5, width: 9, height: 9)), with: .color(color))
                }
                let badgeRect = CGRect(x: badge.x - 9.5, y: badge.y - 9.5, width: 19, height: 19)
                context.fill(Path(ellipseIn: badgeRect), with: .color(.white))
                context.stroke(Path(ellipseIn: badgeRect), with: .color(color))
                label(&context, "\(q.no)", badge.x, badge.y + 4, weight: .medium, color: color)
                let right = degree <= 180
                let title = q.title.count > 8 ? String(q.title.prefix(7)) + "…" : q.title
                label(&context, title, badge.x + (right ? 14 : -14), badge.y + 4, color: q.weak ? RRC.ink : RRC.sub, anchor: right ? .leading : .trailing)
            }
            context.fill(circle(66), with: .color(.white))
            context.stroke(circle(66), with: .color(Color(hex: 0xE4E4E0)))
            label(&context, "总分", Self.cx, Self.cy - 34, color: RRC.sub)
            label(&context, score.map(String.init) ?? "—", Self.cx, Self.cy + 18, size: 50, color: RRC.ink, serif: true)
            label(&context, "/ 100", Self.cx, Self.cy + 47, color: RRC.faint)
            context.stroke(Path { $0.move(to: CGPoint(x: 96, y: 485)); $0.addLine(to: CGPoint(x: 118, y: 485)) }, with: .color(RRC.blue), lineWidth: 2)
            label(&context, "答到位", 124, 489, size: 12, color: RRC.sub, anchor: .leading)
            context.stroke(Path { $0.move(to: CGPoint(x: 186, y: 485)); $0.addLine(to: CGPoint(x: 208, y: 485)) }, with: .color(RRC.orange), lineWidth: 2)
            label(&context, "没到目标", 214, 489, size: 12, color: RRC.sub, anchor: .leading)
            context.stroke(Path { $0.move(to: CGPoint(x: 288, y: 485)); $0.addLine(to: CGPoint(x: 310, y: 485)) }, with: .color(RRC.blue), style: StrokeStyle(lineWidth: 1.25, dash: [5, 4]))
            label(&context, "目标：答到「\(MockRV.levelLabel(target))」", 316, 489, size: 12, color: RRC.sub, anchor: .leading)
        }
        .accessibilityLabel("每道题答到哪一层，总分 \(score.map(String.init) ?? "—")")
    }
}

/// 每道题得分：底线 y=200，100 分高 136。
struct RRScoreBars: View {
    let questions: [MockRV.Question]
    var body: some View {
        RRChart(box: CGRect(x: 0, y: 48, width: 523, height: 184)) { context in
            let base: CGFloat = 200, scale: CGFloat = 1.36, left: CGFloat = 44, width: CGFloat = 459
            for value in [0, 50, 100] {
                let y = base - CGFloat(value) * scale
                context.stroke(Path { $0.move(to: CGPoint(x: left, y: y)); $0.addLine(to: CGPoint(x: left + width, y: y)) }, with: .color(RRC.thin))
                label(&context, "\(value)", 36, y + 4, color: RRC.faint, anchor: .trailing)
            }
            let slot = width / CGFloat(max(1, questions.count)), bar = min(26, slot * 0.6)
            for (index, q) in questions.enumerated() {
                let center = left + slot * (CGFloat(index) + 0.5)
                if let score = q.score {
                    let height = CGFloat(score) * scale
                    context.fill(Path(roundedRect: CGRect(x: center - bar / 2, y: base - height, width: bar, height: height), cornerRadius: 3), with: .color(q.weak ? RRC.orange : RRC.blue))
                    label(&context, "\(score)", center, base - height - 6, size: 12, weight: q.weak ? .medium : .regular, color: q.weak ? RRC.ink : RRC.text)
                }
                label(&context, "\(q.no)", center, base + 20, size: 12, color: RRC.sub)
            }
        }
        .accessibilityLabel("每道题得分")
    }
}

/// 通用能力雷达：圆心 (168,142)，半径 66；以往是灰色虚线，最弱一项标橙。
struct RRAbilityRadar: View {
    let abilities: [MockRV.Ability]
    let weakest: String?
    var body: some View {
        let count = abilities.count
        let vertex = { (index: Int, ratio: CGFloat) -> CGPoint in
            let angle = Double(index) / Double(count) * 2 * .pi
            return CGPoint(x: 168 + 66 * ratio * CGFloat(sin(angle)), y: 142 - 66 * ratio * CGFloat(cos(angle)))
        }
        let side = { (x: CGFloat) -> Int in abs(x - 168) < 8 ? 0 : x > 168 ? 1 : -1 }
        let text = { (a: MockRV.Ability) in "\(a.label) \(a.score)" }
        let width = { (s: String) in CGFloat(s.reduce(0) { $0 + ($1.unicodeScalars.first!.value > 255 ? 12 : 7) }) }
        var left: CGFloat = 0, right: CGFloat = 340
        for (index, item) in abilities.enumerated() {
            let x = vertex(index, 1).x, s = side(x), w = width(text(item))
            let from = s == 0 ? x - w / 2 : s > 0 ? x + 9 : x - 9 - w
            left = min(left, from - 8); right = max(right, from + w + 8)
        }
        let ratio = { (score: Double) in CGFloat(max(0.08, min(1, score / 100))) }
        return RRChart(box: CGRect(x: left, y: 44, width: right - left, height: 200)) { context in
            func shape(_ ratios: [CGFloat]) -> Path {
                Path { p in for (i, r) in ratios.enumerated() { i == 0 ? p.move(to: vertex(i, r)) : p.addLine(to: vertex(i, r)) }; p.closeSubpath() }
            }
            for r in [1, 0.66, 0.33] as [CGFloat] { context.stroke(shape(Array(repeating: r, count: count)), with: .color(RRC.thin)) }
            for index in 0..<count { context.stroke(Path { $0.move(to: CGPoint(x: 168, y: 142)); $0.addLine(to: vertex(index, 1)) }, with: .color(RRC.thin)) }
            if abilities.contains(where: { $0.past != nil }) {
                context.stroke(shape(abilities.map { ratio($0.past ?? Double($0.score)) }), with: .color(RRC.faint), style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
            }
            let mine = shape(abilities.map { ratio(Double($0.score)) })
            context.fill(mine, with: .color(RRC.blue.opacity(0.1)))
            context.stroke(mine, with: .color(RRC.blue), lineWidth: 1.75)
            for (index, item) in abilities.enumerated() {
                let dot = vertex(index, ratio(Double(item.score))), at = vertex(index, 1), s = side(at.x), low = item.key == weakest
                context.fill(Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)), with: .color(low ? RRC.orange : RRC.blue))
                label(&context, text(item), at.x + CGFloat(s) * 9, s != 0 ? at.y + 4 : at.y + (at.y < 142 ? -9 : 19), size: 12, weight: low ? .medium : .regular,
                      color: low ? RRC.ink : RRC.sub, anchor: s == 0 ? .center : s > 0 ? .leading : .trailing)
            }
        }
        .accessibilityLabel(abilities.map(text).joined(separator: "，"))
    }
}

/// 「这场之后，记忆里变了什么」：之前练的这次答上来了、跨题的习惯、等级变化；还在记入时按预计时间再读。
struct RRMemorySection: View {
    @Environment(SessionStore.self) private var session
    let mockID: String
    let pastCount: Int
    let practice: (JSONValue) -> Void

    @State private var points: [JSONValue] = []
    @State private var pending: JSONValue?
    @State private var levels: [JSONValue] = []
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    private var firstReport: CoachSlot { CoachSlot(id: "report-first", user: session.coachUser) }

    private static let word = ["up": "升了", "down": "降了", "same": "没变", "new": "第一次记下", "unsettled": "还说不准"]
    private static let order = ["up": 0, "down": 1, "new": 2, "unsettled": 3, "same": 4]

    var body: some View {
        Group {
            if pending != nil || !points.isEmpty || !levels.isEmpty {
                let first = pastCount == 0
                let many = !levels.isEmpty && pending == nil
                let sub = first && !many ? (pending != nil ? "" : "以后改简历、出题和面试前提醒，都会按这里的结论来。")
                    : [many ? "对照这场之前的记忆。" : pastCount > 0 ? "对照你之前的 \(pastCount) 场面试。" : nil, pending != nil ? nil : "以后出题和面试前提醒会按这里的结论来。"].compactMap { $0 }.joined()
                VStack(alignment: .leading, spacing: 0) {
                    Text(first && !many ? "第一场之后，记忆里记下了什么" : "这场之后，记忆里变了什么").font(V3.serif(22)).foregroundStyle(RRC.ink).lineHeight(22, 30, .serif)
                    if !sub.isEmpty { Text(verbatim: sub).font(V3.sans(13)).foregroundStyle(RRC.sub).frame(height: 20).padding(.top, 4) }
                    VStack(spacing: 0) {
                        if pending == nil && !levels.isEmpty { levelRow }
                        if let pending { pendingRow(pending) } else {
                            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                                if index > 0 || !levels.isEmpty { Rectangle().fill(RRC.line).frame(height: 1) }
                                pointRow(point)
                            }
                        }
                    }
                    .background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RRC.line)).padding(.top, 14)
                }
                // K3（Figma 02A · 61:3080）：第一份报告第一次打开，压暗整页只亮这一块（Web `ReviewMemory`：第一场且没有“正在记入”）
                .coachTarget(first && pending == nil && firstReport.open, label: "第一份报告引导",
                             message: "这些已经记进你的长期记忆。\n以后改简历、出题，都会按这里来。",
                             actions: [CoachAction(label: "回首页看看") { router?.jump(.section(.home)) }, CoachAction(label: "先看完报告")]) { firstReport.dismiss() }
                .padding(.top, 44)
            }
        }
        .task(id: mockID) { await load() }
    }

    private func tag(_ text: String, _ color: Color, hollow: Bool = false) -> some View {
        HStack(spacing: 8) {
            if hollow { Circle().strokeBorder(color, lineWidth: 1.5).frame(width: 8, height: 8) } else { Circle().fill(color).frame(width: 8, height: 8) }
            Text(verbatim: text)
        }
        .font(V3.sans(13, weight: hollow ? .regular : .medium)).foregroundStyle(color).frame(width: 96, height: 22, alignment: .leading)
    }

    private var levelRow: some View {
        HStack(alignment: .top, spacing: 24) {
            tag("等级变化", RRC.ink)
            MockFlow(spacing: 40, lineSpacing: 14) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, item in
                    let change = item.text("change")
                    // 升了蓝、降了橙、没变灰字常规、第一次记下 / 还说不准整行灰、等级加粗（Figma 09 · 11.04）
                    let muted = change == "new" || change == "unsettled"
                    let tone: Color? = change == "up" ? RRC.blue : change == "down" ? RRC.orange : muted ? Color(hex: 0x96968F) : nil
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.text("name")).font(V3.sans(15, weight: .medium)).foregroundStyle(RRC.ink)
                        (Text(verbatim: "\(item.text("before")) → ").foregroundColor(Color(hex: 0x96968F))
                         + Text(verbatim: item.text("after")).foregroundColor(tone ?? RRC.text).fontWeight(tone == nil ? .regular : .medium)
                         + Text(verbatim: " " + (Self.word[change] ?? "")).font(V3.sans(12)).foregroundColor(tone ?? Color(hex: 0x96968F)))
                            .font(V3.sans(13))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
    }

    private func pendingRow(_ card: JSONValue) -> some View {
        let left = CareerApplication.date(card.text("expected_at")).map { max(1, Int(ceil($0.timeIntervalSinceNow / 60))) } ?? 1
        return HStack(alignment: .top, spacing: 24) {
            tag("正在记入", Color(hex: 0x96968F), hollow: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "正在把这场记入长期记忆，大约还要 \(left) 分钟").font(V3.sans(16, weight: .medium)).foregroundStyle(RRC.ink)
                Text("评分已经出来了，可以先看下面每道题。记好后，这里会出现这场带来的变化。").font(V3.sans(13)).foregroundStyle(RRC.sub).lineHeight(13, 22)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
    }

    private func pointRow(_ point: JSONValue) -> some View {
        let progress = point.text("kind") == "progress"
        let name = progress ? "练稳了" : point.text("insight_kind") == "habit" ? "说话习惯" : "值得留意"
        let target = point["target"].flatMap { $0 == .null ? nil : $0 }
        return HStack(alignment: .top, spacing: 24) {
            tag(name, progress ? RRC.blue : RRC.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: point["observed"]?.text("text") ?? "").font(V3.sans(16, weight: .medium)).foregroundStyle(RRC.ink).fixedSize(horizontal: false, vertical: true)
                if let quote = point["observed"]?.text("quote").nonEmptyValue { Text(verbatim: "你说：「\(quote)」").font(V3.sans(13)).foregroundStyle(RRC.sub).lineHeight(13, 22) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: point["next"]?.text("text") ?? "").font(V3.sans(13)).foregroundStyle(RRC.text).lineHeight(13, 22).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: point["review"]?.text("text") ?? "").font(V3.sans(12)).foregroundStyle(Color(hex: 0x96968F)).lineHeight(12, 20)
            }.frame(maxWidth: 300, alignment: .leading)
            if let target {
                Button(progress ? "再答一次 ›" : "练这一点 ›") { practice(target) }.buttonStyle(MockLinkStyle(blue: true))
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
    }

    private func load() async {
        var tries = 0
        while !Task.isCancelled {
            // 两类分开读：只读进展和习惯，没答好的知识点在底部「建议先补」里，不在这里告知
            var found: [JSONValue] = []
            var waiting: JSONValue?
            for kind in ["progress", "insight"] {
                guard let result = try? await session.api.careerRequest(path: "/api/memory/feedback", method: "GET", query: ["mock_interview_id": mockID, "kinds": kind], body: nil),
                      result["enabled"]?.bool == true, let card = result["card"], card != .null else { continue }
                if card.text("status") == "pending" { waiting = card } else { found += (card["points"]?.items ?? []).filter { ["progress", "insight"].contains($0.text("kind")) } }
            }
            if Task.isCancelled { return }
            pending = waiting; points = waiting == nil ? found : []
            if waiting == nil {
                let comparison = try? await session.api.careerRequest(path: "/api/memory/review-comparison", method: "GET", query: ["mock_interview_id": mockID], body: nil)
                let items = comparison?["enabled"]?.bool == true && comparison?["diarized"]?.bool != false ? comparison?["items"]?.items ?? [] : []
                levels = Array(items.enumerated().filter { _, item in
                    ["skill", "point", "type"].contains(item.text("kind")) && !(item.text("before") == "证据不足" && item.text("after") == "证据不足")
                }.sorted { a, b in
                    let x = Self.order[a.element.text("change")] ?? 9, y = Self.order[b.element.text("change")] ?? 9
                    return x != y ? x < y : a.offset < b.offset
                }.map(\.element).prefix(8))
                return
            }
            tries += 1
            if tries >= 8 { return }
            let wait = CareerApplication.date(waiting?.text("expected_at") ?? "").map { $0.timeIntervalSinceNow } ?? 15
            try? await Task.sleep(for: .seconds(min(120, max(15, wait))))
        }
    }
}

/// 换行排列：一行放不下就折到下一行。
struct MockFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(width, widest), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}
