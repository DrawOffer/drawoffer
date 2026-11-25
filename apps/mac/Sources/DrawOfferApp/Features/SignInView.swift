import AppKit
import Foundation
import DrawOfferCore
import SwiftUI

/// 登录（macOS 稿 01 页「02 · 登录页 · 生产环境」37:1135）：微信扫码登录 DrawOffer。
/// A 未勾选协议：二维码虚化，上面叠「请先勾选下方协议」；B 勾选后显示小程序码并轮询；
/// C 手机上确认后只显示加载，不单独做「已扫码」（与 Web 一致，后端也没有扫码未确认这一态）；D 过期换成「二维码已过期 · 刷新二维码」。
/// 后端没开微信登录（开发环境）时，二维码框里换成「在浏览器中登录」，授权码经 `drawoffer://auth/callback` 回到客户端。
struct SignInView: View {
    @Environment(SessionStore.self) private var session
    /// true：整窗登录页（左上品牌、底部版权）；默认只画中间一列，放进登录弹窗。
    var fullPage = false
    /// 整窗登录页右上角的「暂不登录」；为空时不显示。
    var dismiss: (() -> Void)? = nil

    @State private var agreed = false
    @State private var capabilities: DesktopCapabilities?
    @State private var state: QRState = .idle
    @State private var refresh = 0
    @State private var message: String?
    @State private var opening = false
    @State private var email = ""
    @State private var password = ""
    @State private var submitting = false

    enum QRState: Equatable { case idle, loading, ready(NSImage), confirming, expired, failed }

    private var wechat: Bool { capabilities?.wechat_login_enabled ?? true }
    /// 与 Web 一致：开发/本地环境（服务端 password_login_enabled）在客户端内用邮箱密码登录，不再跳浏览器。
    private var passwordMode: Bool { !wechat && capabilities?.password_login_enabled == true }

    var body: some View {
        ZStack {
            column
            if fullPage {
                VStack(spacing: 0) {
                    // 左上品牌（Brand/Lockup，Web drawoffer-lockup.png 高 22）+ 求职工作台 12，距左 35.5、距顶 34。
                    HStack(spacing: 8) {
                        SignInLockup()
                        Text("求职工作台").font(V3.sans(12)).foregroundStyle(V3.fnt)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 35.5).padding(.top, 34)
                    .overlay(alignment: .topTrailing) {
                        // 右上「暂不登录」（稿 E 125:445）。生产稿 A/B/D 此处是界面语言，Mac 端还没有英文文案，暂不放。
                        if let dismiss {
                            Button("暂不登录", action: dismiss).buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.sub)
                                .padding(.trailing, 35.5).padding(.top, 33).keyboardShortcut(.cancelAction)
                        }
                    }
                    Spacer()
                    Text("© 2026 DrawOffer").font(V3.sans(12)).foregroundStyle(V3.fnt2).padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .task { capabilities = try? await (session.api as? HTTPAPIClient)?.capabilities() }
        .task(id: "\(agreed)|\(refresh)|\(wechat)") { await runQR() }
    }

    /// 登录列：标题 30 宋体 → 说明 14（距 7）→ 240 方框（距 38）→ 提示 13（距 18）→ 协议（距 36）。
    @ViewBuilder private var column: some View {
        if passwordMode { passwordColumn } else { wechatColumn }
    }

    /// 开发环境邮箱登录（稿 E 125:419）：仅开发环境标签 → 标题 → 说明 → 邮箱 / 密码 → 协议 → 320×40 墨黑胶囊「登录 →」。
    /// 稿里协议只有文字；与 Web AuthPage 一致保留复选框，未勾选不能登录。
    private var passwordColumn: some View {
        VStack(spacing: 0) {
            Text("仅开发环境").font(V3.sans(11)).foregroundStyle(V3.sub)
                .padding(.horizontal, 8).padding(.vertical, 3).background(Color(hex: 0xF3F3F1), in: RoundedRectangle(cornerRadius: 10))
            Text("登录 DrawOffer。").font(V3.serif(30)).foregroundStyle(V3.txt).frame(height: 43).padding(.top, 14)
            Text("开发环境支持使用邮箱和密码进入工作台。").font(V3.sans(14)).foregroundStyle(V3.sub).frame(height: 17).padding(.top, 7)
            VStack(alignment: .leading, spacing: 16) {
                passwordField("邮箱") { TextField("邮箱", text: $email, prompt: Text("you@example.com").foregroundStyle(V3Skeleton.faint)).textContentType(.username) }
                passwordField("密码") { SecureField("密码", text: $password, prompt: Text("至少 8 位").foregroundStyle(V3Skeleton.faint)).textContentType(.password) }
            }.frame(width: 320).padding(.top, 34)
            agreement.padding(.top, 22)
            if let error = message ?? session.errorMessage {
                Text(error).font(V3.sans(12)).foregroundStyle(V3.red).multilineTextAlignment(.center).frame(maxWidth: 320).padding(.top, 12)
            }
            Button { submitPassword() } label: { Text(submitting ? "登录中…" : "登录  →") }
                .buttonStyle(SignInSubmitStyle()).keyboardShortcut(.defaultAction)
                .disabled(submitting || !agreed || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty).padding(.top, 20)
        }
    }

    /// 字段：12 号 sub 标签，下距 6 是 320×40 白底、圆角 8、#E4E4E0 描边的输入框（左右 12，无图标）。
    private func passwordField<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(V3.sans(12)).foregroundStyle(V3.sub)
            field().textFieldStyle(.plain).font(V3.sans(14)).disabled(submitting).onSubmit { submitPassword() }
                .padding(.horizontal, 12).frame(height: 40)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(V3.cl))
        }
    }

    private func submitPassword() {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard agreed, !submitting, !address.isEmpty, !password.isEmpty else { return }
        submitting = true
        message = nil
        Task { @MainActor in
            await session.signIn(email: address, password: password)
            submitting = false
            if case .signedIn = session.phase { password = "" }
        }
    }

    private var wechatColumn: some View {
        VStack(spacing: 0) {
            Text("微信扫码登录 DrawOffer").font(V3.serif(30)).foregroundStyle(V3.txt).frame(height: 43)
            Text("首次扫码会自动创建账号，无需填写表单。").font(V3.sans(14)).foregroundStyle(V3.sub).frame(height: 17).padding(.top, 7)
            box.padding(.top, 38)
            hint.frame(height: 16).padding(.top, 18)
            agreement.padding(.top, 36)
            if let error = message ?? session.errorMessage {
                Text(error).font(V3.sans(12)).foregroundStyle(V3.red).multilineTextAlignment(.center).frame(maxWidth: 320).padding(.top, 14)
            }
            if case .restoring = session.phase {
                Button("重试恢复登录") { Task { await session.restore() } }.buttonStyle(.link).font(V3.sans(12)).padding(.top, 8)
            }
        }
    }

    /// 240×240 白底、圆角 16、#E4E4E0 描边的二维码框。
    private var box: some View {
        ZStack {
            if !wechat, capabilities?.browser_login_enabled == true { browserLogin }
            else if !wechat { loginUnavailable }
            else if !agreed {
                // A（36:6726）：示意码上整块盖 82% 白，中间 157×61 白卡（圆角 9.5、#E4E4E0 描边、无阴影）。
                AccountSignInQRPlaceholder()
                Color.white.opacity(0.82)
                VStack(spacing: 2) {
                    Text("请先勾选下方协议").font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt)
                    Text("勾选后即可扫码登录").font(V3.sans(12)).foregroundStyle(V3.fnt)
                }
                .frame(width: 157, height: 61)
                .background(.white, in: RoundedRectangle(cornerRadius: 9.5))
                .overlay(RoundedRectangle(cornerRadius: 9.5).stroke(V3.cl))
            } else {
                switch state {
                case .ready(let image): Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 200, height: 200).accessibilityLabel("微信登录二维码")
                case .expired, .failed:
                    // D（36:5932）：整框白底，「二维码已过期」15 中黑，下距 8 是 32 高墨黑主按钮。
                    VStack(spacing: 8) {
                        Text(state == .expired ? "二维码已过期" : "暂时无法获取二维码").font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt)
                        Button(state == .expired ? "刷新二维码" : "重试") { refresh += 1 }.buttonStyle(SignInProminentStyle())
                    }
                case .idle, .loading, .confirming: ProgressView().controlSize(.small)
                }
            }
        }
        .frame(width: 240, height: 240)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(V3.cl))
    }

    /// 服务端扫码、浏览器、邮箱三种桌面登录都没开（通常是没配 AUTH_DESKTOP_RETRY_ENCRYPTION_KEY）：同 Web，提示暂不可用并可重试。
    private var loginUnavailable: some View {
        VStack(spacing: 12) {
            if capabilities == nil { ProgressView().controlSize(.small) }
            else {
                Text("登录服务暂时不可用，请稍后重试。").font(V3.sans(13)).foregroundStyle(V3.sub).multilineTextAlignment(.center)
                Button("重试") { Task { capabilities = try? await (session.api as? HTTPAPIClient)?.capabilities() } }
                    .buttonStyle(V3ButtonStyle(kind: .ghost, height: 30))
            }
        }.padding(20)
    }

    /// 开发环境没有微信登录：框里放「在浏览器中登录」，同样要先勾选协议。
    private var browserLogin: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari").font(.system(size: 28, weight: .light)).foregroundStyle(V3.fnt)
            Text(session.browserLoginPending ? "已在浏览器打开登录页" : "在浏览器中完成登录").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
            Button(session.browserLoginPending ? "重新打开" : "在浏览器中登录") { openBrowser() }
                .buttonStyle(V3ButtonStyle(kind: .dark, height: 32)).disabled(opening || !agreed)
        }.padding(20)
    }

    @ViewBuilder private var hint: some View {
        Text(wechat ? "打开微信扫一扫，在手机上确认登录" : capabilities?.browser_login_enabled == true ? "登录后会自动回到客户端" : " ").font(V3.sans(13)).foregroundStyle(V3.fnt)
    }

    /// 协议：原生复选框 + 13 号 sub 文字，《用户协议》《隐私政策》用 #2E53AA 文字链。
    private var agreement: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $agreed).toggleStyle(.checkbox).labelsHidden().accessibilityLabel("我已阅读并同意用户协议和隐私政策")
            HStack(spacing: 0) {
                Text("我已阅读并同意").foregroundStyle(V3.sub).onTapGesture { agreed.toggle() }
                Button("《用户协议》") { WebBridge.open("/terms", api: session.api) }.buttonStyle(.plain).foregroundStyle(V3.link)
                Text("和").foregroundStyle(V3.sub)
                Button("《隐私政策》") { WebBridge.open("/privacy", api: session.api) }.buttonStyle(.plain).foregroundStyle(V3.link)
            }.font(V3.sans(13))
        }.frame(height: 20)
    }

    // MARK: 动作

    /// 勾选后取码并按后端给的间隔轮询；确认后换取令牌，过期或取消就停在 D 态等用户刷新。
    private func runQR() async {
        guard wechat, agreed, let client = session.api as? HTTPAPIClient else { state = .idle; return }
        message = nil
        state = .loading
        let challenge: DesktopLoginChallenge
        do { challenge = try await client.beginLogin(clientVersion: DesktopClient.version) }
        catch is CancellationError { return }
        catch {
            if Task.isCancelled { return }
            state = .failed; return
        }
        guard let data = Data(base64Encoded: challenge.qrcode.qr_base64), let image = NSImage(data: data) else { state = .failed; return }
        state = .ready(image)
        let deadline = Date().addingTimeInterval(TimeInterval(max(30, challenge.qrcode.expires_in)))
        let interval = max(1, challenge.qrcode.poll_interval_seconds)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }
            if Date() >= deadline { state = .expired; return }
            guard let status = try? await client.loginStatus(challenge) else { continue }
            switch status {
            case "confirmed", "consumed":
                state = .confirming
                do { try await session.completeDesktopLogin(challenge) }
                catch is CancellationError { return }
                catch {
                    if Task.isCancelled { return }
                    message = "登录未完成，请刷新二维码后重新扫码。"
                    state = .expired
                }
                return
            case "expired", "cancelled": state = .expired; return
            default: continue
            }
        }
    }

    private func openBrowser() {
        opening = true
        message = nil
        Task { @MainActor in
            defer { opening = false }
            do {
                let url = try await session.beginBrowserLogin(clientVersion: DesktopClient.version)
                if !DebugSnapshot.recordBrowserURL(url) { NSWorkspace.shared.open(url) }
            } catch {
                message = "暂时无法打开登录页，请检查网络后重试。"
            }
        }
    }
}

/// 左上品牌字标（Web `assets/drawoffer-lockup.png`，稿 Brand/Lockup 高 22）。
private struct SignInLockup: View {
    private static let image: NSImage? = Bundle.module.url(forResource: "lockup", withExtension: "png", subdirectory: "Branding").flatMap(NSImage.init(contentsOf:))
    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(height: 22).accessibilityLabel("DrawOffer")
        } else {
            Text("DrawOffer").font(.system(size: 19, weight: .bold)).foregroundStyle(V3.txt)
        }
    }
}

/// D 态「刷新二维码」（macOS / Button / Prominent）：32 高、左右 16、圆角 8 的墨黑按钮，13 中黑白字。
private struct SignInProminentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(13, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 32)
            .background(configuration.isPressed ? Color(hex: 0x0E0E0D) : V3.txt, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 稿 E「登录 →」：320×40 #1C1C1B 胶囊，14 号白字。
private struct SignInSubmitStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(14)).foregroundStyle(.white)
            .frame(width: 320, height: 40)
            .background(configuration.isPressed ? Color(hex: 0x0E0E0D) : Color(hex: 0x1C1C1B), in: Capsule())
            .opacity(enabled ? 1 : 0.38)
            .contentShape(Capsule())
    }
}

/// A 态的示意二维码（稿 Login/QR 36:6513）：200×200、距框 20；三个定位角 56/40/24（圆角 10/6/3），
/// 其余 8×8 圆角 1.5 的 #1D1D1B 方块照稿逐格排布，中间 40×40 白底圆角 8 的「D」。真码在勾选后才取。
private struct AccountSignInQRPlaceholder: View {
    /// 25×25 格，`#` 为方块（定位角另画）。
    private static let modules = [
        ".........#......#........",
        ".........##.####.........",
        "...........#.##.#........",
        ".........##..............",
        "........###.##.#.........",
        ".........##.##..#........",
        "..........#.##..#........",
        "........###.##...........",
        ".###..##.##..##.##.#.#..#",
        "#.###.####.#.....####....",
        "..#..##........#####..#.#",
        "#....#.#.#.....#.#.##.#..",
        "#.#..#...#......##..#.###",
        "#...##.###.....#..#.#.#.#",
        "##.#.#####.....#.#####...",
        ".##..##..#####......#....",
        "....#.#.....#.#.#.#..###.",
        "........####...#...#..###",
        "........###.........###..",
        "........##....###..#.###.",
        ".........###..###.#..#...",
        "................##....#.#",
        "..........#..#.###..#...#",
        "........###.###.....#.###",
        ".........####...#.###.#..",
    ]

    var body: some View {
        Canvas { context, _ in
            let ink = GraphicsContext.Shading.color(V3.txt), paper = GraphicsContext.Shading.color(.white)
            let origin = CGPoint(x: 20, y: 20), cell: CGFloat = 8
            func box(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat, _ radius: CGFloat, _ shading: GraphicsContext.Shading) {
                context.fill(Path(roundedRect: CGRect(x: origin.x + x, y: origin.y + y, width: side, height: side), cornerRadius: radius), with: shading)
            }
            for (x, y) in [(CGFloat(0), CGFloat(0)), (144, 0), (0, 144)] {
                box(x, y, 56, 10, ink); box(x + 8, y + 8, 40, 6, paper); box(x + 16, y + 16, 24, 3, ink)
            }
            for (row, line) in Self.modules.enumerated() {
                for (col, mark) in line.enumerated() where mark == "#" {
                    box(CGFloat(col) * cell, CGFloat(row) * cell, cell, 1.5, ink)
                }
            }
            box(80, 80, 40, 8, paper)
            context.draw(Text("D").font(.system(size: 20, weight: .bold)).foregroundStyle(V3.txt), at: CGPoint(x: origin.x + 100, y: origin.y + 100))
        }
        .frame(width: 240, height: 240).accessibilityHidden(true)
    }
}

enum DesktopClient {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
