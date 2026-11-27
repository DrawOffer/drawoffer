import Foundation
import Testing
@testable import DrawOfferCore

// 首页（Web feedback.css）随窗口伸缩：窗口 = Web 视口，容器 = 窗口减去侧栏 241（Figma 02A·01.04 214:9800）
private func layout(_ width: Double, _ height: Double, sidebar: Double = 241) -> HomeFeedbackLayout {
    HomeFeedbackLayout(window: CGSize(width: width, height: height), container: CGSize(width: width - sidebar, height: height))
}

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) < tolerance }

@Test func homeLayoutMatchesFigmaDefaultWindow() {
    // Figma 窗口 1392 × 976：左栏文字 x = 241 + 56 + 26，入口三列间距 361
    let l = layout(1392, 976)
    #expect(l.scale == 1)
    #expect(l.padX == 56)
    #expect(near(l.innerWidth, 1039))
    #expect(near(l.rightWidth, 999 * 1.2 / 2.2))
    #expect(l.columnGap == 44 && l.rowGap == 18 && l.rowTop == 26)
    #expect(near((l.innerWidth - 2 * l.columnGap) / 3 + l.columnGap, 361))
    #expect(l.rowColumns == 3 && l.showMore && !l.narrow)
}

@Test func homeLayoutAt1440x932() {
    let l = layout(1440, 932)
    #expect(l.scale == 1)
    #expect(near(l.padTop, 37.28) && l.padX == 56 && near(l.padBottom, 32.62))
    #expect(near(l.innerWidth, 1087))
    #expect(near(l.leftWidth, 1047 / 2.2) && near(l.rightWidth, 1047 * 1.2 / 2.2))
    #expect(near(l.title, 38.88))
    #expect(l.rowGap == 18 && l.columnGap == 44 && l.rowTop == 26)
}

@Test func homeLayoutAt1690x1040ScalesSlightly() {
    // min(1690 / 1600, 1040 / 1000) = 1.04；放大前视口 1625 × 1000，内容区到 1160 封顶
    let l = layout(1690, 1040)
    #expect(near(l.scale, 1.04))
    #expect(near(l.padTop, 41.6) && near(l.padX, 58.24) && near(l.padBottom, 36.4))
    #expect(near(l.innerWidth, 1160 * 1.04))
    #expect(near(l.title, 41.6))
    #expect(near(l.rowGap, 18.72) && near(l.columnGap, 45.76) && near(l.rowTop, 27.04))
}

@Test func homeLayoutAt2000x1260GrowsWithWindow() {
    // min(2000 / 1600, 1260 / 1000) = 1.25：整页按 1600 × 1008 排版后放大
    let l = layout(2000, 1260)
    #expect(l.scale == 1.25)
    #expect(near(l.padTop, 40.32 * 1.25) && l.padX == 70 && near(l.padBottom, 35.28 * 1.25))
    #expect(l.innerWidth == 1450)
    #expect(near(l.leftWidth, 1120 / 2.2 * 1.25) && near(l.rightWidth, 1120 * 1.2 / 2.2 * 1.25))
    #expect(l.title == 50)
    #expect(near(l.rowGap, 22.5) && l.columnGap == 55 && near(l.rowTop, 32.5))
    // 放大封顶 1.5
    #expect(HomeFeedbackLayout.appScale(width: 4000, height: 3000) == 1.5)
}

@Test func homeLayoutNarrowAt960() {
    let l = layout(960, 700, sidebar: 0)
    #expect(l.narrow && l.scale == 1)
    #expect(l.padTop == 24 && l.padX == 20 && l.padBottom == 24)
    #expect(l.innerWidth == 920 && l.leftWidth == 920 && l.rightWidth == 920)
    #expect(l.rowColumns == 2 && !l.showMore)
    #expect(l.title == 26)
}

@Test func homeLayoutHidesStripMoreAt1100() {
    #expect(!layout(1100, 800).showMore)
    #expect(layout(1101, 800).showMore)
}

@Test func homeGraphFitScalesUniformlyWithSlot() {
    // kc = min(宽 / 630, 高 / 540)；节点坐标按 760 × 520 设计稿展开
    let small = CGSize(width: 545, height: 560), big = CGSize(width: 763.6, height: 900)
    #expect(near(HomeGraphFit.kc(small), 545 / 630.0))
    #expect(near(HomeGraphFit.kc(big), 763.6 / 630.0))
    let p = HomeGraphFit.point(x: 0.37, y: -0.43, in: small)
    #expect(near(p.x, 272.5 + 0.37 * 760 * 545 / 630))
    #expect(near(p.y, 280 - 0.43 * 520 * 545 / 630))
    // 区域变大，间距等比变大，不再横竖各自拉
    let q = HomeGraphFit.point(x: 0.37, y: 0, in: big)
    #expect(near((q.x - big.width / 2) / (p.x - small.width / 2), 763.6 / 545))
}

@Test func homeGraphStretchFollowsList() {
    let size = CGSize(width: 630, height: 540)
    // 只按区域：540 / 560 ≈ 0.964
    #expect(near(HomeGraphFit.stretch(size: size, top: -0.43, bottom: 0.43, topHalf: 14, bottomHalf: 12, list: nil), 540 / 560.0))
    // 列表矮：拉伸下限 0.8
    #expect(HomeGraphFit.stretch(size: size, top: -0.43, bottom: 0.43, topHalf: 14, bottomHalf: 12, list: 200) == 0.8)
    // 列表 420：(420 − 17 − 26) / (0.86 × 520) ≈ 0.843
    #expect(near(HomeGraphFit.stretch(size: size, top: -0.43, bottom: 0.43, topHalf: 14, bottomHalf: 12, list: 420), 377 / (0.86 * 520)))
    // 列表顶对齐最高节点的上沿
    let edge = HomeGraphFit.topEdge(size: size, spots: [(y: -0.43, half: 14), (y: 0.2, half: 12)], stretch: 1)
    #expect(edge.map { near($0, 270 - 0.43 * 520 - 14) } == true)
}
