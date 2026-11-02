import AppKit
import DrawOfferCore
import SwiftUI

/// 工作区侧栏，对齐 Web `v3/Shell.tsx` 的 `V3Sidebar`：品牌与公告铃、8 项导航、置顶与最近对话分组、
/// 对话行 ⋯ 菜单（置顶、重命名、删除）和底部个人菜单。
struct WorkspaceSidebar: View {
    @Environment(SessionStore.self) private var session
    @Binding var selection: WorkspaceSection?
    let activeChatID: String?
    let sessions: AgentSessionsModel
    let openChat: (String) -> Void
    let newChat: () -> Void
    let requestLogin: () -> Void
    let openPlans: () -> Void
    let chatDeleted: (String) -> Void

    @State private var collapsed: Set<String> = []
    @State private var userMenu = false
    @State private var userHover = false
    @State private var headerHover: String?

    private var user: User? {
        if case .signedIn(let user) = session.phase { return user }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { selection = .home } label: {
                    if let url = Bundle.module.url(forResource: "wordmark", withExtension: "png", subdirectory: "Branding"),
                       let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 146, height: 30)
                    } else { Text("DrawOffer").font(.title3.bold()) }
                }.buttonStyle(.plain).accessibilityLabel("DrawOffer 首页")
                Spacer()
                AnnouncementBell()
            }.padding(.leading, 8).padding(.top, 24).padding(.bottom, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(WorkspaceSection.sidebar) { section in navRow(section) }
                    }
                    if user != nil {
                        group("pin")
                        group("recent")
                    } else {
                        groupHeader("recent", label: "最近对话")
                        muted("登录后读取对话")
                    }
                }
            }.scrollIndicators(.never)
            Spacer(minLength: 8)
            userEntry.padding(.bottom, 20)
        }.padding(.horizontal, 14).frame(width: 216)
    }

    private func navRow(_ section: WorkspaceSection) -> some View {
        let active = selection == section && (section != .home || activeChatID == nil)
        return Button { selection = section } label: {
            Label(section.title, systemImage: section.symbol)
                .font(.system(size: 14, weight: active ? .medium : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 34)
                .foregroundStyle(active ? Color(hex: 0x1D1D1B) : Color(hex: 0x55554F))
                .background(active ? Color(hex: 0xE6E6E2) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder private func group(_ key: String) -> some View {
        let label = key == "pin" ? "置顶" : "最近对话"
        let items = sessions.sessions.filter { ($0["pinned"]?.bool == true) == (key == "pin") }
        if key == "recent" || !items.isEmpty {
            groupHeader(key, label: label)
            if !collapsed.contains(key) {
                VStack(alignment: .leading, spacing: 0) {
                    switch sessions.status {
                    case .loading, .idle: muted("正在读取对话…")
                    case .error: muted("对话列表暂时无法读取")
                    case .ready:
                        if items.isEmpty { muted(key == "pin" ? "还没有置顶对话" : "还没有对话") }
                        ForEach(key == "pin" ? items : Array(items.prefix(30)), id: \.self) { item in
                            SessionRow(item: item, active: selection == .assistant && activeChatID == item.text("id"),
                                       sessions: sessions, open: { openChat(item.text("id")) },
                                       deleted: { chatDeleted(item.text("id")) })
                        }
                    }
                }.frame(minHeight: 40, alignment: .top) // Web `.v3-side-sessions { min-height: 40px }`
            }
        }
    }

    /// 对齐 Web `.v3-side-section`：外边距 22/12/8，12px #6c6c65；置顶标题在左、18×18 折叠钮在右，
    /// 最近对话的折叠钮带文字（13px）；新建对话只在悬停这一行时出现。
    private func groupHeader(_ key: String, label: String) -> some View {
        let isCollapsed = collapsed.contains(key)
        let toggle = { if isCollapsed { collapsed.remove(key) } else { collapsed.insert(key) } }
        let chevron = Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .medium))
        return HStack(spacing: 0) {
            if key == "pin" {
                Text(label)
                Spacer()
                Button(action: toggle) { chevron.frame(width: 18, height: 18).contentShape(Rectangle()) }
                    .buttonStyle(SideIconStyle())
                    .accessibilityLabel(isCollapsed ? "展开\(label)" : "收起\(label)")
            } else {
                Button(action: toggle) {
                    HStack(spacing: 5) { Text(label).font(.system(size: 13)); chevron }.frame(height: 18).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(isCollapsed ? "展开\(label)" : "收起\(label)")
                Spacer()
                Button(action: newChat) { Image(systemName: "square.and.pencil").font(.system(size: 12)).frame(width: 18, height: 18).contentShape(Rectangle()) }
                    .buttonStyle(SideIconStyle()).help("新建对话").accessibilityLabel("新建对话")
                    .opacity(headerHover == key ? 1 : 0.001)
            }
        }.font(.system(size: 12)).foregroundStyle(Color(hex: 0x6C6C65)).frame(minHeight: 18)
            .padding(.horizontal, 12).padding(.top, 22).padding(.bottom, 8)
            .onHover { headerHover = $0 ? key : (headerHover == key ? nil : headerHover) }
    }

    private func muted(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Color(hex: 0x6C6C65)).padding(.horizontal, 12).padding(.vertical, 4)
    }

    @ViewBuilder private var userEntry: some View {
        if let user {
            Button { userMenu.toggle() } label: {
                // `.v3-side-user`：最小 44 高、内边距 0/6、间距 8、圆角 8；名称 14/500 行高 20，邮箱 12 行高 18（最宽 130）
                HStack(spacing: 8) {
                    UserAvatar(user: user, size: 36)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(user.nickname.isEmpty ? "未设置昵称" : user.nickname).font(.system(size: 14, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 20)
                        Text(user.email ?? "微信登录").font(.system(size: 12)).foregroundStyle(V3.fnt).lineLimit(1).truncationMode(.tail).frame(maxWidth: 130, alignment: .leading).frame(height: 18)
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 6).frame(minHeight: 44).contentShape(Rectangle())
                    .background(selection == .account ? V3.hl : userHover ? V3.field : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .onHover { userHover = $0 }
            }.buttonStyle(.plain).accessibilityLabel("打开个人菜单，当前账号：\(user.nickname.isEmpty ? (user.email ?? "我") : user.nickname)")
                .popover(isPresented: $userMenu, arrowEdge: .top) {
                    UserMenu(user: user, openPlans: { userMenu = false; openPlans() },
                             openAccount: { userMenu = false; selection = .account },
                             close: { userMenu = false })
                }
        } else {
            Button(action: requestLogin) {
                HStack(spacing: 8) {
                    Text("我").foregroundStyle(.white).frame(width: 36, height: 36).background(Color(hex: 0x17191C), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("游客模式").font(.system(size: 13.5, weight: .medium))
                        Text("登录 / 恢复登录").font(.system(size: 11)).foregroundStyle(Color(hex: 0x96968F))
                    }
                }
            }.buttonStyle(.plain).padding(.horizontal, 6)
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
                    .padding(.horizontal, 12).frame(width: 198, height: 32)
                    .background(.white, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(hex: 0x1D1D1B)))
                    .accessibilityLabel("重命名对话 \(title)")
                    .onSubmit { save() }
                    .onExitCommand { draft = title; renaming = false }
                    .onChange(of: draft) { if draft.count > 120 { draft = String(draft.prefix(120)) } }
                    .onChange(of: focused) { if !focused && renaming { save() } }
                Text("Enter 保存 · Esc 取消").font(.system(size: 12)).foregroundStyle(Color(hex: 0x6C6C65)).padding(.leading, 12).padding(.top, 2).padding(.bottom, 3)
            }.onAppear { focused = true }
        } else {
            // 对齐 Web `.v3-side-session`：198×32、14px、左 12 右 36 留给 ⋯（距右 6）；悬停 #f4f4f2，当前 #e6e6e2。
            ZStack(alignment: .trailing) {
                Button(action: open) {
                    Text(title).font(.system(size: 14, weight: active ? .medium : .regular)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12).padding(.trailing, 36)
                        .frame(height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).help(title)
                Menu {
                    Button(pinned ? "取消置顶" : "置顶") { Task { await togglePin() } }.disabled(busy)
                    Button("重命名") { draft = title; renaming = true }
                    Divider()
                    Button("删除", role: .destructive) { confirming = true }.disabled(running)
                } label: { Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(Color(hex: 0x6C6C65)).padding(.trailing, 6)
                    // 与 Web 一样悬停才显示；保留极低不透明度让键盘与读屏仍能找到它。
                    .opacity(hovering ? 1 : 0.001).accessibilityLabel("\(title) 的更多操作")
            }
            .frame(width: 198, height: 32)
            .foregroundStyle(active || hovering ? Color(hex: 0x1D1D1B) : Color(hex: 0x55554F))
            .background(active ? Color(hex: 0xE6E6E2) : (hovering ? Color(hex: 0xF4F4F2) : .clear), in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
            .contextMenu {
                Button(pinned ? "取消置顶" : "置顶") { Task { await togglePin() } }.disabled(busy)
                Button("重命名") { draft = title; renaming = true }
                Divider()
                Button("删除", role: .destructive) { confirming = true }.disabled(running)
            }
            .alert("置顶状态保存失败，请重试", isPresented: $pinError) { Button("知道了", role: .cancel) {} }
            .confirmationDialog("删除这条对话？", isPresented: $confirming) {
                Button(busy ? "正在删除…" : "删除", role: .destructive) { Task { await remove() } }.disabled(busy)
                Button("取消", role: .cancel) {}
            } message: { Text("「\(title)」及其中的全部消息将被永久删除。\n此操作无法撤销。") }
        }
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
            .overlay(alignment: .bottom) { Rectangle().fill(V3.line).frame(height: 1) }
            .padding(.bottom, 4).accessibilityElement(children: .combine)
            item("我的额度", symbol: "gauge.with.dots.needle.33percent", trailing: summary.map { "\($0.availableText) 积分" } ?? "—",
                 warn: summary?.exhausted == true, action: openPlans)
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

/// 头像：默认头像（`/api/auth/default-avatar`）用随包的羽毛 Logo，私有头像经桌面会话下载。
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
        if path.hasPrefix("/api/auth/default-avatar") {
            image = Bundle.module.url(forResource: "AppIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            return
        }
        image = (try? await session.api.accountAvatar(path: path)).flatMap(NSImage.init(data:))
    }
}

/// 侧栏里的 18×18 小图标钮：悬停底色 #f4f4f2、文字转深，对齐 Web `.v3-side-section button:hover`。
private struct SideIconStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(hovering ? Color(hex: 0x1D1D1B) : Color(hex: 0x6C6C65))
            .background(hovering ? Color(hex: 0xF4F4F2) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovering = $0 }
    }
}
