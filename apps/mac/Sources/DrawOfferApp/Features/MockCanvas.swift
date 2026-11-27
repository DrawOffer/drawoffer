import Foundation
import DrawOfferCore
import SwiftUI

/// 模拟面试的画布（Web `v2/DesignStage.tsx`）：面试设置、面试中各页按设计稿坐标排版，外层 `MockStage` 整体等比缩放。
enum MI {
    static let ink = Color(hex: 0x1D1D1B)
}

/// 按设计尺寸排版、整体等比缩放并居中（Web `DesignStage`）。
struct MockStage<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / width, geometry.size.height / height, 1) // 只缩不放，放大会把字拉糊
            content().frame(width: width, height: height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .center)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(.white)
    }
}

extension View {
    /// 把视图钉在设计坐标上：`x` 是左边、中心或右边（按 `align`），`top` 是行框顶。
    func pin(_ x: CGFloat, _ top: CGFloat, align: HorizontalAlignment = .leading) -> some View {
        fixedSize()
            .frame(width: 0, alignment: Alignment(horizontal: align == .center ? .center : align == .trailing ? .trailing : .leading, vertical: .top))
            .offset(x: x, y: top)
    }
}
