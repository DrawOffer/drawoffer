import Foundation
import DrawOfferCore
import SwiftUI

/// 模拟面试首页（Web `v2/MockHome.tsx` + `MockStartHome.tsx` + `HomeV3.tsx`，Figma 5:23 · 01.01–01.08）。
/// 还没练过时是一句话加两张纸（01.01 没有简历 / 01.02 有简历）；有记录时左上是接下来的一场（整段就是下拉，可换一场或通用练习），
/// 中间只抛出一道题——上次卡住的那一处，没有卡住时挑一处还没练的——下面接着练 / 完整模拟和默认配置一行；底部一行长期记忆。
/// 开始前统一弹出确认弹窗（MockStartDialog）。
struct MockHomeV2: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    /// 后台导入推进了一步就重读（Web `subscribeMockInterviews`）。
    @Environment(RecordImports.self) private var recordImports: RecordImports?
    /// 从别处带进来直接开始：打开确认弹窗，关掉后清空
    @Binding var request: MockStartRequest?
    let open: (String) -> Void
    let openReview: (JSONValue) -> Void
    let showRecords: () -> Void
    let showSchedule: () -> Void

    private static let stageW: CGFloat = 1151, stageH: CGFloat = 828
    private static let paper = Color(hex: 0xFCFBF8), paperEdge = Color(hex: 0xE7E5DE), paperMute = Color(hex: 0xA5A39B)

    struct HomeData { var overview: JSONValue; var list: [JSONValue]; var resumes: [JSONValue]; var applications: [JSONValue] = []; var sessions: [JSONValue] = [] }

    @State private var data: HomeData?
    @State private var failed = false
    @State private var tick = 0
    @State private var importing: MockImportRequest?
    @State private var resumeImport = false
    @State private var notice: MockNotice?
    @State private var waitingID: String?
    @State private var topics: [String] = []
    @State private var writing = false
    /// 首页选的场次：nil 是默认最近一场，"general" 是通用练习
    @State private var picked: String?
    @State private var extra: (key: String, outline: JSONValue?, match: JSONValue?) = ("", nil, nil)
    @State private var dialog: MockStartRequest?
    @State private var menu = false
    @State private var pop: String?
    @State private var graph = false
    @State private var anchors: [String: CGFloat] = [:]

    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }
    private func request(_ path: String, query: [String: String] = [:]) async throws -> JSONValue {
        try await session.api.careerRequest(path: path, method: "GET", query: query, body: nil)
    }

    private var active: JSONValue? { data?.list.first { ["in_progress", "preparing"].contains($0.text("status")) } }
    private var recent: JSONValue? { data?.list.sorted { $0.text("created_at") > $1.text("created_at") }.first }
    private var evaluating: JSONValue? { recent.flatMap { ["evaluating", "evaluation_failed"].contains($0.text("status")) ? $0 : nil } }
    private var blocking: JSONValue? { active ?? evaluating }
    private var finished: Int { (data?.overview["counts"]?["mock"]?.integer ?? 0) + (data?.overview["counts"]?["real"]?.integer ?? 0) }
    private var now: Date { Date() }
    private var upcoming: [JSONValue] { data.map { MockHome.upcomingSessions($0.sessions, applications: $0.applications, now: now) } ?? [] }
    private func application(_ id: String) -> JSONValue? { data?.applications.first { $0.display("id") == id } }
    private var target: MockHome.Target {
        if picked == "general" { return .general }
        guard let session = upcoming.first(where: { $0.display("id") == picked }) ?? upcoming.first else { return .general }
        return .session(session, application: application(session.display("application_id")))
    }
    private var latestResume: JSONValue? { data?.resumes.sorted { $0.text("updated_at") > $1.text("updated_at") }.first }

    var body: some View {
        Group {
            if let data {
                if finished == 0 {
                    MockStage(width: Self.stageW, height: Self.stageH) { intro(first: !data.resumes.isEmpty) }
                } else {
                    home(data)
                }
            } else if failed {
                VStack(alignment: .leading, spacing: 12) {
                    Text("MOCK INTERVIEWS").font(V3.sans(12, weight: .medium)).foregroundStyle(MockPalette.mute)
                    Text("模拟面试").font(V3.serif(32)).foregroundStyle(MockPalette.ink)
                    Text("模拟面试没有加载出来").font(V3.sans(15, weight: .medium)).foregroundStyle(MockPalette.ink).padding(.top, 24)
                    Text("请检查网络后重试。").font(V3.sans(13)).foregroundStyle(MockPalette.fnt)
                    Button("重新加载") { tick += 1 }.buttonStyle(MockPillStyle(kind: .ghost, height: 38, padding: 21, size: 13))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.horizontal, 61).padding(.top, 60)
            } else {
                V3Loading("正在加载模拟面试…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.white)
        .overlay { MockNoticeToast(notice: $notice) }
        .task(id: "\(account):\(tick)") { await load() }
        .onChange(of: recordImports?.changed) { _, _ in tick += 1 }
        .task(id: extraKey) { await loadExtra() }
        .task(id: evaluating?.text("status") == "evaluating" ? evaluating?.text("id") ?? "" : "") {
            // 评估中：5 秒起逐步放慢到 30 秒刷新一次，好了提示一下
            guard let id = evaluating?.text("id"), evaluating?.text("status") == "evaluating" else { return }
            waitingID = id
            var attempt = 0
            // 只查这一场的状态，评估完了才作废缓存、整页重取
            while await Polling.wait(attempt, first: 5, cap: 30, topic: "mock_interview", ref: id) {
                attempt += 1
                guard let value = try? await session.api.careerRequest(path: "/api/mock-interviews/\(id)", method: "GET", query: [:], body: nil)["mock_interview"],
                      value.text("status") != "evaluating" else { continue }
                await session.api.purgeCache(); tick += 1; return
            }
        }
        .onChange(of: data?.list.map { $0.text("id") + $0.text("status") } ?? []) { _, _ in
            guard let id = waitingID, data?.list.contains(where: { $0.text("id") == id && $0.text("status") == "completed" }) == true else { return }
            waitingID = nil
            // 一题都没答的没有报告，不提示
            if data?.overview["records"]?.items.first(where: { $0.display("id") == id })?["answered"]?.bool == false, data?.overview["records"]?.items.first(where: { $0.display("id") == id })?["answered"] != nil { return }
            notice = MockNotice(kind: .success, title: "评估报告好了", message: "这场的分数和卡住的地方已经更新")
        }
        .onChange(of: request == nil || data == nil, initial: true) { _, _ in takeRequest() }
        .centeredPanel(item: $dialog) { pending in
            MockStartDialog(request: pending, target: dialogTarget(pending), sessions: finished == 0 ? [] : upcoming,
                            records: data?.overview["records"]?.items ?? [], resumes: data?.resumes ?? [], list: data?.list ?? [],
                            pickTarget: { picked = $0 == .general ? "general" : $0.session?.display("id") },
                            open: { id in dialog = nil; open(id) }, addInterview: { dialog = nil; showSchedule() }, close: { dialog = nil })
        }
        .centeredPanel(item: $importing) { _ in
            MockImportDialog(close: { importing = nil }, done: {
                importing = nil
                // Web `onDone`：关弹窗、重读；进度在铃铛里，页面不再弹提示
                tick += 1
            })
        }
        .centeredSheet(isPresented: $resumeImport) {
            ResumeImportSheet(close: { resumeImport = false }, accepted: { title in
                resumeImport = false
                notice = MockNotice(kind: .queued, title: "已开始导入", message: "「\(title)」解析完成后这里会更新")
                tick += 1
            })
        }
    }

    /// 还没有记录时从别处带进来开始：带了投递就按它接下来的一场，否则通用练习。
    private func dialogTarget(_ pending: MockStartRequest) -> MockHome.Target {
        guard finished == 0 else { return target }
        guard let session = upcoming.first(where: { $0.display("application_id") == pending.applicationID && pending.applicationID != nil }) else { return .general }
        return .session(session, application: application(session.display("application_id")))
    }

    private func takeRequest() {
        guard let pending = request, data != nil else { return }
        request = nil
        if let id = pending.applicationID, let session = upcoming.first(where: { $0.display("application_id") == id }) { picked = session.display("id") }
        dialog = pending
    }

    private func startPlan(_ plan: MockStart.Plan) {
        pop = nil; menu = false
        if let blocking { open(blocking.display("id")); return }
        dialog = MockStartRequest(plan: plan)
    }

    // MARK: 01.01 / 01.02 还没练过

    /// first = false：没有简历（01.01）；first = true：简历放好了、还没练过（01.02）。沿用首页新手引导的“左边文字 + 右边两张纸”。
    private func intro(first: Bool) -> some View {
        let lines = first
            ? ["题目按你简历里写的经历来出，大约 15 分钟。", "练完会记下你答得好和卡住的地方，", "下一场从卡住的地方接着练。"]
            : ["模拟面试的题目从你简历里的经历来出，", "放好以后，第一场大约 15 分钟。", "练完会记下你答得好和卡住的地方。"]
        let primary: () -> Void = { if first { startFirst() } else { resumeImport = true } }
        return ZStack(alignment: .topLeading) {
            Color.white
            HStack(spacing: 10) {
                AssistantBrandMark(size: 28)
                Text(first ? "简历已经放好" : "模拟面试").font(V3.sans(18, weight: .medium)).foregroundStyle(MockPalette.ink)
            }.frame(height: 28).offset(x: 120, y: 210)
            Text(first ? "来练第一场" : "先放一份简历").font(V3.sans(52, weight: .medium)).tracking(-0.52)
                .foregroundStyle(MockPalette.ink).lineLimit(1).fixedSize().frame(height: 70, alignment: .leading).offset(x: 120, y: 258)
            Text(verbatim: lines.joined(separator: "\n")).font(V3.sans(17)).foregroundStyle(MockPalette.sub).lineHeight(17, 30).fixedSize()
                .offset(x: 120, y: 346 - 4.8)
            HStack(spacing: 24) {
                Button(action: primary) {
                    HStack(spacing: 8) {
                        Text(verbatim: first ? (active != nil ? "继续这一场" : evaluating != nil ? "看上一场" : "开始第一场") : "导入简历")
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                    }
                }.buttonStyle(MockPillStyle(height: 44, padding: 24, size: 15))
                Button { if first { importing = MockImportRequest() } else { writeResume() } } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: first ? "已经面过？导入面试记录" : "没有现成的，写一份")
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    }
                }.buttonStyle(MockLinkStyle(size: 15, color: MockPalette.sub)).disabled(writing)
            }.offset(x: 120, y: 476)
            Button(action: primary) { pile(first: first) }.buttonStyle(.plain)
                .frame(width: 600, height: 560, alignment: .topLeading).offset(x: 520, y: 100)
                .accessibilityLabel(first ? "开始第一场模拟面试" : "先放一份简历")
            Text(first ? "点这张纸，开始第一场" : "点这张纸，先放一份简历").font(V3.sans(13)).foregroundStyle(Self.paperMute).fixedSize().offset(x: 850, y: 660)
        }
        .frame(width: Self.stageW, height: Self.stageH, alignment: .topLeading)
        .task(id: first ? latestResume?.display("id") ?? "" : "") {
            // 面试纸上的两道题按简历里的经历写；读不到记忆时用通用说法，不挡页面
            guard first, let json = try? await request("/api/memory/home/graph") else { return }
            topics = HomeGraph(json: json).topics
        }
    }

    /// 两张叠着的纸：后面一张简历（顺时针 6°；有简历时是真实的第一页），前面一张面试题（逆时针 3°）。
    private func pile(first: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Group {
                if first, let id = latestResume?.display("id") {
                    HomeResumePaper(resumeID: id).frame(width: 360, height: 480).clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Self.paperEdge))
                        .shadow(color: .black.opacity(0.08), radius: 14, y: 12)
                } else {
                    blankResume
                }
            }.rotationEffect(.degrees(6)).position(x: 224, y: 307.5)
            interviewPaper(first: first).rotationEffect(.degrees(-3)).position(x: 402.3, y: 258.3)
        }
        .frame(width: 600, height: 560, alignment: .topLeading).contentShape(Rectangle())
    }

    private func paperSheet<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(Self.paper).shadow(color: .black.opacity(0.08), radius: 14, y: 12)
            RoundedRectangle(cornerRadius: 4).strokeBorder(Self.paperEdge)
            content().frame(width: 360, height: 480, alignment: .topLeading).clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(width: 360, height: 480)
    }

    private func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: min(3, h / 2)).fill(color).frame(width: w, height: h).offset(x: x, y: y)
    }

    /// 还没有简历：一张空白简历纸的骨架。
    private var blankResume: some View {
        let strong = Color(hex: 0xCCC9C2), soft = Color(hex: 0xE4E2DB)
        return paperSheet {
            ZStack(alignment: .topLeading) {
                bar(29, 39, 150, 12, strong)
                bar(29, 62, 100, 7, soft)
                bar(29, 92, 24, 2, MockPalette.lightBlue)
                Rectangle().fill(Color(hex: 0xECEBE5)).frame(width: 300, height: 1).offset(x: 29, y: 95)
                ForEach(0..<3, id: \.self) { index in
                    let y = 120 + CGFloat(index) * 95
                    bar(29, y, 60, 8, strong)
                    bar(29, y + 20, 300, 6, soft)
                    bar(29, y + 34, 280, 6, soft)
                    bar(29, y + 48, 240, 6, soft)
                }
                ForEach(Array([40.0, 62, 34].enumerated()), id: \.offset) { index, width in
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xD6D4CC)).frame(width: width, height: 13)
                        .offset(x: 29 + [0.0, 48, 120][index], y: 436)
                }
            }
        }
    }

    private static let wave: [CGFloat] = [2, 2, 2, 3, 6, 5, 5, 6, 9, 6, 11, 8, 10, 12, 18, 13, 9, 17, 22, 14, 11, 18, 21, 11, 17, 15, 16, 18, 22, 13, 12, 22, 24, 14, 12, 21, 20, 10, 11, 15, 13, 13, 12, 9, 7, 13, 11, 5, 6, 9, 6, 3, 3, 3, 2, 2]

    /// 面试纸（Web `InterviewPaper`）：没有简历时开场题 + 灰字的第 2 题；有简历时两道题按简历里的经历写。
    private func interviewPaper(first: Bool) -> some View {
        let firstText = first ? topics.first.map { "讲讲你在「\($0)」里做的事，为什么这样设计？" } ?? "先做个自我介绍，再挑一段你最熟的经历讲讲。" : "先介绍一下你自己，挑一个最想聊的项目讲讲。"
        let secondText = first ? topics.dropFirst().first.map { "「\($0)」里最难的一处是怎么解决的？" } ?? "这段经历里最难的一处是怎么解决的？" : "放好简历后，这一题换成你写过的项目"
        return paperSheet {
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Text(first ? "第 1 题 · 来自你的简历" : "第 1 题 · 开场").font(V3.sans(11)).foregroundStyle(MockPalette.fnt).fixedSize().offset(y: 0)
                    Text(verbatim: firstText)
                        .font(V3.serif(21)).foregroundStyle(MockPalette.ink).lineHeight(21, 31, .serif).frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true).offset(y: 28 - 2.9)
                    Canvas { context, _ in
                        for (index, height) in Self.wave.enumerated() {
                            context.fill(Path(roundedRect: CGRect(x: CGFloat(index) * 5.41, y: 14 - height / 2, width: 2.2, height: height), cornerRadius: 1.1), with: .color(Color(hex: 0xCCC9C2)))
                        }
                    }.frame(width: 300, height: 28).offset(y: 116)
                    Text("轮到你时，直接开口说就行").font(V3.sans(11.5)).foregroundStyle(MockPalette.fnt).fixedSize().offset(y: 170)
                    Rectangle().fill(Color(hex: 0xEFEEE9)).frame(width: 300, height: 1).offset(y: 212)
                    Text("第 2 题 · 来自你的简历").font(V3.sans(11)).foregroundStyle(Self.paperMute).fixedSize().offset(y: 239)
                    Text(verbatim: secondText).font(V3.serif(15)).foregroundStyle(first ? MockPalette.sub : Color(hex: 0xA8A8A1))
                        .frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true).offset(y: 261)
                    Text("第 3 题 · 开始后，接着你的回答追问").font(V3.sans(11)).foregroundStyle(Self.paperMute).fixedSize().offset(y: 310)
                }
                .frame(width: 300, height: 326, alignment: .topLeading).offset(x: 29, y: 39)
                Rectangle().fill(LinearGradient(stops: [.init(color: Self.paper.opacity(0), location: 0), .init(color: Self.paper, location: 0.6), .init(color: Self.paper, location: 1)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 362, height: 174).offset(x: -1, y: 306)
                Text("第一场 · 3 题 · 约 15 分钟").font(V3.sans(11.5)).foregroundStyle(MockPalette.fnt).fixedSize().offset(x: 29, y: 433)
            }
        }
    }

    /// 第一场：3 题先走一遍，确认弹窗里能改。
    private func startFirst() {
        if let blocking { open(blocking.display("id")); return }
        dialog = MockStartRequest(plan: .full(count: MockHome.firstCount, title: "第一场"))
    }

    /// 「没有现成的，写一份」：用默认模板新建（固定名字，重名加序号）并进编辑器引导（Web `startGuidedResume`）。
    private func writeResume() {
        guard !writing else { return }
        writing = true
        Task {
            defer { writing = false }
            for title in ["我的第一份简历", "我的第一份简历 2", "我的第一份简历 3"] {
                do {
                    let result = try await session.api.careerRequest(path: "/api/resumes", method: "POST", query: [:], body: .object(["title": .string(title), "guide": .bool(true)]))
                    let id = (result["resume"] ?? result).display("id")
                    if !id.isEmpty { router?.jump(.editResume(id)) }
                    return
                } catch APIError.server(_, "RESUME_TITLE_CONFLICT") {
                    continue
                } catch APIError.server(_, let code) {
                    notice = MockNotice(title: "没有新建简历", message: code == "RESUME_LIMIT_REACHED" ? "简历数量已到上限，删掉一份再新建。" : "没能新建简历，请重试。")
                    return
                } catch { notice = MockNotice(title: "没有新建简历", message: "没能新建简历，请重试。"); return }
            }
        }
    }

    // MARK: 01.03–01.08 常态首页

    private var extraKey: String {
        guard finished > 0, data != nil, case .session(_, let application) = target else { return "general" }
        let job = application?.display("job_description_id") ?? ""
        let resume = application?.display("resume_id").nonEmptyValue ?? latestResume?.display("id") ?? ""
        return "\(job)|\(resume)"
    }

    /// 选中场次的答辩提纲与岗位要求对照：读不到就按通用规则排，不挡首页。
    private func loadExtra() async {
        let key = extraKey
        guard key != "general" else { extra = (key, nil, nil); return }
        let parts = key.components(separatedBy: "|")
        let job = parts[0], resume = parts.count > 1 ? parts[1] : ""
        async let outline = try? request("/api/memory/outline", query: job.isEmpty ? [:] : ["job_id": job])
        async let match = job.isEmpty || resume.isEmpty ? nil : try? request("/api/memory/match-evidence", query: ["job_id": job, "resume_id": resume])
        let result = (key, await outline, await match)
        if !Task.isCancelled { extra = result }
    }

    private static let side: CGFloat = 80

    private func home(_ data: HomeData) -> some View {
        let overview = data.overview
        let target = target
        let idle = upcoming.isEmpty && picked != "general"
        let model = idle ? MockHome.idle(overview)
            : MockHome.build(target: target, overview: overview, now: now, outline: extra.key == extraKey ? extra.outline : nil, match: extra.key == extraKey ? extra.match : nil)
        let hero = MockHome.hero(overview, model: model)
        let primary = MockHome.primary(model: model, hero: hero, active: active != nil, evaluating: evaluating != nil)
        let resume = data.resumes.first { $0.display("id") == target.application?.display("resume_id") } ?? latestResume
        let total = finished
        return GeometryReader { geometry in
            let side = max(Self.side, (geometry.size.width - 991) / 2)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    top(idle: idle, total: total, target: target).padding(.top, 38)
                    stage(hero: hero, model: model, primary: primary, settings: MockHome.settingsLine(target: target, resumeTitle: resume?.text("title")))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    memory(overview, model: model)
                }
                .padding(.horizontal, side)
                .coordinateSpace(name: "mh3c")
                if menu || pop != nil {
                    Color.white.opacity(0.001).onTapGesture { menu = false; pop = nil }
                }
                if menu {
                    MockTargetMenu(sessions: upcoming, records: overview["records"]?.items ?? [], current: target,
                                   pick: { picked = $0 == .general ? "general" : $0.session?.display("id"); menu = false },
                                   add: { menu = false; showSchedule() })
                        .offset(x: side, y: 38 + 24 + 12)
                }
                if let pop {
                    let left = max(16, min((anchors[pop] ?? 80) - 14, geometry.size.width - 2 * side - 396)) + side
                    upPop(pop, overview: overview)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.bottom, 96).offset(x: left)
                }
                if graph {
                    MockKnowledgeGraphLayer(close: { graph = false })
                }
            }
        }
        .onExitCommand { if menu || pop != nil { menu = false; pop = nil } }
    }

    private func top(idle: Bool, total: Int, target: MockHome.Target) -> some View {
        HStack(spacing: 24) {
            if idle {
                Text(verbatim: total > 0 ? "练过 \(total) 场" : "还没练过").font(V3.sans(13.5)).foregroundStyle(Color(hex: 0x8C8C85))
            } else {
                Button { menu.toggle(); pop = nil } label: {
                    HStack(spacing: 8) {
                        if target.session != nil { Circle().fill(MockPalette.orange).frame(width: 6, height: 6) }
                        Text(verbatim: target.session.map { MockHome.switchLabel($0, now: now) } ?? "通用练习").lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9.5, weight: .medium)).foregroundStyle(MockPalette.fnt)
                    }
                    .font(V3.sans(13.5, weight: .medium)).foregroundStyle(MockPalette.ink).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("选择场次")
            }
            Spacer(minLength: 0)
            HStack(spacing: 28) {
                Button("导入面试记录") { importing = MockImportRequest() }.buttonStyle(MockLinkStyle(size: 13))
                Button("全部记录 (\(total)) ›", action: showRecords).buttonStyle(HomeStrongLink())
            }
        }
        .frame(height: 24)
    }

    private func stage(hero: MockHome.Hero?, model: MockHome.Model, primary: MockHome.Primary, settings: String) -> some View {
        VStack(spacing: 0) {
            if let hero {
                HStack(spacing: 8) {
                    Circle().fill(hero.stuck || !hero.eyebrow.hasPrefix("上次") ? MockPalette.orange : MockPalette.blue).frame(width: 6, height: 6)
                    Text(verbatim: hero.eyebrow).font(V3.sans(13, weight: .medium)).foregroundStyle(MockPalette.sub)
                    if let tail = hero.tail {
                        Text("·").foregroundStyle(Color(hex: 0xC4C4BE))
                        Text(verbatim: tail).foregroundStyle(Color(hex: 0x8C8C85))
                    }
                }.font(V3.sans(13)).frame(height: 20)
                VStack(spacing: 2) {
                    ForEach(Array(MockHome.splitQuestion(hero.question).enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line).font(V3.serif(34)).fontWeight(.semibold).lineHeight(34, 44, .serif)
                    }
                }
                .foregroundStyle(MockPalette.ink).multilineTextAlignment(.center).frame(maxWidth: 760).padding(.top, 14)
                if let sub = hero.sub {
                    Text(verbatim: sub).font(V3.sans(13.5)).foregroundStyle(MockPalette.fnt).multilineTextAlignment(.center).frame(maxWidth: 640).padding(.top, 14)
                }
            } else {
                HStack(spacing: 8) {
                    Circle().fill(MockPalette.orange).frame(width: 6, height: 6)
                    Text(verbatim: model.title).font(V3.sans(13, weight: .medium)).foregroundStyle(MockPalette.sub)
                }.frame(height: 20)
                Text("题目按你简历里写的经历来出").font(V3.serif(34)).fontWeight(.semibold).foregroundStyle(MockPalette.ink).lineHeight(34, 44, .serif).padding(.top, 14)
                Text("练完会记下你答得好和卡住的地方，下一场从卡住的地方接着练").font(V3.sans(13.5)).foregroundStyle(MockPalette.fnt).padding(.top, 14)
            }
            MockRestWave().padding(.top, 28)
            HStack(spacing: 12) {
                Button { startPlan(primary.plan) } label: {
                    Text(verbatim: primary.label + (blocking == nil ? " · \(primary.minutes) 分钟" : "") + " →")
                }.buttonStyle(HomeBigPill(dark: true))
                if primary.showSecondary {
                    Button { startPlan(.full(count: nil, title: nil)) } label: {
                        Text(verbatim: "完整模拟 · \(MockHome.fullCount * MockHome.minutesPerQuestion) 分钟")
                    }.buttonStyle(HomeBigPill(dark: false))
                }
            }.padding(.top, 28)
            HStack(spacing: 12) {
                Text(verbatim: settings).foregroundStyle(Color(hex: 0x8C8C85)).lineLimit(1)
                Button("调整设置 ›") { startPlan(primary.plan) }.buttonStyle(MockLinkStyle(size: 12.5, color: MockPalette.sub))
            }.font(V3.sans(12.5)).padding(.top, 16)
        }
        .padding(.top, 40).padding(.bottom, 110)
    }

    private func memory(_ overview: JSONValue, model: MockHome.Model) -> some View {
        let open = overview["open_topics"]?.items ?? []
        let mastered = (overview["mastered"]?.items ?? []).compactMap(\.stringValue)
        let records = overview["records"]?.items ?? []
        let latest = model.previous ?? model.latest ?? records.filter { $0.text("status") == "completed" && $0["score"]?.numberValue != nil }.sorted { $0.text("at") > $1.text("at") }.first
        return HStack(spacing: 28) {
            Text("长期记忆").font(V3.sans(13, weight: .medium)).foregroundStyle(Color(hex: 0x1C1917))
            if let first = open.first {
                memoryButton("open", icon: "scope", label: "待加强 ", value: "\(first.text("topic"))\(open.count > 1 ? "等" : "") \(open.count) 处") { pop = pop == "open" ? nil : "open"; menu = false }
            }
            if let first = mastered.first {
                memoryButton("mastered", icon: "checkmark.circle", label: "已掌握 ", value: "\(first)\(mastered.count > 1 ? "等" : "") \(mastered.count) 处") { pop = pop == "mastered" ? nil : "mastered"; menu = false }
            }
            if let latest, let score = latest["score"]?.numberValue {
                memoryButton("latest", icon: "clock", label: "上一场 ", value: "\(Int(score)) 分 · 看复盘") { openReview(latest) }
            }
            Spacer(minLength: 0)
            memoryButton("graph", icon: "point.3.connected.trianglepath.dotted", label: "", value: "知识图谱") { graph = true; pop = nil }
        }
        .frame(height: 20)
        .padding(.top, 18).padding(.bottom, 42)
        .overlay(alignment: .top) { Rectangle().fill(MockPalette.line).frame(height: 1) }
        .onPreferenceChange(MockAnchorKey.self) { anchors = $0 }
    }

    private func memoryButton(_ key: String, icon: String, label: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11.5)).foregroundStyle(Color(hex: 0x8C8680))
                HStack(spacing: 0) {
                    Text(verbatim: label).foregroundStyle(Color(hex: 0x8C8680))
                    Text(verbatim: value).font(V3.sans(13, weight: .medium)).foregroundStyle(Color(hex: 0x37332F)).lineLimit(1)
                }
                Text("›").foregroundStyle(Color(hex: 0xA8A29E))
            }
            .font(V3.sans(13)).fixedSize().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { proxy in Color.clear.preference(key: MockAnchorKey.self, value: [key: proxy.frame(in: .named("mh3c")).minX]) })
    }

    /// 底部向上展开的列表（01.05 待加强、01.06 已掌握）：点外面或 Esc 收起。
    private func upPop(_ kind: String, overview: JSONValue) -> some View {
        let open = overview["open_topics"]?.items ?? []
        let mastered = (overview["mastered"]?.items ?? []).compactMap(\.stringValue)
        let records = overview["records"]?.items ?? []
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: kind == "open" ? "待加强 \(open.count) 处" : "已掌握 \(mastered.count) 处").font(V3.sans(15, weight: .semibold)).foregroundStyle(MockPalette.ink)
                    if kind != "open" { Text("最近掌握的在前").font(V3.sans(12)).foregroundStyle(Color(hex: 0xA8A29E)) }
                    Spacer(minLength: 0)
                }
                Text(kind == "open" ? "这几处上次没答到位，下次可能还会被问到" : "接着练时跳过这些，不再重复出题").font(V3.sans(12.5)).foregroundStyle(Color(hex: 0x8C8680))
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
            .overlay(alignment: .bottom) { if kind != "open" { Rectangle().fill(Color(hex: 0xF2F1EE)).frame(height: 1) } }
            .padding(.bottom, kind == "open" ? 0 : 4)
            if kind == "open" {
                VStack(spacing: 0) {
                    ForEach(Array(open.enumerated()), id: \.offset) { index, topic in
                        MockOpenRow(first: index == 0, name: topic.text("topic"), line: MockHome.openLine(topic)) {
                            startPlan(.single(MockStart.Item(label: topic.text("topic"), question: topic.text("question"),
                                                             signals: (topic["signals"]?.items ?? []).compactMap(\.stringValue), source: topic.text("source").nonEmptyValue),
                                              ref: nil, focusKind: nil, origin: nil))
                        }
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(mastered, id: \.self) { name in
                            HStack(spacing: 16) {
                                Text(verbatim: name).font(V3.sans(14, weight: .medium)).foregroundStyle(Color(hex: 0x37332F)).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(verbatim: MockHome.reachedIn(records, name: name) ?? "").font(V3.sans(12)).foregroundStyle(Color(hex: 0xA8A29E))
                            }.padding(.horizontal, 12).frame(minHeight: 36)
                        }
                    }
                }.frame(maxHeight: min(270, CGFloat(mastered.count) * 36))
            }
        }
        .padding(.top, 18).padding(.horizontal, 8).padding(.bottom, 8)
        .frame(width: 380, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MockPalette.line))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 8)
        .accessibilityElement(children: .contain).accessibilityLabel(kind == "open" ? "待加强" : "已掌握")
    }

    // MARK: 读取

    private func load() async {
        guard !account.isEmpty else { return }
        do {
            async let overview = request("/api/mock-interviews/overview")
            async let list = request("/api/mock-interviews", query: ["limit": "100"])
            async let resumes = request("/api/resumes")
            // “下一场按哪场面试准备”：读不到岗位和日程时按通用练习，不挡首页
            let since = ISO8601DateFormatter().string(from: ReadCache.floor(Date(), minutes: 5).addingTimeInterval(-6 * 3600))
            async let applications = try? request("/api/job-applications", query: ["scope": "active", "limit": "200"])
            async let sessions = try? request("/api/interview-sessions", query: ["status": "scheduled", "start_at": since, "limit": "500"])
            var next = HomeData(overview: try await overview, list: try await list["items"]?.items ?? [], resumes: try await resumes["resumes"]?.items ?? [])
            next.applications = await applications?["items"]?.items ?? []
            next.sessions = await sessions?["items"]?.items ?? []
            if Task.isCancelled { return }
            data = next; failed = false
        } catch { if !Task.isCancelled && data == nil { failed = true } }
    }
}

private struct MockAnchorKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// 待加强里的一处：名字、停过几场 · 卡在哪，右边「练这一处」；第一行和悬停浅灰底。
private struct MockOpenRow: View {
    let first: Bool
    let name: String
    let line: String
    let practice: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).font(V3.sans(15, weight: .medium)).foregroundStyle(MockPalette.ink).lineLimit(1)
                Text(verbatim: line).font(V3.sans(12.5)).foregroundStyle(Color(hex: 0x8C8680)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("练这一处", action: practice).buttonStyle(.plain).font(V3.sans(13, weight: .medium)).foregroundStyle(MockPalette.ink)
        }
        .padding(.horizontal, 12).frame(minHeight: 62)
        .background(first || hover ? Color(hex: 0xF1F0ED) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hover = $0 }
    }
}

/// 首页右上「全部记录 (N) ›」：墨色 13 中粗。
private struct HomeStrongLink: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(13, weight: .medium)).foregroundStyle(MockPalette.ink).opacity(configuration.isPressed ? 0.7 : 1).fixedSize().contentShape(Rectangle())
    }
}

/// 首页中间两颗 44 高胶囊（`.mh3c-primary` / `.mh3c-secondary`）。
private struct HomeBigPill: ButtonStyle {
    let dark: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(14, weight: .medium)).lineLimit(1).fixedSize()
            .foregroundStyle(dark ? .white : Color(hex: 0x37332F))
            .padding(.horizontal, 22).frame(minWidth: dark ? 175 : nil).frame(height: 44)
            .background {
                if dark { Capsule().fill(configuration.isPressed ? Color(hex: 0x37332F) : MockPalette.ink) }
                else { Capsule().fill(.white).overlay(Capsule().strokeBorder(configuration.isPressed ? Color(hex: 0xCFCDC6) : MockPalette.cl)) }
            }
            .contentShape(Capsule()).fixedSize()
    }
}

/// 静息声纹：一排灰色细竖条，中间高两边低（Web `RestWave`）。
struct MockRestWave: View {
    private static let bars: [CGFloat] = (0..<72).map { index in
        let center = 1 - abs(Double(index) - 35.5) / 36
        let wobble = (sin(Double(index) * 1.7) + sin(Double(index) * 0.63 + 1)) / 4 + 0.5
        return CGFloat(max(2, (2 + center * center * 30 * wobble).rounded()))
    }
    var body: some View {
        Canvas { context, _ in
            for (index, height) in Self.bars.enumerated() {
                let rect = CGRect(x: CGFloat(index) * 6.1 + 1, y: 18 - height / 2, width: 1.6, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.8), with: .color(height > 14 ? Color(hex: 0xA5A39B) : Color(hex: 0xCFCDC6)))
            }
        }
        .frame(width: 440, height: 36).accessibilityHidden(true)
    }
}

/// 模拟面试错误文案（Web `MOCK_INTERVIEW_ERROR_MESSAGES`）。
enum MockInterviewText {
    static let messages = [
        "CREDIT_INSUFFICIENT": "积分已用完，本次 AI 请求没有发出。",
        "PAID_CREDIT_REQUIRED": "当前额度不能使用这项功能。",
        "MOCK_INTERVIEW_NOT_FOUND": "这场模拟面试不存在或已被删除。",
        "MOCK_INTERVIEW_IN_PROGRESS": "已有一场进行中的模拟面试，请先完成或放弃它。",
        "MOCK_INTERVIEW_QUESTION_MISMATCH": "题目已经变化，请刷新后再作答。",
        "MOCK_INTERVIEW_STATE_INVALID": "当前状态不能执行这个操作，请刷新后重试。",
        "MOCK_INTERVIEW_RESUME_REQUIRED": "这条求职记录没有关联简历，请另选一份简历。",
        "MOCK_INTERVIEW_RESUME_INVALID": "这份简历暂时无法用于模拟面试，请换一份或重新保存后再试。",
        "MOCK_INTERVIEW_MATERIAL_INVALID": "参考资料不可用：最多选择 10 份已解析成功的文字资料。",
        "MOCK_INTERVIEW_SOURCE_NOT_FOUND": "选择的简历、岗位或求职记录不存在。",
        "MOCK_INTERVIEW_CURSOR_INVALID": "列表翻页失败，请刷新后重试。",
        "MOCK_INTERVIEW_TURN_FAILED": "面试官没能生成回复，回答已保存，请重新生成。",
        "MOCK_INTERVIEW_SPEECH_UNAVAILABLE": "语音面试暂不可用，请改用文字面试。",
        "MOCK_INTERVIEW_SPEECH_SESSION_INVALID": "语音识别已过期，请重新录音。",
        "MOCK_INTERVIEW_SPEECH_EMPTY": "没有识别到文字，请重新录音或改用打字。",
        "MOCK_INTERVIEW_SPEECH_FAILED": "语音识别失败，请重录或改用文字。",
        "DATASET_MEDIA_STORAGE_LIMIT_REACHED": "音视频空间已满，录音无法保存。请改用文字作答，或删除不用的录音录像。",
        "MOCK_INTERVIEW_RECORDING_STORE_FAILED": "录音保存失败，请稍后重试提交。",
        "MOCK_INTERVIEW_RECORDING_DELETE_FAILED": "录音删除失败，请稍后重试。",
        "MOCK_INTERVIEW_TRANSCRIPT_ALREADY_CORRECTED": "本场识别稿已经修正过一次。",
        "MOCK_INTERVIEW_TRANSCRIPT_CORRECTION_REJECTED": "修改幅度超过原识别稿的 15%，只能修正错字和术语。",
        "MOCK_INTERVIEW_RECORDING_NOT_FOUND": "录音已删除或不存在。",
        "MOCK_INTERVIEW_RE_EVALUATE_LIMIT": "每道题最多重新评估 3 次。",
        "MOCK_INTERVIEW_ACTION_NOT_FOUND": "这条建议已经不在报告里了，请刷新后重试。",
        "MOCK_INTERVIEW_PLAN_INCOMPLETE": "面试题目没有准备完整，请重试。",
        "MOCK_INTERVIEW_TASK_INTERRUPTED": "后台任务被中断，请重试。",
        "LLM_MODEL_NOT_CONFIGURED": "AI 模型暂未配置，请稍后再试。",
        "LLM_RESPONSE_INVALID": "AI 返回的内容无法使用，请重试。",
        "VALIDATION_ERROR": "提交的内容不符合要求，请检查后重试。",
        "UNAUTHORIZED": "登录已过期，请重新登录。",
        "INTERVIEW_QUESTIONS_NOT_FOUND": "没找到面试问题，换一份文字稿试试。",
    ]
    static func error(_ error: Error) -> String {
        if case APIError.unauthorized = error { return messages["UNAUTHORIZED"]! }
        if case APIError.server(_, let code) = error, let message = messages[code] { return message }
        return "操作没有完成，请稍后重试。"
    }
}
