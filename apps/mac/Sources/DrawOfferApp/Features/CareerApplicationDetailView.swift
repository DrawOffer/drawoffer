import AppKit
import DrawOfferCore
import SwiftUI

struct CareerButtonStyle: ButtonStyle {
    var primary = false
    var radius: CGFloat = 6
    var height: CGFloat = 34
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(LibraryTypography.sans(12, weight: .medium))
            .padding(.horizontal, 16).frame(height: height)
            .foregroundStyle(primary ? .white : Color(hex: 0x1D1D1B))
            .background(primary ? Color(hex: 0x1D1D1B) : .white, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(primary ? .clear : Color(hex: 0xE4E4E0)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
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

/// 04.C01 求职进度页: stepper, the single "next step" card, stage history and side cards.
/// Stage records open 04.C03 stage detail; the AI report (04.C03.C) opens from there.
struct CareerApplicationDetailView: View {
    let application: CareerApplication
    let api: any APIClient
    let back: () -> Void
    let perform: (String, CareerApplication) -> Void
    /// 从资料库「求职进程」进来时直接停在资料页，返回回到资料库。
    var libraryMaterials = false
    private enum Route: Equatable { case stage(String), report(String), job(String), materials(String?), record(String, paste: Bool, fromMaterials: String?) }
    @State private var route: Route?
    @State private var current: JSONValue?
    @State private var sessions: [JSONValue] = []
    @State private var assets: [JSONValue] = []
    @State private var error: String?
    @State private var notice: String?
    @State private var loading = true
    @State private var busy = false
    @State private var jobDescription: String?
    @State private var showJob = false
    @State private var showAllHistory = false
    @State private var rescheduling: JSONValue?
    @State private var cancelling: JSONValue?
    @State private var refreshed = UUID()
    @State private var now = Date()
    @State private var viewKey: String?
    @State private var details: [String: JSONValue] = [:]
    @State private var confirmReject = false
    @State private var prepBusy: String?
    @State private var prepFor: String?
    @State private var adding: JSONValue?
    @State private var addMode: CareerAddContentSheet.Mode = .upload
    @State private var splits: [String: SplitJob] = [:]
    private struct SplitJob { var running: Bool; var error: String? }
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    private var raw: JSONValue { current ?? application.raw }
    private var item: CareerApplication { CareerApplication(raw).includingSessions(sessions) }
    private var model: CareerDetailModel { CareerDetailModel(application: raw, sessions: sessions, now: now) }
    private var active: Bool { raw.text("lifecycle_status") != "terminated" && raw.text("status") == "active" && raw.text("archived_at").isEmpty }

    var body: some View {
        switch route ?? (libraryMaterials ? .materials(nil) : nil) {
        case .stage(let id):
            CareerStageDetailView(sessionID: id, api: api, back: { route = nil; refreshed = UUID() }, openReport: { route = .report(id) })
        case .report(let id):
            CareerReviewReportView(sessionID: id, api: api, back: { route = .stage(id) })
        case .job(let id):
            JobDetailView(jobID: id, application: raw, back: { route = nil; refreshed = UUID() }, deleted: back)
        case .materials(let id):
            CareerMaterialsPage(application: raw, deck: CareerDeck(application: raw, sessions: sessions, now: now), details: details, initialSessionID: id, splitting: Set(splits.filter { $0.value.running }.keys),
                                back: { if libraryMaterials { back() } else { route = nil } }, openRecord: { session, mode in route = .record(session, paste: mode == .paste, fromMaterials: session) },
                                openReview: { route = .stage($0.text("id")) }, generateReview: { route = .stage($0.text("id")) }, add: { addMode = .upload; adding = $0 }, addFromLibrary: { addMode = .library; adding = $0 },
                                openResume: { if !raw.text("resume_id").isEmpty { router?.jump(.editResume(raw.text("resume_id"))) } }, openJob: openJob,
                                fromLibrary: libraryMaterials, openProgress: libraryMaterials ? { router?.jump(.application(application.id)) } : nil)
                .task(id: refreshed) { await load() }
                .sheet(item: Binding(get: { adding.map(CareerSessionRef.init) }, set: { if $0 == nil { adding = nil } })) { entry in
                    CareerAddContentSheet(session: entry.value, recordKind: entry.value.text("stage_type") == "written_test" || entry.value.text("stage_type") == "assessment" ? "笔试" : "面试",
                                          initialMode: addMode, api: api, close: { adding = nil }, saved: { adding = nil; refreshed = UUID() })
                }
        case .record(let id, let paste, let from):
            let deck = CareerDeck(application: raw, sessions: sessions, now: now)
            if let station = deck.stations.first(where: { $0.session?.text("id") == id }) {
                let session = details[id]?["session"] ?? station.session ?? .null
                CareerRecordPage(application: raw, station: station, session: session, mode: paste ? .paste : .record,
                                 splitting: splits[id]?.running == true, splitError: splits[id]?.error, backLabel: from == nil ? "求职进度" : "资料",
                                 back: { route = from.map { .materials($0) } },
                                 split: { text in startSplit(id, text); route = from.map { .materials($0) } },
                                 generateReview: { route = .stage(id) })
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

    private var progressPage: some View {
        let deck = CareerDeck(application: raw, sessions: sessions, now: now)
        let current = deck.current ?? deck.stations[deck.stations.count - 1]
        let shown = viewKey.flatMap { key in deck.stations.first { $0.id == key } } ?? current
        let viewing = shown.id != current.id
        let shownIndex = deck.stations.firstIndex { $0.id == shown.id } ?? 0
        return GeometryReader { geometry in
            let gutter = V3Page<EmptyView>.gutter(card: geometry.size.width)
            let width = max(0, geometry.size.width - gutter * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    deckHeader(deck)
                    if let error { HStack { Text(error).foregroundStyle(PD.red); Button("重试") { refreshed = UUID() }.buttonStyle(CareerActionStyle()) }.font(V3.sans(12)).padding(.top, 12) }
                    if let notice { Text(notice).font(V3.sans(12)).foregroundStyle(PD.body).padding(.top, 12) }
                    // 页头到主体 48；左栏 320、与右侧之间 64（窄屏按比例收）
                    let rail = min(320, max(232, width * 0.29)), gap = min(64, max(28, width * 0.058))
                    HStack(alignment: .top, spacing: gap) {
                        CareerStationRail(deck: deck, application: raw, picked: viewing ? shownIndex : -1, now: now,
                                          pick: { key in withAnimation(.easeOut(duration: 0.24)) { viewKey = key == current.id ? nil : key } },
                                          next: { toApply in handle(toApply ? .recordApplied : .advance) })
                            .frame(width: rail)
                        CareerStationCard(application: raw, deck: deck, station: shown, previous: shownIndex > 0 ? deck.stations[shownIndex - 1] : nil,
                                          details: details, viewing: viewing, now: now, busy: busy || loading, prepBusy: prepBusy == shown.session?.text("id"),
                                          materialsCount: materialsCount, act: { deckAction($0, shown: shown) })
                            .id(shown.id).transition(.opacity)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.top, 48)
                }
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, gutter).padding(.top, 52).padding(.bottom, 72)
            }
        }
        .foregroundStyle(PD.ink).font(V3.sans(13))
        .task(id: refreshed) { await load() }
        .onExitCommand { if viewKey != nil { viewKey = nil } }
        .sheet(isPresented: $showJob) {
            CareerSheet(title: "岗位详情", subtitle: item.company + " · " + item.title, width: 720) {
                Text(jobDescription ?? "原岗位资料已不可用。").font(LibraryTypography.sans(13)).foregroundStyle(CareerPalette.sub).textSelection(.enabled)
            } footer: { Button("关闭") { showJob = false }.buttonStyle(CareerActionStyle(kind: .primary, large: true)) }
            .frame(height: 600)
        }
        .sheet(item: Binding(get: { rescheduling.map(CareerSessionRef.init) }, set: { if $0 == nil { rescheduling = nil } })) { entry in
            CareerRescheduleSheet(session: entry.value, api: api, close: { rescheduling = nil }, saved: { rescheduling = nil; refreshed = UUID() })
        }
        .sheet(item: Binding(get: { prepFor.flatMap { id in sessions.first { $0.text("id") == id } }.map(CareerSessionRef.init) }, set: { if $0 == nil { prepFor = nil } })) { entry in
            let session = CareerSessions.withEffectiveStatus(details[entry.id]?["session"] ?? entry.value, now: now)
            CareerPrepSheet(session: session, busy: prepBusy == entry.id, save: { items in Task { await savePrep(session, items) } },
                            generate: { Task { await generatePrep(session) } }, close: { prepFor = nil })
        }
        .confirmationDialog("\(shown.short)没通过？", isPresented: $confirmReject, titleVisibility: .visible) {
            Button("记为没通过", role: .destructive) { Task { await terminate("company_rejected") } }
            Button("取消", role: .cancel) {}
        } message: { Text("这条投递会结束，记录会一直保留，复盘可以在之后的投递里继续参考。") }
    }

    /// 页头（`.pd-head`）：返回、岗位详情与更多；公司、职位、标签；右侧三个数字。
    private func deckHeader(_ deck: CareerDeck) -> some View {
        let snapshot = raw["job_snapshot"] ?? .null
        let employment = ["full_time": "正式", "campus": "校招", "internship": "实习"][snapshot.text("employment_type")]
        let city = [snapshot.text("work_city"), snapshot.text("city"), snapshot.text("location")].first { !$0.isEmpty }
        let salary = [snapshot.text("salary_text"), snapshot.text("salary")].first { !$0.isEmpty }
        let summary = [city, salary].compactMap { $0 }.joined(separator: " · ")
        let company = [item.company, snapshot.text("department").nonEmptyValue ?? snapshot.text("department_name")].filter { !$0.isEmpty }.joined(separator: " · ")
        let ended = deck.ended != nil || !raw.text("archived_at").isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Button(action: back) {
                    HStack(spacing: 6) { Image(systemName: "arrow.left").font(.system(size: 13)); Text("投递看板") }
                        .font(V3.sans(14)).foregroundStyle(V3.fnt).frame(height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("返回投递看板")
                Spacer()
                HStack(spacing: 4) {
                    Button { openJob() } label: {
                        HStack(spacing: 6) { Image(systemName: "briefcase").font(.system(size: 12)); Text("岗位详情") }
                            .font(V3.sans(14)).foregroundStyle(PD.body).padding(.horizontal, 10).frame(height: 28).contentShape(Capsule())
                    }.buttonStyle(.plain)
                    Menu {
                        Button(raw["is_favorite"]?.bool == true ? "取消收藏" : "收藏") { Task { await toggleFavorite() } }
                        Menu("日历颜色") {
                            ForEach([("blue", "蓝"), ("purple", "紫"), ("green", "绿"), ("orange", "橙"), ("yellow", "黄"), ("red", "红"), ("gray", "灰")], id: \.0) { color in
                                Button(color.1 + (raw.text("calendar_color") == color.0 ? " ✓" : "")) { Task { await update(["calendar_color": .string(color.0)]) } }
                            }
                        }
                        Button(raw.text("archived_at").isEmpty ? "归档" : "取消归档") { perform(raw.text("archived_at").isEmpty ? "archive" : "restore", item) }
                        Divider()
                        Button("删除这条记录", role: .destructive) { perform("delete", item) }.disabled(!ended)
                    } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(V3.fnt).frame(width: 28, height: 28) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("这条投递的操作")
                }.offset(y: -4)
            }
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(company).font(V3.sans(13, weight: .medium)).foregroundStyle(PD.body).frame(height: 20)
                    Text(item.title).font(V3.serif(30)).foregroundStyle(PD.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(minHeight: 40)
                        .accessibilityLabel(item.company + "，" + item.title)
                    HStack(spacing: 8) {
                        if let employment { Text(employment).font(V3.sans(12, weight: .medium)).foregroundStyle(PD.body).padding(.horizontal, 8).frame(height: 22).background(Color(hex: 0xF5F5F2), in: RoundedRectangle(cornerRadius: 6)) }
                        if !summary.isEmpty { Text(summary).font(V3.sans(13)).foregroundStyle(PD.body) }
                    }.frame(minHeight: 22).padding(.top, 6)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 28) {
                    stat(deck.daysLabel, "\(deck.days)", "天", action: nil)
                    stat("复盘", "\(deck.reviews)", "篇") { handleDeck(.review(deck.stations.reversed().compactMap(\.session).first { CareerDeck.hasReview($0) })) }
                    stat("资料", "\(materialsCount)", "份") { route = .materials(nil) }
                }.padding(.bottom, 16)
            }.padding(.top, 8)
        }
    }

    private func stat(_ label: String, _ value: String, _ unit: String, action: (() -> Void)?) -> some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 24, weight: .medium)).foregroundStyle(PD.ink).frame(height: 30)
                Text(unit).font(V3.sans(12.5)).foregroundStyle(PD.mute)
            }
            Text(label).font(V3.sans(11.5)).foregroundStyle(PD.mute).frame(height: 16)
        }
        return Group {
            if let action { Button(action: action) { content.contentShape(Rectangle()) }.buttonStyle(.plain) } else { content }
        }
    }

    private var materialsCount: Int {
        details.values.reduce(0) { $0 + ($1["assets"]?.items.count ?? 0) } + (raw.text("resume_id").isEmpty ? 0 : 1)
    }

    private func deckAction(_ action: CareerDeckAction, shown: CareerStation) {
        switch action {
        case .reschedule: rescheduling = shown.session
        default: handleDeck(action)
        }
    }

    private func handleDeck(_ action: CareerDeckAction) {
        switch action {
        case .recordApplied: perform("apply", item)
        case .advance: perform("stage", item)
        case .schedule: perform("schedule-current", item)
        case .reschedule: rescheduling = CareerDetailModel(application: raw, sessions: sessions, now: now).currentSession
        case .recordOffer, .editOffer, .uploadOffer: perform("offer", item)
        case .handleOffer: perform("accept", item)
        case .editJob: openJob()
        case .editDelivery: perform("apply", item)
        case .reopen: Task { await reopen() }
        case .reject: confirmReject = true
        case .materials(let id):
            // 面试记录：有记录时直接看，否则到资料页
            let markdown = details[id]?["session"]?.text("questions_markdown") ?? ""
            route = InterviewRecord.parse(markdown).isEmpty ? .materials(id) : .record(id, paste: false, fromMaterials: nil)
        case .allMaterials: route = .materials(nil)
        case .review(let session):
            if let id = session?.text("id"), !id.isEmpty { route = .stage(id) } else { notice = "这次求职还没有可查看的复盘记录。" }
        case .generateReview(let session): route = .stage(session.text("id"))
        case .prepOpen(let session): prepFor = session.text("id")
        case .prepToggle(let session, let index):
            let items = (session["prep_items"]?.items ?? []).enumerated().map { position, item -> JSONValue in
                guard position == index, case .object(var fields) = item else { return item }
                fields["done"] = .bool(item["done"]?.bool != true); return .object(fields)
            }
            Task { await savePrep(session, items) }
        case .prepGenerate(let session): Task { await generatePrep(session) }
        case .copy(let text):
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); notice = "已复制"
        }
    }

    /// 有岗位记录时进入完整岗位详情（匹配度、字段编辑）；原岗位已删除时退回只读描述。
    private func openJob() {
        let id = raw.text("job_description_id")
        if id.isEmpty { showJob = true } else { route = .job(id) }
    }

    // MARK: Header

    private func header(_ model: CareerDetailModel) -> some View {
        let snapshot = raw["job_snapshot"] ?? .null
        let employment = ["full_time": "正式", "campus": "校招", "internship": "实习"][snapshot.text("employment_type")]
        let city = [snapshot.text("work_city"), snapshot.text("city"), snapshot.text("location")].first { !$0.isEmpty }
        let salary = [snapshot.text("salary_text"), snapshot.text("salary")].first { !$0.isEmpty }
        let summary = [city, salary].compactMap { $0 }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                CareerBreadcrumb(back: "← 岗位看板", current: item.company, action: back)
                Text(item.title).font(LibraryTypography.serif(28)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(item.company + "，" + item.title)
                HStack(spacing: 8) {
                    if let employment { CareerChipView(employment, .gray) }
                    if !summary.isEmpty { Text(summary).foregroundStyle(CareerPalette.sub) }
                    Text("·").foregroundStyle(CareerPalette.faint)
                    Text(model.headerMeta).foregroundStyle(CareerPalette.faint)
                }.font(LibraryTypography.sans(13))
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                Button(raw["is_favorite"]?.bool == true ? "★ 已收藏" : "☆ 收藏") { Task { await toggleFavorite() } }
                    .buttonStyle(CareerActionStyle(kind: .text)).disabled(busy || current == nil)
                Button("岗位详情") { openJob() }.buttonStyle(CareerActionStyle())
                Menu {
                    Button("修改求职分类") { perform("category", item) }
                    Button("岗位详情") { openJob() }
                    Button("管理关联资料") { router?.jump(.section(.datasets)) }
                    if !active && raw.text("archived_at").isEmpty { Button("归档（从看板隐藏）") { perform("archive", item) } }
                    if !raw.text("archived_at").isEmpty { Button("恢复岗位") { perform("restore", item) } }
                    if active && raw.text("offer_status") == "none" || model.ended {
                        Divider()
                        if active && raw.text("offer_status") == "none" { Button(model.pending ? "不投了" : "结束本次求职", role: .destructive) { perform("terminate", item) } }
                        if model.ended { Button("删除岗位", role: .destructive) { perform("delete", item) } }
                    }
                } label: { Text("•••").font(.system(size: 9, weight: .bold)).foregroundStyle(CareerPalette.text) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .frame(width: 32, height: 18).overlay(RoundedRectangle(cornerRadius: 9).stroke(CareerPalette.border)).accessibilityLabel("更多操作")
            }
        }
    }

    // MARK: Stepper

    private func pipeline(_ model: CareerDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("求职进度").font(LibraryTypography.sans(14, weight: .medium))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                stepMark(step.state)
                                if index < model.steps.count - 1 {
                                    Rectangle().fill(step.state == .done ? CareerPalette.green : CareerPalette.border).frame(height: 2).padding(.trailing, 6)
                                }
                            }
                            Text(step.label).font(LibraryTypography.sans(13, weight: step.state == .current ? .bold : .medium)).lineLimit(1).fixedSize()
                                .foregroundStyle(step.state == .current ? CareerPalette.blue : step.state == .failed ? CareerPalette.red : [.next, .todo].contains(step.state) ? CareerPalette.faint : CareerPalette.text)
                            Text(step.meta.isEmpty ? " " : step.meta).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1).fixedSize()
                                .foregroundStyle(step.state == .failed ? CareerPalette.red : CareerPalette.faint)
                        }.frame(minWidth: 88, maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(minWidth: 780, alignment: .leading)
            }
            .accessibilityLabel("当前阶段：" + model.currentLabel)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(CareerPalette.soft, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(CareerPalette.pipelineLine))
    }

    @ViewBuilder private func stepMark(_ state: CareerDetailStep.State) -> some View {
        switch state {
        case .done, .failed, .offer:
            Circle().fill(state == .done ? CareerPalette.green : state == .failed ? CareerPalette.red : CareerPalette.text).frame(width: 18, height: 18)
                .overlay(Text(state == .done ? "✓" : state == .failed ? "✕" : "★").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
        case .current:
            Circle().fill(.white).frame(width: 18, height: 18).overlay(Circle().stroke(CareerPalette.blue, lineWidth: 1.5)).overlay(Circle().fill(CareerPalette.blue).frame(width: 9, height: 9))
        case .next:
            Circle().fill(.white).frame(width: 18, height: 18).overlay(Circle().stroke(CareerPalette.dashed, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
        case .todo:
            Circle().fill(.white).frame(width: 18, height: 18).overlay(Circle().stroke(CareerPalette.dashed))
        }
    }

    // MARK: Next action

    private func nextCard(_ next: CareerDetailNext) -> some View {
        HStack(spacing: 20) {
            tile(next.tile)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(next.lead).font(LibraryTypography.sans(11, weight: .medium)).foregroundStyle(CareerPalette.faint)
                    ForEach(next.chips, id: \.label) { CareerChipView($0) }
                }
                Text(next.title).font(LibraryTypography.sans(19, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if !next.detail.isEmpty { Text(next.detail).font(LibraryTypography.sans(13)).foregroundStyle(CareerPalette.sub).fixedSize(horizontal: false, vertical: true) }
                if let hint = next.hint { Text(hint).font(LibraryTypography.sans(12)).foregroundStyle(CareerPalette.hint) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                if let primary = next.primary {
                    Button(primary.label) { handle(primary.action) }.buttonStyle(CareerActionStyle(kind: primary.dark ? .primary : .outline, large: true)).disabled(busy || loading)
                }
                if !next.secondary.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(next.secondary, id: \.label) { button in
                            Button(button.label) { handle(button.action) }.buttonStyle(CareerActionStyle(kind: button.danger ? .danger : .text)).disabled(busy || loading)
                        }
                    }
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .leading) { Rectangle().fill(next.accent == .gray ? CareerPalette.dashed : CareerPalette.solid(next.accent)).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(CareerPalette.border))
        .shadow(color: Color(hex: 0x1C1C1A).opacity(0.05), radius: 12, y: 6)
    }

    @ViewBuilder private func tile(_ tile: CareerDetailTile) -> some View {
        switch tile {
        case .date(let head, let day, let foot):
            VStack(spacing: 0) {
                Text(head).font(LibraryTypography.sans(11, weight: .medium)).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 4).background(CareerPalette.text)
                Text(day).font(.system(size: 30, weight: .medium)).padding(.top, 6)
                Text(foot).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(CareerPalette.sub).padding(.bottom, 6)
            }
            .frame(width: 88).background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(CareerPalette.border))
        case .status(let title, let sub, let tone):
            VStack(spacing: 2) {
                Text(title).font(LibraryTypography.sans(15, weight: .medium))
                if !sub.isEmpty { Text(sub).font(LibraryTypography.sans(11)).foregroundStyle(tone == .gray ? CareerPalette.sub : CareerPalette.solid(tone)) }
            }
            .foregroundStyle(tone == .gray ? CareerPalette.text : CareerPalette.solid(tone))
            .frame(width: 88, height: 88).background(CareerPalette.background(tone), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: History and side cards

    private func history(_ model: CareerDetailModel) -> some View {
        let visible = showAllHistory || model.history.count <= 5 ? model.history : Array(model.history.prefix(4))
        return VStack(alignment: .leading, spacing: 10) {
            Text("阶段记录").font(LibraryTypography.sans(15, weight: .medium)).padding(.bottom, 2)
            if visible.isEmpty {
                VStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach([120, 96, 72], id: \.self) { width in
                            HStack(spacing: 8) { Circle().stroke(CareerPalette.dashed, lineWidth: 1.5).frame(width: 8, height: 8); Capsule().fill(CareerPalette.pipelineLine).frame(width: CGFloat(width), height: 8) }
                        }
                    }.padding(.bottom, 8)
                    Text("还没有阶段记录").font(LibraryTypography.sans(13, weight: .medium))
                    Text("记录投递后，筛选、笔试、面试和 Offer 会按时间排在这里").font(LibraryTypography.sans(12)).foregroundStyle(CareerPalette.faint)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 24)
                .background(CareerPalette.soft, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(CareerPalette.rail, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 6) {
                        Group {
                            if let dot = entry.dot { Circle().fill(CareerPalette.solid(dot)) }
                            else { Circle().fill(.white).overlay(Circle().stroke(CareerPalette.faint, lineWidth: 1.5)) }
                        }.frame(width: 10, height: 10)
                        Text(entry.date).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(CareerPalette.faint)
                        if index < visible.count - 1 { Rectangle().fill(CareerPalette.rail).frame(width: 1.5).frame(maxHeight: .infinity).padding(.bottom, -14) }
                    }.frame(width: 52).padding(.top, 16)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) { Text(entry.title).font(LibraryTypography.sans(14, weight: .medium)).lineLimit(1); Spacer(minLength: 0); CareerChipView(entry.chip) }
                        HStack(spacing: 12) {
                            Text(entry.detail).font(LibraryTypography.sans(12)).foregroundStyle(CareerPalette.sub).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                            if let id = entry.sessionID { Button("查看详情 →") { route = .stage(id) }.buttonStyle(CareerActionStyle(kind: .link)) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(entry.highlight.map(CareerPalette.solid) ?? CareerPalette.border, lineWidth: entry.highlight == nil ? 1 : 1.5))
                }
            }
            if visible.count < model.history.count {
                Button("查看更早 \(model.history.count - visible.count) 个阶段 ↓") { showAllHistory = true }
                    .buttonStyle(CareerActionStyle(kind: .muted)).padding(.leading, 66)
            }
        }
    }

    private func side(_ model: CareerDetailModel) -> some View {
        VStack(spacing: 14) {
            if let card = model.offerCard {
                sideCard(card.title, action: card.action, onAction: { handle(model.verbalOffer ? .recordOffer : .editOffer) }) { CareerInfoRows(rows: card.rows) }
            }
            sideCard("投递信息", action: model.pending || !active ? nil : "编辑", onAction: { showJob = true }) { CareerInfoRows(rows: model.deliveryRows) }
            sideCard("关联资料", action: "管理", onAction: { router?.jump(.section(.datasets)) }) {
                let items = resources
                if items.isEmpty { Text("还没有关联简历和资料").font(LibraryTypography.sans(12)).foregroundStyle(CareerPalette.faint) }
                else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(items, id: \.key) { resource in
                            HStack(spacing: 10) {
                                CareerFileBadge(name: resource.name)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(resource.name).font(LibraryTypography.sans(12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                    Text(resource.meta).font(LibraryTypography.sans(11)).foregroundStyle(CareerPalette.faint)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var resources: [(key: String, name: String, meta: String)] {
        var result: [(key: String, name: String, meta: String)] = []
        if !raw.text("resume_id").isEmpty {
            let title = raw.text("resume_title_snapshot").nonEmptyOr("投递简历")
            result.append(("resume", title, "投递简历 · " + CareerFormat.monthDay(raw.text("applied_at").nonEmptyOr(raw.text("updated_at")))))
        }
        if !raw.text("job_description_id").isEmpty {
            result.append(("jd", item.company + "_岗位JD.md", "岗位要求 · " + CareerFormat.monthDay(raw.text("created_at"))))
        }
        for asset in assets {
            let kind = ["audio": "面试录音", "video": "面试视频"][asset.text("asset_type")] ?? "面试材料"
            result.append((asset.text("id"), asset.text("original_file_name"), kind + " · " + CareerFormat.monthDay(asset.text("created_at"))))
        }
        for material in raw["offer_materials"]?.items ?? [] { result.append(("offer-" + material.text("dataset_id"), material.text("file_name"), "Offer 材料")) }
        return result
    }

    private func sideCard<Content: View>(_ title: String, action: String?, onAction: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(LibraryTypography.sans(13, weight: .medium))
                Spacer()
                if let action { Button(action, action: onAction).buttonStyle(CareerActionStyle(kind: .link)).font(LibraryTypography.sans(11)) }
            }
            content()
        }.careerCard()
    }

    // MARK: Actions

    private func handle(_ action: CareerDetailAction) {
        let model = self.model
        switch action {
        case .recordApplied: perform("apply", item)
        case .advance: perform("stage", item)
        case .schedule: perform("schedule-current", item)
        case .recordReview, .answerPlan: if let id = model.currentSession?.text("id") { route = .stage(id) }
        case .reschedule: rescheduling = model.currentSession
        case .cancelSession: cancelling = model.currentSession
        case .recordOffer, .editOffer: perform("offer", item)
        case .acceptOffer: perform("accept", item)
        case .declineOffer: perform("decline", item)
        case .viewReview:
            if let id = model.latestRecorded?.text("id") { route = .stage(id) }
            else { notice = "这次求职还没有可查看的复盘记录。" }
        }
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

    private func terminate(_ reason: String) async {
        busy = true; defer { busy = false }
        do {
            _ = try await api.careerRequest(path: "/api/job-applications/\(application.id)/terminate", method: "POST", query: [:],
                                            body: .object(["client_request_id": .string(UUID().uuidString.lowercased()), "reason": .string(reason), "base_lock_version": .number(Double(raw["lock_version"]?.integer ?? 0))]))
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

    private func cancel(_ session: JSONValue) async {
        cancelling = nil; busy = true; defer { busy = false }
        do {
            _ = try await api.careerRequest(path: "/api/interview-sessions/\(session.text("id"))/cancel", method: "POST", query: [:], body: .object(["base_lock_version": session["lock_version"] ?? .number(1)]))
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
            let latest = CareerDetailModel(application: app, sessions: all, now: now).latestRecorded
            if let id = latest?.text("id"), !id.isEmpty, let session = try? await api.careerRequest(path: "/api/interview-sessions/\(id)", method: "GET", query: [:], body: nil) {
                assets = session["assets"]?.items ?? []
            } else { assets = [] }
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

/// 修改安排: change the time of a scheduled session (or the window of an open-window test).
struct CareerRescheduleSheet: View {
    let session: JSONValue
    let api: any APIClient
    let close: () -> Void
    let saved: () -> Void
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var busy = false
    @State private var error: String?
    @State private var payload: JSONValue?
    var body: some View {
        CareerSheet(title: "修改安排", subtitle: session.text("stage_label") + " · " + CareerSessions.line(session), width: 520) {
            DatePicker("开始时间", selection: $start).disabled(payload != nil)
            DatePicker("结束时间", selection: $end).disabled(payload != nil)
            if let error { Text(error).font(LibraryTypography.sans(12)).foregroundStyle(CareerPalette.red) }
        } footer: {
            Button("取消", action: close).buttonStyle(CareerActionStyle(large: true)).disabled(busy)
            Button(busy ? "正在保存…" : payload == nil ? "保存" : "重试") { Task { await save() } }.buttonStyle(CareerActionStyle(kind: .primary, large: true)).disabled(busy)
        }
        .interactiveDismissDisabled(busy)
        .task {
            start = CareerApplication.date(session.text("start_at")) ?? Date()
            end = CareerApplication.date(session.text("end_at")) ?? start.addingTimeInterval(3600)
        }
    }
    private func save() async {
        guard end > start else { error = "结束时间须晚于开始时间。"; return }
        busy = true; error = nil; defer { busy = false }
        let formatter = ISO8601DateFormatter()
        // A lost response keeps the same request so a retry cannot apply a second, different change.
        if payload == nil { payload = .object(["base_lock_version": session["lock_version"] ?? .number(1), "start_at": .string(formatter.string(from: start)), "end_at": .string(formatter.string(from: end)), "timezone": .string(Beijing.identifier)]) }
        do {
            _ = try await api.careerRequest(path: "/api/interview-sessions/\(session.text("id"))/reschedule", method: "POST", query: [:], body: payload)
            saved()
        } catch {
            if case APIError.server(let status, _) = error, [400, 409, 422].contains(status) { payload = nil }
            self.error = CareerErrors.message(error)
        }
    }
}
