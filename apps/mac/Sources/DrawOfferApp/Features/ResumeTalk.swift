import AppKit
import SwiftUI

/// 纸右边的对话（Figma 03 页分区 12「修改对话与检查简历：对话版」，与分区 05 新建引导同一种写法）：
/// 400 宽一列、不加卡片；职绘头像 28 + 气泡（最新一轮白底细边，上一轮变淡），用户的话是右侧灰底小气泡，
/// 下面一排快捷回答（33 高胶囊）和一行输入框（47 高、右侧 30 圆形发送钮）。
enum ResumeTalk {
    static let columnWidth: CGFloat = 400
    /// 头像左缘 2、气泡左缘 45（头像 28 + 间距 15）。
    static let indent: CGFloat = 45
    static let line = Color(hex: 0xD6D4CC)
    static let fieldLine = Color(hex: 0xDCDAD2)
    static let hint = Color(hex: 0xA5A39B)
    static let note = Color(hex: 0x87867F)
    static let userFill = Color(hex: 0xEDECE7)
    static let oldFill = Color(hex: 0xEFEFEC)
    /// 纸上补出来、要核实的说法（橙）。
    static let verify = Color(hex: 0xC8721C)
}

/// 职绘头像：品牌花（找不到资源时退回应用图标）。
struct ResumeTalkAvatar: View {
    var body: some View {
        Group {
            if let url = Bundle.module.url(forResource: "mark", withExtension: "png", subdirectory: "Branding"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else { Image(systemName: "circle.hexagongrid").foregroundStyle(V3.orange) }
        }.frame(width: 28, height: 28).accessibilityHidden(true)
    }
}

/// 职绘说的一句：主句 14 号墨黑，补充 12.5 号灰；`faded` 是上一轮（灰底、变淡）。
struct ResumeTalkAssistant<Extra: View>: View {
    let text: String
    var note: String? = nil
    var faded = false
    var thinking = false
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            ResumeTalkAvatar().padding(.leading, 2).padding(.top, 3)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(text).font(V3.sans(14)).foregroundStyle(faded ? V3.fnt : V3.txt).lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if thinking { ProgressView().controlSize(.mini) }
                }
                if let note, !note.isEmpty {
                    Text(note).font(V3.sans(12.5)).foregroundStyle(ResumeTalk.note).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 11.5)
                }
                extra()
            }
            .padding(.horizontal, 16.5).padding(.vertical, 14.5)
            .background(faded ? ResumeTalk.oldFill : .white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(faded ? .clear : V3.cl))
            .opacity(faded ? 0.75 : 1)
            Spacer(minLength: 40)
        }
    }
}

extension ResumeTalkAssistant where Extra == EmptyView {
    init(text: String, note: String? = nil, faded: Bool = false, thinking: Bool = false) {
        self.init(text: text, note: note, faded: faded, thinking: thinking) { EmptyView() }
    }
}

/// 用户说的一句：右侧灰底小气泡。
struct ResumeTalkUser: View {
    let text: String
    var faded = false
    var body: some View {
        HStack {
            Spacer(minLength: ResumeTalk.indent + 40)
            Text(text).font(V3.sans(14)).foregroundStyle(faded ? V3.fnt : V3.txt).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 12.5)
                .background(ResumeTalk.userFill, in: RoundedRectangle(cornerRadius: 12))
                .opacity(faded ? 0.7 : 1)
        }
    }
}

/// 快捷回答：33 高白底胶囊、#d6d4cc 细边、13 号字；悬停只加深边线，不加灰块。
struct ResumeTalkChip: View {
    let title: String
    var disabled = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(V3.sans(13)).foregroundStyle(V3.txt).lineLimit(1)
                .padding(.horizontal, 14.5).frame(height: 33)
                .background(.white, in: Capsule())
                .overlay(Capsule().stroke(hover && !disabled ? V3.sub.opacity(0.6) : ResumeTalk.line))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
        .onHover { hover = $0 }
    }
}

/// 一排快捷回答，放不下时换行（间距 9 / 9）。
struct ResumeTalkChips: View {
    let items: [(String, () -> Void)]
    var disabled = false
    var body: some View {
        ResumeTalkFlow(spacing: 9) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                ResumeTalkChip(title: item.0, disabled: disabled, action: item.1)
            }
        }.padding(.leading, ResumeTalk.indent)
    }
}

/// 输入框：355 宽（随列宽撑满）、47 高、圆角 13.5、#dcdad2 边；右侧 30 圆形发送钮，有字时变墨黑。
struct ResumeTalkInput: View {
    let placeholder: String
    @Binding var text: String
    var disabled = false
    var limit = 300
    let send: () -> Void
    @FocusState private var focused: Bool

    private var ready: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !disabled }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(ResumeTalk.hint), axis: .vertical)
                .textFieldStyle(.plain).font(V3.sans(13.5)).foregroundStyle(V3.txt).lineLimit(1...4)
                .focused($focused).disabled(disabled)
                .onSubmit { if ready { send() } }
                .onChange(of: text) { if text.count > limit { text = String(text.prefix(limit)) } }
            Button { if ready { send() } } label: {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(ready ? V3.txt : ResumeTalk.line, in: Circle())
            }.buttonStyle(.plain).disabled(!ready).accessibilityLabel("发送")
        }
        .padding(.leading, 16.5).padding(.trailing, 8).padding(.vertical, 8).frame(minHeight: 47)
        .background(.white, in: RoundedRectangle(cornerRadius: 13.5))
        .overlay(RoundedRectangle(cornerRadius: 13.5).stroke(focused ? V3.sub.opacity(0.5) : ResumeTalk.fieldLine))
        .padding(.leading, ResumeTalk.indent)
        .accessibilityElement(children: .contain).accessibilityLabel(placeholder)
    }
}

/// 简单的换行排布（快捷回答用）。
struct ResumeTalkFlow: Layout {
    var spacing: CGFloat = 9
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += row + spacing; x = 0; row = 0 }
            x += size.width + spacing; row = max(row, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}

/// 改好的那一句：设计稿里直接显示在纸上（浅蓝底=还没换上，橙色=要核实）；原生纸面还不能临时高亮，
/// 先放在对话里，用同样的浅蓝底和橙色标出。
struct ResumeTalkProposal: View {
    let text: String
    var risky: [String] = []
    var body: some View {
        Text(Self.marked(text, risky: risky)).font(V3.sans(13)).foregroundStyle(V3.txt).lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(V3.blueSoft, in: RoundedRectangle(cornerRadius: 6))
            .padding(.top, 10)
    }

    static func marked(_ text: String, risky: [String]) -> AttributedString {
        var result = AttributedString(text)
        for term in risky where !term.isEmpty {
            var start = result.startIndex
            while let range = result[start...].range(of: term) {
                result[range].foregroundColor = ResumeTalk.verify
                start = range.upperBound
            }
        }
        return result
    }
}
