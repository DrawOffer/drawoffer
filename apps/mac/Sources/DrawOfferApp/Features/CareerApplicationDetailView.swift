import AppKit
import DrawOfferCore
import UniformTypeIdentifiers
import SwiftUI

struct CareerIcon: View {
    let name: String
    var size: CGFloat = 20
    var template = false
    var body: some View {
        if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Career"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).renderingMode(template ? .template : .original).resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

/// 投递详情（Figma 07 页 04–09 分区，Web `ProgressDeckPage`）：这一步 + 右侧随状态 + 全程时间线；
/// 面试记录、资料、阶段详情与复盘报告是下级页面。
struct CareerApplicationDetailView: View {
    let application: CareerApplication
    let api: any APIClient
    let back: () -> Void
    let perform: (String, CareerApplication) -> Void
    /// 从资料库「求职进程」进来时直接停在资料页，返回回到资料库。
    var libraryMaterials = false
    /// 资料库里的求职进程页：点开资料进资料预览页。
    var openDataset: ((String) -> Void)? = nil
    /// 一进来就打开资料页（铃铛里录音传完点「查看」，Web `careerMaterialsPath`）：场次 id，"" 为全部场次。
    var initialMaterials: String? = nil
    private enum Route: Equatable { case stage(String), report(String, fromStage: Bool), job(String), materials(String?), record(String, paste: Bool, fromMaterials: String?), written(String) }
    @State private var route: Route?
    /// 从投递详情选好的文件：带进资料页，直接进底部浮层（07.02）。
    @State private var materialFiles: [URL] = []
    @State private var writtenAdding: JSONValue?
    @State private var menuOpen = false
    @State private var current: JSONValue?
    @State private var sessions: [JSONValue] = []
    @State private var error: String?
    @State private var notice: String?
    @State private var loading = true
    @State private var busy = false
    @State private var jobDescription: String?
    @State private var showJob = false
    @State private var rescheduling: JSONValue?
    @State private var arranging = false
    @State private var refreshed = UUID()
    @State private var now = Date()
    @State private var viewKey: String?
    @State private var details: [String: JSONValue] = [:]
    @State private var confirmDelete = false
    @State private var delivering = false
    @State private var deciding = false
    @State private var reviewCost: String?
    /// 待投递、回看投递时画出来的那份简历（`GET /api/resumes/{id}` 的 `resume.data`）。
    @State private var resumeDoc: (id: String, doc: JSONValue)?
    @State private var match: JobMatch?
    /// 题目纸按考点列：后端整理好的考点，按场次存（`record-topics`）。
    @State private var topics: [String: [JSONValue]] = [:]
    @State private var topicRequests: Set<String> = []
    /// 台历上的考点（Web `useMemoryTopics`）：哪条投递读到的长期记忆里没答稳的几处；还没读完时为 nil。
    @State private var memoryTopics: (id: String, topics: [MemorySummary.Topic])?
    @State private var adding: JSONValue?
    @State private var addMode: CareerAddContentSheet.Mode = .upload
    @State private var splits: [String: SplitJob] = [:]
    /// 正往页面上拖文件：录音那一步点亮纸面，其余整页描一圈虚线。
    @State private var dragOver = false
    private struct SplitJob { var running: Bool; var error: String? }
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    private var raw: JSONValue { current ?? application.raw }
    /// 补充投递信息弹窗标题旁的阶段胶囊。
    private var deliveryStage: String { item.stageLabel }
    private var item: CareerApplication { CareerApplication(raw).includingSessions(sessions) }
    private var active: Bool { raw.text("lifecycle_status") != "terminated" && raw.text("status") == "active" && raw.text("archived_at").isEmpty }

    var body: some View {
        Group { page }
            .onAppear {
                if route == nil, let initialMaterials { route = .materials(initialMaterials.isEmpty ? nil : initialMaterials) }
            }
    }

    @ViewBuilder private var page: some View {
        switch route ?? (libraryMaterials ? .materials(nil) : nil) {
        case .stage(let id):
            CareerStageDetailView(sessionID: id, api: api, back: { route = nil; refreshed = UUID() }, openReport: { route = .report(id, fromStage: true) })
        case .report(let id, let fromStage):
            CareerReviewReportView(sessionID: id, api: api, back: { route = fromStage ? .stage(id) : nil; if !fromStage { refreshed = UUID() } })
        case .job(let id):
            JobDetailView(jobID: id, application: raw, back: { route = nil; refreshed = UUID() }, deleted: back)
        case .materials(let id):
            CareerMaterialsPage(application: raw, deck: CareerDeck(application: raw, sessions: sessions, now: now), details: details, initialSessionID: id, api: api,
                                back: { materialFiles = []; if libraryMaterials { back() } else { route = nil } },
                                addFromLibrary: { addMode = .library; adding = $0 },
                                openResume: { if !raw.text("resume_id").isEmpty { router?.jump(.editResume(raw.text("resume_id"))) } }, openJob: openJob,
                                changed: { refreshed = UUID() },
                                fromLibrary: libraryMaterials, openProgress: libraryMaterials ? { router?.jump(.application(application.id)) } : nil,
                                intentFiles: materialFiles, openAsset: libraryMaterials ? openDataset : nil,
                                processed: materialFiles.isEmpty || libraryMaterials ? nil : { message in materialFiles = []; route = nil; if let message { notice = message } })
                .task(id: refreshed) { await load() }
                .centeredSheet(item: Binding(get: { adding.map(CareerSessionRef.init) }, set: { if $0 == nil { adding = nil } })) { entry in
                    CareerAddContentSheet(session: entry.value, recordKind: entry.value.text("stage_type") == "written_test" || entry.value.text("stage_type") == "assessment" ? "笔试" : "面试",
                                          initialMode: addMode, api: api, close: { adding = nil }, saved: { adding = nil; refreshed = UUID() })
                }
        case .record(let id, let paste, let from):
            let deck = CareerDeck(application: raw, sessions: sessions, now: now)
            if let station = deck.stations.first(where: { $0.session?.text("id") == id }) {
                let session = details[id]?["session"] ?? station.session ?? .null
                CareerRecordPage(application: raw, station: station, session: session, mode: paste ? .paste : .record,
                                 splitting: splits[id]?.running == true, splitError: splits[id]?.error, backLabel: from == nil ? item.company + " · " + item.title : "资料",
                                 reviewLabel: reviewCost.map { "生成复盘 · \($0)" } ?? "生成复盘",
                                 back: { route = from.map { .materials($0) } },
                                 split: { text in startSplit(id, text); route = from.map { .materials($0) } },
                                 generateReview: { route = .stage(id) },
                                 repaste: { route = .record(id, paste: true, fromMaterials: from) },
                                 openMaterials: { route = .materials(id) })
                    .task(id: refreshed) { await load() }
            } else { progressPage }
        case .written(let id):
            let deck = CareerDeck(application: raw, sessions: sessions, now: now)
            if let station = deck.stations.first(where: { $0.session?.text("id") == id }), let detail = details[id] {
                CareerWrittenPage(application: raw, station: station, detail: detail, api: api, backLabel: item.company + " · " + item.title,
                                  back: { route = nil }, openMaterials: { route = .materials(id) }, changed: { refreshed = UUID() })
                    .task(id: refreshed) { await load() }
            } else { progressPage }
        case nil:
            progressPage
        }
    }

    /// 粘贴文字拆成问题（Web `recordSplit.ts`）：回到上一页后在后台跑，拆好直接存成这一站的面试记录。
    private func startSplit(_ id: String, _ text: String) {
        guard splits[id]?.running != true, !text.isEmpty else { return }
        splits[id] = SplitJob(running: true, error: nil)
        Task {
            do {
                let draft = try await api.careerRequest(path: "/api/interview-sessions/\(id)/record:structure", method: "POST", query: [:], body: .object(["source": .string("text"), "text": .string(text)]))
                let latest = try await api.careerRequest(path: "/api/interview-sessions/\(id)", method: "GET", query: [:], body: nil)
                let markdown = InterviewRecord.serialize(InterviewRecord.draft(draft))
                _ = try await api.careerRequest(path: "/api/interview-sessions/\(id)", method: "PUT", query: [:],
                                                body: .object(["questions_markdown": markdown.isEmpty ? .null : .string(markdown), "base_lock_version": latest["session"]?["lock_version"] ?? .number(1)]))
                splits[id] = nil
                refreshed = UUID()
            } catch {
                let code: String? = if case APIError.server(_, let code) = error { code } else { nil }
                splits[id] = SplitJob(running: false, error: code == "INTERVIEW_QUESTIONS_NOT_FOUND" ? "这段文字里没找到面试问题，可以补几句再拆。" : CareerErrors.message(error))
            }
        }
    }

    /// 投递详情（Figma 07N · 03–06）：返回栏，中间左边「现在该做什么」、右边这一步的那件东西，各自按外轮廓居中在同一条中线上，
    /// 正好在页头和时间线中间；底部全程时间线。点时间线上过去的节点回看那一轮（07N · 07），Esc 或时间线右上角「回到现在」回到现在。
    private var progressPage: some View {
        let deck = CareerDeck(application: raw, sessions: sessions, now: now)
        let current = deck.current ?? deck.stations[deck.stations.count - 1]
        let shown = viewKey.flatMap { key in deck.stations.first { $0.id == key } } ?? current
        let viewing = shown.id != current.id
        let shownIndex = deck.stations.firstIndex { $0.id == shown.id } ?? 0
        let previous = shownIndex > 0 ? deck.stations[shownIndex - 1] : nil
        let shownSession = shown.session.flatMap { $0.text("status") == "cancelled" ? nil : $0 }
        let shownDetail = shownSession.flatMap { details[$0.text("id")] }
        let upcoming = CareerJourney.memoryTopicsDue(deck: deck, station: shown, viewing: viewing, now: now)
        let step = CareerJourney.step(application: raw, deck: deck, station: shown, viewing: viewing, now: now, detail: shownDetail, previous: previous,
                                      reviewCost: reviewCost, match: needsMatch(deck, shown: shown, viewing: viewing) ? match : nil,
                                      memoryTopics: upcoming ? loadedMemoryTopics?.count ?? 0 : 0)
        let timeline = CareerJourney.timeline(application: raw, deck: deck, now: now)
        let advancing = step.primary?.action == .advance || step.secondary?.action == .advance
        return GeometryReader { geometry in
            // 稿：内容区 1179 宽时左边 64；更宽时内容最多 1200 居中
            let gutter = max(max(40, geometry.size.width * 0.054), (geometry.size.width - 1200) / 2)
            let width = max(0, geometry.size.width - gutter * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar(deck: deck, shown: shown, shownSession: shownSession)
                    if let error { HStack { Text(error).foregroundStyle(PD.red); Button("重试") { refreshed = UUID() }.buttonStyle(CareerActionStyle()) }.font(V3.sans(12)).padding(.top, 12) }
                    Spacer(minLength: 44)
                    let compact = width <= 1010
                    let hero = CareerJourneyHero(job: item.company + " · " + item.title, step: step, compact: compact, disabled: busy || loading,
                                                 act: { journeyAction($0, shown: shown, session: shownSession) })
                    let figure = figureView(step, deck: deck, shown: shown, session: shownSession, detail: shownDetail, upcoming: upcoming)
                        .environment(\.careerFigureStamp, step.stamp)
                        .scaleEffect(compact ? 0.8333 : 1, anchor: .topLeading)
                    Group {
                        if width > 840 {
                            HStack(alignment: .center, spacing: 32) {
                                hero.frame(maxWidth: 560, alignment: .leading)
                                Spacer(minLength: 0)
                                figureBox(figure, compact: compact).padding(.trailing, compact ? 0 : -9)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 40) { hero; figureBox(figure, compact: compact).padding(.leading, -56) }
                        }
                    }
                    .id(shown.id + (viewing ? ":view" : "")).transition(.opacity)
                    Spacer(minLength: 44)
                    CareerJourneyTimeline(timeline: timeline, picked: viewing ? shown.id : nil,
                                          pick: { key in withAnimation(.easeOut(duration: 0.2)) { viewKey = key == current.id ? nil : key } },
                                          onAdvance: CareerJourney.canAdvance(deck, viewing: viewing) && !advancing ? { if !busy { perform("advance", item) } } : nil,
                                          onBackToNow: viewing ? { journeyAction(.backToNow, shown: shown, session: shownSession) } : nil)
                }
                .frame(width: width, alignment: .leading)
                .frame(minHeight: max(0, geometry.size.height - 90), alignment: .top)
                .padding(.horizontal, gutter).padding(.top, 40).padding(.bottom, 50)
            }
            .overlay(alignment: .topTrailing) {
                // ⋯ 菜单：点外面或 Esc 收起
                if menuOpen {
                    ZStack(alignment: .topTrailing) {
                        Color.clear.contentShape(Rectangle()).onTapGesture { menuOpen = false }
                        CareerDetailMenu(items: menuItems(deck: deck, step: step, shown: shown, session: shownSession, detail: shownDetail), color: raw.text("calendar_color"),
                                         pickColor: { color in menuOpen = false; Task { await update(["calendar_color": .string(color)]) } },
                                         close: { menuOpen = false })
                            .padding(.top, 40 + 19 + 6).padding(.trailing, gutter - 4)
                    }
                }
            }
        }
        .foregroundStyle(PD.ink).font(V3.sans(13))
        .overlay {
            if dragOver && step.figure != .recordEmpty {
                RoundedRectangle(cornerRadius: 18).fill(PD.blue.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(PD.blue, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .padding(12).allowsHitTesting(false)
            }
        }
        // 资料放进正在看的那一轮，没有就放当前这一轮；一轮都没有时不接
        .onDrop(of: [.fileURL], delegate: CareerDetailDrop(enabled: (shownSession ?? deck.current?.session) != nil && !loading, over: $dragOver) { providers in
            let target = (shownSession ?? deck.current?.session)?.text("id")
            CareerDrop.batch(providers) { urls in
                let rule = CareerDropRule.accept(urls.map(\.lastPathComponent), figure: step.figure)
                if let message = rule.notice { notice = message }
                guard !rule.kept.isEmpty else { return }
                materialFiles = rule.kept.map { urls[$0] }
                route = .materials(target)
            }
        })
        .overlay(alignment: .top) { TextNoticeToast(text: $notice, kind: { $0.contains("，但") ? .partial : $0.hasPrefix("已") ? .done : $0.contains("还没有") || $0 == CareerDropRule.recordingOnlyNotice ? .info : .failed }) }
        .task(id: refreshed) { await load() }
        .task { await loadPrices() }
        .task(id: matchKey) { await loadMatch() }
        .task(id: topicKey) { await loadTopics() }
        .task(id: memoryTopicKey) { await loadMemoryTopics() }
        .task(id: waiting) {
            // 复盘或转写在后台跑：5 秒起逐步放慢到 30 秒查一次，只查在跑的那几场；有一场落定才整页刷新。App 不在前台时暂停
            var attempt = 0
            while waiting && !Task.isCancelled {
                guard await Polling.wait(attempt, first: 5, cap: 30, topic: "interview_session") else { return }
                attempt += 1
                if waiting { await checkWaiting() }
            }
        }
        .onExitCommand { if menuOpen { menuOpen = false } else if viewKey != nil { viewKey = nil } }
        .centeredSheet(isPresented: $showJob) {
            CareerSheet(title: "岗位详情", subtitle: item.company + " · " + item.title, width: 720) {
                Text(jobDescription ?? "原岗位资料已不可用。").font(LibraryTypography.sans(13)).foregroundStyle(CareerPalette.sub).textSelection(.enabled)
            } footer: { Button("关闭") { showJob = false }.buttonStyle(CareerActionStyle(kind: .primary, large: true)) }
            .frame(height: 600)
        }
        .centeredSheet(item: Binding(get: { rescheduling.map(CareerSessionRef.init) }, set: { if $0 == nil { rescheduling = nil } })) { entry in
            CareerScheduleSheet(target: .edit(entry.value), application: raw, api: api, close: { rescheduling = nil },
                                saved: { message in rescheduling = nil; refreshed = UUID(); if let message { notice = message } })
        }
        .centeredSheet(isPresented: $arranging) {
            CareerScheduleSheet(target: .arrange(raw), api: api, close: { arranging = false },
                                saved: { message in arranging = false; refreshed = UUID(); if let message { notice = message } })
        }
        .centeredSheet(item: Binding(get: { adding.map(CareerSessionRef.init) }, set: { if $0 == nil { adding = nil } })) { entry in
            CareerAddContentSheet(session: entry.value, recordKind: ["written_test", "assessment"].contains(entry.value.text("stage_type")) ? "笔试" : "面试",
                                  initialMode: addMode, api: api, close: { adding = nil }, saved: { adding = nil; refreshed = UUID() })
        }
        .centeredSheet(item: Binding(get: { writtenAdding.map(CareerSessionRef.init) }, set: { if $0 == nil { writtenAdding = nil } })) { entry in
            CareerWrittenAddSheet(detail: details[entry.id] ?? .object(["session": entry.value]), api: api, close: { writtenAdding = nil },
                                  saved: { count in writtenAdding = nil; notice = "已导入 \(count) 道题。"; refreshed = UUID() })
        }
        .centeredSheet(isPresented: $deciding) { decideSheet }
        .centeredSheet(isPresented: $delivering) {
            CareerDeliverySheet(application: raw, stageLabel: deliveryStage, api: api, close: { delivering = false },
                                saved: { delivering = false; refreshed = UUID(); notice = "已保存投递信息。" })
        }
        .centeredConfirmation("删除这条投递？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { perform("delete", item) }
            Button("取消", role: .cancel) {}
        } message: { Text(deleteImpact(deck)) }
    }

    /// 删除确认（Web `ImpactConfirmDialog`）：写清会删除什么、会保留什么。
    private func deleteImpact(_ deck: CareerDeck) -> String {
        let reviews = sessions.filter { CareerDeck.hasReview($0) }.count
        let files = details.values.reduce(0) { $0 + ($1["assets"]?.items.count ?? 0) }
        let removed = ["\(deck.stations.count) 站记录", "面试记录", "笔试题", reviews > 0 ? "\(reviews) 篇复盘" : nil].compactMap { $0 }.joined(separator: "、")
        let kept = files > 0 ? "资料库里的 \(files) 份文件（只是不再关联这条投递）" : "资料库里的文件"
        return "删除后无法恢复。岗位也会从岗位看板上移除。\n会删除：\(removed)\n会保留：\(kept)"
    }

    /// 从电脑选资料：选好后进资料页底部浮层，逐个选放进哪一轮、怎么处理。录音入口只收录音和视频，
    /// 文字稿走「粘贴文字」，PDF、Word 从 ⋯ 的「资料」上传。
    private func pickFiles(into sessionID: String?, recording: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = (recording ? CareerPendingFile.media : CareerPendingFile.media + CareerPendingFile.documents).compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.message = recording ? CareerDropRule.recordingOnlyNotice : ""
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        materialFiles = panel.urls
        route = .materials(sessionID)
    }

    /// ⋯ 菜单（Web `ProgressDeckPage` 页面菜单）：看的是某一轮时改这一轮的时间、方式和链接，投递、筛选这类没有场次的阶段改投递信息；
    /// 这一步不常用的几项、资料、日历颜色，最后是删除（结束或归档后才能点）。
    private func menuItems(deck: CareerDeck, step: CareerJourneyStep, shown: CareerStation, session: JSONValue?, detail: JSONValue?) -> [CareerDetailMenu.Item] {
        let ended = deck.ended != nil || !raw.text("archived_at").isEmpty
        let currentKind = deck.current?.kind
        let offerMenu = currentKind == .offer || currentKind == .oc || deck.ended?.kind == .accepted || deck.ended?.kind == .declined
        var items: [CareerDetailMenu.Item] = []
        if let session {
            let name = session.text("stage_label").trimmingCharacters(in: .whitespaces).nonEmptyOr(shown.title)
            items.append(.init(title: "编辑\(name)信息") { rescheduling = session })
        } else {
            items.append(.init(title: "编辑投递信息") { delivering = true })
        }
        if offerMenu { items.append(.init(title: "编辑 Offer 信息") { perform("offer", item) }) }
        for more in step.more { items.append(.init(title: more.label) { journeyAction(more.action, shown: shown, session: session) }) }
        let files = session == nil ? details.values.reduce(0) { $0 + ($1["assets"]?.items.count ?? 0) } : detail?["assets"]?.items.count ?? 0
        items.append(.init(title: "资料", trailing: files > 0 ? String(files) : nil) { route = .materials(session?.text("id")) })
        items.append(.init(title: raw["is_favorite"]?.bool == true ? "取消收藏" : "收藏") { Task { await toggleFavorite() } })
        items.append(.init(title: "日历颜色", colors: true) {})
        items.append(.init(title: raw.text("archived_at").isEmpty ? "归档" : "取消归档") { perform(raw.text("archived_at").isEmpty ? "archive" : "restore", item) })
        items.append(.init(title: "删除这条投递", danger: true, enabled: ended) { confirmDelete = true })
        return items
    }

    /// 顶部：左上统一返回，右上「岗位详情」文字按钮 + ⋯ 菜单（09.07 / 09.08）。
    private func topBar(deck: CareerDeck, shown: CareerStation, shownSession: JSONValue?) -> some View {
        HStack(spacing: 16) {
            CareerJourneyTextButton(title: "← 投递看板", color: Color(hex: 0x6C6C65), action: back).accessibilityLabel("返回投递看板")
            Spacer()
            HStack(spacing: 14) {
                CareerJourneyTextButton(title: "岗位详情") { openJob() }
                Button { menuOpen.toggle() } label: {
                    Text("⋯").font(.system(size: 16, weight: .medium)).foregroundStyle(menuOpen ? PD.ink : PD.body)
                        .frame(width: 28, height: 28).background(Circle().fill(menuOpen ? Color(hex: 0xEDEDEA) : .clear)).contentShape(Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("这条投递的操作")
            }
        }.frame(height: 19)
    }

    /// 物件按 1 倍画；放不下时缩到 0.8333，外框跟着缩，免得撑开两栏。
    private func figureBox(_ figure: some View, compact: Bool) -> some View {
        figure.frame(width: compact ? 400 : 480, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
    }

    /// 右侧这一步的那件东西（Web `ProgressDeckPage` figure）。
    @ViewBuilder private func figureView(_ step: CareerJourneyStep, deck: CareerDeck, shown: CareerStation, session: JSONValue?, detail: JSONValue?, upcoming: Bool) -> some View {
        let act = { (action: CareerJourneyAction) in journeyAction(action, shown: shown, session: session) }
        let start = session.flatMap { CareerApplication.date($0.text("start_at")) }
        switch step.figure {
        case .resume:
            let doc = resumeDoc.flatMap { $0.id == resumeID ? $0.doc : nil }
            ResumeFigure(sketch: CareerJourney.resumeSketch(doc), matched: Array((match?.covered ?? []).prefix(4)), label: deck.pending ? "准备投的简历" : "投的这份简历",
                         onOpen: { act(resumeID != nil ? .openResume : .pickResume) })
        case .resumeBlank:
            BlankResumeFigure(label: "还没记投的是哪份简历", onPick: { act(.pickResume) })
        case .sent:
            SentFigure(date: CareerDeckFormat.monthDay(CareerApplication.date(raw.text("applied_at")) ?? shown.start), channel: CareerDeck.source(raw))
        case .askDay:
            AskDayFigure(month: Beijing.calendar.component(.month, from: now), onPick: { act(.schedule) })
        case .writtenDue:
            if let session, let start, let end = CareerApplication.date(session.text("end_at")) {
                let open = session.text("schedule_kind") == "open_window"
                let plan = CareerApplication.date(session.text("answer_plan_start_at"))
                let day = open ? end : start
                let minutes = open ? 0 : Int((end.timeIntervalSince(start) / 60).rounded())
                let note = open
                    ? plan.map { "打算 \(CareerDeckFormat.monthDay($0)) \(CareerDeckFormat.clock($0)) 做" } ?? "\(CareerDeckFormat.monthDay(start)) \(CareerDeckFormat.clock(start)) 起开放"
                    : [minutes > 0 ? "\(minutes) 分钟" : nil, session.text("mode") == "onsite" ? "现场" : "线上"].compactMap { $0 }.joined(separator: " · ")
                WrittenDueFigure(title: open ? "\(shown.short)截止" : shown.short, date: CareerDeckFormat.monthDay(day),
                                 time: "\(CareerDeckFormat.weekday(day)) \(CareerDeckFormat.clock(day))", note: note, mine: open && plan != nil)
            }
        case .writtenList:
            let questions = detail?["session"]?["written_questions"]?.items ?? session?["written_questions"]?.items ?? []
            WrittenListFigure(title: "\(shown.short)题", items: questions.enumerated().map { index, item in
                let state = item.text("correctness")
                return SFPaperItem(id: item.display("id").nonEmptyOr(String(index)), title: item.text("question_text"), mark: state == "correct" ? .good : state == "wrong" ? .weak : .open)
            }, onOpen: { act(.openWritten) }, onAdd: { act(.addWritten) })
        case .day:
            if let start {
                // 约好还没面时日期右边列没答稳的考点；还在读时先不写字（Web `topics={upcoming ? topics : []}`）
                DayFigure(day: start, time: CareerDeckFormat.clock(start), ribbon: true,
                          topics: upcoming ? loadedMemoryTopics.map { $0.map { (ref: $0.ref, label: $0.label) } } : [],
                          onPractice: { ref, label in practiceTopic(ref: ref, label: label) })
            }
        case .dayPast:
            DayFigure(day: CareerJourney.stationDay(shown), time: nil, ribbon: false)
        case .clock:
            if let start { ClockFigure(now: now, start: start) }
        case .recordEmpty:
            RecordFigure(state: .empty, over: dragOver, onUpload: { act(.upload) })
        case .recordRunning:
            RecordFigure(state: .running)
        case .recordFailed:
            RecordFigure(state: .failed)
        case .questions, .reviewFailed:
            let paper = paper(session, detail)
            QuestionsFigure(title: shown.short, count: "\(paper.total) 题", items: paper.rows.map { row in
                SFPaperItem(id: row.id, title: row.title, mark: .open, open: { act(.openRecord) })
            }, tone: step.figure == .questions ? .blue : .orange)
        case .questionsPast:
            let paper = paper(session, detail)
            PastQuestionsFigure(title: shown.short, count: "\(CareerDeckFormat.monthDay(CareerJourney.stationDay(shown))) · \(paper.total) 题",
                                items: paper.rows.map { row in (row.id, row.title, row.answer, { act(.openRecord) }) }, onMore: { act(.openRecord) })
        case .reviewing:
            let rows = CareerJourney.progressQuestions(session)
            let paper = paper(session, detail)
            QuestionsFigure(title: shown.short, count: rows.isEmpty ? "\(paper.total) 题" : "\(rows.filter { $0.mark != .waiting }.count) / \(rows.count) 题",
                            items: rows.isEmpty ? paper.rows.map { SFPaperItem(id: $0.id, title: $0.title, mark: .waiting) } : rows.map { SFPaperItem(id: $0.id, title: $0.title, mark: $0.mark) },
                            tone: .ink)
        case .review:
            if let session {
                let questions = CareerJourney.reviewedQuestions(session)
                if questions.isEmpty {
                    ReviewTextFigure(title: "\(shown.short)复盘", text: CareerJourney.reviewHeadline(session).title, onOpen: { openReview(session) })
                } else {
                    let weak = questions.filter(\.weak)
                    ReviewFigure(reached: questions.count - weak.count, total: questions.count,
                                 weak: weak.map { ($0.id, $0.title, $0.line) }, good: questions.map { ($0.id, $0.title) },
                                 onPractice: { id in practiceQuestions(weak.filter { $0.id == id }) }, onMore: { openReview(session) })
                }
            }
        case .wait:
            WaitFigure(days: CareerDeckFormat.dayCount(shown.start, now), label: "等结果")
        case .oral:
            let told = CareerApplication.date(raw.text("oc_communicated_at"))
            let rows: [(label: String, value: String)] = [raw.text("oc_start_text").nonEmptyValue.map { ("入职", $0) }, raw.text("oc_contact").nonEmptyValue.map { ("联系人", $0) },
                                                          told.map { ("时间", CareerDeckFormat.monthDay($0)) }].compactMap { $0 }
            OralOfferFigure(salary: raw.text("oc_salary_text").nonEmptyValue, rows: rows)
        case .offerBlank:
            OfferBlankFigure(onFill: { act(.editOffer) })
        case .offer:
            OfferFigure(offer: CareerJourney.offerText(raw))
        case .offerAccepted:
            OfferAcceptedFigure(offer: CareerJourney.offerText(raw))
        case .offerDeclined:
            OfferDeclinedFigure()
        case .archive, .archiveOpen:
            ArchiveFigure(open: step.figure == .archiveOpen, label: CareerJourney.roundLabel(deck))
        }
    }

    private var resumeID: String? { raw.text("resume_id").nonEmptyValue ?? raw.display("resume_id").nonEmptyValue }

    /// 题目纸：记录里的题按考点列，考点还没整理好时按题列。
    private func paper(_ session: JSONValue?, _ detail: JSONValue?) -> (total: Int, rows: [CareerJourney.PaperRow]) {
        guard let session else { return (0, []) }
        let questions = InterviewRecord.parse(CareerJourney.markdown(session, detail))
        let groups = (detail?["session"]?["record_topics"] ?? session["record_topics"]).flatMap { $0 == .null ? nil : $0.items } ?? topics[session.text("id")]
        return (questions.count, CareerJourney.paperRows(questions, groups: groups))
    }

    private var shownState: (deck: CareerDeck, shown: CareerStation, viewing: Bool) {
        let deck = CareerDeck(application: raw, sessions: sessions, now: now)
        let current = deck.current ?? deck.stations[deck.stations.count - 1]
        let shown = viewKey.flatMap { key in deck.stations.first { $0.id == key } } ?? current
        return (deck, shown, shown.id != current.id)
    }

    /// 待投递、筛选要看这份简历和岗位对得上多少；待投递（和回看投递）还要把简历画出来。
    private func needsMatch(_ deck: CareerDeck, shown: CareerStation, viewing: Bool) -> Bool {
        (deck.ended == nil || viewing) && (shown.kind == .apply || shown.kind == .screening)
    }

    private var matchKey: String {
        let state = shownState
        guard needsMatch(state.deck, shown: state.shown, viewing: state.viewing), let resumeID else { return "" }
        // 与 Web ProgressDeckPage needsDoc 一致：只在投递这一步取简历正文，筛选沿用已取到的那份，没有就画空白简历
        let doc = state.shown.kind == .apply
        return [raw.text("job_description_id"), resumeID, doc ? "doc" : ""].joined(separator: ":")
    }

    private func loadMatch() async {
        let parts = matchKey.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return }
        let (job, resume) = (parts[0], parts[1])
        if parts[2] == "doc", resumeDoc?.id != resume,
           let result = try? await api.careerRequest(path: "/api/resumes/\(resume)", method: "GET", query: [:], body: nil), let doc = result["resume"]?["data"] {
            resumeDoc = (resume, doc)
        }
        guard !job.isEmpty, !Task.isCancelled else { return }
        let result = try? await api.careerRequest(path: "/api/job-descriptions/\(job)/match", method: "GET", query: ["resume_id": resume], body: nil)
        match = JobMatch(result?["match"])
    }

    /// 有记录还没复盘（或复盘失败）的这一轮，题目纸按考点列：后端没存考点时请求整理一次。
    private var topicKey: String {
        let state = shownState
        guard state.shown.kind == .interview, let session = state.shown.session, session.text("status") != "cancelled" else { return "" }
        let detail = details[session.text("id")]
        let status = session.text("review_status")
        guard status != "generating", status == "failed" || !CareerDeck.hasReview(session) else { return "" }
        let stored = detail?["session"]?["record_topics"] ?? session["record_topics"]
        guard stored == nil || stored == .null, topics[session.text("id")] == nil else { return "" }
        let markdown = CareerJourney.markdown(session, detail)
        return markdown.isEmpty ? "" : session.text("id") + "\n" + markdown
    }

    private func loadTopics() async {
        let key = topicKey
        guard !key.isEmpty, !topicRequests.contains(key), let id = key.split(separator: "\n").first.map(String.init) else { return }
        let questions = CareerJourney.topicQuestions(InterviewRecord.parse(String(key.dropFirst(id.count + 1))))
        guard !questions.isEmpty else { return }
        topicRequests.insert(key)
        guard let result = try? await api.careerRequest(path: "/api/interview-sessions/\(id)/record-topics", method: "POST", query: [:],
                                                        body: .object(["questions": .array(questions.map(JSONValue.string))])),
              let groups = result["session"]?["record_topics"]?.items else { return }
        topics[id] = groups
    }

    /// 读台历考点的键：约好还没面时是这条投递，否则不读（空）。
    private var memoryTopicKey: String {
        let state = shownState
        return CareerJourney.memoryTopicsDue(deck: state.deck, station: state.shown, viewing: state.viewing, now: now) ? application.id : ""
    }

    /// 读到的是这条投递的才用；读取中为 nil。
    private var loadedMemoryTopics: [MemorySummary.Topic]? { memoryTopics?.id == application.id ? memoryTopics?.topics : nil }

    /// 台历上的考点（Web `useMemoryTopics`）：面试前才读，3 秒读不到、出错或没有都当没有；
    /// 及时读到且列出来了，就把这几处登记为已告知（`prep`）。
    private func loadMemoryTopics() async {
        let id = memoryTopicKey
        guard !id.isEmpty else { return }
        let api = api
        let found: [MemorySummary.Topic]? = await withTaskGroup(of: [MemorySummary.Topic]?.self) { group in
            group.addTask {
                guard let json = try? await api.careerRequest(path: "/api/memory/summary", method: "GET",
                                                              query: ["application_id": id, "limit": String(MemorySummary.topicFetchLimit)], body: nil) else { return [] }
                return MemorySummary(json: json).topics
            }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return nil }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
        guard !Task.isCancelled else { return }
        let topics = found ?? []
        memoryTopics = (id, topics)
        guard found != nil, !topics.isEmpty else { return }
        _ = try? await api.careerRequest(path: "/api/memory/disclosures", method: "POST", query: [:],
                                         body: .object(["page": .string("prep"), "issues": .array(MemorySummary.disclosed(topics).map(JSONValue.string))]))
    }

    /// 点台历上的一处考点：带着这条投递单练这一处（Web `practiceTopic` → `newMockInterviewPath({ applicationId, focus })`）。
    private func practiceTopic(ref: String, label: String) {
        router?.jump(.mock(PracticeFocus(kind: "topic", ref: ref, label: label, applicationID: application.id)))
    }

    /// 09.03 做决定：460 宽，只写这份 Offer、答复截止、接受后会怎样。
    private var decideSheet: some View {
        let due = CareerJourney.offerDate(raw.text("offer_reply_due_on"))
        return VStack(alignment: .leading, spacing: 0) {
            Text("处理「\(item.company)」的 Offer").font(V3.serif(20)).foregroundStyle(PD.ink)
            Text([CareerJourney.offerSalary(raw).map { "这份 Offer：\($0)" }, due.map { "答复截止 \(CareerDeckFormat.monthDay($0))" }].compactMap { $0 }.joined(separator: " · "))
                .font(V3.sans(13)).foregroundStyle(PD.body).padding(.top, 10)
            Text("接受或婉拒后，这条投递会结束；各站记录、资料和复盘都会保留。").font(V3.sans(13)).foregroundStyle(PD.body).lineHeight(13, 21)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            HStack(spacing: 10) {
                Spacer()
                Button("再想想") { deciding = false }.buttonStyle(PDButtonStyle()).disabled(busy)
                Button("婉拒") { Task { await decide("declined") } }.buttonStyle(PDButtonStyle()).disabled(busy)
                Button("接受 Offer") { Task { await decide("accepted") } }.buttonStyle(PDButtonStyle(kind: .primary)).disabled(busy).keyboardShortcut(.defaultAction)
            }.padding(.top, 24)
        }
        .padding(24).frame(width: 460)
    }

    private func journeyAction(_ action: CareerJourneyAction, shown: CareerStation, session: JSONValue?) {
        let deck = CareerDeck(application: raw, sessions: sessions, now: now)
        // 资料放进哪一轮：正在看的那一轮，没有就放当前这一轮
        let target = session?.text("id") ?? deck.current?.session?.text("id")
        switch action {
        case .recordApplied: perform("apply", item)
        case .advance: perform("advance", item)
        case .schedule: arranging = true
        case .reschedule: rescheduling = session ?? CareerDetailModel(application: raw, sessions: sessions, now: now).currentSession
        case .recordOffer: perform("advance-offer", item)
        case .editOffer: perform("offer", item)
        case .decide: deciding = true
        case .reopen: Task { await reopen() }
        case .backToNow: withAnimation(.easeOut(duration: 0.2)) { viewKey = nil }
        case .openSource:
            if let url = URL(string: raw["job_snapshot"]?.text("source_url") ?? ""), ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        case .enter:
            if let url = URL(string: session?.text("meeting_url") ?? ""), url.scheme != nil { NSWorkspace.shared.open(url) }
        case .openPlace:
            if let url = session.flatMap(CareerJourney.placeOf)?.url { NSWorkspace.shared.open(url) }
        case .copyPlace:
            if let place = session.flatMap(CareerJourney.placeOf) { copy(place.label) }
        case .mock: router?.jump(.mockFor(application: application.id))
        case .practiceWeak: practiceQuestions(CareerJourney.weakQuestions(session))
        case .upload: pickFiles(into: target, recording: true)
        case .addWritten: pickFiles(into: target, recording: false)
        case .paste: if let id = session?.text("id") { route = .record(id, paste: true, fromMaterials: nil) }
        case .pickLibrary:
            if let target = session ?? deck.current?.session { addMode = .library; adding = target }
        case .retryTranscription:
            if let session, case .failed(_, let datasetID) = CareerJourney.recordState(session, details[session.text("id")]) {
                Task { await retryTranscription(session, datasetID) }
            }
        case .pickResume: delivering = true
        case .openResume: if let resumeID { router?.jump(.editResume(resumeID)) }
        case .generateReview: if let id = session?.text("id") { route = .stage(id) }
        case .openReview: openReview(session)
        case .openRecord: if let id = session?.text("id") { route = .record(id, paste: false, fromMaterials: nil) }
        case .openWritten: if let id = session?.text("id") { route = .written(id) }
        }
    }

    /// 练没答到位的题（Web `startPractice`）：最多 3 题，每题追问到讲清为止，带着这条投递进面试设置。
    private func practiceQuestions(_ questions: [CareerJourney.ReviewedQuestion]) {
        guard !questions.isEmpty else { return }
        let items = questions.prefix(CareerJourney.practiceLimit).map { question in
            let gaps = question.gaps
            let reached = question.level.map { $0 <= 0 ? "没到「了解」" : "答到「\(MockRV.levelLabel($0))」" } ?? "没记下回答"
            return MockPracticeItem(label: String(question.title.prefix(120)), question: String(question.ask.prefix(500)),
                                    signals: gaps.prefix(5).map { String($0.prefix(300)) }, note: question.line, tag: nil,
                                    last: [reached, question.line].compactMap { $0 }.joined(separator: "，"),
                                    goal: ["答到「\(MockRV.levelLabel(question.expected))」", gaps.isEmpty ? nil : "把\(gaps.prefix(2).joined(separator: "和"))讲清楚"].compactMap { $0 }.joined(separator: "，"))
        }
        router?.jump(.mockPractice(MockPracticePlan(back: item.company + " · " + item.title, items: Array(items), applicationID: application.id)))
    }

    /// 打开复盘：优先看的这一轮，否则最近一份复盘。
    private func openReview(_ session: JSONValue?) {
        let deck = CareerDeck(application: raw, sessions: sessions, now: now)
        let target = session.flatMap { CareerDeck.hasReview($0) ? $0 : nil } ?? deck.stations.reversed().compactMap(\.session).first { CareerDeck.hasReview($0) }
        if let id = target?.text("id"), !id.isEmpty { route = .report(id, fromStage: false) } else { notice = "这次求职还没有可查看的复盘记录。" }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); notice = "已复制"
    }

    /// 复盘生成中或录音转写中。
    private var waiting: Bool {
        sessions.contains { $0.text("review_status") == "generating" }
            || details.values.contains(where: Self.transcribing)
    }

    private static func transcribing(_ detail: JSONValue) -> Bool {
        (detail["session"]?["transcriptions"]?.items ?? []).contains { ["queued", "running"].contains($0.text("status")) }
    }

    /// 只读在跑的场次详情；有一场复盘或转写落定时作废读缓存并整页刷新，否则原地更新这几场。
    private func checkWaiting() async {
        let ids = Set(sessions.filter { $0.text("review_status") == "generating" }.map { $0.text("id") }
                      + details.filter { Self.transcribing($0.value) }.map(\.key))
        for id in ids.sorted() {
            guard let fresh = try? await api.careerRequest(path: "/api/interview-sessions/\(id)", method: "GET", query: [:], body: nil),
                  !Task.isCancelled else { continue }
            if fresh["session"]?.text("review_status") != "generating" && !Self.transcribing(fresh) {
                await api.purgeCache(); refreshed = UUID(); return
            }
            details[id] = fresh
        }
    }

    private func loadPrices() async {
        guard reviewCost == nil, let result = try? await api.careerRequest(path: "/api/billing/feature-prices", method: "GET", query: [:], body: nil) else { return }
        let items = result["items"]?.items ?? []
        func fixed(_ code: String) -> String? {
            let price = items.first { $0.text("featureCode") == code }
            guard price?.text("priceMode") == "fixed", let points = price?["unitPoints"]?.stringValue.flatMap(Double.init) ?? price?["unitPoints"]?.numberValue else { return nil }
            return points == points.rounded() ? String(Int(points)) : String(points)
        }
        reviewCost = fixed("interview_review").map { "\($0) 积分" }
    }

    private func retryTranscription(_ session: JSONValue, _ datasetID: String) async {
        busy = true; defer { busy = false }
        do {
            _ = try await api.careerRequest(path: "/api/interview-sessions/\(session.text("id"))/transcriptions/\(datasetID):retry", method: "POST", query: [:], body: nil)
            refreshed = UUID()
        } catch { notice = CareerErrors.message(error) }
    }

    private func decide(_ decision: String) async {
        busy = true; defer { busy = false }
        do {
            _ = try await api.careerRequest(path: "/api/job-applications/\(application.id)/close", method: "POST", query: [:],
                                            body: .object(["base_lock_version": .number(Double(raw["lock_version"]?.integer ?? 0)), "status": .string("closed"), "offer_status": .string(decision)]))
            deciding = false
            refreshed = UUID()
        } catch { notice = CareerErrors.message(error) }
    }

    /// 有岗位记录时进入完整岗位详情（10.01）；原岗位已删除时退回只读描述。
    private func openJob() {
        let id = raw.text("job_description_id")
        if id.isEmpty { showJob = true } else { route = .job(id) }
    }

    private func toggleFavorite() async {
        busy = true; defer { busy = false }
        do {
            let result = try await api.careerRequest(path: "/api/job-applications/\(application.id)", method: "PUT", query: [:],
                                                     body: .object(["base_lock_version": .number(Double(raw["lock_version"]?.integer ?? 0)), "is_favorite": .bool(raw["is_favorite"]?.bool != true)]))
            if let updated = result["application"] { current = updated }
        } catch { notice = CareerErrors.message(error) }
    }

    private func update(_ fields: [String: JSONValue]) async {
        busy = true; defer { busy = false }
        var body = fields; body["base_lock_version"] = .number(Double(raw["lock_version"]?.integer ?? 0))
        do {
            let result = try await api.careerRequest(path: "/api/job-applications/\(application.id)", method: "PUT", query: [:], body: .object(body))
            if let updated = result["application"] { current = updated }
        } catch { notice = CareerErrors.message(error) }
    }

    private func reopen() async {
        busy = true; defer { busy = false }
        do {
            _ = try await api.careerRequest(path: "/api/job-applications/\(application.id)/reopen", method: "POST", query: [:], body: .object(["base_lock_version": .number(Double(raw["lock_version"]?.integer ?? 0))]))
            refreshed = UUID()
        } catch { notice = CareerErrors.message(error) }
    }

    private func load() async {
        loading = true; error = nil; now = Date()
        let api = self.api, id = application.id
        do {
            // Web `loadData`（投递详情）：单条进程与它的排期一起读（`Promise.all`），排期内部按 cursor 一页接一页
            async let record = api.careerRequest(path: "/api/job-applications/\(id)", method: "GET", query: [:], body: nil)
            async let listed = ConcurrentLoad.pages(base: ["application_id": id, "limit": "500", "include_archived": "true"]) {
                try await api.careerRequest(path: "/api/interview-sessions", method: "GET", query: $0, body: nil)
            }
            let detail = try await record
            let all = try await listed
            try Task.checkCancellation()
            let app = detail["application"] ?? .null
            current = app; sessions = all
            // Web `ProgressDeckPage.loadDetails`：各场详情一起读，单场读不到只是少这一场；岗位描述与它们同时读
            let jobID = app.text("job_description_id")
            async let job: JSONValue? = jobID.isEmpty ? nil : try? await api.careerRequest(path: "/api/job-descriptions/\(jobID)", method: "GET", query: [:], body: nil)
            let loaded = await ConcurrentLoad.each(all.filter { $0.text("status") != "cancelled" }.map { $0.text("id") }) {
                try await api.careerRequest(path: "/api/interview-sessions/\($0)", method: "GET", query: [:], body: nil)
            }
            details = loaded
            if let job = await job {
                jobDescription = job["job_description"]?.text("description").nonEmptyOr("暂无岗位描述")
            }
        } catch is CancellationError { return }
        catch APIError.unauthorized { error = "登录已失效，请重新登录。" }
        catch { self.error = "求职记录读取失败，请重试。" }
        loading = false
    }
}

struct CareerSessionRef: Identifiable { let value: JSONValue; var id: String { value.text("id") } }

extension String {
    func nonEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// 09.07 · 投递详情右上 ⋯ 菜单（Figma 07 页 84:1255）：白底圆角浮层，编辑类都收在这里；
/// 「日历颜色」后面带当前颜色的小圆点，点开在下面展开一排色块（Web `pd-menu-colors`）；删除在结束或归档后才能点。
struct CareerDetailMenu: View {
    struct Item {
        let title: String
        var danger = false
        var enabled = true
        var colors = false
        /// 右边的灰字（资料份数）。
        var trailing: String? = nil
        let action: () -> Void
    }
    static let swatches: [(value: String, label: String, color: Color)] = [
        ("blue", "蓝", Color(hex: 0x3F6FD8)), ("purple", "紫", Color(hex: 0x7C5CD6)), ("green", "绿", Color(hex: 0x2F9E6E)),
        ("orange", "橙", Color(hex: 0xD9822B)), ("yellow", "黄", Color(hex: 0xD4A82A)), ("red", "红", Color(hex: 0xC2412D)), ("gray", "灰", Color(hex: 0x96968F)),
    ]
    let items: [Item]
    let color: String
    let pickColor: (String) -> Void
    let close: () -> Void
    @State private var colorsOpen = false

    var body: some View {
        let current = Self.swatches.first { $0.value == color } ?? Self.swatches[0]
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if item.colors {
                    CareerDetailMenuRow(title: item.title, enabled: true, danger: false, trailing: {
                        HStack(spacing: 8) {
                            Circle().fill(current.color).frame(width: 8, height: 8)
                            Image(systemName: colorsOpen ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(PD.mute)
                        }
                    }) { colorsOpen.toggle() }
                    if colorsOpen {
                        HStack(spacing: 8) {
                            ForEach(Self.swatches, id: \.value) { swatch in
                                Button { pickColor(swatch.value) } label: {
                                    Circle().fill(swatch.color).frame(width: 16, height: 16)
                                        .overlay(Circle().stroke(.white, lineWidth: 2))
                                        .overlay(Circle().stroke(swatch.value == current.value ? PD.ink : V3.cl, lineWidth: swatch.value == current.value ? 2 : 1).padding(-2))
                                        .frame(width: 22, height: 22).contentShape(Circle())
                                }.buttonStyle(.plain).accessibilityLabel(swatch.label).accessibilityAddTraits(swatch.value == current.value ? .isSelected : [])
                            }
                        }.padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
                    }
                } else {
                    if item.danger { Rectangle().fill(V3.line).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6) }
                    CareerDetailMenuRow(title: item.title, enabled: item.enabled, danger: item.danger, trailing: {
                        if let trailing = item.trailing { Text(trailing).font(V3.sans(12)).foregroundStyle(PD.mute) }
                    }) { close(); item.action() }
                }
            }
        }
        .padding(6).frame(width: 218)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
        .accessibilityElement(children: .contain).accessibilityLabel("这条投递的操作")
    }
}

private struct CareerDetailMenuRow<Trailing: View>: View {
    let title: String
    let enabled: Bool
    let danger: Bool
    @ViewBuilder let trailing: () -> Trailing
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(V3.sans(13)).foregroundStyle(!enabled ? Color(hex: 0xC4C4BE) : danger ? PD.red : PD.ink)
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 12).frame(height: 34)
            // 菜单项的选中高亮（同系统菜单），不是列表悬停
            .background(RoundedRectangle(cornerRadius: 6).fill(hover && enabled ? Color(hex: 0xF2F2EF) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).onHover { hover = $0 }
    }
}

/// 投递详情的拖放：只认本地文件，没有能放的那一轮时不亮也不接。
private struct CareerDetailDrop: DropDelegate {
    let enabled: Bool
    @Binding var over: Bool
    let drop: ([NSItemProvider]) -> Void
    func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { if validateDrop(info: info) { over = true } }
    func dropExited(info: DropInfo) { over = false }
    func performDrop(info: DropInfo) -> Bool {
        over = false
        guard validateDrop(info: info) else { return false }
        drop(info.itemProviders(for: [.fileURL]))
        return true
    }
}
