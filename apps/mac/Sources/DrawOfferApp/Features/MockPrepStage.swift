import AppKit
import Foundation
import DrawOfferCore
import SwiftUI

// MARK: 准备题目（Figma 09 · 03 开始前 03.01；Web `PrepStage`）

/// 准备中只能离开（后台继续准备），不能取消；准备好了也等选题动画放完（onDone）再往下走。
/// 打开时题目已经准备好（从检查设备返回、重新进入）就停在挑完的样子，不自动往下走。
struct MockPrepStage: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let detail: JSONValue
    let changed: () -> Void
    let home: () -> Void
    var onCheckDevice: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil
    @State private var doneAtOpen: Bool
    @State private var picked = false
    @State private var busy = false
    @State private var notice: MockNotice?

    init(detail: JSONValue, changed: @escaping () -> Void, home: @escaping () -> Void, onCheckDevice: (() -> Void)? = nil, onDone: (() -> Void)? = nil) {
        self.detail = detail; self.changed = changed; self.home = home; self.onCheckDevice = onCheckDevice; self.onDone = onDone
        _doneAtOpen = State(initialValue: detail.text("status") == "in_progress")
    }

    private var prep: JSONValue? { detail["prep"].flatMap { $0 == .null ? nil : $0 } }
    private var failed: Bool { detail.text("status") == "preparation_failed" }
    private var ready: Bool { detail.text("status") == "in_progress" }
    private var still: Bool { failed || reduceMotion || doneAtOpen }
    private var voice: Bool { detail.text("answer_mode") == "voice" }

    var body: some View {
        let failedText = MockInterviewText.messages[detail.text("error_code")] ?? "模型服务暂时没有响应"
        let pickCount = prep?["picks"]?.items.count ?? 0
        MockSessionFrame {
            MockPrepOrbit(prep: prep, still: still)
            MockSessionHead(detail: detail, back: ("模拟面试", busy, { if failed { backHome() } else { home() } }))
            MockPrepTitle(text: MockPrep.title(detail, picked: picked))
            MockCenterLine(text: failed ? "\(failedText)，这一次没有扣积分。" : MockPrep.daysLine(detail), top: 206, size: 14, line: 22, color: MockPalette.sub)
            if !failed { MockPrepCaption(lines: MockPrep.pickingLines(detail)) }
            MockSessionFoot {
                MockPrepFootLine(session: MockPrep.sessionLine(detail), note: !failed && !ready ? "准备好了会提醒你，可以先离开页面" : nil)
            } right: {
                if failed {
                    Button(busy ? "正在重新准备…" : "重新准备") { run { _ = try await command("retry") } }.buttonStyle(MockPillStyle()).disabled(busy)
                } else if doneAtOpen, let onCheckDevice {
                    Button(voice ? "去检查设备" : "继续", action: onCheckDevice).buttonStyle(MockPillStyle())
                } else if voice, let onCheckDevice {
                    MockArrowLink(title: "先试一下麦克风", action: onCheckDevice)
                }
            }
        }
        .overlay { MockNoticeToast(notice: $notice) }
        .task(id: "\(prep != nil)-\(pickCount)-\(still)") {
            guard prep != nil else { return }
            if still { picked = true; return }
            try? await Task.sleep(for: .seconds(MockPrep.duration(picks: pickCount)))
            if !Task.isCancelled { picked = true }
        }
        .onChange(of: "\(ready)-\(picked)-\(prep != nil)", initial: true) {
            if ready && !doneAtOpen && (picked || prep == nil) { onDone?() }
        }
    }

    private func command(_ name: String) async throws -> JSONValue {
        try await session.api.careerRequest(path: "/api/mock-interviews/\(detail.display("id"))/\(name)", method: "POST", query: [:], body: nil)
    }
    private func run(_ action: @escaping () async throws -> Void, after: (() -> Void)? = nil) {
        busy = true
        Task {
            do { try await action(); after?(); changed() } catch { notice = MockNotice(title: "操作没有完成", message: MockInterviewText.error(error)) }
            busy = false
        }
    }
    /// 准备失败时返回：这场记为放弃，回模拟面试首页。
    private func backHome() { run({ _ = try await command("abandon") }, after: home) }
}

/// `.mi3-prep-title`：40 号宋体、行高 56、字距 1，顶 140。
struct MockPrepTitle: View {
    let text: String
    var body: some View {
        Text(verbatim: text).font(V3.serif(40)).tracking(1).foregroundStyle(MockPalette.ink).lineHeight(40, 56, .serif)
            .multilineTextAlignment(.center).frame(width: 1120).offset(x: 124, y: 140)
    }
}

/// 底部左边「这一场 云川科技 · 二面 · … | 一句提示」（`.mi3-prep-foot`）。
struct MockPrepFootLine: View {
    let session: String
    let note: String?
    var body: some View {
        HStack(spacing: 0) {
            Text("这一场").foregroundStyle(MockPalette.fnt)
            Text(verbatim: session).fontWeight(.medium).foregroundStyle(MockPalette.ink).padding(.leading, 10)
            if let note {
                Rectangle().fill(MockPalette.cl).frame(width: 1, height: 14).padding(.leading, 18)
                Text(verbatim: note).foregroundStyle(MockPalette.fnt).padding(.leading, 18)
            }
        }
        .font(V3.sans(12)).lineLimit(1)
    }
}

/// `.mi3-prep-mic`：12 号中等字的文字按钮，后面跟一个浅色箭头。
struct MockArrowLink: View {
    let title: String
    var size: CGFloat = 12
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            (Text(verbatim: title).foregroundColor(enabled ? MockPalette.ink : MockPalette.faint) + Text(" →").foregroundColor(MockPalette.fnt))
                .font(V3.sans(size, weight: .medium)).lineLimit(1).fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// 底部小字（`.mi3-prep-cap`，顶 668）：每 5 秒淡出换一句；换一组句子时从第一句开始。轮换的句子不进读屏。
struct MockPrepCaption: View {
    let lines: [String]
    @State private var start = Date()
    private static let every = 5.0, out = 0.45
    var body: some View {
        TimelineView(.periodic(from: start, by: 0.15)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(start))
            let index = lines.count < 2 || elapsed < Self.out ? 0 : Int((elapsed - Self.out) / Self.every) % lines.count
            let leaving = lines.count >= 2 && elapsed >= Self.every && elapsed.truncatingRemainder(dividingBy: Self.every) < Self.out
            HStack(spacing: 10) {
                Circle().fill(Color(hex: 0xC9C4BD)).frame(width: 6, height: 6)
                Text(verbatim: lines.isEmpty ? "" : lines[index]).font(V3.sans(14)).foregroundStyle(MockPalette.sub).lineHeight(14, 22)
            }
            .frame(width: 1120).offset(x: 124, y: 668)
            .opacity(leaving ? 0 : 1).animation(.easeInOut(duration: Self.out), value: leaving)
        }
        .accessibilityHidden(true)
        .onChange(of: lines) { start = Date() }
    }
}

// MARK: 选题动画（Figma 09 · 04 · 04.02；Web `PrepOrbit`）

/// 中间是这一场已挑好的题卡叠；外圈每个圆是一个来源（简历里的一段经历，或「这个方向常考」「岗位要求」），绕着题卡叠慢转；
/// 来源周围的小点是它里面的每一行（白 = 没练过，朱砂 = 上次没守住，绿 = 守住了；知识来源用小方块）。每道题：选中一个来源 →
/// 那一行亮起、旁边浮出原句 → 伸出小卡飞进中间写成题卡、三个核对点依次变绿 → 落进叠里。
/// 读简历（Web Figma 09 页 04R，11-27；Mac 稿暂无，照 Web）：中间一张简历纸，淡黄扫读带从上往下扫；每扫完一段经历，那几行变黄、
/// 缩成一个圆飘进轨道慢转，最后「这个方向常考」淡入；读完扫读带慢慢循环。题目一回来，轨道上的圆直接接上名字、简历纸淡出，
/// 接着逐题演，不再从中间展开。
struct MockPrepOrbit: View {
    let prep: JSONValue?
    let still: Bool
    @State private var start = Date()
    /// 读简历动画从什么时候开始演：题目回来后公转角度从这里接着算，轨道上的圆不跳
    @State private var readSince: Date?

    var body: some View {
        let plan = prep.map(MockPrep.plan) ?? (sources: [], rounds: [])
        let key = plan.rounds.map(\.title).joined(separator: "|") + "#" + plan.sources.map(\.name).joined(separator: "|")
        let end = MockPrep.duration(picks: plan.rounds.count) * 1000
        // 题目回来时读简历已经在演：经历已经在轨道上，不再从中间展开
        let fromReading = prep != nil && !still && readSince != nil
        let shift = fromReading ? max(0, start.timeIntervalSince(readSince ?? start) * 1000) : 0
        Group {
            if prep == nil && still {
                OrbitFrame(sources: Orbit.readingSources, rounds: [], t: 0, reading: true)
            } else if prep == nil {
                TimelineView(.animation) { timeline in
                    OrbitFrame(sources: Orbit.readingSources, rounds: [], t: max(0, timeline.date.timeIntervalSince(readSince ?? start)) * 1000, reading: true)
                }
            } else if still {
                OrbitFrame(sources: plan.sources, rounds: plan.rounds, t: end + 1800, reading: false)
            } else {
                TimelineView(.animation) { timeline in
                    OrbitFrame(sources: plan.sources, rounds: plan.rounds, t: max(0, timeline.date.timeIntervalSince(start)) * 1000, reading: false,
                               fromReading: fromReading, shift: shift)
                }
            }
        }
        .frame(width: MockFull.width, height: MockFull.height).clipped().allowsHitTesting(false).accessibilityHidden(true)
        .onChange(of: key) { start = Date() }
        .onChange(of: "\(prep == nil)-\(still)", initial: true) {
            // 失败后重新准备要从头演读简历，不接上一次的进度
            if prep == nil && still { readSince = nil } else if prep == nil && readSince == nil { readSince = Date() }
        }
    }
}

private enum Orbit {
    static let cx = 684.0, cy = 426.0, orx = 345.0, ory = 135.0, tau = Double.pi * 2
    static let open = 2000.0, round = 5600.0
    static let new = Color.white, weak = Color(hex: 0xE05A47), held = Color(hex: 0x7FA98F), picked = Color(hex: 0xEAB34B)
    static func ease(_ v: Double) -> Double { v < 0.5 ? 2 * v * v : 1 - pow(-2 * v + 2, 2) / 2 }
    static func clamp(_ v: Double, _ low: Double = 0, _ high: Double = 1) -> Double { max(low, min(high, v)) }
    static func seg(_ t: Double, _ from: Double, _ to: Double) -> Double { ease(clamp((t - from) / (to - from))) }
    static func lerp(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }
    static func color(_ state: String) -> Color { state == "weak" ? weak : state == "held" ? held : new }
    static func hex(_ value: String) -> Color { Color(hex: UInt32(value, radix: 16) ?? 0xA8A29E) }

    // MARK: 读简历（Web `PrepOrbit` 的 READING_SOURCES / SHEET_ROWS / SCAN_*）
    static let readingSources = MockPrep.readingSources
    /// 简历纸上的行（x, y, 宽, 高）；第 2–4、5–6、7–8 行各是一段经历
    static let sheetRows: [(x: Double, y: Double, w: Double, h: Double)] = [(38, 18, 48, 5), (38, 27, 30, 4), (14, 48, 96, 4), (14, 60, 80, 4), (14, 72, 90, 4),
                                                                           (14, 92, 96, 4), (14, 104, 70, 4), (14, 124, 92, 4), (14, 136, 64, 4)]
    static let sheetBlocks: [[Int]] = [[2, 3, 4], [5, 6], [7, 8]]
    static let sheetH = 164.0
    /// 扫读带第一遍从纸顶扫到纸底（毫秒）；之后放慢循环
    static let scanFrom = 400.0, scanTo = 4400.0, scanLoop = 3200.0, flyMs = 1000.0, knowIn = 5000.0
    /// 扫过的行变深（rgba(120, 113, 108, .75)）
    static let rowRead = Color(red: 120 / 255, green: 113 / 255, blue: 108 / 255).opacity(0.75)
    static func scanAt(_ y: Double) -> Double { scanFrom + (scanTo - scanFrom) * y / sheetH }
    /// 每段经历被扫完的时刻 = 它最后一行被扫过的时刻
    static let blockDone: [Double] = sheetBlocks.map { rows in scanAt(rows.map { sheetRows[$0].y + sheetRows[$0].h }.max() ?? 0) }
    /// 读简历时第 i 个来源到轨道的进度；三段经历依次从纸上飞出，知识来源最后淡入
    static func arrive(_ t: Double, _ i: Int) -> Double {
        i < sheetBlocks.count ? seg(t, blockDone[i], blockDone[i] + flyMs) : seg(t, knowIn, knowIn + flyMs)
    }
    /// 两个颜色按比例混合（CSS `color-mix(in srgb, a k%, b)`）。
    static func mix(_ a: UInt32, _ k: Double, _ b: UInt32) -> Color {
        func channel(_ v: UInt32, _ shift: UInt32) -> Double { Double((v >> shift) & 0xFF) / 255 }
        return Color(red: lerp(channel(b, 16), channel(a, 16), k), green: lerp(channel(b, 8), channel(a, 8), k), blue: lerp(channel(b, 0), channel(a, 0), k))
    }
}

/// 一个来源在某一刻的样子。
private struct OrbitPlanet {
    struct Moon { var x: Double; var y: Double; var size: Double; var fill: Color; var ring: Bool; var opacity: Double; var mark: Double }
    var x = 0.0, y = 0.0, opacity = 1.0, z = 2, r0 = 0.0, mr = 0.0, md = 0.0
    var chosen = false, selected = 0.0, know = false, name = ""
    /// 读简历时从纸上飞向轨道（圆心变淡黄、金色描边）；名字的透明度另算
    var flying = false, labelOpacity = 1.0
    var moons: [Moon] = []
    var target: (Double, Double)?
}

/// 动画的一帧：t 为毫秒。与 Web 的 `render(t, reading)` 一一对应。
private struct OrbitFrame: View {
    let sources: [MockPrep.Source]
    let rounds: [MockPrep.Round]
    let t: Double
    let reading: Bool
    /// 题目回来时读简历已经在演（轨道上的圆接着转，不从中间展开）；shift 为读简历已演的毫秒
    var fromReading = false
    var shift = 0.0

    var body: some View {
        let count = rounds.count
        let pickEnd = Orbit.open + Double(count) * Orbit.round
        let active = !reading && t >= Orbit.open && t < pickEnd
        let index = active ? Int((t - Orbit.open) / Orbit.round) : -1
        let rt = active ? (t - Orbit.open).truncatingRemainder(dividingBy: Orbit.round) : 0
        let round = index >= 0 ? rounds[index] : nil
        let picked = reading || t < Orbit.open ? 0 : index >= 0 ? index + (rt > 4500 ? 1 : 0) : count
        let usedCount = reading || t < Orbit.open ? 0 : index >= 0 ? index + (rt > 2500 ? 1 : 0) : count
        let used = Set(rounds.prefix(usedCount).map { "\($0.source)-\($0.node)" })
        let open = reading || fromReading ? 1 : t < Orbit.open ? Orbit.seg(t, 500, 1800) : 1
        let settle = reading ? 0 : Orbit.seg(t, pickEnd, pickEnd + 1800)
        let selected = round != nil ? Orbit.seg(rt, 0, 600) * (1 - Orbit.seg(rt, 4700, 5300)) : 0
        let marked = round != nil ? Orbit.seg(rt, 600, 1000) : 0
        let quoteOpacity = round != nil ? Orbit.seg(rt, 900, 1300) * (1 - Orbit.seg(rt, 2300, 2550)) : 0
        // 公转：挑题时匀速，挑完后慢慢停下；读简历时一直匀速转
        let spin = { (speed: Double) in shift / 1000 * speed
            + (reading || t <= pickEnd ? t / 1000 * speed : pickEnd / 1000 * speed + speed * 1.6 * (1 - exp(-(t - pickEnd) / 1000 / 1.6))) }
        let readingCount = Orbit.readingSources.count
        let rot = spin(Orbit.tau / 46), moonRot = spin(Orbit.tau / 22)
        let planets = sources.enumerated().map { i, source -> OrbitPlanet in
            // 题目回来时：读简历那几个圆从原来的角度滑到新的位置，多出来的来源淡入
            let slide = fromReading ? Orbit.seg(t, 0, 900) : 1
            let angle = fromReading && i < readingCount
                ? Orbit.lerp(rot + Double(i) * Orbit.tau / Double(readingCount), rot + Double(i) * Orbit.tau / Double(sources.count), slide)
                : rot + Double(i) * Orbit.tau / Double(sources.count)
            var p = OrbitPlanet()
            p.x = Orbit.cx + Orbit.orx * cos(angle) * open
            p.y = Orbit.cy + Orbit.ory * sin(angle) * open
            let depth = (sin(angle) + 1) / 2
            var k = (0.8 + 0.25 * depth) * Orbit.lerp(0.5, 1, open)
            var o = (0.6 + 0.4 * depth) * Orbit.lerp(0.4, 1, open)
            // 读简历时还没飞到轨道（题目回来得早）或多出来的来源：淡入，不突然冒出来
            if fromReading && (i >= readingCount || Orbit.arrive(shift, i) < 1) { o *= Orbit.seg(t, 0, 700) }
            else if !fromReading && !reading && t < Orbit.open { o *= Orbit.seg(t, 700, 1500) }
            if reading {
                // 经历从纸上它那几行的位置飞出，边飞边长大；知识来源在轨道上原地淡入
                let f = Orbit.arrive(t, i)
                if i < Orbit.sheetBlocks.count {
                    let rows = Orbit.sheetBlocks[i]
                    let fromY = Orbit.cy - 82 + (Orbit.sheetRows[rows[0]].y + Orbit.sheetRows[rows[rows.count - 1]].y) / 2
                    p.x = Orbit.lerp(Orbit.cx + 20, p.x, f)
                    p.y = Orbit.lerp(fromY, p.y, f)
                    k *= Orbit.lerp(0.35, 1, f)
                    p.flying = f > 0 && f < 1
                }
                o *= f > 0 ? (i < Orbit.sheetBlocks.count ? 1 : 0.55 * f) : 0
            }
            p.chosen = round?.source == i
            if p.chosen { k *= Orbit.lerp(1, 1.08, selected); o = Orbit.lerp(o, 1, selected) } else if round != nil { o *= Orbit.lerp(1, 0.55, selected) }
            p.opacity = o * Orbit.lerp(1, 0.45, settle)
            p.labelOpacity = reading ? 0 : fromReading ? Orbit.seg(t, 300, 1100) : 1
            p.z = p.chosen ? 20 : p.flying ? 12 : sin(angle) < 0 ? 2 : 12
            p.r0 = 30 * k; p.mr = 50 * k; p.md = max(8, 9 * k * 0.8)
            p.selected = p.chosen ? selected : 0
            p.know = source.know; p.name = source.name
            p.moons = source.nodes.enumerated().map { j, node in
                let a = moonRot * (i % 2 == 1 ? -1 : 1) + Double(j) * Orbit.tau / Double(source.nodes.count) + Double(i)
                let isUsed = used.contains("\(i)-\(j)")
                let hit = p.chosen && round?.node == j
                let grow = hit && !isUsed ? Orbit.lerp(1, 1.6, marked) : 1
                if hit { p.target = (p.x + p.mr * cos(a), p.y + p.mr * sin(a)) }
                return .init(x: p.mr * cos(a), y: p.mr * sin(a), size: p.md * grow, fill: isUsed ? Orbit.picked : Orbit.color(node.state),
                             ring: !isUsed && node.state != "weak" && node.state != "held", opacity: isUsed && hit ? Orbit.seg(rt, 3300, 3700) * 0.9 : 1,
                             mark: hit && !isUsed ? marked : 0)
            }
            if p.chosen && p.target == nil { p.target = (p.x, p.y - p.r0) }
            return p
        }
        let waiting = !reading && t >= pickEnd
        let dots = min(count == 0 ? 5 : count, 12)
        let card = (x: Orbit.cx, y: Orbit.cy)

        ZStack(alignment: .topLeading) {
            Ellipse().stroke(Color(hex: 0xE7E5E0), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                .frame(width: Orbit.orx * 2, height: Orbit.ory * 2).position(x: Orbit.cx, y: Orbit.cy)
                .opacity(reading ? 0.6 * Orbit.seg(t, 0, 800) + 0.3 * Orbit.arrive(t, 0) : open * (1 - 0.6 * settle))
            OrbitPlanets(planets: planets.filter { $0.z == 2 })
            OrbitCard(kind: .ghost).rotationEffect(.degrees(-4)).position(x: card.x, y: card.y + 8).opacity(picked >= 3 ? 1 : 0)
            OrbitCard(kind: .ghost).rotationEffect(.degrees(3)).position(x: card.x, y: card.y + 4).opacity(picked >= 2 ? 1 : 0)
            OrbitCard(kind: .slot).position(x: card.x, y: card.y).opacity(picked == 0 ? (reading ? 0 : t < Orbit.open ? Orbit.seg(t, 1500, 2000) : 1) : 0)
            OrbitSheet(t: t, reading: reading, fromReading: fromReading).rotationEffect(.degrees(-3)).position(x: Orbit.cx, y: Orbit.cy)
                .opacity(reading ? 1 : t < Orbit.open ? 1 - (fromReading ? Orbit.seg(t, 200, 900) : Orbit.seg(t, 1300, 1900)) : 0)
            if picked >= 1 {
                let shown = rounds[picked - 1]
                OrbitCard(kind: .full(label: "第 \(picked) 题", round: shown), checks: (0..<3).map { j in !waiting || Int((t - pickEnd) / 280) % 4 != j })
                    .position(x: card.x, y: card.y)
            }
            HStack(spacing: 7) {
                ForEach(0..<dots, id: \.self) { j in
                    if j == picked { Circle().strokeBorder(MockPalette.ink, lineWidth: 1.5).frame(width: 9, height: 9) }
                    else { Circle().fill(j < picked ? MockPalette.ink : Color(hex: 0xD8D4CC)).frame(width: 7, height: 7) }
                }
            }
            .frame(height: 9).fixedSize().position(x: Orbit.cx, y: Orbit.cy + 74.5)
            .opacity(reading ? 0 : t < Orbit.open ? Orbit.seg(t, 1500, 2000) : 1)
            OrbitPlanets(planets: planets.filter { $0.z == 12 })
            OrbitPlanets(planets: planets.filter { $0.z == 20 })
            if let round, round.source < planets.count {
                quote(round, planet: planets[round.source], source: sources[round.source]).opacity(quoteOpacity)
            }
            if let round, rt >= 3420 && rt < 4700 {
                let drop = Orbit.seg(rt, 4200, 4600)
                OrbitCard(kind: .full(label: "第 \(index + 1) 题", round: round), checks: (0..<3).map { rt > 3600 + Double($0) * 230 })
                    .position(x: card.x, y: card.y + Orbit.lerp(-18, 0, drop))
            }
            if let round, rt >= 2500 && rt < 3500, round.source < planets.count, let start = planets[round.source].target {
                fly(round, start: start, rt: rt)
            }
        }
        .frame(width: MockFull.width, height: MockFull.height, alignment: .topLeading)
    }

    /// 依据：浮在这个来源外侧，写着那一行原句和为什么挑它。
    private func quote(_ round: MockPrep.Round, planet: OrbitPlanet, source: MockPrep.Source) -> some View {
        let node = round.node >= 0 && round.node < source.nodes.count ? source.nodes[round.node] : nil
        let text = node?.text ?? round.title
        let right = planet.x >= Orbit.cx
        let reach = planet.mr + planet.md
        let fresh = node == nil || node?.state == "new"
        return VStack(alignment: right ? .leading : .trailing, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: source.know ? 2 : 4).fill(fresh ? Orbit.new : Orbit.color(node!.state))
                    .overlay { if fresh { RoundedRectangle(cornerRadius: source.know ? 2 : 4).strokeBorder(MockPalette.ink, lineWidth: 1.5) } }
                    .frame(width: 8, height: 8).padding(.top, 6)
                Text(verbatim: source.know ? text : "“\(text)”").font(V3.sans(13, weight: .medium)).foregroundStyle(MockPalette.ink)
                    .lineHeight(13, 19.5).multilineTextAlignment(right ? .leading : .trailing)
            }
            Text(verbatim: round.why).font(V3.sans(11)).foregroundStyle(Color(hex: 0x6B6863)).lineHeight(11, 16.5).multilineTextAlignment(right ? .leading : .trailing)
        }
        .frame(width: 230, alignment: right ? .leading : .trailing).fixedSize(horizontal: false, vertical: true)
        .position(x: right ? planet.x + reach + 22 + 115 : planet.x - reach - 22 - 115, y: planet.y)
    }

    /// 那一行伸出小卡（写着考点），沿弧线飞进中间，边飞边长成题卡。
    private func fly(_ round: MockPrep.Round, start: (Double, Double), rt: Double) -> some View {
        let grow = Orbit.seg(rt, 2500, 2900), go = Orbit.seg(rt, 2900, 3450)
        let out = (start.0, start.1 - 40)
        let p0 = (Orbit.lerp(start.0, out.0, grow), Orbit.lerp(start.1, out.1, grow))
        let ex = Orbit.cx, ey = Orbit.cy - 18
        let cx = (out.0 + ex) / 2, cy = min(out.1, ey) - 60
        let bx = pow(1 - go, 2) * p0.0 + 2 * (1 - go) * go * cx + go * go * ex
        let by = pow(1 - go, 2) * p0.1 + 2 * (1 - go) * go * cy + go * go * ey
        let chipW = min(Double(round.title.count) * 13 + 30, 220)
        let w = go > 0 ? Orbit.lerp(chipW, 196, go) : Orbit.lerp(12, chipW, grow)
        let h = go > 0 ? Orbit.lerp(32, 104, go) : Orbit.lerp(12, 32, grow)
        let radius = go > 0 ? Orbit.lerp(8, 10, go) : Orbit.lerp(6, 8, grow)
        let fill = grow < 1 ? Orbit.mix(0xEAB34B, 1 - grow, 0xFBF1DC) : Orbit.mix(0xFBF1DC, 1 - go, 0xFFFFFF)
        return RoundedRectangle(cornerRadius: radius).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(MockPalette.ink, lineWidth: Orbit.lerp(1.5, 2, go)))
            .overlay {
                Text(verbatim: round.title).font(V3.sans(13, weight: .bold)).foregroundStyle(MockPalette.ink).lineLimit(1).fixedSize()
                    .opacity(Orbit.clamp((grow - 0.6) / 0.4) * (1 - Orbit.clamp((go - 0.55) / 0.35)))
            }
            .frame(width: w, height: h).clipped()
            .position(x: bx, y: by).opacity(1 - Orbit.clamp((rt - 3420) / 80))
    }
}

/// 一层来源：虚线外圈、选中时的金色光圈、圆心（知识来源白底）、每一行的小点和亮起的标记，下面是名字。
private struct OrbitPlanets: View {
    let planets: [OrbitPlanet]
    var body: some View {
        Canvas { context, _ in
            for p in planets {
                var layer = context
                layer.opacity = p.opacity
                func circle(_ x: Double, _ y: Double, _ size: Double, square: Bool = false) -> Path {
                    let rect = CGRect(x: p.x + x - size / 2, y: p.y + y - size / 2, width: size, height: size)
                    return square ? Path(roundedRect: rect, cornerRadius: 2) : Path(ellipseIn: rect)
                }
                layer.stroke(circle(0, 0, p.mr * 2), with: .color(Color(hex: 0xD8D4CC)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if p.selected > 0 {
                    var halo = layer
                    halo.opacity = p.opacity * p.selected
                    halo.stroke(circle(0, 0, p.r0 * 2 + 12), with: .color(Orbit.picked), lineWidth: 2)
                }
                layer.fill(circle(0, 0, p.r0 * 2), with: .color(p.flying ? Color(hex: 0xFBF1DC) : p.know ? .white : Color(hex: 0xF7F5F0)))
                layer.stroke(circle(0, 0, p.r0 * 2), with: .color(p.flying ? Orbit.picked : MockPalette.ink), lineWidth: p.chosen && p.selected > 0.5 ? 2 : 1.2)
                for moon in p.moons {
                    if moon.mark > 0 {
                        var mark = layer
                        mark.opacity = p.opacity * moon.mark
                        let shape = circle(moon.x, moon.y, moon.size + 14, square: p.know)
                        mark.fill(shape, with: .color(Color(hex: 0xFBF1DC)))
                        mark.stroke(shape, with: .color(Orbit.picked), lineWidth: 1.5)
                    }
                    var dot = layer
                    dot.opacity = p.opacity * moon.opacity
                    let shape = circle(moon.x, moon.y, moon.size, square: p.know)
                    dot.fill(shape, with: .color(moon.fill))
                    if moon.ring { dot.stroke(shape, with: .color(MockPalette.ink), lineWidth: 1.5) }
                }
                let strong = p.chosen && p.selected > 0.5
                guard p.labelOpacity > 0, !p.name.isEmpty else { continue }
                var label = layer
                label.opacity = p.opacity * p.labelOpacity
                label.draw(Text(verbatim: p.name).font(V3.sans(12, weight: strong ? .medium : .regular)).foregroundColor(strong ? MockPalette.ink : Color(hex: 0x6B6863)),
                           at: CGPoint(x: p.x, y: p.y + p.mr + p.md / 2 + 6), anchor: .top)
            }
        }
        .frame(width: MockFull.width, height: MockFull.height)
    }
}

/// 题卡（196 × 104）：第几题、考点、出处，右下三个核对点。叠在下面的是浅描边的空卡，开场时中间是一张虚线空位。
private struct OrbitCard: View {
    enum Kind { case ghost, slot, full(label: String, round: MockPrep.Round) }
    let kind: Kind
    var checks: [Bool] = [true, true, true]
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        ZStack(alignment: .topLeading) {
            switch kind {
            case .ghost:
                shape.fill(.white).overlay(shape.strokeBorder(MockPalette.ink.opacity(0.22), lineWidth: 1))
            case .slot:
                shape.strokeBorder(Color(hex: 0xD8D4CC), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            case let .full(label, round):
                shape.fill(.white).overlay(shape.strokeBorder(MockPalette.ink, lineWidth: 2)).shadow(color: MockPalette.ink.opacity(0.08), radius: 6, y: 4)
                Text(verbatim: label).font(V3.sans(11)).foregroundStyle(Color(hex: 0x8C8680)).frame(height: 16).offset(x: 16, y: 14)
                Text(verbatim: round.title).font(V3.sans(17, weight: .bold)).foregroundStyle(MockPalette.ink).lineLimit(1).truncationMode(.tail)
                    .frame(width: 164, height: 24, alignment: .leading).offset(x: 16, y: 33)
                HStack(spacing: 6) {
                    Circle().fill(Orbit.hex(round.dot)).frame(width: 7, height: 7)
                    Text(verbatim: round.from).font(V3.sans(11)).foregroundStyle(Color(hex: 0x6B6863)).lineLimit(1)
                }
                .frame(width: 124, height: 16, alignment: .leading).offset(x: 16, y: 73)
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { j in Circle().fill(checks[j] ? Orbit.held : Color(hex: 0xE7E5E0)).frame(width: 8, height: 8) }
                }
                .animation(.easeInOut(duration: 0.25), value: checks)
                .offset(x: 148, y: 78)
            }
        }
        .frame(width: 196, height: 104, alignment: .topLeading)
    }
}

/// 读简历时中间那张简历纸（128 × 164，`.mi3-orb-sheet`）：淡黄扫读带（`.mi3-orb-scan`，高 18）从上往下扫，
/// 扫过的行变深；一段经历扫完时那几行短暂变黄（随后飞进轨道）。题目回来后纸上的行保持扫过的颜色淡出。
private struct OrbitSheet: View {
    let t: Double
    let reading: Bool
    var fromReading = false
    private static let line = Color(hex: 0xD8D4CC)

    var body: some View {
        let first = t < Orbit.scanTo
        let bandY = !reading ? -20 : first ? (t - Orbit.scanFrom) / (Orbit.scanTo - Orbit.scanFrom) * Orbit.sheetH
            : (t - Orbit.scanTo).truncatingRemainder(dividingBy: Orbit.scanLoop) / Orbit.scanLoop * Orbit.sheetH
        let bandOpacity = !reading ? 0 : (first ? 1 : 0.55) * Orbit.seg(t, 0, Orbit.scanFrom)
        let shape = RoundedRectangle(cornerRadius: 8)
        ZStack(alignment: .topLeading) {
            shape.fill(.white)
            LinearGradient(stops: [.init(color: Orbit.picked.opacity(0), location: 0), .init(color: Orbit.picked.opacity(0.35), location: 0.5), .init(color: Orbit.picked.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: 128, height: 18).offset(y: bandY - 9).opacity(bandOpacity)
            ForEach(Orbit.sheetRows.indices, id: \.self) { index in
                let bar = Orbit.sheetRows[index]
                let color = rowColor(index)
                RoundedRectangle(cornerRadius: 2).fill(color.0).frame(width: bar.w, height: bar.h).offset(x: bar.x, y: bar.y)
                    .animation(.easeInOut(duration: 0.3), value: color.1)
            }
            Circle().fill(Orbit.picked).frame(width: 16, height: 16).offset(x: 14, y: 14)
        }
        .frame(width: 128, height: 164, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(MockPalette.ink, lineWidth: 1.5))
        .background(shape.fill(.white).shadow(color: MockPalette.ink.opacity(0.08), radius: 9, y: 6))
    }

    /// 某一行此刻的颜色（第二项是颜色的种类，给过渡动画用）。
    private func rowColor(_ index: Int) -> (Color, Int) {
        if index == 0 { return (MockPalette.ink, 0) }
        let bar = Orbit.sheetRows[index]
        let scanned = Orbit.scanAt(bar.y + bar.h)
        let block = Orbit.sheetBlocks.firstIndex { $0.contains(index) }
        let done = block.map { Orbit.blockDone[$0] } ?? scanned
        let lifting = reading && block != nil && t > done - 450 && t < done + 350
        if lifting { return (Orbit.picked, 1) }
        if !reading { return fromReading ? (Orbit.rowRead, 2) : (Self.line, 3) }
        return t >= scanned ? (Orbit.rowRead, 2) : (Self.line, 3)
    }
}

// MARK: 检查设备（Figma 09 · 03 开始前 03.02–03.07；Web `DeviceCheckStage`）

/// 进来就请求麦克风；麦克风只看有没有收到声音：随便说一句、音量过线就算正常，不再让用户照读一句、也不调语音识别（Web #1563，11-27）。
/// 听到你的声音后自动放一句面试官的声音，问听到了没有。
/// 中间的圈随状态变：听你说话时黄色音量圈随音量外扩，放面试官声音时绿色声波外扩，都好了绿圈加勾，出问题朱砂虚线。
struct MockDeviceCheck: View {
    @Environment(SessionStore.self) private var session
    let detail: JSONValue
    let busy: String?
    let onStart: () -> Void
    /// 左上返回：回到准备题目（看挑题），不放弃这一场
    let onBack: () -> Void
    let onSwitchToText: () -> Void
    /// 题目准备好后右下角「取消本场」（积分不退）
    let onCancel: () -> Void

    private enum Speaker { case idle, playing, confirm, heard, unheard, unsupported }
    @State private var mic = MicrophoneProbe()
    @State private var heardVoice = false
    @State private var quiet = false
    @State private var speaker: Speaker = .idle
    @State private var player = InterviewerVoice()
    @State private var output = MicrophoneProbe.outputName() ?? "系统默认扬声器"

    private static let threshold: Float = 0.06

    var body: some View {
        let granted = mic.permission == .granted
        let blocked = mic.permission == .denied || mic.permission == .error
        let silent = granted && quiet && !heardVoice
        let speakerBad = speaker == .unheard
        let micOk = granted && heardVoice
        let soundOk = micOk && (speaker == .heard || speaker == .unsupported)
        let preparing = detail.text("status") == "preparing"
        let ready = soundOk && !preparing
        let bad = blocked || silent || speakerBad
        let count = detail["question_count"]?.integer ?? 0
        let first = MockPrep.prep(detail)?.text("first").nonEmptyValue
        let playing = speaker == .playing || speaker == .confirm
        MockSessionFrame {
            MockSessionHead(detail: detail, back: ("准备题目", busy != nil, onBack))
            if mic.permission == .unavailable {
                MockPrepTitle(text: "这台设备暂时没法语音面试")
                MockCenterLine(text: "没有检测到麦克风", top: 206, size: 14, line: 22, color: MockPalette.sub)
                MockSoundRing(tone: .bad, level: 0)
                mainLine(Text("插上耳机或外接麦克风，或在“系统设置 › 声音 › 输入”里选一个麦克风").font(V3.sans(18, weight: .medium)))
                subLine(Text("同一套 \(count) 道题也可以改成打字作答，题目不用重新准备"))
                act { MockArrowLink(title: "重新检测", size: 14, action: recheck) }
            } else {
                let head: (String, String) = blocked ? ("还听不到你的声音", "DrawOffer 没有拿到麦克风权限")
                    : silent ? ("还听不到你的声音", "麦克风没有收到声音")
                    : speakerBad ? ("听不到面试官的声音", "调大音量，或换一个扬声器、耳机")
                    : ready ? ("可以开始了", first.map { "\(count) 道题已经准备好，第一题从「\($0)」问起" } ?? "\(count) 道题已经准备好")
                    : soundOk ? ("声音没问题", "题目一准备好就能开始")
                    : ("先试一下声音", "安静环境、戴耳机效果更好")
                let listening = granted && !heardVoice
                let tone: MockSoundRing.Tone = bad ? .bad : soundOk ? .ok : playing ? .play : granted ? .listen : .idle
                let micState: (Side, String) = blocked ? (.bad, "没有权限") : silent ? (.bad, "没听到声音") : granted ? (.ok, "正常") : (.wait, "正在请求…")
                let speakerState: (Side, String) = speaker == .heard ? (.ok, "听得到") : speaker == .playing ? (.play, "正在播放") : speaker == .confirm ? (.play, "听到了吗？")
                    : speaker == .unheard ? (.bad, "听不到") : speaker == .unsupported ? (.bad, "没能播放") : (.wait, "还没试")
                MockPrepTitle(text: head.0)
                MockCenterLine(text: head.1, top: 206, size: 14, line: 22, color: MockPalette.sub)
                MockSoundRing(tone: tone, level: listening ? Double(mic.level) : 0, blocked: blocked || silent)
                VStack(alignment: .trailing, spacing: 6) {
                    sideState("麦克风", micState)
                    if !blocked { devicePicker(mic.deviceName.nonEmptyValue ?? "默认麦克风", label: "选择麦克风", pane: "input") }
                }
                .fixedSize().frame(width: 400, alignment: .topTrailing).offset(x: 512 - 400, y: 367)
                sideDot(micState.0).offset(x: 529, y: 379)
                sideDot(speakerState.0).offset(x: 829, y: 379)
                VStack(alignment: .leading, spacing: 6) {
                    sideState("面试官声音", speakerState)
                    HStack(spacing: 10) {
                        devicePicker(output, label: "选择扬声器", pane: "output")
                        if speaker != .idle {
                            Button("▶ 再听一次") { Task { await preview() } }.buttonStyle(MockSideLinkStyle()).disabled(speaker == .playing)
                        } else if granted {
                            Button("▶ 试听") { Task { await preview() } }.buttonStyle(MockSideLinkStyle())
                        }
                    }
                }
                .fixedSize().offset(x: 856, y: 367)
                center(blocked: blocked, silent: silent, speakerBad: speakerBad, playing: playing, soundOk: soundOk, ready: ready, preparing: preparing, granted: granted)
            }
            MockSessionFoot {
                MockPrepFootLine(session: MockPrep.sessionLine(detail, voice: true), note: MockPrep.prepNote(detail))
            } right: {
                if !preparing { MockArrowLink(title: busy == "abandon" ? "正在取消…" : "取消本场", action: onCancel).disabled(busy != nil) }
                MockArrowLink(title: busy == "text" ? "正在切换…" : "改为文字面试", action: onSwitchToText).disabled(busy != nil)
            }
        }
        .task { if mic.permission == .idle { await mic.start() } }
        .onChange(of: mic.level) { _, level in
            if level > Self.threshold * 1.5 { heardVoice = true; quiet = false }
        }
        .task(id: "\(mic.permission == .granted)-\(heardVoice)") {
            guard mic.permission == .granted, !heardVoice else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, !heardVoice { quiet = true }
        }
        // 听到你的声音后自动放一句面试官的声音（04B.02）
        .onChange(of: mic.permission == .granted && heardVoice && speaker == .idle) { _, value in if value { Task { await preview() } } }
        .onDisappear { mic.stop(); player.stop() }
    }

    private enum Side { case ok, bad, wait, play }
    private func toneColor(_ tone: Side) -> Color {
        switch tone {
        case .ok: Orbit.held
        case .bad: Orbit.weak
        case .wait: Color(hex: 0xA8A29E)
        case .play: Orbit.picked
        }
    }
    private func sideState(_ title: String, _ state: (Side, String)) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title).foregroundStyle(Color(hex: 0x8C8680))
            Text(verbatim: state.1).fontWeight(.medium).foregroundStyle(state.0 == .bad ? Orbit.weak : state.0 == .wait ? Color(hex: 0xA8A29E) : MockPalette.ink)
        }
        .font(V3.sans(12)).frame(height: 14)
    }
    private func sideDot(_ tone: Side) -> some View {
        Circle().fill(toneColor(tone)).overlay(Circle().strokeBorder(.white, lineWidth: 2)).frame(width: 10, height: 10)
    }
    /// 设备名 ⌄：macOS 的录音跟随系统默认设备，点开“系统设置 › 声音”的输入或输出页换设备。
    private func devicePicker(_ name: String, label: String, pane: String) -> some View {
        Button {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?\(pane)")!)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: name).font(V3.sans(12, weight: .medium)).foregroundStyle(MockPalette.ink).lineLimit(1).frame(maxWidth: 220, alignment: .trailing).fixedSize(horizontal: true, vertical: false)
                Text("⌄").font(V3.sans(10)).foregroundStyle(MockPalette.sub)
            }
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    @ViewBuilder
    private func center(blocked: Bool, silent: Bool, speakerBad: Bool, playing: Bool, soundOk: Bool, ready: Bool, preparing: Bool, granted: Bool) -> some View {
        let fixSub = "改好后点「重新检测」；不方便说话也可以直接改成打字作答，题目不用重新准备"
        if blocked || silent {
            mainLine(Text(blocked ? "在“系统设置 › 隐私与安全性 › 麦克风”中允许 DrawOffer" : "检查麦克风有没有静音，或在左边换一个设备").font(V3.sans(18, weight: .medium)))
            subLine(Text(fixSub))
            act { MockArrowLink(title: "重新检测", size: 14, action: recheck) }
        } else if playing || speakerBad {
            mainLine(Text("「\(MockPrep.interviewerLine)」").font(V3.sans(22, weight: .medium)))
            subLine(Text(speakerBad ? "调大音量或换耳机后，点右边「再听一次」" : speaker == .playing ? "面试官在说话，听到了吗？" : "面试官说完了，听到了吗？"))
            if !speakerBad {
                act {
                    HStack(spacing: 32) {
                        Button("听到了") { speaker = .heard }.buttonStyle(MockLinkStyle(size: 14, color: MockPalette.ink))
                        Button("听不到") { speaker = .unheard }.buttonStyle(MockLinkStyle(size: 14))
                    }
                    .fontWeight(.medium).padding(.top, 4)
                }
            }
        } else if soundOk {
            mainLine(Text("麦克风和声音都没问题").font(V3.sans(18, weight: .medium)))
            subLine(Text(preparing ? "题目一准备好就能开始" : "随时可以开始"))
            if ready {
                act { Button("开始语音面试") { mic.stop(); player.stop(); onStart() }.buttonStyle(MockPillStyle(height: 42)).frame(minWidth: 140) }
            }
        } else {
            mainLine(Text(granted ? "随便说一句话，中间的圈跟着动就说明麦克风正常" : "正在请求麦克风…").font(V3.sans(18, weight: .medium)))
            subLine(Text(granted ? "正在听…" : "系统弹出提示时，选择允许使用麦克风"))
        }
    }
    private func mainLine(_ text: Text) -> some View {
        text.foregroundStyle(MockPalette.ink).lineLimit(1).frame(width: 1120, height: 30).offset(x: 124, y: 552)
    }
    private func subLine(_ text: Text) -> some View {
        text.font(V3.sans(13)).foregroundStyle(MockPalette.sub).lineLimit(1).frame(width: 1120, height: 20).offset(x: 124, y: 586)
    }
    private func act<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(width: 1120, alignment: .top).offset(x: 124, y: 620)
    }

    private func recheck() {
        heardVoice = false; quiet = false; speaker = .idle
        output = MicrophoneProbe.outputName() ?? "系统默认扬声器"
        Task { await mic.start() }
    }
    private func preview() async {
        player.stop(); speaker = .playing
        do {
            player.play(try await session.api.mockAudio(path: "/api/mock-interviews/\(detail.display("id"))/speech/playback", method: "POST", body: .object([:])))
            try? await Task.sleep(for: .milliseconds(300))
            while player.playing { try? await Task.sleep(for: .milliseconds(200)) }
            if speaker == .playing { speaker = .confirm }
        } catch { speaker = .unsupported }
    }
}

/// 设备两侧「▶ 试听」「▶ 再听一次」：12 号中等字，播放中变浅。
private struct MockSideLinkStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(12, weight: .medium)).foregroundStyle(enabled ? MockPalette.ink : Color(hex: 0xA8A29E)).lineLimit(1).fixedSize()
            .opacity(configuration.isPressed ? 0.6 : 1).contentShape(Rectangle())
    }
}

/// 中间的圈（`SoundRing`，圆心 684, 384）。
struct MockSoundRing: View {
    enum Tone { case idle, listen, play, ok, bad }
    let tone: Tone
    let level: Double
    var blocked = false
    var body: some View {
        let swell = min(1, level / 0.25)
        let dashed = StrokeStyle(lineWidth: 1, dash: [3, 4])
        ZStack {
            Circle().stroke(Color(hex: 0xE7E5E0), style: dashed).frame(width: 300, height: 300)
            Circle().stroke(Color(hex: 0xE7E5E0), style: dashed).frame(width: 236, height: 236)
            if tone == .listen {
                Circle().fill(Orbit.picked.opacity(0.12)).frame(width: 224, height: 224)
                    .scaleEffect((224 + swell * 48) / 224).animation(.linear(duration: 0.12), value: swell)
                Circle().fill(Orbit.picked.opacity(0.16)).overlay(Circle().strokeBorder(Orbit.picked, lineWidth: 2)).frame(width: 192, height: 192)
            }
            if tone == .play {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<2, id: \.self) { i in
                            let phase = (t + Double(i) * 0.9).truncatingRemainder(dividingBy: 1.8) / 1.8
                            let eased = 1 - pow(1 - phase, 2)
                            Circle().stroke(Orbit.held, lineWidth: 1.5).frame(width: 184 + 76 * eased, height: 184 + 76 * eased).opacity(0.9 * (1 - eased))
                        }
                    }
                }
            }
            if tone == .ok { Circle().stroke(Orbit.held, lineWidth: 1.5).frame(width: 184, height: 184) }
            if tone == .bad { Circle().stroke(Orbit.weak, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).frame(width: 184, height: 184) }
            Circle().fill(.white).overlay(Circle().strokeBorder(MockPalette.ink, lineWidth: 1.5)).frame(width: 144, height: 144)
            if tone == .play {
                Text("面试官").font(V3.sans(13, weight: .medium)).foregroundStyle(MockPalette.ink)
            } else {
                Image(systemName: "mic").font(.system(size: 22, weight: .medium)).foregroundStyle(Color(hex: 0x55554F))
                    .overlay { if blocked { Path { p in p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 22, y: 22)) }.stroke(Orbit.weak, lineWidth: 2).frame(width: 22, height: 22) } }
            }
            if tone == .ok {
                Text("✓").font(V3.sans(14, weight: .medium)).foregroundStyle(.white).frame(width: 26, height: 26).background(Circle().fill(Orbit.held)).offset(x: 52, y: -52)
            }
        }
        .frame(width: 300, height: 300).position(x: 684, y: 384).frame(width: MockFull.width, height: MockFull.height, alignment: .topLeading)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
