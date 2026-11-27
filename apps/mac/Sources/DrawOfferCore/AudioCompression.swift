import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// 上传前压缩录音（Web `lib/uploads/compress.ts` 的 `compressAudio`）：转成单声道 48 kbps AAC（m4a，索引在文件头，能边下边播和拖进度条）。
/// 压缩只为少传字节；做不了、压不小或出任何错都原样上传，不影响上传本身。压缩后的文件就是保存的文件，用户本机的原文件不受影响。
/// 调用处与 Web 一致：资料库上传、面试素材上传（`api/client.ts` 的 `uploadDataset` / `uploadInterviewAsset`）和后台录音上传；替换资料不压缩。
/// Web 同一文件里的大图转 JPEG（`compressImage`）不在这里。
public enum AudioCompression {
    static let extensions: Set<String> = ["mp3", "m4a", "wav", "webm", "ogg", "aac", "flac"]
    public static let minimumBytes: Int64 = 8 * 1024 * 1024
    /// 识别和回放人声足够；一小时约 21 MB。
    public static let bitrate = 48_000
    /// 原文件码率低于这个就不转了（省不了多少，还多一次有损编码）。
    public static let minimumSourceBitrate = 96_000.0
    /// 压完至少要小这么多才换掉原文件。
    public static let keepRatio = 0.8

    static func pathExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// Web `renamed`：换扩展名；没有扩展名或以点开头的名字直接接上。
    public static func renamed(_ name: String, extension ext: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "\(name).\(ext)" }
        return "\(name[..<dot]).\(ext)"
    }

    /// Web `isCompressibleAudio`：至少 8 MB、不是视频类型，扩展名是常见录音格式或类型是 audio/*。
    /// 浏览器的 `File.type` 在这里换成按扩展名推出的 MIME 类型（与上传时报给服务端的类型同一来源）。
    public static func compressible(name: String, size: Int64) -> Bool {
        guard size >= minimumBytes else { return false }
        let ext = pathExtension(name)
        let type = ext.isEmpty ? "" : UTType(filenameExtension: ext)?.preferredMIMEType ?? ""
        if type.hasPrefix("video/") { return false }
        return extensions.contains(ext) || type.hasPrefix("audio/")
    }

    /// 时长有效、原码率不低于 96 kbps 才值得转。
    public static func worthTranscoding(size: Int64, duration: Double) -> Bool {
        duration > 0 && duration.isFinite && Double(size) * 8 / duration >= minimumSourceBitrate
    }

    /// Web 依次试原采样率、48 kHz、44.1 kHz，取第一个能编码的。
    public static func sampleRateCandidates(source: Double) -> [Double] {
        var list: [Double] = []
        for rate in [source, 48_000, 44_100] where rate > 0 && !list.contains(rate) { list.append(rate) }
        return list
    }

    /// 压出来的不比原文件小 20% 就不用。
    public static func keeps(compressed: Int64, original: Int64) -> Bool {
        compressed > 0 && Double(compressed) <= Double(original) * keepRatio
    }

    /// 编码器设置：单声道 AAC、48 kbps。
    static func encoderSettings(sampleRate: Double) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: bitrate]
    }

    /// 把 `source` 压成 `target`（m4a）。返回 false 表示不压或压不了，调用方用原文件；取消时抛 `CancellationError`。
    /// 有视频轨、没有音轨、原码率已经很低、编码器不接受、压完不够小，都返回 false。
    public static func export(_ source: URL, to target: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Bool {
        let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        do {
            let asset = AVURLAsset(url: source)
            if !(try await asset.loadTracks(withMediaType: .video)).isEmpty { return false }
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return false }
            let duration = try await asset.load(.duration).seconds
            guard worthTranscoding(size: size, duration: duration) else { return false }
            let format = try await track.load(.formatDescriptions).first
            let sourceRate = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 0
            try? FileManager.default.removeItem(at: target)
            let writer = try AVAssetWriter(outputURL: target, fileType: .m4a)
            writer.shouldOptimizeForNetworkUse = true
            guard let rate = sampleRateCandidates(source: sourceRate).first(where: { writer.canApply(outputSettings: encoderSettings(sampleRate: $0), forMediaType: .audio) })
            else { return false }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: encoderSettings(sampleRate: rate))
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { return false }
            writer.add(input)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return false }
            reader.add(output)
            guard reader.startReading(), writer.startWriting() else { reader.cancelReading(); writer.cancelWriting(); return false }
            writer.startSession(atSourceTime: .zero)
            let pump = AudioPump(reader: reader, output: output, input: input, duration: duration, progress: progress)
            let appended = await withTaskCancellationHandler { await pump.run() } onCancel: { pump.cancel() }
            if Task.isCancelled { writer.cancelWriting(); try? FileManager.default.removeItem(at: target); throw CancellationError() }
            guard appended, reader.status == .completed else { writer.cancelWriting(); try? FileManager.default.removeItem(at: target); return false }
            await writer.finishWriting()
            let written = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard writer.status == .completed, keeps(compressed: written, original: size) else { try? FileManager.default.removeItem(at: target); return false }
            progress(1)
            return true
        } catch {
            try? FileManager.default.removeItem(at: target)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return false
        }
    }
}

/// 在串行队列上把读出的 PCM 喂给 AAC 编码器；只结束一次。AVFoundation 的读写对象不是 Sendable，都只在这个队列上碰。
private final class AudioPump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let input: AVAssetWriterInput
    private let duration: Double
    private let progress: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "drawoffer.audio-compression")
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput, duration: Double, progress: @escaping @Sendable (Double) -> Void) {
        self.reader = reader; self.output = output; self.input = input; self.duration = duration; self.progress = progress
    }

    func cancel() { lock.withLock { cancelled = true } }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// 返回 true 表示读完、全部写进去了。
    func run() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let finish: (Bool) -> Void = { [self] ok in
                guard !finished else { return }
                finished = true
                if !ok { reader.cancelReading() }
                input.markAsFinished()
                continuation.resume(returning: ok)
            }
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData, !finished {
                    if isCancelled { finish(false); return }
                    guard let buffer = output.copyNextSampleBuffer() else { finish(reader.status == .completed); return }
                    let at = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                    if duration > 0, at.isFinite { progress(min(1, max(0, at / duration))) }
                    if !input.append(buffer) { finish(false); return }
                }
            }
        }
    }
}

extension DatasetUpload {
    /// 按 Web 规则先压缩录音：能压就返回一份指向压缩后文件（同一快照目录，名字换成 .m4a）的上传，否则原样返回。
    /// 替换已有资料不压缩（Web `replaceDataset` 直接传原文件）。取消时抛 `CancellationError`，其余失败都用原文件。
    public func compressingAudio(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> DatasetUpload {
        guard replacing == nil else { return self }
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard AudioCompression.compressible(name: name, size: size) else { return self }
        // 快照文件没有扩展名，AVFoundation 靠扩展名认格式：在同一目录挂一个带原扩展名的硬链接给它读，读完就删
        let token = UUID().uuidString.lowercased()
        let readable = directory.appendingPathComponent("source-\(token).\(AudioCompression.pathExtension(name))")
        guard (try? FileManager.default.linkItem(at: file, to: readable)) != nil else { return self }
        defer { try? FileManager.default.removeItem(at: readable) }
        let target = directory.appendingPathComponent("compressed-\(token).m4a")
        guard try await AudioCompression.export(readable, to: target, progress: progress) else { return self }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return DatasetUpload(id: id, file: target, directory: directory, folder: folder, name: AudioCompression.renamed(name, extension: "m4a"),
                             replacing: replacing, revision: revision, limit: limit, session: session, transcribe: transcribe)
    }

    /// 这份上传是不是 `original` 压缩出来的（文件不同）。
    public func isCompressed(from original: DatasetUpload) -> Bool { file != original.file }

    /// 只删压缩出来的那个文件，快照目录和原文件留着（调用方之后还会 `discard`）。
    public func dropCompressed(from original: DatasetUpload) {
        if isCompressed(from: original) { try? FileManager.default.removeItem(at: file) }
    }
}
