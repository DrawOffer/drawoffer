import AppKit
import Foundation
import DrawOfferCore
import SwiftUI

/// 单窗口应用：关掉主窗口即退出（与系统设置等单窗口应用一致），不留下没有窗口、无法再打开的进程。
final class DrawOfferAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DrawOfferApp: App {
    @NSApplicationDelegateAdaptor(DrawOfferAppDelegate.self) private var delegate
    @State private var session: SessionStore?
    @State private var configurationError: String?
    @State private var started = false
    private let lease: DesktopInstanceLease?

    init() {
        var instanceLease: DesktopInstanceLease?
        do {
            // 进程环境优先；经 URL Scheme 由系统拉起时没有自定义环境，回退到上次成功使用的地址。
            let environment = ProcessInfo.processInfo.environment
            let defaults = UserDefaults.standard
            // 都没有时默认连线上 www.drawoffer.com；开发环境用 DRAWOFFER_API_ORIGIN 覆盖。
            let value = environment["DRAWOFFER_API_ORIGIN"] ?? defaults.string(forKey: "DrawOfferAPIOrigin") ?? "https://www.drawoffer.com"
            guard let origin = URL(string: value) else { throw APIError.invalidResponse }
            let allowLocalHTTP = environment["DRAWOFFER_ALLOW_LOCAL_HTTP"].map { $0 == "1" }
                ?? defaults.bool(forKey: "DrawOfferAllowLocalHTTP")
            let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("DrawOffer")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            instanceLease = try DesktopInstanceLease(fileURL: directory.appendingPathComponent("desktop-session.lock"))
            // 本地对照模式（设置了 DRAWOFFER_SNAPSHOT_DIR）不碰系统钥匙串，避免每次重新构建都弹授权框。
            // 本地调试构建（debug）每次签名都不同，用钥匙串会反复弹授权框，所以一律存到本机文件；
            // 即使经 drawoffer:// 回调由系统直接拉起、没有任何环境变量，也不会访问钥匙串。正式 release 构建才用钥匙串。
            #if DEBUG
            let base = environment["DRAWOFFER_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
                ?? directory.appendingPathComponent("debug")
            let tokens: any TokenStore = LocalFileTokenStore(directory: base.appendingPathComponent("credentials"))
            #else
            let tokens: any TokenStore = KeychainTokenStore()
            #endif
            let api = try HTTPAPIClient(baseURL: origin, tokens: tokens, allowLocalHTTP: allowLocalHTTP)
            defaults.set(value, forKey: "DrawOfferAPIOrigin")
            defaults.set(allowLocalHTTP, forKey: "DrawOfferAllowLocalHTTP")
            _session = State(initialValue: SessionStore(api: api))
        } catch APIError.server(status: 409, code: "DESKTOP_ALREADY_RUNNING") {
            _configurationError = State(initialValue: "DrawOffer 已在运行，请使用已打开的窗口。")
        } catch {
            _configurationError = State(initialValue: "API 地址未配置或无效。请设置 DRAWOFFER_API_ORIGIN 后重新启动。")
        }
        lease = instanceLease
    }

    var body: some Scene {
        Window("DrawOffer", id: "main") {
            Group {
                if let session {
                    // Dates and clocks, DatePicker included, read in Beijing time whatever the Mac's zone is.
                    RootView().environment(session).environment(\.timeZone, Beijing.timeZone).environment(\.calendar, Beijing.calendar)
                        .onOpenURL { url in
                            guard url.scheme == "drawoffer", url.host == "auth" else { return }
                            NSApplication.shared.activate(ignoringOtherApps: true)
                            Task { await session.completeBrowserLogin(callback: url) }
                        }
                        .task {
                            guard !started else { return }
                            started = true
                            await session.restore()
                        }
                } else {
                    ContentUnavailableView("无法连接服务", systemImage: "network.slash",
                        description: Text(configurationError ?? "配置无效"))
                }
            }.frame(minWidth: 1080, minHeight: 700)
                .onAppear {
                    DebugSnapshot.startIfConfigured()
                    if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
                       let icon = NSImage(contentsOf: url) {
                        NSApplication.shared.applicationIconImage = icon
                    }
                }
        }
        // 单层窗口：隐藏标题栏，红绿灯浮在侧栏 / 编辑器工具栏左上，内容铺到窗口顶边。
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("账号") {
                Button("退出登录") { Task { await session?.signOut() } }
                    .disabled(session == nil)
            }
        }
        Settings {
            Text("设置（待实现）").padding(Tokens.Space.s6)
        }
    }
}

struct RootView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        WorkspaceView()
    }
}
