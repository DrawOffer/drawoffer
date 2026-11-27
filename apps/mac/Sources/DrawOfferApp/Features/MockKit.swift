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

/// 分段选择（macOS 稿：浅灰底、选中白块带细阴影）。
struct MockSeg<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String, disabled: Bool)]
    let current: Value
    var disabled = false
    /// 弹窗里的胶囊分段（Figma 02.05：浅灰胶囊底、选中白胶囊带细描边）
    var pill = false
    let pick: (Value) -> Void
    var body: some View {
        HStack(spacing: pill ? 0 : 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == current
                let off = disabled || option.disabled
                Button { pick(option.value) } label: {
                    Text(verbatim: option.title).font(V3.sans(pill ? 13 : 12.5, weight: on ? .medium : .regular))
                        .foregroundStyle(off ? MockPalette.faint : on ? MockPalette.ink : MockPalette.sub)
                        .frame(minWidth: pill ? 26 : 38).padding(.horizontal, pill ? 12.5 : 9).frame(height: pill ? 25 : 24)
                        .background {
                            if on && pill { Capsule().fill(.white).overlay(Capsule().strokeBorder(MockPalette.cl)) }
                            else if on { RoundedRectangle(cornerRadius: 5).fill(.white).shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5).shadow(color: .black.opacity(0.06), radius: 2, y: 1) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(off)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(pill ? 2.5 : 2)
        .background(pill ? MockPalette.hover : Color.black.opacity(0.055), in: RoundedRectangle(cornerRadius: pill ? 15 : 7))
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
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            extra()
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(cancel, action: onCancel).buttonStyle(MockPillStyle(kind: .ghost, height: 32, padding: 23, size: 12)).disabled(busy).keyboardShortcut(.cancelAction)
                Button(busy ? busyLabel ?? confirm : confirm, action: onConfirm).buttonStyle(MockPillStyle(height: 38, padding: 24)).disabled(busy)
            }.padding(.top, 30)
        }
        .padding(.horizontal, 33).padding(.top, 30).padding(.bottom, 23)
        .frame(width: 460, alignment: .leading)
    }
}

extension MockConfirmCard where Extra == EmptyView {
    init(title: String, desc: String, confirm: String, cancel: String = "取消", busy: Bool = false, busyLabel: String? = nil, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.init(title: title, desc: desc, confirm: confirm, cancel: cancel, busy: busy, busyLabel: busyLabel, onConfirm: onConfirm, onCancel: onCancel, extra: { EmptyView() })
    }
}

// MARK: 提示条

struct MockNotice: Equatable {
    enum Kind { case error, success, queued }
    var kind: Kind = .error
    var title: String
    var message: String? = nil
}

/// 模拟面试各页的提示条：与其他页面一样走第 16 页「顶部提示栏统一」的 `NoticeToast`（Web `Toast`），居中浮在页面顶部 20pt。
/// 页面仍持有 `MockNotice`，这里换算成 `NoticeToastItem`：出错 = 没做成，成功 = 完成，已提交 = 交给后台。
struct MockNoticeToast: View {
    @Binding var notice: MockNotice?
    @State private var item: NoticeToastItem?
    var body: some View {
        NoticeToast(item: $item).padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(item != nil)
            .onAppear { item = notice.map(Self.item) }
            .onChange(of: notice) { _, next in item = next.map(Self.item) }
            .onChange(of: item) { _, next in if next == nil, notice != nil { notice = nil } }
    }
    private static func item(_ notice: MockNotice) -> NoticeToastItem {
        switch notice.kind {
        case .error: return .failed(notice.title, notice.message)
        case .success: return .done(notice.title, notice.message)
        case .queued: return .queued(notice.title, notice.message)
        }
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
