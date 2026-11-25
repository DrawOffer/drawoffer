@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// 本机语音识别（离线、不计费）：macOS 26 用系统自带的 SpeechTranscriber，更早的系统用 SenseVoice（`SenseVoiceTranscriber`）。
/// 录音照常经 WebSocket 上传给服务端保存（`recognizer=local`），识别在本机完成，停止时把文字和逐词时间随 `stop` 发出。
/// 识别资源还没装好时返回 nil，调用方退回云端识别；资源首次缺失时在后台下载，下次录音再用。
struct LocalTranscript: Sendable {
    struct Word: Sendable { let text: String; let startMs: Int; let endMs: Int }
    let text: String
    let words: [Word]

    /// 服务端要求：每个词 1–32 字、开始时间不倒退、落在录音时长内。这里先收口，避免整段被拒。
    func stopMessage(durationMs: Int) -> String {
        var previous = 0
        let items: [[String: Any]] = words.compactMap { word in
            let text = String(word.text.prefix(32))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let start = min(max(previous, word.startMs), durationMs)
            let end = min(max(start, word.endMs), durationMs)
            previous = start
            return ["text": text, "start_ms": start, "end_ms": end]
        }
        let payload: [String: Any] = ["type": "stop", "transcript": String(text.prefix(6000)), "words": Array(items.prefix(6000))]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"type\":\"stop\"}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// 只供 macOS 26 以上调用；外层用 `LocalSpeech.start` 统一判断可用性。
@MainActor
enum LocalSpeech {
    private static var downloading = false

    /// 能用本机识别时返回已启动的识别器（输入为麦克风原始格式）；否则 nil。`onText` 在主线程收到实时文字。
    /// 开发时设 `DRAWOFFER_LOCAL_ASR=sensevoice` 可在 macOS 26 上也走 SenseVoice。
    static func start(inputFormat: AVAudioFormat, onText: @escaping @MainActor (String) -> Void) async -> LocalSession? {
        let forced = ProcessInfo.processInfo.environment["DRAWOFFER_LOCAL_ASR"] == "sensevoice"
        if #available(macOS 26.0, *), !forced {
            return await LocalTranscriber.make(inputFormat: inputFormat, onText: onText)
        }
        return await SenseVoiceTranscriber.make(inputFormat: inputFormat, onText: onText)
    }

    /// 进入模拟面试时先在后台把本机识别资源装好，第一次录音就能用本机识别，不再回退云端。
    /// 系统识别资源由系统下载；SenseVoice 模型约 240 MB，只在 App 带了识别库时才下。
    static func prepare() async {
        let forced = ProcessInfo.processInfo.environment["DRAWOFFER_LOCAL_ASR"] == "sensevoice"
        if #available(macOS 26.0, *), !forced {
            guard SpeechTranscriber.isAvailable,
                  let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN")) else { return }
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                                attributeOptions: [.audioTimeRange])
            if await AssetInventory.status(forModules: [transcriber]) != .installed { download(transcriber) }
            return
        }
        if SenseVoiceModel.libraryPath != nil, !SenseVoiceModel.installed { downloadSenseVoice() }
    }

    static func downloadSenseVoice() {
        guard !downloading else { return }
        downloading = true
        Task.detached(priority: .utility) {
            try? await SenseVoiceModel.install()
            await MainActor.run { downloading = false }
        }
    }

    @available(macOS 26.0, *)
    fileprivate static func download(_ transcriber: SpeechTranscriber) {
        guard !downloading else { return }
        downloading = true
        Task.detached {
            _ = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()
            await MainActor.run { downloading = false }
        }
    }
}

/// 识别会话：音频线程调用 `feed`，停止时 `finish` 拿最终稿。
protocol LocalSession: AnyObject, Sendable {
    func feed(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> LocalTranscript
    func cancel() async
}

@available(macOS 26.0, *)
final class LocalTranscriber: LocalSession, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let collector: Task<[SpeechTranscriber.Result], Error>

    private init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, converter: AVAudioConverter,
                 format: AVAudioFormat, collector: Task<[SpeechTranscriber.Result], Error>) {
        self.analyzer = analyzer; self.input = input; self.converter = converter; self.format = format; self.collector = collector
    }

    @MainActor
    static func make(inputFormat: AVAudioFormat, onText: @escaping @MainActor (String) -> Void) async -> LocalTranscriber? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN")) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [.audioTimeRange])
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            LocalSpeech.download(transcriber)
            return nil
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AVAudioConverter(from: inputFormat, to: format) else { return nil }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let collector = Task<[SpeechTranscriber.Result], Error> {
            var finals: [SpeechTranscriber.Result] = []
            for try await result in transcriber.results {
                if result.isFinal { finals.append(result) }
                let shown = finals.map { String($0.text.characters) }.joined() + (result.isFinal ? "" : String(result.text.characters))
                await onText(shown)
            }
            return finals
        }
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
        } catch {
            input.finish(); collector.cancel()
            return nil
        }
        return LocalTranscriber(analyzer: analyzer, input: input, converter: converter, format: format, collector: collector)
    }

    /// 音频线程：转换成识别器要的格式后排队。转换器只在这一条线程上使用。
    func feed(_ buffer: AVAudioPCMBuffer) {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        final class Once: @unchecked Sendable { var consumed = false }
        let once = Once()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if once.consumed { status.pointee = .noDataNow; return nil }
            once.consumed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, output.frameLength > 0 else { return }
        input.yield(AnalyzerInput(buffer: output))
    }

    func finish() async throws -> LocalTranscript {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let finals = try await collector.value
        var text = ""
        var words: [LocalTranscript.Word] = []
        for result in finals {
            text += String(result.text.characters)
            for run in result.text.runs {
                guard let range = run.audioTimeRange else { continue }
                let piece = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !piece.isEmpty else { continue }
                words.append(.init(text: piece, startMs: Self.millis(range.start), endMs: Self.millis(range.end)))
            }
        }
        return LocalTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines), words: words)
    }

    func cancel() async {
        input.finish()
        collector.cancel()
        await analyzer.cancelAndFinishNow()
    }

    private static func millis(_ time: CMTime) -> Int {
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite ? max(0, Int((seconds * 1000).rounded())) : 0
    }
}
