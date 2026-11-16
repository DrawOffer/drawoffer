import AppKit
import Foundation
import DrawOfferCore
import SwiftUI

/// 语音面试（Figma 09 · 03 开始前、05 面试中 05.01–05.07；Web `VoiceSessionV2` + `DeviceCheckStage`）：
/// 准备题目 → 检查设备 → 面试官念题（字幕逐字）→ 开口作答，答完点「说完了」（停顿思考不会被打断，最长 5 分钟自动提交）
/// → 面试官看笔记 → 下一题；没听清时请你再说一遍。录音与识别沿用 `VoiceRecorder`。
struct MockVoiceSession: View {
    @Environment(SessionStore.self) private var session
    let detail: JSONValue
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
    @State private var feedback: JSONValue?
    @State private var noted = 0
    @State private var dialog: String?
    @State private var busy: String?
    @State private var notice: MockNotice?
    @State private var recorder = VoiceRecorder()
    @State private var voice = InterviewerVoice()
    @State private var history: [Double] = []

    private static let unclearText = "抱歉，刚才这段没听清，可以再说一遍吗？"
    private static let charInterval = Duration.milliseconds(90)
    private static let pauseHint = 1.0, silenceHint = 8.0, maxRecording = 5.0 * 60
    private static let threshold: Float = 0.06

    var body: some View {
        Group {
            switch phase {
            case .prep: MockPrepStage(detail: local, changed: changed, home: home, onCheckDevice: { phase = .check })
            case .check:
                MockDeviceCheck(detail: local, busy: busy, onStart: start, onBack: { dialog = "back" }, onSwitchToText: { dialog = "text" })
            default: interview
            }
        }
        .overlay { MockNoticeToast(notice: $notice) }
        .modifier(MockSessionDialogs(detail: local, dialog: $dialog, busy: busy, voice: true, skip: skip, end: end))
        .mockDialog($dialog, "back") {
            let preparing = local.text("status") == "preparing"
            MockConfirmCard(title: "返回修改设置？", desc: preparing ? "题目还在准备，返回后这场记为已放弃，不扣积分。" : "返回后这场记为已放弃，改好设置再开始新的一场。",
                            confirm: "返回改设置", cancel: preparing ? "继续准备" : "继续面试", busy: busy == "back", busyLabel: "正在返回…",
                            onConfirm: { leaveCheck("back") }, onCancel: { dialog = nil })
        }
        .mockDialog($dialog, "text") {
            MockConfirmCard(title: "改为文字面试？", desc: "沿用同一套题目，改成打字作答，也可以语音转文字。", confirm: "改为文字面试",
                            busy: busy == "text", busyLabel: "正在切换…", onConfirm: { leaveCheck("text") }, onCancel: { dialog = nil })
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

    // MARK: 作答画面（05.01 面试官在问 / 05.02 轮到你 / 05.03 停顿 / 05.04 看笔记 / 05.05 没听清 / 05.06 提交失败 / 05.07 结束语）

    private var interview: some View {
        let shownQuestion = question ?? (phase == .closing ? nil : MockSession.lastAsked(local))
        let intro = shownQuestion.map { MockSessionText.isIntro(local, $0) } ?? false
        let follow = shownQuestion?.text("kind") == "follow_up"
        let speaking = heard || !recorder.partial.isEmpty
        let liveText = recorder.partial.isEmpty ? transcript : recorder.partial
        let spoken = phase == .unclear ? Self.unclearText : askText
        let questionText = phase == .unclear ? shownQuestion?.text("content") ?? "" : phase == .asking || phase == .closing ? spoken : shownQuestion?.text("content") ?? spoken
        let skipLocked = busy != nil || question == nil || [.submitting, .closing, .unclear].contains(phase)
        let talking = [.asking, .closing, .unclear].contains(phase)
        return TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
            let recordingMs = phase == .listening ? timeline.date.timeIntervalSince(recordStart) : 0
            let silent = phase == .listening ? timeline.date.timeIntervalSince(lastVoice) : 0
            let pausing = phase == .listening && heard && silent >= Self.pauseHint
            let silentLong = phase == .listening && !speaking && recordingMs >= Self.silenceHint
            let status: (String, Bool) = phase == .submitFailed ? (recognized != nil ? "这段回答没提交成功，录音和文字都还在" : "面试官的回复没生成，你的回答已经保存", true)
                : phase == .submitting ? (busy == "skip" ? "跳过了这道题" : "面试官在看笔记…", false)
                : phase == .unclear ? (Self.unclearText, false)
                : phase == .closing ? ("面试官在说结束语", false)
                : silentLong ? ("还在想吗？可以先说思路；实在不会，点右上角跳过此题", true)
                : pausing ? ("停顿中 · 想好了接着说 · \(MockSession.mmss(recordingMs))", false)
                : phase == .listening ? ("轮到你 · \(MockSession.mmss(recordingMs))", false)
                : (follow ? "面试官在追问" : "面试官在问", false)
            let note: (String, Bool)? = recordingDropped && phase != .closing ? ("音视频空间已满，这些回答的录音没有保存；回答和识别文字照常保存", true)
                : intro && phase == .asking ? ("面试官说完直接开口，答完点「说完了」；停顿思考不会被打断", false)
                : phase == .unclear ? ("没听清不算答错，也不计入追问次数", false) : nil
            let subtitle = [.listening, .submitting, .submitFailed].contains(phase) ? liveText : ""
            MockSessionFrame {
                MockSessionHead(detail: local, timer: MockSessionText.elapsed(local, now: timeline.date)) {
                    Button("跳过此题") { dialog = "skip" }.buttonStyle(MockLinkStyle()).disabled(skipLocked)
                    Button("放弃") { dialog = "abandon" }.buttonStyle(MockLinkStyle()).disabled(busy != nil || phase == .closing)
                    Button("结束并评估") { dialog = "finish" }.buttonStyle(MockPillStyle(kind: .ghost)).disabled(busy != nil || phase == .closing || phase == .submitting)
                }
                MockCenterLine(text: phase == .closing ? "面试结束" : MockSessionText.eyebrow(local, shownQuestion), top: 175)
                MockBigQuestion(text: questionText, shown: phase == .asking && shown < spoken.count ? shown : .max)
                MockLiveVoiceprint(tone: talking ? .interviewer : phase == .listening ? .you : phase == .submitting ? .rest : .flat, values: history)
                    .offset(x: 234, y: 373)
                HStack(spacing: 12) {
                    Text(verbatim: status.0).foregroundStyle(status.1 ? MockPalette.orange : MockPalette.sub)
                    if audioFailed && phase == .asking {
                        Text("先看字幕作答").foregroundStyle(MockPalette.sub)
                        Button("重试声音") { replay() }.buttonStyle(MockLinkStyle(blue: true, size: 14))
                    }
                }
                .font(V3.sans(14)).frame(width: 1120, height: 22).offset(x: 124, y: 499)
                if !subtitle.isEmpty {
                    let tail = String(subtitle.suffix(48))
                    Text(verbatim: tail).font(V3.sans(17)).foregroundStyle(phase == .listening && !recorder.partial.isEmpty ? MockPalette.faint : MockPalette.ink)
                        .lineLimit(1).truncationMode(.head).frame(width: 900, height: 28).offset(x: 234, y: 527)
                }
                actions(speaking: speaking, intro: intro)
                if let note {
                    MockCenterLine(text: note.0, top: 696, color: note.1 ? MockPalette.orange : MockPalette.mute)
                }
                MockSessionFoot(goal: local.text("practice_goal")) { MockAnswerFeedback(feedback: feedback, notes: noted) }
            }
            .task(id: Int(recordingMs)) { if phase == .listening && recordingMs >= Self.maxRecording { stopAndSubmit() } }
        }
        .modifier(MockLevelHistory(level: recorder.level, history: $history))
        .task(id: "\(phase)-\(shown)-\(spoken.count)") { await typeAhead(spoken) }
        .onChange(of: recorder.level) { _, level in
            guard phase == .listening else { return }
            if level > Self.threshold { heard = true; lastVoice = Date() }
        }
        .onChange(of: recorder.partial) { _, value in if phase == .listening && !value.isEmpty { heard = true; lastVoice = Date() } }
        .onChange(of: recorder.phase) { _, value in
            if phase == .listening, case .failed(let message) = value { notice = MockNotice(title: "录音没能继续", message: message); shown = 0; phase = .unclear }
        }
    }

    /// 打断并作答（面试官在问）/ 说完了（作答中）/ 重新回答（没听清）/ 重新提交、重新生成（提交失败）。
    @ViewBuilder private func actions(speaking: Bool, intro: Bool) -> some View {
        Group {
            if phase == .asking && question != nil && !intro {
                Button("打断并作答") { beginAnswer() }.buttonStyle(MockPillStyle(kind: .ghost)).offset(y: 543)
            } else if phase == .listening && speaking {
                Button("说完了") { stopAndSubmit() }.buttonStyle(MockPillStyle()).offset(y: 577)
            } else if phase == .unclear {
                Button("重新回答") { beginAnswer() }.buttonStyle(MockPillStyle()).offset(y: 543)
            } else if phase == .submitFailed {
                Button(recognized != nil ? "重新提交" : "重新生成") { if let recognized { submit(recognized) } else { regenerate() } }.buttonStyle(MockPillStyle()).offset(y: 577)
            }
        }
        .frame(width: MockFull.width)
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
            catch { notice = MockNotice(title: "面试官的声音还是没放出来", message: MockInterviewText.error(error)) }
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
        recognized = nil; transcript = ""; heard = false; recordStart = Date(); lastVoice = Date(); history = []
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
            } catch { phase = .submitFailed; notice = MockNotice(title: "回答没有提交成功", message: MockInterviewText.error(error)) }
        }
    }

    private func regenerate() {
        phase = .submitting
        Task {
            do { try await consume("reply:retry", body: nil) }
            catch { phase = .submitFailed; notice = MockNotice(title: "面试官的回复没有生成出来", message: MockInterviewText.error(error)) }
        }
    }

    private func skip() {
        guard let question, busy == nil else { return }
        busy = "skip"; dialog = nil; recorder.cancel(); voice.stop(); transcript = ""; phase = .submitting
        Task {
            do { try await consume("skip", body: .object(["question_id": question["id"] ?? .null, "__idempotency_key": .string(UUID().uuidString.lowercased())])) }
            catch { notice = MockNotice(title: "没有跳过这道题", message: MockInterviewText.error(error)); beginAnswer() }
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
                noted = notes.items.count
                if case .object(var fields) = local {
                    fields["questions"] = .array((local["questions"]?.items ?? []).map { item in
                        guard item.display("id") == id, case .object(var q) = item else { return item }
                        q["notes"] = notes; return .object(q)
                    })
                    local = .object(fields)
                }
            case "interviewer.delta": spoken += data.text("content")
            case "interviewer.audio_failed": audioFailed = true
            case "answer.accepted":
                if data["recording_dropped"]?.bool == true { recordingDropped = true }
                feedback = data["feedback"]; noted = 0
            case "interviewer.turn": end = data
            default: break
            }
        }
        guard let end else { throw APIError.server(status: 502, code: "MOCK_INTERVIEW_TURN_FAILED") }
        if events.contains(where: { $0.text("event") == "interviewer.audio" }) { voice.enqueue(events: events) }
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
            } catch { notice = MockNotice(title: kind == "finish" ? "没有结束面试" : "没有放弃面试", message: MockInterviewText.error(error)) }
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
            } catch { notice = MockNotice(title: "操作没有完成", message: MockInterviewText.error(error)) }
            busy = nil
        }
    }
}

// MARK: 检查设备（Figma 09 · 03 开始前 03.03 先试一下声音、03.04 这台设备暂时没法语音面试；Web `DeviceCheckStage`）

struct MockDeviceCheck: View {
    @Environment(SessionStore.self) private var session
    let detail: JSONValue
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
    @State private var speaker: Speaker = .idle
    @State private var player = InterviewerVoice()
    @State private var trialStart = Date()
    @State private var trialVoiceAt: Date?
    @State private var history: [Double] = []

    private static let phrase = "我准备好了，可以开始了"
    private static let threshold: Float = 0.06

    var body: some View {
        let granted = mic.permission == .granted
        let blocked = mic.permission == .denied || mic.permission == .error
        let silent = granted && quiet && !heardVoice
        let micBad = blocked || silent
        let speakerBad = speaker == .unheard
        let preparing = detail.text("status") == "preparing"
        let ready = granted && trial == .ok && !preparing
        MockSessionFrame {
            MockSessionHead(detail: detail, back: (busy == "back" ? "正在返回…" : "面试设置", busy != nil, onBack))
            MockCenterLine(text: "开始前", top: 175)
            if mic.permission == .unavailable {
                MockCenterLine(text: "这台设备暂时没法语音面试", top: 203, size: 46, line: 64, color: MockPalette.ink, serif: true)
                MockCenterLine(text: "同一套 \(detail["question_count"]?.integer ?? 0) 道题可以改成打字作答，题目不用重新准备。", top: 277, size: 15, line: 26, color: MockPalette.sub)
                VStack(alignment: .leading, spacing: 20) {
                    row("没有检测到麦克风", sub: { Text("插上耳机或外接麦克风后再试") }, state: nil)
                    divider
                    row("系统没有可用的输入设备", sub: { Text("在“系统设置 › 声音 › 输入”里选一个麦克风") }, state: nil)
                }.frame(width: 600, alignment: .leading).offset(x: 384, y: 339)
                MockSessionFoot(goal: detail.text("practice_goal")) {
                    Button("重新检测") { recheck() }.buttonStyle(MockLinkStyle())
                    Button(busy == "text" ? "正在切换…" : "改为文字面试", action: onSwitchToText).buttonStyle(MockPillStyle()).disabled(busy != nil)
                }
            } else {
                MockCenterLine(text: "先试一下声音", top: 203, size: 46, line: 64, color: MockPalette.ink, serif: true)
                MockCenterLine(text: "安静环境、戴耳机效果更好。", top: 277, size: 15, line: 26, color: MockPalette.sub)
                VStack(alignment: .leading, spacing: 20) {
                    row("麦克风", sub: {
                        if blocked {
                            Text("在“系统设置 › 隐私与安全性 › 麦克风”中允许 DrawOffer，然后重新检测").foregroundStyle(MockPalette.orange)
                        } else {
                            Button { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!) } label: {
                                Text(verbatim: "\(mic.deviceName.nonEmptyValue ?? "默认麦克风") ⌄").foregroundStyle(silent ? MockPalette.orange : MockPalette.fnt).lineLimit(1).frame(maxWidth: 240, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityLabel("选择麦克风")
                        }
                    }, wave: granted, state: blocked ? (false, "没有权限") : silent ? (false, "没听到声音") : granted ? (true, "正常") : nil, waiting: "正在请求…")
                    divider
                    row("读一句话试试", sub: {
                        Text(verbatim: trial == .empty || trial == .failed ? "没听清，靠近麦克风再读一遍" : "请读：\(Self.phrase)")
                            .foregroundStyle(trial == .empty || trial == .failed ? MockPalette.orange : MockPalette.fnt)
                        if granted && [.empty, .failed, .ok].contains(trial) { Button("再读一遍") { beginTrial() }.buttonStyle(MockLinkStyle(blue: true)) }
                    }, state: !granted ? nil : trial == .ok ? (true, "识别成功") : trial == .empty || trial == .failed ? (false, "没听清") : nil,
                        waiting: !granted ? "等麦克风可用" : trial == .recognizing ? "正在识别…" : "正在听…")
                    divider
                    row("面试官声音", sub: {
                        Button("▶ \(speaker == .idle ? "试听" : "再听一次")") { Task { await preview() } }.buttonStyle(MockLinkStyle()).disabled(speaker == .playing)
                        if speakerBad { Text("调大音量或换耳机").foregroundStyle(MockPalette.orange) }
                        if speaker == .unsupported { Text("面试时可以看字幕作答") }
                        if speaker == .confirm {
                            Button("听得到") { speaker = .heard }.buttonStyle(MockLinkStyle(blue: true))
                            Button("听不到") { speaker = .unheard }.buttonStyle(MockLinkStyle())
                        }
                    }, state: speaker == .heard ? (true, "听得到") : speaker == .unheard ? (false, "听不到") : speaker == .unsupported ? (false, "没能播放") : nil,
                        waiting: speaker == .confirm ? "听到了吗？" : speaker == .playing ? "正在播放…" : "还没试听")
                }.frame(width: 600, alignment: .leading).offset(x: 384, y: 339)
                MockSessionFoot(goal: detail.text("practice_goal")) {
                    Button(busy == "text" ? "正在切换…" : micBad || speakerBad ? "改为文字面试" : "不方便说话？改为文字面试", action: onSwitchToText).buttonStyle(MockLinkStyle()).disabled(busy != nil)
                    if micBad || speakerBad {
                        Button("重新检测") { recheck() }.buttonStyle(MockPillStyle())
                    } else {
                        Button(preparing ? "题目还在准备…" : "开始语音面试") { mic.stop(); recorder.cancel(); player.stop(); onStart() }.buttonStyle(MockPillStyle()).disabled(!ready)
                    }
                }
            }
        }
        .modifier(MockLevelHistory(level: mic.level, history: $history))
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
        .onChange(of: mic.permission, initial: true) { _, value in if value == .granted && trial == .idle { beginTrial() } }
        .task(id: trial == .listening) {
            // 读完一句并停顿约 1.2 秒结束试读；最长 12 秒
            while trial == .listening && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                if let at = trialVoiceAt, Date().timeIntervalSince(at) >= 1.2 { await finishTrial(); return }
                if Date().timeIntervalSince(trialStart) >= 12 { await finishTrial(); return }
            }
        }
        .onDisappear { mic.stop(); recorder.cancel(); player.stop() }
    }

    private var divider: some View { Rectangle().fill(MockPalette.line).frame(width: 600, height: 1) }

    /// `.mi3-check`：一行 84 高，左边标题 + 一行说明，右边状态（蓝点正常、橙点有问题、灰点等待）。
    private func row<Sub: View>(_ title: String, @ViewBuilder sub: () -> Sub, wave: Bool = false, state: (Bool, String)?, waiting: String = "") -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title).font(V3.sans(15, weight: .medium)).foregroundStyle(MockPalette.ink).frame(height: 22)
                HStack(spacing: 12) { sub() }.font(V3.sans(13)).foregroundStyle(MockPalette.fnt).lineLimit(1).frame(height: 20)
            }
            if wave { MockMiniVoiceprint(values: history).offset(x: 280, y: 24) }
            if !(state == nil && waiting.isEmpty) {
                let color = state.map { $0.0 ? MockPalette.blue : MockPalette.orange } ?? MockPalette.mute
                HStack(spacing: 8) { Circle().fill(color).frame(width: 7, height: 7); Text(verbatim: state?.1 ?? waiting) }
                    .font(V3.sans(13, weight: .medium)).foregroundStyle(color).frame(height: 20)
                    .frame(width: 600, alignment: .trailing).offset(y: 13)
            }
        }
        .frame(width: 600, height: 64, alignment: .topLeading)
    }

    private func beginTrial() {
        recorder.cancel(); trialVoiceAt = nil; trialStart = Date(); trial = .listening
        Task { await recorder.start(api: session.api, interviewID: detail.display("id"), questionID: "", purpose: "device_check") }
    }
    private func finishTrial() async {
        trial = .recognizing
        do {
            let text = try await recorder.stop().text.trimmingCharacters(in: .whitespacesAndNewlines)
            trial = text.isEmpty ? .empty : .ok
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
