import AppKit
import DrawOfferCore
import SwiftUI

/// 工作区侧栏，按 macOS 设计稿第 17 页「macOS 独立风格」（Figma NuYmNOz50Af48mtAaj1kZA 105:578，2026-11-16）：
/// 不放 logo；顶行是红绿灯 + 侧栏开关、右侧铃铛；图标导航；「最近对话」右侧「新对话」入口（02B·01 方案 A）；
/// 底部账户行（头像、名字 · 会员档位、上下箭头）上方一条细线。
struct WorkspaceSidebar: View {
    @Environment(SessionStore.self) private var session
    @Binding var selection: WorkspaceSection?
    let activeChatID: String?
    let sessions: AgentSessionsModel
    let openChat: (String) -> Void
    let newChat: () -> Void
    let requestLogin: () -> Void
    let openPlans: () -> Void
    let openCareerProfile: () -> Void
    let chatDeleted: (String) -> Void
    let toggleSidebar: () -> Void

    static let width: CGFloat = 240
    static let background = Color(hex: 0xF6F6F4)

    @State private var collapsed: Set<String> = []
    @State private var showAll = false
    @State private var userMenu = false
    @State private var userHover = false
    @State private var tier: String?

    private var user: User? {
        if case .signedIn(let user) = session.phase { return user }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶行 32 高，开关和铃铛与红绿灯同一水平中线（y=16）；左 88 起是侧栏开关，右侧只有铃铛
            HStack(spacing: 0) {
                SidebarToggleButton(action: toggleSidebar).padding(.leading, 88)
                Spacer()
                AnnouncementBell().padding(.trailing, 12)
            }.frame(height: 32).padding(.top, 0).padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(WorkspaceSection.sidebar) { section in navRow(section) }
                    }
                    if user != nil {
                        group("pin")
                        group("recent")
                    } else {
                        groupHeader("recent", label: "最近对话")
                        muted("登录后读取对话")
                    }
                }.padding(.horizontal, 8)
            }.scrollIndicators(.never)
            Spacer(minLength: 8)
            Rectangle().fill(.black.opacity(0.07)).frame(height: 1)
            userEntry.padding(.horizontal, 8).padding(.vertical, 8)
        }
        .frame(width: Self.width)
        .background(Self.background)
        .task(id: user?.id ?? "") { await loadTier() }
    }

    private func loadTier() async {
        guard user != nil else { tier = nil; return }
        if let result = try? await session.api.careerRequest(path: "/api/billing/summary", method: "GET", query: [:], body: nil) {
            tier = BillingSummary(json: result).tierLabel
        }
    }

    /// 导航行：224×32、圆角 8；图标 17 在左 10，文字 14 在左 38；选中 7% 黑底、文字 Medium。
    private func navRow(_ section: WorkspaceSection) -> some View {
        let active = selection == section && (section != .home || activeChatID == nil)
        return Button { selection = section } label: {
            HStack(spacing: 11) {
                SideIconView(icon: section.sidebarIcon)
                    .foregroundStyle(Color(hex: 0x55554F))
                Text(section.title).font(.system(size: 14, weight: active ? .medium : .regular)).foregroundStyle(Color(hex: 0x1D1D1B))
                Spacer(minLength: 0)
            }.padding(.leading, 10).frame(height: 32).contentShape(Rectangle())
        }.buttonStyle(SideRowStyle(active: active)).accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder private func group(_ key: String) -> some View {
        let label = key == "pin" ? "置顶" : "最近对话"
        let items = sessions.sessions.filter { ($0["pinned"]?.bool == true) == (key == "pin") }
        if key == "recent" || !items.isEmpty {
            groupHeader(key, label: label)
            if !collapsed.contains(key) {
                VStack(alignment: .leading, spacing: 2) {
                    switch sessions.status {
                    case .loading, .idle: muted("正在读取对话…")
                    case .error: muted("对话列表暂时无法读取")
                    case .ready:
                        if items.isEmpty { muted(key == "pin" ? "还没有置顶对话" : "还没有对话") }
                        let limit = key == "pin" || showAll ? 30 : 5
                        ForEach(Array(items.prefix(limit)), id: \.self) { item in
                            SessionRow(item: item, active: selection == .assistant && activeChatID == item.text("id"),
                                       sessions: sessions, open: { openChat(item.text("id")) },
                                       deleted: { chatDeleted(item.text("id")) })
                        }
                        if key == "recent" && items.count > 5 {
                            Button(showAll ? "收起" : "查看全部") { showAll.toggle() }
                                .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(Color(hex: 0x8A8A82))
                                .padding(.leading, 10).frame(height: 28)
                        }
                    }
                }
            }
        }
    }

    /// 分组标题：12 号 #8a8a82，左 10、上 20、下 6；「最近对话」可折叠，右侧常显「新对话」（笔图标 + 文字）。
    private func groupHeader(_ key: String, label: String) -> some View {
        let isCollapsed = collapsed.contains(key)
        let toggle = { if isCollapsed { collapsed.remove(key) } else { collapsed.insert(key) } }
        return HStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Text(label)
                    SideIconView(icon: .down).rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }.frame(height: 18).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(isCollapsed ? "展开\(label)" : "收起\(label)")
            Spacer()
            if key == "recent" {
                Button(action: user == nil ? requestLogin : newChat) {
                    HStack(spacing: 4) {
                        SideIconView(icon: .pen)
                        Text("新对话")
                    }.padding(.horizontal, 6).frame(height: 20).contentShape(Rectangle())
                }.buttonStyle(SideIconStyle()).help("新建对话")
            }
        }.font(.system(size: 12)).foregroundStyle(Color(hex: 0x8A8A82))
            .padding(.leading, 10).padding(.trailing, 4).padding(.top, 20).padding(.bottom, 6)
    }

    private func muted(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Color(hex: 0x8A8A82)).padding(.horizontal, 10).padding(.vertical, 4)
    }

    /// 账户行：头像 24、名字 14、「· 档位」13 灰、右侧上下箭头；点开个人菜单。
    @ViewBuilder private var userEntry: some View {
        if let user {
            Button { userMenu.toggle() } label: {
                HStack(spacing: 8) {
                    UserAvatar(user: user, size: 24)
                    Text(user.nickname.isEmpty ? (user.email ?? "我") : user.nickname).font(.system(size: 14)).foregroundStyle(V3.txt).lineLimit(1)
                    if let tier { Text("· \(tier)").font(.system(size: 13)).foregroundStyle(Color(hex: 0x8A8A82)).lineLimit(1).fixedSize() }
                    Spacer(minLength: 0)
                    SideIconView(icon: .updown).foregroundStyle(Color(hex: 0x8A8A82))
                }.padding(.horizontal, 8).frame(height: 40).contentShape(Rectangle())
                    .background(selection == .account || userHover ? .black.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .onHover { userHover = $0 }
            }.buttonStyle(.plain).accessibilityLabel("打开个人菜单，当前账号：\(user.nickname.isEmpty ? (user.email ?? "我") : user.nickname)")
                .popover(isPresented: $userMenu, arrowEdge: .top) {
                    UserMenu(user: user, openPlans: { userMenu = false; openPlans() },
                             openAccount: { userMenu = false; selection = .account },
                             openCareerProfile: { userMenu = false; openCareerProfile() },
                             close: { userMenu = false })
                }
        } else {
            Button(action: requestLogin) {
                HStack(spacing: 8) {
                    Text("我").font(.system(size: 12, weight: .medium)).foregroundStyle(.white).frame(width: 24, height: 24).background(Color(hex: 0x1D1D1B), in: Circle())
                    Text("游客模式").font(.system(size: 14)).foregroundStyle(V3.txt)
                    Text("· 登录").font(.system(size: 13)).foregroundStyle(Color(hex: 0x8A8A82))
                    Spacer(minLength: 0)
                }.padding(.horizontal, 8).frame(height: 40).contentShape(Rectangle())
                    .background(userHover ? .black.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .onHover { userHover = $0 }
            }.buttonStyle(.plain).accessibilityLabel("登录或恢复登录")
        }
    }
}

/// 侧栏开关（28 方钮）：侧栏收起时也浮在内容区同一位置，保证随时能再打开。
struct SidebarToggleButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            SideIconView(icon: .side).foregroundStyle(Color(hex: 0x55554F)).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(SideIconStyle()).help("显示或隐藏侧栏").accessibilityLabel("显示或隐藏侧栏")
            .keyboardShortcut("s", modifiers: [.command, .control])
    }
}

/// 导航与对话行：选中 7% 黑、悬停 4% 黑，圆角 8。
private struct SideRowStyle: ButtonStyle {
    let active: Bool
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(active ? .black.opacity(0.07) : hovering || configuration.isPressed ? .black.opacity(0.04) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}

extension WorkspaceSection {
    /// 第 17 页侧栏的线性图标（设计稿矢量，见 `SideIcon`）；其余分区不在侧栏导航里。
    var sidebarIcon: SideIcon {
        switch self {
        case .home: .home
        case .resumes: .doc
        case .templates: .layout
        case .jobs: .kanban
        case .schedule: .cal
        case .mock: .mic
        case .opportunities: .brief
        default: .folder
        }
    }
}

/// 对话行：悬停出现 ⋯；置顶、行内重命名（Enter 保存、Esc 取消、120 字）与删除确认。
private struct SessionRow: View {
    @Environment(SessionStore.self) private var session
    let item: JSONValue
    let active: Bool
    let sessions: AgentSessionsModel
    let open: () -> Void
    let deleted: () -> Void
    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""
    @State private var confirming = false
    @State private var busy = false
    @State private var pinError = false
    @FocusState private var focused: Bool

    private var id: String { item.text("id") }
    private var title: String { item.text("title").isEmpty ? "新对话" : item.text("title") }
    private var pinned: Bool { item["pinned"]?.bool == true }
    private var running: Bool { sessions.runningIDs.contains(id) }

    var body: some View {
        if renaming {
            VStack(alignment: .leading, spacing: 3) {
                TextField("", text: $draft).textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
                    .padding(.horizontal, 10).frame(width: 224, height: 32)
                    .background(.white, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(hex: 0x1D1D1B)))
                    .accessibilityLabel("重命名对话 \(title)")
                    .onSubmit { save() }
                    .onExitCommand { draft = title; renaming = false }
                    .onChange(of: draft) { if draft.count > 120 { draft = String(draft.prefix(120)) } }
                    .onChange(of: focused) { if !focused && renaming { save() } }
                Text("Enter 保存 · Esc 取消").font(.system(size: 12)).foregroundStyle(Color(hex: 0x8A8A82)).padding(.leading, 10).padding(.top, 2).padding(.bottom, 3)
            }.onAppear { focused = true }
        } else {
            // 第 17 页对话行：224×32、14px 黑字、左 10 右 36 留给 ⋯；悬停 4% 黑、当前 7% 黑。
            ZStack(alignment: .trailing) {
                Button(action: open) {
                    Text(title).font(.system(size: 14, weight: active ? .medium : .regular)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10).padding(.trailing, 36)
                        .frame(height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).help(title)
                Menu {
                    rowActions
                } label: { Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 24, height: 24) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(Color(hex: 0x6C6C65)).padding(.trailing, 6)
                    // 与 Web 一样悬停才显示；保留极低不透明度让键盘与读屏仍能找到它。
                    .opacity(hovering ? 1 : 0.001).accessibilityLabel("\(title) 的更多操作")
            }
            .frame(width: 224, height: 32)
            .foregroundStyle(Color(hex: 0x1D1D1B))
            .background(active ? .black.opacity(0.07) : (hovering ? .black.opacity(0.04) : .clear), in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
            .contextMenu { rowActions }
            .centeredAlert("置顶状态保存失败，请重试", isPresented: $pinError) { Button("知道了", role: .cancel) {} }
            .centeredConfirmation("删除这条对话？", isPresented: $confirming) {
                Button(busy ? "正在删除…" : "删除", role: .destructive) { Task { await remove() } }.disabled(busy)
                Button("取消", role: .cancel) {}
            } message: { Text("「\(title)」及其中的全部消息将被永久删除。\n此操作无法撤销。") }
        }
    }

    /// 对话菜单（02B·01 方案 A）：16 号灰色细线圆角图标 + 置顶 / 重命名 / 删除。
    @ViewBuilder private var rowActions: some View {
        Button { Task { await togglePin() } } label: { Label(pinned ? "取消置顶" : "置顶", systemImage: pinned ? "pin.slash" : "pin") }.disabled(busy)
        Button { draft = title; renaming = true } label: { Label("重命名", systemImage: "pencil") }
        Divider()
        Button(role: .destructive) { confirming = true } label: { Label("删除", systemImage: "trash") }.disabled(running)
    }

    private func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = false
        guard !value.isEmpty, value != title else { return }
        Task { try? await sessions.rename(api: session.api, id: id, title: value) }
    }

    private func togglePin() async {
        busy = true; defer { busy = false }
        do { try await sessions.setPinned(api: session.api, id: id, pinned: !pinned) } catch { pinError = true }
    }

    private func remove() async {
        busy = true; defer { busy = false }
        do { try await sessions.delete(api: session.api, id: id); deleted() } catch {}
    }
}

/// 个人菜单，对齐 Web `SidebarUserMenu`：头像、名称、会员档位，我的额度（积分）、个人设置与退出登录。
private struct UserMenu: View {
    @Environment(SessionStore.self) private var session
    let user: User
    let openPlans: () -> Void
    let openAccount: () -> Void
    let openCareerProfile: () -> Void
    let close: () -> Void
    @State private var summary: BillingSummary?
    @State private var loggingOut = false

    /// Web `.bill-user-menu`：288 宽、圆角 12、内边距 8；头部 8/8/16 带下边线，名称 16/500，档位 12 靠右；菜单项 40 高、14/500、16 号图标。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                UserAvatar(user: user, size: 36)
                Text(user.nickname.isEmpty ? (user.email ?? "我") : user.nickname).font(.system(size: 16, weight: .medium)).foregroundStyle(V3.txt)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                if let summary { Text(summary.tierLabel).font(.system(size: 12)).foregroundStyle(V3.sub).fixedSize() }
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 16)
            // 03.01 稿：头部与菜单项之间没有分隔线
            .padding(.bottom, 4).accessibilityElement(children: .combine)
            item("我的额度", symbol: "gauge.with.dots.needle.33percent", trailing: summary.map { "\($0.availableText) 积分" } ?? "—",
                 warn: summary?.exhausted == true, action: openPlans)
            item("求职画像", symbol: "person", action: openCareerProfile)
            item("个人设置", symbol: "gearshape", action: openAccount)
            Rectangle().fill(V3.line).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
            item(loggingOut ? "正在退出…" : "退出登录", symbol: "rectangle.portrait.and.arrow.right") {
                guard !loggingOut else { return }
                loggingOut = true
                close()
                Task { await session.signOut() }
            }.disabled(loggingOut)
        }.padding(8).frame(width: 288)
            .task {
                if let result = try? await session.api.careerRequest(path: "/api/billing/summary", method: "GET", query: [:], body: nil) {
                    summary = BillingSummary(json: result)
                }
            }
    }

    /// `.v3-menu-item`：最小 40 高、内边距 8/10、间距 10、14/500；右侧积分用 sub 色，用完时红色。
    private func item(_ title: String, symbol: String, trailing: String? = nil, warn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 16, height: 16)
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                if let trailing { Text(trailing).foregroundStyle(warn ? V3.red : V3.sub) }
            }.font(.system(size: 14, weight: .medium)).foregroundStyle(V3.txt).padding(.horizontal, 10).frame(minHeight: 40).contentShape(Rectangle())
        }.buttonStyle(MenuRowStyle())
    }
}

struct MenuRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed || hovering ? V3.field : .clear, in: RoundedRectangle(cornerRadius: 6))  // `.v3-menu-item:hover`
            .onHover { hovering = $0 }
    }
}

/// 头像：默认头像（本机或公共 OSS 地址，见 `User.isDefaultAvatar`）用随包的羽毛 Logo，私有头像经桌面会话下载。
struct UserAvatar: View {
    @Environment(SessionStore.self) private var session
    let user: User
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else {
                Text(String((user.nickname.isEmpty ? (user.email ?? "我") : user.nickname).prefix(1)))
                    .font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: 0x17191C))
            }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
            .task(id: user.avatarURL ?? "") { await load() }
    }

    private func load() async {
        guard let path = user.avatarURL, !path.isEmpty else { image = nil; return }
        if User.isDefaultAvatar(path) {
            image = Bundle.module.url(forResource: "AppIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            return
        }
        image = (try? await session.api.accountAvatar(path: path)).flatMap(NSImage.init(data:))
    }
}

/// 侧栏小图标钮：悬停 5% 黑底、文字转深。
struct SideIconStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(hovering ? Color(hex: 0x1D1D1B) : Color(hex: 0x8A8A82))
            .background(hovering ? .black.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}
