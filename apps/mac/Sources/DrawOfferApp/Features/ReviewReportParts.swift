import DrawOfferCore
import SwiftUI

// 复盘总览的两张图（Figma 09 · 08.03；Web `interviews/report/ReviewCharts.tsx`）：通用能力小雷达、本场知识点掌握度曲线，
// 都按 Web 的 viewBox 坐标画，随宽度等比缩放；以及「这场之后，记忆里变了什么」（Figma 09 · 11 记忆变化状态 11.01–11.04，Web `ReviewMemory.tsx`）。

enum RRC {
    static let blue = Color(hex: 0x3F6FD8)
    static let orange = Color(hex: 0xC9651B)
    static let ink = Color(hex: 0x1D1D1B)
    static let text = Color(hex: 0x55554F)
    static let sub = Color(hex: 0x6C6C65)
    static let faint = Color(hex: 0xA9A9A3)
    static let line = Color(hex: 0xE4E4E0)
    static let thin = Color(hex: 0xECECEA)
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

/// 总览右上的小雷达（Web `AbilityRadar compact`）：圆心 (158,92)，外圈半径 54，能力名和分数放在顶点外 26；
/// 这场实线浅蓝填充，以往灰色浅填充；低于 60 的点和字标橙。画布按最长的标签放宽，文字不出框。
struct RRRadar: View {
    let abilities: [MockRV.Ability]
    private static let cx: CGFloat = 158, cy: CGFloat = 92, r: CGFloat = 54, gap: CGFloat = 26

    var body: some View {
        let count = abilities.count
        let vertex = { (index: Int, ratio: CGFloat) -> CGPoint in
            let angle = Double(index) / Double(count) * 2 * .pi
            return CGPoint(x: Self.cx + Self.r * ratio * CGFloat(sin(angle)), y: Self.cy - Self.r * ratio * CGFloat(cos(angle)))
        }
        let width = { (s: String) in CGFloat(s.reduce(0) { $0 + ($1.unicodeScalars.first!.value > 255 ? 11 : 11 * 0.58) }) }
        var left: CGFloat = 0, right: CGFloat = 316, top = Self.cy, bottom = Self.cy
        for (index, item) in abilities.enumerated() {
            let at = vertex(index, (Self.r + Self.gap) / Self.r), half = width(item.label) / 2
            left = min(left, at.x - half - 4); right = max(right, at.x + half + 4)
            top = min(top, at.y - 20); bottom = max(bottom, at.y + 20)
        }
        let ratio = { (score: Double) in CGFloat(max(0.08, min(1, score / 100))) }
        return RRChart(box: CGRect(x: left, y: top, width: right - left, height: bottom - top)) { context in
            func shape(_ ratios: [CGFloat]) -> Path {
                Path { p in for (i, r) in ratios.enumerated() { i == 0 ? p.move(to: vertex(i, r)) : p.addLine(to: vertex(i, r)) }; p.closeSubpath() }
            }
            for r in [1, 0.66, 0.33] as [CGFloat] { context.stroke(shape(Array(repeating: r, count: count)), with: .color(RRC.thin)) }
            for index in 0..<count { context.stroke(Path { $0.move(to: CGPoint(x: Self.cx, y: Self.cy)); $0.addLine(to: vertex(index, 1)) }, with: .color(ROC.headLine)) }
            if abilities.contains(where: { $0.past != nil }) {
                let past = shape(abilities.map { ratio($0.past ?? Double($0.score)) })
                context.fill(past, with: .color(ROC.faint.opacity(0.08)))
                context.stroke(past, with: .color(Color(hex: 0xB5B0A8)), lineWidth: 1.2)
            }
            let mine = shape(abilities.map { ratio(Double($0.score)) })
            context.fill(mine, with: .color(ROC.blue.opacity(0.12)))
            context.stroke(mine, with: .color(ROC.blue), lineWidth: 1.6)
            for (index, item) in abilities.enumerated() {
                let low = item.score < MockRV.passScore
                let dot = vertex(index, ratio(Double(item.score)))
                let ring = CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: ring.insetBy(dx: -1.5, dy: -1.5)), with: .color(.white))
                context.fill(Path(ellipseIn: ring), with: .color(low ? Color(hex: 0xD97706) : ROC.blue))
                let at = vertex(index, (Self.r + Self.gap) / Self.r)
                label(&context, item.label, at.x, at.y - 3, size: 11, weight: low ? .medium : .regular, color: low ? ROC.warn : ROC.gray)
                label(&context, "\(item.score)", at.x, at.y + 13, size: 12, weight: .semibold, color: low ? ROC.low : ROC.ink)
            }
        }
        .accessibilityLabel(abilities.map { "\($0.label) \($0.score)" }.joined(separator: "，"))
    }
}

/// 本场知识点掌握度（Web `WaveChart`）：按作答顺序一题一个点，达标线以上是浅绿的达标区；
/// 低于 60 的点标橙，最高最低两题加光晕；下面一题一格写题号和题名，点点或题名进单题详情。
struct RRWave: View {
    let questions: [MockRV.Question]
    /// 窄时横轴只留题号
    var names = true
    let open: (String) -> Void

    var body: some View {
        let scores = questions.map { $0.score ?? 0 }
        let xs = MockWave.xs(scores.count)
        let points = scores.indices.map { CGPoint(x: xs[$0], y: MockWave.y(scores[$0])) }
        let calls = MockWave.calls(scores)
        let best = scores.max() ?? 0, worst = scores.min() ?? 0
        let step = scores.count > 1 ? xs[1] - xs[0] : MockWave.width
        let cell = min(step, 160)
        GeometryReader { geometry in
            let scale = geometry.size.width / CGFloat(MockWave.width)
            ZStack(alignment: .topLeading) {
                RRChart(box: CGRect(x: 0, y: 0, width: MockWave.width, height: MockWave.bottom + 8)) { context in
                    draw(&context, points: points, scores: scores, calls: calls, best: best, worst: worst)
                }
                ForEach(Array(questions.enumerated()), id: \.element.id) { index, q in
                    Button { open(q.id) } label: { Color.clear.frame(width: 24, height: 24).contentShape(Circle()) }
                        .buttonStyle(.plain).position(x: points[index].x * scale, y: points[index].y * scale)
                        .accessibilityLabel("\(q.title) \(scores[index]) 分")
                    Button { open(q.id) } label: {
                        VStack(spacing: 0) {
                            Text(verbatim: "Q\(index + 1)").font(V3.number(10.5, weight: .regular)).foregroundStyle(ROC.faint).frame(height: 15)
                            if names {
                                Text(verbatim: q.title).font(V3.sans(12, weight: .medium)).foregroundStyle(ROC.ink).lineLimit(2).multilineTextAlignment(.center)
                                    .lineHeight(12, 16).truncationMode(.tail)
                            }
                        }
                        .frame(width: max(0, CGFloat(cell) * scale - 12)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(x: CGFloat(xs[index]) * scale, y: CGFloat(MockWave.bottom + 8) * scale + 2 + (names ? 25 : 9))
                }
            }
        }
        .aspectRatio(MockWave.width / (MockWave.bottom + 8), contentMode: .fit)
        .padding(.bottom, names ? 52 : 20)
    }

    private func draw(_ context: inout GraphicsContext, points: [CGPoint], scores: [Int], calls: [MockWave.Call], best: Int, worst: Int) {
        let w = MockWave.width, left = MockWave.left, bottom = MockWave.bottom, pass = MockWave.pass
        let passY = MockWave.y(pass)
        let green = Color(hex: 0x4D8B68)
        context.fill(Path(CGRect(x: left, y: MockWave.top, width: w - left, height: passY - MockWave.top)), with: .color(Color(hex: 0xF2FBF5)))
        let hline = { (y: Double) in Path { $0.move(to: CGPoint(x: left, y: y)); $0.addLine(to: CGPoint(x: w, y: y)) } }
        context.stroke(hline(MockWave.y(25)), with: .color(ROC.thin))
        context.stroke(hline(bottom), with: .color(ROC.line))
        context.stroke(hline(passY), with: .color(Color(hex: 0xB7DEC5)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        for value in [100, 25, 0] { label(&context, "\(value)", 24, MockWave.y(value) + 4, size: 10.5, color: ROC.faint, anchor: .trailing) }
        label(&context, "\(pass)", 24, passY + 4, size: 10.5, weight: .medium, color: green, anchor: .trailing)
        // 右端的“达标线”名字和最右一题的分数挤在一起时，名字挪到线下面
        let crowded = calls.contains { $0.x > w - 130 && abs($0.y - (passY - 6)) < 16 }
        label(&context, "达标线 \(pass)", w - 8, crowded ? passY + 14 : passY - 6, size: 10.5, weight: .medium, color: green, anchor: .trailing)
        if points.count > 1 {
            let tangents = MockWave.tangents(points.map { (x: Double($0.x), y: Double($0.y)) })
            var line = Path()
            line.move(to: points[0])
            for i in 0..<(points.count - 1) {
                let p = points[i], q = points[i + 1], dx = (q.x - p.x) / 3
                line.addCurve(to: q, control1: CGPoint(x: p.x + dx, y: p.y + CGFloat(tangents[i]) * dx), control2: CGPoint(x: q.x - dx, y: q.y - CGFloat(tangents[i + 1]) * dx))
            }
            var area = line
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: bottom)); area.addLine(to: CGPoint(x: points[0].x, y: bottom)); area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [ROC.blue.opacity(0.1), ROC.blue.opacity(0.01)]), startPoint: CGPoint(x: 0, y: MockWave.top), endPoint: CGPoint(x: 0, y: bottom)))
            context.stroke(line, with: .color(ROC.blue), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
        for (index, point) in points.enumerated() {
            let score = scores[index], low = score < pass
            let halo = points.count > 1 && (score == best || score == worst) && best != worst
            if halo {
                context.fill(Path(ellipseIn: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)), with: .color(low ? Color(hex: 0xFEF3C7).opacity(0.9) : Color(hex: 0xDBEAFE).opacity(0.7)))
            }
            let dot = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: dot.insetBy(dx: -1, dy: -1)), with: .color(.white))
            context.fill(Path(ellipseIn: dot.insetBy(dx: 1, dy: 1)), with: .color(low ? Color(hex: 0xD97706) : ROC.blue))
            let call = calls[index]
            let anchor: UnitPoint = call.anchor == .start ? .leading : call.anchor == .end ? .trailing : .center
            label(&context, "\(score)", call.x, call.y, size: 12.5, weight: .semibold, color: low ? ROC.low : score == best && halo ? ROC.blue : ROC.ink, anchor: anchor)
        }
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
            // 两次读互不依赖，一起发；结果仍按 进展 → 习惯 的顺序合并
            let api = session.api, id = mockID
            async let progress = try? api.careerRequest(path: "/api/memory/feedback", method: "GET", query: ["mock_interview_id": id, "kinds": "progress"], body: nil)
            async let insight = try? api.careerRequest(path: "/api/memory/feedback", method: "GET", query: ["mock_interview_id": id, "kinds": "insight"], body: nil)
            for value in [await progress, await insight] {
                guard let result = value, result["enabled"]?.bool == true, let card = result["card"], card != .null else { continue }
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
