import SwiftUI

// 一级页面骨架（Web `v3/skeletons.tsx` / `skeletons.css`）：侧栏一级页面首次加载、还没有任何数据时，
// 按真实页面的版式画灰色占位块；页头里的静态文字和按钮照常显示，只有要等数据的地方画灰块。
// 二级页面（详情、报告、编辑器等）仍用 `V3Loading`（Web `PageLoader`）。占位块本身是 `V3Skeleton`（`.v3-sk`）。

/// 行内文字占位（Web `LoadingText` / `.ui-loading-text`）：高 0.8em、圆角 3、#ECECEA 底 + 同一道扫光。
struct V3LoadingText: View {
    let width: CGFloat
    /// 所在文字的字号，占位高取 0.8 倍。
    var size: CGFloat = 13
    var body: some View { V3Skeleton(width: width, height: (size * 0.8).rounded(), radius: 3) }
}

/// 按所在容器宽度的百分比画一条占位（Web `<Sk w="58%" />`）。
struct V3SkeletonLine: View {
    let fraction: CGFloat
    var height: CGFloat = 12
    var radius: CGFloat = 4
    var color: Color = V3Skeleton.fill
    var body: some View {
        GeometryReader { box in V3Skeleton(width: box.size.width * fraction, height: height, radius: radius, color: color) }
            .frame(height: height)
    }
}

extension View {
    /// 骨架比可视区长时向下渐隐，暗示“后面还有”（Web 各骨架的 `mask-image: linear-gradient(to bottom, #000 N%, transparent)`）。
    func v3SkeletonFade(_ solid: CGFloat) -> some View {
        mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: solid), .init(color: .clear, location: 1)],
                            startPoint: .top, endPoint: .bottom))
    }
}

/// 简历模板网格骨架（Web `SkeletonGrid`）：每张卡与真实模板卡同尺寸——A4 纸面（纸上几道细灰条示意姓名、联系方式与分节）
/// + 名称行（上 14）+ 标签行（上 4、高 20：两个标签 + 右侧使用次数）。纸面沿用 Mac 模板卡的白纸、圆角 10 与轻阴影。
struct V3SkeletonTemplateGrid: View {
    var count = 8
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 20, alignment: .top)], alignment: .leading, spacing: 32) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 0) {
                    V3SkeletonTemplatePaper().shadow(color: .black.opacity(0.07), radius: 6, y: 2)
                    V3SkeletonLine(fraction: 0.58, height: 12, radius: 3).frame(height: 16).padding(.top, 14)
                    HStack(spacing: 6) {
                        V3Skeleton(width: 40, height: 22, radius: 5)
                        V3Skeleton(width: 40, height: 22, radius: 5)
                        Spacer(minLength: 0)
                        V3Skeleton(width: 44, height: 10, radius: 3)
                    }.frame(height: 20).padding(.top, 4)
                }
            }
        }
        .v3SkeletonFade(0.7)
        .accessibilityElement(children: .ignore).accessibilityLabel("正在加载简历模板…")
    }
}

/// 模板卡里的纸面（Web `SkeletonTemplatePaper`）：尺寸按卡宽百分比（cqw）缩放，纸上的灰条用 #F0F0EE。
private struct V3SkeletonTemplatePaper: View {
    private static let sections: [[CGFloat]] = [[84, 78, 64], [84, 72], [80, 84, 58], [84, 70]]
    private static let ink = Color(hex: 0xF0F0EE)
    var body: some View {
        GeometryReader { box in
            let q = box.size.width / 100
            VStack(alignment: .leading, spacing: 0) {
                V3Skeleton(width: 36 * q, height: 4.6 * q, radius: 2, color: Self.ink)
                V3Skeleton(width: 58 * q, height: 2.2 * q, radius: 2, color: Self.ink).padding(.top, 3.4 * q)
                ForEach(Array(Self.sections.enumerated()), id: \.offset) { _, lines in
                    VStack(alignment: .leading, spacing: 0) {
                        V3Skeleton(width: 22 * q, height: 2.8 * q, radius: 2, color: Self.ink)
                        ForEach(Array(lines.enumerated()), id: \.offset) { line, width in
                            V3Skeleton(width: width * q, height: 2 * q, radius: 2, color: Self.ink).padding(.top, (line > 0 ? 2.4 : 3.2) * q)
                        }
                    }.padding(.top, 8 * q)
                }
            }
            .padding(.top, 10 * q).padding(.horizontal, 9 * q)
            .frame(width: box.size.width, height: box.size.height, alignment: .topLeading)
        }
        .aspectRatio(210.0 / 297, contentMode: .fit)
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// 投递看板骨架（Web `SkeletonBoard`）：列宽与真实阶段列相同（容器宽减 40 后五等分，夹在 220–280），
/// 预留十列、超出裁掉；每列 #F7F7F5 圆角 10，列头一条 64×11，下面 88 高的白卡（1px #EBEBE7 内描边、圆角 8）。
struct V3SkeletonBoard: View {
    private static let counts = [3, 2, 2, 1, 2, 3, 2, 2, 1, 2]
    var label = "正在加载求职数据…"
    var body: some View {
        GeometryReader { box in
            let width = min(280, max(220, (box.size.width - 40) / 5))
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(Self.counts.enumerated()), id: \.offset) { _, count in
                    VStack(alignment: .leading, spacing: 0) {
                        V3Skeleton(width: 64, height: 11).padding(.top, 14).padding(.horizontal, 6).padding(.bottom, 16)
                        ForEach(0..<count, id: \.self) { _ in
                            V3Skeleton(height: 88, radius: 8, color: .white)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0xEBEBE7)))
                                .padding(.bottom, 8)
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                    .frame(width: width, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
                    .background(Color(hex: 0xF7F7F5), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(width: box.size.width, height: box.size.height, alignment: .topLeading).clipped()
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

/// 日历骨架（Web `SkeletonCalendar bar={false}`）：7 列 × 5 行格子，行高至少 88、平分剩余高度；
/// 每格左上一条日期占位，隔几格有一条日程占位；格线 #ECECEA。
struct V3SkeletonCalendar: View {
    var label = "正在加载日程…"
    var body: some View {
        GeometryReader { box in
            let row = max(88, box.size.height / 5)
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { line in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { column in
                            VStack(alignment: .leading, spacing: 0) {
                                V3Skeleton(width: 16, height: 10)
                                if (line * 7 + column) % 5 == 1 { V3SkeletonLine(fraction: 0.8, height: 14, radius: 4).padding(.top, 10) }
                            }
                            .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .overlay(alignment: .trailing) { Rectangle().fill(V3.line).frame(width: 1) }
                            .overlay(alignment: .bottom) { Rectangle().fill(V3.line).frame(height: 1) }
                        }
                    }.frame(height: row)
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
            .overlay(alignment: .leading) { Rectangle().fill(V3.line).frame(width: 1) }
            .frame(width: box.size.width, height: box.size.height, alignment: .top).clipped()
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

/// 模拟面试首页骨架（Web `SkeletonMockHome`）：顶栏（左投递切换、右导入与全部记录）+ 居中的题目区
/// （眉题、两行题目、说明、声波、两个按钮、设置行）+ 底部长期记忆行；左右留白与真实首页相同。
struct V3SkeletonMockHome: View {
    var label = "正在加载模拟面试…"
    var body: some View {
        GeometryReader { box in
            let side = max(80, (box.size.width - 991) / 2)
            VStack(spacing: 0) {
                HStack(spacing: 24) {
                    V3Skeleton(width: 168, height: 13)
                    Spacer(minLength: 0)
                    HStack(spacing: 28) { V3Skeleton(width: 78, height: 12); V3Skeleton(width: 92, height: 12) }
                }.frame(height: 24).padding(.top, 38)
                VStack(spacing: 0) {
                    V3Skeleton(width: 150, height: 12).frame(height: 20)
                    V3Skeleton(width: 520, height: 28, radius: 6).frame(height: 44).padding(.top, 14)
                    V3Skeleton(width: 360, height: 28, radius: 6).frame(height: 44).padding(.top, 2)
                    V3Skeleton(width: 380, height: 12).frame(height: 20).padding(.top, 14)
                    V3Skeleton(width: 440, height: 36, radius: 8, color: V3.field).padding(.top, 28)
                    HStack(spacing: 12) { V3Skeleton(width: 175, height: 44, radius: 22); V3Skeleton(width: 156, height: 44, radius: 22) }.padding(.top, 28)
                    V3Skeleton(width: 280, height: 11).frame(height: 18).padding(.top, 16)
                }
                .padding(.top, 40).padding(.bottom, 110)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 28) {
                    V3Skeleton(width: 56, height: 12); V3Skeleton(width: 150, height: 12); V3Skeleton(width: 140, height: 12); V3Skeleton(width: 120, height: 12)
                    Spacer(minLength: 0)
                    V3Skeleton(width: 72, height: 12)
                }
                .padding(.top, 22).padding(.bottom, 46)
                .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
            }
            .padding(.horizontal, side)
            .frame(width: box.size.width, height: box.size.height)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

/// 列表行骨架（Web `SkeletonRows header={false}`）：1px #E4E4E0 圆角 14 的框，行高 56、左右 18；
/// 每行 32 方块 + 两行文字 + 两列短值，行间 #ECECEA 细线，越往下越淡。
struct V3SkeletonRows: View {
    var rows = 4
    var label = "正在加载…"
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { index in
                HStack(spacing: 14) {
                    V3Skeleton(width: 32, height: 32, radius: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        V3SkeletonLine(fraction: (58 - CGFloat(index % 3) * 9) / 100, height: 13)
                        V3SkeletonLine(fraction: 0.32, height: 10).padding(.top, 7)
                    }.frame(maxWidth: .infinity)
                    V3Skeleton(width: 72, height: 11).frame(width: 96, alignment: .leading)
                    V3Skeleton(width: 56, height: 11).frame(width: 72, alignment: .leading)
                }
                .padding(.horizontal, 18).frame(height: 56)
                .overlay(alignment: .top) { if index > 0 { Rectangle().fill(V3.line).frame(height: 1) } }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(V3.cl))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .v3SkeletonFade(0.55)
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}
