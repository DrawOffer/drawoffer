import Foundation
import Observation

/// 登录态。整个 App 共享一个实例；工作区始终开放，`phase` 控制账号操作与登录弹窗。
@MainActor
@Observable
public final class SessionStore {
    public enum Phase: Equatable {
        case restoring
        case signedOut
        case signedIn(User)
    }

    public private(set) var phase: Phase = .restoring
    public private(set) var errorMessage: String?
    public let api: any APIClient
    private var operation = 0

    public init(api: any APIClient) {
        self.api = api
    }

    /// 账号页改昵称后同步侧栏；只更新同一账号，不改变登录状态。
    public func updateNickname(_ nickname: String) {
        guard case .signedIn(let user) = phase, !nickname.isEmpty else { return }
        phase = .signedIn(User(id: user.id, email: user.email, nickname: nickname, isAdmin: user.isAdmin, avatarURL: user.avatarURL))
    }

    public func restore() async {
        operation += 1
        let current = operation
        errorMessage = nil
        do {
            let user = try await api.currentUser()
            guard current == operation else { return }
            phase = user.map(Phase.signedIn) ?? .signedOut
        } catch APIError.unauthorized {
            guard current == operation else { return }
            phase = .signedOut
            errorMessage = "登录已失效，请重新登录。"
        } catch {
            guard current == operation else { return }
            phase = .restoring
            errorMessage = "暂时无法恢复登录，可重试；已保留安全凭据。"
        }
    }

    public func signIn(email: String, password: String) async {
        operation += 1
        let current = operation
        errorMessage = nil
        do {
            let user = try await api.signIn(email: email, password: password)
            guard current == operation else { return }
            phase = .signedIn(user)
        } catch {
            guard current == operation else { return }
            errorMessage = "登录失败，请检查邮箱和密码。"
        }
    }

    public func signOut() async {
        operation += 1
        let current = operation
        phase = .signedOut
        errorMessage = nil
        do {
            try await api.signOut()
        } catch {
            guard current == operation else { return }
            errorMessage = "本地已退出；远端撤销或安全存储清理未确认，请重试。"
        }
    }

    public func completeDesktopLogin(_ challenge: DesktopLoginChallenge) async throws {
        guard let client = api as? HTTPAPIClient else { throw APIError.invalidResponse }
        let current = operation
        let user = try await client.completeLogin(challenge)
        guard current == operation else { throw APIError.unauthorized }
        errorMessage = nil
        phase = .signedIn(user)
    }

    /// 账号页换头像后同步侧栏。
    public func updateAvatar(_ path: String?) {
        guard case .signedIn(let user) = phase else { return }
        phase = .signedIn(User(id: user.id, email: user.email, nickname: user.nickname, isAdmin: user.isAdmin, avatarURL: path))
    }

    /// 浏览器登录：打开授权页后等待 URL Scheme 回调；`browserLoginPending` 用于界面显示等待状态。
    public private(set) var browserLoginPending = false

    public func beginBrowserLogin(clientVersion: String) async throws -> URL {
        guard let client = api as? HTTPAPIClient else { throw APIError.invalidResponse }
        operation += 1
        errorMessage = nil
        let challenge = try await client.beginBrowserLogin(clientVersion: clientVersion)
        phase = .signedOut
        browserLoginPending = true
        return challenge.authorizeURL
    }

    public func completeBrowserLogin(callback: URL) async {
        // 没有进行中的浏览器登录时忽略回调（例如重复点击了旧页面的“打开 DrawOffer”）。
        guard browserLoginPending, let client = api as? HTTPAPIClient else { return }
        let current = operation
        do {
            let user = try await client.completeBrowserLogin(callback: callback)
            guard current == operation else { return }
            errorMessage = nil
            browserLoginPending = false
            phase = .signedIn(user)
        } catch {
            guard current == operation else { return }
            browserLoginPending = false
            errorMessage = switch error {
            case APIError.server(status: 410, code: _): "授权已过期，请重新登录。"
            case APIError.server(status: 400, code: "LOGIN_CALLBACK_INVALID"), APIError.unauthorized: "登录回调与本次请求不匹配，请从客户端重新点击登录。"
            default: "登录未完成，请检查网络后重新登录。"
            }
        }
    }

    public func reportAuthenticationFailure() {
        operation += 1
        phase = .signedOut
        errorMessage = "登录已失效，请重新登录。"
    }
}
