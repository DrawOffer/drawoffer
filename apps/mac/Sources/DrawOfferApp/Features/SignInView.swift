import AppKit
import Foundation
import DrawOfferCore
import SwiftUI

/// 登录入口：不在客户端内填写账号，打开浏览器登录并授权，授权码经 `drawoffer://auth/callback` 回到客户端。
struct SignInView: View {
    @Environment(SessionStore.self) private var session
    @State private var message: String?
    @State private var opening = false

    var body: some View {
        VStack(spacing: Tokens.Space.s4) {
            Text("在浏览器中登录 DrawOffer").font(.custom("Songti SC", size: 20).weight(.semibold))
            Text(message ?? (session.browserLoginPending
                ? "已在浏览器打开登录页。登录后点击“授权并打开客户端”，会自动回到这里。"
                : "点击下方按钮，在浏览器完成登录后会自动回到客户端。"))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            if let error = session.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            if case .restoring = session.phase {
                Button("重试恢复登录") { Task { await session.restore() } }
            }
            Button(session.browserLoginPending ? "重新打开浏览器登录" : "在浏览器中登录") { open() }
                .buttonStyle(WebActionStyle()).disabled(opening)
        }
        .padding(Tokens.Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Color.background)
    }

    private func open() {
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

enum DesktopClient {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
