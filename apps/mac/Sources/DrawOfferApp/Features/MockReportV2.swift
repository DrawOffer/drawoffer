import DrawOfferCore
import SwiftUI

/// 面试复盘（模拟面试这一边，Figma 09 · 10 复盘 10.01–10.09、11 记忆变化状态；Web `mock-interview/v2/ReportV2.tsx`）：
/// 评估报告转成统一结构（`MockRV`）交给总览、单题详情、面试记录三页，再接上模拟面试才有的东西：
/// 回放录音、修改识别稿后重新评分、判得不对、删除录音、练这几题 / 练这一处。
struct MockReportV2: View {
    @Environment(SessionStore.self) private var session
    let id: String
    let home: () -> Void
    let records: () -> Void
    let practice: (PracticeFocus) -> Void
    let open: (String) -> Void
    var changed: () -> Void = {}
    /// 「练这 N 道」「练这一处」：带着题目进面试设置（Figma 09 · 02 配置页的练习卡）。
    var practicePlan: (MockPracticePlan) -> Void = { _ in }

    private static let maxReEvaluate = 3

    @State private var detail: JSONValue?
    @State private var context: JSONValue?
    @State private var failed: String?
    @State private var question: String?
    @State private var reading: (at: String?, on: Bool) = (nil, false)
    @State private var judging: MockRV.Question?
    @State private var editing: MockRV.Question?
    @State private var removing = false
    @State private var saving = false
    @State private var busy = false
    @State private var notice: MockNotice?
    @State private var next: NextInterview?
    @State private var player = InterviewerVoice()
    @State private var playing: String?

    var body: some View {
        Group {
            if let detail, let view = MockRV.view(detail, context: context) {
                content(detail, view)
            } else if let detail {
                VStack(spacing: 12) {
                    Text("这场还没有评估报告").font(V3.serif(22)).foregroundStyle(MockPalette.ink)
                    Button("刷新") { self.detail = nil; Task { await load() } }.buttonStyle(MockPillStyle(kind: .ghost))
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white).id(detail.display("id"))
            } else if let failed {
                VStack(spacing: 10) {
                    Text(failed.contains("不存在") ? "找不到这场模拟面试" : "模拟面试没有加载出来").font(V3.serif(22)).foregroundStyle(MockPalette.ink)
                    Text(verbatim: failed).font(V3.sans(13)).foregroundStyle(MockPalette.sub)
                    Button("返回模拟面试", action: home).buttonStyle(MockPillStyle()).padding(.top, 6)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
            } else { V3Loading("正在打开复盘…").frame(maxWidth: .infinity, maxHeight: .infinity).background(.white) }
        }
        .overlay { MockNoticeToast(notice: $notice) }
        .task(id: id) { await load() }
        .task(id: "\(id)-\(detail?["report"]?["total_score"]?.numberValue ?? -1)") { await loadContext() }
        .task(id: detail?.display("job_application_id") ?? "") { await loadNext() }
        .onDisappear { player.stop() }
        .centeredSheet(item: $judging) { item in
            MockJudgeDialog(question: item, busy: saving, save: { depth in Task { await saveJudge(item, depth) } }, close: { judging = nil })
        }
        .centeredSheet(item: $editing) { item in
            MockEditDialog(question: item, remaining: remaining(item), busy: saving, save: { drafts in Task { await saveEdit(item, drafts) } }, close: { editing = nil })
        }
        .centeredSheet(isPresented: $removing) {
            MockConfirmCard(title: "删除本场录音？", desc: "录音删除后不能恢复，识别文字和评估结果都会保留。", confirm: "删除录音", busy: saving, busyLabel: "正在删除…",
                            onConfirm: { Task { await removeRecordings() } }, onCancel: { removing = false })
        }
    }

    @ViewBuilder private func content(_ detail: JSONValue, _ view: MockRV.View) -> some View {
        let focus = MockRV.suggestions(view.questions)
        let deleted = detail["recordings_deleted"]?.bool == true
        let hasRecording = { (q: MockRV.Question) in !deleted && q.turns.contains(where: \.hasRecording) }
        let canEdit = { (q: MockRV.Question) in !deleted && q.turns.contains(where: \.editable) }
        let anyRecording = detail.text("answer_mode") == "voice" && view.questions.contains(where: hasRecording)
        if reading.on {
            MockReviewRecord(view: view, initial: reading.at, playing: playing, play: deleted ? nil : { toggle($0, detail) }) {
                MockBackCrumb(label: view.title) { reading = (nil, false) }
            }
        } else if let question, let index = view.questions.firstIndex(where: { $0.id == question }) {
            let current = view.questions[index]
            MockQuestionDetail(question: current, total: view.questions.count, prev: view.questions[safe: index - 1], next: view.questions[safe: index + 1],
                               open: { self.question = $0 }, practice: { start([$0], detail, view) }, record: { reading = ($0.id, true) },
                               judge: current.level != nil ? { judging = $0 } : nil,
                               edit: canEdit(current) ? { editing = $0 } : nil,
                               play: hasRecording(current) ? { toggle($0, detail) } : nil,
                               playing: playing == current.id) {
                MockBackCrumb(label: view.title) { self.question = nil }
            }
            .id(current.id)
        } else {
            MockReviewOverview(view: view, next: next, open: { question = $0 }, practice: { start($0, detail, view) }) {
                MockBackCrumb(label: "全部记录", action: records)
            } actions: {
                Button("翻看面试记录") { reading = (nil, true) }.buttonStyle(MockPillStyle(kind: .ghost, height: 40, padding: 20))
                if !focus.isEmpty {
                    Button("练这 \(focus.count) 道") { start(focus, detail, view) }.buttonStyle(MockPillStyle(height: 40, padding: 20))
                } else {
                    Button(busy ? "正在准备…" : "再练一次") { Task { await repeatSession() } }.buttonStyle(MockPillStyle(height: 40, padding: 20)).disabled(busy)
                }
            } memory: {
                RRMemorySection(mockID: detail.display("id"), pastCount: view.pastCount) { target in
                    practice(PracticeFocus(kind: target.text("kind").nonEmptyValue ?? "topic", ref: target.text("ref"), label: target.text("label")))
                }
            } footnote: {
                if anyRecording { Button("删除本场录音") { removing = true }.buttonStyle(MockLinkStyle(blue: true, size: 12)) }
            }
        }
    }

    // MARK: 动作

    private func start(_ questions: [MockRV.Question], _ detail: JSONValue, _ view: MockRV.View) {
        guard !questions.isEmpty else { return }
        practicePlan(MockPracticePlan(back: view.title, items: questions.prefix(3).map(MockRV.practiceItem),
                                      applicationID: detail.display("job_application_id").nonEmptyValue,
                                      interviewType: detail.text("interview_type").nonEmptyValue, difficulty: detail.text("difficulty").nonEmptyValue,
                                      mode: detail.text("answer_mode").nonEmptyValue, resumeID: detail.display("resume_id").nonEmptyValue))
    }

    private func remaining(_ item: MockRV.Question) -> Int { max(0, Self.maxReEvaluate - item.reEvaluated) }

    private func call(_ path: String, _ method: String = "POST", _ body: JSONValue? = nil) async throws -> JSONValue {
        try await session.api.careerRequest(path: "/api/mock-interviews/\(id)\(path)", method: method, query: [:], body: body)
    }

    private func load() async {
        #if DEBUG
        if let file = ProcessInfo.processInfo.environment["DRAWOFFER_MOCK_FIXTURE"], let data = FileManager.default.contents(atPath: file),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) { detail = value["mock_interview"]; return }
        #endif
        do { detail = try await call("", "GET")["mock_interview"]; failed = nil } catch { failed = MockInterviewText.error(error) }
    }

    /// 「和以往比」的数据；拿不到时报告照常，只是不写以往。
    private func loadContext() async {
        guard detail != nil else { return }
        context = try? await session.api.careerRequest(path: "/api/mock-interviews/review-context", method: "GET", query: ["kind": "mock", "id": id], body: nil)
    }

    private func loadNext() async {
        guard let application = detail?.display("job_application_id"), !application.isEmpty else { next = nil; return }
        let now = Date()
        let query = ["status": "scheduled", "start_at": ISO8601DateFormatter().string(from: now), "application_id": application]
        guard let result = try? await session.api.careerRequest(path: "/api/interview-sessions", method: "GET", query: query, body: nil) else { return }
        guard let first = (result["items"]?.items ?? []).sorted(by: { $0.text("start_at") < $1.text("start_at") }).first,
              let date = CareerApplication.date(first.text("start_at")) else { next = nil; return }
        let parts = Beijing.calendar.dateComponents([.month, .day], from: date)
        next = NextInterview(label: first.text("stage_label"), date: String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0), days: MockMap.dayDiff(now, date))
    }

    private func toggle(_ item: MockRV.Question, _ detail: JSONValue) {
        if playing == item.id { player.stop(); playing = nil; return }
        guard let turn = item.turns.first(where: \.hasRecording) else { return }
        player.stop(); playing = item.id
        Task {
            do {
                // 一题的几轮回答按顺序接着放
                for part in item.turns where part.hasRecording {
                    let audio = try await session.api.mockAudio(path: "/api/mock-interviews/\(detail.display("id"))/questions/\(part.id)/recording", method: "GET", body: nil)
                    if playing != item.id { return }
                    player.play(audio)
                }
                _ = turn
                while player.playing && playing == item.id { try? await Task.sleep(for: .milliseconds(250)) }
                if playing == item.id { playing = nil }
            } catch { playing = nil; notice = MockNotice(title: "这段录音放不了", message: MockInterviewText.error(error)) }
        }
    }

    private func repeatSession() async {
        busy = true
        do { let result = try await call("/repeat"); busy = false; open(result["mock_interview"]?.display("id") ?? "") }
        catch { busy = false; notice = MockNotice(title: "没能再练一次", message: MockInterviewText.error(error)) }
    }

    private func saveJudge(_ item: MockRV.Question, _ depth: Int?) async {
        saving = true
        defer { saving = false }
        do {
            let result = try await call("/questions/\(item.id)/judgement", "PUT", .object(["user_depth": depth.map { .number(Double($0)) } ?? .null]))
            if let next = result["mock_interview"] { detail = next; changed() }
            judging = nil
        } catch { notice = MockNotice(title: "没有保存", message: MockInterviewText.error(error)) }
    }

    private func saveEdit(_ item: MockRV.Question, _ drafts: [String: String]) async {
        saving = true
        defer { saving = false }
        do {
            var latest: JSONValue?
            for turn in item.turns where turn.editable {
                guard let draft = drafts[turn.id], draft != (turn.answer ?? "") else { continue }
                latest = try await call("/questions/\(turn.id)/transcript", "PUT", .object(["text": .string(draft)]))["mock_interview"]
            }
            if let latest {
                detail = latest
                if remaining(item) > 0 {
                    let result = try await call("/questions/\(item.id)/re-evaluate")
                    if let next = result["mock_interview"] { detail = next }
                    notice = MockNotice(kind: .success, title: "已保存并重新评分这一题", message: "还剩 \(result["remaining"]?.integer ?? 0) 次 · 不另扣积分")
                }
                changed()
            }
            editing = nil
        } catch { notice = MockNotice(title: "识别稿没有保存", message: MockInterviewText.error(error)) }
    }

    private func removeRecordings() async {
        saving = true
        defer { saving = false }
        do {
            let result = try await call("/recordings", "DELETE")
            if let next = result["mock_interview"] { detail = next }
            removing = false; player.stop(); playing = nil
            notice = MockNotice(kind: .success, title: "本场录音已删除", message: "识别文字和评估结果都已保留。")
        } catch { notice = MockNotice(title: "录音没有删除", message: MockInterviewText.error(error)) }
    }
}
