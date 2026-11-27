import AppKit
@preconcurrency import AVFoundation
import CoreAudio
import DrawOfferCore
import SwiftUI

/// 实时语音作答（Web `SpeechRecognition` + `useMicrophone`）：AVAudioEngine 取麦克风，转换为 16 kHz 单声道 PCM16，
/// 约每 100ms 一帧经 `WS /api/mock-interviews/{id}/speech` 发送；停止时发 `{"type":"stop"}`，等待 `final` 取得一次性
/// `session_id`。握手超时 15 秒、停止后 30 秒没有最终稿按识别失败处理，发送积压超过 1 MB 主动放弃。录音不落盘。
/// 本机识别资源已装好时改用本机识别（macOS 26 用 `LocalTranscriber`，更早用 `SenseVoiceTranscriber`，不计费）：音频照常上传供保存录音，
/// 实时文字来自本机，停止时随 `stop` 发出文字与逐词时间；其余情况走服务端识别。
@MainActor @Observable
final class VoiceRecorder {
    enum Phase: Equatable { case idle, connecting, recording, finishing, failed(String) }
    struct Final: Sendable { let sessionID: String; let text: String; let durationMs: Int }

    private(set) var phase: Phase = .idle
    private(set) var partial = ""
    private(set) var level: Float = 0
    private var engine: AVAudioEngine?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var finalWaiter: CheckedContinuation<Final, Error>?
    private var pendingBytes = 0
    private var earlyFinal: Final?
    private var local: LocalSession?
    private var sentBytes = 0

    nonisolated(unsafe) static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    func start(api: any APIClient, interviewID: String, questionID: String, purpose: String = "voice_answer") async {
        guard phase == .idle || { if case .failed = phase { return true }; return false }() else { return }
        partial = ""; earlyFinal = nil; sentBytes = 0; phase = .connecting
        guard await Self.microphoneAllowed() else { phase = .failed("没有麦克风权限。请在“系统设置 › 隐私与安全性 › 麦克风”中允许 DrawOffer。"); return }
        do {
            let engine = AVAudioEngine()
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: Self.targetFormat) else { throw APIError.invalidResponse }
            let local = await LocalSpeech.start(inputFormat: format) { [weak self] text in
                guard let self, self.phase == .recording || self.phase == .finishing else { return }
                self.partial = text
            }
            self.local = local
            let socket = try await api.speechSocket(interviewID: interviewID, questionID: questionID, purpose: purpose, local: local != nil)
            self.socket = socket
            socket.resume()
            receiver = Task { [weak self] in await self?.receive(socket) }
            try startEngine(engine, converter: converter, socket: socket, local: local)
            phase = .recording
        } catch {
            if case APIError.unauthorized = error { phase = .failed("登录已失效，请重新登录。") }
            else { phase = .failed("无法开始录音：\(error.localizedDescription)") }
            teardown()
        }
    }

    /// 停止录音并等待服务端最终识别稿（30 秒超时）。最终稿可能早于等待开始到达，因此先暂存。
    func stop() async throws -> Final {
        guard phase == .recording, let socket else { throw APIError.invalidResponse }
        phase = .finishing
        stopEngine()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.fail("识别超时，请重新录音。")
        }
        defer { timeout.cancel() }
        if let local {
            self.local = nil
            let transcript: LocalTranscript
            do { transcript = try await local.finish() } catch {
                socket.cancel(with: .goingAway, reason: nil)
                fail("本机识别失败，请重新录音。")
                throw APIError.server(status: 502, code: "本机识别失败，请重新录音。")
            }
            guard phase == .finishing, self.socket === socket else { throw APIError.server(status: 502, code: "识别超时，请重新录音。") }
            partial = transcript.text
            try await socket.send(.string(transcript.stopMessage(durationMs: sentBytes / 32)))
        } else {
            try await socket.send(.string("{\"type\":\"stop\"}"))
        }
        if let early = earlyFinal { earlyFinal = nil; return early }
        return try await withCheckedThrowingContinuation { finalWaiter = $0 }
    }

    func cancel() {
        socket?.cancel(with: .goingAway, reason: nil)
        fail(nil)
    }

    private func fail(_ message: String?) {
        if let waiter = finalWaiter { finalWaiter = nil; waiter.resume(throwing: APIError.server(status: 502, code: message ?? "MOCK_INTERVIEW_SPEECH_CANCELLED")) }
        teardown()
        phase = message.map { .failed($0) } ?? .idle
    }

    private func teardown() {
        stopEngine()
        if let local { Task { await local.cancel() } }
        local = nil
        receiver?.cancel(); receiver = nil
        socket = nil; pendingBytes = 0; level = 0
    }

    private func receive(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do { message = try await socket.receive() }
            catch {
                guard finalWaiter != nil || phase == .recording || phase == .connecting else { return }
                let code = socket.closeCode.rawValue
                fail(code == 4401 ? "登录已失效，请重新登录。" : code == 4409 ? "面试状态已变化，请刷新后再作答。" : "语音识别连接中断，请重新录音。")
                return
            }
            guard case .string(let text) = message, let data = text.data(using: .utf8),
                  let event = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
            switch event.text("type") {
            case "partial": partial = event.text("text")
            case "final":
                let result = Final(sessionID: event.text("session_id"), text: event.text("text"), durationMs: event["duration_ms"]?.integer ?? 0)
                partial = result.text
                if let waiter = finalWaiter { finalWaiter = nil; waiter.resume(returning: result) } else { earlyFinal = result }
                teardown(); phase = .idle
                return
            case "error":
                let code = event.text("code")
                fail(code == "MOCK_INTERVIEW_SPEECH_UNAVAILABLE" ? "语音识别暂未开放，请联系管理员配置语音线路。" : "语音识别失败（\(code)），请重新录音。")
                return
            default: continue
            }
        }
    }

    private func startEngine(_ engine: AVAudioEngine, converter: AVAudioConverter, socket: URLSessionWebSocketTask, local: LocalSession?) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let frames = AVAudioFrameCount(format.sampleRate / 10)
        let deliver: @Sendable (Data, Float) -> Void = { [weak self] data, level in
            Task { @MainActor [weak self] in self?.send(data, level: level, socket: socket) }
        }
        input.installTap(onBus: 0, bufferSize: frames, format: format, block: Self.tap(converter: converter, local: local, deliver: deliver))
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    private func send(_ data: Data, level: Float, socket: URLSessionWebSocketTask) {
        guard phase == .recording, self.socket === socket else { return }
        self.level = level
        guard pendingBytes + data.count <= 1024 * 1024 else { socket.cancel(with: .goingAway, reason: nil); fail("网络太慢，录音没能及时发送，请重新录音。"); return }
        pendingBytes += data.count
        sentBytes += data.count
        socket.send(.data(data)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingBytes = max(0, self.pendingBytes - data.count)
                if error != nil, self.phase == .recording { self.fail("语音识别连接中断，请重新录音。") }
            }
        }
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// 麦克风回调在音频线程执行，必须在非隔离上下文中创建，不能继承 MainActor。
    nonisolated static func tap(converter: AVAudioConverter, local: LocalSession?, deliver: @escaping @Sendable (Data, Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            local?.feed(buffer)
            guard let data = convert(buffer, with: converter) else { return }
            deliver(data, rms(buffer))
        }
    }

    nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> Data? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        // 输入块同步调用，只交出这一个缓冲；用引用类型承载标记，避免并发捕获可变局部变量。
        final class Once: @unchecked Sendable { var consumed = false }
        let once = Once()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if once.consumed { status.pointee = .noDataNow; return nil }
            once.consumed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[0][index] * channel[0][index] }
        return min(1, (sum / Float(buffer.frameLength)).squareRoot() * 4)
    }

    static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// 面试官语音：按 seq 顺序播放回合 SSE 中的 mp3 片段与试听音频；失败只保留字幕，不影响面试。
@MainActor @Observable
final class InterviewerVoice: NSObject, AVAudioPlayerDelegate {
    private(set) var playing = false
    private var queue: [Data] = []
    private var player: AVAudioPlayer?

    func enqueue(events: [JSONValue]) {
        let audio = events.filter { $0.text("event") == "interviewer.audio" }
            .sorted { ($0["data"]?["seq"]?.integer ?? 0) < ($1["data"]?["seq"]?.integer ?? 0) }
            .compactMap { Data(base64Encoded: $0["data"]?.text("data") ?? "") }
        queue += audio
        if !playing { next() }
    }

    func play(_ data: Data) { queue.append(data); if !playing { next() } }

    func stop() { queue.removeAll(); player?.stop(); player = nil; playing = false }

    private func next() {
        guard !queue.isEmpty else { playing = false; player = nil; return }
        let data = queue.removeFirst()
        guard let player = try? AVAudioPlayer(data: data) else { next(); return }
        player.delegate = self
        self.player = player
        playing = player.play()
        if !playing { next() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.next() }
    }
}

/// 设备检测用的麦克风探针（Web `useMicrophone` 的取流 + 电平部分）：只读电平，不连接识别、不保存音频。
/// macOS 的 AVAudioEngine 跟随系统默认输入设备，换麦克风在“系统设置 › 声音 › 输入”中完成。
@MainActor @Observable
final class MicrophoneProbe {
    enum Permission: Equatable { case idle, requesting, granted, denied, unavailable, error }

    private(set) var permission: Permission = .idle
    private(set) var level: Float = 0
    private(set) var deviceName = ""
    private var engine: AVAudioEngine?

    func start() async {
        stop()
        permission = .requesting
        guard await VoiceRecorder.microphoneAllowed() else {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            permission = status == .denied || status == .restricted ? .denied : .unavailable
            return
        }
        guard let device = AVCaptureDevice.default(for: .audio) else { permission = .unavailable; return }
        deviceName = device.localizedName
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { permission = .unavailable; return }
        let deliver: @Sendable (Float) -> Void = { [weak self] level in
            Task { @MainActor [weak self] in self?.level = level }
        }
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format, block: Self.tap(deliver))
        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            permission = .granted
        } catch {
            input.removeTap(onBus: 0)
            permission = .error
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = 0
    }

    nonisolated static func tap(_ deliver: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in deliver(VoiceRecorder.rms(buffer)) }
    }

    /// 系统默认输出设备的名字（面试官的声音从这里放出来）；取不到时为 nil。
    static func outputName() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else { return nil }
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let value = name?.takeRetainedValue() else { return nil }
        return (value as String).nonEmptyValue
    }
}
