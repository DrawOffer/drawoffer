import SwiftUI

/// macOS 设计稿（Figma NuYmNOz50Af48mtAaj1kZA，2026-11-16 定）：所有弹窗与确认框都在窗口正中显示，四角圆角、无灰色遮罩。
/// 系统 `.sheet` / `.alert` / `.confirmationDialog` 在 macOS 上只能贴在标题栏下方，所以统一换成这里的浮层：
/// 各页用 `.centeredSheet` / `.centeredAlert` / `.centeredConfirmation`（参数与系统版相同），
/// 窗口根部（`WorkspaceView`）用 `.modalHost()` 统一画在整个窗口正中；弹窗里再弹的，画在上一层弹窗正中。

// MARK: Presentation plumbing

struct ModalEntry: Identifiable {
    let id: String
    /// true：由宿主套白底圆角卡片（Sheet）；false：内容自己画外观（Alert）。
    let framed: Bool
    let view: AnyView
}

struct ModalPreferenceKey: PreferenceKey {
    static var defaultValue: [ModalEntry] { [] }
    static func reduce(value: inout [ModalEntry], nextValue: () -> [ModalEntry]) { value += nextValue() }
}

/// 浮层里的“关闭”：替代系统 `@Environment(\.dismiss)`（浮层不是系统 Sheet，dismiss 不起作用）。
struct ModalCloseAction {
    var run: () -> Void = {}
    func callAsFunction() { run() }
}

private struct ModalCloseKey: EnvironmentKey {
    static var defaultValue: ModalCloseAction { ModalCloseAction() }
}

extension EnvironmentValues {
    var closeModal: ModalCloseAction {
        get { self[ModalCloseKey.self] }
        set { self[ModalCloseKey.self] = newValue }
    }
}

private struct ModalPresenter: ViewModifier {
    let entry: ModalEntry?
    let presented: Bool
    let onDismiss: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .transformPreference(ModalPreferenceKey.self) { value in if let entry { value.append(entry) } }
            .onChange(of: presented) { old, new in if old && !new { onDismiss?() } }
    }
}

/// 把子视图登记的浮层画在自己正中；登记不再往上传，避免外层宿主重复画。
private struct ModalHost: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(ModalPreferenceKey.self) { entries in
                ZStack {
                    ForEach(entries) { entry in
                        ZStack {
                            // 不加灰色遮罩，但挡住下层的点击（与系统模态一致）
                            Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture {}
                                .accessibilityHidden(true)
                            ModalCenterLayout {
                                if entry.framed { ModalCard { entry.view.modalHost() } }
                                else { entry.view.modalHost() }
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
                .animation(.easeOut(duration: 0.16), value: entries.map(\.id))
            }
            .transformPreference(ModalPreferenceKey.self) { $0.removeAll() }
    }
}

/// 按内容的理想尺寸摆在正中；超过可用空间时收进窗口（四周留 24），内容里的滚动区自己滚。
private struct ModalCenterLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, max(0, bounds.width - 48)), height: min(ideal.height, max(0, bounds.height - 48)))
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(size))
        }
    }
}

/// Sheet 外观：白底、四角 12、10% 黑描边、窗口级阴影。
private struct ModalCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.1)))
            .shadow(color: .black.opacity(0.18), radius: 28, y: 14)
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }
}

extension View {
    /// 窗口根部调用一次：本视图里登记的浮层都画在它正中。
    func modalHost() -> some View { modifier(ModalHost()) }

    /// 与 `.sheet(isPresented:onDismiss:content:)` 相同，但画在窗口正中。
    func centeredSheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(CenteredSheetModifier(isPresented: isPresented, onDismiss: onDismiss, sheet: content))
    }

    /// 与 `.sheet(item:onDismiss:content:)` 相同，但画在窗口正中。
    func centeredSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        modifier(CenteredItemSheetModifier(item: item, onDismiss: onDismiss, sheet: content))
    }

    /// 与 `.alert(_:isPresented:actions:message:)` 相同：260 宽、花标、按钮竖排（设计稿 00 页 Alert 89:35）。
    func centeredAlert<Actions: View, Message: View>(_ title: String, isPresented: Binding<Bool>,
                                                     @ViewBuilder actions: @escaping () -> Actions,
                                                     @ViewBuilder message: @escaping () -> Message) -> some View {
        modifier(CenteredAlertModifier(title: title, isPresented: isPresented, actions: actions, message: message))
    }

    func centeredAlert<Actions: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> Actions) -> some View {
        centeredAlert(title, isPresented: isPresented, actions: actions, message: { EmptyView() })
    }

    /// 与 `.alert(_:isPresented:presenting:actions:message:)` 相同。
    func centeredAlert<T, Actions: View, Message: View>(_ title: String, isPresented: Binding<Bool>, presenting data: T?,
                                                        @ViewBuilder actions: @escaping (T) -> Actions,
                                                        @ViewBuilder message: @escaping (T) -> Message) -> some View {
        centeredAlert(title, isPresented: Binding(get: { isPresented.wrappedValue && data != nil }, set: { isPresented.wrappedValue = $0 }),
                      actions: { if let data { actions(data) } }, message: { if let data { message(data) } })
    }

    /// `.confirmationDialog` 在 macOS 上也是确认框，统一用同一个 Alert；调用方须自己放「取消」按钮。
    func centeredConfirmation<Actions: View, Message: View>(_ title: String, isPresented: Binding<Bool>,
                                                            @ViewBuilder actions: @escaping () -> Actions,
                                                            @ViewBuilder message: @escaping () -> Message) -> some View {
        centeredAlert(title, isPresented: isPresented, actions: actions, message: message)
    }

    func centeredConfirmation<Actions: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> Actions) -> some View {
        centeredAlert(title, isPresented: isPresented, actions: actions, message: { EmptyView() })
    }
}

private struct CenteredSheetModifier<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let sheet: () -> Sheet
    @State private var id = UUID().uuidString

    func body(content: Content) -> some View {
        let binding = $isPresented
        let entry = isPresented
            ? ModalEntry(id: id, framed: true, view: AnyView(sheet().environment(\.closeModal, ModalCloseAction { binding.wrappedValue = false })))
            : nil
        return content.modifier(ModalPresenter(entry: entry, presented: isPresented, onDismiss: onDismiss))
    }
}

private struct CenteredItemSheetModifier<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let sheet: (Item) -> Sheet

    func body(content: Content) -> some View {
        let binding = $item
        // 换了一项时当作重新打开（与系统 Sheet 一致：内容状态重置）
        let entry = item.map { value in
            ModalEntry(id: "item-\(value.id)", framed: true,
                       view: AnyView(sheet(value).environment(\.closeModal, ModalCloseAction { binding.wrappedValue = nil })))
        }
        return content.modifier(ModalPresenter(entry: entry, presented: item != nil, onDismiss: onDismiss))
    }
}

private struct CenteredAlertModifier<Actions: View, Message: View>: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let actions: () -> Actions
    let message: () -> Message
    @State private var id = UUID().uuidString

    func body(content: Content) -> some View {
        let binding = $isPresented
        let entry = isPresented
            ? ModalEntry(id: id, framed: false, view: AnyView(
                AlertCard(title: title, close: { binding.wrappedValue = false }, actions: actions, message: message)
                    .environment(\.closeModal, ModalCloseAction { binding.wrappedValue = false })))
            : nil
        return content.modifier(ModalPresenter(entry: entry, presented: isPresented, onDismiss: nil))
    }
}

// MARK: Alert

/// 设计稿 Alert：260 宽、花标 48、标题 13 半粗、说明 11、按钮竖排撑满；点任何按钮都会关闭（与系统 Alert 一致）。
private struct AlertCard<Actions: View, Message: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let message: () -> Message

    var body: some View {
        VStack(spacing: 0) {
            AppIconImage().frame(width: 48, height: 48).accessibilityHidden(true)
            Text(title).font(V3.sans(13, weight: .semibold)).foregroundStyle(V3.txt).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            message().font(V3.sans(11)).foregroundStyle(V3.sub).multilineTextAlignment(.center).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            VStack(spacing: 8) { actions() }
                .buttonStyle(AlertActionStyle(close: close))
                .padding(.top, 16)
        }
        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 16)
        .frame(width: 260)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// 按钮按 role 着色：普通是墨黑主按钮、destructive 红色、cancel 浅灰（并接 Esc）；点完先执行动作再关闭。
private struct AlertActionStyle: PrimitiveButtonStyle {
    let close: () -> Void
    func makeBody(configuration: Configuration) -> some View {
        let role = configuration.role
        let kind: AlertButtonStyle.Kind = role == .destructive ? .danger : role == .cancel ? .secondary : .primary
        return Button(role: role) {
            configuration.trigger()
            close()
        } label: { configuration.label }
            .buttonStyle(AlertButtonStyle(kind: kind))
            .modifier(CancelShortcut(active: role == .cancel))
    }
}

private struct CancelShortcut: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.keyboardShortcut(.cancelAction) } else { content }
    }
}
