import DrawOfferCore
import SwiftUI

/// Web `features/interviews/progress/progressDeck.css` 的颜色。
enum PD {
    static let ink = Color(hex: 0x1D1D1B)
    static let body = Color(hex: 0x55554F)
    static let mute = Color(hex: 0x96968F)
    static let blue = Color(hex: 0x3F6FD8)
    static let blueText = Color(hex: 0x145ED6)
    static let tint = Color(hex: 0xE9F1FD)
    static let red = Color(hex: 0xC2412D)
    static let redTint = Color(hex: 0xFDEEEA)
    static let act = Color(hex: 0xC9D6EE)
    static let done = Color(hex: 0x96ACD6)
    static let dash = Color(hex: 0xC4C4BE)
    static let edge = Color(hex: 0xECEBE6)
    static let field = Color(hex: 0xDED7CC)
    static let axis: CGFloat = 68
}

/// `.pd-btn`（Figma 07 页 macOS / Button / Prominent）：36 高胶囊，13.5 中黑；
/// 一页只有一个墨黑实心主按钮，其余白底细边，没通过是红字。
struct PDButtonStyle: ButtonStyle {
    enum Kind { case normal, primary, reject }
    var kind: Kind = .normal
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(13.5, weight: .medium)).lineLimit(1).fixedSize()
            .padding(.horizontal, 20).frame(height: 36)
            .foregroundStyle(kind == .primary ? .white : kind == .reject ? PD.red : PD.ink)
            .background(kind == .primary ? (configuration.isPressed ? Color(hex: 0x2F2F2C) : PD.ink) : (configuration.isPressed ? Color(hex: 0xF4F4F2) : .white), in: Capsule())
            .overlay(Capsule().stroke(kind == .primary ? PD.ink : kind == .reject ? Color(hex: 0xEFD2CC) : Color(hex: 0xE4E4E0)))
            .opacity(enabled ? 1 : 0.55)
            .contentShape(Capsule())
    }
}
