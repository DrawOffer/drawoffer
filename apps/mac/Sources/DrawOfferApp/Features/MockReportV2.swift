import DrawOfferCore
import SwiftUI

/// 面试复盘（模拟面试这一边，Web `mock-interview/v2/ReportV2.tsx`）：评估报告转成统一结构交给 `ReviewReportView`，
/// 再接上模拟面试才有的东西：语音表现、对照资料、行动打勾、再练一次；点题进单题详情（RP-2a / RP-2b）。
struct MockReportV2: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let id: String
    let home: () -> Void
    let records: () -> Void
    let practice: (PracticeFocus) -> Void
    let open: (String) -> Void
    var changed: () -> Void = {}

    @State private var detail: JSONValue?
    @State private var failed: String?
    @State private var question: String?
    @State private var reading = false
    @State private var readingAt = 0
    @State private var busy = false
    @State private var toast: (title: String, message: String, error: Bool)?
    @State private var next: NextInterview?

    var body: some View {
        Group {
            if let detail, let report = detail["report"], report != .null {
                let rows = MockReview.rows(detail, report)
                ZStack(alignment: .topLeading) {
                    ReviewReportView(
                        view: view(detail, report, rows), next: next, paused: reading || question != nil,
                        crumb: { crumb([("模拟面试", home)], current: nil, trailing: [("面试复盘", records)]) },
                        actions: {
                            Button("翻看面试记录") { reading = true }.buttonStyle(MockButtonStyle())
                            Button(busy ? "正在准备…" : "再练一次") { Task { await repeatSession() } }.buttonStyle(MockButtonStyle(kind: .dark)).disabled(busy)
                        },
                        open: { question = $0 },
                        practice: { focus($0.first?.title, detail) },
                        action: { runAction($0, detail, rows) },
                        toggleDone: { index in Task { await toggleDone(index, detail) } },
                        abilityExtra: { if detail.text("answer_mode") == "voice", let metrics = report["voice_metrics"], metrics != .null { voiceExtra(detail, metrics) } },
                        nextExtra: { factExtra(report) },
                        footnote: "评分规则 \(report.text("rubric_version")) · 总分是各主问题的平均分")
                    .opacity(reading || question != nil ? 0 : 1).allowsHitTesting(!(reading || question != nil)).accessibilityHidden(reading || question != nil)
                    if reading { recordPage(detail) }
                    else if let question, let row = rows.first(where: { $0.round.main.display("id") == question }) {
                        MockQuestionDetail(detail: detail, rows: rows, row: row, open: { self.question = $0 }, home: home,
                                           focus: { focus($0, detail) }, updated: { self.detail = $0; changed() }, toast: { toast = $0 })
                            .id(question)
                    }
                    if let toast { toastView(toast) }
                }
            } else if let detail {
                VStack(spacing: 10) {
                    Text("这场还没有评估报告").font(V3.serif(18))
                    Button("刷新") { self.detail = nil; Task { await load() } }.buttonStyle(MockButtonStyle())
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white).id(detail.display("id"))
            } else if let failed {
                VStack(spacing: 10) {
                    Text(failed.contains("不存在") ? "找不到这场模拟面试" : "模拟面试没有加载出来").font(V3.serif(18)).foregroundStyle(MI.ink)
                    Text(verbatim: failed).font(V3.sans(13)).foregroundStyle(MI.sub)
                    Button("返回模拟面试", action: home).buttonStyle(MockButtonStyle())
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
            } else { Color.white }
        }
        .task(id: id) { await load() }
        .task(id: detail?.display("job_application_id") ?? "") { await loadNext() }
    }

    private func view(_ detail: JSONValue, _ report: JSONValue, _ rows: [MockReview.Row]) -> MockReview.View {
        let finished = detail.text("finished_at").nonEmptyValue ?? detail.text("created_at")
        let stats = MockMap.stats(detail)
        let sub = [detail.text("company_name").nonEmptyValue ?? "通用练习", MockMap.diffName[detail.text("difficulty")], detail.text("answer_mode") == "voice" ? "语音" : "文字",
                   "\(rows.count) 题", stats.minutes.map { "\($0) 分钟" }].compactMap { $0 }.joined(separator: " · ")
        return MockReview.view(detail, report, rows: rows, title: "\(MockMap.mmddDot(finished))  \(MockMap.typeName(detail))", sub: sub)
    }

    private func crumb(_ back: [(String, () -> Void)], current: String?, trailing: [(String, () -> Void)]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(back.enumerated()), id: \.offset) { _, item in
                Button(action: item.1) { HStack(spacing: 6) { Image(systemName: "arrow.left").font(.system(size: 13)); Text(verbatim: item.0) }.contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("返回" + item.0)
            }
            ForEach(Array(trailing.enumerated()), id: \.offset) { _, item in
                Text("/").accessibilityHidden(true)
                Button(action: item.1) { Text(verbatim: item.0) }.buttonStyle(.plain)
            }
            if let current { Text("/").accessibilityHidden(true); Text(verbatim: current) }
        }.font(V3.sans(16)).foregroundStyle(V3.fnt).frame(height: 20)
    }

    private func toastView(_ value: (title: String, message: String, error: Bool)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value.title).font(V3.sans(13, weight: .medium)).foregroundStyle(value.error ? V3.red : RR.ink)
            if !value.message.isEmpty { Text(verbatim: value.message).font(V3.sans(12)).foregroundStyle(MI.sub) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12).background(.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xE6E3DC))).shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(24)
        .task(id: value.title + value.message) { try? await Task.sleep(for: .seconds(5)); toast = nil }
    }

    /// 能力页右下：语音面试才有的语速、停顿、口头禅。
    private func voiceExtra(_ detail: JSONValue, _ metrics: JSONValue) -> some View {
        let reference = metrics["reference"] ?? .null
        let range = { (key: String, fallback: [Double]) in (reference[key]?.items.compactMap(\.numberValue)).flatMap { $0.count == 2 ? $0 : nil } ?? fallback }
        let speed = range("chars_per_minute", [180, 240]), pauses = range("long_pauses", [0, 3]), fillers = range("filler_ratio", [0, 0.05])
        let cpm = metrics["chars_per_minute"]?.numberValue ?? 0, long = metrics["long_pauses"]?.numberValue ?? 0, filler = metrics["filler_ratio"]?.numberValue ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("语音表现").font(V3.sans(14, weight: .semibold))
                Text("只在语音面试里有").font(V3.sans(12)).foregroundStyle(RR.mute)
            }.padding(.bottom, 10)
            HStack(spacing: 0) {
                metric("语速", "\(Int(cpm.rounded()))", "字/分", cpm > speed[1] || cpm < speed[0])
                metric("长停顿", "\(Int(long))", "次", long > pauses[1])
                metric("口头禅", "\(Int((filler * 100).rounded()))%", "", filler > fillers[1])
            }
            Text(verbatim: metrics.text("tip")).font(V3.sans(12.5)).foregroundStyle(RR.sub).lineHeight(12.5, 20).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            if detail["recordings_deleted"]?.bool != true {
                Button(busy ? "正在删除…" : "删除本场录音") { Task { await deleteRecordings(detail) } }.buttonStyle(RRLinkStyle(sub: true)).disabled(busy)
            }
        }
    }

    private func metric(_ label: String, _ value: String, _ unit: String, _ warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(V3.sans(12)).foregroundStyle(RR.mute)
            (Text(value).font(.system(size: 22, weight: .semibold)).foregroundColor(warn ? RR.or : RR.ink) + Text(unit).font(V3.sans(13)))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 下一步页下半部：带了对照资料时，核对你说过的数字和事实。
    @ViewBuilder private func factExtra(_ report: JSONValue) -> some View {
        let facts = report["fact_check"]?["items"]?.items ?? []
        if !facts.isEmpty {
            let files = facts.map { $0.text("file_name") }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("对照资料").font(V3.sans(17, weight: .bold))
                    Text(verbatim: "\(files.joined(separator: "、")) · 只核对你说过的数字和事实，不影响分数").font(V3.sans(12.5)).foregroundStyle(RR.mute)
                }.frame(height: 24).padding(.bottom, 6)
                ForEach(Array(facts.prefix(3).enumerated()), id: \.offset) { _, item in
                    let verdict: (String, Color) = ["consistent": ("一致", RR.blue), "conflict": ("冲突", RR.or), "material_stronger": ("资料更强", RR.blue)][item.text("verdict")] ?? ("没找到", MI.gry)
                    HStack(spacing: 16) {
                        Text(verbatim: "你说：\(item.text("claim"))").lineLimit(1).frame(maxWidth: 300, alignment: .leading)
                        Text(verbatim: item.text("quote").isEmpty ? "资料里没有找到相关记录" : "资料：「\(item.text("quote"))」").foregroundStyle(RR.sub).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: verdict.0).font(V3.sans(13.5, weight: .medium)).foregroundStyle(verdict.1).frame(width: 80, alignment: .trailing)
                    }.font(V3.sans(13.5)).frame(minHeight: 44).overlay(alignment: .bottom) { Rectangle().fill(RR.line).frame(height: 1) }
                }
            }
        }
    }

    private func recordPage(_ detail: JSONValue) -> some View {
        let rounds = MockMap.rounds(detail)
        let questions = MockReview.record(detail).map { RecordQuestion(question: $0.question, answer: $0.answer, followUps: $0.followUps.map { RecordQuestion.FollowUp(question: $0.question, answer: $0.answer) }) }
        let finished = detail.text("finished_at").nonEmptyValue ?? detail.text("created_at")
        return GeometryReader { geometry in
            let gutter = V3Page<EmptyView>.gutter(card: geometry.size.width)
            let width = min(max(0, geometry.size.width - gutter * 2), V3Page<EmptyView>.maxWidth(card: geometry.size.width))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        crumb([("模拟面试", home)], current: "面试记录", trailing: [("面试复盘", { reading = false })]).padding(.bottom, 12)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: [detail.text("company_name"), detail.text("job_title").nonEmptyValue ?? detail.text("target_role")].filter { !$0.isEmpty }.joined(separator: " · ")).font(V3.sans(13)).frame(height: 21)
                            Text(verbatim: "\(MockMap.mmddDot(finished)) \(MockMap.typeName(detail))的面试记录").font(V3.serif(30)).frame(height: 42).padding(.bottom, 6)
                            Text(verbatim: [MockMap.diffName[detail.text("difficulty")] ?? "", detail.text("answer_mode") == "voice" ? "语音" : "文字", "\(rounds.count) 道题"].joined(separator: "  ·  "))
                                .font(V3.sans(13)).foregroundStyle(Color(hex: 0x7D7A72)).frame(height: 21)
                        }.padding(.bottom, 26)
                        RecordReaderView(questions: questions, active: $readingAt, proxy: proxy,
                                         missing: { _, position in rounds[safe: position]?.main.text("answer_status") == "skipped" ? "跳过了这道题" : "这道题没有作答" })
                    }
                    .frame(width: width, alignment: .leading).padding(.horizontal, gutter).padding(.top, 104).padding(.bottom, 80)
                }
                .coordinateSpace(name: "record")
                .onPreferenceChange(RecordOffsets.self) { offsets in readingAt = offsets.filter { $0.value <= 60 }.map(\.key).max() ?? 0 }
            }
        }
        .background(.white).foregroundStyle(V3.txt)
    }

    // MARK: 动作

    private func load() async {
        #if DEBUG
        if let file = ProcessInfo.processInfo.environment["DRAWOFFER_MOCK_FIXTURE"], let data = FileManager.default.contents(atPath: file),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) { detail = value["mock_interview"]; return }
        #endif
        do {
            let value = try await session.api.careerRequest(path: "/api/mock-interviews/\(id)", method: "GET", query: [:], body: nil)
            detail = value["mock_interview"]; failed = nil
        } catch { failed = MockInterviewText.error(error) }
    }

    /// 下一场面试：求职进度里这家公司下一场还没开始的面试。
    private func loadNext() async {
        guard let application = detail?.display("job_application_id"), !application.isEmpty else { next = nil; return }
        let now = Date()
        let query = ["status": "scheduled", "start_at": ISO8601DateFormatter().string(from: now), "application_id": application]
        guard let result = try? await session.api.careerRequest(path: "/api/interview-sessions", method: "GET", query: query, body: nil) else { return }
        let first = (result["items"]?.items ?? []).sorted { $0.text("start_at") < $1.text("start_at") }.first
        guard let first, let date = CareerApplication.date(first.text("start_at")) else { next = nil; return }
        let calendar = Beijing.calendar
        let week = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let parts = calendar.dateComponents([.month, .day, .weekday], from: date)
        next = NextInterview(label: first.text("stage_label"), date: String(format: "%02d·%02d ", parts.month ?? 0, parts.day ?? 0) + week[(parts.weekday ?? 1) - 1],
                             days: MockMap.dayDiff(now, date))
    }

    private func focus(_ topic: String?, _ detail: JSONValue) {
        guard let topic, !topic.isEmpty else { return }
        practice(PracticeFocus(kind: "topic", ref: "", label: topic))
    }

    private func runAction(_ action: MockReview.Action, _ detail: JSONValue, _ rows: [MockReview.Row]) {
        if action.kind == "resume" {
            let resume = detail.display("resume_id")
            if resume.isEmpty { router?.jump(.section(.resumes)) } else { router?.jump(.editResume(resume)) }
        } else if action.kind == "material" { router?.jump(.section(.datasets)) }
        else if let first = rows.first(where: { action.refs.contains($0.no) }) { focus(first.round.topic, detail) }
        else { Task { await repeatSession() } }
    }

    private func repeatSession() async {
        guard let detail else { return }
        busy = true
        do {
            let result = try await session.api.careerRequest(path: "/api/mock-interviews/\(detail.display("id"))/repeat", method: "POST", query: [:], body: nil)
            busy = false
            open(result["mock_interview"]?.display("id") ?? "")
        } catch { busy = false; toast = ("没能再练一次", MockInterviewText.error(error), true) }
    }

    private func toggleDone(_ index: Int, _ detail: JSONValue) async {
        let done = Set((detail["done_actions"]?.items ?? []).compactMap(\.integer))
        do {
            let result = try await session.api.careerRequest(path: "/api/mock-interviews/\(detail.display("id"))/actions/\(index)", method: "PUT", query: [:], body: .object(["done": .bool(!done.contains(index))]))
            if let next = result["mock_interview"] { self.detail = next }
        } catch { toast = ("没有保存", MockInterviewText.error(error), true) }
    }

    private func deleteRecordings(_ detail: JSONValue) async {
        busy = true
        defer { busy = false }
        do {
            let result = try await session.api.careerRequest(path: "/api/mock-interviews/\(detail.display("id"))/recordings", method: "DELETE", query: [:], body: nil)
            if let next = result["mock_interview"] { self.detail = next }
            toast = ("本场录音已删除", "识别文字和评估结果都已保留。", false)
        } catch { toast = ("录音没有删除", MockInterviewText.error(error), true) }
    }
}
