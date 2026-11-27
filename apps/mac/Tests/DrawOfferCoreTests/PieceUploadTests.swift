import Foundation
import Testing
@testable import DrawOfferCore

private let uploadID = String(repeating: "a1", count: 16)

private func json(_ source: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)) }

private func stateJSON(size: Int64, chunk: Int64 = PieceUpload.chunkBytes, received: [Int] = [], dataset: String? = nil) throws -> JSONValue {
    let total = (size + chunk - 1) / chunk
    let result = dataset.map { #","dataset":{"id":"\#($0)","file_name":"面试.m4a"}"# } ?? #","dataset":null"#
    return try json(#"{"upload_id":"\#(uploadID)","purpose":"dataset","chunk_size":\#(chunk),"total_chunks":\#(total),"file_size":\#(size),"received":\#(received)\#(result),"asset":null}"#)
}

/// 假的上传通道：记下收到的分片内容，可以让指定的分片第一次失败。
private actor FakePieces: PieceTransport {
    let size: Int64
    let chunk: Int64
    var parts: [Int: Data] = [:]
    var failOnce: [Int: Error]
    var puts: [Int] = []
    var completes = 0
    var maxInflight = 0
    var inflight = 0
    var finishedAlready = false

    init(size: Int64, chunk: Int64, received: [Int: Data] = [:], failOnce: [Int: Error] = [:]) {
        self.size = size; self.chunk = chunk; parts = received; self.failOnce = failOnce
    }
    func markFinished() { finishedAlready = true }

    func state(_ id: String) async throws -> PieceUploadState {
        try PieceUploadState(json: stateJSON(size: size, chunk: chunk, received: parts.keys.sorted(), dataset: finishedAlready ? "7" : nil))!
    }
    func put(_ id: String, index: Int, data: Data, progress: @escaping @Sendable (Int64) -> Void) async throws {
        inflight += 1; maxInflight = max(maxInflight, inflight); defer { inflight -= 1 }
        puts.append(index)
        progress(Int64(data.count) / 2)
        try await Task.sleep(for: .milliseconds(5))
        if let error = failOnce.removeValue(forKey: index) { throw error }
        parts[index] = data
    }
    func complete(_ id: String) async throws -> PieceUploadState {
        completes += 1
        let total = Int((size + chunk - 1) / chunk)
        guard parts.count == total else { throw APIError.server(status: 409, code: "UPLOAD_INCOMPLETE") }
        return try PieceUploadState(json: stateJSON(size: size, chunk: chunk, received: Array(0..<total), dataset: "7"))!
    }
}

private func tempFile(_ size: Int) throws -> (URL, Data) {
    let data = Data((0..<size).map { UInt8($0 % 251) })
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("piece-\(UUID().uuidString)")
    try data.write(to: url)
    return (url, data)
}

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    private var retries: [Int] = []
    func progress(_ value: Int64) { lock.withLock { values.append(value) } }
    func retry(_ value: Int) { lock.withLock { retries.append(value) } }
    var last: Int64? { lock.withLock { values.last } }
    var all: [Int64] { lock.withLock { values } }
    var retried: [Int] { lock.withLock { retries } }
}

@Test func uploadRoutesAreWhitelistedExactly() {
    #expect(UploadRequest.allowed(path: "/api/uploads", method: "POST"))
    #expect(!UploadRequest.allowed(path: "/api/uploads", method: "GET"))
    #expect(UploadRequest.allowed(path: "/api/uploads/\(uploadID)", method: "GET"))
    #expect(UploadRequest.allowed(path: "/api/uploads/\(uploadID)", method: "DELETE"))
    #expect(UploadRequest.allowed(path: "/api/uploads/\(uploadID)/complete", method: "POST"))
    #expect(UploadRequest.allowed(path: "/api/uploads/\(uploadID)/chunks/0", method: "PUT"))
    #expect(UploadRequest.allowed(path: "/api/uploads/\(uploadID)/chunks/127", method: "PUT"))
    #expect(!UploadRequest.allowed(path: "/api/uploads/\(uploadID)/chunks/007", method: "PUT"))
    #expect(!UploadRequest.allowed(path: "/api/uploads/\(uploadID)/chunks/-1", method: "PUT"))
    #expect(!UploadRequest.allowed(path: "/api/uploads/\(uploadID.uppercased())", method: "GET"))
    #expect(!UploadRequest.allowed(path: "/api/uploads/../datasets", method: "GET"))
    #expect(!UploadRequest.allowed(path: "/api/uploads/\(uploadID)/complete", method: "GET"))
    // 通用 careerRequest 不放行这组路径（只能经专门的分片方法）
    #expect(!CareerRequest.allowed(path: "/api/uploads", method: "POST"))
}

@Test func uploadStateValidatesShapeAndMissingPieces() throws {
    let size = PieceUpload.chunkBytes * 2 + 10
    let state = try #require(PieceUploadState(json: try stateJSON(size: size, received: [2, 0])))
    #expect(state.totalChunks == 3 && state.missing == [1] && state.size(of: 2) == 10)
    #expect(state.confirmed == PieceUpload.chunkBytes + 10 && !state.finished && state.result == nil)
    #expect(PieceUploadState(json: try json(#"{"upload_id":"\#(uploadID)","chunk_size":4194304,"total_chunks":5,"file_size":10,"received":[]}"#)) == nil)
    #expect(PieceUploadState(json: try json(#"{"upload_id":"\#(uploadID)","chunk_size":4194304,"total_chunks":1,"file_size":10,"received":[3]}"#)) == nil)
    #expect(PieceUploadState(json: try json(#"{"upload_id":"\#(uploadID)","chunk_size":9999999,"total_chunks":1,"file_size":10,"received":[]}"#)) == nil)
    #expect(PieceUploadState(json: try json(#"{"upload_id":"nope","chunk_size":4194304,"total_chunks":1,"file_size":10,"received":[]}"#)) == nil)
    let finished = try #require(PieceUploadState(json: try stateJSON(size: 10, received: [0], dataset: "42")))
    #expect(finished.finished && finished.result?.text("id") == "42")
    let asset = try #require(PieceUploadState(json: try json(#"{"upload_id":"\#(uploadID)","chunk_size":4194304,"total_chunks":1,"file_size":10,"received":[0],"dataset":null,"asset":{"id":"9"}}"#)))
    #expect(asset.result?["asset"]?.text("id") == "9")
}

@Test func uploadStartBodyFollowsPurpose() throws {
    let (file, _) = try tempFile(16)
    defer { try? FileManager.default.removeItem(at: file) }
    var upload = DatasetUpload(id: UUID().uuidString.lowercased(), file: file, directory: file.deletingLastPathComponent(), folder: "12", name: "笔记.pdf", replacing: nil, revision: nil, limit: 100)
    let dataset = try PieceUploadStart.from(upload, size: 16)
    #expect(dataset.json == .object(["purpose": .string("dataset"), "file_name": .string("笔记.pdf"), "file_size": .number(16), "content_type": .string("application/pdf"), "folder_id": .string("12")]))
    upload.replacing = "34"; upload.revision = "5"
    let replace = try PieceUploadStart.from(upload, size: 16)
    #expect(replace.purpose == .datasetReplace && replace.datasetID == "34" && replace.ifMatch == "\"dataset-34-5\"" && replace.json["folder_id"] == nil)
    upload.revision = "x"
    #expect(throws: APIError.self) { try PieceUploadStart.from(upload, size: 16) }
    upload.replacing = nil; upload.revision = nil; upload.session = "56"; upload.transcribe = false; upload.name = "二面.m4a"
    let asset = try PieceUploadStart.from(upload, size: 16)
    #expect(asset.json["purpose"] == .string("interview_asset") && asset.json["session_id"] == .string("56"))
    #expect(asset.json["source_type"] == .string("uploaded") && asset.json["transcribe"] == .bool(false) && asset.json["folder_id"] == nil)
    #expect(PieceUpload.contentType("a.m4a") == "audio/x-m4a" || PieceUpload.contentType("a.m4a") == "audio/mp4")
    #expect(PieceUpload.contentType("noext") == "application/octet-stream")
}

@Test func retryPolicyMatchesWeb() {
    #expect(PieceUpload.isFinal(APIError.server(status: 409, code: "UPLOAD_INCOMPLETE")))
    #expect(PieceUpload.isFinal(APIError.server(status: 413, code: "UPLOAD_CHUNK_TOO_LARGE")))
    #expect(!PieceUpload.isFinal(APIError.server(status: 503, code: "HTTP_503")))
    #expect(!PieceUpload.isFinal(APIError.server(status: 429, code: "UPLOAD_TOO_MANY")))
    #expect(!PieceUpload.isFinal(URLError(.timedOut)))
    #expect(PieceUpload.isFinal(APIError.unauthorized))
    #expect([1, 2, 3, 4, 5, 6].map { PieceUpload.delay(attempt: $0) } == [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
    #expect(!PieceUpload.chunked(size: PieceUpload.threshold) && PieceUpload.chunked(size: PieceUpload.threshold + 1))
    #expect(PieceUpload.cancelled(CancellationError()) && PieceUpload.cancelled(URLError(.cancelled)))
}

@Test func senderFillsOnlyMissingPiecesInParallel() async throws {
    let chunk: Int64 = 100
    let (file, data) = try tempFile(950)
    defer { try? FileManager.default.removeItem(at: file) }
    let fake = FakePieces(size: 950, chunk: chunk, received: [1: data[100..<200], 4: data[400..<500]])
    let log = Log()
    let state = try await PieceSender.send(fake, id: uploadID, file: file, size: 950, sleep: { _ in },
                                           events: PieceEvents(progress: { value, _ in log.progress(value) }))
    #expect(state.finished)
    let puts = await fake.puts, parts = await fake.parts, peak = await fake.maxInflight
    #expect(Set(puts) == [0, 2, 3, 5, 6, 7, 8, 9] && puts.count == 8)
    #expect(peak <= PieceUpload.parallel && peak > 1)
    var joined = Data(); for index in 0..<10 { joined.append(parts[index]!) }
    #expect(joined == data)
    #expect(log.all.first == 200 && log.last == 950)
}

@Test func senderRetriesNetworkFailuresFromServerRecord() async throws {
    let (file, data) = try tempFile(300)
    defer { try? FileManager.default.removeItem(at: file) }
    let fake = FakePieces(size: 300, chunk: 100, failOnce: [1: URLError(.networkConnectionLost)])
    let log = Log()
    let state = try await PieceSender.send(fake, id: uploadID, file: file, size: 300, sleep: { _ in },
                                           events: PieceEvents(progress: { value, _ in log.progress(value) }, retry: { log.retry($0) }))
    #expect(state.finished)
    let puts = await fake.puts, parts = await fake.parts
    // 第二轮只补失败的那一片
    #expect(puts.filter { $0 == 1 }.count == 2 && parts[1] == data[100..<200])
    #expect(log.retried.first == 1)
}

@Test func senderStopsOnFinalErrorsAndAfterMaxAttempts() async throws {
    let (file, _) = try tempFile(300)
    defer { try? FileManager.default.removeItem(at: file) }
    let rejected = FakePieces(size: 300, chunk: 100, failOnce: [0: APIError.server(status: 400, code: "UPLOAD_CHUNK_INVALID")])
    await #expect(throws: APIError.server(status: 400, code: "UPLOAD_CHUNK_INVALID")) {
        _ = try await PieceSender.send(rejected, id: uploadID, file: file, size: 300, parallel: 1, sleep: { _ in })
    }
    let rejectedPuts = await rejected.puts
    #expect(rejectedPuts == [0])

    struct Down: PieceTransport {
        func state(_ id: String) async throws -> PieceUploadState { throw URLError(.notConnectedToInternet) }
        func put(_ id: String, index: Int, data: Data, progress: @escaping @Sendable (Int64) -> Void) async throws {}
        func complete(_ id: String) async throws -> PieceUploadState { throw URLError(.notConnectedToInternet) }
    }
    let log = Log()
    await #expect(throws: URLError.self) {
        _ = try await PieceSender.send(Down(), id: uploadID, file: file, size: 300, maxAttempts: 3, sleep: { _ in }, events: PieceEvents(retry: { log.retry($0) }))
    }
    #expect(log.retried == [1, 2])
}

@Test func senderSkipsFinishedUploadsAndRejectsSizeMismatch() async throws {
    let (file, _) = try tempFile(300)
    defer { try? FileManager.default.removeItem(at: file) }
    let fake = FakePieces(size: 300, chunk: 100)
    await fake.markFinished()
    let state = try await PieceSender.send(fake, id: uploadID, file: file, size: 300, sleep: { _ in })
    let puts = await fake.puts, completes = await fake.completes
    #expect(state.finished && puts.isEmpty && completes == 0)
    await #expect(throws: APIError.invalidResponse) {
        _ = try await PieceSender.send(FakePieces(size: 300, chunk: 100), id: uploadID, file: file, size: 299, sleep: { _ in })
    }
    await #expect(throws: APIError.invalidResponse) {
        _ = try await PieceSender.send(fake, id: "not-an-id", file: file, size: 300, sleep: { _ in })
    }
}

@Test func backgroundUploadTextsAndBellState() {
    var item = BackgroundUpload(id: uploadID, sessionID: "8", applicationID: "3", fileName: "得物二面.m4a", fileSize: 1000,
                                source: .init(size: 1000, modified: 1_700_000_000), transcribe: true)
    item.loaded = 150
    let start = Date(timeIntervalSince1970: 1000)
    item.rateFrom = (start, 0)
    #expect(item.percent == 15)
    #expect(item.remaining(now: start.addingTimeInterval(2)) == nil)
    #expect(item.remaining(now: start.addingTimeInterval(30)) == "约 3 分钟")
    #expect(item.runningMeta(now: start.addingTimeInterval(30)) == "已传 15% · 约 3 分钟 · 可以先去做别的")
    item.loaded = 1000
    #expect(item.percent == 99)
    item.status = .retrying; item.loaded = 420
    #expect(item.runningMeta(now: start) == "网络不稳，正在重连… 已传 42%")

    var other = item; other.id = String(repeating: "b", count: 32); other.status = .uploading; other.loaded = 0; other.fileSize = 1000
    var bell = UploadBellState([item, other])
    #expect(bell.progress == 0.21 && bell.dot == nil && bell.summary == "2 个正在上传")
    item.status = .done
    bell = UploadBellState([item])
    #expect(bell.progress == nil && bell.dot == .info && bell.summary == nil)
    #expect(item.resultTitle == "录音已上传" && item.resultAction == "查看" && item.resultCategory == "处理结果")
    item.seen = true
    #expect(UploadBellState([item]).dot == nil)
    item.status = .interrupted
    #expect(UploadBellState([item]).dot == .warn && UploadBellState([item]).summary == "1 条要处理")
    #expect(item.resultAction == "选择文件" && item.resultBody(mismatch: true) == "请选回 得物二面.m4a，要同一个文件才能接着传。")
    #expect(item.matches(name: "得物二面.m4a", source: .init(size: 1000, modified: 1_700_000_000)))
    #expect(!item.matches(name: "得物二面.m4a", source: .init(size: 999, modified: 1_700_000_000)))
    item.status = .failed; item.retryable = false; item.error = BackgroundUpload.errorText(APIError.server(status: 409, code: "DATASET_MEDIA_STORAGE_LIMIT_REACHED"))
    #expect(item.resultAction == nil && item.resultBody() == "录音空间不够了，删掉一些录音或升级会员后再传。")
    #expect(BackgroundUpload.errorText(URLError(.timedOut)) == "网络一直连不上，稍后点重试从断点继续。")
    #expect(UploadBellState([]).progress == nil && UploadBellState([]).dot == nil)
}

@Test func backgroundUploadJournalRestoresAsInterrupted() throws {
    var item = BackgroundUpload(id: uploadID, sessionID: "8", applicationID: "3", fileName: "a.m4a", fileSize: 10,
                                source: .init(size: 10, modified: 5), transcribe: false)
    item.loaded = 4
    let bad = BackgroundUploadJournal(BackgroundUpload(id: "x", sessionID: "8", applicationID: "3", fileName: "a", fileSize: 1, source: .init(size: 1, modified: 0), transcribe: true))
    let data = try JSONEncoder().encode([BackgroundUploadJournal(item), bad])
    let restored = BackgroundUploadJournal.decode(data)
    #expect(restored.count == 1)
    let interrupted = restored[0].interrupted
    #expect(interrupted.status == .interrupted && interrupted.loaded == 0 && !interrupted.transcribe && interrupted.applicationID == "3")
    #expect(BackgroundUploadJournal.decode(Data("oops".utf8)).isEmpty && BackgroundUploadJournal.decode(nil).isEmpty)
    #expect(BackgroundUploadJournal.key(account: "1") == "drawoffer.interviewUploads.v1.1")
}
