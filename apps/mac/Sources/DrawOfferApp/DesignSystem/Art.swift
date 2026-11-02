import SwiftUI

// 插图积木（Web `v3/art.tsx`）：坐标照设计稿，放在 `V3DotStage` 里。

struct ArtBox<Content: View>: View {
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View { content().frame(width: w, height: h).offset(x: x, y: y) }
}

struct ArtBar: View {
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    var r: CGFloat = 1
    var color: Color = V3.line
    var body: some View { RoundedRectangle(cornerRadius: r).fill(color).frame(width: w, height: h).offset(x: x, y: y) }
}

struct ArtPaper<Content: View>: View {
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    var r: CGFloat = 8
    var shadow = true
    var fill: Color = .white
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack(alignment: .topLeading) { content() }
            .frame(width: w, height: h, alignment: .topLeading)
            .background(fill).clipShape(RoundedRectangle(cornerRadius: r))
            .overlay(RoundedRectangle(cornerRadius: r).stroke(V3.cl))
            .shadow(color: .black.opacity(shadow ? 0.06 : 0), radius: 8, y: 6)
            .offset(x: x, y: y)
    }
}

struct ArtBadge: View {
    let x: CGFloat, y: CGFloat
    var size: CGFloat = 22
    var symbol = "xmark"
    var fill: Color = V3.txt
    var color: Color = .white
    var border: Color?
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(color)
            .frame(width: size, height: size).background(fill, in: Circle())
            .overlay(Circle().stroke(border ?? .clear))
            .shadow(color: .black.opacity(0.1), radius: 3, y: 2).offset(x: x, y: y)
    }
}

