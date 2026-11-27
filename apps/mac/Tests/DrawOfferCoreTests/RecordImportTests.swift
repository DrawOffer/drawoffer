import AVFoundation
import Foundation
import Testing
@testable import DrawOfferCore

private func json(_ source: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)) }

// MARK: 上传前压缩录音（Web lib/uploads/compress.ts）

@Test func audioCompressionRules() {
    let big = AudioCompression.minimumBytes
    #expect(AudioCompression.compressible(name: "面试.mp3", size: big))
    #expect(AudioCompression.compressible(name: "面试.WAV", size: big + 1))
    #expect(AudioCompression.compressible(name: "面试.flac", size: big))
    #expect(!AudioCompression.compressible(name: "面试.mp3", size: big - 1))
    // 视频不压；不认识的扩展名也不压
    #expect(!AudioCompression.compressible(name: "面试.mp4", size: big))
    #expect(!AudioCompression.compressible(name: "面试.mov", size: big))
    #expect(!AudioCompression.compressible(name: "面试.pdf", size: big))
    #expect(!AudioCompression.compressible(name: "面试", size: big))

    #expect(AudioCompression.renamed("面试.wav", extension: "m4a") == "面试.m4a")
    #expect(AudioCompression.renamed("a.b.mp3", extension: "m4a") == "a.b.m4a")
    #expect(AudioCompression.renamed("录音", extension: "m4a") == "录音.m4a")
    #expect(AudioCompression.renamed(".hidden", extension: "m4a") == ".hidden.m4a")

    // 原码率低于 96 kbps 不转：10 MB、1000 秒是 80 kbps
    #expect(!AudioCompression.worthTranscoding(size: 10_000_000, duration: 1000))
    #expect(AudioCompression.worthTranscoding(size: 12_000_000, duration: 1000))
    #expect(!AudioCompression.worthTranscoding(size: 12_000_000, duration: 0))
    #expect(!AudioCompression.worthTranscoding(size: 12_000_000, duration: .nan))

    #expect(AudioCompression.sampleRateCandidates(source: 22_050) == [22_050, 48_000, 44_100])
    #expect(AudioCompression.sampleRateCandidates(source: 48_000) == [48_000, 44_100])
    #expect(AudioCompression.sampleRateCandidates(source: 0) == [48_000, 44_100])

    // 至少小 20% 才换掉原文件
    #expect(AudioCompression.keeps(compressed: 80, original: 100))
    #expect(!AudioCompression.keeps(compressed: 81, original: 100))
    #expect(!AudioCompression.keeps(compressed: 0, original: 100))
}

/// 一段正弦波的 16 位 PCM WAV。
private func wav(seconds: Int, rate: Int, channels: Int) -> Data {
    let frames = seconds * rate, bytes = frames * channels * 2
    var data = Data()
    func u32(_ v: Int) { var x = UInt32(v).littleEndian; data.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: Int) { var x = UInt16(v).littleEndian; data.append(Data(bytes: &x, count: 2)) }
    data.append(Data("RIFF".utf8)); u32(36 + bytes); data.append(Data("WAVEfmt ".utf8))
    u32(16); u16(1); u16(channels); u32(rate); u32(rate * channels * 2); u16(channels * 2); u16(16)
    data.append(Data("data".utf8)); u32(bytes)
    var samples = [Int16](repeating: 0, count: frames * channels)
    for frame in 0..<frames {
        let value = Int16(sin(Double(frame) * 2 * .pi * 440 / Double(rate)) * 8000)
        for channel in 0..<channels { samples[frame * channels + channel] = value }
    }
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    return data
}

@Test func audioCompressionExportsMonoM4AAndFallsBack() async throws {
    let directory = try DatasetUpload.privateDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    // 50 秒 44.1 kHz 双声道 ≈ 8.8 MB、1411 kbps：压成 m4a，名字跟着换，替换资料不压
    let source = directory.appendingPathComponent("二面录音.wav")
    try wav(seconds: 50, rate: 44_100, channels: 2).write(to: source)
    let upload = try DatasetUpload.snapshot(source, session: "8", limit: 512 * 1024 * 1024)
    defer { upload.discard() }
    let fractions = Fractions()
    let prepared = try await upload.compressingAudio { fractions.add($0) }
    #expect(prepared.isCompressed(from: upload) && prepared.name == "二面录音.m4a" && prepared.session == "8" && prepared.id == upload.id)
    let size = try prepared.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    #expect(size > 0 && Double(size) <= Double(upload.limit) && size < 8_800_000 / 5)
    #expect(fractions.last == 1)
    // 单声道 AAC、约 48 kbps
    let track = try #require(try await AVURLAsset(url: prepared.file).loadTracks(withMediaType: .audio).first)
    let format = try #require(try await track.load(.formatDescriptions).first)
    let basic = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
    #expect(basic.mChannelsPerFrame == 1 && basic.mFormatID == kAudioFormatMPEG4AAC)
    let rate = try await track.load(.estimatedDataRate)
    #expect(rate > 30_000 && rate < 70_000)
    prepared.dropCompressed(from: upload)
    #expect(!FileManager.default.fileExists(atPath: prepared.file.path) && FileManager.default.fileExists(atPath: upload.file.path))

    var replacing = upload; replacing.replacing = "5"; replacing.revision = "2"
    let kept = try await replacing.compressingAudio()
    #expect(!kept.isCompressed(from: replacing))

    // 不到 8 MB 的不压
    let small = directory.appendingPathComponent("短.wav")
    try wav(seconds: 2, rate: 8_000, channels: 1).write(to: small)
    let tiny = try DatasetUpload.snapshot(small, session: "8", limit: 512 * 1024 * 1024)
    defer { tiny.discard() }
    let short = try await tiny.compressingAudio()
    #expect(!short.isCompressed(from: tiny))

    // 读不出来的「录音」原样上传，不抛错
    let broken = directory.appendingPathComponent("坏.mp3")
    try Data(repeating: 7, count: Int(AudioCompression.minimumBytes)).write(to: broken)
    let junk = try DatasetUpload.snapshot(broken, session: "8", limit: 512 * 1024 * 1024)
    defer { junk.discard() }
    let same = try await junk.compressingAudio()
    #expect(!same.isCompressed(from: junk))
    let target = directory.appendingPathComponent("out.m4a")
    let exported = try await AudioCompression.export(broken, to: target)
    #expect(!exported)
    #expect(!FileManager.default.fileExists(atPath: target.path))
}

private final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var last: Double? { lock.withLock { values.last } }
}

@Test func backgroundUploadCompressingTextsAndJournal() throws {
    var item = BackgroundUpload(id: BackgroundUpload.localID(), sessionID: "8", applicationID: "3", fileName: "一面.wav", fileSize: 1000,
                                source: .init(size: 1000, modified: 5), transcribe: true, review: .init(title: "得物", replace: true))
    item.status = .compressing; item.loaded = 300
    #expect(item.local && item.running && item.runningTitle == "正在压缩 一面.wav")
    #expect(item.runningMeta(now: Date()) == "已压缩 30% · 压完再传会快很多 · 可以先去做别的")
    #expect(UploadBellState([item]).progress == 0.3 && UploadBellState([item]).summary == "1 个正在上传")

    item.id = String(repeating: "c", count: 32); item.compressed = true; item.status = .uploading
    let restored = BackgroundUploadJournal.decode(try JSONEncoder().encode([BackgroundUploadJournal(item)]))[0].interrupted
    #expect(restored.compressed && restored.review == .init(title: "得物", replace: true))
    // 旧版本的记录没有 compressed / review
    let old = try JSONDecoder().decode([BackgroundUploadJournal].self, from: Data(#"[{"id":"\#(String(repeating: "d", count: 32))","sessionID":"8","applicationID":"3","fileName":"a.m4a","fileSize":10,"source":{"size":10,"modified":5},"transcribe":true}]"#.utf8))
    #expect(!old[0].interrupted.compressed && old[0].interrupted.review == nil)
}

// MARK: 导入面试记录的后台处理（Web v2/backgroundRecordImports.ts）

@Test func recordImportStepsProgressAndTexts() {
    let start = Date(timeIntervalSince1970: 1000)
    var item = RecordImport(id: "1", sessionID: "8", company: "得物", step: .uploading, since: start)
    item.uploaded = 60
    #expect(item.working && abs(item.progress(now: start) - 0.03) < 1e-9 && item.stepText == "正在上传文件 60% · 可以先去做别的")
    item.move(to: .reading, now: start)
    #expect(item.progress(now: start) == 0.05 && item.stepText == "正在读取文件里的文字 · 可以先去做别的")
    item.move(to: .structuring, now: start)
    #expect(item.progress(now: start) == 0.07)
    #expect(item.progress(now: start.addingTimeInterval(25)) > 0.11 && item.progress(now: start.addingTimeInterval(1000)) < 0.1401)
    #expect(item.stepText == "正在整理面试问题 · 整理完自动复盘")
    item.move(to: .transcribing, now: start)
    #expect(item.progress(now: start) == 0 && abs(item.progress(now: start.addingTimeInterval(180)) - 0.14 * (1 - exp(-1))) < 1e-9)
    #expect(item.stepText == "正在转写录音 · 转好自动复盘 · 可以先去做别的")
    item.move(to: .reviewing, now: start)
    #expect(item.progress(now: start) == 0.15 && item.stepText == "整理好了，正在开始复盘")
    #expect(item.runningTitle == "正在导入「得物」面试记录")

    item.fail("网络或服务暂时不稳，稍后点重试。", retryable: true, now: start.addingTimeInterval(5))
    #expect(!item.working && item.retryable && item.since == start.addingTimeInterval(5) && item.failedTitle == "得物的面试记录没导入完")
    // 重试时换步骤：清掉错误、重新计时
    item.move(to: .structuring, now: start.addingTimeInterval(9))
    #expect(item.working && item.error == nil && item.since == start.addingTimeInterval(9))

    #expect(RecordImport.ago(start, now: start.addingTimeInterval(30)) == "刚刚")
    #expect(RecordImport.ago(start, now: start.addingTimeInterval(600)) == "10 分钟前")
    #expect(RecordImport.ago(start, now: start.addingTimeInterval(7200)) == "2 小时前")
}

@Test func recordImportFailureTexts() {
    func check(_ error: Error, _ text: String, _ retryable: Bool) {
        let result = RecordImportFlow.failure(error)
        #expect(result.text == text && result.retryable == retryable)
    }
    check(APIError.server(status: 422, code: "INTERVIEW_QUESTIONS_NOT_FOUND"), "没找到面试问题，换一份文字稿再导入。", false)
    check(RecordImportFlow.Unreadable(), "这个文件读不出文字，换一份再导入。", false)
    check(APIError.server(status: 409, code: "INTERVIEW_REVIEW_IN_PROGRESS"), "另一场面试正在复盘，等它好了再点重试。", true)
    check(APIError.server(status: 402, code: "CREDIT_INSUFFICIENT"), "积分已用完，本次 AI 请求没有发出。", true)
    check(APIError.server(status: 403, code: "PAID_CREDIT_REQUIRED"), "当前额度不能使用这项功能。", true)
    // 桌面端没开放的接口（403）、断网、5xx 都按普通失败，可以重试
    check(APIError.server(status: 403, code: "CLIENT_NOT_ALLOWED"), "网络或服务暂时不稳，稍后点重试。", true)
    check(URLError(.notConnectedToInternet), "网络或服务暂时不稳，稍后点重试。", true)

    #expect(RecordImportFlow.parse(.object(["parse_status": .string("succeeded")])) == .succeeded)
    #expect(RecordImportFlow.parse(.object(["dataset": .object(["parse_status": .string("failed")])])) == .failed)
    #expect(RecordImportFlow.parse(.object(["parse_status": .string("running")])) == .pending)
    #expect(RecordImportFlow.parseAttempts == 30 && RecordImportFlow.parseWait == .seconds(2) && RecordImportFlow.recordingPoll == .seconds(15))
}

private func session(review: String = "idle", started: String? = nil, lock: Int = 4, markdown: String = "", transcription: String? = nil) throws -> JSONValue {
    let startedJSON = started.map { "\"\($0)\"" } ?? "null"
    let list = transcription.map { "[{\"dataset_id\":51,\"status\":\"other\"},\($0)]" } ?? "[]"
    return try json(#"{"id":"8","review_status":"\#(review)","review_started_at":\#(startedJSON),"lock_version":\#(lock),"questions_markdown":"\#(markdown)","transcriptions":\#(list)}"#)
}

@Test func recordingWatchDecisions() throws {
    var job = RecordingJob(sessionID: "8", applicationID: "3", datasetID: "52", title: "得物", replace: false)
    // 第一次看时记下复盘开始时间作基线，之后不再改
    #expect(RecordImportFlow.setBase(&job, session: try session(started: "2026-11-01T10:00:00Z")))
    #expect(job.baseSet && job.base == "2026-11-01T10:00:00Z")
    #expect(!RecordImportFlow.setBase(&job, session: try session()))
    #expect(job.base == "2026-11-01T10:00:00Z")

    var fresh = RecordingJob(sessionID: "8", applicationID: "3", datasetID: "52", title: "得物", replace: false)
    _ = RecordImportFlow.setBase(&fresh, session: try session())
    #expect(fresh.baseSet && fresh.base == nil)
    // 别处已经开始复盘（正在生成，或开始时间变了）就不再提交
    #expect(RecordImportFlow.recordingStep(try session(review: "generating"), job: fresh, again: false) == .dismiss)
    #expect(RecordImportFlow.recordingStep(try session(started: "2026-11-02T10:00:00Z"), job: fresh, again: false) == .dismiss)
    // 没有这份录音的转写：确认过替换才让服务端转，否则提示
    #expect(RecordImportFlow.recordingStep(try session(), job: fresh, again: false) == .fail("录音已经传好，但没有转写。到这场面试的资料里看看。", retryable: false))
    var replacing = fresh; replacing.replace = true
    #expect(RecordImportFlow.recordingStep(try session(), job: replacing, again: false) == .retranscribe)
    // 转写中下次再看；取消了收起；失败了可以重试，点了重试才让服务端重转
    #expect(RecordImportFlow.recordingStep(try session(transcription: #"{"dataset_id":52,"status":"running"}"#), job: fresh, again: false) == .wait)
    #expect(RecordImportFlow.recordingStep(try session(transcription: #"{"dataset_id":"52","status":"cancelled"}"#), job: fresh, again: false) == .dismiss)
    let failed = try session(transcription: #"{"dataset_id":52,"status":"failed"}"#)
    #expect(RecordImportFlow.recordingStep(failed, job: fresh, again: false) == .fail("录音没有转出文字，可以再试一次，或者改成粘贴文字导入。", retryable: true))
    #expect(RecordImportFlow.recordingStep(failed, job: fresh, again: true) == .retranscribe)
    // 转好：原来有记录的，没确认替换就不盖掉，确认过先替换再复盘
    let pending = try session(lock: 6, transcription: #"{"dataset_id":52,"status":"succeeded","pending_replace":true}"#)
    #expect(RecordImportFlow.recordingStep(pending, job: fresh, again: false) == .fail("这场已经有别的记录，没有替换。转写好的文字在这场面试的资料里。", retryable: false))
    #expect(RecordImportFlow.recordingStep(pending, job: replacing, again: false) == .review(apply: true, version: 6))
    // 转好写进了记录才复盘；记录是空的就收起
    #expect(RecordImportFlow.recordingStep(try session(lock: 7, markdown: "面试官：介绍一下项目", transcription: #"{"dataset_id":52,"status":"succeeded"}"#), job: fresh, again: false) == .review(apply: false, version: 7))
    #expect(RecordImportFlow.recordingStep(try session(markdown: " ", transcription: #"{"dataset_id":52,"status":"succeeded"}"#), job: fresh, again: false) == .dismiss)
}

@Test func recordingWatchErrorsAndJournal() throws {
    #expect(RecordImportFlow.recordingError(APIError.server(status: 404, code: "INTERVIEW_SESSION_NOT_FOUND")) == .dismiss)
    #expect(RecordImportFlow.recordingError(APIError.server(status: 422, code: "INTERVIEW_REVIEW_TEXT_TOO_LONG")) == .fail("转写的文字太长，到这场面试里删减后再复盘。", retryable: false))
    #expect(RecordImportFlow.recordingError(APIError.server(status: 409, code: "INTERVIEW_TRANSCRIPTION_DISABLED")) == .fail("录音已经传好，现在不能转写，可以改成粘贴文字导入。", retryable: false))
    #expect(RecordImportFlow.recordingError(APIError.server(status: 409, code: "INTERVIEW_INVALID_TRANSITION")) == .fail("这条投递已归档，或这场面试还没结束，没有复盘。", retryable: true))
    #expect(RecordImportFlow.recordingError(APIError.server(status: 402, code: "CREDIT_INSUFFICIENT")) == .fail("积分已用完，本次 AI 请求没有发出。", retryable: true))
    #expect(RecordImportFlow.recordingError(APIError.server(status: 403, code: "CLIENT_NOT_ALLOWED")) == .fail("网络或服务暂时不稳，稍后点重试。", retryable: true))
    // 另一场正在复盘、刚被改过、5xx、断网：下次再看
    #expect(RecordImportFlow.recordingError(APIError.server(status: 409, code: "INTERVIEW_REVIEW_IN_PROGRESS")) == .later)
    #expect(RecordImportFlow.recordingError(APIError.server(status: 412, code: "INTERVIEW_SESSION_CONFLICT")) == .later)
    #expect(RecordImportFlow.recordingError(APIError.server(status: 503, code: "HTTP_503")) == .later)
    #expect(RecordImportFlow.recordingError(URLError(.timedOut)) == .later)

    var job = RecordingJob(id: "j1", sessionID: "8", applicationID: "3", datasetID: "52", title: "得物", replace: true, since: Date(timeIntervalSince1970: 100))
    _ = RecordImportFlow.setBase(&job, session: try session(started: "t0"))
    let bad = RecordingJob(id: "j2", sessionID: "x", applicationID: "3", datasetID: "52", title: "坏", replace: false)
    let restored = RecordingJob.decode(try JSONEncoder().encode([job, bad]))
    #expect(restored == [job] && restored[0].baseSet && restored[0].base == "t0" && restored[0].since == 100)
    #expect(RecordingJob.decode(Data("oops".utf8)).isEmpty && RecordingJob.decode(nil).isEmpty)
    #expect(RecordingJob.key(account: "1") == "drawoffer.recordingReviews.v1.1")
}
