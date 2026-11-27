import Foundation

/// 工作区日常首页（Figma 02A·01.04，Web `assistant/home/FeedbackHome.tsx` + `feedback.css`）随窗口伸缩的尺寸。
///
/// Web 的 `vw` / `vh` 是浏览器视口，对应 Mac 的窗口内容区（不是屏幕）；页面自己的宽高是首页容器。
/// 窗口到 1600 × 1000 以上时 Web 把整个工作区按 `appScaleOf` 等比放大（`v3/appScale.ts`），
/// 这里先按“放大前”的视口和容器套 CSS 规则，再把所有长度乘回放大倍数，得到实际点数。
public struct HomeFeedbackLayout: Equatable, Sendable {
    /// 放大倍数（Web `appScaleOf`）：1 … 1.5；字号、图标等固定尺寸也乘它
    public let scale: Double
    /// `.hf-page` 的 padding：clamp(24px, 4vh, 48px) clamp(28px, 4.6vw, 56px) clamp(24px, 3.5vh, 44px)
    public let padTop: Double
    public let padX: Double
    public let padBottom: Double
    /// `.hf-inner`：max-width 1160，居中
    public let innerWidth: Double
    /// `@media (max-width: 980px)`：单栏，入口两列，页面改为可滚动
    public let narrow: Bool
    /// `.hf-hero`：minmax(0, 1fr) minmax(0, 1.2fr)，gap 40；单栏时两栏都是整宽
    public let heroGap: Double
    public let leftWidth: Double
    public let rightWidth: Double
    /// `.hf-title`：clamp(26px, 2.7vw, 40px)
    public let title: Double
    /// `.hf-row`：三列（≤980 两列），gap clamp(12px, 2vh, 18px) clamp(24px, 3.4vw, 44px)，margin-top clamp(14px, 3vh, 26px)
    public let rowColumns: Int
    public let rowGap: Double
    public let columnGap: Double
    public let rowTop: Double
    /// `@media (max-width: 1100px) { .hf-strip-more { display: none } }`：入口第二行的补充（“，共 2 场”）收起
    public let showMore: Bool
    /// `.hf-pending` 左右 padding：clamp(0px, 3vw, 40px)
    public let pendingPad: Double

    public static let maxInner = 1160.0
    public static let appScaleMax = 1.5

    /// Web `appScaleOf(width, height)`：min(1.5, max(1, min(宽 / 1600, 高 / 1000)))
    public static func appScale(width: Double, height: Double) -> Double {
        min(appScaleMax, max(1, min(width / 1600, height / 1000)))
    }

    static func clamp(_ low: Double, _ value: Double, _ high: Double) -> Double { min(high, max(low, value)) }

    /// - Parameters:
    ///   - window: 窗口内容区（Web 视口）
    ///   - container: 首页容器（侧栏右边那一块）
    public init(window: CGSize, container: CGSize) {
        let s = Self.appScale(width: window.width, height: window.height)
        // 放大前的视口与容器（CSS 像素）
        let vw = window.width / s, vh = window.height / s, cw = container.width / s
        narrow = vw <= 980
        let top = narrow ? 24 : Self.clamp(24, vh * 0.04, 48)
        let side = narrow ? 20 : Self.clamp(28, vw * 0.046, 56)
        let bottom = narrow ? 24 : Self.clamp(24, vh * 0.035, 44)
        let inner = max(0, min(Self.maxInner, cw - side * 2))
        let gap = 40.0
        let left = narrow ? inner : max(0, inner - gap) / 2.2
        let right = narrow ? inner : max(0, inner - gap) * 1.2 / 2.2
        scale = s
        padTop = top * s; padX = side * s; padBottom = bottom * s
        innerWidth = inner * s
        heroGap = gap * s
        leftWidth = left * s; rightWidth = right * s
        title = Self.clamp(26, vw * 0.027, 40) * s
        rowColumns = narrow ? 2 : 3
        rowGap = Self.clamp(12, vh * 0.02, 18) * s
        columnGap = Self.clamp(24, vw * 0.034, 44) * s
        rowTop = Self.clamp(14, vh * 0.03, 26) * s
        showMore = vw > 1100
        pendingPad = Self.clamp(0, vw * 0.03, 40) * s
    }
}

/// 首页小图的摆法（Web `feedbackStage.ts` 收起态）：坐标按 760 × 520 的设计稿展开，
/// 再按图谱区域等比缩放 kc = min(宽 / 630, 高 / 540)，居中；字号不随 kc 变（只随放大倍数变）。
/// 左边最近进展的列表和图上最高、最低的节点对齐：图在竖直方向再拉伸 0.8 … 1.32 倍，列表顶上补出到最高节点的距离。
public enum HomeGraphFit {
    public static let design = (width: 760.0, height: 520.0)
    public static let home = (width: 630.0, height: 540.0)

    /// kc：区域放大或缩小，节点间距跟着等比变
    public static func kc(_ size: CGSize) -> Double {
        guard size.width > 0, size.height > 0 else { return 0 }
        return min(size.width / home.width, size.height / home.height)
    }

    /// 节点中心（区域内坐标）：spot 是 `HomeGraphStage.home` 里的 -0.37…0.37 × -0.43…0.43
    public static func point(x: Double, y: Double, in size: CGSize, stretch: Double = 1) -> CGPoint {
        let k = kc(size)
        return CGPoint(x: size.width / 2 + x * design.width * k, y: size.height / 2 + y * design.height * k * stretch)
    }

    /// 竖直拉伸（Web `stretch`）：max(0.8, min(1.32, H / (560·kc), (列表高 − 17 − 顶点半高 − 底点半高) / (纵跨 · kc)))。
    /// 列表高未知时只按区域高度算。长度都是实际点数，`scale` 是放大倍数（17 这样的常数要跟着乘）。
    public static func stretch(size: CGSize, top: Double, bottom: Double, topHalf: Double, bottomHalf: Double, list: Double?, scale: Double = 1) -> Double {
        let k = kc(size)
        guard k > 0 else { return 1 }
        var fit = size.height / (560 * k)
        if let list {
            let span = max(1, (bottom - top) * design.height)
            fit = min(fit, (list - 17 * scale - topHalf - bottomHalf) / (span * k))
        }
        return max(0.8, min(1.32, fit))
    }

    /// 最高那个节点标签的上沿（区域内 y）：列表顶上补这么多再减 3（Web `paddingTop = 区域顶 − 首屏顶 + a − 3`）
    public static func topEdge(size: CGSize, spots: [(y: Double, half: Double)], stretch: Double) -> Double? {
        guard !spots.isEmpty else { return nil }
        return spots.map { point(x: 0, y: $0.y, in: size, stretch: stretch).y - $0.half }.min()
    }
}
