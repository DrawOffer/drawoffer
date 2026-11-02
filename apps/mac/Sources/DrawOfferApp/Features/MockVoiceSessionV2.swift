import AppKit
import Foundation
import DrawOfferCore
import SwiftUI

/// 语音面试（Web `VoiceSessionV2` + `DeviceCheckStage`）：准备题目 → 检查设备 → 面试官念题（字幕逐字）→ 开口作答，
/// 停顿 3 秒自动提交 → 面试官看笔记 → 下一题；没听清时请你再说一遍。录音与识别沿用 `VoiceRecorder`。
struct MockVoiceSession: View {
    @Environment(SessionStore.self) private var session
    let detail: JSONValue
    let context: MockSessionContext
    let changed: () -> Void
    let home: () -> Void
    let pause: (Bool) -> Void

    private enum Phase: Equatable { case prep, check, asking, listening, submitting, unclear, submitFailed, closing }
    @State private var local: JSONValue = .null
    @State private var phase: Phase = .prep
    @State private var question: JSONValue?
    @State private var askText = ""
    @State private var shown = 0
    @State private var recordStart = Date()
    @State private var heard = false
    @State private var lastVoice = Date()
    @State private var transcript = ""
    @State private var recognized: VoiceRecorder.Final?
    @State private var audioFailed = false
    @State private var recordingDropped = false
    @State private var dialog: String?
    @State private var busy: String?
    @State private var drawer = false
    @State private var toast: (title: String, message: String)?
    @State private var recorder = VoiceRecorder()
    @State private var voice = InterviewerVoice()

    private static let unclearText = "抱歉，刚才这段没听清，可以再说一遍吗？"
    private static let charInterval = Duration.milliseconds(90)
    private static let pauseHint = 1.0, autoSubmit = 3.0, silenceHint = 8.0

    var body: some View {
        Group {
            switch phase {
            case .prep: MockPrepStage(detail: local, context: context, changed: changed, home: home, onCheckDevice: { phase = .check })
            case .check:
                MockDeviceCheck(detail: local, context: context, busy: busy, onStart: start, onBack: { dialog = "back" }, onSwitchToText: { dialog = "text" })
                    .overlay { leaveDialog }
            default: interview
            }
        }
        .onAppear {
            if local == .null { local = detail }
            phase = detail.text("status") == "in_progress" ? .check : .prep
            question = MockSession.current(detail)
        }
        .onChange(of: detail) { _, value in
            local = value
            if phase == .prep && value.text("status") == "in_progress" { phase = .check }
            if phase == .check || phase == .prep { question = MockSession.current(value) }
        }
        .onDisappear { recorder.cancel(); voice.stop() }
    }

    // MARK: 作答画面

    private var interview: some View {
        let shownQuestion = question ?? (phase == .closing ? nil : MockSession.lastAsked(local))
        let mapPhase: MockSession.Phase = phase == .submitting ? .thinking : phase == .closing ? .done : phase == .listening ? .answering : .asking
        let map = context.map(local, current: shownQuestion, phase: mapPhase)
        let round = MockSession.roundOf(local, shownQuestion)
        let intro = shownQuestion.map { $0.text("anchor_kind") == "intro" || MockMap.isIntro(local, $0) } ?? false
        let follow = shownQuestion?.text("kind") == "follow_up"
        let chip = MockSession.sourceChip(shownQuestion)
        let speaking = heard || !recorder.partial.isEmpty
        let liveText = recorder.partial.isEmpty ? transcript : recorder.partial
        let askingNow = phase == .asking || phase == .closing
        let spoken = phase == .unclear ? Self.unclearText : askText
        let questionText = phase == .unclear ? shownQuestion?.text("content") ?? "" : askingNow ? spoken : shownQuestion?.text("content") ?? spoken
        let roundIndex = map.rounds.firstIndex { $0.main.display("id") == round?.main.display("id") } ?? -1
        let previous = shownQuestion?.text("kind") == "main" && roundIndex > 0 ? map.rounds[roundIndex - 1] : nil
        let skipLocked = busy != nil || question == nil || [.submitting, .closing, .unclear].contains(phase)
        let count = detail["question_count"]?.integer ?? 0
        return TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
            let recordingMs = phase == .listening ? timeline.date.timeIntervalSince(recordStart) : 0
            let silent = phase == .listening ? timeline.date.timeIntervalSince(lastVoice) : 0
            let pausing = phase == .listening && heard && silent >= Self.pauseHint
            let silentLong = phase == .listening && !speaking && recordingMs >= Self.silenceHint
            let countdown = pausing ? max(1, Int((Self.autoSubmit - silent).rounded(.up))) : 0
            let status: (String, MockTone, Color?) = phase == .submitFailed ? (recognized != nil ? "这段回答还没提交" : "等面试官回复", .or, MI.orange)
                : phase == .submitting ? ("面试官在看笔记…", .sub, MI.gry)
                : phase == .unclear ? ("直接重新说一遍就行", .sub, MI.blue)
                : pausing ? ("停顿中 · \(countdown) 秒后自动提交 · 继续说就取消", .blue, MI.blue)
                : silentLong ? ("轮到你了 · 已经 \(Int(recordingMs)) 秒没说话", .or, MI.orange)
                : phase == .listening && speaking ? ("正在听 · 停顿 3 秒自动提交", .sub, MI.orange)
                : phase == .closing ? ("面试官在说结束语", .sub, MI.gry)
                : intro ? ("面试官说完后直接开口", .sub, MI.blue) : ("直接开口就能答 · 停顿 3 秒自动提交", .sub, MI.blue)
            SessionFrame {
                SessionTop(title: MockSession.heading(local), sub: MockSession.subtitle(local),
                           center: phase == .closing ? "\(count) / \(count) 题 · 全部完成" : MockSession.progress(local, shownQuestion),
                           started: CareerApplication.date(local.text("started_at")), timerLive: phase != .closing,
                           onAbandon: { dialog = "abandon" }, onFinish: { dialog = "finish" }, finishDisabled: phase == .submitting, busy: busy != nil || phase == .closing)
                SessionMapView(map: map, targetLevel: MockMap.diffLevel[local.text("difficulty")] ?? 3,
                               listen: phase == .listening ? (pausing ? .paused : speaking ? .speaking(Double(recorder.level)) : .idle) : nil)
                SessionHorizonView(beads: MockSession.beads(local, shownQuestion), introNow: MockSession.introNow(local, shownQuestion), ended: phase == .closing)
                if audioFailed && phase != .closing {
                    HStack(spacing: 12) {
                        Text("面试官的声音没放出来，先看字幕作答").foregroundStyle(MI.orange).font(V3.sans(11.5, weight: .medium))
                        Button("重试声音") { replay() }.buttonStyle(.plain).font(V3.sans(11.5)).foregroundStyle(MI.blue)
                    }.offset(x: 56, y: 80)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if recordingDropped && phase != .closing {
                        Text("音视频空间已满，这些回答的录音没有保存；回答和识别文字照常保存").font(V3.sans(11)).foregroundStyle(MI.orange).padding(.bottom, 14)
                    }
                    if let previous, askingNow {
                        (Text(verbatim: "上一题 · \(previous.topic)").foregroundColor(MI.mute).font(V3.sans(11))
                         + Text(verbatim: "  " + (previous.skipped ? "跳过了" : "追问 \(previous.turns.count - 1) 次 · 答到「\(MockMap.levelName(previous.to))」")).foregroundColor(MI.blue).font(V3.sans(10.5, weight: .medium)))
                            .frame(height: 22).padding(.bottom, 14)
                    }
                    if let chip, !follow, phase != .unclear { MockSourceChip(label: chip.label, quote: chip.quote).padding(.bottom, 14) }
                    if phase == .unclear {
                        speaker(intro: intro, follow: follow).padding(.bottom, 10)
                        MockQuestionText(text: questionText, small: true)
                        MockSpeaker(you: false, text: "正在说", live: true).padding(.top, 22).padding(.bottom, 10)
                        MockQuestionText(text: spoken, shown: shown)
                        Text("没听清不算答错，也不计入追问次数").font(V3.sans(12)).foregroundStyle(MI.mute).padding(.top, 10)
                    } else {
                        speaker(intro: intro, follow: follow).padding(.bottom, 10)
                        MockQuestionText(text: questionText, quote: follow ? shownQuestion?.text("source_quote") : shownQuestion?.text("anchor"),
                                         shown: phase == .asking && shown < spoken.count ? shown : .max, size: intro ? 24 : 23, line: 34)
                        if follow && askingNow { Text("↳ 追问来自你刚才的原话").font(V3.sans(11.5)).foregroundStyle(MI.blue).padding(.top, 10) }
                        if shownQuestion?.text("anchor_kind") == "job" && askingNow {
                            Text("这题从岗位要求里来，可能是你简历里还没写过的").font(V3.sans(12)).foregroundStyle(MI.orange).padding(.top, 18)
                        }
                    }
                    if intro && phase == .asking { firstTimeTip }
                    if phase == .asking && !intro && !follow { Text("面试官说完后直接开口").font(V3.sans(12.5)).foregroundStyle(MI.gry).padding(.top, 18) }
                    if follow && askingNow, let prev = previousAnswer(shownQuestion) {
                        MockSpeaker(you: true, text: "上一段回答", tone: .gry).padding(.top, 34).padding(.bottom, 10)
                        MockQuestionText(text: prev.text, quote: prev.quote, size: 15, line: 28, small: false)
                            .foregroundStyle(MI.gry)
                    }
                    if silentLong {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("还在想吗？").font(V3.sans(13, weight: .medium)).foregroundStyle(MI.ink)
                            Text("可以先说思路，想到哪说到哪；实在不会，点左下角跳过此题").font(V3.sans(12)).foregroundStyle(MI.sub)
                        }.padding(.leading, 16).overlay(alignment: .leading) { Rectangle().fill(MI.line).frame(width: 1) }.padding(.top, 22)
                    }
                    if (phase == .listening && (speaking || !liveText.isEmpty)) || phase == .submitting || phase == .submitFailed || (phase == .unclear && !transcript.isEmpty) {
                        HStack {
                            MockSpeaker(you: true, text: youLabel(recordingMs), tone: phase == .submitting || phase == .unclear ? .gry : .or, live: phase == .listening)
                            Spacer()
                            if phase == .listening { Text(verbatim: "已说 \(liveText.filter { !$0.isWhitespace }.count) 字").font(V3.sans(11)).foregroundStyle(MI.mute) }
                        }.frame(width: 652).padding(.top, 34).padding(.bottom, 10)
                        MockTranscript(height: phase == .listening ? 196 : 112) {
                            if phase == .unclear { Text(verbatim: transcript).font(V3.sans(15)).strikethrough().foregroundStyle(MI.gry) }
                            else { MockSaid(text: liveText.isEmpty ? "……" : liveText + (phase == .listening ? "……" : ""), past: phase == .submitting || liveText.isEmpty) }
                        }
                        if phase == .listening && !pausing { MockWave(level: Double(recorder.level)).padding(.top, 16) }
                    }
                    if phase == .submitFailed {
                        MockAlert(title: recognized != nil ? "这段回答没提交成功" : "面试官的回复没生成", sub: recognized != nil ? "网络断了一下，录音和文字都还在" : "你的回答已经保存，重新生成不会重复计入") {
                            Button(recognized != nil ? "重新提交" : "重新生成") { if let recognized { submit(recognized) } else { regenerate() } }.buttonStyle(MockButtonStyle())
                        }
                    }
                    if !intro { MockNotesBox(notes: MockSession.notes(round)) }
                }
                .frame(width: 680, alignment: .leading).offset(x: 56, y: audioFailed ? 104 : 96)
                if phase != .closing {
                    SessionBottom(left: "跳过此题", onLeft: { dialog = "skip" }, leftDisabled: skipLocked, status: status.0, statusTone: status.1, dot: status.2,
                                  right: "对话记录", onRight: { withAnimation(.easeOut(duration: 0.22)) { drawer = true } }) {
                        if phase == .listening && speaking { Button("说完了") { stopAndSubmit() }.buttonStyle(MockButtonStyle()) }
                        else if phase == .asking && question != nil && !intro { Button("打断并作答") { beginAnswer() }.buttonStyle(MockQuietStyle()) }
                    }
                }
                if drawer { MockConversationDrawer(detail: local, currentID: shownQuestion?.display("id"), close: { drawer = false }) }
                dialogs
                MockToast(toast: $toast)
            }
            .onChange(of: pausing && silent >= Self.autoSubmit) { _, due in if due { stopAndSubmit() } }
        }
        .task(id: "\(phase)-\(shown)-\(spoken.count)") { await typeAhead(spoken) }
        .onChange(of: recorder.level) { _, level in
            if level > 0.08 && phase == .listening { heard = true; lastVoice = Date() }
        }
        .onChange(of: recorder.partial) { _, text in if !text.isEmpty { heard = true; lastVoice = Date() } }
        .onChange(of: recorder.phase) { _, value in
            if case .failed(let message) = value, phase == .listening { toast = ("录音没有完成", message); phase = .unclear; shown = 0 }
        }
    }

    private func speaker(intro: Bool, follow: Bool) -> MockSpeaker {
        switch phase {
        case .closing: return MockSpeaker(you: false, text: "结束语", live: true)
        case .unclear: return MockSpeaker(you: false, text: follow ? "追问" : "提问", tone: .gry)
        case .submitting: return MockSpeaker(you: false, text: "在想下一句")
        case .listening, .submitFailed: return MockSpeaker(you: false, text: follow ? "追问" : "在听")
        default: return audioFailed ? MockSpeaker(you: false, text: "字幕") : MockSpeaker(you: false, text: intro ? "正在说" : follow ? "追问" : "正在提问", live: true)
        }
    }

    private func youLabel(_ recordingMs: Double) -> String {
        let time = recognized.map { MockSession.mmss(Double($0.durationMs) / 1000) } ?? MockSession.mmss(recordingMs)
        switch phase {
        case .listening: return "正在回答 · \(MockSession.mmss(recordingMs))"
        case .submitting: return transcript.isEmpty ? "跳过了这道题" : "已提交 · \(time)"
        case .unclear: return "刚才那段"
        default: return "回答 · \(time)"
        }
    }

    private var firstTimeTip: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("第一次语音面试").font(V3.sans(11)).foregroundStyle(MI.mute)
            VStack(alignment: .leading, spacing: 9) {
                tipRow(1, "面试官说完，直接开口就行"); tipRow(2, "停顿 3 秒自动提交，也可以点「说完了」"); tipRow(3, "面试官说话时你开口，可以直接打断")
            }.padding(.top, 10)
        }.padding(.leading, 16).overlay(alignment: .leading) { Rectangle().fill(MI.line).frame(width: 1) }.padding(.top, 26)
    }
    private func tipRow(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(n)").font(.system(size: 11, weight: .medium)).foregroundStyle(MI.gry)
            Text(verbatim: text).font(V3.sans(13)).foregroundStyle(MI.sub)
        }.frame(height: 16)
    }

    private func previousAnswer(_ question: JSONValue?) -> (text: String, quote: String?)? {
        guard let question, question.text("kind") == "follow_up" else { return nil }
        let sequence = question["sequence_no"]?.numberValue ?? 0
        let before = (local["questions"]?.items ?? []).filter { ($0["sequence_no"]?.numberValue ?? 0) < sequence && $0.text("answer_status") == "answered" }
            .max { ($0["sequence_no"]?.numberValue ?? 0) < ($1["sequence_no"]?.numberValue ?? 0) }
        guard let text = before?.text("answer_text").nonEmptyValue else { return nil }
        return (text, question.text("source_quote").nonEmptyValue)
    }

    @ViewBuilder private var dialogs: some View {
        if dialog == "skip" {
            MockConfirm(title: "跳过这道题？", desc: "跳过的部分记为没答，面试官会换下一个考点；前面已经答的照常评分。", confirm: "跳过此题",
                        busy: busy == "skip", busyLabel: "正在跳过…", onConfirm: skip, onCancel: { dialog = nil })
        } else if dialog == "finish" {
            MockConfirm(title: "结束并生成评估？", desc: MockSession.hasAnswered(local) ? "已作答的题目会进入评估，后面没问到的题不扣分。" : "你还没有回答任何考点，结束后这场记为已放弃，不生成报告。",
                        confirm: "结束并评估", busy: busy == "finish", busyLabel: "正在结束…", onConfirm: { end("finish") }, onCancel: { dialog = nil }) {
                MockFinishStats(detail: local, elapsed: MockSession.mmss(Date().timeIntervalSince(CareerApplication.date(local.text("started_at")) ?? Date())))
            }
        } else if dialog == "abandon" {
            MockConfirm(title: "放弃这场语音面试？", desc: "已作答的内容不会生成评估报告，录音会删除。放弃后可以重新开始一场。", confirm: "放弃面试", cancel: "继续面试", danger: true,
                        busy: busy == "abandon", busyLabel: "正在放弃…", onConfirm: { end("abandon") }, onCancel: { dialog = nil })
        }
    }

    @ViewBuilder private var leaveDialog: some View {
        if dialog == "back" || dialog == "text" {
            MockStage(width: MockFull.width, height: MockFull.height) {
                MockConfirm(title: dialog == "text" ? "改为文字面试？" : "返回修改设置？",
                            desc: dialog == "text" ? "沿用同一套题目，只是改成打字作答；输入框里还可以用语音转文字。" : "将放弃这场语音面试，回到模拟面试首页修改设置后重新开始。",
                            confirm: dialog == "text" ? "改为文字面试" : "返回修改", busy: busy == dialog, busyLabel: dialog == "text" ? "正在切换…" : "正在返回…",
                            onConfirm: { leaveCheck(dialog ?? "back") }, onCancel: { dialog = nil })
            }.background(.clear)
        }
    }

    // MARK: 流程

    private func path(_ command: String) -> String { "/api/mock-interviews/\(local.display("id"))/\(command)" }

    private func start() {
        if local["needs_reply"]?.bool == true { regenerate(); return }
        guard let first = MockSession.current(local) else { return }
        ask(first)
    }

    private func ask(_ next: JSONValue) {
        question = next; askText = next.text("content"); shown = 0; audioFailed = false; phase = .asking
        Task {
            guard let audio = try? await session.api.mockAudio(path: path("speech/playback"), method: "POST", body: .object(["question_id": next["id"] ?? .null])) else { audioFailed = true; return }
            voice.play(audio)
        }
    }

    private func replay() {
        guard let question else { return }
        Task {
            do { voice.play(try await session.api.mockAudio(path: path("speech/playback"), method: "POST", body: .object(["question_id": question["id"] ?? .null]))); audioFailed = false }
            catch { toast = ("面试官的声音还是没放出来", MockInterviewText.error(error)) }
        }
    }

    /// 面试官逐字「播报」，念完（且语音播完）0.5 秒后自动开始收音；结束语念完 1.5 秒交给结束页；没听清念完 2.6 秒重新收音。
    private func typeAhead(_ spoken: String) async {
        guard [.asking, .closing, .unclear].contains(phase) else { return }
        if shown < spoken.count {
            try? await Task.sleep(for: Self.charInterval)
            if !Task.isCancelled { shown += 1 }
            return
        }
        if phase == .unclear {
            try? await Task.sleep(for: .seconds(2.6))
            if !Task.isCancelled && phase == .unclear { beginAnswer() }
            return
        }
        if phase == .asking && question == nil { return }
        while voice.playing && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(150)) }
        try? await Task.sleep(for: .milliseconds(phase == .asking ? 500 : 1500))
        guard !Task.isCancelled else { return }
        if phase == .asking { beginAnswer() } else if phase == .closing { pause(false); changed() }
    }

    private func beginAnswer() {
        guard let question else { return }
        voice.stop()
        recognized = nil; transcript = ""; heard = false; recordStart = Date(); lastVoice = Date()
        phase = .listening
        Task { await recorder.start(api: session.api, interviewID: local.display("id"), questionID: question.display("id")) }
    }

    private func stopAndSubmit() {
        guard phase == .listening else { return }
        phase = .submitting
        Task {
            do {
                let result = try await recorder.stop()
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !result.sessionID.isEmpty else { shown = 0; phase = .unclear; return }
                recognized = result; transcript = result.text
                submit(result)
            } catch { shown = 0; phase = .unclear }
        }
    }

    private func submit(_ result: VoiceRecorder.Final) {
        guard let question else { return }
        phase = .submitting
        Task {
            do {
                try await consume("answers", body: .object(["question_id": question["id"] ?? .null, "speech_session_id": .string(result.sessionID), "__idempotency_key": .string(UUID().uuidString.lowercased())]))
            } catch { phase = .submitFailed; toast = ("回答没有提交成功", MockInterviewText.error(error)) }
        }
    }

    private func regenerate() {
        phase = .submitting
        Task {
            do { try await consume("reply:retry", body: nil) }
            catch { phase = .submitFailed; toast = ("面试官的回复没有生成出来", MockInterviewText.error(error)) }
        }
    }

    private func skip() {
        guard let question, busy == nil else { return }
        busy = "skip"; dialog = nil; recorder.cancel(); voice.stop(); transcript = ""; phase = .submitting
        Task {
            do { try await consume("skip", body: .object(["question_id": question["id"] ?? .null, "__idempotency_key": .string(UUID().uuidString.lowercased())])) }
            catch { toast = ("没有跳过这道题", MockInterviewText.error(error)); beginAnswer() }
            busy = nil
        }
    }

    /// 读完一个回合：笔记先到，面试官的话按序念（语音片段随回合返回），最后的 turn 带下一题。
    private func consume(_ command: String, body: JSONValue?) async throws {
        pause(true)
        defer { if phase != .closing { pause(false) } }
        let result = try await session.api.careerRequest(path: path(command), method: "POST", query: [:], body: body)
        let events = result["events"]?.items ?? []
        var end: JSONValue?
        var spoken = ""
        for event in events {
            let data = event["data"] ?? .null
            switch event.text("event") {
            case "interviewer.notes":
                let id = data.display("question_id"), notes = data["notes"] ?? .array([])
                if case .object(var fields) = local {
                    fields["questions"] = .array((local["questions"]?.items ?? []).map { item in
                        guard item.display("id") == id, case .object(var q) = item else { return item }
                        q["notes"] = notes; return .object(q)
                    })
                    local = .object(fields)
                }
            case "interviewer.delta": spoken += data.text("content")
            case "interviewer.audio_failed": audioFailed = true
            case "answer.accepted": if data["recording_dropped"]?.bool == true { recordingDropped = true }
            case "interviewer.turn": end = data
            default: break
            }
        }
        guard let end else { throw APIError.server(status: 502, code: "MOCK_INTERVIEW_TURN_FAILED") }
        if events.contains(where: { $0.text("event") == "interviewer.audio" }) { voice.enqueue(events: events) } else { audioFailed = audioFailed || false }
        if let fresh = try? await session.api.careerRequest(path: "/api/mock-interviews/\(local.display("id"))", method: "GET", query: [:], body: nil)["mock_interview"] { local = fresh }
        if end.text("action") == "finish" || end["question"] == nil || end["question"] == .null {
            question = nil; askText = spoken.nonEmptyValue ?? end.text("closing_message").nonEmptyValue ?? "今天的面试就到这里，感谢你的时间。"; shown = 0; phase = .closing
            return
        }
        let next = end["question"]!
        question = next; askText = spoken.nonEmptyValue ?? next.text("content"); shown = 0; phase = .asking
    }

    private func end(_ kind: String) {
        busy = kind
        Task {
            do {
                _ = try await session.api.careerRequest(path: path(kind), method: "POST", query: [:], body: nil)
                recorder.cancel(); voice.stop(); dialog = nil; changed()
            } catch { toast = (kind == "finish" ? "没有结束面试" : "没有放弃面试", MockInterviewText.error(error)) }
            busy = nil
        }
    }

    /// 检查设备阶段：返回修改是放弃本场回首页；改为文字面试沿用同一份题目（`POST answer-mode`）。
    private func leaveCheck(_ target: String) {
        busy = target
        Task {
            do {
                if target == "back" {
                    if ["preparing", "preparation_failed", "in_progress"].contains(local.text("status")) { _ = try await session.api.careerRequest(path: path("abandon"), method: "POST", query: [:], body: nil) }
                    dialog = nil; home()
                } else {
                    _ = try await session.api.careerRequest(path: path("answer-mode"), method: "POST", query: [:], body: .object(["answer_mode": .string("text")]))
                    dialog = nil; changed()
                }
            } catch { toast = ("操作没有完成", MockInterviewText.error(error)) }
            busy = nil
        }
    }
}

/// `Wave`：一排小竖条，左边 72% 着色。
struct MockWave: View {
    var level: Double
    var width: CGFloat = 300
    var flat = false
    @State private var history: [Double] = Array(repeating: 0, count: 60)
    var body: some View {
        let count = Int(width / 5)
        Canvas { context, _ in
            for index in 0..<count {
                let source = history[Int(Double(index) / Double(count) * Double(history.count))]
                let height = flat ? 2 : 3 + min(1, source * 2.4) * 18
                let lit = !flat && Double(index) < Double(count) * 0.72
                context.fill(Path(roundedRect: CGRect(x: Double(index) * 5, y: 12 - height / 2, width: 2.4, height: height), cornerRadius: 1.2),
                             with: .color(lit ? MI.blue : MI.gry.opacity(0.5)))
            }
        }
        .frame(width: width, height: 24)
        .onChange(of: level) { _, value in history.removeFirst(); history.append(value) }
        .accessibilityHidden(true)
    }
}

// MARK: 检查设备（Web `DeviceCheckStage`）

struct MockDeviceCheck: View {
    @Environment(SessionStore.self) private var session
    let detail: JSONValue
    let context: MockSessionContext
    let busy: String?
    let onStart: () -> Void
    let onBack: () -> Void
    let onSwitchToText: () -> Void

    private enum Trial { case idle, listening, recognizing, ok, empty, failed }
    private enum Speaker { case idle, playing, confirm, heard, unheard, unsupported }
    @State private var mic = MicrophoneProbe()
    @State private var recorder = VoiceRecorder()
    @State private var heardVoice = false
    @State private var quiet = false
    @State private var trial: Trial = .idle
    @State private var heardText = ""
    @State private var speaker: Speaker = .idle
    @State private var player = InterviewerVoice()
    @State private var trialStart = Date()
    @State private var trialVoiceAt: Date?

    private static let phrase = "我准备好了，可以开始了"
    private static let threshold: Float = 0.06

    var body: some View {
        let count = detail["question_count"]?.integer ?? 5
        var map = context.map(detail, current: nil, phase: .done)
        let focus = detail["practice_focus"]?.text("label").nonEmptyValue.flatMap { label in map.points.first { $0.name == label } }
        if let focus { map.hot = [focus.id] + map.hot }
        let granted = mic.permission == .granted
        let blocked = mic.permission == .denied || mic.permission == .error
        let silent = granted && quiet && !heardVoice
        let micBad = blocked || silent
        let speakerBad = speaker == .unheard
        let preparing = detail.text("status") == "preparing"
        let ready = granted && trial == .ok && !preparing
        return SessionFrame {
            SessionTop(title: MockSession.heading(detail), sub: MockSession.subtitle(detail), center: "检查设备", exit: (busy == "back" ? "正在返回…" : "退出", onBack))
            SessionMapView(map: map, targetLevel: MockMap.diffLevel[detail.text("difficulty")] ?? 3, caption: false, labelAll: true)
            SessionHorizonView(beads: MockSession.beads(detail, nil), introNow: false)
            if mic.permission == .unavailable {
                MockPrepColumn {
                    MockPrepTitle(title: "这台设备暂时没法语音面试", sub: "没有找到可用的麦克风，或者系统不允许录音。")
                    VStack(alignment: .leading, spacing: 12) {
                        missing("·  没有检测到麦克风", "插上耳机或外接麦克风后再试")
                        missing("·  系统没有可用的输入设备", "在“系统设置 › 声音 › 输入”里选一个麦克风")
                    }.padding(.top, 22)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("改成文字面试，题目不用重新准备").font(V3.sans(14, weight: .medium)).foregroundStyle(MI.ink)
                        Text(verbatim: "同一套 \(count) 道题，打字作答").font(V3.sans(12)).foregroundStyle(MI.sub)
                        HStack(spacing: 14) {
                            Button(busy == "text" ? "正在切换…" : "改为文字面试", action: onSwitchToText).buttonStyle(MockBigButtonStyle()).disabled(busy != nil)
                            Button("重新检测") { recheck() }.buttonStyle(MockQuietStyle(size: 13))
                        }.padding(.top, 14)
                    }.padding(.vertical, 16).padding(.horizontal, 20).overlay(alignment: .leading) { Rectangle().fill(MI.blue).frame(width: 1.5) }.padding(.top, 34)
                }
            } else {
                MockPrepColumn {
                    MockPrepTitle(title: "开始前，试一下声音", sub: "面试官会用语音提问，你直接开口回答，停顿 3 秒自动提交。\(count) 题 · 约 \(count * 5) 分钟。")
                    VStack(alignment: .leading, spacing: 0) {
                        check("麦克风", state: blocked ? (.or, "没有权限") : silent ? (.or, "没听到声音") : granted ? (.blue, "音量正常") : (.mute, "正在请求…")) {
                            if blocked { note("系统没有给麦克风权限。在“系统设置 › 隐私与安全性 › 麦克风”中允许 DrawOffer，然后重新检测。", or: true) }
                            if silent { note("换一个麦克风，或检查是否静音", or: true) }
                            if !blocked {
                                HStack(spacing: 20) {
                                    Button { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!) } label: {
                                        Text(verbatim: "\(mic.deviceName.nonEmptyValue ?? "默认麦克风") ⌄").font(V3.sans(12)).foregroundStyle(MI.ink).lineLimit(1)
                                            .frame(width: 186, height: 22, alignment: .leading).padding(.horizontal, 10)
                                            .background(.white, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(MI.line))
                                    }.buttonStyle(.plain).accessibilityLabel("选择麦克风")
                                    MockWave(level: Double(mic.level), width: 150, flat: !granted).padding(.top, 0)
                                }.padding(.top, 6)
                            }
                        }
                        check("读一句话试试", state: !granted ? (.mute, "等麦克风可用") : trial == .ok ? (.blue, "识别正常") : trial == .recognizing ? (.mute, "正在识别…") : trial == .empty || trial == .failed ? (.or, "没听清") : (.blue, "正在听…")) {
                            note(!granted ? "等麦克风可用" : trial == .ok ? "请读：「\(Self.phrase)」 → 识别成「\(heardText)」" : trial == .empty || trial == .failed ? "没听清，靠近麦克风再读一遍" : "请读：「\(Self.phrase)」" + (recorder.partial.isEmpty ? "" : " → \(recorder.partial)"))
                            if granted && [.empty, .failed, .ok].contains(trial) {
                                Button("再读一遍") { beginTrial() }.buttonStyle(MockQuietStyle(color: MI.blue)).frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        check("面试官声音", state: speaker == .heard ? (.blue, "听得到") : speaker == .confirm ? (.blue, "听到了吗？") : speaker == .unheard ? (.or, "听不到") : speaker == .unsupported ? (.or, "没能播放") : speaker == .playing ? (.mute, "正在播放…") : (.mute, "还没试听")) {
                            note(speakerBad ? "听不到？调大音量或换耳机" : speaker == .unsupported ? "这台设备没能播放声音，面试时可以看字幕作答" : "点试听，确认能听到", or: speakerBad)
                            HStack(spacing: 20) {
                                if speaker == .confirm {
                                    Button("听得到") { speaker = .heard }.buttonStyle(MockQuietStyle(color: MI.blue))
                                    Button("听不到") { speaker = .unheard }.buttonStyle(MockQuietStyle(color: MI.orange))
                                }
                                Button("▶ \(speaker == .idle ? "试听" : "再试听")") { Task { await preview() } }.buttonStyle(MockQuietStyle(color: MI.blue)).disabled(speaker == .playing)
                            }.frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 6)
                        }
                    }.frame(width: 488).padding(.top, 28)
                    HStack(spacing: 14) {
                        if micBad || speakerBad {
                            Button("重新检测") { recheck() }.buttonStyle(MockBigButtonStyle())
                            Button(busy == "text" ? "正在切换…" : "改为文字面试", action: onSwitchToText).buttonStyle(MockQuietStyle(size: 13)).disabled(busy != nil)
                        } else {
                            Button(preparing ? "题目还在准备…" : "开始语音面试") { mic.stop(); recorder.cancel(); player.stop(); onStart() }
                                .buttonStyle(MockBigButtonStyle(kind: ready ? .dark : .off)).disabled(!ready)
                            Button(busy == "text" ? "正在切换…" : "不方便说话？改为文字面试", action: onSwitchToText).buttonStyle(MockQuietStyle(size: 13)).disabled(busy != nil)
                        }
                    }.padding(.top, 28)
                    Text("安静环境、戴耳机效果更好；回答会保存录音和识别文字，报告里可以对照修正。").font(V3.sans(13)).foregroundStyle(MI.sub).frame(height: 20).padding(.top, 8)
                }
            }
        }
        .task { if mic.permission == .idle { await mic.start() } }
        .onChange(of: mic.level) { _, level in
            if level > Self.threshold * 1.5 { heardVoice = true; quiet = false }
            if trial == .listening && level > Self.threshold { trialVoiceAt = Date() }
        }
        .task(id: "\(mic.permission == .granted)-\(heardVoice)") {
            guard mic.permission == .granted, !heardVoice else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, !heardVoice { quiet = true }
        }
        .onChange(of: mic.permission) { _, value in if value == .granted && trial == .idle { beginTrial() } }
        .task(id: trial == .listening) {
            // 读完一句并停顿约 1.2 秒结束试读；最长 12 秒
            while trial == .listening && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                let elapsed = Date().timeIntervalSince(trialStart)
                if let at = trialVoiceAt, Date().timeIntervalSince(at) >= 1.2 { await finishTrial(); return }
                if elapsed >= 12 { await finishTrial(); return }
            }
        }
        .onDisappear { mic.stop(); recorder.cancel(); player.stop() }
    }

    private func check<Extra: View>(_ title: String, state: (MockTone, String), @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: title).font(V3.sans(14, weight: .medium)).foregroundStyle(MI.ink)
                Spacer()
                HStack(spacing: 6) { Circle().fill(state.0.color).frame(width: 6, height: 6); Text(verbatim: state.1) }.font(V3.sans(12, weight: .medium)).foregroundStyle(state.0.color)
            }
            extra()
        }
        .padding(.top, 14).padding(.bottom, 18)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xE6E3DC)).frame(height: 1) }
    }
    private func note(_ text: String, or: Bool = false) -> some View {
        Text(verbatim: text).font(V3.sans(12)).foregroundStyle(or ? MI.orange : MI.mute).lineSpacing(12 * 0.5).fixedSize(horizontal: false, vertical: true)
    }
    private func missing(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(V3.sans(13.5, weight: .medium)).foregroundStyle(MI.ink)
            Text(verbatim: sub).font(V3.sans(12)).foregroundStyle(MI.mute).padding(.leading, 18)
        }
    }

    private func beginTrial() {
        recorder.cancel(); heardText = ""; trialVoiceAt = nil; trialStart = Date(); trial = .listening
        Task { await recorder.start(api: session.api, interviewID: detail.display("id"), questionID: "", purpose: "device_check") }
    }
    private func finishTrial() async {
        trial = .recognizing
        do {
            let text = try await recorder.stop().text.trimmingCharacters(in: .whitespacesAndNewlines)
            heardText = text; trial = text.isEmpty ? .empty : .ok
            if !text.isEmpty { heardVoice = true; quiet = false }
        } catch { trial = .failed }
    }
    private func recheck() {
        heardVoice = false; quiet = false; trial = .idle; speaker = .idle; recorder.cancel()
        Task { await mic.start() }
    }
    private func preview() async {
        player.stop(); speaker = .playing
        do {
            player.play(try await session.api.mockAudio(path: "/api/mock-interviews/\(detail.display("id"))/speech/playback", method: "POST", body: .object([:])))
            try? await Task.sleep(for: .milliseconds(300))
            while player.playing { try? await Task.sleep(for: .milliseconds(200)) }
            speaker = .confirm
        } catch { speaker = .unsupported }
    }
}
