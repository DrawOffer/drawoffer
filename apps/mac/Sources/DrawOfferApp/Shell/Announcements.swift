import AppKit
import DrawOfferCore
import SwiftUI

/// 站内消息（`GET /api/notifications`，Web `UserNotification`）：面试提醒、复盘、记忆提示、后台任务结果。
/// 服务端关闭 `MEMORY_NUDGES_ENABLED` 时整组接口 404，客户端当作没有消息。
struct InboxMessage: Identifiable, Equatable {
    let id: String
    let category: String
    let title: String
    let body: String
    let link: String
    var read: Bool
    let createdAt: Date?

    init(json: JSONValue) {
        id = json.text("id"); category = json.text("category"); title = json.text("title")
        body = json.text("body"); link = json.text("link"); read = json["read"]?.bool ?? false
        createdAt = Self.date(json.text("createdAt"))
    }

    /// 与 Web `notificationCategoryLabel` 一致。
    var categoryLabel: String {
        switch category {
        case "interview": "面试提醒"
        case "review": "面试复盘"
        case "peak", "insight": "长期记忆"
        case "idle": "练习提醒"
        case "task": "处理结果"
        default: "消息"
        }
    }

    /// 只认站内单斜杠路径（Web `safeNotificationLink`），不接受协议或 `//host`。
    var safeLink: String? {
        let value = link.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("/"), !value.hasPrefix("//"), !value.hasPrefix("/\\") else { return nil }
        return value
    }

    /// 从用户角度说点开去哪（Web `messageAction`）；没有可去的页面时不显示。
    var action: String? {
        guard let link = safeLink else { return nil }
        switch category {
        case "task": return link.range(of: #"/report(?:[?#]|$)"#, options: .regularExpression) != nil ? "查看报告" : "去看看"
        case "interview": return "去准备"
        case "review": return "去复盘"
        default: return "去看看"
        }
    }

    /// 站内路径对应的原生栏目；对不上的交给浏览器打开 Web 同一页面。
    var jump: WorkspaceRouter.Jump? {
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
            return .section(.jobs)
        case "resumes":
            if path.count >= 3, path[2] == "edit" { return .editResume(path[1]) }
            return .section(.resumes)
        case "templates": return .section(.templates)
        case "datasets": return .section(.datasets)
        case "account": return .section(.account)
        default: return nil
        }
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
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
            Image(systemName: "bell").font(.system(size: 14))
                .foregroundStyle(open || hover ? V3.txt : V3.sub).frame(width: 28, height: 28)
                .background(open || hover ? V3.cl : .clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topTrailing) {
                    if center.unreadCount > 0 {
                        Circle().fill(V3.blue).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color(hex: 0xF1F1EF), lineWidth: 1.5)).padding(4)
                    }
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }
            .help("通知").accessibilityLabel(center.unreadCount > 0 ? "通知，有未读" : "通知")
            .popover(isPresented: $open, arrowEdge: .trailing) {
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
                        if center.status != .error { Image(systemName: "bell").font(.system(size: 20)).foregroundStyle(Color(hex: 0xB3B3AD)).padding(.bottom, 2) }
                        Text(center.status == .error ? "通知暂时无法读取" : "暂时没有通知").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                        Text(center.status == .error ? "稍后再打开试试" : "模拟面试出报告、面试前的提醒和产品更新，都会出现在这里。")
                            .font(V3.sans(12)).foregroundStyle(V3Skeleton.faint).lineSpacing(4).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
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
            // 处理结果蓝、面试提醒橙，其余灰（Web `.ann-item-category[data-tone]`）
            let tone = item.category == "task" ? V3.blue : item.category == "interview" ? Color(hex: 0xC46C26) : V3Skeleton.faint
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
                }.frame(height: 16).padding(.top, 8)
            }.padding(.vertical, 10).contentShape(Rectangle())
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

private struct NoticeImportantChip: View {
    var body: some View {
        Text("重要").font(V3.sans(11, weight: .medium)).foregroundStyle(Color(hex: 0xA13A28))
            .padding(.horizontal, 6).frame(height: 18).background(Color(hex: 0xFAEDEA), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// 公告详情（12 页 02 · 方向 A「信笺头图」，已选）：520 宽；顶部按分类着色的信笺带（白色 44 图标块 + 分类名 + 发布日期），
/// 下面 22 号衬线标题与 14 号正文；底部左侧分页点（当前为 18 宽的色条），右侧 Bordered「关闭」+ 墨黑「下一条 →」/「知道了」。
struct AnnouncementDetailSheet: View {
    @Environment(AnnouncementCenter.self) private var center

    var body: some View {
        let byID = Dictionary(uniqueKeysWithValues: center.items.map { ($0.id, $0) })
        let ids = (center.detail?.ids ?? []).filter { byID[$0] != nil }
        let currentID = center.detail.flatMap { $0.ids.indices.contains($0.index) ? $0.ids[$0.index] : nil }
        let index = currentID.flatMap { ids.firstIndex(of: $0) } ?? -1
        if let currentID, let item = byID[currentID] {
            let tone = NoticeTone(category: item.category)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: item.categorySymbol).font(.system(size: 18)).foregroundStyle(tone.fg).frame(width: 44, height: 44)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.categoryLabel).font(V3.sans(13, weight: .medium)).foregroundStyle(tone.label)
                            if item.important { NoticeImportantChip() }
                        }.frame(height: 20)
                        if !item.dateText.isEmpty { Text("\(item.dateText)发布").font(V3.sans(12)).foregroundStyle(V3.sub) }
                    }
                    Spacer()
                }.padding(.leading, 32).padding(.trailing, 24).padding(.vertical, 22).background(tone.soft)
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.title).font(V3.serif(22)).foregroundStyle(V3.txt).fixedSize(horizontal: false, vertical: true)
                    ScrollView { NativeMarkdownView(source: item.body, size: 14, line: 24).foregroundStyle(Color(hex: 0x3D3D39)).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 340).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 32).padding(.top, 28)
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        if ids.count > 1 {
                            ForEach(Array(ids.enumerated()), id: \.element) { position, _ in
                                Button { goTo(position, ids: ids) } label: {
                                    Capsule().fill(position == index ? tone.fg : Color(hex: 0xD6D6D1)).frame(width: position == index ? 18 : 6, height: 6)
                                }.buttonStyle(.plain).accessibilityLabel("第 \(position + 1) 条，共 \(ids.count) 条")
                            }
                        }
                    }.animation(.easeOut(duration: 0.18), value: index)
                    Spacer()
                    if index < ids.count - 1 {
                        Button("关闭") { center.detail = nil }.buttonStyle(V3ButtonStyle(kind: .ghost))
                        Button { goTo(index + 1, ids: ids) } label: { Text("下一条"); Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)) }
                            .buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).keyboardShortcut(.defaultAction)
                    } else {
                        Button("知道了") { center.detail = nil }.buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).keyboardShortcut(.defaultAction)
                    }
                }.padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 26)
            }
            .frame(width: 520)
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

/// 公告分类配色（与 Web `.ann-card[data-category]` 一致）：产品更新蓝、活动福利紫、服务通知橙。
private struct NoticeTone {
    let fg: Color, label: Color, soft: Color
    init(category: String) {
        switch category {
        case "product_update": fg = V3.blue; label = V3.link; soft = V3.blueSoft
        case "promotion": fg = V3.purple; label = Color(hex: 0x6F45A8); soft = V3.purpleSoft
        default: fg = V3.orange; label = Color(hex: 0xB8681C); soft = V3.orangeSoft
        }
    }
}
