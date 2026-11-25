import Foundation
import DrawOfferCore
import SwiftUI

/// 模拟面试首页（Figma 09 · 01 首页，11-16 定稿：01.01 没有简历 / 01.02 有简历没练过 / 01.03 多条记录；Web `v2/MockHome.tsx` 仍是旧版）。
/// 没有记录时是一句话加两张纸：左边标题和入口，右边叠着的简历纸与面试纸，点纸等于点主按钮。
/// 有记录时左边是「还要补」时间线，右边是「下一场」计划卡片，底下是最近几场的分数。三个状态都按 1151 × 828 的设计画布等比缩放。
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
    /// 「开始」「接着练」进面试配置（02）；不传时直接开新的一场配置页由外层决定。
    var showConfig: () -> Void = {}

    private static let countWord = ["", "一", "两", "三", "四", "五", "六", "七", "八", "九"]
    private static let stageW: CGFloat = 1151, stageH: CGFloat = 828
    private static let paper = Color(hex: 0xFCFBF8), paperEdge = Color(hex: 0xE7E5DE), paperMute = Color(hex: 0xA5A39B)
    private static let lineGray = Color(hex: 0xD6D4C9), ringGray = Color(hex: 0xC9C7BC)

    struct HomeData { var overview: JSONValue; var list: [JSONValue]; var resumes: [JSONValue]; var applications: [JSONValue] = []; var sessions: [JSONValue] = [] }

    /// 「还要补」里的一条：卡住的考点、停在哪、你说过的原话、停过几场。
    struct OpenItem: Identifiable {
        var topic: String
        var detail: String?
        var quote: String?
        var meta: String?
        var id: String { topic }
    }

    @State private var data: HomeData?
    @State private var failed = false
    @State private var tick = 0
    @State private var importing = false
    @State private var resumeImport = false
    @State private var notice: MockNotice?
    @State private var waitingID: String?

    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }
    private func request(_ path: String, query: [String: String] = [:]) async throws -> JSONValue {
        try await session.api.careerRequest(path: path, method: "GET", query: query, body: nil)
    }

    private var active: JSONValue? { data?.list.first { ["in_progress", "preparing"].contains($0.text("status")) } }
    private var recent: JSONValue? { data?.list.sorted { $0.text("created_at") > $1.text("created_at") }.first }
    private var evaluating: JSONValue? { recent.flatMap { ["evaluating", "evaluation_failed"].contains($0.text("status")) ? $0 : nil } }
    private var blocking: JSONValue? { active ?? evaluating }

    var body: some View {
        Group {
            if let data {
                let finished = (data.overview["counts"]?["mock"]?.integer ?? 0) + (data.overview["counts"]?["real"]?.integer ?? 0)
                let reviewing = data.overview["records"]?.items.contains { $0.text("status") == "reviewing" } ?? false
                MockStage(width: Self.stageW, height: Self.stageH) {
                    if data.resumes.isEmpty {
                        intro(first: false, reviewing: false, resumeTitle: "")
                    } else if finished == 0 {
                        intro(first: true, reviewing: reviewing, resumeTitle: data.resumes.first?.text("title") ?? "")
                    } else {
                        history(data, finished: finished)
                    }
                }
            } else if failed {
                VStack(alignment: .leading, spacing: 12) {
                    Text("模拟面试没有加载出来").font(V3.serif(28)).foregroundStyle(MockPalette.ink)
                    Text("请检查网络后重试。").font(V3.sans(13)).foregroundStyle(MockPalette.fnt)
                    Button("重新加载") { tick += 1 }.buttonStyle(MockPillStyle(kind: .ghost, height: 32, padding: 21, size: 13))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.horizontal, 61).padding(.top, 120)
            } else {
                V3Loading("正在加载模拟面试…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.white)
        .overlay { MockNoticeToast(notice: $notice) }
        .task(id: "\(account):\(tick)") { await load() }
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
            notice = MockNotice(kind: .success, title: "评估报告好了", message: "这场的分数和卡住的地方已经更新")
        }
        .centeredSheet(isPresented: $importing) {
            MockImportDialog(close: { importing = false }, done: {
                importing = false
                notice = MockNotice(kind: .queued, title: "已开始生成复盘", message: "好了会出现在这里，也会记进长期记忆")
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

    // MARK: 01.01 / 01.02 没有记录

    /// first = false：没有简历（01.01）；first = true：简历放好了、还没练过（01.02）。
    private func intro(first: Bool, reviewing: Bool, resumeTitle: String) -> some View {
        let lines = first
            ? ["题目按你简历里写的经历来出，大约 15 分钟。", "练完会记下你答得好和卡住的地方，", "下一场从卡住的地方接着练。"]
            : ["模拟面试的题目从你简历里的经历来出，", "放好以后，第一场大约 15 分钟。", "练完会记下你答得好和卡住的地方。"]
        let primary: () -> Void = { if first { start() } else { resumeImport = true } }
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
                        Text(verbatim: first ? startLabel("开始第一场") : "导入简历")
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                    }
                }.buttonStyle(MockPillStyle(height: 44, padding: 24, size: 15))
                Button { if first { importing = true } else { showResumes() } } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: first ? "已经面过？导入面试记录" : "没有现成的，写一份")
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    }
                }.buttonStyle(MockLinkStyle(size: 15, color: MockPalette.sub))
            }.offset(x: 120, y: 476)
            if reviewing {
                Text("导入的面试正在生成复盘，好了会出现在这里。").font(V3.sans(13)).foregroundStyle(MockPalette.fnt).fixedSize().offset(x: 120, y: 540)
            }
            Button(action: primary) { pile(first: first, resumeTitle: resumeTitle) }.buttonStyle(.plain)
                .frame(width: 600, height: 560, alignment: .topLeading).offset(x: 520, y: 100)
                .accessibilityLabel(first ? "开始第一场模拟面试" : "放一份简历")
            Text(first ? "点这张纸，开始第一场" : "点这张纸，先放一份简历").font(V3.sans(13)).foregroundStyle(Self.paperMute).fixedSize().offset(x: 850, y: 660)
        }
        .frame(width: Self.stageW, height: Self.stageH, alignment: .topLeading)
    }

    /// 两张叠着的纸：后面一张简历（顺时针 6°），前面一张面试题（逆时针 3°）。
    private func pile(first: Bool, resumeTitle: String) -> some View {
        ZStack(alignment: .topLeading) {
            resumePaper(filled: first, title: resumeTitle).rotationEffect(.degrees(6)).position(x: 224, y: 307.5)
            interviewPaper(first: first).rotationEffect(.degrees(-3)).position(x: 402.3, y: 258.3)
        }
        .frame(width: 600, height: 560, alignment: .topLeading).contentShape(Rectangle())
    }

    private func paperSheet<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(Self.paper).shadow(color: .black.opacity(0.08), radius: 14, y: 12)
            RoundedRectangle(cornerRadius: 4).strokeBorder(Self.paperEdge)
            content().clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(width: 360, height: 480)
    }

    private func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: min(3, h / 2)).fill(color).frame(width: w, height: h).offset(x: x, y: y)
    }

    private func resumePaper(filled: Bool, title: String) -> some View {
        let strong = Color(hex: filled ? 0x9C9A93 : 0xCCC9C2), soft = Color(hex: filled ? 0xC9C7C0 : 0xE4E2DB)
        return paperSheet {
            ZStack(alignment: .topLeading) {
                if filled && !title.isEmpty {
                    Text(verbatim: title).font(V3.serif(16)).foregroundStyle(MockPalette.sub).lineLimit(1).frame(width: 180, alignment: .leading).offset(x: 29, y: 32)
                } else {
                    bar(29, 39, 150, 12, strong)
                }
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

    private func interviewPaper(first: Bool) -> some View {
        paperSheet {
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Text(first ? "第 1 题 · 来自你的简历" : "第 1 题 · 开场").font(V3.sans(11)).foregroundStyle(MockPalette.fnt).fixedSize().offset(y: 0)
                    Text(first ? "讲讲你简历里最有挑战的一个项目，为什么这样设计？" : "先介绍一下你自己，挑一个最想聊的项目讲讲。")
                        .font(V3.serif(21)).foregroundStyle(MockPalette.ink).lineHeight(21, 31, .serif).frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true).offset(y: 28 - 2.9)
                    Canvas { context, _ in
                        for (index, height) in Self.wave.enumerated() {
                            context.fill(Path(roundedRect: CGRect(x: CGFloat(index) * 5.41, y: 14 - height / 2, width: 2.2, height: height), cornerRadius: 1.1), with: .color(Color(hex: 0xCCC9C2)))
                        }
                    }.frame(width: 300, height: 28).offset(y: 116)
                    Text("轮到你时，直接开口说就行").font(V3.sans(11.5)).foregroundStyle(MockPalette.fnt).fixedSize().offset(y: 170)
                    Rectangle().fill(Color(hex: 0xEFEEE9)).frame(width: 300, height: 1).offset(y: 212)
                    Text(first ? "第 2 题 · 来自你的简历" : "第 2 题 · 来自你的简历").font(V3.sans(11)).foregroundStyle(Self.paperMute).fixedSize().offset(y: 239)
                    Text(first ? "接着问你简历里的另一段经历" : "放好简历后，这一题换成你写过的项目").font(V3.serif(15)).foregroundStyle(Color(hex: 0xA8A8A1)).fixedSize().offset(y: 261)
                    Text("第 3 题 · 开始后，接着你的回答追问").font(V3.sans(11)).foregroundStyle(Self.paperMute).fixedSize().offset(y: 310)
                }
                .frame(width: 300, height: 326, alignment: .topLeading).offset(x: 29, y: 39)
                Rectangle().fill(LinearGradient(stops: [.init(color: Self.paper.opacity(0), location: 0), .init(color: Self.paper, location: 0.6), .init(color: Self.paper, location: 1)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 362, height: 174).offset(x: -1, y: 306)
                Text("第一场 · 3 题 · 约 15 分钟").font(V3.sans(11.5)).foregroundStyle(MockPalette.fnt).fixedSize().offset(x: 29, y: 433)
            }
        }
    }

    // MARK: 01.03 有记录

    private func history(_ data: HomeData, finished: Int) -> some View {
        let overview = data.overview
        let stuck = overview["stuck"].flatMap { $0 == .null ? nil : $0 }
        let items = Self.openItems(overview, stuck: stuck)
        let openCount = max(overview["tallies"]?["open"]?["count"]?.integer ?? 0, items.count)
        let cleared = overview["tallies"]?["cleared"]
        let clearedCount = cleared?["count"]?.integer ?? 0
        let clearedText = (cleared?["examples"]?.items ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }.joined(separator: "、")
        return ZStack(alignment: .topLeading) {
            Color.white
            Text(verbatim: ["MOCK INTERVIEWS", Self.countLine(overview)].filter { !$0.isEmpty }.joined(separator: " · ")).font(V3.sans(12, weight: .medium))
                .foregroundStyle(MockPalette.fnt).fixedSize().frame(height: 18).offset(x: 48, y: 52)
            Text(verbatim: stuck.map(Self.stuckTitle) ?? "这几场没有卡住的地方。").font(V3.serif(28)).foregroundStyle(MockPalette.ink).lineLimit(1).fixedSize().frame(height: 36).offset(x: 48, y: 78)
            Text(verbatim: "根据你 \(finished) 场面试和练习记下的：还要补 \(openCount) 处，已经掌握 \(clearedCount) 处。").font(V3.sans(14)).foregroundStyle(MockPalette.sub)
                .lineLimit(1).fixedSize().frame(height: 22).offset(x: 48, y: 120)
            Button("导入面试记录") { importing = true }.buttonStyle(MockPillStyle(kind: .ghost, height: 40)).offset(x: 980, y: 82)
            openColumn(items, openCount: openCount, clearedCount: clearedCount, clearedText: clearedText).offset(x: 48, y: 184)
            nextCard(overview, items: items, data: data).offset(x: 712, y: 176)
            recentScores(overview).offset(x: 48, y: 656)
        }
        .frame(width: Self.stageW, height: Self.stageH, alignment: .topLeading)
    }

    private func ring(_ color: Color) -> some View {
        Circle().fill(.white).overlay(Circle().strokeBorder(color, lineWidth: 1.5)).frame(width: 9, height: 9)
    }

    private func openColumn(_ items: [OpenItem], openCount: Int, clearedCount: Int, clearedText: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("还要补").font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.ink)
                Text(verbatim: "\(openCount) 处").font(V3.sans(14)).foregroundStyle(MockPalette.mute)
            }.frame(height: 24)
            if items.isEmpty {
                Text("这几场没有留下要补的地方。").font(V3.sans(13)).foregroundStyle(MockPalette.fnt).padding(.top, 16)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let last = index == items.count - 1
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: item.topic).font(V3.sans(16, weight: .medium)).foregroundStyle(MockPalette.ink).lineLimit(1).frame(height: 24)
                    if let detail = item.detail {
                        Text(verbatim: detail).font(V3.sans(13)).foregroundStyle(MockPalette.sub).lineHeight(13, 20).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                    }
                    if let quote = item.quote {
                        Text(verbatim: quote).font(V3.sans(13)).foregroundStyle(MockPalette.fnt).lineHeight(13, 20).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                    }
                    if let meta = item.meta {
                        Text(verbatim: meta).font(V3.sans(12)).foregroundStyle(MockPalette.mute).lineLimit(1).frame(height: 20).padding(.top, 2)
                    }
                }
                .padding(.leading, 24).frame(width: 616, alignment: .leading)
                .padding(.top, index == 0 ? 16 : 0).padding(.bottom, last ? 0 : 28)
                .background(alignment: .topLeading) {
                    if !last { Rectangle().fill(Self.lineGray).frame(width: 1).padding(.top, (index == 0 ? 16 : 0) + 12).padding(.leading, 4).padding(.bottom, -8) }
                }
                .overlay(alignment: .topLeading) {
                    Group { if index == 0 { Circle().fill(MockPalette.orange).frame(width: 9, height: 9) } else { ring(Self.ringGray) } }
                        .padding(.top, (index == 0 ? 16 : 0) + 7.5)
                }
            }
            if clearedCount > 0 {
                Rectangle().fill(MockPalette.line).frame(width: 616, height: 1).padding(.top, 32)
                HStack(spacing: 10) {
                    Text("已经掌握").font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.ink)
                    Text(verbatim: "\(clearedCount) 处 · 之后不再单独出题").font(V3.sans(14)).foregroundStyle(MockPalette.mute)
                }
                .padding(.leading, 24).frame(height: 24).padding(.top, 24)
                .overlay(alignment: .topLeading) { ring(MockPalette.blue).padding(.top, 24 + 7.5) }
                if !clearedText.isEmpty {
                    Text(verbatim: clearedText).font(V3.sans(13)).foregroundStyle(MockPalette.sub).lineHeight(13, 20).fixedSize(horizontal: false, vertical: true)
                        .frame(width: 592, alignment: .leading).padding(.leading, 24).padding(.top, 4)
                }
            }
        }
        .frame(width: 616, alignment: .topLeading)
    }

    /// 下一场计划卡片：标题跟着最近的面试日程走，列表是上面「还要补」的前几处。
    private func nextCard(_ overview: JSONValue, items: [OpenItem], data: HomeData) -> some View {
        let now = Date()
        let target = MockMap.pickTarget(applications: data.applications, sessions: data.sessions, now: now, chosen: nil)
        var title = "接着练卡住的地方", sub = "从上次停下的地方问起，答过去就不用再练了"
        if target.kind != .general {
            let company = MockMap.companyName(target)
            let stage = target.session?.text("stage_label").nonEmptyValue ?? target.application?.text("current_stage_label") ?? ""
            title = "按\(company)\(stage)准备"
            if let start = target.session.flatMap({ CareerApplication.date($0.text("start_at")) }) {
                let calendar = Beijing.calendar
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: start)).day ?? 0
                sub = "\(MockHomeV2.mmdd(target.session?.text("start_at") ?? "")) \(stage)，\(days <= 0 ? "就在今天" : "还有 \(days) 天")，先练最影响通过的"
            } else {
                sub = "先练最影响通过的"
            }
        }
        let rows = Array(items.prefix(4))
        let goal = overview["goal"].flatMap { $0 == .null ? nil : $0.stringValue }
        let late = overview["tallies"]?["late"]
        let lateCount = late?["count"]?.integer ?? 0, lateTotal = late?["total"]?.integer ?? 0
        let tip = goal.map { $0 == "先说结论，再讲做法" ? "会提醒你先说结论再讲做法" : "这一场从「\($0)」问起" }
        let dividerY = CGFloat(127 + 40 * rows.count)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(.white)
            RoundedRectangle(cornerRadius: 12).strokeBorder(MockPalette.cl)
            ZStack(alignment: .topLeading) {
                HStack {
                    Text("下一场").font(V3.sans(12)).foregroundStyle(MockPalette.mute)
                    Spacer(minLength: 0)
                    Text(verbatim: rows.isEmpty ? "约 15 分钟" : "\(rows.count) 处 · 约 15 分钟").font(V3.sans(12)).foregroundStyle(MockPalette.mute)
                }.frame(width: 343, height: 20).offset(x: 23, y: 23)
                Text(verbatim: title).font(V3.sans(16, weight: .medium)).foregroundStyle(MockPalette.ink).lineLimit(1).frame(width: 343, height: 24, alignment: .leading).offset(x: 23, y: 47)
                Text(verbatim: sub).font(V3.sans(13)).foregroundStyle(MockPalette.fnt).lineLimit(1).frame(width: 343, height: 20, alignment: .leading).offset(x: 23, y: 75)
                Rectangle().fill(MockPalette.line).frame(width: 343, height: 1).offset(x: 23, y: 111)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    let y = CGFloat(127 + 40 * index)
                    Text(verbatim: "\(index + 1)").font(V3.sans(13)).foregroundStyle(MockPalette.mute).frame(height: 24).offset(x: 23, y: y)
                    Text(verbatim: item.topic).font(V3.sans(14)).foregroundStyle(MockPalette.ink).lineLimit(1).frame(width: 210, height: 24, alignment: .leading).offset(x: 47, y: y)
                    Text("上次停在这").font(V3.sans(12)).foregroundStyle(MockPalette.orange).frame(width: 343, height: 20, alignment: .trailing).offset(x: 23, y: y + 2)
                }
                if !rows.isEmpty { Rectangle().fill(MockPalette.line).frame(width: 343, height: 1).offset(x: 23, y: dividerY) }
                let base = rows.isEmpty ? CGFloat(127) : dividerY + 16
                if let tip {
                    Text(verbatim: tip).font(V3.sans(13)).foregroundStyle(MockPalette.ink).lineLimit(1).frame(width: 343, height: 20, alignment: .leading).offset(x: 23, y: base)
                }
                if lateTotal > 0 && lateCount > 0 {
                    Text(verbatim: "前 \(lateTotal) 场有 \(lateCount) 场是被追问才讲做法").font(V3.sans(12)).foregroundStyle(MockPalette.mute).lineLimit(1)
                        .frame(width: 343, height: 20, alignment: .leading).offset(x: 23, y: base + 20)
                }
                HStack(spacing: 16) {
                    Button(startLabel("开始这一场"), action: start).buttonStyle(MockPillStyle(height: 37, padding: 24, size: 14))
                    Text("岗位、简历、音色开始后能改").font(V3.sans(12)).foregroundStyle(MockPalette.mute).lineLimit(1)
                }.offset(x: 23, y: base + (tip == nil ? 0 : 51))
            }
            .padding(1)
        }
        .frame(width: 391, height: 448, alignment: .topLeading)
    }

    /// 最近几场（最多 4 场）：分数、日期和标题，最新一场旁边写比第一场多了多少。
    private func recentScores(_ overview: JSONValue) -> some View {
        let scored = (overview["records"]?.items ?? []).filter { $0["score"]?.numberValue != nil && $0.text("status") == "completed" }
            .sorted { (CareerApplication.date($0.text("at")) ?? .distantPast) < (CareerApplication.date($1.text("at")) ?? .distantPast) }
        let shown = Array(scored.suffix(4))
        let score = overview["tallies"]?["score"].flatMap { $0 == .null ? nil : $0 }
        let diff = (score?["latest"]?.integer ?? 0) - (score?["first"]?.integer ?? 0)
        let showDiff = (score?["count"]?.integer ?? 0) >= 2 && shown.count >= 2
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(MockPalette.line).frame(width: 1055, height: 1)
            HStack(spacing: 14) {
                Text(verbatim: "最近 \(shown.count) 场").font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.ink)
                if shown.count >= 2, let first = shown.first?["score"]?.integer, let last = shown.last?["score"]?.integer {
                    Text(verbatim: "得分从 \(first) 到 \(last)").font(V3.sans(14)).foregroundStyle(MockPalette.mute)
                }
            }.fixedSize().frame(height: 20).offset(y: 24)
            Button("全部记录 ›", action: showRecords).buttonStyle(MockLinkStyle()).frame(width: 200, height: 20, alignment: .trailing).offset(x: 1055 - 200, y: 24)
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, record in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            Text(verbatim: "\(record["score"]?.integer ?? 0)").font(V3.serif(26)).foregroundStyle(MockPalette.ink)
                            Text("分").font(V3.sans(13)).foregroundStyle(MockPalette.fnt)
                            if index == shown.count - 1 && showDiff {
                                Text(verbatim: "比第一场 \(diff >= 0 ? "+" : "")\(diff)").font(V3.sans(13)).foregroundStyle(diff >= 0 ? MockPalette.blue : MockPalette.orange).padding(.leading, 8)
                            }
                        }.frame(height: 36)
                        Text(verbatim: "\(Self.mmdd(record.text("at"))) · \(record.text("title"))").font(V3.sans(12.5)).foregroundStyle(MockPalette.mute).lineLimit(1)
                            .frame(width: 240, alignment: .leading).padding(.top, 4)
                    }
                    .frame(width: 1055.0 / 4, alignment: .leading)
                }
            }.offset(y: 58)
        }
        .frame(width: 1055, height: 130, alignment: .topLeading)
    }

    /// 「还要补」最多三条：先是卡得最多的一处，再是还没答到位的其他考点，细节从各场记录里找。
    static func openItems(_ overview: JSONValue, stuck: JSONValue?) -> [OpenItem] {
        let records = (overview["records"]?.items ?? []).filter { $0.text("status") == "completed" && ($0["stuck"] ?? .null) != .null }
            .sorted { (CareerApplication.date($0.text("at")) ?? .distantPast) > (CareerApplication.date($1.text("at")) ?? .distantPast) }
        func key(_ text: String) -> String { text.lowercased().filter { !$0.isWhitespace } }
        var names: [String] = []
        if let topic = stuck?.text("topic").nonEmptyValue { names.append(topic) }
        for name in (overview["tallies"]?["open"]?["examples"]?.items ?? []).compactMap(\.stringValue) where !name.isEmpty && !names.contains(where: { key($0) == key(name) }) { names.append(name) }
        return names.prefix(3).enumerated().map { index, name in
            let hits = records.filter { key($0["stuck"]?.text("topic") ?? "") == key(name) }
            var item = OpenItem(topic: name)
            item.detail = hits.first?["stuck"]?.text("detail").nonEmptyValue
            if index == 0, let stuck, key(stuck.text("topic")) == key(name) {
                let times = max(stuck["times"]?.integer ?? 0, hits.count)
                if item.detail == nil, let detail = stuck.text("detail").nonEmptyValue { item.detail = "停在 \(detail)" }
                if let quote = stuck["records"]?.items.last?.text("quote").nonEmptyValue { item.quote = "你上次说：“\(quote)……”" }
                let latest = stuck["records"]?.items.last
                let when = [latest.map { mmdd($0.text("date")) }, latest?.text("title").nonEmptyValue].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
                item.meta = "停过 \(max(times, 1)) 场" + (when.isEmpty ? "" : " · 最近 \(when)")
            } else if let latest = hits.first {
                let when = [mmdd(latest.text("at")), latest.text("title")].filter { !$0.isEmpty }.joined(separator: " ")
                item.meta = "停过 \(hits.count) 场" + (when.isEmpty ? "" : " · \(when)")
            }
            return item
        }
    }

    // MARK: 摘要（旧版首页的四列，其他页面和测试还会用到文案）

    static func tallies(_ overview: JSONValue) -> [MockTally] {
        let counts = overview["counts"], t = overview["tallies"]
        let total = (counts?["mock"]?.integer ?? 0) + (counts?["real"]?.integer ?? 0)
        let first = total <= 1
        let cleared = t?["cleared"], open = t?["open"], late = t?["late"]
        let clearedCount = cleared?["count"]?.integer ?? 0, openCount = open?["count"]?.integer ?? 0
        let examples = { (value: JSONValue?) in (value?["examples"]?.items ?? []).map { $0.stringValue ?? "" }.filter { !$0.isEmpty }.joined(separator: "、") }
        var items = [
            clearedCount > 0
                ? MockTally(value: "\(clearedCount)", unit: "处", label: first ? "答好了" : "不用再练", text: examples(cleared), dot: MockPalette.blue)
                : MockTally(value: "0", unit: "处", label: first ? "答好了" : "不用再练", text: "答好的地方，之后就不再问。"),
            openCount > 0
                ? MockTally(value: "\(openCount)", unit: "处", label: "还要补", text: examples(open), dot: MockPalette.orange)
                : MockTally(value: "0", unit: "处", label: "还要补", text: "这几场没有留下要补的地方。"),
        ]
        let lateTotal = late?["total"]?.integer ?? 0, lateCount = late?["count"]?.integer ?? 0
        if first || lateTotal == 0 {
            items.append(MockTally(value: "1", unit: "场后", label: "看出回答习惯", text: "再练一场，就能看出来。"))
        } else {
            items.append(MockTally(value: "\(lateCount)", unit: "场", label: "被追问才讲做法", text: lateCount == 0 ? "每场都先说了结论，保持这个习惯。" : "这场试试先说结论。"))
        }
        if let score = t?["score"], score != .null {
            let latest = score["latest"]?.integer ?? 0, start = score["first"]?.integer ?? 0, count = score["count"]?.integer ?? 0
            let diff = latest - start
            items.append(count <= 1
                ? MockTally(value: "\(latest)", unit: "分", label: "第一场", text: "下一场开始，看得到进步。")
                : MockTally(value: "\(latest)", unit: "分", label: diff >= 0 ? "+\(diff)" : "\(diff)", tone: diff >= 0 ? MockPalette.blue : MockPalette.orange,
                            text: "从 \(start) 分\(count > 2 ? "练" : "")到 \(latest) 分，一共 \(count) 场。"))
        }
        return items
    }

    static func stuckTitle(_ stuck: JSONValue) -> String {
        let topic = stuck.text("topic"), times = stuck["times"]?.integer ?? 1
        if times >= 2 { return "\(topic)，你\(times < countWord.count ? countWord[times] : "\(times)")次都停在同一处。" }
        guard let detail = stuck.text("detail").nonEmptyValue else { return "\(topic)，你上次停在了这里。" }
        let spaced = detail.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
        return "\(topic)，你停在了\(spaced ? " " : "")\(detail)这一步。"
    }

    static func countLine(_ overview: JSONValue) -> String {
        let real = overview["counts"]?["real"]?.integer ?? 0, mock = overview["counts"]?["mock"]?.integer ?? 0
        return [real > 0 ? "面了 \(real) 场" : nil, mock > 0 ? "练了 \(mock) 场" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    static func mmdd(_ value: String) -> String {
        guard let date = CareerApplication.date(value) else { return "" }
        let parts = Beijing.calendar.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0)
    }


    // MARK: 命令

    private func startLabel(_ idle: String) -> String { active != nil ? "继续这一场" : evaluating != nil ? "看上一场" : idle }

    private func start() {
        if let blocking { open(blocking.text("id")) } else { showConfig() }
    }

    private func load() async {
        guard !account.isEmpty else { return }
        do {
            async let overview = request("/api/mock-interviews/overview")
            async let list = request("/api/mock-interviews", query: ["limit": "100"])
            async let resumes = request("/api/resumes")
            // 下一场卡片的标题跟着最近的面试日程走；这两个读不到就用通用标题
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
