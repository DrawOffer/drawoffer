import Foundation
import DrawOfferCore
import SwiftUI

/// 模拟面试重做（Figma「DrawOffer macOS 设计稿」09 · 模拟面试，页 5:23）的公共部件：
/// 配色、黑白胶囊、文字链、确认卡、表单卡、分段选择、声纹、摘要四列。对应 Web `v2/mi3.css`、`mi3Ui.tsx`、`Voiceprint.tsx`。
enum MockPalette {
    static let ink = Color(hex: 0x1D1D1B)
    static let sub = Color(hex: 0x55554F)
    static let fnt = Color(hex: 0x6C6C65)
    static let mute = Color(hex: 0x96968F)
    static let hint = Color(hex: 0x87867F)
    static let faint = Color(hex: 0xCFCFCA)
    static let cl = Color(hex: 0xE4E4E0)
    static let line = Color(hex: 0xECECEA)
    static let edge = Color(hex: 0xDEDEDA)
    static let field = Color(hex: 0xF7F7F4)
    static let chip = Color(hex: 0xF4F4F2)
    static let hover = Color(hex: 0xF3F3F0)
    static let rowHover = Color(hex: 0xFAFAF8)
    static let blue = Color(hex: 0x3F6FD8)
    static let blueDeep = Color(hex: 0x2F5CC2)
    static let lightBlue = Color(hex: 0x8AA9EE)
    static let orange = Color(hex: 0xD9822B)
}

// MARK: 按钮

/// `.mi3-btn`：一页一个墨黑胶囊，其余白底细边胶囊；宽度跟着文字。
struct MockPillStyle: ButtonStyle {
    enum Kind { case dark, ghost }
    var kind: Kind = .dark
    var height: CGFloat = 38
    var padding: CGFloat? = nil
    var size: CGFloat = 13.5
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let dark = kind == .dark
        return configuration.label
            .font(V3.sans(size, weight: .medium)).lineLimit(1).fixedSize()
            .foregroundStyle(dark ? Color.white : MockPalette.ink)
            .padding(.horizontal, padding ?? (dark ? 28 : 21))
            .frame(height: height)
            .background {
                if dark { Capsule().fill(pressed ? Color(hex: 0x33332F) : MockPalette.ink) }
                else { Capsule().fill(pressed ? MockPalette.chip : .white).overlay(Capsule().strokeBorder(.black.opacity(0.12))) }
            }
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// `.mi3-link`：13px 灰字，悬停变墨黑；蓝色版本只给文字链。
struct MockLinkStyle: ButtonStyle {
    var blue = false
    var size: CGFloat = 13
    var color: Color? = nil
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        let base = color ?? (blue ? MockPalette.blue : MockPalette.fnt)
        let active = blue ? MockPalette.blueDeep : MockPalette.ink
        return configuration.label.font(V3.sans(size)).lineLimit(1).fixedSize()
            .foregroundStyle(!enabled ? MockPalette.faint : hover || configuration.isPressed ? active : base)
            .contentShape(Rectangle()).onHover { hover = $0 }
    }
}

/// 下拉箭头（Web `Caret`）：10 × 10 的折线。
struct MockCaret: View {
    var color = MockPalette.fnt
    var body: some View {
        Path { path in path.move(to: CGPoint(x: 2.5, y: 3.75)); path.addLine(to: CGPoint(x: 5, y: 6.25)); path.addLine(to: CGPoint(x: 7.5, y: 3.75)) }
            .stroke(color, style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            .frame(width: 10, height: 10).offset(y: -1).accessibilityHidden(true)
    }
}

/// 分段选择（macOS 稿：浅灰底、选中白块带细阴影）。
struct MockSeg<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String, disabled: Bool)]
    let current: Value
    var disabled = false
    let pick: (Value) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == current
                let off = disabled || option.disabled
                Button { pick(option.value) } label: {
                    Text(verbatim: option.title).font(V3.sans(12.5, weight: on ? .medium : .regular))
                        .foregroundStyle(off ? MockPalette.faint : on ? MockPalette.ink : MockPalette.sub)
                        .frame(minWidth: 38).padding(.horizontal, 9).frame(height: 24)
                        .background {
                            if on { RoundedRectangle(cornerRadius: 5).fill(.white).shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5).shadow(color: .black.opacity(0.06), radius: 2, y: 1) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(off)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2).background(Color.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
        .accessibilityElement(children: .contain).accessibilityLabel(label)
    }
}

// MARK: 弹窗

/// `ConfirmDialog`（mi3Ui）：460 宽，标题 17、说明 14，右下取消 + 墨黑确认。放进 `.centeredSheet` 用。
struct MockConfirmCard<Extra: View>: View {
    let title: String
    let desc: String
    let confirm: String
    var cancel = "取消"
    var busy = false
    var busyLabel: String? = nil
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @ViewBuilder var extra: () -> Extra
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title).font(V3.sans(17, weight: .medium)).foregroundStyle(MockPalette.ink).frame(height: 24, alignment: .leading)
            Text(verbatim: desc).font(V3.sans(14)).foregroundStyle(MockPalette.sub).lineHeight(14, 22)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            extra()
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(cancel, action: onCancel).buttonStyle(MockPillStyle(kind: .ghost, height: 36, padding: 20)).disabled(busy).keyboardShortcut(.cancelAction)
                Button(busy ? busyLabel ?? confirm : confirm, action: onConfirm).buttonStyle(MockPillStyle(height: 36, padding: 24)).disabled(busy)
            }.padding(.top, 24)
        }
        .padding(.horizontal, 33).padding(.top, 29).padding(.bottom, 28)
        .frame(width: 460, alignment: .leading)
    }
}

extension MockConfirmCard where Extra == EmptyView {
    init(title: String, desc: String, confirm: String, cancel: String = "取消", busy: Bool = false, busyLabel: String? = nil, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.init(title: title, desc: desc, confirm: confirm, cancel: cancel, busy: busy, busyLabel: busyLabel, onConfirm: onConfirm, onCancel: onCancel, extra: { EmptyView() })
    }
}

/// `.mi3-form`：462 宽的表单卡，标题 17（导入记录用 20 衬线），说明 13；底部一条分隔线上是 72 高的按钮行。
struct MockFormCard<Content: View, Left: View, Foot: View>: View {
    let title: String
    var sub: String? = nil
    var serif = false
    var width: CGFloat = 462
    let close: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var left: () -> Left
    @ViewBuilder var foot: () -> Foot
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title).font(serif ? V3.serif(20) : V3.sans(17, weight: .medium)).foregroundStyle(MockPalette.ink).frame(height: serif ? 28 : 24, alignment: .leading)
            if let sub { Text(verbatim: sub).font(V3.sans(13)).foregroundStyle(MockPalette.fnt).frame(height: 20, alignment: .leading).padding(.top, 6) }
            content()
            HStack(spacing: 10) {
                left()
                Spacer(minLength: 0)
                foot()
            }
            .frame(maxWidth: .infinity).frame(height: 72)
            .overlay(alignment: .top) { Rectangle().fill(MockPalette.line).frame(height: 1).padding(.horizontal, -33) }
            .padding(.top, 20)
        }
        .padding(.horizontal, 33).padding(.top, 29)
        .frame(width: width, alignment: .leading)
        .background { Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
    }
}

// MARK: 提示条

struct MockNotice: Equatable {
    enum Kind { case error, success, queued }
    var kind: Kind = .error
    var title: String
    var message: String? = nil
}

/// 页面右上角的提示条（Web `Toast`）：4 秒后自动收起。
struct MockNoticeToast: View {
    @Binding var notice: MockNotice?
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let notice {
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(notice.kind == .error ? MockPalette.orange : notice.kind == .success ? V3.green : MockPalette.blue).frame(width: 7, height: 7).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: notice.title).font(V3.sans(13, weight: .medium)).foregroundStyle(MockPalette.ink)
                        if let message = notice.message { Text(verbatim: message).font(V3.sans(12.5)).foregroundStyle(MockPalette.fnt).fixedSize(horizontal: false, vertical: true) }
                    }
                    Button { self.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).foregroundStyle(MockPalette.mute) }
                        .buttonStyle(.plain).accessibilityLabel("关闭提示")
                }
                .padding(.horizontal, 14).padding(.vertical, 11).frame(maxWidth: 340, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.08)))
                .shadow(color: .black.opacity(0.1), radius: 14, y: 6)
                .padding(.top, 16).padding(.trailing, 20)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .task(id: notice) { try? await Task.sleep(for: .seconds(4)); if !Task.isCancelled { withAnimation { self.notice = nil } } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.easeOut(duration: 0.2), value: notice)
        .allowsHitTesting(notice != nil)
    }
}

// MARK: 声纹（Web `Voiceprint.tsx`）

enum MockRand {
    /// LCG（与 Web 相同的常数），种子由 FNV-1a 散列得到。
    static func generator(_ seed: String) -> () -> Double {
        var value = hash(seed)
        if value == 0 { value = 1 }
        return {
            value = value &* 1664525 &+ 1013904223
            return Double(value) / 4294967296
        }
    }
    static func hash(_ text: String) -> UInt32 {
        var value: UInt32 = 2166136261
        for unit in text.unicodeScalars { value = (value ^ UInt32(truncatingIfNeeded: unit.value & 0xFFFF)) &* 16777619 }
        return value
    }
}

private enum Wave {
    static let rowW = 1000.0, rowStep = 5.0, barW = 2.6, rowScale = 1.625
    static let rowBars = Int(rowW / rowStep), orangeBars = 17
    static let ghost: [Double] = [6, 23, 11, 10, 22, 19, 16, 28, 31, 26, 32, 31, 38, 18, 22, 32, 30, 10, 26, 18, 27, 23, 8, 15, 23, 19, 19, 19, 28, 31, 19, 19, 36, 21, 15, 20, 24, 19, 39, 25, 28, 30, 8, 12, 17, 15, 13, 9, 23, 7, 15, 15, 25, 31, 19, 10, 14, 10, 10, 10, 7, 8, 7, 3, 5, 3]
    static let ghostBlue = 53, ghostStep = 5.5
    static let ghostBars = Int(rowW / ghostStep)
}

/// 首页一条回答的声纹：蓝色是答出来的部分，橙色是停下的那段；画得比最宽的页面还长，靠右对齐裁掉左边。
struct MockRowVoiceprint: View {
    let seed: String
    var opacity: Double = 1
    var body: some View {
        let bars: [Double] = {
            let next = MockRand.generator(seed)
            let blue: [Double] = (0..<(Wave.rowBars - Wave.orangeBars)).map { (_: Int) -> Double in 10 + next() * 25 }
            let orange: [Double] = (0..<Wave.orangeBars).map { (index: Int) -> Double in
                let fade: Double = pow(1 - Double(index) / Double(Wave.orangeBars), 1.4)
                let jitter: Double = 0.8 + next() * 0.2
                return 3 + jitter * 24 * fade
            }
            return (blue + orange).map { $0 * Wave.rowScale }
        }()
        Canvas { context, size in
            Self.draw(context, size, heights: bars, viewH: 60, step: Wave.rowStep, blueCount: Wave.rowBars - Wave.orangeBars, opacity: opacity)
        }
        .frame(height: 60).accessibilityHidden(true)
    }

    /// `preserveAspectRatio="xMaxYMid slice"`：按较大的缩放铺满，右对齐、上下居中。
    static func draw(_ context: GraphicsContext, _ size: CGSize, heights: [Double], viewH: Double, step: Double, blueCount: Int, opacity: Double) {
        let scale = max(size.width / Wave.rowW, size.height / viewH)
        let dx = size.width - Wave.rowW * scale, dy = (size.height - viewH * scale) / 2
        let count = heights.count
        for (index, height) in heights.enumerated() {
            let x = Wave.rowW - Wave.barW - Double(count - 1 - index) * step
            let rect = CGRect(x: dx + x * scale, y: dy + (viewH - height) / 2 * scale, width: Wave.barW * scale, height: height * scale)
            guard rect.maxX > 0 else { continue }
            context.fill(Path(roundedRect: rect, cornerRadius: 1.3 * scale), with: .color((index < blueCount ? MockPalette.lightBlue : MockPalette.orange).opacity(opacity)))
        }
    }
}

/// 还没发生的一行：灰条占位加一段淡声纹，shift 让每行错开。
struct MockGhostRow: View {
    let opacity: Double
    var shift = 0
    var body: some View {
        let tail = Wave.ghost.count - Wave.ghostBlue
        let heights = (0..<Wave.ghostBars).map { index -> Double in
            let at = index - (Wave.ghostBars - tail)
            return (at >= 0 ? Wave.ghost[Wave.ghostBlue + at] : Wave.ghost[(index + shift * 17) % Wave.ghostBlue]) * Wave.rowScale
        }
        Canvas { context, size in
            MockRowVoiceprint.draw(context, size, heights: heights, viewH: 64, step: Wave.ghostStep, blueCount: Wave.ghostBars - tail, opacity: 1)
        }
        .frame(height: 64).accessibilityHidden(true)
    }
}

/// 面试中的大声纹（900 × 100）：you 跟着麦克风，interviewer 说话时持续起伏，rest 是静止的灰声纹，flat 是一条线。
struct MockLiveVoiceprint: View {
    enum Tone { case interviewer, you, rest, flat }
    let tone: Tone
    var values: [Double] = []
    private static let bars = 150, step = 6.0, barW = 3.0, waveH = 100.0, minH = 3.0, maxH = 80.0

    private static func envelope(_ index: Int) -> Double { pow(sin(Double.pi * (Double(index) + 0.5) / Double(bars)), 0.6) }
    static func speech(_ frame: Int) -> [Double] {
        (0..<bars).map { (index: Int) -> Double in
            let i = Double(index), f = Double(frame)
            let a: Double = sin(i * 0.37 + f * 0.9) * 0.55
            let b: Double = sin(i * 0.11 - f * 0.5) * 0.45
            let wave: Double = abs(a + b)
            let grain: Double = MockRand.generator("\(index):\(frame % 7)")()
            let mixed: Double = wave * 0.75 + grain * 0.25
            return max(minH, mixed * maxH * envelope(index))
        }
    }
    private static let resting = speech(3).map { max(minH, $0 * 0.38) }

    var body: some View {
        Group {
            if tone == .interviewer {
                TimelineView(.periodic(from: .now, by: 0.12)) { timeline in
                    canvas(Self.speech(Int(timeline.date.timeIntervalSinceReferenceDate / 0.12)))
                }
            } else {
                canvas(tone == .you ? mic : tone == .rest ? Self.resting : Array(repeating: Self.minH, count: Self.bars))
            }
        }
        .frame(width: 900, height: Self.waveH).accessibilityHidden(true)
    }

    private var mic: [Double] {
        (0..<Self.bars).map { (index: Int) -> Double in
            let at: Int = Int(Double(index) / Double(Self.bars) * Double(values.count))
            let value: Double = values.isEmpty ? 0 : values[min(values.count - 1, at)]
            let level: Double = min(1, value * 2.4)
            return max(Self.minH, level * Self.maxH * Self.envelope(index))
        }
    }

    private func canvas(_ heights: [Double]) -> some View {
        let fill = tone == .you ? MockPalette.blue : tone == .interviewer ? MockPalette.fnt : MockPalette.faint
        return Canvas { context, _ in
            for (index, height) in heights.enumerated() {
                context.fill(Path(roundedRect: CGRect(x: Double(index) * Self.step + 1, y: (Self.waveH - height) / 2, width: Self.barW, height: height), cornerRadius: 1.5), with: .color(fill))
            }
        }
    }
}

/// 设备检测的小声纹（165 × 24）。
struct MockMiniVoiceprint: View {
    let values: [Double]
    var body: some View {
        Canvas { context, _ in
            for index in 0..<33 {
                let value = values.isEmpty ? 0 : values[min(values.count - 1, Int(Double(index) / 33 * Double(values.count)))]
                let height = max(2, min(1, value * 2.4) * 22)
                context.fill(Path(roundedRect: CGRect(x: Double(index) * 5, y: 12 - height / 2, width: 2.6, height: height), cornerRadius: 1.3), with: .color(MockPalette.blue))
            }
        }
        .frame(width: 165, height: 24).accessibilityHidden(true)
    }
}

/// 一段声音的音量记录：每次音量变化推进一格（面试中、设备检测用）。
struct MockLevelHistory: ViewModifier {
    let level: Float
    @Binding var history: [Double]
    func body(content: Content) -> some View {
        content.onChange(of: level) { _, value in
            var next = history.count >= 64 ? Array(history.dropFirst()) : history
            next.append(Double(value)); history = next
        }
    }
}

// MARK: 摘要四列（首页、结束页共用）

struct MockTally: Identifiable {
    var value: String
    var unit: String? = nil
    var label: String
    var tone: Color? = nil
    var text: String
    var dot: Color? = nil
    var id: String { label }
}

/// `.mi3-tally`：衬线大数 + 单位 + 标签，下面一行说明（带点时是蓝 / 橙小圆点）。
struct MockTallyCell: View {
    let item: MockTally
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: item.value).font(V3.serif(28)).foregroundStyle(item.unit == nil ? MockPalette.faint : MockPalette.ink)
                if let unit = item.unit { Text(verbatim: unit).font(V3.sans(13)).foregroundStyle(MockPalette.fnt).padding(.leading, 3) }
                Text(verbatim: item.label).font(V3.sans(13, weight: .medium)).foregroundStyle(item.tone ?? MockPalette.ink).lineLimit(1)
                    .padding(.leading, item.unit == nil ? 5 : 8)
            }
            .frame(height: 38, alignment: .leading)
            HStack(alignment: .top, spacing: 8) {
                if let dot = item.dot { Circle().fill(dot).frame(width: 6, height: 6).padding(.top, 7) }
                Text(verbatim: item.text).font(V3.sans(13)).foregroundStyle(item.dot == nil ? MockPalette.fnt : MockPalette.sub)
                    .lineHeight(13, 20).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
