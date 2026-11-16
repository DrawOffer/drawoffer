import AppKit
import DrawOfferCore
import SwiftUI

struct WorkspaceView: View {
    @Environment(SessionStore.self) private var session
    @State private var selection: WorkspaceSection? = .home
    private struct LoginRequest: Identifiable {
        let id = UUID()
        let template: ResumeTemplate?
        let reasonOverride: String?
        init(template: ResumeTemplate?, reasonOverride: String? = nil) {
            self.template = template; self.reasonOverride = reasonOverride
        }
        var reason: String { reasonOverride ?? template.map { "登录后继续使用「\($0.name)」。" } ?? "登录后查看和同步你的简历。" }
    }
    @State private var loginRequest: LoginRequest?
    @State private var pendingCreateKey: String?
    private struct ChatTarget: Equatable { let token = UUID(); let sessionID: String?; let initial: String?; var model: String? = nil; var draft: String? = nil }
    @State private var chat: ChatTarget?
    @State private var agentSessions = AgentSessionsModel()
    @State private var focusResumeID: String?
    @State private var editResumeID: String?
    @State private var featureNotice = false
    @State private var homeDraft = ""
    @State private var pluginNotice = false
    @State private var router = WorkspaceRouter()
    @State private var announcements = AnnouncementCenter()
    @State private var plansPresented = false
    @State private var careerProfile = false
    /// 首页星图“去练”带过去的练习焦点（模拟面试首页读取后清空）。
    @State private var mockFocus: PracticeFocus?
    @State private var mockFullScreen = false
    /// 首页点开某一场模拟面试（面试纸 / 报告纸 / “看这一场的报告”）
    @State private var mockSession: String?
    /// 首页“选择文件”导入简历：我的简历页收到后打开导入。
    @State private var importRequest: UUID?
    @State private var openApplication: String?
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
                             openPlans: { plansPresented = true },
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
                // 模拟面试场次画面不显示侧栏：顶部让出红绿灯一行；其余内容直接铺满窗口，不再套圆角描边卡片。
                .padding(.top, bare && !edge ? 40 : 0)
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
        // 登录按 macOS 稿 01 页「02 · 登录页」做成整窗页面（盖住侧栏），右上角「暂不登录」回到游客模式
        .overlay {
            if loginRequest != nil {
                SignInView(fullPage: true, dismiss: { loginRequest = nil }).transition(.opacity)
            }
        }
        .centeredSheet(isPresented: Binding(get: { announcements.detail != nil }, set: { if !$0 { announcements.detail = nil } })) {
            AnnouncementDetailSheet().environment(announcements)
        }
        .centeredSheet(isPresented: $plansPresented) { PlansSheet() }
        // 所有弹窗与确认框画在整个窗口正中（设计稿 11-16）；浮层也要拿到 router 与公告，所以宿主放在这两个 environment 里面
        .modalHost()
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
            case .plans: plansPresented = true
            case .application(let id): openApplication = id; selection = .jobs
            case .mock(let focus): mockFocus = focus; selection = .mock
            case .mockSession(let id): mockSession = id; selection = .mock
            case nil: break
            }
        }
        .task(id: user?.id ?? "") { await agentSessions.load(api: session.api, account: user?.id ?? "") }
        .onChange(of: session.phase) { previous, current in
            if case .signedIn(let nextUser) = current {
                if case .signedIn(let oldUser) = previous, oldUser.id != nextUser.id {
                    pendingCreateKey = nil
                    focusResumeID = nil
                    editResumeID = nil
                    chat = nil
                    loginRequest = nil
                    homeDraft = ""
                    selection = .home
                }
                let template = loginRequest?.template
                loginRequest = nil
                // 登录前选中的示例模板：回到模板页，按 key 匹配真实模板后打开创建弹窗
                if let template { pendingCreateKey = template.key; selection = .templates }
            } else if case .signedIn = previous {
                pendingCreateKey = nil
                focusResumeID = nil
                editResumeID = nil
                chat = nil
                loginRequest = nil
                homeDraft = ""
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
                               navigate: { selection = $0 })
            } else {
                GuestHomeView(requireAccount: { requestLogin(reason: "登录 DrawOffer，开始你的第一份简历。") })
            }
        case .datasets: DatasetLibraryView(requireAccount: { requestLogin(reason: "登录后管理你的资料库。") })
                case .mock: MockInterviewView(requireAccount: { requestLogin(reason: "登录后开始模拟面试。") }, showSchedule: { selection = .schedule }, navigate: { selection = $0 }, incomingFocus: $mockFocus, incomingSession: $mockSession, fullScreen: $mockFullScreen)
        case .schedule: InterviewScheduleView(requireAccount: { requestLogin(reason: "登录后管理面试安排。") })
        case .jobs: JobsBoardView(requireAccount: { requestLogin(reason: "登录后管理岗位和求职进度。") }, openApplication: $openApplication)
        case .templates:
            TemplatesView(pendingCreateKey: $pendingCreateKey,
                          requireLogin: { loginRequest = LoginRequest(template: $0) },
                          onCreated: { id in editResumeID = id.isEmpty ? nil : id; selection = .resumes })
        case .resumes:
            ResumesView(focusResumeID: $focusResumeID, editResumeID: $editResumeID, browse: { selection = .templates }, login: { requestLogin() }, importRequest: importRequest)
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
            } else { PlaceholderView(section: .assistant) }
        case .opportunities:
            if user != nil { JobPoolView(openApplication: { openApplication = $0; selection = .jobs }) }
            else { PlaceholderView(section: .opportunities) }
        case .account:
            if user != nil { AccountSection(career: $careerProfile) } else { PlaceholderView(section: .account) }
        case let section?: PlaceholderView(section: section)
        }
    }

    private func startChat(_ text: String, _ model: String?) {
        chat = ChatTarget(sessionID: nil, initial: text, model: model)
        homeDraft = ""
        selection = .assistant
    }

    private func requestLogin(reason: String? = nil) {
        if user != nil { featureNotice = true; return }
        loginRequest = LoginRequest(template: nil, reasonOverride: reason)
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

struct EmptyResumeArt: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for x in stride(from: 0, through: 504, by: 12) {
                    for y in stride(from: 0, through: 236, by: 12) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.gray.opacity(0.15)))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0x17191C)).frame(width: 48, height: 7)
                Rectangle().fill(Color(hex: 0xDCDCD8)).frame(width: 72, height: 3)
                ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 4).stroke(Color(hex: 0xE9E9E5), style: StrokeStyle(lineWidth: 1, dash: [3])).frame(height: 28) }
            }.padding(16).frame(width: 132, height: 176).background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: 0xE4E4E0)))
                .shadow(color: .black.opacity(0.04), radius: 8, y: 4).offset(x: 186, y: 30)
            chip("教育经历", x: 90, y: 68, angle: -4)
            chip("项目经历", x: 336, y: 110, angle: 3)
            chip("专业技能", x: 104, y: 158, angle: 2)
        }.accessibilityHidden(true)
    }
    private func chip(_ title: String, x: CGFloat, y: CGFloat, angle: Double) -> some View {
        Label(title, systemImage: "square.grid.2x2").font(.system(size: 11)).padding(10).background(.white)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: 0xE4E4E0)))
            .rotationEffect(.degrees(angle)).offset(x: x, y: y)
    }
}

struct PlaceholderView: View {
    let section: WorkspaceSection
    var body: some View {
        ContentUnavailableView(section.title, systemImage: section.symbol,
            description: Text("原生版本待实现"))
            .navigationTitle(section.title)
    }
}
