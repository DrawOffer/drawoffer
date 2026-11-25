import AppKit
import DrawOfferCore
import SwiftUI

/// 首次引导浮层（Figma 02A · 05 首次进岗位广场 J1–J3、K3、K5；Web `features/onboarding/ScenarioSpotlight.tsx`）：
/// 整页压暗（黑 42%），只留被指的控件亮着；被指控件下方（放不下就在上方）弹出一张白色浮层，山茶花标记加一句话，
/// 下面是文字胶囊按钮。点按钮或蒙层任意处都会关闭；亮着的控件本身仍可点（点它的页面自己调用 dismiss，也算看过）。
///
/// 用法：
/// 1. 被指的控件 `.coachTarget(show, message:, actions:, onClose:)`；
/// 2. 页面根部 `.coachMarkHost()` 画蒙层和浮层（只盖住这一页的内容区）；
/// 3. 是否出现：`CoachSlot(id:, user:).open` 再加页面自己的业务条件，关闭时 `dismiss()`。
///
/// 要让蒙层盖住整个窗口（含侧栏），在 `WorkspaceView` 根部加 `.environment(\.coachMarkExternalHost, true).coachMarkHost()`，
/// 各页的 `coachMarkHost()` 就只传递不再重复绘制。

// MARK: - 条目与偏好键

struct CoachAction: Identifiable {
    let label: String
    var run: (() -> Void)? = nil
    var id: String { label }
}

struct CoachMarkEntry {
    let anchor: Anchor<CGRect>
    let label: String
    let message: String
    let actions: [CoachAction]
    let padding: CGFloat
    let corner: CGFloat
    let onClose: () -> Void
}

struct CoachMarkKey: PreferenceKey {
    static var defaultValue: CoachMarkEntry? { nil }
    /// 同时只出一个浮层：先登记的优先。
    static func reduce(value: inout CoachMarkEntry?, nextValue: () -> CoachMarkEntry?) {
        if value == nil { value = nextValue() }
    }
}

private struct CoachSizeKey: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct CoachExternalHostKey: EnvironmentKey {
    static var defaultValue: Bool { false }
}

extension EnvironmentValues {
    /// 窗口根部已经有一个宿主时置 true，页面里的宿主不再重复绘制。
    var coachMarkExternalHost: Bool {
        get { self[CoachExternalHostKey.self] }
        set { self[CoachExternalHostKey.self] = newValue }
    }
}

// MARK: - 修饰符

extension View {
    /// 把这个控件登记为引导要指的目标。`show` 为 false 时不登记。
    func coachTarget(_ show: Bool, label: String = "引导", message: String, actions: [CoachAction],
                     padding: CGFloat = 8, corner: CGFloat = 12, onClose: @escaping () -> Void) -> some View {
        anchorPreference(key: CoachMarkKey.self, value: .bounds) { anchor in
            show ? CoachMarkEntry(anchor: anchor, label: label, message: message, actions: actions, padding: padding, corner: corner, onClose: onClose) : nil
        }
    }

    /// 在这一层画蒙层和浮层；同时同步「新手引导」开关（管理端 `ONBOARDING_ENABLED`）。
    func coachMarkHost() -> some View { modifier(CoachMarkHost()) }
}

private struct CoachMarkHost: ViewModifier {
    @Environment(\.coachMarkExternalHost) private var external
    @Environment(SessionStore.self) private var session

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(CoachMarkKey.self) { entry in
                if !external { CoachMarkLayer(entry: entry) }
            }
            .task { await CoachGuide.shared.refresh(api: session.api) }
    }
}

// MARK: - 蒙层与浮层

struct CoachMarkLayer: View {
    let entry: CoachMarkEntry?
    @State private var cardSize: CGSize = .zero

    private static let dim = Color.black.opacity(0.42)
    private static let border = Color(hex: 0xE7E5DE)
    private static let edge: CGFloat = 12
    private static let gap: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            if let entry {
                let bounds = CGRect(origin: .zero, size: proxy.size)
                let target = proxy[entry.anchor]
                let hole = target.insetBy(dx: -entry.padding, dy: -entry.padding)
                // 目标不在这一屏里（滚出去了）就不出，和 Web 一致
                if hole.intersects(bounds), bounds.width > 0 {
                    layer(entry, target: target, hole: hole, bounds: bounds)
                }
            }
        }
    }

    @ViewBuilder
    private func layer(_ entry: CoachMarkEntry, target: CGRect, hole: CGRect, bounds: CGRect) -> some View {
        let shade = Path { path in
            path.addRect(bounds)
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: entry.corner, height: entry.corner))
        }
        let size = cardSize
        let fitsBelow = hole.maxY + Self.gap + size.height <= bounds.maxY - Self.edge
        let fitsAbove = hole.minY - Self.gap - size.height >= Self.edge
        let below = fitsBelow || !fitsAbove
        let rawY = below ? hole.maxY + Self.gap : hole.minY - Self.gap - size.height
        let y = min(max(rawY, Self.edge), max(Self.edge, bounds.maxY - Self.edge - size.height))
        let x = min(max(target.minX, Self.edge), max(Self.edge, bounds.maxX - Self.edge - size.width))
        let arrowCenter = min(target.midX, target.minX + 37.5) - x
        let arrow = min(max(arrowCenter, 24), max(24, size.width - 24))

        ZStack(alignment: .topLeading) {
            shade.fill(Self.dim, style: FillStyle(eoFill: true))
                .contentShape(shade, eoFill: true)
                .onTapGesture { entry.onClose() }
                .accessibilityHidden(true)
            card(entry, below: below, arrow: arrow)
                .fixedSize()
                .background(GeometryReader { g in Color.clear.preference(key: CoachSizeKey.self, value: g.size) })
                .offset(x: x, y: y)
                .opacity(size == .zero ? 0 : 1)
            // Esc 关闭
            Button("") { entry.onClose() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .onPreferenceChange(CoachSizeKey.self) { cardSize = $0 }
    }

    /// 浮层卡片：宽 hug 内容，圆角 14，白底 + #E7E5DE 描边；左边 28 的山茶花，右边文字 14 / 行距 23，下面 33 高胶囊按钮与文字左对齐。
    private func card(_ entry: CoachMarkEntry, below: Bool, arrow: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                CoachMarkLogo().frame(width: 28, height: 28).padding(.top, 2)
                Text(verbatim: entry.message).font(V3.sans(14)).foregroundStyle(V3.txt).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                ForEach(entry.actions) { action in
                    Button {
                        entry.onClose()
                        action.run?()
                    } label: {
                        Text(verbatim: action.label).font(V3.sans(13)).foregroundStyle(V3.txt).lineLimit(1)
                            .padding(.horizontal, 14.5).frame(height: 33)
                            .background(Capsule().fill(.white))
                            .overlay(Capsule().strokeBorder(Color(hex: 0xD6D4CC)))
                            .contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(.leading, 42)
        }
        .padding(.horizontal, 19).padding(.top, 16).padding(.bottom, 16)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Self.border))
        // 尖角：11 的方块转 45°，压在卡片后面，只露出朝向目标的一小角
        .background(alignment: below ? .topLeading : .bottomLeading) {
            Rectangle().fill(.white).overlay(Rectangle().strokeBorder(Self.border)).frame(width: 11, height: 11)
                .rotationEffect(.degrees(45)).offset(x: arrow - 5.5, y: below ? -2.5 : 2.5)
        }
        .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.label)
    }
}

/// 浮层里的职绘标记（Resources/Branding/mark.png）。
private struct CoachMarkLogo: View {
    private static let image: NSImage? = Bundle.module.url(forResource: "mark", withExtension: "png", subdirectory: "Branding").flatMap(NSImage.init(contentsOf:))
    var body: some View {
        Group {
            if let image = Self.image { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
            else { Circle().fill(V3.orange.opacity(0.85)) }
        }.accessibilityHidden(true)
    }
}

// MARK: - 「看过没有」与引导开关

/// Web `scenarioGuide.ts`：每个账号、每一步只出一次，点按钮或蒙层后记下；管理端关掉新手引导时一律不出。
/// Web 存浏览器 localStorage（`drawoffer.scenario.v1:<userId>` 一组已看过的步骤），这里同样按账号存 UserDefaults。
@MainActor @Observable
final class CoachGuide {
    static let shared = CoachGuide()

    /// 管理端「新手引导」开关（`GET /api/auth/capabilities` 的 `onboarding_enabled`）；读到之前和读取失败时都不出引导。
    private(set) var enabled = false
    /// 只用来让读 `isOpen` 的视图在记下「看过」后刷新。
    private(set) var revision = 0
    /// 「对着这个岗位练一场」带给面试设置页的岗位（一次性，设置页读走就清）。
    var pendingMockApplication: String?

    @ObservationIgnored private var checkedAt: Date?
    @ObservationIgnored private var fetching = false

    private static let recheck: TimeInterval = 5 * 60
    private static func key(_ user: String) -> String { "drawoffer.scenario.v1:" + user }

    func isSeen(_ id: String, user: String) -> Bool {
        _ = revision
        return UserDefaults.standard.stringArray(forKey: Self.key(user))?.contains(id) ?? false
    }

    func isOpen(_ id: String, user: String) -> Bool { !user.isEmpty && enabled && !isSeen(id, user: user) }

    func markSeen(_ id: String, user: String) {
        guard !user.isEmpty else { return }
        var ids = UserDefaults.standard.stringArray(forKey: Self.key(user)) ?? []
        guard !ids.contains(id) else { return }
        ids.append(id)
        UserDefaults.standard.set(ids, forKey: Self.key(user))
        revision += 1
    }

    /// 已读到开关后 5 分钟内不重复读；读取失败先隐藏，下次再试。
    func refresh(api: any APIClient) async {
        if enabled, let checkedAt, Date().timeIntervalSince(checkedAt) < Self.recheck { return }
        guard !fetching else { return }
        guard let client = api as? HTTPAPIClient else { enabled = true; checkedAt = Date(); return }
        fetching = true
        defer { fetching = false }
        var request = URLRequest(url: client.origin.appending(path: "/api/auth/capabilities"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let flag = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["onboarding_enabled"] as? Bool else { enabled = false; return }
            enabled = flag
            checkedAt = Date()
        } catch {
            if !Task.isCancelled { enabled = false }
        }
    }

    /// 模拟面试设置页用：取走并清掉从岗位广场带来的岗位。
    func takePendingMockApplication() -> String? {
        defer { pendingMockApplication = nil }
        return pendingMockApplication
    }

    /// 首页「第一份报告看过」：与 `HomeMemoryView` 同一个键（Web `FIRST_REPORT_SEEN`，打开过任意一份报告就记下）。
    static func firstReportSeenKey(_ user: String) -> String { "home.firstReportSeen.\(user)" }
}

/// 某个账号的某一步引导：页面再加自己的业务条件。
@MainActor
struct CoachSlot {
    let id: String
    let user: String
    var open: Bool { CoachGuide.shared.isOpen(id, user: user) }
    func dismiss() { CoachGuide.shared.markSeen(id, user: user) }
}

extension SessionStore {
    /// 当前登录账号 id；未登录为空串。
    var coachUser: String { if case .signedIn(let user) = phase { return user.id }; return "" }
}
