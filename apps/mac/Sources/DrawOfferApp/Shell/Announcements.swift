import AppKit
import DrawOfferCore
import SwiftUI

/// 站内消息点开后去哪（服务端关闭 `MEMORY_NUDGES_ENABLED` 时整组接口 404，客户端当作没有消息）。
extension InboxMessage {
    /// 站内路径对应的原生栏目；对不上的交给浏览器打开 Web 同一页面。反馈送的积分打开额度弹窗的积分页。
    var jump: WorkspaceRouter.Jump? {
        if opensCredits { return .credits }
        guard let link = safeLink, let parts = URLComponents(string: link) else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        guard let head = path.first else { return .section(.home) }
        switch head {
        case "mock-interviews":
            if path.count >= 2 { return path[1] == "new" ? .mock(nil) : .mockSession(path[1]) }
            return .section(.mock)
        case "interviews": return .section(.schedule)
        case "assistant", "home": return .section(.home)
        case "career":
            if path.count >= 3, path[1] == "applications" { return .application(path[2]) }
            // 面试复盘 `/career/reviews?session=…&application=…`：进这条投递的详情
            if path.count >= 2, path[1] == "reviews", let id = parts.queryItems?.first(where: { $0.name == "application" })?.value, !id.isEmpty { return .application(id) }
            return .section(.jobs)
        case "resumes":
            if path.count >= 3, path[2] == "edit" { return .editResume(path[1]) }
            return .section(.resumes)
        case "templates": return .section(.templates)
        case "datasets": return .section(.datasets)
        case "account": return .section(.account)
        case "feedback": return .feedback
        default: return nil
        }
    }
}

/// 公告与站内消息，对齐 Web `features/announcements/AnnouncementCenter.tsx`：铃铛未读点（公告未读 + 消息未读）、
/// 一个列表按时间从新到旧混排（读取中/失败/空态）、悬停换出 × 删除、公告详情弹窗（分页点、下一条/知道了）；
/// 打开列表时公告和消息全部标为已读，自动弹出重要公告时只读公告。
@MainActor @Observable
final class AnnouncementCenter {
    enum Status { case idle, loading, ready, error }
    private(set) var items: [Announcement] = []
    private(set) var messages: [InboxMessage] = []
    private(set) var unreadCount = 0
    private(set) var status: Status = .idle
    /// 列表打开那一刻还未读的条目（消息记为 `n:<id>`），蓝点只在这次查看里保留。
    private(set) var freshIDs: Set<String> = []
    var detail: (ids: [String], index: Int)?
    private var fetchedAt = Date.distantPast
    private var owner = ""

    nonisolated static func messageKey(_ id: String) -> String { "n:" + id }

    func reset(account: String) {
        guard owner != account else { return }
        owner = account; items = []; messages = []; unreadCount = 0; status = .idle; freshIDs = []; detail = nil; fetchedAt = .distantPast
    }

    /// 60 秒内的再次刷新复用上次结果（与 Web `REFRESH_INTERVAL_MS` 一致）。
    func refresh(api: any APIClient, force: Bool = false) async {
        guard !owner.isEmpty else { return }
        if !force, status == .ready, Date().timeIntervalSince(fetchedAt) < 60 { return }
        let account = owner
        status = .loading
        do {
            async let announcements = api.careerRequest(path: "/api/announcements", method: "GET", query: [:], body: nil)
            async let inbox = Self.loadMessages(api: api)
            let list = AnnouncementList(json: try await announcements)
            let (messageItems, messageUnread) = try await inbox
            guard account == owner else { return }
            items = list.items; messages = messageItems
            unreadCount = list.unreadCount + messageUnread; status = .ready
        } catch {
            guard account == owner else { return }
            status = .error
        }
        fetchedAt = Date()
    }

    /// 站内消息；服务端关掉时（404）没有消息，不算失败。
    private static func loadMessages(api: any APIClient) async throws -> ([InboxMessage], Int) {
        do {
            let json = try await api.careerRequest(path: "/api/notifications", method: "GET", query: [:], body: nil)
            let count: Int = if case .number(let value) = json["unreadCount"] { Int(value) } else { 0 }
            return ((json["items"]?.items ?? []).map(InboxMessage.init), count)
        } catch APIError.server(status: 404, code: _) {
            return ([], 0)
        }
    }

    private static func read(_ item: Announcement) -> Announcement {
        var json: [String: JSONValue] = ["id": .string(item.id), "level": .string(item.important ? "important" : "normal"),
            "category": .string(item.category), "title": .string(item.title), "body": .string(item.body), "read": .bool(true)]
        if let date = item.publishedAt { json["publishedAt"] = .string(ISO8601DateFormatter().string(from: date)) }
        return Announcement(json: .object(json))
    }

    private func recount() { unreadCount = items.filter { !$0.read }.count + messages.filter { !$0.read }.count }

    /// 先在本地标为已读；请求失败时下次刷新会带回未读状态。
    func markAllRead(api: any APIClient) {
        guard unreadCount > 0 else { return }
        let announcementsUnread = items.contains { !$0.read }, messagesUnread = messages.contains { !$0.read }
        unreadCount = 0
        items = items.map(Self.read)
        messages = messages.map { var message = $0; message.read = true; return message }
        if announcementsUnread { Task { _ = try? await api.careerRequest(path: "/api/announcements/read-all", method: "POST", query: [:], body: nil) } }
        if messagesUnread { Task { _ = try? await api.careerRequest(path: "/api/notifications/read-all", method: "POST", query: [:], body: nil) } }
    }

    func viewList(api: any APIClient) {
        freshIDs = Set(items.filter { !$0.read }.map(\.id) + messages.filter { !$0.read }.map { Self.messageKey($0.id) })
        markAllRead(api: api)
    }

    /// 有未读的重要公告时自动打开详情，从重要的开始（接口已把重要排在前面），可往后翻其余未读。
    /// 这里只读公告，未读消息继续点亮铃铛。
    func autoOpenImportant(api: any APIClient) {
        let unread = items.filter { !$0.read }
        guard detail == nil, unread.contains(where: \.important) else { return }
        detail = (unread.map(\.id), 0)
        items = items.map(Self.read)
        recount()
        Task { _ = try? await api.careerRequest(path: "/api/announcements/read-all", method: "POST", query: [:], body: nil) }
    }

    /// 点开一条消息：记一次打开（服务端同时标已读），返回它要去的地方。
    func openMessage(_ message: InboxMessage, api: any APIClient) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index].read = true; recount() }
        Task { _ = try? await api.careerRequest(path: "/api/notifications/\(message.id)/open", method: "POST", query: [:], body: nil) }
    }

    /// 从铃铛删掉一条：消息真删除，公告只对本人隐藏。乐观删除，失败时下次刷新会带回来。
    func removeAnnouncement(_ id: String, api: any APIClient) {
        items.removeAll { $0.id == id }; recount()
        Task { _ = try? await api.careerRequest(path: "/api/announcements/\(id)", method: "DELETE", query: [:], body: nil) }
    }

    func removeMessage(_ id: String, api: any APIClient) {
        messages.removeAll { $0.id == id }; recount()
        Task { _ = try? await api.careerRequest(path: "/api/notifications/\(id)", method: "DELETE", query: [:], body: nil) }
    }
}

/// 侧栏右上角铃铛（12 页 03 · Announcement/Bell 90:4512）：28×28、圆角 7；悬停或展开时 #E4E4E0 底；
/// 有未读时右上角 8px 蓝点，外圈 1.5px 窗口底色描边。
struct AnnouncementBell: View {
    @Environment(SessionStore.self) private var session
    @Environment(AnnouncementCenter.self) private var center
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button {
            if open { open = false; return }
            open = true
            Task { await center.refresh(api: session.api, force: true); center.viewList(api: session.api) }
        } label: {
            SideIconView(icon: .bell)
                .foregroundStyle(open || hover ? V3.txt : V3.sub).frame(width: 28, height: 28)
                .background(open || hover ? V3.cl : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topTrailing) {
                    // 10.02 / 06：未读时铃铛右上角橙点，外圈一道侧栏底色把它和铃铛分开
                    if center.unreadCount > 0 {
                        Circle().fill(Color(hex: 0xE8791A)).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(WorkspaceSidebar.background, lineWidth: 1.5)).padding(3)
                    }
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }
            .help("通知").accessibilityLabel(center.unreadCount > 0 ? "通知，\(center.unreadCount > 99 ? "99+" : String(center.unreadCount)) 条未读" : "通知")
            // 10.02：通知弹层从铃铛下方展开
            .popover(isPresented: $open, arrowEdge: .bottom) {
                NoticeCenterList(pick: { ids, index in open = false; center.detail = (ids, index) },
                                 pickMessage: { message in open = false; openMessage(message) })
            }
    }

    /// Web `openMessage`：记一次打开，再去消息指向的页面；原生没有对应栏目的交给浏览器。
    private func openMessage(_ message: InboxMessage) {
        center.openMessage(message, api: session.api)
        if let jump = message.jump, let router { router.jump(jump) }
        else if let link = message.safeLink { WebBridge.open(link, api: session.api) }
    }
}

/// 列表里的一条：公告或站内消息，按时间混排。
private enum NoticeEntry: Identifiable {
    case announcement(Announcement), message(InboxMessage)
    var id: String {
        switch self {
        case .announcement(let item): item.id
        case .message(let item): AnnouncementCenter.messageKey(item.id)
        }
    }
    var at: Date? {
        switch self {
        case .announcement(let item): item.publishedAt
        case .message(let item): item.createdAt
        }
    }
}

/// 通知浮层（12 页 04 · 通知中心 21.1 / 21.2）：360 宽，头部「通知」17 衬线 + 「N 条未读」；公告与站内消息按时间从新到旧
/// 排成一列，不分组、无分隔线、悬停不加底色，只把右上角时间换成 × 删除。
private struct NoticeCenterList: View {
    @Environment(SessionStore.self) private var session
    @Environment(AnnouncementCenter.self) private var center
    let pick: ([String], Int) -> Void
    let pickMessage: (InboxMessage) -> Void

    var body: some View {
        let list = (center.items.map(NoticeEntry.announcement) + center.messages.map(NoticeEntry.message))
            .sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("通知").font(V3.serif(17)).foregroundStyle(V3.txt)
                let fresh = list.filter { center.freshIDs.contains($0.id) }.count
                if fresh > 0 { Text("\(fresh) 条未读").font(V3.sans(11.5)).foregroundStyle(V3Skeleton.faint) }
            }.frame(height: 24).padding(.horizontal, 24).padding(.top, 20)
            if list.isEmpty {
                switch center.status {
                case .ready, .error:
                    VStack(spacing: 8) {
                        Text(center.status == .error ? "通知暂时无法读取" : "暂时没有通知").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                        Text(center.status == .error ? "稍后再打开试试" : "模拟面试出报告、面试前的提醒和产品更新，都会出现在这里。")
                            .font(V3.sans(12.5)).foregroundStyle(V3Skeleton.faint).lineSpacing(5).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 28)
                default:
                    // 15 页 03「加载中 · 公告列表」：三条占位，标题与时间一行、摘要一行
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(0..<3, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { V3Skeleton(width: 190, height: 10); Spacer(); V3Skeleton(width: 72, height: 9) }
                                V3Skeleton(height: 9)
                            }
                        }
                    }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 26)
                        .accessibilityElement().accessibilityLabel("正在读取通知…")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(list) { entry in row(entry) }
                    }.padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 12)
                }.frame(maxHeight: min(520, (NSApp.mainWindow?.frame.height ?? 900) - 120)).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(width: 360)
    }

    @ViewBuilder private func row(_ entry: NoticeEntry) -> some View {
        let fresh = center.freshIDs.contains(entry.id)
        switch entry {
        case .announcement(let item):
            NoticeCenterRow(fresh: fresh, important: item.important, title: item.title, time: NoticeCenterRow.time(item.publishedAt),
                            summary: item.summary, category: item.categoryLabel, tone: V3Skeleton.faint, action: "查看全文", arrow: false,
                            open: { let ids = center.items.map(\.id); pick(ids, ids.firstIndex(of: item.id) ?? 0) },
                            remove: { center.removeAnnouncement(item.id, api: session.api) })
        case .message(let item):
            let tone = item.tone == "blue" ? V3.blue : item.tone == "orange" ? Color(hex: 0xC46C26) : V3Skeleton.faint
            NoticeCenterRow(fresh: fresh, important: false, title: item.title, time: NoticeCenterRow.time(item.createdAt),
                            summary: item.body, category: item.categoryLabel, tone: tone, action: item.action, arrow: true,
                            open: { pickMessage(item) },
                            remove: { center.removeMessage(item.id, api: session.api) })
        }
    }
}

/// 通知条目（12 页 04 · Notification/Item 90:4532）：未读蓝点 + 14 中粗标题、右上「月 日 时:分」；两行 13 摘要；
/// 底部左侧分类、右侧蓝色动作文字（公告「查看全文」，消息「查看报告 →」「去准备 →」等）。整条可点；
/// 悬停或键盘聚焦时右上角时间换成 ×，点 × 删除这一条，不加底色。
private struct NoticeCenterRow: View {
    let fresh: Bool
    let important: Bool
    let title: String
    let time: String
    let summary: String
    let category: String
    let tone: Color
    let action: String?
    let arrow: Bool
    let open: () -> Void
    let remove: () -> Void
    @State private var hover = false
    @State private var closeHover = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if fresh { Circle().fill(V3.blue).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }.accessibilityLabel("新") }
                    if important { NoticeImportantChip() }
                    Text(title).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(time).font(V3.sans(11)).foregroundStyle(V3Skeleton.faint).fixedSize().opacity(hover ? 0 : 1)
                }.frame(height: 20)
                Text(summary).font(V3.sans(13)).foregroundStyle(V3.sub).lineLimit(2).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                HStack {
                    Text(category).font(V3.sans(11, weight: .medium)).foregroundStyle(tone)
                    Spacer()
                    if let action {
                        HStack(spacing: 3) {
                            Text(action).font(V3.sans(12))
                            if arrow { Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium)) }
                        }.foregroundStyle(V3.blue)
                    }
                }.frame(height: 16).padding(.top, 5)
            }.padding(.vertical, 6.5).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                if hover {
                    Button(action: remove) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(closeHover ? V3.txt : V3Skeleton.faint).frame(width: 21, height: 21).contentShape(Rectangle())
                    }.buttonStyle(.plain).onHover { closeHover = $0 }
                        .help("删除这条通知").accessibilityLabel("删除这条通知").padding(.top, 9)
                }
            }
            .onHover { hover = $0 }
            .accessibilityAction(named: "删除这条通知", remove)
    }
    /// 「11 月 13 日 14:32」；不是今年的再加年份。
    static func time(_ date: Date?) -> String {
        guard let date else { return "" }
        let c = Beijing.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let core = String(format: "%d 月 %d 日 %02d:%02d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        return c.year == Beijing.calendar.component(.year, from: Date()) ? core : "\(c.year ?? 0) 年 " + core
    }
}

/// 「重要」标签（Web `.ann-chip-important`）：浅橙底、橙字。
private struct NoticeImportantChip: View {
    var body: some View {
        Text("重要").font(V3.sans(12, weight: .medium)).foregroundStyle(Color(hex: 0xB86014))
            .padding(.horizontal, 7).frame(height: 20).background(Color(hex: 0xFDECDF), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// 公告详情（5:32 · 06.1 / 06.2，Web `AnnouncementDialogHost` 680×440）：一行灰字「分类 · 日期」（重要公告前加橙色标签）
/// 与右上角 ×，下面 28 号粗体标题和 15 号正文，正文在弹窗里滚动；底部一道细线，左侧「1 / 3」，右侧墨黑胶囊「下一条 →」或「知道了」。
struct AnnouncementDetailSheet: View {
    @Environment(AnnouncementCenter.self) private var center

    var body: some View {
        let byID = Dictionary(uniqueKeysWithValues: center.items.map { ($0.id, $0) })
        let ids = (center.detail?.ids ?? []).filter { byID[$0] != nil }
        let currentID = center.detail.flatMap { $0.ids.indices.contains($0.index) ? $0.ids[$0.index] : nil }
        let index = currentID.flatMap { ids.firstIndex(of: $0) } ?? -1
        if let currentID, let item = byID[currentID] {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if item.important { NoticeImportantChip() }
                    Text(item.metaText).font(V3.sans(13)).foregroundStyle(V3Skeleton.faint)
                    Spacer(minLength: 12)
                    Button { center.detail = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .regular)).frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(NoticeCloseStyle()).accessibilityLabel("关闭").padding(.trailing, -8)
                }.frame(height: 20).padding(.top, 32).padding(.horizontal, 40)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(item.title).font(V3.sans(28, weight: .bold)).foregroundStyle(V3.txt).lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                        NativeMarkdownView(source: item.body, size: 15, line: 26).foregroundStyle(Color(hex: 0x3D3D39))
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 40).padding(.top, 10).padding(.bottom, 8)
                }.scrollIndicators(.automatic).frame(maxHeight: .infinity)
                HStack(spacing: 10) {
                    if ids.count > 1 {
                        Text("\(index + 1) / \(ids.count)").font(V3.sans(13)).foregroundStyle(V3Skeleton.faint)
                            .accessibilityLabel("第 \(index + 1) 条，共 \(ids.count) 条")
                    }
                    Spacer()
                    if index < ids.count - 1 {
                        Button { goTo(index + 1, ids: ids) } label: { HStack(spacing: 6) { Text("下一条"); Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)) } }
                            .buttonStyle(AccountPillButtonStyle(kind: .dark, width: 86, height: 35)).keyboardShortcut(.defaultAction)
                    } else {
                        Button("知道了") { center.detail = nil }.buttonStyle(AccountPillButtonStyle(kind: .dark, width: 86, height: 35)).keyboardShortcut(.defaultAction)
                    }
                }.padding(.leading, 40).padding(.trailing, 32).padding(.top, 16).padding(.bottom, 20)
                    .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xF1F1EF)).frame(height: 1) }
            }
            .frame(width: 680, height: min(440, max(300, (NSApp.mainWindow?.frame.height ?? 900) - 32)))
            .background { Button("") { center.detail = nil }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
        } else {
            Color.clear.frame(width: 1, height: 1).onAppear { center.detail = nil }
        }
    }

    private func goTo(_ position: Int, ids: [String]) {
        guard let detail = center.detail, ids.indices.contains(position), let target = detail.ids.firstIndex(of: ids[position]) else { return }
        center.detail = (detail.ids, target)
    }
}

/// `.ann-dialog-close`：28 方块，悬停浅灰底、字转深。
private struct NoticeCloseStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(hover ? V3.txt : V3.fnt)
            .background(hover || configuration.isPressed ? Color(hex: 0xF1F1EF) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .onHover { hover = $0 }
    }
}
