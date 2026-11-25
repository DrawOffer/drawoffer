import SwiftUI

/// 顶部提示栏（macOS 稿第 16 页「顶部提示栏统一」90:13317）：一种白色卡片覆盖全部操作提示。
/// 左侧 13 号图标按状态着色（完成绿勾 / 等待转圈 / 没做成红叹号 / 需要注意橙色），标题 14 中粗直接写结果，
/// 说明 12.5 灰字只写原因或下一步，动作只用蓝色文字（最多两个），不放黑色按钮。
/// 停留：只有一行的完成提示 2.5 秒；带说明 4 秒；带动作或出错的不自动消失，右上角有 ×。
///
/// 接入：页面持有 `@State var notice: NoticeToastItem?`，在页面根部 `.overlay(alignment: .top) { NoticeToast(item: $notice).padding(.top, 20) }`，
/// 需要提示时赋值 `notice = .done("已移动到「证书」")` 等。弹窗打开时由宿主画在浮层之上即可。
struct NoticeToastItem: Equatable, Identifiable {
    /// done 完成 / waiting 正在进行 / failed 没做成 / attention 需要注意（橙色三角）/ partial 只完成一部分 / queued 已交给后台 / info 系统替你处理了
    enum Kind: Equatable { case done, waiting, failed, attention, partial, queued, info }
    struct Action: Equatable { let label: String; let id: String }
    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String? = nil
    var actions: [Action] = []
    /// 常驻且无 ×（编辑器保存一直失败、设备问题），直到状态解除由调用方清空。
    var persistent = false

    static func done(_ title: String, _ detail: String? = nil, actions: [Action] = []) -> Self { .init(kind: .done, title: title, detail: detail, actions: actions) }
    static func waiting(_ title: String, _ detail: String? = nil) -> Self { .init(kind: .waiting, title: title, detail: detail) }
    static func failed(_ title: String, _ detail: String? = nil, actions: [Action] = [], persistent: Bool = false) -> Self { .init(kind: .failed, title: title, detail: detail, actions: actions, persistent: persistent) }
    static func attention(_ title: String, _ detail: String? = nil, actions: [Action] = []) -> Self { .init(kind: .attention, title: title, detail: detail, actions: actions) }
    static func partial(_ title: String, _ detail: String? = nil, actions: [Action] = []) -> Self { .init(kind: .partial, title: title, detail: detail, actions: actions) }
    static func queued(_ title: String, _ detail: String? = nil) -> Self { .init(kind: .queued, title: title, detail: detail) }
    static func info(_ title: String, _ detail: String? = nil) -> Self { .init(kind: .info, title: title, detail: detail) }

    /// 自动消失时间（与 Web top-notice 一致）：一行完成 2.5 秒；带说明或动作的完成、已提交、系统处理说明 4 秒；
    /// 失败、注意、部分完成 6 秒；进行中与 persistent 常驻。
    var lifetime: Duration? {
        if persistent { return nil }
        switch kind {
        case .waiting: return nil
        case .failed, .attention, .partial: return .seconds(6)
        case .done: return (detail == nil && actions.isEmpty) ? .milliseconds(2500) : .seconds(4)
        case .queued, .info: return .seconds(4)
        }
    }

    /// 右上角 ×：失败、注意、部分完成、进行中显示；persistent 不显示。
    var showsClose: Bool {
        if persistent { return false }
        switch kind {
        case .failed, .attention, .partial, .waiting: return true
        case .done, .queued, .info: return false
        }
    }
}

struct NoticeToast: View {
    @Binding var item: NoticeToastItem?
    var perform: (NoticeToastItem.Action) -> Void = { _ in }
    @State private var hover = false

    var body: some View {
        Group {
            if let item {
                let hasDetail = !(item.detail ?? "").isEmpty
                let closable = item.showsClose
                HStack(alignment: hasDetail ? .top : .center, spacing: 10) {
                    NoticeToastIcon(kind: item.kind).frame(width: 16, height: 16).padding(.top, hasDetail ? 2 : 0)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(minHeight: 20, alignment: .leading)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail).font(V3.sans(12.5)).foregroundStyle(Color(hex: 0x6C6C65))
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(minHeight: 20, alignment: .leading)
                        }
                    }
                    if !item.actions.isEmpty {
                        HStack(spacing: 12) {
                            ForEach(item.actions, id: \.id) { action in
                                Button(action.label) { perform(action); self.item = nil }.buttonStyle(.plain)
                                    .font(V3.sans(13, weight: .medium)).foregroundStyle(V3.blue)
                            }
                        }.frame(minHeight: 20).padding(.leading, 0)
                    }
                    if closable {
                        Button { self.item = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(hex: 0x9A9A93)).frame(width: 20, height: 20).contentShape(Rectangle()) }
                            .buttonStyle(.plain).accessibilityLabel("关闭提示")
                    }
                }
                .padding(.leading, 18).padding(.trailing, closable ? 12 : 18).padding(.vertical, hasDetail ? 13 : 11)
                .frame(maxWidth: 520, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(hover ? Color(hex: 0xCFCFCA) : V3.cl))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 8)
                .onHover { hover = $0 }
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .contain).accessibilityAddTraits(.updatesFrequently)
                .task(id: "\(item.id)\(hover)") {
                    guard let lifetime = item.lifetime, !hover else { return }
                    try? await Task.sleep(for: lifetime)
                    if !Task.isCancelled, self.item?.id == item.id { withAnimation(.easeOut(duration: 0.18)) { self.item = nil } }
                }
            }
        }.animation(.easeOut(duration: 0.18), value: item)
    }
}

/// 状态图标（16pt）：绿勾圈、转圈、红叹号圈、橙色三角、橙色半圆、蓝色时钟圈、灰色 i 圈。
private struct NoticeToastIcon: View {
    let kind: NoticeToastItem.Kind
    @State private var spin = false
    var body: some View {
        switch kind {
        case .done: sym("checkmark.circle", 0x2F9A5B)
        case .failed: sym("exclamationmark.circle", 0xC94A3A)
        case .attention: sym("exclamationmark.triangle", 0xD47C28)
        case .partial: sym("circle.lefthalf.filled", 0xD47C28)
        case .queued: sym("clock", 0x3F6FD8)
        case .info: sym("info.circle", 0x8A8A83)
        case .waiting:
            ZStack {
                Circle().stroke(V3.cl, lineWidth: 2)
                Circle().trim(from: 0, to: 0.25).stroke(V3.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .frame(width: 14, height: 14).rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
        }
    }
    private func sym(_ name: String, _ hex: UInt32) -> some View {
        Image(systemName: name).font(.system(size: 14, weight: .medium)).foregroundStyle(Color(hex: hex))
    }
}

/// 整站状态胶囊（E1–E6）：浅灰底、1px 描边、36 高圆角胶囊，状态点区分（蓝=更新中、橙=警告、红=错误），状态解除前一直在。
/// 宿主放在窗口顶部 20px；同时有操作提示时，提示排在胶囊下方 12px，最多同时显示一个胶囊。
struct StatusPill: View {
    enum Tone { case info, warn, error }
    var tone: Tone = .info
    var title: String
    var message: String? = nil
    var actionLabel: String? = nil
    var action: () -> Void = {}

    private var dot: Color {
        switch tone {
        case .info: return V3.blue
        case .warn: return Color(hex: 0xD47C28)
        case .error: return Color(hex: 0xC94A3A)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(title).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
            if let message, !message.isEmpty { Text(message).font(V3.sans(13)).foregroundStyle(Color(hex: 0x6C6C65)).lineLimit(1) }
            if let actionLabel {
                Button(actionLabel, action: action).buttonStyle(.plain).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.blue)
            }
        }
        .padding(.leading, 14.5).padding(.trailing, 16).frame(height: 36)
        .background(Color(hex: 0xF4F4F2), in: Capsule())
        .overlay(Capsule().strokeBorder(V3.cl))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// 只有一句话的页面提示（`String?`）也画成统一的顶部提示栏：页面根部 `.overlay(alignment: .top) { TextNoticeToast(text: $notice) }`。
/// 默认按原文判断：「已…」开头的是完成，其余（多为接口错误原文）是没做成；调用方可传 `kind` 自定。
struct TextNoticeToast: View {
    @Binding var text: String?
    var kind: (String) -> NoticeToastItem.Kind = { $0.hasPrefix("已") || $0.hasSuffix("已保存") ? .done : .failed }
    @State private var item: NoticeToastItem?
    var body: some View {
        NoticeToast(item: $item).padding(.top, 20)
            .onAppear { item = text.map(make) }
            .onChange(of: text) { _, next in if next != item?.title { item = next.map(make) } }
            .onChange(of: item) { _, next in if next == nil, text != nil { text = nil } }
    }
    private func make(_ title: String) -> NoticeToastItem { NoticeToastItem(kind: kind(title), title: title) }
}
