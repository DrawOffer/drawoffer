import DrawOfferCore
import SwiftUI

/// 首页知识图谱「聊一聊」带进对话的节点（Web `HomeChatNode`）：技术和知识点由 AI 先开口讲掌握情况。
struct HomeChatTopic: Equatable, Sendable {
    let key: String
    let name: String
    /// 掌握情况的一两个字（还不牢 / 刚练稳），显示在输入框上方的标签里
    let state: String
    let tone: HomeGraph.Node.Tone
}

/// 展开的知识图谱右边的对话栏（Figma 02A·10 ②③）：404 宽，右上 ↗ 展开到对话页、✕ 收起；
/// 对话本身就是对话页那一套（`AssistantChatView` 的 `panel` 模式），只是消息区更窄、输入框上方挂这个知识点。
struct HomeGraphChatPanel: View {
    static let width: CGFloat = 404

    let topic: HomeChatTopic
    /// 同一个知识点再点「聊一聊」接着上次那段聊
    let sessionID: String?
    let created: (String) -> Void
    let sessionsChanged: () -> Void
    /// ↗：在对话页打开同一条对话；nil 时不显示
    let expand: ((String) -> Void)?
    let close: () -> Void

    @State private var current: String?

    var body: some View {
        AssistantChatView(sessionID: sessionID, initialMessage: nil,
                          created: { id in current = id; created(id) },
                          deleted: close,
                          sessionsChanged: sessionsChanged,
                          knowledge: topic, panel: true)
            .id(topic.key)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    if let expand, let id = current ?? sessionID {
                        iconButton("arrow.up.right", label: "在对话页打开") { expand(id) }
                    }
                    iconButton("xmark", label: "关闭对话", action: close)
                }.padding(.top, 13).padding(.trailing, 12)
            }
            .frame(width: Self.width)
            .background(.white)
            .overlay(alignment: .leading) { Rectangle().fill(V3.line).frame(width: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("和 \(topic.name) 有关的对话")
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .regular)).foregroundStyle(V3.fnt)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}
