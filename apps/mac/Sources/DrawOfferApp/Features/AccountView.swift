import AppKit
import DrawOfferCore
import SwiftUI
import UniformTypeIdentifiers

/// `/account` 与 `/account/career-profile`：求职资料是账号下的独立页面，左上角面包屑回到账号。
struct AccountSection: View {
    @State private var career = false
    var body: some View {
        if career { CareerProfileView(back: { career = false }) }
        else { AccountView(openCareerProfile: { career = true }) }
    }
}

/// 账号（Web `features/account/AccountPage.tsx`，Figma 08.4）：资料卡、账号与安全、求职资料入口、偏好、退出与注销。
/// 桌面端不提供修改密码、微信绑定和注销账号（后端只接受 Web Cookie），对应行和弹窗都不显示。
struct AccountView: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    @State private var profile: JSONValue?
    @State private var preferences: JSONValue?
    @State private var preferencesFailed = false
    @State private var savingPreference = false
    @State private var loading = true
    @State private var loadFailed = false
    @State private var reload = UUID()
    @State private var careerSummary: String?
    @State private var avatar: NSImage?
    @State private var dialog: Dialog?
    @State private var inlineError: String?
    @State private var toast: AccountToast?
    @State private var loggingOut = false
    var openCareerProfile: () -> Void = {}

    enum Dialog: String, Identifiable { case profile, email, logout, avatar; var id: String { rawValue } }

    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }
    private var user: JSONValue { profile?["user"] ?? .null }
    private var authMode: String { profile?["capabilities"]?.text("auth_mode") ?? "" }
    private var initial: String { String((user.text("nickname").trimmingCharacters(in: .whitespaces).nonEmptyValue ?? "我").prefix(1)) }

    var body: some View {
        V3Page(top: 51) {
            VStack(alignment: .leading, spacing: 0) {
                // `.acc-page`：眉题 12/18，标题 28/36 距眉题 9，说明 14/22 距标题 6
                Text(["ACCOUNT", authMode == "password" ? user.text("email").nonEmptyValue : authMode == "wechat" ? "微信登录" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(V3.sans(12, weight: .medium)).foregroundStyle(V3.fnt).frame(height: 18)
                Text("账号").font(V3.serif(28)).foregroundStyle(V3.txt).frame(height: 36).padding(.top, 9)
                Text("管理个人资料、登录安全与偏好设置。").font(V3.sans(14)).foregroundStyle(V3.sub).frame(height: 22).padding(.top, 6)
                if loading && profile == nil {
                    ProgressView("正在加载个人资料…").font(V3.sans(13)).frame(maxWidth: .infinity, minHeight: 200).padding(.top, 80)
                } else if loadFailed, profile == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("暂时无法读取个人资料").font(V3.serif(18))
                        Text("请检查网络连接后重新加载。").font(V3.sans(13)).foregroundStyle(V3.sub)
                        Button("重新加载") { reload = UUID() }.buttonStyle(V3ButtonStyle(kind: .ghost))
                    }.padding(.top, 40)
                } else if profile != nil {
                    content
                }
            }
        }
        .background(Color.white)
        .overlay(alignment: .top) { if let toast { AccountToastView(toast: toast) { self.toast = nil } } }
        .task(id: "\(account)|\(reload)") { await load() }
        .sheet(item: $dialog) { kind in
            switch kind {
            case .profile:
                EditProfileSheet(user: user, avatar: avatar, close: { dialog = nil }, updated: apply,
                                 saved: { message in dialog = nil; inlineError = nil; toast = .init(kind: .success, title: message) },
                                 failed: { inlineError = $0 }, notice: { toast = .init(kind: .error, title: $0) })
            case .email:
                ContactEmailSheet(email: user.text("contact_email").nonEmptyValue, close: { dialog = nil }) { email in
                    var next = user
                    if case .object(var fields) = next { fields["contact_email"] = email.map(JSONValue.string) ?? .null; next = .object(fields) }
                    apply(next); dialog = nil; toast = .init(kind: .success, title: "联系邮箱已保存")
                }
            case .logout:
                LogoutSheet(initial: initial, device: profile?["current_session"]?.text("device_label") ?? "", busy: loggingOut, close: { dialog = nil }) {
                    Task { await logout() }
                }
            case .avatar:
                if let avatar {
                    Image(nsImage: avatar).resizable().scaledToFit().frame(width: 420).overlay(alignment: .topTrailing) {
                        Button { dialog = nil } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28) }
                            .buttonStyle(.plain).foregroundStyle(V3.fnt).background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 7))
                            .keyboardShortcut(.cancelAction).accessibilityLabel("关闭").padding(12)
                    }.accessibilityLabel("头像原图")
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let inlineError {
            // 10.3 局部状态：标题下 48 高的浅红提示条
            HStack(spacing: 10) {
                Text("保存失败").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                Text(inlineError).font(V3.sans(14)).foregroundStyle(V3.sub).frame(maxWidth: .infinity, alignment: .leading)
                Button { self.inlineError = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(V3.fnt).accessibilityLabel("关闭提示")
            }.padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 12).frame(minHeight: 48)
                .background(Color(hex: 0xFDF5F5), in: RoundedRectangle(cornerRadius: 10)).padding(.top, 14).padding(.bottom, -2)
        }
        hero.padding(.top, 28)
        section("账号与安全", "管理登录方式与联系信息。") {
            if authMode == "password" { row("登录邮箱", value: user.text("email").nonEmptyValue ?? "未设置") { EmptyView() } }
            if authMode == "wechat" { row("登录方式", value: "微信登录") { EmptyView() } }
            row("联系邮箱", value: user.text("contact_email").nonEmptyValue ?? "未设置") {
                RowLink(label: user.text("contact_email").isEmpty ? "设置" : "修改") { dialog = .email }
            }
        }
        section("求职资料", "网申插件和 AI 都只用这一份，不会改动简历。") {
            row("求职资料", value: careerSummary ?? "基本信息、证件、求职意向和经历") { RowLink(label: "查看与编辑", action: openCareerProfile) }
        }
        section("偏好", "界面显示偏好。") {
            if preferencesFailed {
                HStack(spacing: 4) {
                    Text("偏好读取失败，请重新加载后重试。")
                    Button("重试") { Task { await loadPreferences() } }.buttonStyle(.plain).foregroundStyle(V3.link)
                }.font(V3.sans(14)).foregroundStyle(V3.sub).padding(.horizontal, 19).padding(.top, 14)
            }
            row("界面语言", value: nil) {
                LanguageSelect(value: preferences?.text("locale").nonEmptyValue ?? "zh-CN", disabled: preferences == nil || savingPreference) { locale in
                    Task { await savePreference(locale) }
                }
            }
        }
        section("退出与注销", "注销后个人数据会被永久清理，无法恢复。", last: true) {
            row("退出登录", value: profile?["current_session"]?.text("device_label") ?? "") {
                Button("退出") { dialog = .logout }.buttonStyle(V3ButtonStyle(kind: .ghost, height: 28, width: 72, small: true))
            }
        }
    }

    /// `.acc-hero`：92 高、圆角 14 的白卡，56 头像、16/600 昵称、12/18 注册时间，右侧 96×32「编辑资料」。
    private var hero: some View {
        HStack(spacing: 16) {
            Button { if avatar != nil, !user.text("avatar_url").isEmpty { dialog = .avatar } } label: {
                AvatarCircle(image: avatar, initial: initial, size: 56)
            }.buttonStyle(.plain).accessibilityLabel(user.text("avatar_url").isEmpty ? "头像预览不可用" : "查看头像原图").disabled(user.text("avatar_url").isEmpty)
            VStack(alignment: .leading, spacing: 8) {
                Text(user.text("nickname")).font(V3.sans(16, weight: .semibold)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 24)
                Text("注册于 \(registeredText)").font(V3.sans(12)).foregroundStyle(V3.fnt).frame(height: 18)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("编辑资料") { inlineError = nil; dialog = .profile }.buttonStyle(V3ButtonStyle(kind: .ghost, width: 96))
        }
        .padding(.horizontal, 23).frame(height: 92)
        .background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(V3.cl))
    }

    private var registeredText: String {
        guard let date = CareerApplication.date(user.text("registered_at")) else { return "—" }
        let parts = Beijing.calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)年\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }

    /// `.acc-section`：左栏 228 宽（标题 16/600 行高 24，说明 14/22 距标题 9），右栏圆角 12 的白卡；区块间距 32。
    private func section<Content: View>(_ title: String, _ desc: String, last: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(V3.sans(16, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 24)
                Text(desc).font(V3.sans(14)).foregroundStyle(V3.fnt).lineHeight(14, 22).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 4).padding(.trailing, 28).frame(width: 228, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.cl))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }.padding(.top, 32).padding(.bottom, last ? 20 : 0)
    }

    /// `.acc-row`：至少 56 高，标签 148 宽 14/500，值 14/22 sub 色，右侧操作；行间分隔线左右缩进 20。
    private func row<Trailing: View>(_ label: String, value: String?, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 0) {
            Text(label).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).frame(width: 148, height: 20, alignment: .leading)
            if let value { Text(value).font(V3.sans(14)).foregroundStyle(V3.sub).lineHeight(14, 22).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 12) }
            else { Spacer(minLength: 0) }
            trailing()
        }
        .padding(.horizontal, 19).padding(.vertical, 14).frame(minHeight: 56)
        .overlay(alignment: .top) { RowDivider() }
    }

    private func apply(_ next: JSONValue) {
        guard case .object(var fields) = profile ?? .object([:]) else { return }
        fields["user"] = next; profile = .object(fields)
        session.updateNickname(next.text("nickname"))
        if next.text("avatar_url") != user.text("avatar_url") || next.text("avatar_url").isEmpty { session.updateAvatar(next.text("avatar_url").nonEmptyValue) }
        Task { await loadAvatar() }
    }

    // MARK: 动作

    private func load() async {
        let owner = account
        guard !owner.isEmpty else { return }
        loadFailed = false
        defer { if owner == account { loading = false } }
        async let preferenceTask: Void = loadPreferences()
        async let summaryTask: Void = loadCareerSummary()
        do {
            let value = try await session.api.careerRequest(path: "/api/account/profile", method: "GET", query: [:], body: nil)
            guard owner == account else { return }
            profile = value
            session.updateNickname(value["user"]?.text("nickname") ?? "")
            await loadAvatar()
        } catch is CancellationError {
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            if profile == nil { loadFailed = true }
        }
        _ = await (preferenceTask, summaryTask)
    }

    private func loadPreferences() async {
        do { preferences = try await session.api.careerRequest(path: "/api/account/preferences", method: "GET", query: [:], body: nil); preferencesFailed = false }
        catch { preferencesFailed = true }
    }

    /// 求职资料只在独立页面编辑，这里只显示一行摘要：姓名 · 经历读自《简历》。
    private func loadCareerSummary() async {
        guard let value = try? await session.api.careerRequest(path: "/api/account/career-profile", method: "GET", query: [:], body: nil) else { careerSummary = nil; return }
        let source = value["experience_resume"]?.text("title").nonEmptyValue
        careerSummary = [value["personal"]?.text("name").nonEmptyValue, source.map { "经历读自《\($0)》" } ?? "还没有读取简历"].compactMap { $0 }.joined(separator: " · ")
    }

    private func loadAvatar() async {
        let path = user.text("avatar_url")
        guard !path.isEmpty else { avatar = nil; return }
        if path.hasPrefix("/api/auth/default-avatar") { avatar = Bundle.module.url(forResource: "AppIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:)); return }
        avatar = (try? await session.api.accountAvatar(path: path)).flatMap(NSImage.init(data:))
    }

    private func savePreference(_ locale: String) async {
        guard !savingPreference else { return }
        savingPreference = true
        defer { savingPreference = false }
        do {
            preferences = try await session.api.careerRequest(path: "/api/account/preferences", method: "PATCH", query: [:], body: .object(["locale": .string(locale)]))
            toast = .init(kind: .success, title: "偏好已保存")
        } catch { toast = .init(kind: .error, title: AccountRequest.errorMessage(error, fallback: "偏好保存失败，请重试。")) }
    }

    private func logout() async {
        guard !loggingOut else { return }
        loggingOut = true
        await session.signOut()
        loggingOut = false
        dialog = nil
    }
}

// MARK: - 共用小件

private struct RowDivider: View {
    var body: some View { Rectangle().fill(V3.line).frame(height: 1).padding(.horizontal, 20) }
}

/// `.acc-row-link`：14/500 fnt 色文字 + 12 号右箭头，悬停变深。
private struct RowLink: View {
    let label: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { Text(label).font(V3.sans(14, weight: .medium)); Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(V3.fnt) }
                .foregroundStyle(hover ? V3.txt : V3.fnt).frame(height: 20).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }.accessibilityLabel(label)
    }
}

/// `Select size=sm`：160×32 的下拉。
private struct LanguageSelect: View {
    let value: String
    let disabled: Bool
    let change: (String) -> Void
    var body: some View {
        Menu {
            ForEach([("zh-CN", "简体中文"), ("en-US", "English")], id: \.0) { option in
                Button { if option.0 != value { change(option.0) } } label: { if option.0 == value { Label(option.1, systemImage: "checkmark") } else { Text(option.1) } }
            }
        } label: {
            HStack {
                Text(value == "en-US" ? "English" : "简体中文").font(V3.sans(14)).foregroundStyle(V3.txt)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(V3.fnt)
            }.padding(.leading, 12).padding(.trailing, 14).frame(width: 160, height: 32)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(disabled).opacity(disabled ? 0.5 : 1).accessibilityLabel("界面语言")
    }
}

struct AvatarCircle: View {
    let image: NSImage?
    let initial: String
    let size: CGFloat
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Text(initial).font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity).background(V3.txt) }
        }.frame(width: size, height: size).clipShape(Circle())
    }
}

struct AccountToast: Equatable {
    enum Kind { case success, error, warn }
    let kind: Kind
    let title: String
    var message: String? = nil
}

/// `.v3-toast`：顶部居中、最小 320 宽、圆角 12 的白卡，3 秒后收起。
struct AccountToastView: View {
    let toast: AccountToast
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.kind == .success ? "checkmark" : "exclamationmark.circle").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(toast.kind == .error ? V3.red : toast.kind == .warn ? V3.orange : V3.green).frame(width: 16, height: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(toast.title).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                if let message = toast.message { Text(message).font(V3.sans(12)).foregroundStyle(V3.sub) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 14).frame(minWidth: 320).fixedSize()
        .background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.cl))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 8).padding(.top, 28)
        .task(id: toast.title) { try? await Task.sleep(for: .seconds(3)); dismiss() }
    }
}

// MARK: - 08.4a 编辑资料（620 宽）

private struct EditProfileSheet: View {
    @Environment(SessionStore.self) private var session
    let user: JSONValue
    let avatar: NSImage?
    let close: () -> Void
    let updated: (JSONValue) -> Void
    let saved: (String) -> Void
    let failed: (String) -> Void
    let notice: (String) -> Void

    @State private var nickname = ""
    @State private var image: NSImage?
    @State private var draft: AvatarCrop.Draft?
    @State private var removeAvatar = false
    @State private var saving = false
    @State private var error: String?
    @State private var dragStart: AvatarCrop.Draft?

    /// 裁剪区按 232/320 缩小显示。
    private let scale = 232 / AvatarCrop.viewport
    private var currentAvatar: NSImage? { removeAvatar ? nil : avatar }
    private var name: String { nickname.trimmingCharacters(in: .whitespaces).nonEmptyValue ?? user.text("nickname") }

    var body: some View {
        V3Dialog(width: 620, closable: !saving, close: close) {
            V3DialogHead(title: "编辑资料", sub: "头像和昵称会显示在侧栏、分享页和 AI 对话里。", subTop: 7, subLine: 20)
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 0) {
                    crop
                    HStack(spacing: 17) {
                        Text("缩放").font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub)
                        Slider(value: Binding(get: { draft?.zoom ?? 1 }, set: { value in if var next = draft { next.zoom = value; draft = AvatarCrop.clamp(next) } }),
                               in: AvatarCrop.minZoom...AvatarCrop.maxZoom).controlSize(.small).tint(V3.txt).disabled(draft == nil || saving).accessibilityLabel("缩放")
                    }.frame(height: 16).padding(.top, 22)
                }.frame(width: 232)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        (Text("昵称") + Text("*").foregroundColor(V3.red).fontWeight(.bold)).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.sub)
                        Spacer()
                        Text("\(nickname.count) / 50").font(V3.sans(12)).foregroundStyle(V3.fnt).monospacedDigit()
                    }.frame(height: 20).padding(.bottom, 5)
                    TextField("", text: $nickname).textFieldStyle(.plain).font(V3.sans(14)).padding(.horizontal, 14).frame(height: 40)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(error?.contains("昵称") == true ? V3.red : V3.cl))
                        .disabled(saving).accessibilityLabel("昵称").onSubmit { Task { await save() } }
                        .onChange(of: nickname) { if nickname.count > 50 { nickname = String(nickname.prefix(50)) } }
                    Text("头像").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.sub).frame(height: 20).padding(.top, 22).padding(.bottom, 5)
                    HStack(spacing: 16) {
                        Button { Task { await pick() } } label: { Label("重新选择", systemImage: "arrow.up.to.line").labelStyle(.titleAndIcon) }
                            .buttonStyle(V3ButtonStyle(kind: .ghost, height: 34, width: 112)).disabled(saving)
                        Button("移除头像") { draft = nil; image = nil; removeAvatar = true }.buttonStyle(.plain).font(V3.sans(12, weight: .medium))
                            .foregroundStyle(saving || (draft == nil && currentAvatar == nil) ? V3.fnt2 : V3.red).disabled(saving || (draft == nil && currentAvatar == nil))
                    }
                    Text("支持 JPG、PNG、WebP，最大 10 MB。").font(V3.sans(14)).foregroundStyle(V3.fnt).frame(height: 22).padding(.top, 10)
                    Text("预览").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.sub).frame(height: 20).padding(.top, 22).padding(.bottom, 9)
                    HStack(spacing: 16) { ForEach([56.0, 36.0, 24.0], id: \.self) { preview($0) } }
                }.frame(width: 292, alignment: .leading)
            }.padding(.top, 21).padding(.bottom, 4)
        } left: {
            if let error { Text(error).font(V3.sans(14)).foregroundStyle(V3.red).lineLimit(2) }
        } foot: {
            Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36, width: 80)).disabled(saving)
            Button(saving ? "保存中…" : "保存") { Task { await save() } }.buttonStyle(V3ButtonStyle(kind: .dark, height: 36, width: 88)).disabled(saving)
        }
        .onAppear { nickname = user.text("nickname") }
    }

    /// `.acc-crop`：232×232、圆角 12 的灰底；圆窗外 45% 黑色遮罩 + 白色细描边，底部提示胶囊。
    private var crop: some View {
        ZStack {
            V3.field
            Group {
                if let draft, let image {
                    let layout = AvatarCrop.layout(draft)
                    Image(nsImage: image).resizable().frame(width: layout.renderedWidth * scale, height: layout.renderedHeight * scale)
                        .offset(x: draft.offsetX * scale, y: draft.offsetY * scale)
                } else if let currentAvatar {
                    Image(nsImage: currentAvatar).resizable().scaledToFill().frame(width: AvatarCrop.window * scale, height: AvatarCrop.window * scale).clipped()
                } else {
                    AvatarCircle(image: nil, initial: String(name.prefix(1)), size: AvatarCrop.window * scale)
                }
            }
            Rectangle().fill(Color(hex: 0x1D1D1B).opacity(0.45))
                .mask { Rectangle().overlay(Circle().frame(width: AvatarCrop.window * scale, height: AvatarCrop.window * scale).blendMode(.destinationOut)).compositingGroup() }
            Circle().stroke(.white, lineWidth: 1.4).frame(width: AvatarCrop.window * scale, height: AvatarCrop.window * scale)
            Text(draft == nil ? "点击选择图片" : "拖动调整位置").font(V3.sans(10.5, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 12).frame(height: 22)
                .background(Color(hex: 0x1D1D1B).opacity(0.8), in: Capsule()).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 12)
        }
        .frame(width: 232, height: 232).clipShape(RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
        .onTapGesture { if draft == nil { Task { await pick() } } }
        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
            guard let current = draft, !saving else { return }
            let start = dragStart ?? current
            if dragStart == nil { dragStart = current }
            var next = start
            next.offsetX = start.offsetX + value.translation.width / scale
            next.offsetY = start.offsetY + value.translation.height / scale
            draft = AvatarCrop.clamp(next)
        }.onEnded { _ in dragStart = nil })
        .accessibilityElement().accessibilityLabel(draft == nil ? "头像区域，点击选择图片" : "头像裁剪区域，可使用方向键移动")
        .accessibilityAddTraits(.isButton).accessibilityAction { if draft == nil { Task { await pick() } } }
    }

    /// 三种尺寸预览：把裁剪窗口里的画面按比例缩到 56 / 36 / 24。
    @ViewBuilder private func preview(_ size: CGFloat) -> some View {
        if let draft, let image {
            let layout = AvatarCrop.layout(draft), k = size / AvatarCrop.window
            Image(nsImage: image).resizable().frame(width: layout.renderedWidth * k, height: layout.renderedHeight * k)
                .offset(x: draft.offsetX * k, y: draft.offsetY * k).frame(width: size, height: size).clipShape(Circle()).background(V3.field, in: Circle())
        } else {
            AvatarCircle(image: currentAvatar, initial: String(name.prefix(1)), size: size)
        }
    }

    private func pick() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 10 * 1024 * 1024 { notice("头像图片不能超过 10MB。"); return }
        guard let picked = NSImage(contentsOf: url), let cg = picked.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width > 0, cg.height > 0 else {
            notice("头像图片无法读取，请选择其他图片。"); return
        }
        image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        draft = AvatarCrop.Draft(width: Double(cg.width), height: Double(cg.height))
        removeAvatar = false
    }

    /// 按圆窗取原图正方形，缩到 512 输出 PNG（与 Web `createAvatarCropDataUrl` 一致）。
    private func cropped() -> Data? {
        guard let draft, let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let source = AvatarCrop.source(draft)
        guard let part = cg.cropping(to: CGRect(x: source.x, y: source.y, width: source.size, height: source.size).integral) else { return nil }
        let side = Int(AvatarCrop.output)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: part, size: NSSize(width: part.width, height: part.height)).draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private func fail(_ message: String) { error = message; failed(message) }

    /// 依次保存：昵称（有变化才提交）→ 新头像上传 / 移除头像。任一步失败保留弹窗和裁剪状态。
    private func save() async {
        guard !saving else { return }
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 50 else { fail("昵称不能为空，且不能超过 50 个字符。"); return }
        saving = true; error = nil
        defer { saving = false }
        var latest = user
        if trimmed != user.text("nickname") {
            do {
                latest = try await session.api.careerRequest(path: "/api/account/profile", method: "PATCH", query: [:], body: .object(["nickname": .string(trimmed)]))
                updated(latest)
            } catch { fail(AccountRequest.errorMessage(error, fallback: "昵称保存失败，请稍后重试。")); return }
        }
        if draft != nil {
            do {
                guard let png = cropped() else { throw APIError.invalidResponse }
                let result = try await session.api.careerRequest(path: "/api/account/avatar", method: "PUT", query: [:],
                    body: .object(["fileName": .string("avatar.png"), "dataUrl": .string("data:image/png;base64," + png.base64EncodedString())]))
                if case .object(var fields) = latest { fields["avatar_url"] = result["url"] ?? .null; latest = .object(fields) }
                updated(latest)
                saved("头像已更新。")
            } catch { fail(AccountRequest.errorMessage(error, fallback: "头像处理或上传失败，请重试。")); return }
        } else if removeAvatar, !user.text("avatar_url").isEmpty {
            do {
                _ = try await session.api.careerRequest(path: "/api/account/avatar", method: "DELETE", query: [:], body: nil)
                if case .object(var fields) = latest { fields["avatar_url"] = .null; latest = .object(fields) }
                updated(latest)
                saved("头像已删除。")
            } catch { fail(AccountRequest.errorMessage(error, fallback: "头像删除失败，请稍后重试。")); return }
        } else {
            saved("资料已保存。")
        }
    }
}

// MARK: - 08.4b 联系邮箱（520 宽）

private struct ContactEmailSheet: View {
    @Environment(SessionStore.self) private var session
    let email: String?
    let close: () -> Void
    let saved: (String?) -> Void
    @State private var draft = ""
    @State private var saving = false
    @State private var error: String?

    private var trimmed: String { draft.trimmingCharacters(in: .whitespaces) }
    private var valid: Bool { trimmed.isEmpty || trimmed.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil }

    var body: some View {
        V3Dialog(width: 520, closable: !saving, close: close) {
            V3DialogHead(title: "联系邮箱", sub: "用于联系信息；保存后不会发送验证邮件或通知。", subTop: 7, subLine: 20)
            V3DotStage(height: 120) { ChangeEmailArt(email: email ?? "未设置") }.padding(.top, 13)
            VStack(alignment: .leading, spacing: 5) {
                Text("邮箱地址").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.sub).frame(height: 20)
                HStack(spacing: 8) {
                    Image(systemName: "envelope").font(.system(size: 13)).foregroundStyle(V3.fnt)
                    TextField("", text: $draft, prompt: Text("you@example.com").foregroundStyle(V3.fnt2)).textFieldStyle(.plain).font(V3.sans(14))
                        .accessibilityLabel("邮箱地址").onSubmit { Task { await save() } }
                }.padding(.leading, 12).padding(.trailing, 14).frame(height: 40)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
            }.padding(.top, 24)
            Text("留空即可清除联系邮箱。").font(V3.sans(14)).foregroundStyle(V3.sub).padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).background(V3.field, in: RoundedRectangle(cornerRadius: 8)).padding(.top, 22).padding(.bottom, 4)
        } left: {
            if let error { Text(error).font(V3.sans(14)).foregroundStyle(V3.red) }
        } foot: {
            Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36, width: 80)).disabled(saving)
            Button(saving ? "保存中…" : "保存") { Task { await save() } }.buttonStyle(V3ButtonStyle(kind: .dark, height: 36, width: 100))
                .disabled(saving || !valid || trimmed.nonEmptyValue == email)
        }
        .onAppear { draft = email ?? "" }
    }

    private func save() async {
        guard !saving, valid else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            let result = try await session.api.careerRequest(path: "/api/account/contact-email", method: "PUT", query: [:], body: .object(["email": trimmed.isEmpty ? .null : .string(trimmed)]))
            saved(result.text("contact_email").nonEmptyValue)
        } catch { self.error = AccountRequest.errorMessage(error, fallback: "联系邮箱保存失败，请重试。") }
    }
}

// MARK: - 08.4h 退出：居中确认（420 宽）

private struct LogoutSheet: View {
    let initial: String
    let device: String
    let busy: Bool
    let close: () -> Void
    let confirm: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            V3DotStage(height: 128) { LogoutArt(initial: initial) }.padding(.bottom, 20)
            Text("确认退出登录？").font(.system(size: 20, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 26)
            Text("退出后需要重新登录。").font(V3.sans(14)).foregroundStyle(V3.sub).frame(height: 20).padding(.top, 6)
            VStack(alignment: .leading, spacing: 14) {
                impact("rectangle.portrait.and.arrow.right", device)
                impact("checkmark", "其他设备上的登录不受影响")
            }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .leading)
                .background(V3.field, in: RoundedRectangle(cornerRadius: 10)).padding(.top, 11)
            HStack(spacing: 12) {
                Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 40, fill: true)).disabled(busy)
                Button(busy ? "正在退出…" : "退出登录", action: confirm).buttonStyle(V3ButtonStyle(kind: .dark, height: 40, fill: true)).disabled(busy).keyboardShortcut(.defaultAction)
            }.padding(.top, 32)
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 24).frame(width: 420)
        .overlay(alignment: .topTrailing) {
            if !busy {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(V3.fnt).keyboardShortcut(.cancelAction).accessibilityLabel("关闭").padding(.top, 32).padding(.trailing, 24)
            }
        }
    }
    private func impact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) { Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(V3.fnt).frame(width: 14); Text(text).font(V3.sans(14)).foregroundStyle(V3.sub).frame(height: 22) }
    }
}

// MARK: - 插图（坐标照 Web `accountArt.tsx`）

private struct MiniAvatar: View {
    let x: CGFloat, y: CGFloat, size: CGFloat, initial: String
    var body: some View {
        Text(initial).font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.white).frame(width: size, height: size).background(V3.txt, in: Circle()).offset(x: x, y: y)
    }
}

/// 08.4h：当前电脑带退出角标，手机淡掉表示不受影响（舞台 372×128）。
private struct LogoutArt: View {
    let initial: String
    var body: some View {
        ZStack(alignment: .topLeading) {
            ArtPaper(x: 112, y: 22, w: 136, h: 86) {
                ArtBar(x: 0, y: 0, w: 136, h: 16, r: 0, color: V3.field)
                ForEach([8.0, 17, 26], id: \.self) { ArtBar(x: $0, y: 5, w: 6, h: 6, r: 3, color: V3.sk2) }
                MiniAvatar(x: 14, y: 30, size: 20, initial: initial)
                ArtBar(x: 42, y: 33, w: 52, h: 5, r: 2, color: V3.txt)
                ArtBar(x: 42, y: 43, w: 34, h: 4, r: 2, color: V3.sk2)
                ArtBar(x: 14, y: 62, w: 108, h: 4, r: 2)
                ArtBar(x: 14, y: 72, w: 80, h: 4, r: 2)
            }
            ArtBadge(x: 236, y: 90, symbol: "rectangle.portrait.and.arrow.right")
            ArtPaper(x: 272, y: 34, w: 40, h: 70, shadow: false) {
                ArtBar(x: 14, y: 6, w: 12, h: 3, r: 2, color: V3.sk2)
                MiniAvatar(x: 12, y: 20, size: 16, initial: initial)
                ArtBar(x: 8, y: 44, w: 24, h: 3, r: 2)
                ArtBar(x: 8, y: 52, w: 18, h: 3, r: 2)
            }.opacity(0.45)
        }.frame(width: 372, height: 128, alignment: .topLeading)
    }
}

/// 08.4b：当前邮箱卡 → 信封里露出 6 位验证码（舞台 456×120）。
private struct ChangeEmailArt: View {
    let email: String
    var body: some View {
        ZStack(alignment: .topLeading) {
            ArtPaper(x: 45, y: 50, w: 150, h: 44, r: 10) {
                Image(systemName: "envelope").font(.system(size: 10)).foregroundStyle(V3.sub).frame(width: 24, height: 24).background(V3.field, in: Circle()).offset(x: 10, y: 10)
                Text("当前邮箱").font(.system(size: 9)).foregroundStyle(V3.fnt).offset(x: 42, y: 8)
                Text(email).font(.system(size: 10.5)).foregroundStyle(V3.sub).lineLimit(1).frame(maxWidth: 100, alignment: .leading).offset(x: 42, y: 21)
            }
            DashArrowShape().stroke(Color(hex: 0xB9B9B3), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round, dash: [3, 3])).frame(width: 58, height: 14).offset(x: 211, y: 65)
            ArtPaper(x: 291, y: 40, w: 120, h: 64, r: 7, shadow: false, fill: Color(hex: 0xF1F1EE)) { EmptyView() }
            ArtPaper(x: 303, y: 16, w: 96, h: 52, r: 6) {
                ForEach(Array(["4", "8", "2", "9", "1", "3"].enumerated()), id: \.offset) { index, digit in
                    Text(digit).font(.system(size: 10, weight: .semibold)).frame(width: 12, height: 16).background(V3.field, in: RoundedRectangle(cornerRadius: 3)).offset(x: 5 + CGFloat(index) * 15, y: 10)
                }
                ArtBar(x: 18, y: 34, w: 60, h: 3, r: 1.5)
            }
            EnvelopePocket().fill(.white).overlay(EnvelopePocket().stroke(V3.cl)).frame(width: 120, height: 38).offset(x: 291, y: 66)
            ArtBadge(x: 395, y: 30, symbol: "checkmark", fill: V3.green)
        }.frame(width: 456, height: 120, alignment: .topLeading)
    }
}

private struct DashArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 2, y: 7)); path.addLine(to: CGPoint(x: rect.width - 8, y: 7))
        path.move(to: CGPoint(x: rect.width - 10, y: 3)); path.addLine(to: CGPoint(x: rect.width - 5, y: 7)); path.addLine(to: CGPoint(x: rect.width - 10, y: 11))
        return path
    }
}

private struct EnvelopePocket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0.5, y: 0.5)); path.addLine(to: CGPoint(x: 60, y: 26)); path.addLine(to: CGPoint(x: 119.5, y: 0.5))
        path.addLine(to: CGPoint(x: 119.5, y: 31)); path.addQuadCurve(to: CGPoint(x: 113, y: 37.5), control: CGPoint(x: 119.5, y: 37.5))
        path.addLine(to: CGPoint(x: 7, y: 37.5)); path.addQuadCurve(to: CGPoint(x: 0.5, y: 31), control: CGPoint(x: 0.5, y: 37.5))
        path.closeSubpath()
        return path
    }
}
