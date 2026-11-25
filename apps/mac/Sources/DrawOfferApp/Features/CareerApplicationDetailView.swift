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
    @State private var prepCost: String?
    @State private var prepBusy: String?
    @State private var adding: JSONValue?
    @State private var addMode: CareerAddContentSheet.Mode = .upload
    @State private var splits: [String: SplitJob] = [:]
    private struct SplitJob { var running: Bool; var error: String? }
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    private var raw: JSONValue { current ?? application.raw }
    /// 补充投递信息弹窗标题旁的阶段胶囊。
    private var deliveryStage: String { item.stageLabel }
    private var item: CareerApplication { CareerApplication(raw).includingSessions(sessions) }
    private var active: Bool { raw.text("lifecycle_status") != "terminated" && raw.text("status") == "active" && raw.text("archived_at").isEmpty }

    var body: some View {
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
                                intentFiles: materialFiles,
                                processed: materialFiles.isEmpty || libraryMaterials ? nil : { materialFiles = []; route = nil })
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

    private func savePrep(_ session: JSONValue, _ items: [JSONValue]) async {
        let id = session.text("id")
        prepBusy = id; defer { prepBusy = nil }
        let lock = details[id]?["session"]?["lock_version"] ?? session["lock_version"] ?? .number(1)
        do {
            _ = try await api.careerRequest(path: "/api/interview-sessions/\(id)", method: "PUT", query: [:], body: .object(["prep_items": .array(items), "base_lock_version": lock]))
            refreshed = UUID()
        } catch { notice = CareerErrors.message(error) }
    }

    /// 投递详情（Figma 07 页 04–09 分区）：返回栏，上半「这一步」+ 右侧随状态换的内容，底部全程时间线。
    /// 点时间线上过去的节点回看那一轮（07.08），Esc 或「回到…」回到现在。
    private var progressPage: some View {
        let deck = CareerDeck(application: raw, sessions: sessions, now: now)
        let current = deck.current ?? deck.stations[deck.stations.count - 1]
        let shown = viewKey.flatMap { key in deck.stations.first { $0.id == key } } ?? current
        let viewing = shown.id != current.id
        let shownIndex = deck.stations.firstIndex { $0.id == shown.id } ?? 0
        let previous = shownIndex > 0 ? deck.stations[shownIndex - 1] : nil
        let shownSession = shown.session.flatMap { $0.text("status") == "cancelled" ? nil : $0 }
        let shownDetail = shownSession.flatMap { details[$0.text("id")] }
        let step = CareerJourney.step(application: raw, deck: deck, station: shown, viewing: viewing, now: now, detail: shownDetail, previous: previous, reviewCost: reviewCost)
        let timeline = CareerJourney.timeline(application: raw, deck: deck, now: now)
        let files = shownSession == nil ? [] : shownDetail?["assets"]?.items ?? []
        // 右侧已经有黑按钮（上传录音、生成准备清单）时，左边只留白按钮
        let prepEmpty = shownSession.map { ($0["prep_items"]?.items ?? []).isEmpty && ($0["prep_generated_at"] == nil || $0["prep_generated_at"] == .null) } ?? false
        let sideHasBlack = step.side == .recordEntry || (step.side == .prep && prepEmpty)
        return GeometryReader { geometry in
            // 稿：内容区 1178 宽时左右各 63，主体 500 + 420 两栏
            let gutter = max(max(40, geometry.size.width * 0.0535), (geometry.size.width - 1200) / 2)
            let width = max(0, geometry.size.width - gutter * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar(deck: deck, shown: shown, shownSession: shownSession)
                    if let error { HStack { Text(error).foregroundStyle(PD.red); Button("重试") { refreshed = UUID() }.buttonStyle(CareerActionStyle()) }.font(V3.sans(12)).padding(.top, 12) }
                    Spacer(minLength: 48)
                    let hero = CareerJourneyHero(job: item.company + " · " + item.title, step: step, files: files, sideHasBlack: sideHasBlack, disabled: busy || loading,
                                                 act: { journeyAction($0, shown: shown, session: shownSession) }, copy: copy, openFile: openAsset,
                                                 addFromComputer: { if let shownSession { pickFiles(into: shownSession) } },
                                                 addFromLibrary: { if let shownSession { addMode = .library; adding = shownSession } })
                        .id(shown.id + (viewing ? ":view" : "")).transition(.opacity)
                    let side = sideView(step.side, deck: deck, shown: shown, session: shownSession, detail: shownDetail)
                    if width >= 900 {
                        HStack(alignment: .center, spacing: 48) {
                            hero.frame(maxWidth: 500, alignment: .leading)
                            Spacer(minLength: 0)
                            side.frame(maxWidth: 420, alignment: .leading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 44) { hero; side.frame(maxWidth: 560, alignment: .leading) }
                    }
                    Spacer(minLength: 64)
                    CareerJourneyTimeline(timeline: timeline, picked: viewing ? shown.id : nil) { key in
                        withAnimation(.easeOut(duration: 0.2)) { viewKey = key == current.id ? nil : key }
                    }
                }
                .frame(width: width, alignment: .leading)
                .frame(minHeight: max(0, geometry.size.height - 90), alignment: .top)
                .padding(.horizontal, gutter).padding(.top, 40).padding(.bottom, 50)
            }
            .overlay(alignment: .topTrailing) {
                // 09.07 ⋯ 菜单：点外面或 Esc 收起
                if menuOpen {
                    ZStack(alignment: .topTrailing) {
                        Color.clear.contentShape(Rectangle()).onTapGesture { menuOpen = false }
                        CareerDetailMenu(items: menuItems(deck: deck), color: raw.text("calendar_color"),
                                         pickColor: { color in menuOpen = false; Task { await update(["calendar_color": .string(color)]) } },
                                         close: { menuOpen = false })
                            .padding(.top, 40 + 19 + 6).padding(.trailing, gutter - 4)
                    }
                }
            }
        }
        .foregroundStyle(PD.ink).font(V3.sans(13))
        .overlay(alignment: .top) { TextNoticeToast(text: $notice, kind: { $0.contains("，但") ? .partial : $0.hasPrefix("已") ? .done : $0.contains("还没有") ? .info : .failed }) }
        .task(id: refreshed) { await load() }
        .task { await loadPrices() }
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

    /// 从电脑选资料（07.03「＋ 添加」、07.01「上传录音」）：选好后进资料页底部浮层，逐个选放进哪一轮、怎么处理。
    private func pickFiles(into session: JSONValue) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = (CareerPendingFile.media + CareerPendingFile.documents).compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        materialFiles = panel.urls
        route = .materials(session.text("id"))
    }

    /// 09.07 / 09.08 ⋯ 里的编辑类操作；删除在结束或归档后才能点。
    private func menuItems(deck: CareerDeck) -> [CareerDetailMenu.Item] {
        let ended = deck.ended != nil || !raw.text("archived_at").isEmpty
        let currentKind = deck.current?.kind
        let offerMenu = currentKind == .offer || currentKind == .oc || deck.ended?.kind == .accepted || deck.ended?.kind == .declined
        // 「编辑投递信息」只补投递本身的字段（09.09 / Web DeliveryDialog），不走「记录投递」加阶段
        var items: [CareerDetailMenu.Item] = [.init(title: "编辑投递信息") { delivering = true }]
        if offerMenu { items.append(.init(title: "编辑 Offer 信息") { perform("offer", item) }) }
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

    @ViewBuilder private func sideView(_ side: CareerJourneySide, deck: CareerDeck, shown: CareerStation, session: JSONValue?, detail: JSONValue?) -> some View {
        switch side {
        case .resume:
            CareerJourneyResumeSide(application: raw, pending: deck.pending, api: api,
                                    open: { if !raw.text("resume_id").isEmpty { router?.jump(.editResume(raw.text("resume_id"))) } },
                                    pick: { perform("apply", item) })
        case .prep:
            CareerJourneyPrepSide(short: shown.short, session: session.map { details[$0.text("id")]?["session"] ?? $0 }, busy: prepBusy != nil && prepBusy == session?.text("id"), cost: prepCost,
                                  save: { items in if let session { Task { await savePrep(session, items) } } },
                                  generate: { if let session { Task { await generatePrep(session) } } }, practice: practice)
        case .recordEntry:
            if let session {
                CareerJourneyRecordEntrySide(state: CareerJourney.recordState(session, detail), busy: busy,
                                             upload: { pickFiles(into: session) },
                                             paste: { route = .record(session.text("id"), paste: true, fromMaterials: nil) },
                                             retry: { id in Task { await retryTranscription(session, id) } })
            }
        case .questions:
            if let session {
                CareerJourneyQuestionsSide(session: session, detail: detail, api: api) { _ in route = .record(session.text("id"), paste: false, fromMaterials: nil) }
            }
        case .review:
            if let session { CareerJourneyReviewSide(session: session, detail: detail, openReview: { openReview(session) }, practice: practice) }
        case .written:
            if let session { CareerJourneyWrittenSide(session: session, detail: detail, open: { route = .written(session.text("id")) }, add: { writtenAdding = session }) }
        case .offer:
            CareerJourneyOfferSide(application: raw, oc: false, accepted: deck.ended?.kind == .accepted)
        case .oc:
            CareerJourneyOfferSide(application: raw, oc: true, accepted: false)
        case .left:
            CareerJourneyLeftSide(deck: deck, details: details, openReview: { openReview(nil) }, practice: practice)
        case .none:
            EmptyView()
        }
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
        case .mock: router?.jump(.mockFor(application: application.id))
        case .generateReview: if let id = session?.text("id") { route = .stage(id) }
        case .openReview: openReview(session)
        case .openRecord: if let id = session?.text("id") { route = .record(id, paste: false, fromMaterials: nil) }
        case .openWritten: if let id = session?.text("id") { route = .written(id) }
        }
    }

    /// 打开复盘：优先看的这一轮，否则最近一份复盘。
    private func openReview(_ session: JSONValue?) {
        let deck = CareerDeck(application: raw, sessions: sessions, now: now)
        let target = session.flatMap { CareerDeck.hasReview($0) ? $0 : nil } ?? deck.stations.reversed().compactMap(\.session).first { CareerDeck.hasReview($0) }
        if let id = target?.text("id"), !id.isEmpty { route = .report(id, fromStage: false) } else { notice = "这次求职还没有可查看的复盘记录。" }
    }

    /// 「去练这一处」：带着这一处进模拟面试（Web `journey.tsx` practice：kind topic、ref 与 label 都是这一处的标题）。
    private func practice(_ label: String) {
        let topic = label.trimmingCharacters(in: .whitespacesAndNewlines)
        router?.jump(.mock(topic.isEmpty ? nil : PracticeFocus(kind: "topic", ref: topic, label: topic)))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); notice = "已复制"
    }

    private func openAsset(_ asset: JSONValue) {
        Task {
            do {
                let file = try await api.downloadDataset(id: asset.text("id"), limit: 512 * 1024 * 1024)
                let named = file.url.deletingLastPathComponent().appendingPathComponent(asset.text("original_file_name").nonEmptyOr(file.url.lastPathComponent))
                if named != file.url { try? FileManager.default.moveItem(at: file.url, to: named) }
                NSWorkspace.shared.open(FileManager.default.fileExists(atPath: named.path) ? named : file.url)
            } catch { notice = CareerErrors.message(error) }
        }
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
        prepCost = fixed("interview_prep").map { "消耗 \($0) 积分" }
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

    private func generatePrep(_ session: JSONValue) async {
        prepBusy = session.text("id"); defer { prepBusy = nil }
        do {
            _ = try await api.careerRequest(path: "/api/interview-sessions/\(session.text("id"))/prep-items:generate", method: "POST", query: [:], body: nil)
            refreshed = UUID()
        } catch { notice = CareerErrors.message(error) }
    }

    private func load() async {
        loading = true; error = nil; now = Date()
        do {
            let detail = try await api.careerRequest(path: "/api/job-applications/\(application.id)", method: "GET", query: [:], body: nil)
            var all: [JSONValue] = []; var cursor = ""; var seen = Set<String>()
            repeat {
                var query = ["application_id": application.id, "limit": "500", "include_archived": "true"]; if !cursor.isEmpty { query["cursor"] = cursor }
                let page = try await api.careerRequest(path: "/api/interview-sessions", method: "GET", query: query, body: nil)
                all += page["items"]?.items ?? []; cursor = page.text("next_cursor")
                if !cursor.isEmpty && !seen.insert(cursor).inserted { throw APIError.invalidResponse }
            } while !cursor.isEmpty
            try Task.checkCancellation()
            let app = detail["application"] ?? .null
            current = app; sessions = all
            var loaded: [String: JSONValue] = [:]
            for session in all where session.text("status") != "cancelled" {
                if let detail = try? await api.careerRequest(path: "/api/interview-sessions/\(session.text("id"))", method: "GET", query: [:], body: nil) { loaded[session.text("id")] = detail }
            }
            details = loaded
            if !app.text("job_description_id").isEmpty, let job = try? await api.careerRequest(path: "/api/job-descriptions/\(app.text("job_description_id"))", method: "GET", query: [:], body: nil) {
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
                    CareerDetailMenuRow(title: item.title, enabled: item.enabled, danger: item.danger, trailing: { EmptyView() }) { close(); item.action() }
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
