import DrawOfferCore
import SwiftUI

/// 编辑器右上角的小绘（Figma 5:10 分区 214:6501 C1，Web `WorkbenchAiOrb`）：40×40 品牌花，画布右 24、上 20。
struct ResumeEditorOrb: View {
    var open: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            ResumeTalkAvatar().scaleEffect(40 / 28).frame(width: 40, height: 40)
                .scaleEffect(hover || open ? 1.06 : 1).animation(.easeOut(duration: 0.15), value: hover || open)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help("小绘").accessibilityLabel("小绘：帮你改简历")
    }
}

/// C1 白板：小绘左边一段话，不加卡片——一句判断（14 墨黑）+ 一行灰字，编号选项（第一项蓝字），一行“或者直接说想改什么…”。
/// 数字键选对应项，Esc 或再点小绘收起。
struct ResumeOrbBoard: View {
    let dialogue: ResumeOrb.Dialogue
    let pick: (ResumeOrb.Action) -> Void
    let say: (String) -> Void
    let close: () -> Void
    /// 选了某一项后的一句回应（失败或说明），留在白板上，可以收起。
    var reply: String? = nil
    @State private var text = ""
    @FocusState private var focused: Bool

    static let width: CGFloat = 308

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dialogue.say).font(V3.sans(14)).foregroundStyle(V3.txt).lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
            if let note = dialogue.note {
                Text(note).font(V3.sans(12.5)).foregroundStyle(ResumeTalk.note).padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(dialogue.actions.enumerated()), id: \.offset) { index, action in
                    Button { pick(action) } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)").font(V3.number(12)).foregroundStyle(index == 0 ? V3.blue : V3.fnt)
                                .frame(width: 10, alignment: .leading)
                            Text(action.label).font(V3.sans(14)).foregroundStyle(index == 0 ? V3.blue : V3.txt)
                        }.frame(height: 27).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                    .accessibilityLabel(action.label)
                }
            }.padding(.top, 10)
            if let reply {
                Text(reply).font(V3.sans(12.5)).foregroundStyle(V3.orange).padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.txt).lineLimit(1...4).focused($focused)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty { Text(ResumeOrb.inputPlaceholder).font(V3.sans(13)).foregroundStyle(V3.fnt2).allowsHitTesting(false) }
                }
                .onSubmit { send() }
                .padding(.top, 14)
                .accessibilityLabel("直接说想改什么")
        }
        .frame(width: Self.width, alignment: .leading)
        .onExitCommand(perform: close)
    }

    private func send() {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        text = ""
        say(said)
    }
}

/// 14.1 画布缩放（Web `.wbs-zoom`）：右下角 30 高白底胶囊，#d6d4cc 细边、圆角 14；− 百分比 +，点百分比回到 100%。
struct ResumeZoomBar: View {
    let zoom: Double
    let range: ClosedRange<Double>
    let set: (Double) -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("−", label: "缩小", disabled: zoom <= range.lowerBound + 0.001) { set(zoom - 0.1) }
            Button { set(1) } label: {
                Text("\(Int((zoom * 100).rounded()))%").font(V3.sans(12.5)).monospacedDigit().foregroundStyle(V3.txt)
                    .frame(minWidth: 46).frame(height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).help("回到合适大小").accessibilityLabel("回到合适大小")
            button("+", label: "放大", disabled: zoom >= range.upperBound - 0.001) { set(zoom + 0.1) }
        }
        .padding(.horizontal, 4).frame(height: 30)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ResumeTalk.line))
        .accessibilityElement(children: .contain).accessibilityLabel("画布缩放")
    }

    private func button(_ symbol: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol).font(V3.sans(15)).foregroundStyle(disabled ? Color(hex: 0xBDBBB3) : V3.txt)
                .frame(minWidth: 26).frame(height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled).accessibilityLabel(label)
    }
}
