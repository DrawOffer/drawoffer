import DrawOfferCore
import SwiftUI

/// 编辑器右上角的小绘（Figma 5:10 分区 214:6501 C1，Web `WorkbenchAiOrb`）：40×40 品牌花，画布右 24、上 20。
struct ResumeEditorOrb: View {
    var open: Bool
    /// 正在排版：外圈一道 1.5 蓝细环 1 秒转一圈（Web `.wbs-ai-orb.is-busy::after`）。
    var busy = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            ResumeTalkAvatar().scaleEffect(40 / 28).frame(width: 40, height: 40)
                .scaleEffect(hover || open ? 1.06 : 1).animation(.easeOut(duration: 0.15), value: hover || open)
                .overlay { if busy { ResumeOrbRing() } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help("小绘").accessibilityLabel("小绘：帮你改简历")
    }
}

/// C1 白板：小绘左边一段话，不加卡片——一句判断（14 墨黑）+ 一行灰字，编号选项（第一项蓝字），一行“或者直接说想改什么…”。
/// 数字键选对应项，Esc 或再点小绘收起；选了一项序号先变 ✓、其余变淡，120ms 后再去做（Web 规范 ⑥）。
/// “或者直接说想改什么…”平时是一行灰字，点了才展开成输入框（占位“想改什么，直接说”）。
struct ResumeOrbBoard: View {
    let dialogue: ResumeOrb.Dialogue
    let pick: (ResumeOrb.Action) -> Void
    let say: (String) -> Void
    let close: () -> Void
    /// 选了某一项后的一句回应（失败或说明），留在白板上，可以收起。
    var reply: String? = nil
    @State private var text = ""
    @State private var typing = false
    @State private var chosen: Int?
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
                    Button { choose(action, index) } label: {
                        HStack(spacing: 8) {
                            Text(chosen == index ? "✓" : "\(index + 1)").font(V3.number(12)).foregroundStyle(index == 0 ? V3.blue : V3.fnt)
                                .frame(width: 10, alignment: .leading)
                            Text(action.label).font(V3.sans(14)).foregroundStyle(index == 0 ? V3.blue : V3.txt)
                        }.frame(height: 27).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(chosen != nil && chosen != index ? 0.42 : 1)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                    .accessibilityLabel(action.label)
                }
            }.padding(.top, 10)
            if let reply {
                Text(reply).font(V3.sans(12.5)).foregroundStyle(V3.orange).padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if dialogue.input {
                if typing {
                    ResumeTalkInput(placeholder: ResumeOrb.inputExpandedPlaceholder, text: $text) { send() }
                        .padding(.top, 14)
                        .accessibilityLabel("直接说想改什么")
                } else {
                    Button(ResumeOrb.inputPlaceholder) { typing = true }
                        .buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.fnt2).padding(.top, 14)
                }
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .onExitCommand(perform: close)
    }

    private func choose(_ action: ResumeOrb.Action, _ index: Int) {
        guard chosen == nil else { return }
        chosen = index
        Task { try? await Task.sleep(for: .milliseconds(120)); pick(action) }
    }

    private func send() {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        text = ""
        say(said)
    }
}

/// 外圈细环：inset 2、1.5 宽，只画上沿一段 #3366d9，1 秒转一圈；减少动态效果时不转。
struct ResumeOrbRing: View {
    @State private var turn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().trim(from: 0, to: 0.25).stroke(ResumeOrbNudge.blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(turn ? 225 : -135)).padding(2)
            .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: turn)
            .onAppear { turn = true }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// 小绘白板收着时挂在它左边的一句（Web `.wbs-ai-nudge`，Mac 稿 03N-F）：
/// 正在排版——灰字“正在排版…”+ 蓝字“停下”，不加底；排好了——14 墨黑一句，带“撤销”时是白底细边胶囊（#e6e4de，内边距 9/14，间距 14）。
struct ResumeOrbNudge: View {
    enum Kind { case busy, said }
    /// Web `.wbs-ai-nudge-action` / 细环的 #3366d9。
    static let blue = Color(hex: 0x3366D9)
    let kind: Kind
    let text: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        switch kind {
        case .busy:
            HStack(spacing: 12) {
                Text(text).font(V3.sans(14)).foregroundStyle(Color(hex: 0x87867F))
                if let actionLabel, let action {
                    Button(actionLabel, action: action).buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(ResumeOrbNudge.blue)
                }
            }
            .accessibilityElement(children: .contain)
        case .said:
            if let actionLabel, let action {
                HStack(spacing: 14) {
                    Text(text).font(V3.sans(14)).foregroundStyle(V3.txt).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Button(actionLabel, action: action).buttonStyle(.plain).font(V3.sans(14, weight: .medium)).foregroundStyle(ResumeOrbNudge.blue)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.white, in: Capsule()).overlay(Capsule().strokeBorder(Color(hex: 0xE6E4DE)))
                .frame(maxWidth: 360, alignment: .trailing)
            } else {
                Text(text).font(V3.sans(14)).foregroundStyle(V3.txt).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .trailing).multilineTextAlignment(.trailing)
            }
        }
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
