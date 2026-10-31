import Foundation
import DrawOfferCore
import SwiftUI

/// 模拟面试首页 V2（Web `mock-interview/v2/MockHomeV2.tsx`，Figma 09 · V2-A ~ V2-F、H1 ~ H12）：正中是以下一场面试为中心的
/// 掌握程度图，下面是地平线（练过的分数 → 今天 → 面试），底部「面试设置」+「开始练习」；设计稿 1151 × 828 整体缩放。
struct MockHomeV2: View {
    @Environment(SessionStore.self) private var session
    var focus: PracticeFocus?
    let open: (String) -> Void
    let openReport: (String) -> Void
    let showRecords: () -> Void
    let showSchedule: () -> Void
    let showResumes: () -> Void
    let showLibrary: () -> Void
    let showOpportunities: () -> Void

    private static let width = 1151.0, height = 828.0
    private static let map = MockLayout.home.at
    private static let auto = "auto", general = "general"
    private static let counts = [5, 8, 10]
    private static let types = ["technical", "project_deep_dive", "comprehensive", "hr"]

    struct HomeData {
        var list: [JSONValue] = []
        var applications: [JSONValue] = []
        var sessions: [JSONValue] = []
        var resumes: [JSONValue] = []
        var atlas: JSONValue?
        var datasets: [JSONValue] = []
        var speech = false
        var targetRole: String?
        var prices: [JSONValue] = []
    }

    enum Menu { case switchJob, settings, resume, legend }
    enum Dialog { case jobs, more }

    @State private var data: HomeData?
    @State private var failed = false
    @State private var tick = 0
    @State private var now = Date()
    @State private var chosen: String?
    @State private var detailApp: JSONValue?
    @State private var outline: JSONValue?
    @State private var match: JSONValue?
    @State private var type = "comprehensive"
    @State private var typeTouched = false
    @State private var difficulty = "intermediate"
    @State private var mode = "voice"
    @State private var count = 8
    @State private var language = "zh"
    @State private var followUp = true
    @State private var useMaterials = false
    @State private var resume = ""
    @State private var focusID = MockHomeV2.auto
    @State private var focusTouched = false
    @State private var menu: Menu?
    @State private var switchFromSettings = false
    @State private var dialog: Dialog?
    @State private var previewDiff: String?
    @State private var selected: String?
    @State private var selectedSession: String?
    @State private var sessionDetail: JSONValue?
    @State private var sessionResume: (id: String, data: JSONValue)?
    @State private var drag: (id: String, x: Double, y: Double, over: Bool)?
    @State private var submitting = false
    @State private var busy: String?
    @State private var toast: (title: String, message: String?, error: Bool)?
    @State private var remind = false
    @State private var remindID: String?

    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }
    private func request(_ path: String, _ method: String = "GET", _ body: JSONValue? = nil, query: [String: String] = [:]) async throws -> JSONValue {
        try await session.api.careerRequest(path: path, method: method, query: query, body: body)
    }

    // MARK: 派生

    private var target: MockMap.Target {
        guard let data else { return MockMap.Target(kind: .general, application: nil, session: nil) }
        return MockMap.pickTarget(applications: data.applications, sessions: data.sessions, now: now, chosen: chosen)
    }
    private var effectiveDiff: String { previewDiff ?? difficulty }
    private var targetLevel: Double { MockMap.diffLevel[effectiveDiff] ?? 3 }
    private var home: (points: [MockMap.HomePoint], sectors: [MockMap.Sector]) {
        MockMap.homePoints(atlas: data?.atlas, outline: outline, match: match, type: type)
    }
    private var active: JSONValue? { data?.list.first { ["in_progress", "preparing"].contains($0.text("status")) } }
    private var recent: JSONValue? { data?.list.sorted { $0.text("created_at") > $1.text("created_at") }.first }
    private var evaluating: JSONValue? { recent.flatMap { ["evaluating", "evaluation_failed"].contains($0.text("status")) ? $0 : nil } }
    private var blockingID: String? { active?.text("id") ?? evaluating?.text("id") }
    private var completed: [JSONValue] { data?.list.filter { $0.text("status") == "completed" } ?? [] }
    private var fresh: Bool {
        guard data != nil else { return false }
        return completed.isEmpty && (data?.atlas?["nodes"]?.items.isEmpty ?? true) && target.kind == .general && chosen != Self.general
    }
    private var targetLabel: String { "\(MockMap.diffName[effectiveDiff] ?? "")目标线 · 要答到「\(MockMap.levels[Int(targetLevel) - 1])」" }
    private var showSession: JSONValue? { selectedSession != nil || blockingID != nil ? sessionDetail : nil }

    var body: some View {
        MockStage(width: Self.width, height: Self.height) { canvas }
            .task(id: "\(account):\(tick)") { await load() }
            .task(id: target.application?.display("id") ?? "") { await loadApplication() }
            .task(id: "\(target.kind == .general ? "" : target.application?.display("job_description_id") ?? ""):\(target.kind == .general)") { await loadOutline() }
            .task(id: "\(target.application?.display("job_description_id") ?? ""):\(resume):\(target.kind == .general)") { await loadMatch() }
            .task(id: (selectedSession ?? blockingID) ?? "") { await loadSession() }
            .task(id: evaluating?.text("status") == "evaluating" ? evaluating?.text("id") ?? "" : "") {
                guard evaluating?.text("status") == "evaluating" else { return }
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(5)); if Task.isCancelled { return }; tick += 1 }
            }
            .onChange(of: data?.list.map { $0.text("id") + $0.text("status") } ?? []) { _, _ in checkReminder() }
    }

    // MARK: 加载

    private func load() async {
        guard !account.isEmpty else { return }
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-6 * 3600))
        do {
            async let list = request("/api/mock-interviews", query: ["limit": "100"])
            async let applications = try? request("/api/job-applications", query: ["scope": "active", "limit": "200"])
            async let sessions = try? request("/api/interview-sessions", query: ["status": "scheduled", "start_at": since, "limit": "500"])
            async let resumes = try? request("/api/resumes")
            async let atlas = try? request("/api/memory/atlas")
            async let datasets = try? request("/api/datasets")
            async let speech = try? request("/api/mock-interviews/speech-capability")
            async let profile = try? request("/api/account/user-profile")
            async let prices = try? request("/api/billing/feature-prices")
            let value = try await list
            var next = HomeData()
            next.list = value["items"]?.items ?? []
            next.applications = await applications?["items"]?.items ?? []
            next.sessions = await sessions?["items"]?.items ?? []
            next.resumes = await resumes?["resumes"]?.items ?? []
            next.atlas = await atlas
            next.datasets = await datasets?["datasets"]?.items ?? []
            let capability = await speech
            next.speech = capability?["stt"]?.bool == true && capability?["tts"]?.bool == true
            let role = await profile
            next.targetRole = role?["profile"]?.text("target_role").nonEmptyValue ?? role?.text("target_role").nonEmptyValue
            next.prices = await prices?["items"]?.items ?? []
            if Task.isCancelled { return }
            now = Date()
            if data == nil && !next.speech { mode = "text" }
            if data == nil, focus == nil { } // 首次加载后由 applyDefaults 决定「先问」
            data = next; failed = false
            applyDefaults()
        } catch { if !Task.isCancelled && data == nil { failed = true } }
    }

    private func loadApplication() async {
        guard let id = target.application?.display("id"), !id.isEmpty else { detailApp = nil; return }
        detailApp = (try? await request("/api/job-applications/\(id)"))?["application"]
    }
    private func loadOutline() async {
        guard data != nil else { return }
        let job = target.kind == .general ? "" : target.application?.display("job_description_id") ?? ""
        outline = try? await request("/api/memory/outline", query: job.isEmpty ? [:] : ["job_id": job])
        applyDefaults()
    }
    private func loadMatch() async {
        let job = target.application?.display("job_description_id") ?? ""
        guard !job.isEmpty, !resume.isEmpty, target.kind != .general else { match = nil; return }
        match = try? await request("/api/memory/match-evidence", query: ["job_id": job, "resume_id": resume])
        applyDefaults()
    }
    private func loadSession() async {
        guard let id = selectedSession ?? blockingID else { sessionDetail = nil; return }
        sessionDetail = (try? await request("/api/mock-interviews/\(id)"))?["mock_interview"]
        let resumeID = sessionDetail?.display("resume_id") ?? ""
        if !resumeID.isEmpty, sessionResume?.id != resumeID, let value = try? await request("/api/resumes/\(resumeID)") {
            sessionResume = (resumeID, value["resume"]?["data"] ?? .null)
        }
    }

    /// 简历、类型、「先问」的默认值（Web 里几个 useEffect）。
    private func applyDefaults() {
        guard let data else { return }
        if !data.resumes.isEmpty {
            let linked = target.application?.display("resume_id") ?? ""
            if !linked.isEmpty, data.resumes.contains(where: { $0.display("id") == linked }) { resume = linked }
            else if !data.resumes.contains(where: { $0.display("id") == resume }) {
                resume = data.resumes.sorted { $0.text("updated_at") > $1.text("updated_at") }.first?.display("id") ?? ""
            }
        }
        if !typeTouched {
            let stage = target.session?.text("stage_label").nonEmptyValue ?? target.application?.text("current_stage_label") ?? ""
            type = stage.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("HR") ? "hr" : "comprehensive"
        }
        guard !focusTouched else { return }
        let points = home.points
        if let focus {
            if let found = points.first(where: { $0.focus != nil && ((!focus.ref.isEmpty && $0.focus?.ref == focus.ref) || $0.point.name == focus.label || $0.focus?.label == focus.label) }) { focusID = found.point.id }
            return
        }
        let suggested = MockMap.suggestFocus(points, targetLevel: MockMap.diffLevel[difficulty] ?? 3)
        focusID = suggested != nil && !fresh ? suggested!.point.id : Self.auto
    }

    private func checkReminder() {
        guard let id = remindID, let done = data?.list.first(where: { $0.text("id") == id && $0.text("status") == "completed" }) else { return }
        remindID = nil; remind = false
        toast = ("评估报告好了", "\(MockMap.mmddDot(done.text("created_at"))) 这场的报告已经生成", false)
    }

    // MARK: 画布

    @ViewBuilder private var canvas: some View {
        if failed && data == nil {
            VStack(spacing: 10) {
                Text("模拟面试没有加载出来").font(V3.serif(18)).foregroundStyle(MI.ink)
                Text("请检查网络后重试。").font(V3.sans(13)).foregroundStyle(MI.sub)
                Button("重新加载") { tick += 1 }.buttonStyle(MockButtonStyle())
            }.frame(width: Self.width, height: Self.height * 0.8)
        } else {
            board
        }
    }

    @ViewBuilder private var board: some View {
        let (points, sectors) = home
        let slots = showSession.flatMap { MockLayout.slots($0, memory: points.map(\.point), experienceOf: MockMap.experienceIndex(sessionResume?.id == $0.display("resume_id") ? sessionResume?.data : nil)) }
        let mapPoints = slots?.points ?? points.map(\.point)
        let focusPoint = focusID == Self.auto ? nil : points.first { $0.point.id == focusID }
        let subs = subsFor(points)
        let placed = MockMap.place(Self.map, mapPoints)
        let sessionLayout = slots.map { MockLayout.homeSession($0, targetLevel: targetLevel, targetLabel: targetLabel) }
        let homeLayout: MockLayout.Layout? = slots != nil || data == nil ? nil : MockLayout.homeMap(
            points: placed, sectors: sectors, targetLevel: targetLevel, targetLabel: targetLabel,
            subs: subs.mapValues(\.0), strong: [selected, focusPoint?.point.id].compactMap { $0 }, gaps: true)
        let layout = sessionLayout ?? homeLayout
        let dim: [String] = type == "project_deep_dive" ? sectors.filter { $0.name != MockMap.projectSector }.map(\.name)
            : type == "hr" ? sectors.filter { $0.name != MockMap.expressSector }.map(\.name) : []
        let focusPlaced = focusPoint.flatMap { f in placed.first { $0.point.id == f.point.id } }
        let horizon = data.map { MockMap.horizon(list: $0.list, target: target, difficulty: difficulty, now: now) }
        ZStack(alignment: .topLeading) {
            Color.white.frame(width: Self.width, height: Self.height).onTapGesture { selected = nil; selectedSession = nil; menu = nil }
            MasteryMapView(
                width: Self.width, height: Self.height, g: Self.map, points: data == nil ? [] : mapPoints, sectors: slots?.sectors ?? sectors,
                targetLevel: targetLevel, targetLabel: targetLabel, center: data == nil ? " " : centerText, dim: slots == nil ? dim : [],
                path: slots?.path, bounds: slots?.bounds, labels: layout?.labels, sectorLabels: layout?.sectors, selected: selected,
                focus: showSession == nil ? focusPoint?.point.id : nil, labelOnly: showSession != nil ? slots?.path.map(\.id) : nil,
                subs: showSession == nil ? subs : [:], noGap: slots != nil, empty: data == nil, loading: data == nil)
            if data != nil { pointTargets(placed) }
            HomeHorizonView(
                horizon: horizon, selectedSession: selectedSession,
                todayLabel: evaluating.map { $0.text("status") == "evaluation_failed" ? "今天 · 评估没完成" : "今天 · 报告生成中" } ?? "今天 \(MockMap.mmddDot(now))",
                slots: count, slotsLabel: "这一场 · \(count) 题 · 约 \(count * 5) 分钟",
                focusSlot: focusPlaced != nil && showSession == nil ? (pointColor(focusPlaced!.point), CGPoint(x: focusPlaced!.x, y: focusPlaced!.y)) : nil,
                dashSlots: fresh, hideSlots: data == nil || active != nil, dropActive: drag?.over == true,
                live: active.map { "进行中 · \(max(1, sessionDetail?["answered_main_questions"]?.integer ?? 1)) / \($0["question_count"]?.integer ?? 0)" },
                evaluating: evaluating != nil, interviewLink: target.session != nil ? showSchedule : nil,
                onSession: { id in selectedSession = id == selectedSession ? nil : id; selected = nil },
                onReport: openReport, onLive: { if let id = active?.text("id") { open(id) } })
            if let drag, let point = mapPoints.first(where: { $0.id == drag.id }) {
                Circle().fill(MI.orange.opacity(0.12)).overlay(Circle().stroke(MI.orange, style: StrokeStyle(lineWidth: 1.3, dash: [3, 2])))
                    .frame(width: 16, height: 16).offset(x: drag.x - 8, y: drag.y - 8).allowsHitTesting(false)
                MapLabel(text: point.name, size: 11.5, color: MI.orange, weight: .medium).pin(drag.x + 12, drag.y - 22).allowsHitTesting(false)
                if drag.over, let x = MockMap.slotXs(count).first {
                    MapLabel(text: "松开设为先问", size: 11, color: MI.blue, weight: .medium).pin(x, MockMap.arcY(width: Self.width, top: MockMap.homeHorizonTop)(x) - 46, align: .center)
                }
            }
            panel(points).offset(x: 56, y: 28)
            topRight.frame(width: Self.width - 25, alignment: .trailing).offset(y: 30)
            composer.frame(width: Self.width).offset(y: 760)
            note.frame(width: Self.width).offset(y: 806)
            overlays(points)
            if let toast {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: toast.title).font(V3.sans(13, weight: .medium)).foregroundStyle(toast.error ? V3.red : MI.ink)
                        if let message = toast.message { Text(verbatim: message).font(V3.sans(12)).foregroundStyle(MI.sub) }
                    }
                    Button { self.toast = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(MI.mute).accessibilityLabel("关闭")
                }
                .padding(.horizontal, 16).padding(.vertical, 12).background(.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xE6E3DC))).shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                .frame(width: Self.width - 24, height: Self.height - 24, alignment: .bottomTrailing)
                .task(id: toast.title) { try? await Task.sleep(for: .seconds(5)); self.toast = nil }
            }
        }
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
    }

    private var centerText: String {
        if target.kind == .general { return "只按简历" }
        if fresh { return "先练一场" }
        if let session = target.session { return MockMap.companyName(target) + session.text("stage_label") }
        return MockMap.companyName(target)
    }

    private func pointColor(_ point: MockMap.Point) -> Color {
        if point.pending { return MI.gry }
        if point.level == 0 { return point.job ? MI.orange : MI.gry }
        return point.level >= targetLevel ? MI.blue : MI.orange
    }

    private func askWord(_ ask: Int) -> String { ask >= 3 ? "高" : ask == 2 ? "中" : "低" }

    private func subsFor(_ points: [MockMap.HomePoint]) -> [String: (String, MockMap.SubTone)] {
        if let previewDiff, previewDiff != difficulty {
            var changed: [String: (String, MockMap.SubTone)] = [:]
            for item in points where item.point.level > 0 && item.point.level < targetLevel && item.point.ask == 3 { changed[item.point.id] = ("差 \(Int(targetLevel - item.point.level)) 层", .orange) }
            return changed
        }
        if type == "project_deep_dive" {
            var hooks: [String: (String, MockMap.SubTone)] = [:]
            for item in points where item.point.sector == MockMap.projectSector {
                if item.point.level == 0 { hooks[item.point.id] = ("还没被追问过 · 被问概率 \(askWord(item.point.ask))", .orange) }
                else if item.point.level < targetLevel { hooks[item.point.id] = ("只答到「\(MockMap.levelName(item.point.level))」", .orange) }
            }
            return hooks
        }
        return MockMap.pointSubs(points, targetLevel: targetLevel, focusID: focusID == Self.auto ? nil : focusID)
    }

    /// 图上每个点的点击与拖动区域（半径 15）。
    @ViewBuilder private func pointTargets(_ placed: [MockMap.Placed]) -> some View {
        let slotX = MockMap.slotXs(count).first ?? 590
        let slotY = MockMap.arcY(width: Self.width, top: MockMap.homeHorizonTop)(slotX)
        ForEach(placed, id: \.point.id) { item in
            Color.clear.frame(width: 30, height: 30).contentShape(Circle())
                .help(item.point.name)
                .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("mockHome"))
                    .onChanged { value in
                        guard blockingID == nil, home.points.first(where: { $0.point.id == item.point.id })?.focus != nil else { return }
                        let x = item.x + value.translation.width, y = item.y + value.translation.height
                        drag = (item.point.id, x, y, hypot(x - slotX, y - slotY) < 30)
                    }
                    .onEnded { _ in
                        if let drag, drag.over { chooseFocus(drag.id) }
                        drag = nil
                    })
                .onTapGesture { if drag == nil { selected = item.point.id == selected ? nil : item.point.id; selectedSession = nil } }
                .accessibilityElement().accessibilityLabel(item.point.name).accessibilityAddTraits(.isButton)
                .accessibilityAction { selected = item.point.id == selected ? nil : item.point.id; selectedSession = nil }
                .offset(x: item.x - 15, y: item.y - 15)
        }
    }

    private func chooseFocus(_ id: String) { focusTouched = true; focusID = id; menu = nil }

    // MARK: 左上角

    @ViewBuilder private func panel(_ points: [MockMap.HomePoint]) -> some View {
        if data != nil {
            if let id = selected, let point = points.first(where: { $0.point.id == id }) { pointPanel(point) }
            else if let id = selectedSession, let detail = sessionDetail, detail.text("id") == id { sessionPanel(detail) }
            else if blockingID != nil, let view = blockingPanel() { view }
            else { headPanel(points) }
        }
    }

    private var chain: [MockMap.ChainItem] { MockMap.stageChain(detailApp ?? target.application, session: target.session, now: now) }

    private func sessionSub() -> String? {
        guard let session = target.session, let start = CareerApplication.date(session.text("start_at")) else { return nil }
        return "\(session.text("stage_label")) · \(MockMap.relativeDay(start, now: now)) \(MockMap.hhmm(start)) · \(target.application?.text("job_title_snapshot").nonEmptyValue ?? session.text("job_title"))"
    }

    @ViewBuilder private func headPanel(_ points: [MockMap.HomePoint]) -> some View {
        let missing = points.filter { $0.point.level > 0 && $0.point.level < targetLevel }
        let jobUnasked = points.filter { $0.point.job && $0.point.level == 0 }
        let diffName = MockMap.diffName[effectiveDiff] ?? ""
        let hint = MockLine(text: "圈越往里答得越深，点越大越可能被问", size: 12)
        if fresh {
            MockPanel(label: "还没练过", big: "先练一场") {
                MockLine(text: "面试官按你的简历出题。练完以后，每个知识点会落到它答到的那一圈。")
                MockLine(text: "外圈虚线 = 简历里写了、还没被问过", tone: .gry, size: 12)
            }
        } else if target.kind == .general {
            MockPanel(label: "通用练习", big: "不挑岗位", bigSub: "只按简历出题") {
                MockLine(text: "没有岗位要求，外圈的点只按简历里写到的排")
                MockLine(text: "适合保持手感；有面试安排时建议换回那一场")
            }
        } else {
            let sub = sessionSub() ?? "\(target.application?.text("job_title_snapshot") ?? "") · 待约面"
            MockPanel(label: target.session != nil ? "下一场" : "在投岗位", big: MockMap.companyName(target), bigSub: sub) {
                if !chain.isEmpty { MockChain(items: chain) }
                if target.session == nil { MockLine(text: "没有面试安排，按在投岗位里最该练的排") }
                let gapLine: MockLine? = !missing.isEmpty ? MockLine(text: "\(diffName)要答到「\(MockMap.levels[Int(targetLevel) - 1])」，\(previewDiff != nil ? "有" : "还有") \(missing.count) 个点没到", tone: .or)
                    : !points.isEmpty ? MockLine(text: "\(diffName)的目标线以内都答到了", tone: .blue) : nil
                if let previewDiff, previewDiff != difficulty {
                    if let gapLine { gapLine }
                    MockLine(text: "\(target.session?.text("stage_label") ?? "这场")按「\(MockMap.diffName[difficulty] ?? "")」推荐；选\(MockMap.diffName[previewDiff] ?? "")时追问会\((MockMap.diffLevel[previewDiff] ?? 0) > (MockMap.diffLevel[difficulty] ?? 0) ? "更深" : "更浅")")
                    hint
                } else if type == "project_deep_dive" {
                    MockLine(text: "项目深挖只追问简历里的经历，其他领域先放一边")
                    ForEach(points.filter { $0.point.sector == MockMap.projectSector && $0.point.level < targetLevel }.prefix(2), id: \.point.id) { item in
                        MockLine(text: item.point.name + (item.point.level == 0 ? "还没被追问过，被问概率" + askWord(item.point.ask) : "只答到「\(MockMap.levelName(item.point.level))」"), tone: .or)
                    }
                } else if drag != nil {
                    MockLine(text: "拖一个点到第一颗珠子上，就先问它")
                    MockLine(text: "其余题仍由面试官按简历和记忆安排", size: 12)
                } else {
                    if completed.count == 1 { MockLine(text: "只练过一场，图上 \(points.filter { $0.point.level > 0 }.count) 个点落了位") }
                    if let gapLine { gapLine }
                    if !jobUnasked.isEmpty { MockLine(text: "岗位要求里的\(jobUnasked.prefix(2).map { "「\($0.point.name)」" }.joined())还没被问过", tone: .or) }
                    if let track = trackText { MockLine(text: track, tone: .blue) }
                    hint
                }
            }
        }
    }

    private var trackText: String? {
        guard let data else { return nil }
        let track = MockMap.trackLine(list: data.list, target: target, difficulty: difficulty)
        guard track.count >= 2, let last = track.last else { return nil }
        let verdict = last.text("verdict").nonEmptyValue.flatMap { MockMap.verdictName[$0] }.map { "，判定「\($0)」" } ?? ""
        let scores = track.suffix(3).map { "\(Int(($0["total_score"]?.numberValue ?? 0).rounded()))" }.joined(separator: " → ")
        return "\(target.kind == .general ? "通用练习" : MockMap.companyName(target)) · \(MockMap.diffName[difficulty] ?? "")练了\(track.count == 2 ? "两" : "\(track.count)")场：\(scores)\(verdict)"
    }

    private func pointPanel(_ item: MockMap.HomePoint) -> some View {
        let asks = Array((item.node?["asks"]?.items ?? []).reversed().prefix(2))
        let lastMock = (item.node?["asks"]?.items ?? []).reversed().first { $0.text("kind") == "mock" }
        let isFocus = focusID == item.point.id
        return MockPanel(label: item.source == "hook" ? "简历说法" : item.source == "job" ? "岗位要求" : "知识点", big: item.point.name, bigSub: "\(item.point.sector) · 被问概率 \(askWord(item.point.ask))") {
            DepthBars(level: item.point.level, target: targetLevel)
            if item.source == "job" { MockLine(text: "岗位要求有 · 还没被问过", tone: .or) }
            if item.source == "hook", let hook = item.hook { MockLine(text: hook["held"]?.text("statement") ?? "") }
            ForEach(Array(asks.enumerated()), id: \.offset) { _, ask in
                let depth = ask["depth"]?.numberValue
                let head = ask.text("kind") == "real" ? "\(ask.text("company"))\(ask.text("stage")) \(MockMap.mmddDot(ask.text("date")))（真实面试）" : "模拟 \(MockMap.mmddDot(ask.text("date"))) "
                MockLine(text: head + (depth.map { ask.text("kind") == "real" ? "只答到「\(MockMap.levelName($0))」" : "追问到「\(MockMap.levelName($0))」" } ?? "没有记下深度"))
            }
            if item.point.level == 0 && item.source == "atlas" { MockLine(text: "还没被问过") }
            if !item.followUps.isEmpty {
                MockLine(text: "接下来可能被追问", tone: .mute, size: 11)
                ForEach(item.followUps.prefix(2), id: \.self) { MockLine(text: "「\($0)」", tone: .ink) }
            }
            HStack(spacing: 12) {
                if item.focus != nil {
                    Button(isFocus ? "已设为先问 ✓" : "设为先问") { chooseFocus(isFocus ? Self.auto : item.point.id) }.buttonStyle(MockButtonStyle())
                        .accessibilityLabel(isFocus ? "取消先问" : "设为先问")
                } else {
                    Text("这一处由面试官安排").font(V3.sans(12)).foregroundStyle(MI.gry)
                }
                if let lastMock { Button("看 \(MockMap.mmddDot(lastMock.text("date"))) 那道题 ›") { openReport(lastMock.text("source_id")) }.buttonStyle(MockButtonStyle(kind: .link)) }
            }.frame(height: 36).padding(.top, 2)
        }
    }

    private func sessionPanel(_ detail: JSONValue) -> some View {
        let stats = MockMap.stats(detail)
        let report = detail["report"]
        let verdict = report?["verdict"]?.text("level").nonEmptyValue ?? detail.text("verdict").nonEmptyValue
        let score = detail["total_score"]?.numberValue
        return MockPanel(label: "一场练习", big: "\(MockMap.mmddDot(detail.text("finished_at").nonEmptyValue ?? detail.text("created_at")))  \(MockMap.typeName(detail))",
                         bigSub: "\(detail.text("company_name").nonEmptyValue ?? "通用练习") · \(MockMap.diffName[detail.text("difficulty")] ?? "")") {
            if detail.text("status") == "completed", let score {
                MockLine(text: "\(Int(score.rounded())) 分" + (verdict.flatMap { MockMap.verdictName[$0] }.map { " · \($0)" } ?? ""), tone: verdict == "meets" ? .blue : .or, size: 15, weight: .medium)
            } else {
                MockLine(text: detail.text("status") == "abandoned" ? "这场已放弃" : "还没有分数", tone: .gry, size: 15, weight: .medium)
            }
            if let headline = report?.text("headline").nonEmptyValue { MockLine(text: headline) }
            MockLine(text: "\(stats.rounds.count) 道主问题 · 追问 \(stats.follows) 次 · \(detail.text("answer_mode") == "voice" ? "语音" : "文字")\(stats.minutes.map { " \($0) 分钟" } ?? "")", tone: .mute, size: 12)
            HStack(spacing: 12) {
                if detail.text("status") == "completed" { Button("看评估报告 ›") { openReport(detail.text("id")) }.buttonStyle(MockButtonStyle()) }
                Button("用同样设置再练") { Task { await repeatSession(detail.text("id")) } }.buttonStyle(MockButtonStyle(kind: .link))
            }.frame(height: 36).padding(.top, 2)
        }
    }

    private func blockingPanel() -> AnyView? {
        if let active, let detail = sessionDetail, detail.text("id") == active.text("id") {
            let asked = MockMap.stats(detail).rounds.count
            let total = active["question_count"]?.integer ?? 0
            let current = (detail["current_question_id"] ?? .null) == .null ? 1 : 0
            return AnyView(MockPanel(label: "下一场", big: MockMap.companyName(target).nonEmptyValue ?? active.text("company_name").nonEmptyValue ?? "通用练习", bigSub: sessionSub()) {
                if !chain.isEmpty { MockChain(items: chain) }
                MockLine(text: "这场还没答完，继续后从第 \(min(total, asked + current)) 题开始", tone: .blue)
                MockLine(text: "已问的 \(asked) 题画在图上，× 是没答上的那层", size: 12)
            })
        }
        if let evaluating {
            let failed = evaluating.text("status") == "evaluation_failed"
            return AnyView(MockPanel(label: "刚练完", big: "\(MockMap.mmddDot(evaluating.text("created_at")))  \(MockMap.typeName(evaluating))",
                                     bigSub: "\(evaluating.text("company_name").nonEmptyValue ?? "通用练习") · \(MockMap.diffName[evaluating.text("difficulty")] ?? "") · \(evaluating.text("answer_mode") == "voice" ? "语音" : "文字")") {
                if failed {
                    MockLine(text: "评估报告没能生成", tone: .or, size: 13, weight: .medium)
                    MockLine(text: "作答记录都还在，重新评估不另扣积分")
                    HStack(spacing: 12) {
                        Button(busy == "retry" ? "正在评估…" : "重新评估") { Task { await retryEvaluation() } }.buttonStyle(MockButtonStyle(kind: .dark)).disabled(busy != nil)
                        Button("放弃这场") { Task { await abandon(evaluating.text("id")) } }.buttonStyle(MockButtonStyle(kind: .link)).disabled(busy != nil)
                    }.frame(height: 36).padding(.top, 2)
                } else {
                    MockLine(text: "报告生成中，约 1 分钟", tone: .or, size: 13, weight: .medium)
                    MockLine(text: "可以先离开，好了会提醒你")
                    MockLine(text: "图上是这场的提问路线，× 是在那一层没答上", size: 12)
                    HStack {
                        Button(remind ? "好了会提醒你 ✓" : "好了提醒我") { remind = true; remindID = evaluating.text("id") }.buttonStyle(MockButtonStyle()).disabled(remind)
                    }.frame(height: 36).padding(.top, 2)
                }
            })
        }
        return nil
    }

    // MARK: 右上角、开练条

    private var boardJobs: [JSONValue] { (data?.applications ?? []).filter { $0.text("status") == "active" && ($0["archived_at"] ?? .null) == .null } }

    @ViewBuilder private var topRight: some View {
        HStack(spacing: 18) {
            if data != nil && active == nil {
                Button(fresh ? "选岗位 ⌄" : target.kind == .general && !boardJobs.isEmpty ? "换回\(boardJobs[0].text("company_name_snapshot")) ⌄" : "换一场 ⌄") {
                    switchFromSettings = false; menu = menu == .switchJob ? nil : .switchJob
                }.buttonStyle(MockTopLink(color: MI.blue))
            }
            if !fresh { Button("全部练习记录 ›", action: showRecords).buttonStyle(MockTopLink(color: MI.sub)) }
            Button { menu = menu == .legend ? nil : .legend } label: {
                HStack(spacing: 4) { Text("图例"); Image(systemName: "info.circle").font(.system(size: 10.5)) }
            }.buttonStyle(MockTopLink(color: menu == .legend ? MI.ink : MI.mute)).accessibilityLabel("图例")
        }
    }

    @ViewBuilder private var composer: some View {
        if data == nil { EmptyView() }
        else if let active {
            HStack(spacing: 14) {
                Text(verbatim: "上次没答完 · \(active.text("company_name").nonEmptyValue ?? "通用练习") \(MockMap.typeName(active)) · 第 \(max(1, sessionDetail?["answered_main_questions"]?.integer ?? 1)) / \(active["question_count"]?.integer ?? 0) 题 · \(minutesAgo(active.text("started_at").nonEmptyValue ?? active.text("created_at")))")
                    .font(V3.serif(16)).foregroundStyle(MI.sub).frame(height: 16 * 1.45)
                Button("继续") { open(active.text("id")) }.buttonStyle(MockButtonStyle(kind: .dark, size: 14, go: true))
                Button("放弃") { Task { await abandon(active.text("id")) } }.buttonStyle(MockButtonStyle(kind: .link, size: 13)).foregroundStyle(MI.mute).disabled(busy != nil)
            }
        } else {
            HStack(spacing: 12) {
                Button { menu = menu == .settings ? nil : .settings } label: {
                    HStack(spacing: 6) { Image(systemName: "slider.horizontal.3").font(.system(size: 13)); Text("面试设置") }
                        .font(V3.sans(14, weight: .medium)).foregroundStyle(MI.ink).frame(minWidth: 72).frame(height: 40).padding(.horizontal, 20)
                        .background(menu == .settings ? Color(hex: 0xF4F3EF) : .white, in: Capsule())
                        .overlay(Capsule().stroke(menu == .settings ? Color(hex: 0xB9B5AA) : MI.line)).contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityLabel("面试设置")
                Button { Task { await start() } } label: {
                    HStack(spacing: 8) {
                        Text(submitting ? "正在准备…" : fresh ? "开始第一场" : "开始练习")
                        if !submitting { Image(systemName: "arrow.right").font(.system(size: 12.5, weight: .semibold)) }
                    }
                    .font(V3.sans(14, weight: .medium)).foregroundStyle(blockingID != nil ? MI.gry : .white).frame(minWidth: 72).frame(height: 40).padding(.horizontal, 20)
                    .background(blockingID != nil ? Color(hex: 0xE9E7E1) : MI.ink, in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain).disabled(submitting || blockingID != nil).accessibilityLabel(fresh ? "开始第一场" : "开始练习")
            }
        }
    }

    @ViewBuilder private var note: some View {
        let text: String? = data == nil ? "正在加载模拟面试…" : active != nil ? "同一时间只能进行一场 · 放弃后这场不生成报告"
            : evaluating.map { $0.text("status") == "evaluation_failed" ? "上一场评估完成或放弃后才能开始新的一场" : "上一场评估完成后才能开始新的一场" }
        if let text { Text(verbatim: text).font(V3.sans(10.5)).tracking(10.5 * 0.04).foregroundStyle(data == nil ? MI.gry : MI.mute).frame(height: 10.5 * 1.45) }
    }

    private func minutesAgo(_ value: String) -> String {
        guard let date = CareerApplication.date(value) else { return "" }
        let minutes = max(1, Int((now.timeIntervalSince(date) / 60).rounded()))
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = Int((Double(minutes) / 60).rounded())
        return hours < 24 ? "\(hours) 小时前" : "\(Int((Double(hours) / 24).rounded())) 天前"
    }

    // MARK: 菜单与弹窗

    @ViewBuilder private func overlays(_ points: [MockMap.HomePoint]) -> some View {
        switch menu {
        case .switchJob:
            MockFloatMenu(label: "换一场", items: switchItems(), width: 260)
                .offset(x: switchFromSettings ? Self.width / 2 - 130 : 858, y: switchFromSettings ? 0 : 54)
                .frame(height: switchFromSettings ? Self.height - 76 : nil, alignment: .bottom)
        case .settings:
            settingsPanel(points).frame(width: Self.width, height: Self.height - 76, alignment: .bottom)
        case .resume:
            MockFloatMenu(label: "选择简历", items: resumeItems(), width: 260).frame(width: Self.width, height: Self.height - 76, alignment: .bottom)
        case .legend:
            legend.frame(width: Self.width - 25, alignment: .trailing).offset(y: 52)
        case nil: EmptyView()
        }
        if dialog == .jobs, let data { jobPicker(data) }
        if dialog == .more { moreSettings }
    }

    private func resumeItems() -> [MockMenuItem] {
        let items = (data?.resumes ?? []).prefix(8).map { item in
            MockMenuItem(id: item.display("id"), title: item.text("title"), hint: "\(MockMap.mmddDot(item.text("updated_at"))) 更新", checked: resume == item.display("id")) {
                resume = item.display("id"); menu = nil
            }
        }
        return items.isEmpty ? [MockMenuItem(id: "none", title: "还没有简历", hint: "去「我的简历」导入或新建") { showResumes() }] : Array(items)
    }

    private func pickJob(_ id: String) { chosen = id; selected = nil; selectedSession = nil; focusTouched = false; menu = nil; dialog = nil; applyDefaults() }

    private func switchItems() -> [MockMenuItem] {
        var items = boardJobs.filter { ($0["job_description_id"] ?? .null) != .null }.prefix(3).map { item -> MockMenuItem in
            let id = item.display("id")
            let session = data?.sessions.first { $0.display("application_id") == id && (CareerApplication.date($0.text("end_at")) ?? .distantPast) >= now }
            let start = session.flatMap { CareerApplication.date($0.text("start_at")) }
            return MockMenuItem(
                id: id, title: "\(item.text("company_name_snapshot")) · \(session?.text("stage_label").nonEmptyValue ?? item.text("job_title_snapshot"))",
                hint: start.map { "\(MockMap.relativeDay($0, now: now)) \(MockMap.hhmm($0)) · \(item.text("job_title_snapshot"))" } ?? "\(item.text("current_stage_label")) · 还没有面试安排",
                checked: target.kind != .general && target.application?.display("id") == id) { pickJob(id) }
        }
        items.append(MockMenuItem(id: Self.general, title: "不挑岗位", hint: "只按简历出题", checked: target.kind == .general) { pickJob(Self.general) })
        items.append(MockMenuItem(id: "board", title: "从岗位看板选其他岗位 ›", hint: "看板里共 \(boardJobs.count) 个岗位，JD 跟着岗位走") { menu = nil; dialog = .jobs })
        return items
    }

    private func settingsPanel(_ points: [MockMap.HomePoint]) -> some View {
        let focusName = focusID == Self.auto ? nil : points.first { $0.point.id == focusID }?.point.name
        let selectedResume = data?.resumes.first { $0.display("id") == resume }
        let jdLabel = target.kind == .general ? "不带岗位 JD" : "带入 \(MockMap.companyName(target))" + (target.application?.text("job_title_snapshot").nonEmptyValue.map { " · \($0)" } ?? "")
        let price = { (code: String) in data?.prices.first { $0.text("featureCode") == code } }
        let credits = MockMap.credits(text: price("mock_interview"), voice: mode == "voice" ? price("mock_interview_voice") : nil, count: count)
        let meta = ["约 \(count * 5) 分钟", credits].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("面试设置").font(V3.sans(14, weight: .semibold)).foregroundStyle(MI.ink).frame(height: 22)
                Spacer()
                Button("恢复推荐") {
                    typeTouched = false; difficulty = "intermediate"; previewDiff = nil; mode = data?.speech == true ? "voice" : "text"; count = 8; focusTouched = false; applyDefaults()
                }.buttonStyle(.plain).font(V3.sans(12.5)).foregroundStyle(MI.mute)
            }
            settingRow("简历") { pickButton(selectedResume?.text("title") ?? "未选择") { menu = .resume } }
            settingRow("岗位 JD") { pickButton(jdLabel) { switchFromSettings = true; menu = .switchJob } }
            settingRow("类型") {
                MockSegment(label: "类型", options: Self.types.map { ($0, MockMap.typeNames[$0] ?? "", false) }, current: type) { type = $0; typeTouched = true; applyDefaults() }
            }
            settingRow("难度") {
                MockSegment(label: "难度", options: ["junior", "intermediate", "senior"].map { ($0, MockMap.diffName[$0] ?? "", false) }, current: difficulty,
                            pick: { difficulty = $0; previewDiff = nil; applyDefaults() }, preview: { previewDiff = $0 })
            }
            settingRow("作答") {
                MockSegment(label: "作答", options: [("text", "文字", false), ("voice", "语音", data?.speech != true)], current: mode) { mode = $0 }
            }
            settingRow("题数") { MockSegment(label: "题数", options: Self.counts.map { ($0, "\($0)", false) }, current: count) { count = $0 } }
            HStack(spacing: 0) {
                if let focusName {
                    Circle().fill(MI.orange).frame(width: 6, height: 6).padding(.trailing, 6)
                    Text(verbatim: "先问「\(focusName)」").foregroundStyle(MI.orange)
                } else { Text("让面试官决定先问哪一处").foregroundStyle(MI.mute) }
                Text(" · 点图上的知识点可以换").foregroundStyle(MI.mute)
            }
            .font(V3.sans(12)).frame(height: 18).padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xEEECE6)).frame(height: 1) }
            HStack {
                Text(verbatim: meta).font(V3.sans(11.5)).foregroundStyle(MI.mute)
                Spacer()
                Button("更多设置 ›") { menu = nil; dialog = .more }.buttonStyle(.plain).font(V3.sans(12, weight: .medium)).foregroundStyle(MI.ink)
            }
            .frame(height: 18).padding(.top, 12).overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xEEECE6)).frame(height: 1) }
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14).frame(width: 360)
        .background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0xE6E3DC)))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 8)
        .accessibilityElement(children: .contain).accessibilityLabel("面试设置")
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) { Text(label).font(V3.sans(13)).foregroundStyle(MI.sub); Spacer(minLength: 0); content() }
    }

    private func pickButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Text(verbatim: text).lineLimit(1).truncationMode(.tail); Image(systemName: "chevron.down").font(.system(size: 9.5, weight: .medium)) }
                .font(V3.sans(12)).foregroundStyle(MI.ink).padding(.leading, 12).padding(.trailing, 10).frame(height: 30).frame(maxWidth: 220)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(MI.line)).fixedSize()
        }.buttonStyle(.plain)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("图上的记号").font(V3.sans(13, weight: .medium)).frame(height: 22)
            ForEach(Array(legendRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 18) {
                    Canvas { context, _ in row.0(&context) }.frame(width: 18, height: 18)
                    Text(verbatim: row.1).font(V3.sans(12.5)).frame(height: 18)
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 18).frame(width: 280, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xE6E3DC)))
        .shadow(color: .black.opacity(0.1), radius: 15, y: 10)
        .accessibilityElement(children: .contain).accessibilityLabel("图上的记号")
    }

    private var legendRows: [((inout GraphicsContext) -> Void, String)] {
        func ring(_ c: inout GraphicsContext, _ color: Color) {
            c.stroke(Path(ellipseIn: CGRect(x: 1.5, y: 1.5, width: 15, height: 15)), with: .color(color.opacity(0.35)), lineWidth: 1)
            c.fill(Path(ellipseIn: CGRect(x: 4.3, y: 4.3, width: 9.4, height: 9.4)), with: .color(.white))
            c.stroke(Path(ellipseIn: CGRect(x: 4.3, y: 4.3, width: 9.4, height: 9.4)), with: .color(color), lineWidth: 1)
            c.fill(Path(ellipseIn: CGRect(x: 6.6, y: 6.6, width: 4.8, height: 4.8)), with: .color(color))
        }
        return [
            ({ ring(&$0, MI.blue) }, "到了目标线"),
            ({ ring(&$0, MI.orange) }, "还没到 · 橙色短线是还差几层"),
            ({ $0.fill(Path(ellipseIn: CGRect(x: 3.5, y: 3.5, width: 11, height: 11)), with: .color(.white)); $0.stroke(Path(ellipseIn: CGRect(x: 3.5, y: 3.5, width: 11, height: 11)), with: .color(MI.orange), style: StrokeStyle(lineWidth: 1.3, dash: [2, 2])) }, "还没被问过 · 橙色是岗位要求里有"),
            ({ $0.fill(Path(ellipseIn: CGRect(x: 2.5, y: 6.5, width: 5, height: 5)), with: .color(MI.gry)); $0.fill(Path(ellipseIn: CGRect(x: 8, y: 4, width: 10, height: 10)), with: .color(MI.gry)) }, "点越大，越可能被问"),
            ({ $0.fill(Path(ellipseIn: CGRect(x: 2, y: 2, width: 14, height: 14)), with: .color(MI.blue.opacity(0.05))); $0.stroke(Path(ellipseIn: CGRect(x: 2, y: 2, width: 14, height: 14)), with: .color(MI.blue), style: StrokeStyle(lineWidth: 1.4, dash: [3, 2])) }, "目标线 · 这一档难度要答进的那一圈"),
            ({ c in
                var a = Path(); a.move(to: CGPoint(x: 2, y: 14)); a.addLine(to: CGPoint(x: 12, y: 5)); c.stroke(a, with: .color(MI.blue), lineWidth: 2)
                var x = Path(); x.move(to: CGPoint(x: 12, y: 2)); x.addLine(to: CGPoint(x: 17, y: 7)); x.move(to: CGPoint(x: 17, y: 2)); x.addLine(to: CGPoint(x: 12, y: 7)); c.stroke(x, with: .color(MI.orange), lineWidth: 1.6)
            }, "一场练习的路线 · × 是那层没答上"),
            ({ c in var p = Path(); p.move(to: CGPoint(x: 1, y: 14)); p.addQuadCurve(to: CGPoint(x: 17, y: 14), control: CGPoint(x: 9, y: 6)); c.stroke(p, with: .color(MI.ink), lineWidth: 1.2) }, "地平线 · 练过的分数 → 今天 → 面试"),
        ]
    }

    @State private var jobQuery = ""
    @State private var picked: String?

    private func jobPicker(_ data: HomeData) -> some View {
        let query = jobQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = boardJobs.filter { query.isEmpty || "\($0.text("company_name_snapshot"))\($0.text("job_title_snapshot"))".lowercased().contains(query) }
        let current = picked ?? (target.kind == .general ? nil : target.application?.display("id"))
        return MockDialog(title: "从岗位看板选岗位", sub: "面试官按这个岗位的 JD 出题。没有的岗位请先加进岗位看板。", width: 464, close: { dialog = nil; picked = nil }) {
            HStack(spacing: 8) {
                Text("⌕").foregroundStyle(MI.gry)
                TextField("搜公司或岗位", text: $jobQuery).textFieldStyle(.plain).font(V3.sans(12.5)).foregroundStyle(MI.ink)
            }
            .padding(.horizontal, 12).frame(height: 38).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xE6E3DC))).padding(.top, 18)
            ScrollView {
                VStack(spacing: 0) {
                    if shown.isEmpty { Text("没有匹配的岗位").font(V3.sans(12.5)).foregroundStyle(MI.gry).padding(.vertical, 18) }
                    ForEach(shown, id: \.self) { item in
                        let id = item.display("id")
                        let usable = (item["job_description_id"] ?? .null) != .null
                        let session = data.sessions.first { $0.display("application_id") == id && (CareerApplication.date($0.text("end_at")) ?? .distantPast) >= now }
                        let start = session.flatMap { CareerApplication.date($0.text("start_at")) }
                        Button { if usable { picked = id } else { showOpportunities() } } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: "\(item.text("company_name_snapshot")) · \(item.text("job_title_snapshot"))").font(V3.sans(13.5, weight: .medium)).foregroundStyle(usable ? MI.ink : MI.gry)
                                    Text(verbatim: start.map { "\(session!.text("stage_label")) · \(MockMap.relativeDay($0, now: now)) \(MockMap.hhmm($0))" } ?? item.text("current_stage_label"))
                                        .font(V3.sans(11.5)).foregroundStyle(usable ? MI.mute : MI.gry)
                                }
                                Spacer()
                                Text(usable ? "JD 已上传" : "还没有 JD · 去补 ›").font(V3.sans(11.5)).foregroundStyle(usable ? MI.mute : MI.blue)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 53)
                            .background(current == id ? Color(hex: 0xF3F1EC) : .clear, in: RoundedRectangle(cornerRadius: current == id ? 8 : 0))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(current == id ? MI.ink : .clear))
                            .overlay(alignment: .bottom) { if current != id { Rectangle().fill(Color(hex: 0xF0EEE8)).frame(height: 1) } }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(current == id ? .isSelected : [])
                    }
                }
            }.frame(maxHeight: 300).padding(.top, 12)
        } footer: {
            Button("去岗位看板添加新岗位 ›", action: showOpportunities).buttonStyle(MockButtonStyle(kind: .link))
            Spacer()
            Button("取消") { dialog = nil; picked = nil }.buttonStyle(MockButtonStyle())
            Button("用这个岗位练") { if let current { pickJob(current); picked = nil } }.buttonStyle(MockButtonStyle(kind: .dark)).disabled(current == nil)
        }
        .frame(width: Self.width, height: Self.height)
    }

    @State private var moreDraft: (language: String, follow: Bool, materials: Bool)?

    private var moreSettings: some View {
        let docs = libraryDocs.count
        let draft = moreDraft ?? (language, followUp, useMaterials && docs > 0)
        return MockDialog(title: "更多设置", width: 464, close: { dialog = nil; moreDraft = nil }) {
            VStack(spacing: 0) {
                moreRow("面试语言", "面试官提问和报告使用的语言") {
                    MockSegment(label: "面试语言", options: [("zh", "中文", false), ("en", "英文", false)], current: draft.language) { moreDraft = ($0, draft.follow, draft.materials) }
                }
                moreRow("允许追问", "每道主问题最多追问 2 次，关掉就一题一答") {
                    MockSwitch(on: Binding(get: { draft.follow }, set: { moreDraft = (draft.language, $0, draft.materials) }), label: "允许追问")
                }
                moreRow("评分时参考资料库", docs > 0 ? "\(docs) 份文档 · 只用于评分，不参与出题" : "资料库里还没有可用的文档", link: true) {
                    MockSwitch(on: Binding(get: { draft.materials }, set: { moreDraft = (draft.language, draft.follow, $0) }), label: "评分时参考资料库").disabled(docs == 0).opacity(docs == 0 ? 0.5 : 1)
                }
            }
        } footer: {
            Button("取消") { dialog = nil; moreDraft = nil }.buttonStyle(MockButtonStyle())
            Button("保存") { language = draft.language; followUp = draft.follow; useMaterials = draft.materials; dialog = nil; moreDraft = nil }.buttonStyle(MockButtonStyle(kind: .dark))
        }
        .frame(width: Self.width, height: Self.height)
    }

    private func moreRow<Control: View>(_ title: String, _ hint: String, link: Bool = false, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(V3.sans(14, weight: .medium)).foregroundStyle(MI.ink)
                HStack(spacing: 4) {
                    Text(verbatim: hint).font(V3.sans(12)).foregroundStyle(MI.mute)
                    if link { Button("去资料库 ›", action: showLibrary).buttonStyle(.plain).font(V3.sans(12)).foregroundStyle(MI.blue) }
                }
            }
            Spacer()
            control()
        }.padding(.top, 22)
    }

    private var libraryDocs: [JSONValue] {
        (data?.datasets ?? []).filter { ($0.text("asset_kind").nonEmptyValue ?? "document") == "document" && $0.text("upload_status") == "succeeded" && $0.text("parse_status") == "succeeded" }
    }

    // MARK: 命令

    private func start() async {
        guard let data, !submitting, blockingID == nil else { return }
        guard !resume.isEmpty else { toast = ("还没有简历", "先导入或新建一份简历，面试官按简历出题。", true); return }
        submitting = true
        defer { submitting = false }
        let focusPoint = focusID == Self.auto ? nil : home.points.first { $0.point.id == focusID }
        var body: [String: JSONValue] = [
            "resume_id": .string(resume), "interview_type": .string(type), "difficulty": .string(difficulty), "question_count": .number(Double(count)),
            "follow_up_enabled": .bool(followUp), "language": .string(language), "answer_mode": .string(mode),
        ]
        if target.kind != .general, let id = target.application?.display("id") { body["job_application_id"] = .string(id) }
        if target.kind == .general, let role = data.targetRole { body["target_role"] = .string(role) }
        if useMaterials { body["material_ids"] = .array(libraryDocs.prefix(10).map { .string($0.display("id")) }) }
        if let practice = focusPoint?.focus {
            let origin = focus != nil && focus?.ref == practice.ref ? "outline" : "settings"
            body["practice_focus"] = .object(["kind": .string(practice.kind), "ref": .string(practice.ref), "label": .string(practice.label), "origin": .string(origin)])
        }
        var display: [String: JSONValue] = [:]
        if let title = data.resumes.first(where: { $0.display("id") == resume })?.text("title") { display["resume_title"] = .string(title) }
        if let app = target.application {
            display["company_name"] = .string(app.text("company_name_snapshot")); display["job_title"] = .string(app.text("job_title_snapshot"))
        }
        if let stage = target.session?.text("stage_label").nonEmptyValue ?? target.application?.text("current_stage_label").nonEmptyValue { display["stage_label"] = .string(stage) }
        if !display.isEmpty { body["display"] = .object(display) }
        do {
            let result = try await request("/api/mock-interviews", "POST", .object(body))
            open(result["mock_interview"]?.text("id") ?? "")
        } catch { toast = ("这场没有开始", MockInterviewText.error(error), true) }
    }

    private func retryEvaluation() async {
        guard let id = evaluating?.text("id") else { return }
        busy = "retry"; defer { busy = nil }
        do { _ = try await request("/api/mock-interviews/\(id)/retry", "POST"); tick += 1 }
        catch { toast = ("没有重新评估", MockInterviewText.error(error), true) }
    }

    private func abandon(_ id: String) async {
        busy = "abandon"; defer { busy = nil }
        do { _ = try await request("/api/mock-interviews/\(id)/abandon", "POST"); tick += 1 }
        catch { toast = ("没有放弃这场", MockInterviewText.error(error), true) }
    }

    private func repeatSession(_ id: String) async {
        do { let result = try await request("/api/mock-interviews/\(id)/repeat", "POST"); open(result["mock_interview"]?.text("id") ?? "") }
        catch { toast = ("没有开始新的一场", MockInterviewText.error(error), true) }
    }
}

/// `.mi2-top-link`。
struct MockTopLink: ButtonStyle {
    var color: Color
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(11.5)).foregroundStyle(hover ? (color == MI.blue ? Color(hex: 0x2F5CC0) : MI.ink) : color)
            .frame(height: 11.5 * 1.45).contentShape(Rectangle()).onHover { hover = $0 }
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
    ]
    static func error(_ error: Error) -> String {
        if case APIError.unauthorized = error { return messages["UNAUTHORIZED"]! }
        if case APIError.server(_, let code) = error, let message = messages[code] { return message }
        return "操作没有完成，请稍后重试。"
    }
}
