import Foundation
import DrawOfferCore
import SwiftUI

/// 复盘报告「练这几题 / 练这一处」带来的内容（Web `practicePlan.ts`）。
struct MockPracticeItem: Equatable {
    var label: String
    var question: String
    var signals: [String]
    var note: String?
    var tag: String?
    /// 上次到哪
    var last: String
    /// 这次要到
    var goal: String
    /// 重练的是哪场的哪一题（mock|real:场次:题号），复盘按它比“上次”的分
    var source: String? = nil
}

struct MockPracticePlan: Equatable {
    var back: String
    var items: [MockPracticeItem]
    var applicationID: String?
    var interviewType: String?
    var difficulty: String?
    var mode: String?
    var resumeID: String?
}

/// 从别处带进来直接开始（Web `StartRequest`）：哪个投递、哪份简历、哪种练法，以及复盘带来的原设置。
struct MockStartRequest: Equatable, Identifiable {
    let id = UUID()
    var applicationID: String?
    var resumeID: String?
    var plan: MockStart.Plan
    var interviewType: String?
    var difficulty: String?
    var mode: String?

    init(applicationID: String? = nil, resumeID: String? = nil, plan: MockStart.Plan, interviewType: String? = nil, difficulty: String? = nil, mode: String? = nil) {
        self.applicationID = applicationID; self.resumeID = resumeID; self.plan = plan
        self.interviewType = interviewType; self.difficulty = difficulty; self.mode = mode
    }

    init(practice: MockPracticePlan) {
        self.init(applicationID: practice.applicationID, resumeID: practice.resumeID,
                  plan: .practice(practice.items.map { MockStart.Item(label: $0.label, question: $0.question, signals: $0.signals, source: $0.source) }),
                  interviewType: practice.interviewType, difficulty: practice.difficulty, mode: practice.mode)
    }

    /// 首页星图、对话、资料库带来的一个考点或一段经历（Web `readFocus` + `startRequest`）。
    init(focus: PracticeFocus) {
        if focus.kind == "experience", focus.scope != nil || focus.hook != nil || focus.short {
            self.init(applicationID: focus.applicationID, resumeID: focus.resumeID, plan: .experience(MockStart.Experience(ref: focus.ref, label: focus.label, scope: focus.scope ?? "packaged",
                                                                                        hook: focus.hook, short: focus.short, origin: focus.origin)))
        } else {
            self.init(applicationID: focus.applicationID, resumeID: focus.resumeID, plan: .single(MockStart.Item(label: focus.label), ref: focus.ref.nonEmptyValue,
                                                             focusKind: focus.kind == "experience" ? "experience" : "topic", origin: focus.origin))
        }
    }
}

/// 开始前确认（Web `v2/StartDialog.tsx`，Figma 07.01–07.07）：确认场次、答题方式、难度和简历；面试类型、面试官、音色、语言和追问收在「更多设置」。
/// 积分不够时主按钮换成「去充值」。
struct MockStartDialog: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let request: MockStartRequest
    let target: MockHome.Target
    /// 场次「更换」能选的：日程里还没开始的面试
    let sessions: [JSONValue]
    let records: [JSONValue]
    let resumes: [JSONValue]
    let list: [JSONValue]
    let pickTarget: (MockHome.Target) -> Void
    let open: (String) -> Void
    let addInterview: () -> Void
    let close: () -> Void

    private static let types = ["technical", "project_deep_dive", "comprehensive", "hr"]

    @State private var speechOK: Bool?
    @State private var voices: [JSONValue] = []
    @State private var defaultVoices: [String: String] = [:]
    @State private var targetRole: String?
    @State private var prices: [JSONValue] = []
    @State private var balance: Double?
    @State private var mode = "voice"
    @State private var difficulty = "intermediate"
    @State private var type: String?
    @State private var voice = "male"
    @State private var voiceIDs: [String: String] = [:]
    @State private var language = "zh"
    @State private var followUp = true
    @State private var resume = ""
    @State private var more = false
    @State private var menu: String?
    @State private var submitting = false
    @State private var notice: MockNotice?
    @State private var scope = "packaged"
    /// 这段经历的延伸点（复习稿接口给的练习情况）；nil 是还没读到或读不出
    @State private var points: [JSONValue]?
    @State private var started = false

    private var experience: MockStart.Experience? { if case .experience(let value) = request.plan { return value }; return nil }
    private var packaged: Int { points?.count ?? 0 }
    private var pendingPoints: Int { points?.filter { $0.text("state") != "rounded" }.count ?? 0 }
    private var count: Int { MockStart.count(request.plan, packaged: packaged, pending: pendingPoints, scope: scope) }
    private var activeType: String { type ?? (target.session?.text("stage_type") == "hr" ? "hr" : "technical") }
    private var cost: MockStart.Cost? {
        let price = { (code: String) in prices.first { $0.text("featureCode") == code } }
        return MockStart.cost(text: price("mock_interview"), voice: mode == "voice" ? price("mock_interview_voice") : nil, count: count)
    }
    private var short: Bool { if let points = cost?.points, let balance { return balance < points }; return false }
    private var blocking: JSONValue? { list.first { ["in_progress", "preparing", "evaluating", "evaluation_failed"].contains($0.text("status")) } }
    private var sortedResumes: [JSONValue] { resumes.sorted { $0.text("updated_at") > $1.text("updated_at") } }
    private var selectedResume: JSONValue? { resumes.first { $0.display("id") == resume } }
    private var genderVoices: [JSONValue] { voices.filter { $0.text("gender") == voice } }
    private var voiceValue: String { voiceIDs[voice] ?? defaultVoices[voice] ?? genderVoices.first?.display("id") ?? "" }
    private var title: String { MockStart.title(request.plan, hasSession: target.session != nil) }
    private var subtitle: String { MockStart.subtitle(request.plan, count: count, packaged: packaged) }
    private var targetLabel: String { target.session.map { "\(MockHome.sessionTitle($0)) · \(MockHome.mmdd($0.text("start_at")))" } ?? "通用练习 · 不针对岗位" }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title).font(V3.serif(20)).foregroundStyle(MockPalette.ink).lineHeight(20, 29, .serif).lineLimit(2)
                Text(verbatim: subtitle).font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.mute).lineHeight(14, 21)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let experience {
                    row("范围") {
                        MockSeg(label: "范围", options: [("packaged", "只练延伸点", points != nil && packaged == 0), ("all", "整段完整练", false)],
                                current: packaged > 0 ? scope : "all", pill: true) { scope = $0 }
                    }
                    Text(verbatim: MockStart.scopeNote(experience, scope: packaged > 0 ? scope : "all", packaged: packaged, loaded: points != nil))
                        .font(V3.sans(13)).foregroundStyle(MockPalette.mute).lineHeight(13, 19).padding(.leading, 84).padding(.top, -6)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    row("场次") {
                        Text(verbatim: targetLabel).font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.ink).lineLimit(1).help(targetLabel)
                        Spacer(minLength: 12)
                        change("target", disabled: false)
                    }
                    .zIndex(menu == "target" ? 2 : 0)
                    .overlay(alignment: .topTrailing) {
                        if menu == "target" {
                            MockTargetMenu(sessions: sessions, records: records, current: target, pick: { pickTarget($0); menu = nil },
                                           add: { menu = nil; addInterview() })
                                .offset(x: 8, y: 42)
                        }
                    }
                }
                row("答题方式") {
                    MockSeg(label: "答题方式", options: [("voice", "语音", speechOK == false), ("text", "文字", false)], current: mode, pill: true) { mode = $0 }
                }
                row("难度") {
                    MockSeg(label: "难度", options: ["junior", "intermediate", "senior"].map { (value: $0, title: MockMap.diffName[$0] ?? $0, disabled: false) }, current: difficulty, pill: true) { difficulty = $0 }
                }
                row("简历") {
                    Text(verbatim: selectedResume?.text("title") ?? "还没有简历").font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.ink).lineLimit(1)
                    Spacer(minLength: 12)
                    change("resume", disabled: resumes.isEmpty)
                }
                .zIndex(menu == "resume" ? 2 : 0)
                .overlay(alignment: .topTrailing) {
                    if menu == "resume" { resumeMenu.offset(x: 8, y: 42) }
                }
                if more {
                    row("面试类型") {
                        MockSeg(label: "面试类型", options: Self.types.map { (value: $0, title: MockMap.typeNames[$0] ?? $0, disabled: false) }, current: activeType, pill: true) { type = $0 }
                    }
                    if mode == "voice" {
                        row("面试官") {
                            MockSeg(label: "面试官", options: [("male", "男声", false), ("female", "女声", false)], current: voice, pill: true) { voice = $0 }
                        }
                        if genderVoices.count > 1 {
                            row("音色") {
                                MockSeg(label: "音色", options: genderVoices.prefix(4).map { (value: $0.display("id"), title: $0.text("name"), disabled: false) }, current: voiceValue, pill: true) { voiceIDs[voice] = $0 }
                            }
                        }
                    }
                    row("面试语言") {
                        MockSeg(label: "面试语言", options: [("zh", "中文", false), ("en", "英文", false)], current: language, pill: true) { language = $0 }
                    }
                    row("追问") {
                        MockSeg(label: "追问", options: [("on", "最多 \(MockStart.followUps[difficulty] ?? 2) 次", false), ("off", "不追问", false)],
                                current: followUp ? "on" : "off", pill: true) { followUp = $0 == "on" }
                    }
                }
                Button(more ? "收起更多设置" : "更多设置") { more.toggle() }.buttonStyle(MockLinkStyle(blue: true, size: 14)).padding(.top, 4)
            }
            .padding(.top, -4)
            .zIndex(1)
            HStack(spacing: 12) {
                footNote.frame(maxWidth: .infinity, alignment: .leading)
                Button("取消", action: close).buttonStyle(MockDialogButton(dark: false))
                Button(short ? "去充值" : submitting ? "正在准备…" : blocking != nil ? "继续上一场" : experience != nil ? "开始练习" : "开始面试") { start() }
                    .buttonStyle(MockDialogButton(dark: true)).disabled(submitting).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 24)
        .frame(width: 462, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.white).shadow(color: .black.opacity(0.08), radius: 14, y: 8)
                // 点弹层外面收起
                if menu != nil { Color.white.opacity(0.001).onTapGesture { menu = nil } }
            }
        }
        .background { Button("", action: { if menu != nil { menu = nil } else { close() } }).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
        .overlay(alignment: .bottom) { MockNoticeToast(notice: $notice).offset(y: 80) }
        .task { await load() }
        .task(id: "\(experience?.ref ?? ""):\(resume)") { await loadPoints() }
        .onChange(of: target) { _, _ in applyResume() }
    }

    private var footNote: some View {
        HStack(spacing: 0) {
            if let cost { Text(verbatim: cost.label).font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.ink) }
            if let balance, cost?.points != nil {
                Text(verbatim: "\(cost != nil ? " · " : "")余额 \(MockStart.number(balance))").font(V3.sans(14)).foregroundStyle(short ? MockPalette.orange : MockPalette.mute)
            }
        }.lineLimit(1)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: label).font(V3.sans(14)).foregroundStyle(MockPalette.mute).frame(width: 84, alignment: .leading)
            content()
        }.frame(minHeight: 36)
    }

    private func change(_ name: String, disabled: Bool) -> some View {
        Button("更换") { menu = menu == name ? nil : name }.buttonStyle(MockLinkStyle(blue: true, size: 14)).disabled(disabled)
    }

    private var resumeMenu: some View {
        MockPopMenu(width: 360) {
            ForEach(sortedResumes, id: \.self) { item in
                let id = item.display("id")
                MockPopRow(on: id == resume, title: item.text("title"),
                           sub: (id == target.application?.display("resume_id") ? "这个岗位用的简历 · " : "") + "\(MockHome.mmdd(item.text("updated_at"))) 更新") {
                    resume = id; menu = nil
                }
            }
        }
    }

    // MARK: 读与写

    private func get(_ path: String, query: [String: String] = [:]) async throws -> JSONValue {
        try await session.api.careerRequest(path: path, method: "GET", query: query, body: nil)
    }

    private func load() async {
        if !started {
            started = true
            mode = request.mode ?? mode; difficulty = request.difficulty ?? difficulty; type = request.interviewType
            if let id = request.resumeID { resume = id }
            if case .experience(let value) = request.plan { scope = value.scope ?? "packaged" }
            applyResume()
        }
        async let capability = try? get("/api/mock-interviews/speech-capability")
        async let profile = try? get("/api/account/user-profile")
        async let priceList = try? get("/api/billing/feature-prices")
        async let summary = try? get("/api/billing/summary")
        let speech = await capability
        let ok = speech?["stt"]?.bool == true && speech?["tts"]?.bool == true
        speechOK = ok
        if !ok { mode = "text" }
        voices = speech?["voices"]?.items ?? []
        if case .object(let defaults)? = speech?["default_voices"] { defaultVoices = defaults.compactMapValues(\.stringValue) }
        let role = await profile
        targetRole = role?["profile"]?.text("target_role").nonEmptyValue ?? role?.text("target_role").nonEmptyValue
        prices = await priceList?["items"]?.items ?? []
        balance = await summary.flatMap { Double($0.display("available")) }
    }

    /// 带来的简历优先，其次岗位关联的简历，否则最近更新的一份。
    private func applyResume() {
        guard !resumes.isEmpty else { return }
        let has = { (id: String) in resumes.contains { $0.display("id") == id } }
        if let id = request.resumeID, has(id) { resume = id; return }
        if let linked = target.application?.display("resume_id").nonEmptyValue, has(linked) { resume = linked; return }
        if has(resume) { return }
        resume = sortedResumes.first?.display("id") ?? ""
    }

    /// 练经历：这段经历的延伸点（`GET /api/resumes/{id}/experience/{entry}/doc`，桌面端未开放时读不到，按整段估题数）。
    private func loadPoints() async {
        guard let experience, !resume.isEmpty else { return }
        points = nil
        let doc = try? await get("/api/resumes/\(resume)/experience/\(experience.ref)/doc")
        if let doc, !Task.isCancelled { points = doc["points"]?.items ?? [] }
    }

    private func start() {
        guard !submitting else { return }
        if short { close(); router?.jump(.plans); return }
        if let blocking { open(blocking.display("id")); return }
        guard !resume.isEmpty else { notice = MockNotice(title: "这场没有开始", message: "先导入或新建一份简历，面试官按简历出题。"); return }
        submitting = true
        var body: [String: JSONValue] = [
            "resume_id": .string(resume), "interview_type": .string(activeType), "difficulty": .string(difficulty), "question_count": .number(Double(count)),
            "follow_up_enabled": .bool(followUp), "language": .string(language), "answer_mode": .string(mode),
        ]
        let session = target.session
        if experience == nil, let id = target.application?.display("id").nonEmptyValue ?? session?.display("application_id").nonEmptyValue {
            body["job_application_id"] = .string(id)
        }
        if session == nil || experience != nil, let targetRole { body["target_role"] = .string(targetRole) }
        if mode == "voice" {
            body["interviewer_voice"] = .string(voice)
            if !voiceValue.isEmpty { body["interviewer_voice_id"] = .string(voiceValue) }
        }
        if let focus = MockStart.practiceFocus(request.plan, scope: scope, packaged: packaged) { body["practice_focus"] = focus }
        Task {
            do {
                let result = try await self.session.api.careerRequest(path: "/api/mock-interviews", method: "POST", query: [:], body: .object(body))
                open(result["mock_interview"]?.display("id") ?? "")
            } catch {
                notice = MockNotice(title: "这场没有开始", message: MockInterviewText.error(error))
                submitting = false
            }
        }
    }
}

/// 弹窗底部按钮（`.ms3-foot .v3-btn`）：36 高、左右 20、14 字；描边按钮 #d4d4cf。
struct MockDialogButton: ButtonStyle {
    let dark: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(14, weight: .medium)).lineLimit(1).fixedSize()
            .foregroundStyle(dark ? .white : MockPalette.ink)
            .padding(.horizontal, 20).frame(height: 36)
            .background {
                if dark { Capsule().fill(configuration.isPressed ? Color(hex: 0x33332F) : MockPalette.ink) }
                else { Capsule().fill(configuration.isPressed ? MockPalette.chip : .white).overlay(Capsule().strokeBorder(Color(hex: 0xD4D4CF))) }
            }
            .opacity(enabled ? 1 : 0.5).contentShape(Capsule()).fixedSize()
    }
}

/// 下拉弹层（`.ms3-pop`）：360 宽，每行两行字，选中浅灰底。
struct MockPopMenu<Content: View>: View {
    var width: CGFloat = 360
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(6).frame(width: width, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MockPalette.line))
            .shadow(color: .black.opacity(0.12), radius: 20, y: 16)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct MockPopRow: View {
    let on: Bool
    let title: String
    var sub: String? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(V3.sans(15, weight: .medium)).foregroundStyle(MockPalette.ink).lineLimit(1).frame(height: 22)
                if let sub { Text(verbatim: sub).font(V3.sans(13)).foregroundStyle(MockPalette.mute).lineLimit(1).frame(height: 18) }
            }
            .padding(.horizontal, 15).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color(hex: 0xF1F0ED) : hover ? Color(hex: 0xF6F5F2) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 换一场（Figma 01.04 / 07.05）：日程里接下来的面试、通用练习，最后是添加面试。
struct MockTargetMenu: View {
    let sessions: [JSONValue]
    let records: [JSONValue]
    let current: MockHome.Target
    let pick: (MockHome.Target) -> Void
    let add: () -> Void
    var body: some View {
        let now = Date()
        MockPopMenu(width: 360) {
            ForEach(sessions, id: \.self) { session in
                MockPopRow(on: session.display("id") == current.id, title: MockHome.sessionTitle(session),
                           sub: MockHome.sessionLine(session, records: records, now: now)) { pick(.session(session, application: nil)) }
            }
            if !sessions.isEmpty { Rectangle().fill(Color(hex: 0xF0EFEC)).frame(height: 1).padding(.vertical, 2) }
            MockPopRow(on: current.id == "general", title: "通用练习", sub: "不针对岗位，只按简历和长期记忆出题") { pick(.general) }
            Button(action: add) {
                HStack(spacing: 4) { Image(systemName: "plus").font(.system(size: 12)); Text("添加面试") }
                    .font(V3.sans(14)).foregroundStyle(MockPalette.blue).padding(.horizontal, 15).padding(.top, 10).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

/// 全站统一的左上返回（`BackCrumb`）：← 上一页 / 当前。
struct MockBackCrumb: View {
    let label: String
    var current: String? = nil
    var disabled = false
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 6) { Image(systemName: "arrow.left").font(.system(size: 13)); Text(verbatim: label) }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(disabled).accessibilityLabel("返回\(label)")
            if let current {
                Text("/").accessibilityHidden(true)
                Text(verbatim: current).foregroundStyle(MockPalette.ink).lineLimit(1)
            }
        }
        .font(V3.sans(16)).foregroundStyle(MockPalette.fnt).frame(height: 20).fixedSize()
    }
}

/// 在模拟面试首页、复盘报告里就地打开首页那张知识图谱（Web `KnowledgeGraphLayer`）：盖住整块内容区，点「收起」或 Esc 回到原页面。
struct MockKnowledgeGraphLayer: View {
    @Environment(SessionStore.self) private var session
    let close: () -> Void
    @State private var graph: HomeGraph?
    @State private var stage: HomeGraphStage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let graph, graph.points > 0 {
                HomeGraphExpandedView(graph: graph, stage: stage, compact: false, chatKey: nil, collapse: close, chat: nil).padding(24)
            } else {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 12) {
                        if failed {
                            Text("知识图谱暂时无法读取").font(V3.serif(20)).foregroundStyle(V3.txt)
                            Button("重试") { attempt += 1 }.buttonStyle(MockPillStyle(kind: .ghost, height: 32, padding: 18, size: 13))
                        } else if graph != nil {
                            Text("图谱里还没有内容").font(V3.serif(20)).foregroundStyle(V3.txt)
                            Text("简历里的经历和技术、练过的面试，都会画在这里。").font(V3.sans(13)).foregroundStyle(V3.fnt)
                        } else {
                            V3Loading("正在加载知识图谱…")
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Button(action: close) {
                        HStack(spacing: 4) { Text("收起"); Image(systemName: "xmark").font(.system(size: 11)) }.contentShape(Rectangle())
                    }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.txt).padding(.top, 34).padding(.trailing, 32)
                }
                .background(Color(hex: 0xFAFAF8), in: RoundedRectangle(cornerRadius: 16)).padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
        .onExitCommand(perform: close)
        .task(id: attempt) {
            failed = false
            guard let json = try? await session.api.careerRequest(path: "/api/memory/home/graph", method: "GET", query: [:], body: nil) else { failed = true; return }
            let next = HomeGraph(json: json)
            graph = next
            stage = await Task.detached(priority: .userInitiated) { HomeGraphStage(graph: next) }.value
        }
    }
}
