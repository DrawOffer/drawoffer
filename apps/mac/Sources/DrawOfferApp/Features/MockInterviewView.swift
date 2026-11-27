import Foundation
import DrawOfferCore
import SwiftUI

/// 模拟面试模块入口（Figma 5:23 · 模拟面试）：首页（开始前确认弹窗）→ 面试中（全屏）→ 复盘；全部记录、导入面试记录从首页进。
struct MockInterviewView: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let showSchedule: () -> Void
    var navigate: (WorkspaceSection) -> Void = { _ in }
    /// 首页星图“去练”、资料库“练这段经历”带来的考点或经历：打开开始前确认并随创建提交 `practice_focus`（与 Web `?focus=` 一致）。
    var incomingFocus: Binding<PracticeFocus?> = .constant(nil)
    /// 首页点开的某一场：直接进这一场（进行中接着答，完成的看复盘）。
    var incomingSession: Binding<String?> = .constant(nil)
    /// 对话里模拟面试预览的「练没答好的 N 处」：带着练习计划打开开始前确认（Web `startPractice`）。
    var incomingPlan: Binding<MockPracticePlan?> = .constant(nil)
    /// 求职进程或对话预览里的「模拟这场面试」：带着投递打开开始前确认并选好这一场（Web `newMockInterviewPath({ applicationId })`）。
    var incomingApplication: Binding<String?> = .constant(nil)
    /// 面试中隐藏侧栏（Web `SessionFrame` 用 `V3Shell bare`）。
    var fullScreen: Binding<Bool> = .constant(false)

    private enum Screen: Equatable { case home, records, session, report }
    @State private var screen = Screen.home
    @State private var selectedID = ""
    /// 别处带来的「直接开始」：落到首页并打开开始前确认弹窗（原来的设置页已删，Web `/mock-interviews/new` 同样落到首页）
    @State private var startRequest: MockStartRequest?

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
            // 游客进不来这一页；退出登录的一瞬间账号已清空，先留白等外壳切回首页
            if account.isEmpty {
                Color.white
            } else {
                switch screen {
                case .home:
                    MockHomeV2(request: $startRequest, open: open, openReview: openReview,
                               showRecords: { screen = .records }, showSchedule: showSchedule)
                case .records:
                    MockRecordsV2(back: { goHome() }, openReport: open, open: open,
                                  openReal: openReal, startFirst: { start(MockStartRequest(plan: .full(count: MockHome.firstCount, title: "第一场"))) })
                case .session:
                    // 面试中（准备、作答、结束）是无侧栏的全屏画面；完成的场次交给复盘
                    MockSessionV2(id: selectedID, home: { goHome() }, report: { _ in screen = .report }, open: open).id(selectedID)
                case .report:
                    // 面试复盘（Figma 09 · 10）：带侧栏
                    MockReportV2(id: selectedID, home: { goHome() }, records: { screen = .records },
                                 practice: { focus in start(MockStartRequest(focus: focus)) }, open: open,
                                 practicePlan: { plan in start(MockStartRequest(practice: plan)) },
                                 restart: { application in start(MockStartRequest(applicationID: application, plan: .full(count: nil, title: nil))) }).id(selectedID)
                }
            }
        }
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.environment["DRAWOFFER_MOCK_FIXTURE"] != nil { open("fixture") } }
        #endif
        // 岗位广场「对着这个岗位练一场」：带着刚加入的岗位打开开始前确认
        .onAppear { if !account.isEmpty, let joined = CoachGuide.shared.takePendingMockApplication() { start(MockStartRequest(applicationID: joined, plan: .full(count: nil, title: nil))) } }
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
            start(MockStartRequest(focus: focus))
        }
        .onChange(of: incomingPlan.wrappedValue, initial: true) { _, plan in
            guard let plan else { return }
            incomingPlan.wrappedValue = nil
            start(MockStartRequest(practice: plan))
        }
        .onChange(of: incomingApplication.wrappedValue, initial: true) { _, application in
            guard let application else { return }
            incomingApplication.wrappedValue = nil
            start(MockStartRequest(applicationID: application, plan: .full(count: nil, title: nil)))
        }
    }

    private func open(_ id: String) {
        guard !id.isEmpty else { return }
        selectedID = id; startRequest = nil; screen = .session
    }

    private func start(_ request: MockStartRequest) { startRequest = request; screen = .home }

    /// 首页「上一场 · 看复盘」：模拟面试进复盘，真实面试进这条投递。
    private func openReview(_ record: JSONValue) {
        if record.text("kind") == "mock" { open(record.display("id")) } else { openReal(record.display("id"), record.display("application_id").nonEmptyValue) }
    }

    private func openReal(_ id: String, _ application: String?) {
        if let application, let router { router.jump(.application(application)) } else { navigate(.jobs) }
    }

    private func goHome() { startRequest = nil; screen = .home }
}
