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
    static let purpleSoft = Color(hex: 0xF3EEFA)

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
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                Text(eyebrow.joined(separator: " · ")).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.fnt).frame(height: 18)
                Text(title).font(V3.serif(28)).foregroundStyle(V3.txt).frame(height: 36).padding(.top, compact ? 9 : 8)
                if let subtitle {
                    Text(subtitle).font(V3.sans(compact ? 13 : 14)).foregroundStyle(V3.sub).lineLimit(1)
                        .frame(height: compact ? 16 : subtitleHeight).padding(.top, compact ? 6 : 6)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: compact ? 8 : 10) { actions() }.padding(.top, compact ? 32 : 31)
        }
    }
}

/// `.v3-btn`: pill buttons. Dark is the single primary action on a page.
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
        return HStack(spacing: 6) { configuration.label }
            .font(V3.sans(kind == .text ? 13 : small ? 12 : 14, weight: .medium)).lineLimit(1).fixedSize(horizontal: !fill, vertical: false)
            .frame(maxWidth: fill ? .infinity : nil)
            .foregroundStyle(kind == .dark || kind == .danger ? Color.white : kind == .text ? (pressed ? V3.txt : V3.sub) : V3.txt)
            .padding(.horizontal, kind == .text ? 0 : height >= 36 ? 18 : 14)
            .frame(width: width, height: kind == .text ? nil : height)
            .background {
                switch kind {
                case .dark: Capsule().fill(pressed ? Color(hex: 0x0E0E0D) : V3.txt)
                case .danger: Capsule().fill(pressed ? Color(hex: 0xC33B3B) : V3.red)
                case .ghost: Capsule().fill(pressed ? V3.field : .white).overlay(Capsule().stroke(V3.cl))
                case .text: Color.clear
                }
            }
            .opacity(enabled ? 1 : 0.38)
            .contentShape(Capsule())
    }
}

/// Full-width 44pt dark submit (`.mi-new-submit`).
struct V3PrimaryBlockStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(13.5, weight: .medium)).foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(configuration.isPressed ? Color(hex: 0x0E0E0D) : V3.txt, in: Capsule())
            .opacity(enabled ? 1 : 0.45).contentShape(Capsule())
    }
}

/// `.v3-search`.
struct V3SearchField: View {
    @Binding var text: String
    var placeholder: String
    var width: CGFloat? = 180
    var height: CGFloat = 32
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(V3.fnt)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(V3.fnt)).textFieldStyle(.plain)
                .font(V3.sans(14)).foregroundStyle(V3.txt).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(V3.fnt2) }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10).frame(width: width, height: height)
        .background(focused ? Color.white : V3.field, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? V3.sk2 : .clear))
    }
}

/// `.v3-seg`: grey track with a white pressed segment.
struct V3Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var segmentWidth: CGFloat? = nil
    var height: CGFloat = 30
    var fontSize: CGFloat = 14
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let chosen = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1).font(V3.sans(fontSize, weight: .medium)).foregroundStyle(chosen ? V3.txt : V3.sub)
                        .padding(.horizontal, segmentWidth == nil ? 12 : 0)
                        .frame(width: segmentWidth, height: height - 6)
                        .background {
                            if chosen { RoundedRectangle(cornerRadius: 6).fill(.white).shadow(color: .black.opacity(0.08), radius: 1.5, y: 1) }
                        }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(3).frame(height: height).background(V3.field, in: RoundedRectangle(cornerRadius: 8))
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

/// `.v3-menu`-style popover row with an optional check mark.
struct V3MenuRow: View {
    let label: String
    var systemImage: String? = nil
    var checked = false
    var danger = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 13)).frame(width: 15) }
                Text(label).font(V3.sans(12.5))
                Spacer(minLength: 0)
                if checked { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
            }
            .foregroundStyle(danger ? V3.red : V3.txt)
            .padding(.horizontal, 10).frame(height: 34)
            .background(hover ? (danger ? V3.redSoft : V3.field) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}

extension View {
    /// CSS `line-height`：多行时补行距，首行上下各补一半，使单行高度与 Web 相同（系统字体行高约为字号 × 1.2）。
    func lineHeight(_ size: CGFloat, _ height: CGFloat) -> some View {
        let extra = max(0, height - size * 1.2)
        return lineSpacing(extra).padding(.vertical, extra / 2)
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
            HStack(spacing: 6) {
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
        Button(action: action) {
            Text(title).padding(.horizontal, 10).frame(minWidth: 32, minHeight: 32)
                .foregroundStyle(current ? .white : V3.sub)
                .background(current ? V3.blue : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(current ? V3.blue : Color(hex: 0xE4E4E0)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(loading || !enabled).opacity(loading || !enabled ? 0.45 : 1)
            .accessibilityAddTraits(current ? .isSelected : [])
    }
}


/// `.v3-dialog`：正文 28/32/24 内边距，右上 28×28 关闭（距边 26），底部 88 高、顶线分隔的按钮区（左侧可放说明）。
struct V3Dialog<Body: View, Foot: View, Left: View>: View {
    var width: CGFloat = 440
    var closable = true
    let close: () -> Void
    @ViewBuilder var content: () -> Body
    @ViewBuilder var left: () -> Left
    @ViewBuilder var foot: () -> Foot
    /// false：正文自己排内边距（新建简历这类分区弹窗）。
    var padded = true

    func bodyPadding(_ on: Bool) -> Self { var copy = self; copy.padded = on; return copy }

    /// `@container dialog (max-width: 500px)`：窄弹窗用 24/20 内边距、关闭按钮 20/16、页脚 72 高，左侧为空时按钮靠左。
    private var narrow: Bool { width <= 500 }
    private var hasLeft: Bool { Left.self != EmptyView.self }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, maxHeight: padded ? nil : .infinity, alignment: .topLeading)
                .padding(.horizontal, padded ? (narrow ? 20 : 32) : 0).padding(.top, padded ? (narrow ? 24 : 28) : 0).padding(.bottom, padded ? 24 : 0)
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
                    }.padding(.horizontal, 32).frame(minHeight: 88)
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
        }
        .frame(width: width)
        .overlay(alignment: .topTrailing) {
            if closable {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(V3.fnt).keyboardShortcut(.cancelAction).accessibilityLabel("关闭")
                    .padding(.top, narrow ? 20 : 26).padding(.trailing, narrow ? 16 : 26)
            }
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
        Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 28).padding(.trailing, 28)
        if let sub { Text(sub).font(V3.sans(14)).foregroundStyle(V3.sub).lineHeight(14, subLine).fixedSize(horizontal: false, vertical: true).padding(.top, subTop) }
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
            Text(label).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.sub).frame(height: 20)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(V3.fnt2))
                .textFieldStyle(.plain).font(V3.sans(14)).foregroundStyle(V3.txt).focused($focused)
                .padding(.horizontal, 14).frame(height: 40)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(error != nil ? V3.red : focused ? V3.txt : V3.cl))
                .disabled(disabled).onSubmit(submit).accessibilityLabel(label)
                .onAppear { focused = true }
                .onChange(of: text) { if text.count > maxLength { text = String(text.prefix(maxLength)) } }
            if let error { Text(error).font(V3.sans(14)).foregroundStyle(V3.red).lineHeight(14, 22).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
