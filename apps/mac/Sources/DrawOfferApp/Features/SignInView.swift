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
                    // 左上品牌：DrawOffer 19 粗体 + 求职工作台 12
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("DrawOffer").font(.system(size: 19, weight: .bold)).foregroundStyle(V3.txt)
                        Text("求职工作台").font(V3.sans(12)).foregroundStyle(V3.fnt)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 35).padding(.top, 29)
                    .overlay(alignment: .topTrailing) {
                        if let dismiss {
                            Button("暂不登录", action: dismiss).buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.sub)
                                .padding(.trailing, 35).padding(.top, 29).keyboardShortcut(.cancelAction)
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

    /// 开发环境邮箱登录：对齐 Web AuthPage 的「仅开发环境」表单（标题 → 说明 → 邮箱 / 密码 → 协议 → 黑色登录）。
    private var passwordColumn: some View {
        VStack(spacing: 0) {
            Text("仅开发环境").font(V3.sans(11, weight: .medium)).foregroundStyle(V3.sub)
                .padding(.horizontal, 8).frame(height: 20).background(V3.field, in: Capsule())
            Text("登录 DrawOffer。").font(V3.serif(30)).foregroundStyle(V3.txt).frame(height: 43).padding(.top, 14)
            Text("开发环境支持使用邮箱和密码进入工作台。").font(V3.sans(14)).foregroundStyle(V3.sub).frame(height: 17).padding(.top, 7)
            VStack(alignment: .leading, spacing: 16) {
                passwordField("邮箱", symbol: "envelope") { TextField("you@example.com", text: $email).textContentType(.username) }
                passwordField("密码", symbol: "lock") { SecureField("至少 8 位", text: $password).textContentType(.password) }
            }.frame(width: 320).padding(.top, 34)
            agreement.padding(.top, 22)
            if let error = message ?? session.errorMessage {
                Text(error).font(V3.sans(12)).foregroundStyle(V3.red).multilineTextAlignment(.center).frame(maxWidth: 320).padding(.top, 12)
            }
            Button { submitPassword() } label: {
                HStack(spacing: 6) { Text(submitting ? "登录中…" : "登录"); if !submitting { Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium)) } }
                    .frame(width: 320)
            }
            .buttonStyle(V3ButtonStyle(kind: .dark, height: 40)).keyboardShortcut(.defaultAction)
            .disabled(submitting || !agreed || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty).padding(.top, 20)
        }
    }

    private func passwordField<Field: View>(_ label: String, symbol: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub)
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(V3.fnt).frame(width: 14)
                field().textFieldStyle(.plain).font(V3.sans(14)).disabled(submitting).onSubmit { submitPassword() }
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
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
                AccountSignInQRPlaceholder().blur(radius: 1.6).opacity(0.55)
                VStack(spacing: 4) {
                    Text("请先勾选下方协议").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                    Text("勾选后即可扫码登录").font(V3.sans(12)).foregroundStyle(V3.sub)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.cl))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            } else {
                switch state {
                case .ready(let image): Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 200, height: 200).accessibilityLabel("微信登录二维码")
                case .expired, .failed:
                    VStack(spacing: 12) {
                        Text(state == .expired ? "二维码已过期" : "暂时无法获取二维码").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                        Button(state == .expired ? "刷新二维码" : "重试") { refresh += 1 }.buttonStyle(V3ButtonStyle(kind: .dark, height: 32))
                    }
                case .idle, .loading, .confirming: ProgressView().controlSize(.small)
                }
            }
        }
        .frame(width: 240, height: 240)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(V3.cl))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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

/// A 态的占位二维码：三个定位角 + 固定伪随机方块，#D6D6D1，只作示意（真码在勾选后才取）。
private struct AccountSignInQRPlaceholder: View {
    var body: some View {
        Canvas { context, size in
            let cells = 25, cell = (size.width - 40) / CGFloat(cells), origin = CGPoint(x: 20, y: 20)
            let color = GraphicsContext.Shading.color(Color(hex: 0xD6D6D1))
            func finder(_ col: Int, _ row: Int) {
                let rect = CGRect(x: origin.x + CGFloat(col) * cell, y: origin.y + CGFloat(row) * cell, width: cell * 7, height: cell * 7)
                context.stroke(Path(roundedRect: rect.insetBy(dx: cell / 2, dy: cell / 2), cornerRadius: cell * 1.2), with: color, lineWidth: cell)
                context.fill(Path(roundedRect: rect.insetBy(dx: cell * 2, dy: cell * 2), cornerRadius: cell * 0.6), with: color)
            }
            finder(0, 0); finder(cells - 7, 0); finder(0, cells - 7)
            var seed: UInt32 = 20261027
            for row in 0..<cells {
                for col in 0..<cells {
                    seed = seed &* 1103515245 &+ 12345
                    let inFinder = (row < 8 && col < 8) || (row < 8 && col >= cells - 8) || (row >= cells - 8 && col < 8)
                    if inFinder || (seed >> 16) % 5 > 1 { continue }
                    context.fill(Path(CGRect(x: origin.x + CGFloat(col) * cell, y: origin.y + CGFloat(row) * cell, width: cell, height: cell)), with: color)
                }
            }
        }
        .frame(width: 240, height: 240).accessibilityHidden(true)
    }
}

enum DesktopClient {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
