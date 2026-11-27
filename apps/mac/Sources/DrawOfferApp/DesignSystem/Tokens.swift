import SwiftUI

/// 设计 Token，数值取自 apps/web/src/design-system/tokens.css，名字与 `--ui-*` 对应。
/// 只映射仍在用的「品牌」值；控件本身用系统原生外观，不去模仿网页控件。
enum Tokens {
    enum Color {
        static let stage = SwiftUI.Color(hex: 0xF3F2EF)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension Color {
    /// CSS `color-mix(in srgb, self (1 - amount), other amount)`。
    func mix(with other: Color, by amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black, b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        let t = min(1, max(0, amount))
        return Color(.sRGB, red: a.redComponent * (1 - t) + b.redComponent * t, green: a.greenComponent * (1 - t) + b.greenComponent * t,
                     blue: a.blueComponent * (1 - t) + b.blueComponent * t)
    }
}
