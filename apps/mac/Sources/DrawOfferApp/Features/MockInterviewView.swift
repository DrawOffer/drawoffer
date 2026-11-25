import Foundation
import DrawOfferCore
import SwiftUI

/// 模拟面试模块入口（Figma 09 · 模拟面试）：首页 → 面试设置 → 面试中（全屏）→ 复盘；全部记录、导入面试记录从首页进。
struct MockInterviewView: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let requireAccount: () -> Void
    let showSchedule: () -> Void
    var navigate: (WorkspaceSection) -> Void = { _ in }
    /// 首页星图“去练”带来的练习焦点：直接打开面试设置并随创建提交 `practice_focus`（与 Web `?focus=` 一致）。
    var incomingFocus: Binding<PracticeFocus?> = .constant(nil)
    /// 首页点开的某一场：直接进这一场（进行中接着答，完成的看复盘）。
    var incomingSession: Binding<String?> = .constant(nil)
    /// 对话里模拟面试预览的「练没答好的 N 处」：带着练习计划直接进面试设置（Web `startPractice`）。
    var incomingPlan: Binding<MockPracticePlan?> = .constant(nil)
    /// 求职进程或对话预览里的「模拟这场面试」：带着投递直接进面试设置并选好这个岗位（Web `newMockInterviewPath({ applicationId })`）。
    var incomingApplication: Binding<String?> = .constant(nil)
    /// 面试中隐藏侧栏（Web `SessionFrame` 用 `V3Shell bare`）。
    var fullScreen: Binding<Bool> = .constant(false)

    private enum Screen: Equatable { case home, config, records, session, report }
    @State private var screen = Screen.home
    @State private var selectedID = ""
    @State private var practiceFocus: PracticeFocus?
    @State private var configApplication: String?
    @State private var practicePlan: MockPracticePlan?
    @State private var configKey = UUID()

    private var account: String {
        if case .signedIn(let user) = session.phase { return user.id }
        #if DEBUG
        // 本地对照的只读替身：后端连不上时也按已登录排版这一场（不发请求）。
        if ProcessInfo.processInfo.environment["DRAWOFFER_MOCK_FIXTURE"] != nil { return "fixture" }
        #endif
        return ""
    }

    var body: some View {
        Group {
            if account.isEmpty {
                signedOut
            } else {
                switch screen {
                case .home:
                    MockHomeV2(
                        focus: nil,
                        open: open, openReport: open,
                        showRecords: { screen = .records },
                        showSchedule: showSchedule,
                        showResumes: { navigate(.resumes) },
                        showLibrary: { navigate(.datasets) },
                        showOpportunities: { navigate(.opportunities) },
                        showConfig: { config() })
                case .config:
                    // 面试设置（Figma 09 · 02）
                    MockConfigPage(applicationID: configApplication, focus: practiceFocus, practice: practicePlan, back: { goHome() }, open: open,
                                   showBoard: { navigate(.jobs) }, showOpportunities: { navigate(.opportunities) })
                        .id(configKey)
                case .records:
                    MockRecordsV2(back: { goHome() }, openReport: open, open: open,
                                  openReal: { _, application in if let application, let router { router.jump(.application(application)) } else { navigate(.jobs) } }, startFirst: { config() })
                case .session:
                    // 面试中（准备、作答、结束）是无侧栏的全屏画面；完成的场次交给复盘
                    MockSessionV2(id: selectedID, home: { goHome() }, report: { _ in screen = .report }, open: open).id(selectedID)
                case .report:
                    // 面试复盘（Figma 09 · 10）：带侧栏
                    MockReportV2(id: selectedID, home: { goHome() }, records: { screen = .records },
                                 practice: { focus in config(focus: focus) }, open: open,
                                 practicePlan: { plan in config(plan: plan) }).id(selectedID)
                }
            }
        }
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.environment["DRAWOFFER_MOCK_FIXTURE"] != nil { open("fixture") } }
        #endif
        // 岗位广场「对着这个岗位练一场」：直接落在面试设置页，设置页读走带来的岗位
        .onAppear { if CoachGuide.shared.pendingMockApplication != nil, !account.isEmpty { config() } }
        .onChange(of: screen == .session && !account.isEmpty, initial: true) { _, value in fullScreen.wrappedValue = value }
        .onDisappear { fullScreen.wrappedValue = false }
        .onChange(of: account) { _, _ in goHome() }
        .onChange(of: incomingSession.wrappedValue, initial: true) { _, id in
            guard let id else { return }
            incomingSession.wrappedValue = nil
            open(id)
        }
        .onChange(of: incomingFocus.wrappedValue, initial: true) { _, focus in
            guard let focus else { return }
            incomingFocus.wrappedValue = nil
            config(focus: focus)
        }
        .onChange(of: incomingPlan.wrappedValue, initial: true) { _, plan in
            guard let plan else { return }
            incomingPlan.wrappedValue = nil
            config(plan: plan)
        }
        .onChange(of: incomingApplication.wrappedValue, initial: true) { _, application in
            guard let application else { return }
            incomingApplication.wrappedValue = nil
            config(application: application)
        }
    }

    /// 没登录：一句说明 + 登录入口。
    private var signedOut: some View {
        VStack(spacing: 14) {
            Text("模拟面试").font(V3.serif(28)).foregroundStyle(MockPalette.ink)
            Text("登录后开始模拟面试，练过的每一场都会记进长期记忆。").font(V3.sans(14)).foregroundStyle(MockPalette.sub)
            Button("登录", action: requireAccount).buttonStyle(MockPillStyle()).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
    }

    private func open(_ id: String) {
        guard !id.isEmpty else { return }
        selectedID = id; practiceFocus = nil; practicePlan = nil; screen = .session
    }

    private func config(focus: PracticeFocus? = nil, plan: MockPracticePlan? = nil, application: String? = nil) {
        practiceFocus = focus; practicePlan = plan; configApplication = application; configKey = UUID(); screen = .config
    }

    private func goHome() { practiceFocus = nil; practicePlan = nil; screen = .home }
}
