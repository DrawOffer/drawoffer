import AppKit
import Foundation
import DrawOfferCore
import SwiftUI

/// 面试中（Figma 09 · 03–07；Web `MockInterviewPage` 的 `InterviewRoute`）：按状态分到准备题目、设备检测、文字 / 语音作答和结束页。
/// 面试中是无侧栏的全屏画面；完成后交给复盘。
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

    var body: some View {
        Group {
            if let failed, detail == nil {
                VStack(spacing: 10) {
                    Text(failed.contains("不存在") ? "找不到这场模拟面试" : "模拟面试没有加载出来").font(V3.serif(22)).foregroundStyle(MockPalette.ink)
                    Text(verbatim: failed).font(V3.sans(13)).foregroundStyle(MockPalette.sub)
                    Button("返回模拟面试", action: home).buttonStyle(MockPillStyle()).padding(.top, 6)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
            } else if let detail {
                stage(detail)
            } else {
                Color.white
            }
        }
        .task(id: "\(id)-\(tick)") { await load() }
        .task(id: "\(id)-\(detail?.text("status") ?? "")") { await poll() }
    }

    @ViewBuilder private func stage(_ detail: JSONValue) -> some View {
        let status = detail.text("status")
        let changed = { tick += 1 }
        if status == "completed" {
            Color.white.onAppear { report(detail.display("id")) }
        } else if detail.text("answer_mode") == "voice", ["preparing", "preparation_failed", "in_progress"].contains(status) {
            MockVoiceSession(detail: detail, changed: changed, home: home, pause: { paused = $0 }).id(detail.display("id"))
        } else if status == "preparing" || status == "preparation_failed" {
            MockPrepStage(detail: detail, changed: changed, home: home)
        } else if status == "in_progress" {
            MockTextSession(interview: detail, changed: changed, pause: { paused = $0 }).id(detail.display("id"))
        } else {
            MockClosingStage(detail: detail, changed: changed, home: home, open: open)
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

// MARK: 准备题目（Figma 09 · 03 开始前 03.01–03.02、04 选题动效；Web `PrepStage`）

struct MockPrepStage: View {
    @Environment(SessionStore.self) private var session
    let detail: JSONValue
    let changed: () -> Void
    let home: () -> Void
    var onCheckDevice: (() -> Void)? = nil
    @State private var busy = false
    @State private var dialog: String?
    @State private var notice: MockNotice?
    @State private var lineStart = Date()

    private static let titles = ["面试官在读你的简历", "从题库里为你挑题", "第一道问题快好了"]
    private static let pace = ["quiet": "只挑最影响通过的点，不再试探新点", "near": "先补短板，顺带确认几处拿不准的",
                               "far": "先摸清你还拿不准的点，再集中补短板", "none": "还没有约面试，按两周的节奏：先摸清你还拿不准的点"]

    private var prep: JSONValue? { detail["prep"].flatMap { $0 == .null ? nil : $0 } }
    private var failed: Bool { detail.text("status") == "preparation_failed" }
    private var step: Int {
        if failed, let stage = ["analysis": 0, "plan": 1, "opening": 2][detail.text("failed_stage")] { return stage }
        guard let prep else { return 0 }
        return prep.text("stage") == "select" ? 1 : 2
    }
    private var hasJob: Bool { !detail.text("job_title").isEmpty || !detail.text("company_name").isEmpty }

    var body: some View {
        let failedText = MockInterviewText.messages[detail.text("error_code")] ?? "模型服务暂时没有响应"
        MockSessionFrame {
            MockSessionHead(detail: detail, back: ("面试设置", busy, { if failed { backToSettings() } else { dialog = "back" } }))
            MockCenterLine(text: "准备题目 · \(step + 1) / 3", top: 114)
            MockCenterLine(text: failed ? "面试官没能准备好题目" : Self.titles[step], top: 138, size: 46, line: 64, color: MockPalette.ink, serif: true)
            if failed {
                MockCenterLine(text: "\(failedText)，这一次没有扣积分。", top: 210, size: 15, line: 26, color: MockPalette.sub)
            } else {
                rotating
            }
            MockPrepCards(prep: prep, frozen: failed, hasJob: hasJob)
            MockSessionFoot(goal: detail.text("practice_goal")) {
                if failed {
                    Button(busy ? "正在重新准备…" : "重新准备") { run { _ = try await command("retry") } }.buttonStyle(MockPillStyle()).disabled(busy)
                } else if detail.text("answer_mode") == "voice", let onCheckDevice {
                    Button("先试一下麦克风", action: onCheckDevice).buttonStyle(MockPillStyle(kind: .ghost))
                }
            }
        }
        .overlay { MockNoticeToast(notice: $notice) }
        .mockDialog($dialog, "back") {
            MockConfirmCard(title: "返回修改设置？", desc: "题目还在准备，返回后这场记为已放弃，不扣积分。", confirm: "返回改设置", cancel: "继续准备",
                            busy: busy, busyLabel: "正在返回…", onConfirm: backToSettings, onCancel: { dialog = nil })
        }
        .onChange(of: step) { lineStart = Date() }
    }

    /// 标题下的小字每 4.5 秒换一句，讲这一步实际在按什么挑；换步骤时从第一句重新开始。
    private var rotating: some View {
        let lines = step == 0 ? readingLines : step == 1 && prep != nil ? selectingLines(prep!) : openingLines
        return TimelineView(.periodic(from: lineStart, by: 0.3)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(lineStart))
            let index = lines.count < 2 ? 0 : Int(elapsed / 4.5) % lines.count
            let out = lines.count >= 2 && elapsed.truncatingRemainder(dividingBy: 4.5) > 4.2
            MockCenterLine(text: lines.isEmpty ? "" : lines[index], top: 210, size: 15, line: 26, color: MockPalette.sub)
                .opacity(out ? 0 : 1).animation(.easeInOut(duration: 0.3), value: out)
        }
        .accessibilityHidden(true)
    }

    private var readingLines: [String] {
        let focus = detail["practice_focus"]?.text("label").nonEmptyValue
        return [
            "通常 20–40 秒。可以先离开页面，准备好了会提醒你。",
            hasJob ? "先看这场属于什么方向，再找出岗位要求里写到的考点" : "先看你的经历属于什么方向，再找这个方向常考的点",
            "简历里写到的项目和经历，会挑出来准备追问",
            focus.map { "你选的「\($0)」会放在最前面问" } ?? (detail["has_past_practice"]?.bool == true ? "也会翻一遍以前的练习：上次没答好的点，这次会再确认一次" : nil),
        ].compactMap { $0 }
    }

    private func selectingLines(_ prep: JSONValue) -> [String] {
        let picks = prep["picks"]?.items ?? []
        let tags = Set(picks.map { $0.text("tag") })
        let gap = picks.contains { $0.text("tag") == "job" && $0.text("note") == "简历里还没有写到" }
        let who = [detail.text("company_name"), detail.text("stage_label")].joined().nonEmptyValue ?? "面试"
        let days = prep["days_left"].flatMap { $0 == .null ? nil : $0.integer }
        let when = days.map { $0 <= 0 ? "今天就是\(who)" : "离\(who)还有 \($0) 天" }
        let pace = Self.pace[prep.text("strategy")] ?? "按\(hasJob ? "岗位要求和你的经历" : "你的经历和这个方向常考的点")为你挑题"
        var lines = [when.map { "\($0)，\(pace)" } ?? pace]
        if tags.contains("retest") { lines.append("上次没答好的点会再问一次，看看这次有没有补上") }
        if tags.contains("probe") { lines.append("还拿不准你掌握没有的点，会补问一题确认") }
        if tags.contains("focus") { lines.append("你点名要练的，优先放进这一场") }
        if gap { lines.append("岗位要求里有、简历里还没写到的点，也会问到") } else if tags.contains("job") { lines.append("岗位要求里写到的点优先挑") }
        if tags.contains("resume") { lines.append("从你的经历里挑一两段深挖，问做法和结果") }
        if tags.contains("basics") { lines.append("再配几道这个方向常考的基础") }
        if tags.contains("competency") { lines.append("留一道综合题，看沟通、协作和推进") }
        return lines
    }

    private var openingLines: [String] {
        var lines = ["考点已经挑好，面试官正在组织第一问。"]
        if let first = prep?.text("first").nonEmptyValue { lines.append("第一题从「\(first)」问起") }
        if detail["follow_up_enabled"]?.bool == true { lines.append("答完之后，面试官会顺着你的回答追问") }
        if detail.text("answer_mode") == "voice" { lines.append("趁这会儿可以先试一下麦克风") }
        return lines
    }

    private func command(_ name: String) async throws -> JSONValue {
        try await session.api.careerRequest(path: "/api/mock-interviews/\(detail.display("id"))/\(name)", method: "POST", query: [:], body: nil)
    }
    private func run(_ action: @escaping () async throws -> Void, after: (() -> Void)? = nil) {
        busy = true
        Task {
            do { try await action(); after?(); changed() } catch { notice = MockNotice(title: "操作没有完成", message: MockInterviewText.error(error)) }
            busy = false
        }
    }
    private func backToSettings() { run({ _ = try await command("abandon") }, after: { dialog = nil; home() }) }
}

// MARK: 结束（Figma 09 · 07 结束 07.01 整理报告、07.02 放弃 / 没能生成；Web `ClosingStage`）

struct MockClosingStage: View {
    @Environment(SessionStore.self) private var session
    let detail: JSONValue
    let changed: () -> Void
    let home: () -> Void
    let open: (String) -> Void
    @State private var busy = false
    @State private var notice: MockNotice?

    private static let statX: [CGFloat] = [380, 684, 988]

    var body: some View {
        let failed = detail.text("status") == "evaluation_failed"
        let abandoned = detail.text("status") == "abandoned"
        let voice = detail.text("answer_mode") == "voice"
        MockSessionFrame {
            if abandoned || failed {
                MockSessionHead(detail: detail, back: ("模拟面试", false, home))
                MockCenterLine(text: abandoned ? "这场面试已放弃" : "评估报告没能生成", top: 314, size: 46, line: 64, color: MockPalette.ink, serif: true)
                MockCenterLine(text: abandoned ? "没有生成报告\(voice ? "，录音已删除" : "")。" : "作答\(voice ? "和录音" : "")都保存了，重新评估不另扣积分。", top: 388, size: 15, line: 26, color: MockPalette.sub)
                MockSessionFoot(goal: nil) {
                    if abandoned {
                        Button(busy ? "正在准备…" : "用同样设置重新开始") { restart() }.buttonStyle(MockPillStyle()).disabled(busy)
                    } else {
                        Button(busy ? "正在重新评估…" : "重新评估") { retry() }.buttonStyle(MockPillStyle()).disabled(busy)
                    }
                }
            } else {
                let questions = detail["questions"]?.items ?? []
                let mains = questions.filter { $0.text("kind") == "main" && !MockMap.isIntro(detail, $0) }.count
                let follows = questions.filter { $0.text("kind") == "follow_up" }.count
                let points = questions.reduce(0) { $0 + ($1["notes"]?.items.count ?? 0) }
                let started = CareerApplication.date(detail.text("started_at")) ?? CareerApplication.date(detail.text("created_at")) ?? Date()
                let finished = CareerApplication.date(detail.text("finished_at")) ?? Date()
                MockSessionHead(detail: detail)
                MockCenterLine(text: "用时 \(MockSession.mmss(finished.timeIntervalSince(started)))", top: 216)
                MockCenterLine(text: "面试结束，辛苦了", top: 244, size: 46, line: 64, color: MockPalette.ink, serif: true)
                MockCenterLine(text: "面试官在把笔记整理成评估报告，约 1 分钟。", top: 318, size: 15, line: 26, color: MockPalette.sub)
                MockLiveVoiceprint(tone: .rest).offset(x: 234, y: 370)
                ForEach(Array([(mains, "主问题"), (follows, "次追问"), (points, "条要点")].enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(verbatim: "\(item.0)").font(V3.serif(28)).foregroundStyle(MockPalette.ink)
                        Text(verbatim: item.1).font(V3.sans(13)).foregroundStyle(MockPalette.fnt)
                    }
                    .frame(width: 200, height: 38).offset(x: Self.statX[index] - 100, y: 484)
                }
                MockSessionFoot(goal: nil) {
                    Text("报告好了会出现在模拟面试首页。").font(V3.sans(13)).foregroundStyle(MockPalette.fnt)
                } right: {
                    Button("先去忙，好了提醒我", action: home).buttonStyle(MockPillStyle())
                }
            }
        }
        .overlay { MockNoticeToast(notice: $notice) }
    }

    private func command(_ name: String) async throws -> JSONValue {
        try await session.api.careerRequest(path: "/api/mock-interviews/\(detail.display("id"))/\(name)", method: "POST", query: [:], body: nil)
    }
    private func retry() {
        busy = true
        Task { do { _ = try await command("retry"); changed() } catch { notice = MockNotice(title: "操作没有完成", message: MockInterviewText.error(error)) }; busy = false }
    }
    private func restart() {
        busy = true
        Task { do { open(try await command("repeat")["mock_interview"]?.display("id") ?? "") } catch { notice = MockNotice(title: "操作没有完成", message: MockInterviewText.error(error)) }; busy = false }
    }
}

// MARK: 文字面试（Figma 09 · 06 文字面试 06.01–06.11；Web `TextSessionV2`）

private let typeInterval = Duration.milliseconds(40)
private let maxAnswer = 8000

/// 和语音面试同一套画面，声纹的位置换成无框写字区，发送在底部右侧；面试官说话时没有写字区。
/// 发送后到面试官开口之前是思考界面：题目收起，回答留在原处变灰，笔记到了标出被记下的原话。
struct MockTextSession: View {
    @Environment(SessionStore.self) private var session
    let interview: JSONValue
    let changed: () -> Void
    let pause: (Bool) -> Void

    private enum Phase { case answer, sent, asking, closing }
    @State private var detail: JSONValue = .null
    @State private var phase: Phase = .answer
    @State private var draft = ""
    @State private var sent: String?
    @State private var askText = ""
    @State private var shown = Int.max
    @State private var dialog: String?
    @State private var busy: String?
    @State private var notice: MockNotice?
    @State private var turnReady = false
    @State private var noted = 0
    @State private var quotes: [String] = []
    @State private var voiceInput = VoiceRecorder()
    @State private var speechSessionID: String?
    @State private var voiceFailed = false
    @FocusState private var focused: Bool

    private var question: JSONValue? { MockSession.current(detail) }
    private var needsReply: Bool { detail["needs_reply"]?.bool == true && phase == .answer }
    private var locked: Bool { phase != .answer || question == nil || needsReply || busy != nil }
    private var listening: Bool { voiceInput.phase == .recording || voiceInput.phase == .finishing || voiceInput.phase == .connecting }

    var body: some View {
        let shownQuestion = question ?? MockSession.lastAsked(detail)
        let typing = phase == .asking || phase == .closing
        let writing = phase == .answer && !needsReply && question != nil
        let status: (String, Color) = phase == .asking ? ("面试官在问", MockPalette.sub)
            : phase == .closing ? ("面试官在说结束语", MockPalette.sub)
            : needsReply ? ("面试官的回复没生成，你的回答已经保存", MockPalette.orange)
            : voiceInput.phase == .recording ? ("正在听 · 再点一下停止", MockPalette.blue)
            : ("轮到你", MockPalette.sub)
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            MockSessionFrame {
                MockSessionHead(detail: detail, timer: MockSessionText.elapsed(detail, now: timeline.date)) {
                    Button("跳过此题") { dialog = "skip" }.buttonStyle(MockLinkStyle()).disabled(locked)
                    Button("放弃") { dialog = "abandon" }.buttonStyle(MockLinkStyle()).disabled(busy != nil || phase == .closing)
                    Button("结束并评估") { dialog = "finish" }.buttonStyle(MockPillStyle(kind: .ghost)).disabled(busy != nil || phase == .closing || phase == .sent)
                }
                if phase == .sent {
                    thinking(shownQuestion)
                } else {
                    MockCenterLine(text: phase == .closing ? "面试结束" : MockSessionText.eyebrow(detail, shownQuestion), top: 175)
                    MockBigQuestion(text: typing ? askText : shownQuestion?.text("content") ?? "", shown: typing ? shown : .max)
                    MockCenterLine(text: status.0, top: 360, size: 14, line: 20, color: status.1)
                }
                if writing { writeArea }
                MockSessionFoot(goal: detail.text("practice_goal")) {
                    if needsReply {
                        Button(busy == "send" ? "正在生成…" : "重新生成") { regenerate() }.buttonStyle(MockPillStyle(padding: 22)).disabled(busy != nil)
                    } else if writing {
                        if !listening {
                            Text(verbatim: draft.isEmpty ? "Enter 发送，Shift + Enter 换行" : "\(draft.count) 字").font(V3.sans(13)).foregroundStyle(MockPalette.mute).lineLimit(1)
                        }
                        voiceButton
                        Button("发送", action: send).buttonStyle(MockPillStyle(padding: 22)).padding(.leading, 4)
                            .disabled(locked || listening || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        MockAnswerFeedback(feedback: nil, notes: noted)
                    }
                }
            }
        }
        .overlay { MockNoticeToast(notice: $notice) }
        .modifier(MockSessionDialogs(detail: detail, dialog: $dialog, busy: busy, voice: false, skip: skip, end: end))
        .onAppear { if detail == .null { detail = interview } }
        .onChange(of: interview) { _, value in if phase != .sent { detail = value } }
        .task(id: "\(phase)-\(askText.count)-\(shown)") { await typeAhead() }
        .onChange(of: locked, initial: true) { _, value in if !value { focused = true } }
        .onChange(of: question?.display("id")) { voiceInput.cancel(); voiceFailed = false }
        .onDisappear { voiceInput.cancel() }
    }

    /// 思考界面：题目收起，三个点在闪，刚写的回答留在原处变灰，被记下的原话标蓝色下划线。
    @ViewBuilder private func thinking(_ shownQuestion: JSONValue?) -> some View {
        let title = sent == nil ? "好，这题先放下。" : noted > 0 ? "好，我想想下一个问题。" : "我看一下你的回答。"
        MockCenterLine(text: MockSessionText.thinkingEyebrow(detail, shownQuestion, skipped: sent == nil), top: 239)
        MockCenterLine(text: title, top: 267, size: 46, line: 64, color: MockPalette.ink, serif: true)
        MockThinkDots()
        if let sent, !sent.isEmpty {
            MockSessionText.quoteSegments(sent, quotes).reduce(Text(verbatim: "")) { result, part in
                result + (part.marked ? Text(verbatim: part.text).foregroundColor(MockPalette.ink).underline(true, color: MockPalette.blue) : Text(verbatim: part.text).foregroundColor(MockPalette.mute))
            }
            .font(V3.sans(17)).lineHeight(17, 30).lineLimit(4)
            .frame(width: 892, alignment: .topLeading).offset(x: 234, y: 404)
        }
    }

    /// 无框写字区（左 234、顶 404、903 × 300）：语音输入时说的话接在后面，还没确认的字浅灰。
    @ViewBuilder private var writeArea: some View {
        if listening {
            ScrollView {
                (Text(verbatim: draft).foregroundColor(MockPalette.ink) + Text(verbatim: voiceInput.partial).foregroundColor(MockPalette.faint))
                    .font(V3.sans(17)).lineHeight(17, 30).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.bottom).frame(width: 903, height: 300).offset(x: 234, y: 404)
        } else {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(V3.sans(17)).lineSpacing(30 - 17 * 1.2).scrollContentBackground(.hidden).foregroundStyle(MockPalette.ink).tint(MockPalette.blue)
                    .focused($focused).disabled(locked).accessibilityLabel("你的回答")
                    .onChange(of: draft) { _, value in if value.count > maxAnswer { draft = String(value.prefix(maxAnswer)) } }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        send(); return .handled
                    }
                if draft.isEmpty {
                    Text("写下你的回答").font(V3.sans(17)).foregroundStyle(MockPalette.faint).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .frame(width: 903, height: 300).offset(x: 234, y: 404)
        }
    }

    /// 底部「语音输入」：说的话转成文字落进写字区，发送时带上识别会话。
    private var voiceButton: some View {
        let recording = voiceInput.phase == .recording
        let label = recording ? "停止" : voiceInput.phase == .finishing || voiceInput.phase == .connecting ? "正在识别…" : voiceFailed ? "没听清，再试一次" : "语音输入"
        return Button {
            if recording { stopVoice() }
            else if let question { voiceFailed = false; Task { await voiceInput.start(api: session.api, interviewID: detail.display("id"), questionID: question.display("id"), purpose: "voice_input") } }
        } label: {
            HStack(spacing: 6) {
                if recording { Circle().fill(MockPalette.blue).frame(width: 7, height: 7) } else { Image(systemName: "mic").font(.system(size: 12)) }
                Text(verbatim: label)
            }
        }
        .buttonStyle(MockLinkStyle(color: recording ? MockPalette.blue : nil))
        .disabled(!recording && (locked || voiceInput.phase == .finishing || voiceInput.phase == .connecting))
        .accessibilityLabel(recording ? "停止录音" : "语音输入")
        .onChange(of: voiceInput.phase) { _, value in if case .failed = value { voiceFailed = true } }
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

    /// 面试官逐字「打」出来（一次两个字），打完 0.6 秒后回到作答；结束语打完交给结束页。
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
        phase = .sent; sent = sentText; turnReady = false; noted = 0; quotes = []; pause(true)
        do {
            let turn = Turn(try await session.api.careerRequest(path: path(command), method: "POST", query: [:], body: body))
            if let answered, let id = body?.display("question_id") {
                detail = detail.replacingQuestions { $0.map { $0.display("id") == id ? $0.setting("answer_status", .string("answered")).setting("answer_text", .string(answered)) : $0 } }
            }
            for item in turn.notes {
                detail = detail.withNotes(item.question, item.notes)
                noted = item.notes.items.count
                quotes = item.notes.items.map { $0.text("quote") }.filter { !$0.isEmpty }
            }
            // 被记下的原话至少留 1.2 秒才看得清
            if !turn.notes.isEmpty { try? await Task.sleep(for: .milliseconds(1200)) }
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
            notice = MockNotice(title: answered == nil && sentText == nil ? "没能跳过此题" : "回答没有提交成功", message: MockInterviewText.error(error))
            if let answered { draft = answered }
            sent = nil; askText = ""; phase = .answer
        }
        pause(false); changed()
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let question, !text.isEmpty, !locked, !listening else { return }
        busy = "send"; draft = ""
        var body: [String: JSONValue] = ["question_id": question["id"] ?? .null, "answer": .string(text), "__idempotency_key": idempotency()]
        if let speechSessionID { body["speech_session_id"] = .string(speechSessionID) }
        speechSessionID = nil
        Task { await consume("answers", body: .object(body), answered: text, sentText: text); busy = nil }
    }
    private func skip() {
        guard let question else { return }
        dialog = nil; busy = "skip"
        Task { await consume("skip", body: .object(["question_id": question["id"] ?? .null, "__idempotency_key": idempotency()]), answered: nil, sentText: nil); busy = nil }
    }
    private func regenerate() {
        let last = (detail["questions"]?.items ?? []).filter { $0.text("answer_status") == "answered" }.max { ($0["sequence_no"]?.numberValue ?? 0) < ($1["sequence_no"]?.numberValue ?? 0) }
        busy = "send"
        Task { await consume("reply:retry", body: nil, answered: nil, sentText: last?.text("answer_text") ?? ""); busy = nil }
    }
    private func end(_ kind: String) {
        busy = kind
        Task {
            do { _ = try await session.api.careerRequest(path: path(kind), method: "POST", query: [:], body: nil); dialog = nil; voiceInput.cancel(); changed() }
            catch { notice = MockNotice(title: "操作没有完成", message: MockInterviewText.error(error)) }
            busy = nil
        }
    }
}

/// 面试中的三个确认（跳过此题、结束并评估、放弃）：文字和语音面试共用。
struct MockSessionDialogs: ViewModifier {
    let detail: JSONValue
    @Binding var dialog: String?
    let busy: String?
    let voice: Bool
    let skip: () -> Void
    let end: (String) -> Void
    func body(content: Content) -> some View {
        content
            .mockDialog($dialog, "skip") {
                MockConfirmCard(title: "跳过这道题？", desc: "跳过的部分记为没答，面试官会换下一个考点；前面已经答的照常评分。", confirm: "跳过此题", cancel: "继续作答",
                                busy: busy == "skip", busyLabel: "正在跳过…", onConfirm: skip, onCancel: { dialog = nil })
            }
            .mockDialog($dialog, "finish") {
                if MockSession.hasAnswered(detail) {
                    MockConfirmCard(title: "结束并生成评估？", desc: "已作答的题目会进入评估，后面没问到的题不扣分。", confirm: "结束并评估", cancel: "继续面试",
                                    busy: busy == "finish", busyLabel: "正在结束…", onConfirm: { end("finish") }, onCancel: { dialog = nil }) {
                        MockFinishStats(detail: detail, elapsed: MockSessionText.elapsed(detail))
                    }
                } else {
                    MockConfirmCard(title: "结束这场面试？", desc: "你还没有回答任何考点，结束后这场记为已放弃，不生成报告。", confirm: "结束这场", cancel: "继续面试",
                                    busy: busy == "finish", busyLabel: "正在结束…", onConfirm: { end("finish") }, onCancel: { dialog = nil })
                }
            }
            .mockDialog($dialog, "abandon") {
                MockConfirmCard(title: "放弃这场面试？", desc: voice ? "已作答的内容不会生成评估报告，录音会删除。放弃后可以重新开始一场。" : "已作答的内容不会生成评估报告。放弃后可以重新开始一场。",
                                confirm: "放弃面试", cancel: "继续面试", busy: busy == "abandon", busyLabel: "正在放弃…", onConfirm: { end("abandon") }, onCancel: { dialog = nil })
            }
    }
}
