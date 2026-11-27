import AppKit
import SwiftUI

/// Web `v3/v3.css` page tokens and base controls shared by the board, schedule, library and mock pages.
enum V3 {
    static let txt = Color(hex: 0x1D1D1B)
    static let sub = Color(hex: 0x55554F)
    static let fnt = Color(hex: 0x6C6C65)
    static let fnt2 = Color(hex: 0xC4C4BE)
    static let line = Color(hex: 0xECECEA)
    static let cl = Color(hex: 0xE4E4E0)
    static let field = Color(hex: 0xF4F4F2)
    static let hl = Color(hex: 0xE6E6E2)
    static let stage = Color(hex: 0xF4F4F1)
    static let column = Color(hex: 0xF7F7F5)
    static let sk2 = Color(hex: 0xDCDCD8)
    static let blue = Color(hex: 0x3F6FD8)
    static let link = Color(hex: 0x2E53AA)
    static let blueSoft = Color(hex: 0xEAF0FB)
    static let orange = Color(hex: 0xD9822B)
    static let orangeSoft = Color(hex: 0xFBF1E6)
    static let green = Color(hex: 0x3B9A5B)
    static let greenSoft = Color(hex: 0xEEF6F0)
    static let red = Color(hex: 0xD64545)
    static let redSoft = Color(hex: 0xFBF2F2)
    static let purple = Color(hex: 0x8A5CC7)

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { LibraryTypography.sans(size, weight: weight) }
    static func serif(_ size: CGFloat) -> Font { LibraryTypography.serif(size) }
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .default).monospacedDigit() }
}

/// `.career-v3-head`: eyebrow, serif page title, subtitle and right-aligned actions (31px from the top).
/// `compact` 是「我的简历」的 `.hv3-head`：标题距眉题 9、说明 13px / 16 行高距标题 6、按钮距顶 32。
struct V3PageHead<Actions: View>: View {
    let eyebrow: [String]
    let title: String
    var subtitle: String? = nil
    var compact = false
    /// 求职页 `CareerPageHead` 的副标题行高 20（简历页为文字自然高度）。
    var subtitleHeight: CGFloat? = nil
    /// 副标题还在等数据：同一行画这么宽的文字占位（Web `<Reveal inline placeholder={<LoadingText width />}>`）。
    var subtitleLoading: CGFloat? = nil
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                Text(eyebrow.joined(separator: " · ")).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.fnt).frame(height: 18)
                Text(title).font(V3.serif(28)).foregroundStyle(V3.txt).frame(height: 36).padding(.top, compact ? 9 : 8)
                if let subtitleLoading {
                    V3LoadingText(width: subtitleLoading, size: compact ? 13 : 14)
                        .frame(height: compact ? 16 : subtitleHeight ?? 20, alignment: .leading).padding(.top, 6)
                } else if let subtitle {
                    Text(subtitle).font(V3.sans(compact ? 13 : 14)).foregroundStyle(V3.sub).lineLimit(1)
                        .frame(height: compact ? 16 : subtitleHeight).padding(.top, compact ? 6 : 6)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: compact ? 8 : 10) { actions() }.padding(.top, compact ? 32 : 31)
        }
    }
}

/// macOS 稿（Figma 00 页 Button/Prominent · Bordered）：圆角 6 的原生按钮尺寸，常规高 28、大号高 32；
/// 配色保留品牌——主按钮墨黑、次按钮白底 10% 黑描边。一页只有一个墨黑主按钮。
struct V3ButtonStyle: ButtonStyle {
    enum Kind { case dark, ghost, text, danger }
    var kind: Kind = .ghost
    var height: CGFloat = 32
    var width: CGFloat? = nil
    /// `.v3-btn.is-sm`：12px 字。
    var small = false
    /// 撑满可用宽度（居中确认的两个按钮）。
    var fill = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let large = height >= 36
        let shape = RoundedRectangle(cornerRadius: 6)
        return HStack(spacing: 6) { configuration.label }
            .font(V3.sans(kind == .text ? 13 : small ? 12 : 13, weight: .medium)).lineLimit(1).fixedSize(horizontal: !fill, vertical: false)
            .frame(maxWidth: fill ? .infinity : nil)
            .foregroundStyle(kind == .dark || kind == .danger ? Color.white : kind == .text ? (pressed ? V3.txt : V3.sub) : V3.txt)
            .padding(.horizontal, kind == .text ? 0 : large ? 14 : 12)
            .frame(width: width, height: kind == .text ? nil : large ? 32 : 28)
            .background {
                switch kind {
                case .dark: shape.fill(pressed ? Color(hex: 0x0E0E0D) : V3.txt)
                case .danger: shape.fill(pressed ? Color(hex: 0xC33B3B) : V3.red)
                case .ghost: shape.fill(pressed ? V3.field : .white).overlay(shape.stroke(.black.opacity(0.1)))
                        .shadow(color: .black.opacity(0.05), radius: 0.5, y: 0.5)
                case .text: Color.clear
                }
            }
            .opacity(enabled ? 1 : 0.38)
            .contentShape(shape)
    }
}

/// macOS 稿 SearchField（NSSearchField 观感）：5% 黑底、圆角 7、28 高，聚焦时 accent 聚焦环。
struct V3SearchField: View {
    @Binding var text: String
    var placeholder: String
    var width: CGFloat? = 180
    var height: CGFloat = 28
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(V3.fnt)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(V3.fnt)).textFieldStyle(.plain)
                .font(V3.sans(13)).foregroundStyle(V3.txt).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(V3.fnt2) }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 8).frame(width: width, height: min(height, 28))
        .background(focused ? Color.white : Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 3).padding(-1.5))
    }
}

/// 分段控件：直接用原生 NSSegmentedControl（SwiftUI `.pickerStyle(.segmented)`）。
/// `segmentWidth` / `height` / `fontSize` 保留给旧调用，原生控件按系统尺寸绘制。
struct V3Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var segmentWidth: CGFloat? = nil
    var height: CGFloat = 30
    var fontSize: CGFloat = 14
    /// 与 Web `.v3-seg` / 稿一致：浅灰底槽，选中项白底细阴影、墨色字；不用系统分段控件的蓝色选中态。
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1).font(V3.sans(min(fontSize, 13), weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? V3.txt : V3.sub).lineLimit(1).fixedSize()
                        .padding(.horizontal, segmentWidth == nil ? 14 : 0)
                        .frame(width: segmentWidth).frame(height: height - 6)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6).fill(.white).shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3).frame(height: height)
        .background(Color(hex: 0xF0F0EE), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }
}

/// macOS 稿 ScopeButton（Finder 搜索范围栏 / `.accessoryBar` 观感）：筛选标签无描边，选中 10% 黑底。
struct V3ScopeButton: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(label).font(V3.sans(12, weight: selected ? .medium : .regular)).lineLimit(1).fixedSize()
                .foregroundStyle(selected || hover ? V3.txt : V3.sub)
                .padding(.horizontal, 10).frame(height: 24)
                .background(selected ? Color.black.opacity(0.1) : hover ? Color.black.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }.accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// `.v3-chip`.
struct V3Chip: View {
    let label: String
    var foreground: Color = V3.sub
    var background: Color = V3.field
    var height: CGFloat = 22
    var size: CGFloat = 12
    var body: some View {
        Text(label).font(V3.sans(size, weight: .medium)).lineLimit(1).fixedSize()
            .foregroundStyle(foreground).padding(.horizontal, 7).frame(height: height)
            .background(background, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// `.v3-stage.has-dots`: the dotted art stage used by empty states and dialogs.
struct V3DotStage<Content: View>: View {
    /// `nil` fills the proposed height.
    var height: CGFloat? = 200
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack {
            Canvas { context, size in
                for x in stride(from: 5.0, through: size.width, by: 14) {
                    for y in stride(from: 5.0, through: size.height, by: 14) {
                        context.fill(Path(ellipseIn: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)), with: .color(Color(hex: 0xD6D6D1)))
                    }
                }
            }
            content()
        }
        .frame(maxWidth: .infinity).frame(height: height)
        .background(V3.stage).clipShape(RoundedRectangle(cornerRadius: 11))
    }
}

/// `.v3-empty`: a 520pt card with art, a serif heading, body copy and actions.
struct V3EmptyCard<Art: View, Actions: View>: View {
    let title: String
    let message: String
    var stageHeight: CGFloat = 200
    /// 各页覆盖：卡宽、内边距（含 1px 边框）、说明与按钮行的上距。
    var width: CGFloat = 520
    var inset: CGFloat = 8
    var messageTop: CGFloat = 10
    var actionsTop: CGFloat = 26
    @ViewBuilder var art: () -> Art
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            V3DotStage(height: stageHeight, content: art)
            Text(title).font(V3.serif(18)).foregroundStyle(V3.txt).frame(height: 26).padding(.horizontal, 24).padding(.top, 22)
            Text(message).font(V3.sans(13)).foregroundStyle(V3.sub).lineHeight(13, 22).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24).padding(.top, messageTop)
            HStack(spacing: 20) { actions() }.padding(.horizontal, 24).padding(.top, actionsTop)
        }
        .padding(.horizontal, inset).padding(.top, inset).padding(.bottom, 30)
        .frame(maxWidth: width)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(V3.cl))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

extension View {
    /// CSS `line-height`：多行时补行距，首行上下各补一半，使单行高度与 Web 相同。
    /// 自然行高按字体算：`V3.sans` 是系统字体（SF / 苹方），约 1.2 em；`V3.serif` 约 1.437 em。按错的字体减会让每行差几个点（15/28 的正文实际只有 25）。
    func lineHeight(_ size: CGFloat, _ height: CGFloat, _ face: LineFace = .sans) -> some View {
        let extra = max(0, height - size * face.natural)
        return lineSpacing(extra).padding(.vertical, extra / 2)
    }
}

/// `lineHeight` 用来算自然行高的字体。
enum LineFace {
    case sans, serif, system
    var natural: CGFloat {
        switch self {
        case .sans: 1.2
        case .serif: 1.437
        case .system: 1.2
        }
    }
}

/// `.v3-page`：内容卡里的页面容器。最大宽度随内容卡宽度分档（<1180 为 860、≥1180 为 1100、≥1800 为 1400），
/// 左右留白取 `max(24, 3% 卡宽)` 与居中余量中较大者，上 52、下 60，与 Web 的容器查询一致。
struct V3Page<Content: View>: View {
    var top: CGFloat = 52
    var bottom: CGFloat = 60
    @ViewBuilder var content: () -> Content

    static func maxWidth(card: CGFloat) -> CGFloat { card >= 1800 ? 1400 : card >= 1180 ? 1100 : 860 }
    static func gutter(card: CGFloat) -> CGFloat { max(max(24, card * 0.03), (card - maxWidth(card: card)) / 2) }

    var body: some View {
        GeometryReader { geometry in
            let card = geometry.size.width, gutter = Self.gutter(card: card)
            ScrollView {
                content().frame(width: max(0, card - gutter * 2), alignment: .leading)
                    .padding(.horizontal, gutter).padding(.top, top).padding(.bottom, bottom)
            }
        }
    }
}

/// Web `components/ui/pagination.tsx`：左侧「共 N 条 · 每页 M 条」，右侧上一页、页码（超过 7 页时首尾与前后一页，中间省略）、下一页。
struct V3Pagination: View {
    let page: Int
    let total: Int
    var pageSize = 20
    var loading = false
    let change: (Int) -> Void

    static func numbers(_ current: Int, _ total: Int) -> [Int?] {
        if total <= 7 { return Array(1...max(1, total)).map { $0 } }
        let pages = Set([1, current - 1, current, current + 1, total]).filter { $0 > 0 && $0 <= total }.sorted()
        var out: [Int?] = []
        for (index, value) in pages.enumerated() {
            if index > 0 && value - pages[index - 1] > 1 { out.append(nil) }
            out.append(value)
        }
        return out
    }

    var body: some View {
        let count = max(1, (total + pageSize - 1) / pageSize)
        HStack(spacing: 12) {
            Text("共 \(total) 条 · 每页 \(pageSize) 条")
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                cell("上一页", enabled: page > 1) { change(page - 1) }
                ForEach(Array(Self.numbers(page, count).enumerated()), id: \.offset) { _, value in
                    if let value {
                        cell("\(value)", current: value == page, enabled: true) { change(value) }.accessibilityLabel("第 \(value) 页")
                    } else { Text("…") }
                }
                cell("下一页", enabled: page < count) { change(page + 1) }
            }
        }.font(.system(size: 12)).foregroundStyle(V3.sub).padding(.vertical, 20)
    }

    private func cell(_ title: String, current: Bool = false, enabled: Bool, action: @escaping () -> Void) -> some View {
        // macOS 稿 Pagination：无边框页码，当前页 10% 黑底；上一页 / 下一页用 ‹ ›。
        Button(action: action) {
            Group {
                if title == "上一页" { Image(systemName: "chevron.left").font(.system(size: 11, weight: .medium)) }
                else if title == "下一页" { Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)) }
                else { Text(title) }
            }
            .padding(.horizontal, 6).frame(minWidth: 24, minHeight: 24)
            .foregroundStyle(current ? V3.txt : V3.sub).fontWeight(current ? .medium : .regular)
            .background(current ? Color.black.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(loading || !enabled).opacity(loading || !enabled ? 0.35 : 1)
            .accessibilityLabel(title)
            .accessibilityAddTraits(current ? .isSelected : [])
    }
}


/// Sheet 内容（macOS 稿：去掉右上角 ×，Esc 关闭；底部 20 内边距、顶线分隔的按钮行，左侧可放说明）。
struct V3Dialog<Body: View, Foot: View, Left: View>: View {
    var width: CGFloat = 440
    var closable = true
    let close: () -> Void
    @ViewBuilder var content: () -> Body
    @ViewBuilder var left: () -> Left
    @ViewBuilder var foot: () -> Foot
    /// `@container dialog (max-width: 500px)`：窄弹窗用 24/20 内边距、关闭按钮 20/16、页脚 72 高，左侧为空时按钮靠左。
    private var narrow: Bool { width <= 500 }
    private var hasLeft: Bool { Left.self != EmptyView.self }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, narrow ? 20 : 32).padding(.top, narrow ? 24 : 28).padding(.bottom, 24)
            Group {
                if narrow {
                    VStack(alignment: .leading, spacing: 10) {
                        if hasLeft { HStack(spacing: 20) { left() }.frame(maxWidth: .infinity, alignment: .leading) }
                        HStack(spacing: 10) { foot() }
                    }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).padding(.vertical, 16).padding(.horizontal, 20)
                } else {
                    HStack(spacing: 10) {
                        HStack(spacing: 20) { left() }.frame(maxWidth: .infinity, alignment: .leading)
                        foot()
                    }.padding(.horizontal, 24).padding(.vertical, 16).frame(minHeight: 60)
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
        }
        .frame(width: width)
        .background {
            // 不画 ×：Esc（取消操作）关闭，底部按钮行里的「取消」负责可见的关闭入口。
            if closable { Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
        }
    }
}

extension V3Dialog where Left == EmptyView {
    init(width: CGFloat = 440, closable: Bool = true, close: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Body, @ViewBuilder foot: @escaping () -> Foot) {
        self.init(width: width, closable: closable, close: close, content: content, left: { EmptyView() }, foot: foot)
    }
}

/// `.v3-dialog-title` / `.v3-dialog-sub`：20px 半粗标题（行高 28），14px 说明（行高 22，距标题 8）。
struct V3DialogHead: View {
    let title: String
    var sub: String? = nil
    /// 账号弹窗（`.acc-dialog`）的说明距标题 7、行高 20。
    var subTop: CGFloat = 8
    var subLine: CGFloat = 22
    var body: some View {
        Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 24)
        if let sub { Text(sub).font(V3.sans(13)).foregroundStyle(V3.sub).lineHeight(13, subLine - 2).fixedSize(horizontal: false, vertical: true).padding(.top, subTop) }
    }
}

/// `.v3-field` + `.v3-input`：14px 中粗标签（行高 20），间距 8，40 高、圆角 8、内边距 14 的输入框，出错时红框与提示。
struct V3TextInput: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var error: String? = nil
    var disabled = false
    var maxLength = 255
    var submit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.sub).frame(height: 18)
            // macOS 稿 TextField：28 高、圆角 6、10% 黑描边，聚焦时 accent 聚焦环。
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(V3.fnt2))
                .textFieldStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.txt).focused($focused)
                .padding(.horizontal, 8).frame(height: 28)
                .background(.white, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(error != nil ? V3.red : .black.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused && error == nil ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 3).padding(-1.5))
                .disabled(disabled).onSubmit(submit).accessibilityLabel(label)
                .onAppear { focused = true }
                .onChange(of: text) { if text.count > maxLength { text = String(text.prefix(maxLength)) } }
            if let error { Text(error).font(V3.sans(12)).foregroundStyle(V3.red).lineHeight(12, 18).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// 统一加载（macOS 稿第 15 页 · 04「二级页面统一加载」93:3090）：内容区正中一朵山茶花逐瓣绽放（与 Web `ThinkingMark`
/// 同一动画）+ 一行 12.5 灰字；180ms 内返回不出现；超过 8 秒补一行慢加载提示（15 页 01 · B），有重试动作时附蓝色「重新加载」。
struct V3Loading: View {
    let label: String
    var retry: (() -> Void)? = nil
    @State private var shown = false
    init(_ label: String, retry: (() -> Void)? = nil) { self.label = label; self.retry = retry }
    var body: some View {
        VStack(spacing: 8) {
            V3ThinkingMark(size: 40).frame(width: 56, height: 48)
            Text(label).font(V3.sans(12.5)).foregroundStyle(V3Skeleton.faint).multilineTextAlignment(.center)
            V3SlowLoadHint(retry: retry).padding(.top, 1)
        }
        .opacity(shown ? 1 : 0)
        .accessibilityElement(children: .contain).accessibilityLabel(label)
        .task {
            try? await Task.sleep(for: .milliseconds(180))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.1)) { shown = true } }
        }
    }
}

/// 品牌山茶花五片花瓣（Resources/Library/loading-petal-1…5，两片黄瓣在下、三片红瓣在上）依次绽放、停留后收拢，3 秒一轮；
/// 「减少动态效果」时静止显示完整花朵。
struct V3ThinkingMark: View {
    var size: CGFloat = 40
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let petals: [NSImage] = (1...5).compactMap { index in
        Bundle.module.url(forResource: "loading-petal-\(index)", withExtension: "png", subdirectory: "Library").flatMap(NSImage.init(contentsOf:))
    }
    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(Self.petals.enumerated()), id: \.offset) { index, image in
                    let pose = reduceMotion ? (scale: 1.0, angle: 0.0) : Self.pose(time - Double(index) * 0.15)
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
                        .scaleEffect(pose.scale, anchor: UnitPoint(x: 0.5, y: 0.547))
                        .rotationEffect(.degrees(pose.angle), anchor: UnitPoint(x: 0.5, y: 0.547))
                }
            }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
    }
    /// Web `assistant-thinking-petal` 关键帧：0% 缩 0 转 -30° → 20% 放大 1.05 转 3° → 28%–72% 停住 → 94% 收回。
    private static func pose(_ time: Double) -> (scale: Double, angle: Double) {
        let p = (time.truncatingRemainder(dividingBy: 3) + 3).truncatingRemainder(dividingBy: 3) / 3
        func ease(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }
        switch p {
        case ..<0.2: let t = ease(p / 0.2); return (1.05 * t, -30 + 33 * t)
        case ..<0.28: let t = ease((p - 0.2) / 0.08); return (1.05 - 0.05 * t, 3 - 3 * t)
        case ..<0.72: return (1, 0)
        case ..<0.94: let t = ease((p - 0.72) / 0.22); return (1 - t, -30 * t)
        default: return (0, -30)
        }
    }
}

/// 慢加载提示（15 页 01 · B）：加载超过 8 秒才出现，「比平时慢一些，还在加载。」+ 蓝色「重新加载」。
struct V3SlowLoadHint: View {
    var retry: (() -> Void)? = nil
    @State private var slow = false
    var body: some View {
        Group {
            if slow {
                HStack(spacing: 6) {
                    Text("比平时慢一些，还在加载。").foregroundStyle(V3Skeleton.faint)
                    if let retry {
                        Button("重新加载", action: retry).buttonStyle(.plain).foregroundStyle(V3.link).pointingHandCursor()
                    }
                }.font(V3.sans(12.5)).accessibilityElement(children: .combine).transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { slow = true } }
        }
    }
}

/// 加载失败（15 页 01 · D）：骨架换成一行灰字 + 蓝色「重新加载」，不弹窗、不放插图。
struct V3LoadFailed: View {
    var message = "没有加载出来。"
    let retry: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text(message).foregroundStyle(V3.sub)
            Button("重新加载", action: retry).buttonStyle(.plain).fontWeight(.medium).foregroundStyle(V3.blue).pointingHandCursor()
        }.font(V3.sans(13))
    }
}

/// 骨架占位块（Web `.v3-sk`）：#ECECEA 底 + 一道从左往右扫过的高光（1.5 秒一轮）；150ms 后淡入，快的请求不闪骨架。
/// `light` 是卡片舞台里的白色纸张占位。「减少动态效果」时改为缓慢明暗。
struct V3Skeleton: View {
    static let fill = Color(hex: 0xECECEA)
    /// 稿里的提示灰 #96968F（说明、计数、骨架页的辅助字）。
    static let faint = Color(hex: 0x96968F)
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = 4
    var color: Color = V3Skeleton.fill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    var body: some View {
        RoundedRectangle(cornerRadius: radius).fill(color)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation) { context in
                        GeometryReader { box in
                            let p = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
                            let travel = min(1, p / 0.7)
                            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.7), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                                .frame(width: box.size.width / 2).offset(x: -box.size.width / 2 + travel * box.size.width * 1.5)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .frame(width: width, height: height)
            .opacity(shown ? (reduceMotion ? 0.8 : 1) : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(150))
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.16)) { shown = true } }
            }
            .accessibilityHidden(true)
    }
}

extension View {
    /// 文字链（蓝色「重新加载」等）悬停时显示手形光标。
    func pointingHandCursor() -> some View {
        onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}

/// 统一弹窗（Web `StandardDialog`，Figma 00 · 06N「DrawOffer / Dialog」）：衬线标题 + 一句灰色副标题 → 正文 → 底部。
/// 上 24、左右和下 32，区块间距 24，底部无分隔线；宽度按弹窗固定。有「取消」就不放右上 ×，没有取消的只读 / 提示类才放。
/// 底部：左侧一句说明或文字链，右侧次按钮（描边）+ 唯一的墨黑主按钮。
struct V3StandardDialog<Content: View, Note: View, Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var width: CGFloat = 462
    var showClose = false
    let close: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var note: () -> Note
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(V3.serif(20)).foregroundStyle(V3.txt).lineHeight(20, 28, .serif).fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.sub).lineHeight(13, 20).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.trailing, showClose ? 36 : 0)
            if Content.self != EmptyView.self {
                VStack(alignment: .leading, spacing: 24) { content() }.font(V3.sans(13)).foregroundStyle(V3.txt)
            }
            HStack(spacing: 12) {
                HStack(spacing: 0) { note() }.font(V3.sans(13)).foregroundStyle(V3.sub).frame(maxWidth: .infinity, alignment: .leading)
                actions()
            }
        }
        .padding(.top, 24).padding(.horizontal, 32).padding(.bottom, 32)
        .frame(width: width, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if showClose {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundStyle(V3.fnt).frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("关闭").padding(.top, 20).padding(.trailing, 20)
            }
        }
        .background { if !showClose { Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) } }
    }
}

extension V3StandardDialog where Content == EmptyView {
    init(title: String, subtitle: String? = nil, width: CGFloat = 462, showClose: Bool = false, close: @escaping () -> Void,
         @ViewBuilder note: @escaping () -> Note, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: title, subtitle: subtitle, width: width, showClose: showClose, close: close, content: { EmptyView() }, note: note, actions: actions)
    }
}

/// 统一弹窗里的信息行（Web `DialogField`）：左 84 宽灰标签、右侧 Medium 值，可带一个蓝色文字操作。
struct V3DialogField<Value: View, Action: View>: View {
    let label: String
    var muted = false
    @ViewBuilder var value: () -> Value
    @ViewBuilder var action: () -> Action
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label).foregroundStyle(V3.fnt).frame(width: 84, alignment: .leading)
            value().font(V3.sans(13, weight: muted ? .regular : .medium)).foregroundStyle(muted ? V3.fnt : V3.txt)
                .frame(maxWidth: .infinity, alignment: .leading)
            action().padding(.leading, 12)
        }.font(V3.sans(13)).lineHeight(13, 20).padding(.vertical, 4)
    }
}

extension V3DialogField where Action == EmptyView, Value == Text {
    init(_ label: String, _ text: String, muted: Bool = false) {
        self.init(label: label, muted: muted, value: { Text(text) }, action: { EmptyView() })
    }
}

/// 统一弹窗底部左侧的文字链：文字后跟细尖括号。
struct V3TextLink: View {
    let title: String
    var chevron = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                if chevron { Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)) }
            }.font(V3.sans(13)).foregroundStyle(V3.link).contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHandCursor()
    }
}
