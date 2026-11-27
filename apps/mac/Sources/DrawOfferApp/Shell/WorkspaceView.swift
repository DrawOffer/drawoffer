import AppKit
import DrawOfferCore
import SwiftUI

struct WorkspaceView: View {
    @Environment(SessionStore.self) private var session
    @State private var selection: WorkspaceSection? = .home
    /// 整窗登录页是否打开。
    @State private var loginShown = false
    private struct ChatTarget: Equatable { let token = UUID(); let sessionID: String?; let initial: String?; var model: String? = nil; var draft: String? = nil }
    @State private var chat: ChatTarget?
    @State private var agentSessions = AgentSessionsModel()
    @State private var focusResumeID: String?
    @State private var editResumeID: String?
    @State private var featureNotice = false
    @State private var pluginNotice = false
    @State private var router = WorkspaceRouter()
    @State private var network = NetworkStatus()
    @State private var networkNotice: NoticeToastItem?
    @State private var announcements = AnnouncementCenter()
    @State private var plansPresented = false
    @State private var careerProfile = false
    /// 额度弹窗打开时停在哪个标签（"credits" 为积分页）。
    @State private var plansTab: String?
    /// 整窗反馈页（10.03–10.05）是否打开。
    @State private var feedbackShown = false
    /// 首页星图“去练”带过去的练习焦点（模拟面试首页读取后清空）。
    @State private var mockFocus: PracticeFocus?
    @State private var mockFullScreen = false
    /// 首页点开某一场模拟面试（面试纸 / 报告纸 / “看这一场的报告”）
    @State private var mockSession: String?
    @State private var mockPlan: MockPracticePlan?
    @State private var mockApplication: String?
    @State private var openJob: WorkspaceRouter.JobTarget?
    /// 首页“选择文件”导入简历：我的简历页收到后打开导入。
    @State private var importRequest: UUID?
    @State private var openApplication: String?
    @State private var openDataset: String?
    /// 第 17 页：侧栏可以收起（⌃⌘S 或左上角开关），收起后开关浮在内容区同一位置。
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    private var user: User? {
        if case .signedIn(let user) = session.phase { return user }
        return nil
    }

    /// Web 编辑器用 `V3Shell bare` + `.wb3-content { inset: 0; border: 0; radius: 0 }`：不显示侧栏，编辑器铺满窗口。
    private var bare: Bool { (selection == .resumes && editResumeID != nil || selection == .mock && mockFullScreen) && (user != nil || fixture) }
    #if DEBUG
    private var fixture: Bool { ProcessInfo.processInfo.environment["DRAWOFFER_MOCK_FIXTURE"] != nil }
    #else
    private let fixture = false
    #endif
    /// 编辑器铺满窗口（工具栏与红绿灯同一行）；模拟面试的场次画面只是不显示侧栏。
    private var edge: Bool { bare && selection == .resumes }

    var body: some View {
        HStack(spacing: 0) {
            if !bare && sidebarVisible {
            WorkspaceSidebar(selection: $selection, activeChatID: selection == .assistant ? chat?.sessionID : nil, sessions: agentSessions,
                             openChat: { id in chat = ChatTarget(sessionID: id, initial: nil); selection = .assistant },
                             newChat: { chat = ChatTarget(sessionID: nil, initial: nil); selection = .assistant },
                             requestLogin: { requestLogin() },
                             openPlans: { plansTab = nil; plansPresented = true },
                             openCareerProfile: { careerProfile = true; selection = .account },
                             chatDeleted: { id in if chat?.sessionID == id { chat = nil; selection = .home } },
                             toggleSidebar: { withAnimation(.easeOut(duration: 0.18)) { sidebarVisible = false } })
                    .transition(.move(edge: .leading))
                // 单层窗口（NavigationSplitView 观感）：侧栏贴满左侧到顶，和内容之间只留 1px 分隔线。
                Rectangle().fill(.black.opacity(0.08)).frame(width: 1).accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                if let message = session.errorMessage {
                    HStack {
                        Text(message).font(.callout)
                        if case .restoring = session.phase {
                            Button("重试恢复") { Task { await session.restore() } }
                        }
                    }.padding(12).frame(maxWidth: .infinity).background(.yellow.opacity(0.1))
                }
                mainContent
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white)
                // 模拟面试场次画面不显示侧栏、直接铺满窗口：顶行和红绿灯同一行（Figma 09 · 05），左边从 x 80 起让开红绿灯。
                .overlay(alignment: .topLeading) {
                    if !bare && !sidebarVisible {
                        SidebarToggleButton { withAnimation(.easeOut(duration: 0.18)) { sidebarVisible = true } }
                            .padding(.leading, 88).padding(.top, 2)
                    }
                }
        }.background(.white).ignoresSafeArea(.container, edges: .top)
        .centeredAlert("安装浏览器插件", isPresented: $pluginNotice) {
            Button("在浏览器打开") { WebBridge.open("/career/applications", api: session.api) }
            Button("知道了", role: .cancel) {}
        } message: { Text("浏览器插件在 Chrome / Edge 中使用，安装包与安装说明在 Web 的岗位看板页面提供。") }
        .centeredAlert("此功能尚未开放", isPresented: $featureNotice) {
            Button("知道了", role: .cancel) {}
        } message: { Text("此功能将在后续版本开放。你已输入的内容会保留，可以继续浏览模板。") }
        // 反馈得积分（10.03–10.05）：整窗页面盖住侧栏，右上角「← 返回」回到原处；未登录时「登录后提交」叠出登录页
        .overlay {
            if feedbackShown {
                FeedbackPage(back: { feedbackShown = false }, login: { loginShown = true }).transition(.opacity)
            }
        }
        // 登录按 macOS 稿 01 页「02 · 登录页」做成整窗页面（盖住侧栏），右上角「暂不登录」回到游客模式
        .overlay {
            if loginShown {
                SignInView(fullPage: true, dismiss: { loginShown = false }).transition(.opacity)
            }
        }
        .centeredSheet(isPresented: Binding(get: { announcements.detail != nil }, set: { if !$0 { announcements.detail = nil } })) {
            AnnouncementDetailSheet().environment(announcements)
        }
        .centeredSheet(isPresented: $plansPresented) { PlansSheet(initialTab: plansTab) }
        // 断网时窗口顶部 20pt 常驻一枚警告胶囊（第 16 页 E 组 / Web `PageUpdateNotice`），网络恢复自动消失。
        // 恢复后换成一闪而过的「网络已恢复」（E2 → A1）。
        .overlay(alignment: .top) {
            VStack(spacing: 12) {
                if network.offline { StatusPill(tone: .warn, title: "网络断开了").transition(.opacity) }
                NoticeToast(item: $networkNotice)
            }.padding(.top, 20)
        }
        .animation(.easeOut(duration: 0.18), value: network.offline)
        .onChange(of: network.offline) { wasOffline, offline in
            networkNotice = wasOffline && !offline ? .done("网络已恢复") : nil
        }
        // 所有弹窗与确认框画在整个窗口正中（设计稿 11-16）；浮层也要拿到 router 与公告，所以宿主放在这两个 environment 里面
        .modalHost()
        // 新手引导的压暗蒙层盖住整个窗口（含侧栏）；各页自己的 host 见到外层宿主后只登记目标、不重复绘制
        .environment(\.coachMarkExternalHost, true).coachMarkHost()
        .environment(router)
        .environment(announcements)
        .onAppear { if fixture { selection = .mock } }
        .task(id: user?.id ?? "") {
            announcements.reset(account: user?.id ?? "")
            await announcements.refresh(api: session.api)
            announcements.autoOpenImportant(api: session.api)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await announcements.refresh(api: session.api); announcements.autoOpenImportant(api: session.api) }
        }
        // 实时事件：后台任务状态变了就唤醒对应页面，新站内消息直接刷新消息中心；换账号或退出时断开重连
        .task(id: user?.id ?? "") {
            guard user != nil else { return }
            await EventHub.shared.run(api: session.api) { Task { await announcements.refresh(api: session.api, force: true) } }
        }
        .onChange(of: selection) { old, new in
            // 未登录只开放首页：点其他栏目留在原处，直接弹出整窗登录页
            if user == nil, let new, new != .home {
                selection = old == nil || old == new ? .home : old
                requestLogin()
                return
            }
            if new != .account { careerProfile = false }
        }
        .onChange(of: user == nil) { _, guest in if guest { selection = .home } }
        .onChange(of: router.pending) {
            switch router.take() {
            case .section(let section): selection = section
            case .draft(let text): chat = ChatTarget(sessionID: nil, initial: nil, draft: String(text.prefix(4000))); selection = .assistant
            case .editResume(let id): editResumeID = id; selection = .resumes
            case .plans: plansTab = nil; plansPresented = true
            case .credits: plansTab = "credits"; plansPresented = true
            case .feedback: feedbackShown = true
            case .application(let id): openApplication = id; selection = .jobs
            case .mock(let focus): mockFocus = focus; selection = .mock
            case .mockSession(let id): mockSession = id; selection = .mock
            case .mockPractice(let plan): mockPlan = plan; selection = .mock
            case .mockFor(let application): mockApplication = application; selection = .mock
            case .job(let target): openJob = target; selection = .jobs
            case .dataset(let id): openDataset = id; selection = .datasets
            case .careerProfile: careerProfile = true; selection = .account
            case nil: break
            }
        }
        .task(id: user?.id ?? "") { await agentSessions.load(api: session.api, account: user?.id ?? "") }
        .onChange(of: session.phase) { previous, current in
            if case .signedIn(let nextUser) = current {
                if case .signedIn(let oldUser) = previous, oldUser.id != nextUser.id {
                    focusResumeID = nil
                    editResumeID = nil
                    chat = nil
                    selection = .home
                }
                loginShown = false
            } else if case .signedIn = previous {
                focusResumeID = nil
                editResumeID = nil
                chat = nil
                loginShown = false
                selection = .home
            }
        }
    }

    @ViewBuilder private var mainContent: some View {
        switch selection {
        case .home, nil:
            if user != nil {
                // macOS 设计稿 02A：新用户 / 练第一场 / 有记忆三种首页，按长期记忆和模拟面试场次自动选
                HomeMemoryView(editResume: { editResumeID = $0; selection = .resumes },
                               practice: { focus in mockFocus = focus; selection = .mock },
                               openMock: { id, _ in mockSession = id; selection = .mock },
                               navigate: { selection = $0 },
                               // 知识图谱「聊一聊」侧栏：↗ 在对话页接着聊同一条；新建对话后刷新侧栏「最近对话」
                               openChat: { id in chat = ChatTarget(sessionID: id, initial: nil); selection = .assistant },
                               chatsChanged: { Task { await agentSessions.load(api: session.api, account: user?.id ?? "") } })
            } else {
                GuestHomeView(requireAccount: { requestLogin() })
            }
        case .datasets: DatasetLibraryView(openDataset: $openDataset)
                case .mock: MockInterviewView(showSchedule: { selection = .schedule }, navigate: { selection = $0 }, incomingFocus: $mockFocus, incomingSession: $mockSession, incomingPlan: $mockPlan, incomingApplication: $mockApplication, fullScreen: $mockFullScreen)
        case .schedule: InterviewScheduleView()
        case .jobs: JobsBoardView(openApplication: $openApplication, openJob: $openJob)
        case .templates:
            TemplatesView(onCreated: { id in editResumeID = id.isEmpty ? nil : id; selection = .resumes })
        case .resumes:
            ResumesView(focusResumeID: $focusResumeID, editResumeID: $editResumeID, importRequest: importRequest)
        case .assistant:
            if user != nil, let chat {
                AssistantChatView(sessionID: chat.sessionID, initialMessage: chat.initial,
                                  created: { _ in Task { await agentSessions.load(api: session.api, account: user?.id ?? "") } },
                                  deleted: { self.chat = nil; selection = .home; Task { await agentSessions.load(api: session.api, account: user?.id ?? "") } },
                                  sessionsChanged: { Task { await agentSessions.load(api: session.api, account: user?.id ?? "") } },
                                  initialModelID: chat.model, initialDraft: chat.draft,
                                  runningChanged: { id, running in
                                      if running { agentSessions.runningIDs.insert(id) } else { agentSessions.runningIDs.remove(id) }
                                  })
                    .id(chat.token)
            } else { Color.white }
        case .opportunities:
            if user != nil { JobPoolView(openApplication: { openApplication = $0; selection = .jobs }, openCareerProfile: { careerProfile = true; selection = .account }) }
        case .account:
            if user != nil { AccountSection(career: $careerProfile) }
        }
    }

    private func requestLogin() {
        if user != nil { featureNotice = true; return }
        loginShown = true
    }

}

struct WebActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white).opacity(enabled ? 1 : 0.5).padding(.horizontal, 14).frame(height: 32)
            .background(Color(hex: 0x17191C).opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}
