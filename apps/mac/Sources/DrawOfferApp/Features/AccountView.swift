import AppKit
import DrawOfferCore
import SwiftUI
import UniformTypeIdentifiers

/// `/account` 与 `/account/career-profile`：求职画像是账号下的独立页面，左上角返回账号设置。
struct AccountSection: View {
    @Binding var career: Bool
    var body: some View {
        if career { CareerProfileView(back: { career = false }) }
        else { AccountView(openCareerProfile: { career = true }) }
    }
}

/// 账号设置（macOS 稿 01 页「04 · 账号设置」04.01 定稿）：居中 760 宽的一列——
/// 头像 + 昵称（点笔就地改，04.07）→ 额度（当前方案 / 可用积分，打开会员与积分弹窗，04.05/04.06）
/// → 账号（联系邮箱就地展开 04.09、界面语言行内下拉 04.04）→ API Key → 退出登录（确认 04.10）→ 隐私政策 · 用户协议。
/// 桌面端不提供修改密码、微信绑定和注销账号（后端只接受 Web Cookie）；API Key 在客户端内列出、创建（明文只显示一次）和删除（AccountApiKeys.swift）。
struct AccountView: View {
    @Environment(SessionStore.self) private var session
    @State private var profile: JSONValue?
    @State private var preferences: JSONValue?
    @State private var billing: BillingSummary?
    @State private var savingPreference = false
    @State private var loading = true
    @State private var loadFailed = false
    @State private var reload = UUID()
    @State private var avatar: NSImage?
    @State private var toast: AccountToast?
    @State private var avatarOpen = false
    @State private var logoutOpen = false
    @State private var loggingOut = false
    @State private var plansTab: AccountPlansTab?
    @State private var editingName = false
    @State private var editingEmail = false
    var openCareerProfile: () -> Void = {}

    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }
    private var user: JSONValue { profile?["user"] ?? .null }
    private var initial: String { String((user.text("nickname").trimmingCharacters(in: .whitespaces).nonEmptyValue ?? "我").prefix(1)) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    if loading && profile == nil {
                        V3Loading("正在加载个人资料…").font(V3.sans(13)).frame(maxWidth: .infinity, minHeight: 240).padding(.top, 120)
                    } else if loadFailed, profile == nil {
                        VStack(spacing: 10) {
                            Text("暂时无法读取个人资料").font(V3.serif(18)).foregroundStyle(V3.txt)
                            Text("请检查网络连接后重新加载。").font(V3.sans(13)).foregroundStyle(V3.sub)
                            Button("重新加载") { reload = UUID() }.buttonStyle(V3ButtonStyle(kind: .ghost)).padding(.top, 6)
                        }.frame(maxWidth: .infinity).padding(.top, 160)
                    } else if profile != nil {
                        content
                    }
                }
                .frame(width: min(760, max(320, geometry.size.width - 64)))
                .padding(.top, 64).padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }.scrollIndicators(.never)
        }
        .background(Color.white)
        .overlay(alignment: .top) { if let toast { AccountToastView(toast: toast) { self.toast = nil } } }
        .task(id: "\(account)|\(reload)") { await load() }
        .centeredSheet(isPresented: $avatarOpen) {
            AccountAvatarSheet(user: user, avatar: avatar, close: { avatarOpen = false }, updated: apply,
                               saved: { avatarOpen = false; toast = .init(kind: .success, title: $0) },
                               notice: { toast = .init(kind: .error, title: $0) })
        }
        .centeredSheet(isPresented: $logoutOpen) {
            AccountLogoutSheet(device: profile?["current_session"]?.text("device_label") ?? "", busy: loggingOut, close: { logoutOpen = false }) {
                Task { await logout() }
            }
        }
        .centeredSheet(item: $plansTab, onDismiss: { Task { await loadBilling() } }) { tab in PlansSheet(initialTab: tab.id) }
    }

    @ViewBuilder private var content: some View {
        // 头像 84 圆（墨黑底白字），点开换头像（04.08）
        Button { avatarOpen = true } label: { AvatarCircle(image: avatar, initial: initial, size: 84) }
            .buttonStyle(.plain).accessibilityLabel("更换头像").help("更换头像")
        AccountNameField(name: user.text("nickname"), editing: $editingName) { name in await saveNickname(name) }
            .padding(.top, 21)
        group("额度") {
            AccountRow(label: "当前方案", value: billing?.tierLabel ?? "—") { plansTab = .init(id: nil) }
            AccountRow(label: "可用积分", value: billing.map(\.availableText) ?? "—", warn: billing?.exhausted == true) { plansTab = .init(id: "credits") }
        }.padding(.top, 37)
        group("账号") {
            AccountEmailRow(email: user.text("contact_email").nonEmptyValue, editing: $editingEmail) { email in await saveEmail(email) }
            AccountRow(label: "界面语言", value: nil) {} trailing: {
                AccountLanguageMenu(value: preferences?.text("locale").nonEmptyValue ?? "zh-CN", disabled: preferences == nil || savingPreference) { locale in
                    Task { await savePreference(locale) }
                }
            }
            // 组尾说明：「求职画像」可点，进入求职画像页
            HStack(spacing: 0) {
                Text("联系邮箱只用于找回账号；网申要填的电话、邮箱在")
                Button("「求职画像」", action: openCareerProfile).buttonStyle(.plain).foregroundStyle(V3.link)
                Text("里。")
            }.font(V3.sans(12)).foregroundStyle(V3.fnt).frame(height: 14).padding(.top, 7)
        }.padding(.top, 41)
        AccountApiKeySection(notify: { toast = $0 }).padding(.top, 47)
        // 退出登录：上下细线，红字浅红底胶囊
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("退出登录").font(V3.sans(14)).foregroundStyle(V3.txt)
                Text("只退出当前设备，其他设备不受影响").font(V3.sans(12)).foregroundStyle(V3.fnt)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("退出登录") { logoutOpen = true }.buttonStyle(AccountDangerPillStyle())
        }
        .frame(height: 64)
        .overlay(alignment: .top) { AccountHairline() }.overlay(alignment: .bottom) { AccountHairline() }
        .padding(.top, 47)
        HStack(spacing: 12) {
            Button("隐私政策") { WebBridge.open("/privacy", api: session.api) }.buttonStyle(.plain).foregroundStyle(V3.blue)
            Text("·").foregroundStyle(Color(hex: 0xA8A8A4))
            Button("用户协议") { WebBridge.open("/terms", api: session.api) }.buttonStyle(.plain).foregroundStyle(V3.blue)
        }.font(V3.sans(12)).padding(.top, 40)
    }

    /// 分组：15/500 标题，下方 6 起细线，行 50 高、行间细线。
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt).frame(height: 18).padding(.bottom, 6)
            AccountHairline()
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
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
        async let billingTask: Void = loadBilling()
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
        _ = await (preferenceTask, billingTask)
    }

    private func loadPreferences() async {
        preferences = try? await session.api.careerRequest(path: "/api/account/preferences", method: "GET", query: [:], body: nil)
    }

    private func loadBilling() async {
        if let value = try? await session.api.careerRequest(path: "/api/billing/summary", method: "GET", query: [:], body: nil) { billing = BillingSummary(json: value) }
    }

    private func loadAvatar() async {
        let path = user.text("avatar_url")
        guard !path.isEmpty else { avatar = nil; return }
        if path.hasPrefix("/api/auth/default-avatar") { avatar = Bundle.module.url(forResource: "AppIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:)); return }
        avatar = (try? await session.api.accountAvatar(path: path)).flatMap(NSImage.init(data:))
    }

    /// 返回 nil 表示保存成功，否则是要显示在输入框下的错误。
    private func saveNickname(_ name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 50 else { return "昵称需要 1–50 个字符。" }
        guard trimmed != user.text("nickname") else { return nil }
        do {
            apply(try await session.api.careerRequest(path: "/api/account/profile", method: "PATCH", query: [:], body: .object(["nickname": .string(trimmed)])))
            toast = .init(kind: .success, title: "昵称已保存")
            return nil
        } catch { return AccountRequest.errorMessage(error, fallback: "昵称保存失败，请稍后重试。") }
    }

    private func saveEmail(_ email: String) async -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || trimmed.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else { return "请输入有效的邮箱地址。" }
        do {
            let result = try await session.api.careerRequest(path: "/api/account/contact-email", method: "PUT", query: [:], body: .object(["email": trimmed.isEmpty ? .null : .string(trimmed)]))
            var next = user
            if case .object(var fields) = next { fields["contact_email"] = result["contact_email"] ?? .null; next = .object(fields) }
            apply(next)
            toast = .init(kind: .success, title: trimmed.isEmpty ? "联系邮箱已清除" : "联系邮箱已保存")
            return nil
        } catch { return AccountRequest.errorMessage(error, fallback: "联系邮箱保存失败，请重试。") }
    }

    private func savePreference(_ locale: String) async {
        guard !savingPreference else { return }
        savingPreference = true
        defer { savingPreference = false }
        do {
            preferences = try await session.api.careerRequest(path: "/api/account/preferences", method: "PATCH", query: [:], body: .object(["locale": .string(locale)]))
        } catch { toast = .init(kind: .error, title: AccountRequest.errorMessage(error, fallback: "偏好保存失败，请重试。")) }
    }

    private func logout() async {
        guard !loggingOut else { return }
        loggingOut = true
        await session.signOut()
        loggingOut = false
        logoutOpen = false
    }
}

/// 会员与积分弹窗打开在哪个标签（nil 为会员方案）。
struct AccountPlansTab: Identifiable { let id: String? }

// MARK: - 共用小件

struct AccountHairline: View {
    var body: some View { Rectangle().fill(V3.line).frame(height: 1) }
}

/// 一行设置：50 高，左 14 标签，右 14 sub 值 + 细箭头；整行可点，悬停只把箭头加深（不加灰底）。
private struct AccountRow<Trailing: View>: View {
    let label: String
    let value: String?
    var warn = false
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @State private var hover = false

    var body: some View {
        let row = HStack(spacing: 10) {
            Text(label).font(V3.sans(14)).foregroundStyle(V3.txt)
            Spacer(minLength: 12)
            if let value {
                Text(value).font(V3.sans(14)).foregroundStyle(warn ? V3.red : V3.sub).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(hover ? V3.sub : V3.fnt2)
            }
            trailing()
        }
        .frame(height: 49).padding(.bottom, 1)
        .overlay(alignment: .bottom) { AccountHairline() }
        .contentShape(Rectangle())
        if value != nil {
            Button(action: action) { row }.buttonStyle(.plain).onHover { hover = $0 }.accessibilityLabel("\(label)：\(value ?? "")")
        } else { row }
    }
}

extension AccountRow where Trailing == EmptyView {
    init(label: String, value: String?, warn: Bool = false, action: @escaping () -> Void) {
        self.init(label: label, value: value, warn: warn, action: action, trailing: { EmptyView() })
    }
}

/// 04.01 / 04.07：宋体 24 昵称 + 小笔；点笔就地变成 1px 墨黑描边的输入框，回车保存、Esc 取消。
private struct AccountNameField: View {
    let name: String
    @Binding var editing: Bool
    let save: (String) async -> String?
    @State private var draft = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if editing {
                TextField("", text: $draft).textFieldStyle(.plain).font(V3.serif(24)).foregroundStyle(V3.txt).multilineTextAlignment(.center)
                    .focused($focused).disabled(saving)
                    .frame(width: 219, height: 43)
                    .overlay(RoundedRectangle(cornerRadius: 7.5).stroke(error == nil ? V3.txt : V3.red))
                    .onSubmit { Task { await commit() } }
                    .onExitCommand { cancel() }
                    .onChange(of: draft) { if draft.count > 50 { draft = String(draft.prefix(50)) } }
                    .onAppear { draft = name; focused = true }
                    .accessibilityLabel("昵称")
                Text(error ?? "回车保存 · Esc 取消 · 最多 50 个字").font(V3.sans(12)).foregroundStyle(error == nil ? V3.fnt : V3.red)
            } else {
                HStack(spacing: 4) {
                    Text(name.nonEmptyValue ?? "未设置昵称").font(V3.serif(24)).foregroundStyle(V3.txt).lineLimit(1)
                    Button { error = nil; editing = true } label: {
                        Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(V3.fnt).frame(width: 20, height: 20).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("修改昵称").help("修改昵称")
                }.padding(.leading, 24).frame(height: 34)
            }
        }
    }

    private func cancel() { editing = false; error = nil }

    private func commit() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        if let message = await save(draft) { error = message } else { editing = false; error = nil }
    }
}

/// 04.09：联系邮箱就地展开——输入框 + 取消 + 墨黑小「保存」，保存后收起；留空即清除。
private struct AccountEmailRow: View {
    let email: String?
    @Binding var editing: Bool
    let save: (String) async -> String?
    @State private var draft = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 0) {
                Text("联系邮箱").font(V3.sans(14)).foregroundStyle(V3.txt).frame(height: 17).padding(.top, 16)
                HStack(spacing: 10) {
                    TextField("", text: $draft, prompt: Text("you@example.com").foregroundStyle(V3.fnt2)).textFieldStyle(.plain)
                        .font(V3.sans(14)).foregroundStyle(V3.txt).focused($focused).disabled(saving)
                        .padding(.horizontal, 12).frame(height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(error == nil ? V3.txt : V3.red))
                        .onSubmit { Task { await commit() } }
                        .onExitCommand { editing = false }
                        .accessibilityLabel("联系邮箱")
                    Button("取消") { editing = false }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.fnt).disabled(saving)
                    Button(saving ? "保存中…" : "保存") { Task { await commit() } }.buttonStyle(AccountPillButtonStyle(kind: .dark, width: 64, height: 28, size: 13))
                        .disabled(saving || draft.trimmingCharacters(in: .whitespaces) == (email ?? ""))
                }.padding(.top, 14)
                // 稿内没有提示行：校验失败时才在输入框下显示红字；留空保存即清除联系邮箱
                if let error { Text(error).font(V3.sans(12)).foregroundStyle(V3.red).padding(.top, 8) }
                Color.clear.frame(height: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { AccountHairline() }
            .onAppear { draft = email ?? ""; error = nil; focused = true }
        } else {
            AccountRow(label: "联系邮箱", value: email ?? "未设置") { editing = true }
        }
    }

    private func commit() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        if let message = await save(draft) { error = message } else { editing = false }
    }
}

/// 04.04：界面语言行内小下拉，选完立即生效。
private struct AccountLanguageMenu: View {
    let value: String
    let disabled: Bool
    let change: (String) -> Void
    private let options = [("zh-CN", "简体中文"), ("en-US", "English")]
    @State private var hover = false
    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button { if option.0 != value { change(option.0) } } label: {
                    if option.0 == value { Label(option.1, systemImage: "checkmark") } else { Text(option.1) }
                }
            }
        } label: {
            // 04.01：静止时就是右对齐的 14 sub 文字（无箭头）；04.04：悬停 / 展开时出现 73×25 的描边小下拉。
            // 文字左右各 10.5 的内边距靠负的 trailing 抵回，静止态文字仍贴齐右边线。
            Text(options.first { $0.0 == value }?.1 ?? "简体中文").font(V3.sans(14)).foregroundStyle(V3.sub)
                .padding(.horizontal, 10.5).frame(height: 25)
                .overlay(RoundedRectangle(cornerRadius: 7.5).stroke(hover ? V3.cl : Color.clear))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(disabled).accessibilityLabel("界面语言")
        .onHover { hover = $0 }.padding(.trailing, -10.5)
    }
}

/// 退出登录：#FDF0F0 底、#D64545 字的 33 高胶囊。
private struct AccountDangerPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(14, weight: .medium)).foregroundStyle(V3.red)
            .padding(.horizontal, 16).frame(height: 33)
            .background(configuration.isPressed ? Color(hex: 0xF9E3E3) : Color(hex: 0xFDF0F0), in: Capsule())
            .contentShape(Capsule())
    }
}

/// 弹窗里的胶囊按钮（稿内 `DrawOffer / V3 / Button`）：墨黑实心 / 白底浅描边，14 中粗字，32 高；`width` 为最小宽度。
struct AccountPillButtonStyle: ButtonStyle {
    enum Kind { case dark, ghost }
    var kind: Kind
    var width: CGFloat? = nil
    var height: CGFloat = 32
    var size: CGFloat = 14
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label.font(V3.sans(size, weight: .medium)).lineLimit(1).fixedSize()
            .foregroundStyle(kind == .dark ? Color.white : V3.txt)
            .padding(.horizontal, 16).frame(minWidth: width, minHeight: height, maxHeight: height)
            .background {
                switch kind {
                case .dark: Capsule().fill(pressed ? Color(hex: 0x0E0E0D) : V3.txt)
                case .ghost: Capsule().fill(pressed ? V3.field : Color.white).overlay(Capsule().stroke(V3.cl))
                }
            }
            .opacity(enabled ? 1 : 0.38).contentShape(Capsule())
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

/// 账号页与求职画像的提示：走第 16 页「顶部提示栏统一」的 `NoticeToast`，居中浮在页面顶部 20pt。
struct AccountToastView: View {
    let toast: AccountToast
    let dismiss: () -> Void
    @State private var item: NoticeToastItem?
    var body: some View {
        NoticeToast(item: $item).padding(.top, 20)
            .onAppear { item = Self.item(toast) }
            .onChange(of: toast) { _, next in item = Self.item(next) }
            .onChange(of: item) { _, next in if next == nil { dismiss() } }
    }
    private static func item(_ toast: AccountToast) -> NoticeToastItem {
        switch toast.kind {
        case .success: return .done(toast.title, toast.message)
        case .error: return .failed(toast.title, toast.message)
        case .warn: return .attention(toast.title, toast.message)
        }
    }
}

// MARK: - 04.08 换头像（460 宽）

private struct AccountAvatarSheet: View {
    @Environment(SessionStore.self) private var session
    let user: JSONValue
    let avatar: NSImage?
    let close: () -> Void
    let updated: (JSONValue) -> Void
    let saved: (String) -> Void
    let notice: (String) -> Void

    @State private var image: NSImage?
    @State private var draft: AvatarCrop.Draft?
    @State private var removeAvatar = false
    @State private var saving = false
    @State private var error: String?
    @State private var dragStart: AvatarCrop.Draft?

    /// 裁剪区 412×240，圆窗直径 178（04.08，按 178/264 缩小显示）。
    private let scale = 178 / AvatarCrop.window
    private var currentAvatar: NSImage? { removeAvatar ? nil : avatar }
    private var initial: String { String((user.text("nickname").nonEmptyValue ?? "我").prefix(1)) }
    private var changed: Bool { draft != nil || (removeAvatar && !user.text("avatar_url").isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("换头像").font(V3.sans(18, weight: .medium)).foregroundStyle(V3.txt).frame(height: 22).padding(.top, 4)
            Text("支持 JPG、PNG、WebP，最大 10 MB。").font(V3.sans(13)).foregroundStyle(V3.fnt).frame(height: 16).padding(.top, 12)
            crop.padding(.top, 20)
            HStack(spacing: 14) {
                Text("缩放").font(V3.sans(13)).foregroundStyle(V3.fnt)
                Slider(value: Binding(get: { draft?.zoom ?? 1 }, set: { value in if var next = draft { next.zoom = value; draft = AvatarCrop.clamp(next) } }),
                       in: AvatarCrop.minZoom...AvatarCrop.maxZoom).controlSize(.small).tint(V3.txt).disabled(draft == nil || saving).accessibilityLabel("缩放")
            }.frame(height: 21).padding(.top, 20)
            if let error { Text(error).font(V3.sans(12)).foregroundStyle(V3.red).padding(.top, 10) }
            HStack(spacing: 16) {
                Button { Task { await pick() } } label: {
                    HStack(spacing: 2) { Image(systemName: "arrow.up.to.line").font(.system(size: 13)); Text("重新选择") }
                }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(Color(hex: 0x2966D9)).disabled(saving)
                Button("移除头像") { draft = nil; image = nil; removeAvatar = true }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.fnt)
                    .disabled(saving || (draft == nil && currentAvatar == nil)).opacity(saving || (draft == nil && currentAvatar == nil) ? 0.4 : 1)
                Spacer()
                HStack(spacing: 8) {
                    Button("取消", action: close).buttonStyle(AccountPillButtonStyle(kind: .ghost, width: 79)).disabled(saving)
                    Button(saving ? "保存中…" : "保存") { Task { await save() } }.buttonStyle(AccountPillButtonStyle(kind: .dark, width: 100))
                        .disabled(saving || !changed).keyboardShortcut(.defaultAction)
                }
            }.padding(.top, 20)
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20).frame(width: 460)
        .background { Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true).disabled(saving) }
    }

    /// 412×240、圆角 10 的深色区；圆窗外 45% 墨黑遮罩 + 白色描边；还没选图时底部有「点击选择图片」提示（稿内选图后无提示）。
    private var crop: some View {
        let window = AvatarCrop.window * scale
        return ZStack {
            V3.txt
            Group {
                if let draft, let image {
                    let layout = AvatarCrop.layout(draft)
                    Image(nsImage: image).resizable().frame(width: layout.renderedWidth * scale, height: layout.renderedHeight * scale)
                        .offset(x: draft.offsetX * scale, y: draft.offsetY * scale)
                } else {
                    AvatarCircle(image: currentAvatar, initial: initial, size: window)
                }
            }
            Rectangle().fill(V3.txt.opacity(0.45))
                .mask { Rectangle().overlay(Circle().frame(width: window, height: window).blendMode(.destinationOut)).compositingGroup() }
            Circle().stroke(.white, lineWidth: 2).frame(width: window, height: window)
            if draft == nil {
                Text("点击选择图片").font(V3.sans(11, weight: .medium)).foregroundStyle(.white).padding(.horizontal, 12).frame(height: 22)
                    .background(V3.txt.opacity(0.8), in: Capsule()).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 10)
            }
        }
        .frame(width: 412, height: 240).clipShape(RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
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
        .accessibilityElement().accessibilityLabel(draft == nil ? "头像区域，点击选择图片" : "头像裁剪区域，可拖动调整")
        .accessibilityAddTraits(.isButton).accessibilityAction { if draft == nil { Task { await pick() } } }
    }

    private func pick() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 10 * 1024 * 1024 { notice("头像图片不能超过 10MB。"); return }
        guard let picked = NSImage(contentsOf: url), let cg = picked.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width > 0, cg.height > 0 else {
            notice("头像图片无法读取，请选择其他图片。"); return
        }
        image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        draft = AvatarCrop.Draft(width: Double(cg.width), height: Double(cg.height))
        removeAvatar = false
        error = nil
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

    /// 新头像上传或移除头像；失败保留弹窗和裁剪状态。
    private func save() async {
        guard !saving, changed else { return }
        saving = true; error = nil
        defer { saving = false }
        var latest = user
        if draft != nil {
            do {
                guard let png = cropped() else { throw APIError.invalidResponse }
                let result = try await session.api.careerRequest(path: "/api/account/avatar", method: "PUT", query: [:],
                    body: .object(["fileName": .string("avatar.png"), "dataUrl": .string("data:image/png;base64," + png.base64EncodedString())]))
                if case .object(var fields) = latest { fields["avatar_url"] = result["url"] ?? .null; latest = .object(fields) }
                updated(latest)
                saved("头像已更新")
            } catch { self.error = AccountRequest.errorMessage(error, fallback: "头像处理或上传失败，请重试。") }
        } else {
            do {
                _ = try await session.api.careerRequest(path: "/api/account/avatar", method: "DELETE", query: [:], body: nil)
                if case .object(var fields) = latest { fields["avatar_url"] = .null; latest = .object(fields) }
                updated(latest)
                saved("头像已移除")
            } catch { self.error = AccountRequest.errorMessage(error, fallback: "头像删除失败，请稍后重试。") }
        }
    }
}

// MARK: - 04.10 退出登录确认（460 宽）

private struct AccountLogoutSheet: View {
    let device: String
    let busy: Bool
    let close: () -> Void
    let confirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("退出登录？").font(V3.sans(18, weight: .medium)).foregroundStyle(V3.txt).frame(height: 22).padding(.top, 4)
            Text(device.isEmpty ? "只退出当前设备，其他设备上的登录不受影响。" : "只退出当前设备（\(device)），其他设备上的登录不受影响。")
                .font(V3.sans(13)).foregroundStyle(V3.fnt).lineHeight(13, 18).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: close).buttonStyle(AccountPillButtonStyle(kind: .ghost, width: 79)).disabled(busy)
                Button(busy ? "正在退出…" : "退出登录", action: confirm).buttonStyle(AccountPillButtonStyle(kind: .dark, width: 100)).disabled(busy).keyboardShortcut(.defaultAction)
            }.padding(.top, 20)
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 20).frame(width: 460, alignment: .leading)
        .background { Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true).disabled(busy) }
    }
}
