import SwiftUI

/// 顶部提示栏（macOS 稿第 16 页「顶部提示栏统一」90:13317）：一种白色卡片覆盖全部操作提示。
/// 左侧 13 号图标按状态着色（完成绿勾 / 等待转圈 / 没做成红叹号 / 需要注意橙色），标题 14 中粗直接写结果，
/// 说明 12.5 灰字只写原因或下一步，动作只用蓝色文字（最多两个），不放黑色按钮。
/// 停留：只有一行的完成提示 2.5 秒；带说明 4 秒；带动作或出错的不自动消失，右上角有 ×。
///
/// 接入：页面持有 `@State var notice: NoticeToastItem?`，在页面根部 `.overlay(alignment: .top) { NoticeToast(item: $notice).padding(.top, 20) }`，
/// 需要提示时赋值 `notice = .done("已移动到「证书」")` 等。弹窗打开时由宿主画在浮层之上即可。
struct NoticeToastItem: Equatable, Identifiable {
    enum Kind: Equatable { case done, waiting, failed, attention }
    struct Action: Equatable { let label: String; let id: String }
    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String? = nil
    var actions: [Action] = []

    static func done(_ title: String, _ detail: String? = nil) -> Self { .init(kind: .done, title: title, detail: detail) }
    static func waiting(_ title: String, _ detail: String? = nil) -> Self { .init(kind: .waiting, title: title, detail: detail) }
    static func failed(_ title: String, _ detail: String? = nil, actions: [Action] = []) -> Self { .init(kind: .failed, title: title, detail: detail, actions: actions) }
    static func attention(_ title: String, _ detail: String? = nil) -> Self { .init(kind: .attention, title: title, detail: detail) }

    /// 自动消失时间；nil 表示常驻到用户关闭或被下一条替换。
    var lifetime: Duration? {
        switch kind {
        case .waiting: return nil
        case .failed: return actions.isEmpty ? .seconds(6) : nil
        case .done, .attention: return actions.isEmpty ? (detail == nil ? .milliseconds(2500) : .seconds(4)) : .seconds(4)
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
                HStack(alignment: .top, spacing: 12) {
                    NoticeToastIcon(kind: item.kind).frame(width: 13, height: 13).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        if let detail = item.detail { Text(detail).font(V3.sans(12.5)).foregroundStyle(V3.fnt).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
                    }
                    if !item.actions.isEmpty {
                        HStack(spacing: 14) {
                            ForEach(item.actions, id: \.id) { action in
                                Button(action.label) { perform(action); self.item = nil }.buttonStyle(.plain)
                                    .font(V3.sans(13, weight: .medium)).foregroundStyle(V3.blue)
                            }
                        }.padding(.leading, 8)
                    }
                    if item.lifetime == nil || item.kind == .failed {
                        Button { self.item = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(hex: 0x9A9A93)).frame(width: 16, height: 16) }
                            .buttonStyle(.plain).accessibilityLabel("关闭提示").padding(.top, 1)
                    }
                }
                .padding(.leading, 18).padding(.trailing, 16).padding(.vertical, 14)
                .frame(maxWidth: 520, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.cl))
                .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
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

/// 状态图标：绿勾、转圈、红叹号圈、橙色半圆（只完成一部分 / 需要注意）。
private struct NoticeToastIcon: View {
    let kind: NoticeToastItem.Kind
    var body: some View {
        switch kind {
        case .done: Image(systemName: "checkmark.circle").font(.system(size: 13, weight: .medium)).foregroundStyle(Color(hex: 0x2F9A5B))
        case .failed: Image(systemName: "exclamationmark.circle").font(.system(size: 13, weight: .medium)).foregroundStyle(Color(hex: 0xC94A3A))
        case .attention: Image(systemName: "circle.lefthalf.filled").font(.system(size: 13, weight: .medium)).foregroundStyle(Color(hex: 0xD47C28))
        case .waiting: ProgressView().controlSize(.mini).scaleEffect(0.8)
        }
    }
}
