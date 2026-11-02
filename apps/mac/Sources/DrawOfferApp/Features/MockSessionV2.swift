import AppKit
import Foundation
import DrawOfferCore
import SwiftUI

/// 面试中（Web `MockInterviewPage` 的 `InterviewRoute`）：按状态分到准备题目、设备检测、文字 / 语音作答和结束页。
/// 面试中是无侧栏的全屏画面；完成后交给报告。
struct MockSessionV2: View {
    @Environment(SessionStore.self) private var session
    let id: String
    let home: () -> Void
    let report: (String) -> Void
    let open: (String) -> Void

    @State private var detail: JSONValue?
    @State private var failed: String?
    @State private var paused = false
    @State private var tick = 0
    @State private var context = MockSessionContext()

    var body: some View {
        Group {
            if let failed, detail == nil {
                VStack(spacing: 10) {
                    Text(failed.contains("不存在") ? "找不到这场模拟面试" : "模拟面试没有加载出来").font(V3.serif(18)).foregroundStyle(MI.ink)
                    Text(verbatim: failed).font(V3.sans(13)).foregroundStyle(MI.sub)
                    Button("返回模拟面试", action: home).buttonStyle(MockButtonStyle())
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
            } else if let detail {
                stage(detail)
            } else {
                Color.white
            }
        }
        .task(id: "\(id)-\(tick)") { await load() }
        .task(id: "\(id)-\(detail?.text("status") ?? "")") { await poll() }
        .task(id: "\(detail?.display("resume_id") ?? "")-\(detail?.display("job_description_id") ?? "")") { await context.load(detail, api: session.api) }
    }

    @ViewBuilder private func stage(_ detail: JSONValue) -> some View {
        let status = detail.text("status")
        let changed = { tick += 1 }
        if status == "completed" {
            Color.white.onAppear { report(detail.display("id")) }
        } else if detail.text("answer_mode") == "voice", ["preparing", "preparation_failed", "in_progress"].contains(status) {
            MockVoiceSession(detail: detail, context: context, changed: changed, home: home, pause: { paused = $0 }).id(detail.display("id"))
        } else if status == "preparing" || status == "preparation_failed" {
            MockPrepStage(detail: detail, context: context, changed: changed, home: home)
        } else if status == "in_progress" {
            MockTextSession(interview: detail, context: context, changed: changed, pause: { paused = $0 }).id(detail.display("id"))
        } else {
            MockClosingStage(detail: detail, context: context, changed: changed, home: home, open: open)
        }
    }

    private func load() async {
        #if DEBUG
        // 本地对照用的只读替身：DRAWOFFER_MOCK_FIXTURE 指向一份虚构场次 JSON，作答页按它排版，不发请求。
        if let file = ProcessInfo.processInfo.environment["DRAWOFFER_MOCK_FIXTURE"], let data = FileManager.default.contents(atPath: file),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) { detail = value["mock_interview"]; return }
        #endif
        do {
            let value = try await session.api.careerRequest(path: "/api/mock-interviews/\(id)", method: "GET", query: [:], body: nil)
            guard !Task.isCancelled else { return }
            detail = value["mock_interview"]; failed = nil
        } catch { if !Task.isCancelled { failed = MockInterviewText.error(error) } }
    }

    /// 准备题目与生成评估由后台任务完成，页面没有推送，2.5 秒轮询一次到状态变化。
    private func poll() async {
        while !Task.isCancelled, ["preparing", "evaluating"].contains(detail?.text("status") ?? "") {
            try? await Task.sleep(for: .milliseconds(2500))
            if Task.isCancelled { return }
            if !paused { await load() }
        }
    }
}

/// `useMapContext`：作答页的图用长期记忆里的点给题找领域，「从简历里来」的题按经历分扇区。
@MainActor @Observable
final class MockSessionContext {
    var points: [MockMap.Point] = []
    var sectors: [MockMap.Sector] = []
    var experienceOf: ((String?) -> String?)?
    private var loadedKey = ""

    func load(_ detail: JSONValue?, api: any APIClient) async {
        guard let detail else { return }
        let job = detail.display("job_description_id"), resume = detail.display("resume_id")
        let key = "\(job)|\(resume)|\(detail.text("interview_type"))"
        guard key != loadedKey else { return }
        loadedKey = key
        async let atlas = try? api.careerRequest(path: "/api/memory/atlas", method: "GET", query: [:], body: nil)
        async let outline = try? api.careerRequest(path: "/api/memory/outline", method: "GET", query: job.isEmpty ? [:] : ["job_id": job], body: nil)
        async let document = resume.isEmpty ? nil : try? api.careerRequest(path: "/api/resumes/\(resume)", method: "GET", query: [:], body: nil)
        let (a, o, r) = await (atlas, outline, document)
        let model = MockMap.homePoints(atlas: a, outline: o, match: nil, type: detail.text("interview_type"))
        points = model.points.map(\.point); sectors = model.sectors
        experienceOf = MockMap.experienceIndex(r?["resume"]?["data"])
    }

    func map(_ detail: JSONValue, current: JSONValue?, phase: MockSession.Phase) -> MockSession.Map {
        MockSession.map(detail, memory: points, memorySectors: sectors, experienceOf: experienceOf, current: current, phase: phase)
    }
}

private func target(_ detail: JSONValue) -> Double { MockMap.diffLevel[detail.text("difficulty")] ?? 3 }
private func now() -> Date { Date() }
private func idempotency() -> JSONValue { .string(UUID().uuidString.lowercased()) }

/// 回合 SSE（Mac 端整段返回）：笔记、面试官的话（delta 拼起来）、语音片段、最后的 turn。
private struct Turn {
    var notes: [(question: String, notes: JSONValue)] = []
    var spoken = ""
    var audio: [JSONValue] = []
    var audioFailed = false
    var recordingDropped = false
    var end: JSONValue?
    init(_ result: JSONValue) {
        let events = result["events"]?.items ?? []
        for event in events {
            let data = event["data"] ?? .null
            switch event.text("event") {
            case "interviewer.notes": notes.append((data.display("question_id"), data["notes"] ?? .array([])))
            case "interviewer.delta": spoken += data.text("content")
            case "interviewer.audio": audio.append(event)
            case "interviewer.audio_failed": audioFailed = true
            case "answer.accepted": if data["recording_dropped"]?.bool == true { recordingDropped = true }
            case "interviewer.turn": end = data
            default: break
            }
        }
    }
    var finished: Bool { end?.text("action") == "finish" || end?["question"] == nil || end?["question"] == .null }
}

private extension JSONValue {
    func replacingQuestions(_ transform: ([JSONValue]) -> [JSONValue]) -> JSONValue {
        guard case .object(var fields) = self else { return self }
        fields["questions"] = .array(transform(self["questions"]?.items ?? []))
        return .object(fields)
    }
    func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = self else { return self }
        fields[key] = value
        return .object(fields)
    }
    func withNotes(_ question: String, _ notes: JSONValue) -> JSONValue {
        replacingQuestions { $0.map { $0.display("id") == question ? $0.setting("notes", notes) : $0 } }
    }
    func appendingTurn(_ end: JSONValue) -> JSONValue {
        guard let next = end["question"], next != .null else { return self }
        let added = (self["questions"]?.items ?? []).contains { $0.display("id") == next.display("id") } ? self : replacingQuestions { $0 + [next] }
        return added.setting("current_question_id", next["id"] ?? .null).setting("needs_reply", .bool(false))
    }
}

/// 场次画面的公共布景：顶栏 + 「这一场」的图 + 地平线。
private struct SessionScene<Left: View, Overlay: View>: View {
    let detail: JSONValue
    let top: SessionTop
    let map: MockSession.Map
    var caption = true
    var labelAll = false
    var listen: MapListen? = nil
    var beadsCurrent: JSONValue? = nil
    var ended = false
    var grey = false
    @ViewBuilder var left: () -> Left
    @ViewBuilder var overlay: () -> Overlay
    var body: some View {
        SessionFrame {
            top
            SessionMapView(map: map, targetLevel: target(detail), caption: caption, labelAll: labelAll, listen: listen)
                .saturation(grey ? 0 : 1).opacity(grey ? 0.55 : 1)
            SessionHorizonView(beads: MockSession.beads(detail, beadsCurrent), introNow: MockSession.introNow(detail, beadsCurrent), ended: ended)
            left()
            overlay()
        }
    }
}

// MARK: 准备题目（Web `PrepStage`）

private let prepStepSeconds = [9.0, 24.0]

struct MockPrepStage: View {
    @Environment(SessionStore.self) private var session
    let detail: JSONValue
    let context: MockSessionContext
    let changed: () -> Void
    let home: () -> Void
    var onCheckDevice: (() -> Void)? = nil
    @State private var busy = false
    @State private var confirm = false
    @State private var toast: (title: String, message: String)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            content(timeline.date)
        }
    }

    private func content(_ date: Date) -> some View {
        let failed = detail.text("status") == "preparation_failed"
        let elapsed = max(0, date.timeIntervalSince(CareerApplication.date(detail.text("created_at")) ?? date))
        let failedStep = ["analysis": 0, "plan": 1, "opening": 2][detail.text("failed_stage")] ?? 1
        let step = failed ? failedStep : elapsed < prepStepSeconds[0] ? 0 : elapsed < prepStepSeconds[1] ? 1 : 2
        let count = detail["question_count"]?.integer ?? 5
        let decided = step == 0 ? 0 : min(count, 1 + Int((elapsed - prepStepSeconds[0]) / 3))
        let failedText = MockInterviewText.messages[detail.text("error_code")] ?? "模型服务暂时没有响应"
        let focus = detail["practice_focus"]?.text("label").nonEmptyValue
        let map = prepMap()
        let analysisSub = "读了 简历「\(detail.text("resume_title"))」" + (detail.text("company_name").nonEmptyValue.map { " · \($0) JD" } ?? "") + (context.points.isEmpty ? "" : " · 长期记忆 \(context.points.count) 个点")
        let steps: [(String, String)] = [
            ("分析简历与岗位背景", failed ? (failedStep == 0 ? "没有完成 · \(failedText)" : "已完成") : analysisSub),
            ("制定考察计划", failed ? (failedStep == 1 ? "没有完成 · \(failedText)" : failedStep > 1 ? "已完成" : "") : step >= 1 ? "已挑 \(decided) / \(count) 个点" + (focus.map { "：先问「\($0)」，再按离目标线的远近排" } ?? "：按离目标线的远近排") : ""),
            ("生成第一道问题", failed && failedStep == 2 ? "没有完成 · \(failedText)" : ""),
        ]
        return SessionScene(detail: detail,
                            top: SessionTop(title: MockSession.heading(detail), sub: MockSession.subtitle(detail), center: failed ? "准备题目" : "准备题目 · \(min(3, step + 1)) / 3", exit: ("退出", home)),
                            map: map, caption: false, labelAll: true) {
            MockPrepColumn {
                MockPrepTitle(title: failed ? "面试官没能准备好题目" : "面试官在读你的简历", sub: failed ? "\(failedText)，这一次没有扣积分。" : "通常 20–40 秒。可以先离开页面，准备好了会提醒你。")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                        let state = failed ? (index < failedStep ? "done" : index == failedStep ? "fail" : "todo") : index < step ? "done" : index == step ? "now" : "todo"
                        MockStepRow(title: item.0, sub: state == "todo" ? "" : item.1, state: state)
                    }
                }.padding(.top, 26)
                if failed {
                    HStack(spacing: 14) {
                        Button(busy ? "正在重新准备…" : "重新准备") { run { _ = try await request("retry") } }.buttonStyle(MockBigButtonStyle()).disabled(busy)
                        Button("返回改设置") { backToSettings() }.buttonStyle(MockQuietStyle(size: 13)).disabled(busy)
                    }.padding(.top, 28)
                } else if detail.text("answer_mode") == "voice", let onCheckDevice {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("趁现在先试一下麦克风").font(V3.sans(13.5, weight: .medium)).foregroundStyle(MI.ink)
                            Text("试完回来，题目也差不多准备好了").font(V3.sans(12)).foregroundStyle(MI.sub)
                        }
                        Spacer()
                        Button("去试一下", action: onCheckDevice).buttonStyle(MockButtonStyle())
                    }
                    .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 14)).frame(width: 432)
                    .background(Color(hex: 0xEEF2FB), in: RoundedRectangle(cornerRadius: 8)).padding(.top, 30)
                }
            }
        } overlay: {
            if !failed {
                SessionBottom(right: "返回改设置", onRight: { confirm = true })
            }
            if confirm {
                MockConfirm(title: "返回修改设置？", desc: "面试官还在准备题目，返回后这场记为已放弃，题目准备不扣积分。", confirm: "返回改设置", cancel: "继续准备",
                            busy: busy, busyLabel: "正在返回…", onConfirm: backToSettings, onCancel: { confirm = false })
            }
            MockToast(toast: $toast)
        }
    }

    private func prepMap() -> MockSession.Map {
        var map = context.map(detail, current: nil, phase: .done)
        let focus = detail["practice_focus"]?.text("label").nonEmptyValue.flatMap { label in map.points.first { $0.name == label } }
        if let focus { map.hot = [focus.id] + map.hot }
        map.now = nil
        return map
    }

    private func request(_ command: String) async throws -> JSONValue {
        try await session.api.careerRequest(path: "/api/mock-interviews/\(detail.display("id"))/\(command)", method: "POST", query: [:], body: nil)
    }
    private func run(_ action: @escaping () async throws -> Void, after: (() -> Void)? = nil) {
        busy = true
        Task {
            do { try await action(); after?(); changed() } catch { toast = ("操作没有完成", MockInterviewText.error(error)) }
            busy = false
        }
    }
    private func backToSettings() { run({ _ = try await request("abandon") }, after: { confirm = false; home() }) }
}

/// `.mi2-step`：准备题目的一步（完成打勾、进行中虚线转圈、失败感叹号）。
struct MockStepRow: View {
    let title: String
    let sub: String
    let state: String
    @State private var spin = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                switch state {
                case "done":
                    Circle().fill(MI.blue)
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                case "fail":
                    Circle().fill(MI.orange)
                    Text("!").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                case "now":
                    Circle().stroke(MI.blue, style: StrokeStyle(lineWidth: 1.6, dash: [3, 2])).rotationEffect(.degrees(spin ? 360 : 0))
                        .onAppear { withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { spin = true } }
                default:
                    Circle().stroke(Color(hex: 0xC5C1B6), lineWidth: 1.3)
                }
            }.frame(width: 16, height: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title).font(V3.sans(14, weight: .medium)).foregroundStyle(state == "todo" ? MI.gry : MI.ink).frame(height: 14 * 1.45)
                if !sub.isEmpty { Text(verbatim: sub).font(V3.sans(12)).foregroundStyle(state == "fail" ? MI.orange : MI.mute).lineSpacing(12 * 0.3).fixedSize(horizontal: false, vertical: true) }
            }
        }.frame(minHeight: 64, alignment: .topLeading)
    }
}

// MARK: 结束（Web `ClosingStage`）

struct MockClosingStage: View {
    @Environment(SessionStore.self) private var session
    let detail: JSONValue
    let context: MockSessionContext
    let changed: () -> Void
    let home: () -> Void
    let open: (String) -> Void
    @State private var busy = false
    @State private var toast: (title: String, message: String)?

    var body: some View {
        let failed = detail.text("status") == "evaluation_failed"
        let abandoned = detail.text("status") == "abandoned"
        let map = context.map(detail, current: nil, phase: .done)
        let follows = (detail["questions"]?.items ?? []).filter { $0.text("kind") == "follow_up" }.count
        let points = map.rounds.reduce(0) { $0 + MockSession.notes($1).count }
        let started = CareerApplication.date(detail.text("started_at")) ?? CareerApplication.date(detail.text("created_at"))
        let voice = detail.text("answer_mode") == "voice"
        SessionScene(detail: detail,
                     top: SessionTop(title: MockSession.heading(detail), sub: MockSession.subtitle(detail), center: abandoned ? "已放弃" : failed ? "评估没完成" : "已结束",
                                     started: started, ended: CareerApplication.date(detail.text("finished_at")) ?? Date(), timerLive: false),
                     map: map, caption: false, ended: true, grey: abandoned) {
            MockPrepColumn {
                if abandoned {
                    MockPrepTitle(title: "这场模拟面试已放弃", size: 30, sub: "没有生成报告\(voice ? "，录音已删除" : "")。")
                    HStack(spacing: 14) {
                        Button(busy ? "正在准备…" : "用同样设置重新开始") { restart() }.buttonStyle(MockBigButtonStyle()).disabled(busy)
                        Button("返回模拟面试", action: home).buttonStyle(MockQuietStyle(size: 13))
                    }.padding(.top, 34)
                } else if failed {
                    MockPrepTitle(title: "评估报告没能生成", size: 30, sub: "作答\(voice ? "和录音" : "")都保存了，重新评估不另扣积分。")
                    HStack(spacing: 14) {
                        Button(busy ? "正在重新评估…" : "重新评估") { retry() }.buttonStyle(MockBigButtonStyle()).disabled(busy)
                        Button("返回模拟面试", action: home).buttonStyle(MockQuietStyle(size: 13))
                    }.padding(.top, 34)
                } else {
                    MockPrepTitle(title: "面试结束，辛苦了", size: 30, sub: "面试官在把笔记整理成评估报告。")
                    MockSpinLine(text: "正在整理报告 · 约 1 分钟").padding(.top, 46)
                    HStack(spacing: 70) {
                        stat("\(map.rounds.count)", "主问题"); stat("\(follows)", "次追问"); stat("\(points)", "条要点")
                    }.padding(.top, 36)
                    Button("先去忙，好了提醒我", action: home).buttonStyle(MockButtonStyle()).padding(.top, 40)
                    // `.mi2-prep > p` 比 `.mi2-foot-note` 更具体：13px、#5f5d57
                    Text("报告好了会出现在模拟面试首页的地平线上").font(V3.sans(13)).foregroundStyle(MI.sub).frame(height: 20).padding(.top, 8)
                }
            }
        } overlay: { MockToast(toast: $toast) }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: value).font(.system(size: 26, weight: .medium).monospacedDigit()).foregroundStyle(MI.ink).frame(height: 22)
            Text(verbatim: label).font(V3.sans(11.5)).foregroundStyle(MI.mute).frame(height: 22)
        }
    }
    private func command(_ name: String) async throws -> JSONValue {
        try await session.api.careerRequest(path: "/api/mock-interviews/\(detail.display("id"))/\(name)", method: "POST", query: [:], body: nil)
    }
    private func retry() {
        busy = true
        Task { do { _ = try await command("retry"); changed() } catch { toast = ("操作没有完成", MockInterviewText.error(error)) }; busy = false }
    }
    private func restart() {
        busy = true
        Task { do { open(try await command("repeat")["mock_interview"]?.display("id") ?? "") } catch { toast = ("操作没有完成", MockInterviewText.error(error)) }; busy = false }
    }
}

/// `.mi2-spin-line`：橙色虚线小圈慢慢转。
struct MockSpinLine: View {
    let text: String
    @State private var spin = false
    var body: some View {
        HStack(spacing: 8) {
            Circle().stroke(MI.orange, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2])).frame(width: 12, height: 12).rotationEffect(.degrees(spin ? 360 : 0))
                .onAppear { withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { spin = true } }
            Text(verbatim: text).font(V3.sans(12)).foregroundStyle(MI.mute)
        }.frame(height: 28).accessibilityElement(children: .combine)
    }
}

// MARK: 文字面试（Web `TextSessionV2`）

private let typeInterval = Duration.milliseconds(40)
private let maxAnswer = 8000
private let saidHeight: CGFloat = 194

struct MockTextSession: View {
    @Environment(SessionStore.self) private var session
    let interview: JSONValue
    let context: MockSessionContext
    let changed: () -> Void
    let pause: (Bool) -> Void

    private enum Phase { case answer, sent, asking, closing }
    @State private var detail: JSONValue = .null
    @State private var phase: Phase = .answer
    @State private var draft = ""
    @State private var beat = 0
    @State private var beatAt = Date.distantPast
    @State private var sent: String?
    @State private var askText = ""
    @State private var shown = Int.max
    @State private var dialog: String?
    @State private var busy: String?
    @State private var drawer = false
    @State private var toast: (title: String, message: String)?
    @State private var turnReady = false
    @State private var voiceInput = VoiceRecorder()
    @State private var speechSessionID: String?
    @State private var voiceFailed = false
    @FocusState private var focused: Bool

    private var question: JSONValue? { MockSession.current(detail) }
    private var needsReply: Bool { detail["needs_reply"]?.bool == true && phase == .answer }
    private var locked: Bool { phase != .answer || question == nil || needsReply || busy != nil }

    var body: some View {
        let shownQuestion = question ?? MockSession.lastAsked(detail)
        let follow = shownQuestion?.text("kind") == "follow_up"
        let intro = shownQuestion.map { $0.text("anchor_kind") == "intro" || MockMap.isIntro(detail, $0) } ?? false
        let typing = !locked && !draft.isEmpty
        let mapPhase: MockSession.Phase = phase == .sent ? .thinking : phase == .closing ? .done : typing ? .answering : .asking
        let map = context.map(detail, current: shownQuestion, phase: mapPhase)
        let round = MockSession.roundOf(detail, shownQuestion)
        let chip = MockSession.sourceChip(shownQuestion)
        let speaking = phase == .asking || phase == .closing
        let text = speaking ? askText : shownQuestion?.text("content") ?? ""
        let roundIndex = map.rounds.firstIndex { $0.main.display("id") == round?.main.display("id") } ?? -1
        let previous = shownQuestion?.text("kind") == "main" && roundIndex > 0 && phase != .answer ? map.rounds[roundIndex - 1] : nil
        let lastAnswered = (detail["questions"]?.items ?? []).filter { $0.text("answer_status") == "answered" }.max { ($0["sequence_no"]?.numberValue ?? 0) < ($1["sequence_no"]?.numberValue ?? 0) }
        let status: (String, MockTone) = phase == .sent ? (needsReply ? "面试官的回复没生成" : "等面试官回复", .sub)
            : phase == .asking ? ("面试官在提问", .sub) : phase == .closing ? ("面试官在说结束语", .sub)
            : voiceInput.phase == .recording ? ("正在听 · 再点一下停止", .blue)
            : needsReply ? ("等面试官回复", .or) : ("打字作答，发送前可以修改", .sub)
        let count = draft.count
        SessionScene(detail: detail,
                     top: SessionTop(title: MockSession.heading(detail), sub: MockSession.subtitle(detail),
                                     center: phase == .closing ? "\(detail["question_count"]?.integer ?? 0) / \(detail["question_count"]?.integer ?? 0) 题 · 全部完成" : MockSession.progress(detail, shownQuestion),
                                     started: CareerApplication.date(detail.text("started_at")), timerLive: phase != .closing,
                                     onAbandon: { dialog = "abandon" }, onFinish: { dialog = "finish" }, finishDisabled: phase == .sent, busy: busy != nil || phase == .closing),
                     map: map, listen: phase == .answer && !needsReply ? .typing(beat) : nil, beadsCurrent: shownQuestion, ended: phase == .closing) {
            VStack(alignment: .leading, spacing: 0) {
                if let previous {
                    (Text(verbatim: "上一题 · \(previous.topic)").foregroundColor(MI.mute).font(V3.sans(11))
                     + Text(verbatim: "  " + (previous.skipped ? "跳过了" : "追问 \(previous.turns.count - 1) 次 · 答到「\(MockMap.levelName(previous.to))」")).foregroundColor(MI.blue).font(V3.sans(10.5, weight: .medium)))
                        .frame(height: 22).padding(.bottom, 14)
                }
                if let chip, !follow { MockSourceChip(label: chip.label, quote: chip.quote).padding(.bottom, 14) }
                MockSpeaker(you: false, text: phase == .closing ? "结束语" : phase == .sent ? "在想下一句" : follow ? "追问" : intro ? "正在说" : "提问", live: speaking).padding(.bottom, 10)
                MockQuestionText(text: text, quote: follow ? shownQuestion?.text("source_quote") : shownQuestion?.text("anchor"), shown: speaking ? shown : .max, size: 22, line: 33)
                if follow, phase != .answer, shownQuestion?.text("source_quote").nonEmptyValue != nil {
                    Text("↳ 追问来自你刚才写的原话").font(V3.sans(11.5)).foregroundStyle(MI.blue).padding(.top, 10)
                }
                if phase == .sent, let sent {
                    MockSpeaker(you: true, text: sent.isEmpty ? "跳过了这道题" : "已发送", tone: .gry).padding(.top, 34).padding(.bottom, 10)
                    if !sent.isEmpty { MockTranscript(height: saidHeight, follow: false, card: true) { MockSaid(text: sent, past: true) } }
                }
                if phase == .answer && needsReply {
                    if let answer = lastAnswered?.text("answer_text").nonEmptyValue {
                        MockSpeaker(you: true, text: "已发送", tone: .gry).padding(.top, 34).padding(.bottom, 10)
                        MockTranscript(height: saidHeight, follow: false, card: true) { MockSaid(text: answer, past: true) }
                    }
                    MockAlert(title: "面试官的回复没生成", sub: "你的回答已经保存") {
                        Button(busy == "send" ? "正在生成…" : "重新生成") { regenerate(lastAnswered?.text("answer_text") ?? "") }.buttonStyle(MockButtonStyle()).disabled(busy != nil)
                    }
                }
                if phase == .answer && !needsReply { answerArea(count) }
                if !intro { MockNotesBox(notes: MockSession.notes(round), width: 300) }
            }
            .frame(width: 680, alignment: .leading).offset(x: 56, y: 96)
        } overlay: {
            if phase != .closing {
                SessionBottom(left: "跳过此题", onLeft: { dialog = "skip" }, leftDisabled: locked, status: status.0, statusTone: status.1,
                              dot: status.1 == .or ? MI.orange : status.1 == .blue ? MI.blue : nil, right: "对话记录", onRight: { withAnimation(.easeOut(duration: 0.22)) { drawer = true } })
            }
            if drawer { MockConversationDrawer(detail: detail, currentID: shownQuestion?.display("id"), close: { drawer = false }) }
            dialogs
            MockToast(toast: $toast)
        }
        .onAppear { if detail == .null { detail = interview } }
        .onChange(of: interview) { _, value in if phase != .sent { detail = value } }
        .task(id: "\(phase)-\(askText.count)-\(shown)") { await typeAhead() }
        .onChange(of: locked, initial: true) { _, value in if !value { focused = true } }
    }

    private func answerArea(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("你 的 回 答").font(V3.sans(10.5)).tracking(2.1).foregroundStyle(MI.mute).frame(height: 22).padding(.top, 34).padding(.bottom, 10)
            ZStack(alignment: .topLeading) {
                TextEditor(text: voiceInput.phase == .recording && !voiceInput.partial.isEmpty ? .constant(draft + voiceInput.partial) : $draft)
                    .font(V3.sans(15)).lineSpacing(28 - 15 * 1.2).scrollContentBackground(.hidden).foregroundStyle(MI.ink)
                    .focused($focused).disabled(locked).accessibilityLabel("你的回答")
                    .onChange(of: draft) { _, value in
                        if value.count > maxAnswer { draft = String(value.prefix(maxAnswer)) }
                        if Date().timeIntervalSince(beatAt) > 0.35 { beatAt = Date(); beat += 1 }
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        send(); return .handled
                    }
                if draft.isEmpty {
                    Text("输入你的回答…").font(V3.sans(15)).foregroundStyle(Color(hex: 0xC5C1B6)).padding(.leading, 5).allowsHitTesting(false)
                }
            }.frame(height: 155)
            HStack(spacing: 14) {
                voiceButton
                Spacer()
                Text(verbatim: (count > 0 ? "\(count) 字 · " : "") + "Enter 发送，Shift + Enter 换行").font(V3.sans(11)).foregroundStyle(MI.mute)
                let ready = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !locked
                Button("发送", action: send).buttonStyle(MockButtonStyle(kind: ready ? .dark : .off)).disabled(!ready)
            }
            .padding(.top, 10).overlay(alignment: .top) { Rectangle().fill(MI.ink).frame(height: 1) }
        }.frame(width: 652)
    }

    /// 作答区工具行的「语音输入」（Web `VoiceInputButton variant="plain"`）：说的话转成文字落进作答区，发送时带上识别会话。
    private var voiceButton: some View {
        let recording = voiceInput.phase == .recording
        let label = recording ? "正在听 · 再点一下停止" : voiceInput.phase == .finishing || voiceInput.phase == .connecting ? "正在识别…" : voiceFailed ? "没听清，再试一次" : "语音输入"
        return Button {
            if recording { stopVoice() }
            else if let question { voiceFailed = false; Task { await voiceInput.start(api: session.api, interviewID: detail.display("id"), questionID: question.display("id"), purpose: "voice_input") } }
        } label: {
            HStack(spacing: 6) {
                if recording { Circle().fill(MI.blue).frame(width: 7, height: 7).modifier(MockPulse()) } else { Image(systemName: "mic").font(.system(size: 12)) }
                Text(verbatim: label)
            }.font(V3.sans(12.5)).foregroundStyle(recording ? MI.blue : MI.sub)
        }
        .buttonStyle(.plain).disabled(!recording && (locked || voiceInput.phase == .finishing || voiceInput.phase == .connecting))
        .accessibilityLabel(recording ? "停止录音" : "语音输入")
        .onChange(of: question?.display("id")) { voiceInput.cancel(); voiceFailed = false }
        .onChange(of: voiceInput.phase) { _, value in if case .failed = value { voiceFailed = true } }
        .onExitCommand { if recording { voiceInput.cancel() } }
        .onDisappear { voiceInput.cancel() }
    }

    private func stopVoice() {
        Task {
            do {
                let result = try await voiceInput.stop()
                draft = draft.isEmpty ? result.text : draft + result.text
                speechSessionID = result.sessionID
            } catch { voiceFailed = true }
        }
    }

    @ViewBuilder private var dialogs: some View {
        if dialog == "skip" {
            MockConfirm(title: "跳过这道题？", desc: "跳过的部分记为没答，面试官会换下一个考点；前面已经答的照常评分。", confirm: "跳过此题",
                        busy: busy == "skip", busyLabel: "正在跳过…", onConfirm: skip, onCancel: { dialog = nil })
        } else if dialog == "finish" {
            MockConfirm(title: "结束并生成评估？", desc: MockSession.hasAnswered(detail) ? "已作答的题目会进入评估，后面没问到的题不扣分。" : "你还没有回答任何考点，结束后这场记为已放弃，不生成报告。",
                        confirm: "结束并评估", busy: busy == "finish", busyLabel: "正在结束…", onConfirm: { end("finish") }, onCancel: { dialog = nil }) {
                MockFinishStats(detail: detail, elapsed: MockSession.mmss(Date().timeIntervalSince(CareerApplication.date(detail.text("started_at")) ?? Date())))
            }
        } else if dialog == "abandon" {
            MockConfirm(title: "放弃这场文字面试？", desc: "已作答的内容不会生成评估报告。放弃后可以重新开始一场。", confirm: "放弃面试", cancel: "继续面试", danger: true,
                        busy: busy == "abandon", busyLabel: "正在放弃…", onConfirm: { end("abandon") }, onCancel: { dialog = nil })
        }
    }

    /// 面试官逐字「打」出来（一次两个字），打完后回到作答；结束语打完交给结束页。
    private func typeAhead() async {
        guard phase == .asking || phase == .closing else { return }
        if shown < askText.count {
            try? await Task.sleep(for: typeInterval)
            if !Task.isCancelled { shown += 2 }
            return
        }
        if phase == .asking && turnReady {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { phase = .answer; askText = ""; shown = .max; turnReady = false }
        }
    }

    private func path(_ command: String) -> String { "/api/mock-interviews/\(detail.display("id"))/\(command)" }

    private func consume(_ command: String, body: JSONValue?, answered: String?, sentText: String?) async {
        phase = .sent; sent = sentText; turnReady = false; pause(true)
        do {
            let turn = Turn(try await session.api.careerRequest(path: path(command), method: "POST", query: [:], body: body))
            if let answered, let id = body?.display("question_id") {
                detail = detail.replacingQuestions { $0.map { $0.display("id") == id ? $0.setting("answer_status", .string("answered")).setting("answer_text", .string(answered)) : $0 } }
            }
            for item in turn.notes { detail = detail.withNotes(item.question, item.notes) }
            guard let end = turn.end else { throw APIError.server(status: 502, code: "MOCK_INTERVIEW_TURN_FAILED") }
            if turn.finished {
                askText = turn.spoken.nonEmptyValue ?? end.text("closing_message").nonEmptyValue ?? "今天的面试就到这里，感谢你的时间。"
                shown = 0; phase = .closing
                try? await Task.sleep(for: .seconds(2.4))
                pause(false); changed()
                return
            }
            detail = detail.appendingTurn(end)
            askText = turn.spoken.nonEmptyValue ?? end["question"]?.text("content") ?? ""
            shown = 0; phase = .asking; sent = nil; turnReady = true
        } catch {
            toast = (answered == nil && sentText == nil ? "没能跳过此题" : "回答没有提交成功", MockInterviewText.error(error))
            if let answered { draft = answered }
            sent = nil; askText = ""; phase = .answer
        }
        pause(false); changed()
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let question, !text.isEmpty, !locked else { return }
        busy = "send"; draft = ""
        var body: [String: JSONValue] = ["question_id": question["id"] ?? .null, "answer": .string(text), "__idempotency_key": idempotency()]
        if let speechSessionID { body["speech_session_id"] = .string(speechSessionID) }
        speechSessionID = nil
        Task {
            await consume("answers", body: .object(body), answered: text, sentText: text)
            busy = nil
        }
    }
    private func skip() {
        guard let question else { return }
        dialog = nil; busy = "skip"
        Task {
            await consume("skip", body: .object(["question_id": question["id"] ?? .null, "__idempotency_key": idempotency()]), answered: nil, sentText: nil)
            busy = nil
        }
    }
    private func regenerate(_ last: String) {
        busy = "send"
        Task { await consume("reply:retry", body: nil, answered: nil, sentText: last); busy = nil }
    }
    private func end(_ kind: String) {
        busy = kind
        Task {
            do { _ = try await session.api.careerRequest(path: path(kind), method: "POST", query: [:], body: nil); dialog = nil; changed() }
            catch { toast = ("操作没有完成", MockInterviewText.error(error)) }
            busy = nil
        }
    }
}
