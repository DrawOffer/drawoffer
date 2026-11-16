@preconcurrency import AVFoundation
import CryptoKit
import CSherpaOnnx
import Foundation

/// macOS 26 以下的本机识别：SenseVoice Small（int8，FunAudioLLM）+ Silero VAD，经 sherpa-onnx 在本机 CPU 上运行。
/// 动态库随 App 打包（`scripts/fetch-sherpa.sh` + `bundle.sh`），模型约 240 MB，首次需要时从公共 CDN 后台下载、逐个校验 sha256，
/// 存到 Application Support；没下完、库缺失或加载失败时返回 nil，调用方退回云端识别。
enum SenseVoiceModel {
    struct File: Sendable { let name: String; let sha256: String }

    static let version = "sensevoice-small-int8-2024-07-17"
    static let files = [
        File(name: "model.int8.onnx", sha256: "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"),
        File(name: "tokens.txt", sha256: "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"),
        File(name: "silero_vad.onnx", sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"),
    ]

    /// 开发时可用 `DRAWOFFER_SPEECH_MODEL_BASE` 指向别的地址。
    static var baseURL: URL {
        let value = ProcessInfo.processInfo.environment["DRAWOFFER_SPEECH_MODEL_BASE"]
            ?? "https://qingluo-public.oss-cn-shanghai.aliyuncs.com/DrawOffer/models/\(version)/"
        return URL(string: value.hasSuffix("/") ? value : value + "/")!
    }

    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "DrawOffer/SpeechModels/\(version)", directoryHint: .isDirectory)
    }

    static func path(_ name: String) -> String { directory.appending(path: name).path(percentEncoded: false) }

    static var installed: Bool { files.allSatisfy { FileManager.default.fileExists(atPath: path($0.name)) } }

    /// 打进 App 的 `Contents/Frameworks/libsherpa-onnx-c-api.dylib`；`swift run` 时可用 `DRAWOFFER_SHERPA_LIB` 指定。
    static var libraryPath: String? {
        if let custom = ProcessInfo.processInfo.environment["DRAWOFFER_SHERPA_LIB"] { return custom }
        guard let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let path = frameworks.appending(path: "libsherpa-onnx-c-api.dylib").path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// 缺哪个下哪个；校验不过的文件丢弃，不会留下半截模型。
    static func install() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files where !FileManager.default.fileExists(atPath: path(file.name)) {
            let (temporary, response) = try await URLSession.shared.download(from: baseURL.appending(path: file.name))
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200, try sha256(of: temporary) == file.sha256 else {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.moveItem(at: temporary, to: directory.appending(path: file.name))
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 一次录音的识别。音频线程只做格式转换，VAD 切段和识别都在串行队列上做：每说完一句（停顿约 0.5 秒）识别一次并回传文字。
final class SenseVoiceTranscriber: LocalSession, @unchecked Sendable {
    private static let sampleRate = 16_000.0
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private let queue = DispatchQueue(label: "drawoffer.sensevoice")
    private let converter: AVAudioConverter
    private let onText: @MainActor (String) -> Void
    // 以下只在 queue 上读写。
    private var recognizer: OpaquePointer?
    private var segments: [LocalTranscript] = []

    private init(recognizer: OpaquePointer, converter: AVAudioConverter, onText: @escaping @MainActor (String) -> Void) {
        self.recognizer = recognizer; self.converter = converter; self.onText = onText
    }

    deinit { if let recognizer { dos_sherpa_destroy(recognizer) } }

    /// 模型还没下载时在后台开始下载并返回 nil（这次走云端，下次录音再用本机）。
    @MainActor
    static func make(inputFormat: AVAudioFormat, onText: @escaping @MainActor (String) -> Void) async -> SenseVoiceTranscriber? {
        guard let library = SenseVoiceModel.libraryPath else { return nil }
        guard SenseVoiceModel.installed else {
            LocalSpeech.downloadSenseVoice()
            return nil
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else { return nil }
        // 创建识别器要读 240 MB 模型（约 1 秒），放到后台线程。
        struct Handle: @unchecked Sendable { let pointer: OpaquePointer }
        let handle: Handle? = await Task.detached(priority: .userInitiated) {
            guard dos_sherpa_load(library) == 1 else { return nil }
            let threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)))
            return dos_sherpa_create(SenseVoiceModel.path("model.int8.onnx"), SenseVoiceModel.path("tokens.txt"),
                                     SenseVoiceModel.path("silero_vad.onnx"), threads).map(Handle.init)
        }.value
        guard let handle else { return nil }
        return SenseVoiceTranscriber(recognizer: handle.pointer, converter: converter, onText: onText)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        final class Once: @unchecked Sendable { var consumed = false }
        let once = Once()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if once.consumed { status.pointee = .noDataNow; return nil }
            once.consumed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, output.frameLength > 0, let channel = output.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
        queue.async { [self] in
            guard let recognizer else { return }
            samples.withUnsafeBufferPointer { dos_sherpa_accept(recognizer, $0.baseAddress, Int32($0.count)) }
            drain()
        }
    }

    func finish() async throws -> LocalTranscript {
        await withCheckedContinuation { (done: CheckedContinuation<LocalTranscript, Never>) in
            queue.async { [self] in
                if let recognizer { dos_sherpa_flush(recognizer) }
                drain()
                done.resume(returning: Self.join(segments))
            }
        }
    }

    func cancel() async {
        queue.async { [self] in
            if let recognizer { dos_sherpa_destroy(recognizer) }
            recognizer = nil
        }
    }

    /// queue 上：把 VAD 已切好的段逐个识别。
    private func drain() {
        guard let recognizer else { return }
        var changed = false
        while let segment = dos_sherpa_next(recognizer) {
            defer { dos_sherpa_free_segment(segment) }
            segments.append(Self.transcript(of: segment.pointee))
            changed = true
        }
        guard changed else { return }
        let text = Self.join(segments).text
        let onText = onText
        Task { @MainActor in onText(text) }
    }

    /// SenseVoice 的 token：汉字一字一个，英文是子词（词首带空格）；`<|zh|>` 这类标签不算词。
    /// 每个词的结束时间取下一个 token 的开始，最后一个到这段结束。
    private static func transcript(of segment: DOSSegment) -> LocalTranscript {
        let text = String(cString: segment.text).trimmingCharacters(in: .whitespacesAndNewlines)
        var pieces: [(text: String, start: Double)] = []
        for index in 0..<Int(segment.count) {
            let token = String(cString: segment.tokens[index]!)
            if token.hasPrefix("<|") { continue }
            let start = segment.start + Double(segment.times[index])
            let piece = token.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
            // 标点跟在前一个词后面；英文以空格（或 “▁”）开头才是新词；汉字一字一词。
            let punctuation = !piece.isEmpty && piece.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            let startsWord = pieces.isEmpty || (!punctuation && (token.hasPrefix(" ") || token.hasPrefix("▁")
                || piece.unicodeScalars.contains { $0.properties.isIdeographic }
                || pieces.last!.text.unicodeScalars.contains { $0.properties.isIdeographic }))
            if startsWord { pieces.append((piece, start)) } else { pieces[pieces.count - 1].text += piece }
        }
        let end = segment.start + segment.duration
        let words: [LocalTranscript.Word] = pieces.enumerated().compactMap { index, piece in
            guard !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let until = index + 1 < pieces.count ? pieces[index + 1].start : end
            return .init(text: piece.text, startMs: millis(piece.start), endMs: millis(max(piece.start, until)))
        }
        return LocalTranscript(text: text, words: words)
    }

    /// 中文段直接相连，英文段之间补一个空格。
    private static func join(_ segments: [LocalTranscript]) -> LocalTranscript {
        var text = ""
        for segment in segments where !segment.text.isEmpty {
            if let last = text.unicodeScalars.last, last.isASCII, !last.properties.isWhitespace,
               let first = segment.text.unicodeScalars.first, first.isASCII { text += " " }
            text += segment.text
        }
        return LocalTranscript(text: text, words: segments.flatMap(\.words))
    }

    private static func millis(_ seconds: Double) -> Int { max(0, Int((seconds * 1000).rounded())) }
}
