import Foundation
import UniformTypeIdentifiers

/// 公共上传通道 `/api/uploads`（后端 `modules/uploads/routes.py`，五个接口都已 `desktop=True`）的路径白名单。
/// 只给专门的分片上传方法用，不进通用的 `careerRequest`，也不带任何查询参数。
public enum UploadRequest {
    /// 服务端上传号：`uuid4().hex`，32 位小写十六进制。
    public static func id(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
    static func index(_ value: String) -> Bool { value == "0" || (value.count <= 5 && DatasetRequest.id(value)) }
    public static func allowed(path: String, method: String) -> Bool {
        if path == "/api/uploads" { return method == "POST" }
        let p = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 4, p.count <= 6, p[0].isEmpty, p[1] == "api", p[2] == "uploads", id(p[3]) else { return false }
        switch p.count {
        case 4: return ["GET", "DELETE"].contains(method)
        case 5: return p[4] == "complete" && method == "POST"
        default: return p[4] == "chunks" && index(p[5]) && method == "PUT"
        }
    }
}

/// `POST /api/uploads` 的请求体（Web `UploadStartBody`）。`purpose` 决定其余字段。
public struct PieceUploadStart: Sendable, Equatable {
    public enum Purpose: String, Sendable { case dataset, datasetReplace = "dataset_replace", interviewAsset = "interview_asset" }
    public var purpose: Purpose
    public var fileName: String
    public var fileSize: Int64
    public var contentType: String
    public var folderID: String? = nil
    public var datasetID: String? = nil
    public var ifMatch: String? = nil
    public var sessionID: String? = nil
    public var sourceType: String? = nil
    public var transcribe = true

    public init(purpose: Purpose, fileName: String, fileSize: Int64, contentType: String) {
        self.purpose = purpose; self.fileName = fileName; self.fileSize = fileSize; self.contentType = contentType
    }

    /// 与单次上传 `DesktopTransport.uploadDataset` 同一份快照：进场次（面试素材）、替换资料或新资料。
    public static func from(_ upload: DatasetUpload, size: Int64) throws -> PieceUploadStart {
        var start = PieceUploadStart(purpose: .dataset, fileName: upload.name, fileSize: size, contentType: PieceUpload.contentType(upload.name))
        if let session = upload.session {
            guard DatasetRequest.id(session), upload.replacing == nil else { throw APIError.invalidResponse }
            start.purpose = .interviewAsset; start.sessionID = session; start.sourceType = "uploaded"; start.transcribe = upload.transcribe
        } else if let replacing = upload.replacing {
            guard DatasetRequest.id(replacing), let revision = upload.revision, !revision.isEmpty, revision.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { throw APIError.invalidResponse }
            start.purpose = .datasetReplace; start.datasetID = replacing; start.ifMatch = "\"dataset-\(replacing)-\(revision)\""
        } else {
            guard DatasetRequest.id(upload.folder) else { throw APIError.invalidResponse }
            start.folderID = upload.folder
        }
        return start
    }

    public var json: JSONValue {
        var fields: [String: JSONValue] = ["purpose": .string(purpose.rawValue), "file_name": .string(fileName),
                                           "file_size": .number(Double(fileSize)), "content_type": .string(contentType)]
        if let folderID { fields["folder_id"] = .string(folderID) }
        if let datasetID { fields["dataset_id"] = .string(datasetID) }
        if let ifMatch { fields["if_match"] = .string(ifMatch) }
        if let sessionID { fields["session_id"] = .string(sessionID) }
        if let sourceType { fields["source_type"] = .string(sourceType) }
        if purpose == .interviewAsset, !transcribe { fields["transcribe"] = .bool(false) }
        return .object(fields)
    }

    var valid: Bool {
        !fileName.isEmpty && fileName.count <= 255 && !fileName.contains(where: { "\r\n\"\\/".contains($0) }) && fileSize > 0 && fileSize <= PieceUpload.maximumBytes
    }
}

/// 服务端的分片上传状态（`UploadStateResponse`）：已收到哪些片；完成后带 `dataset`（资料库）或 `asset`（面试素材）。
public struct PieceUploadState: Sendable, Equatable {
    public let id: String
    public let chunkSize: Int64
    public let totalChunks: Int
    public let fileSize: Int64
    public let received: [Int]
    public let dataset: JSONValue?
    public let asset: JSONValue?

    /// 校验形状：上传号格式、片大小不超过 4 MiB、片数与文件大小对得上、已收到的序号都在范围内。
    public init?(json: JSONValue) {
        guard let id = json["upload_id"]?.stringValue, UploadRequest.id(id),
              let chunk = json["chunk_size"]?.numberValue, let total = json["total_chunks"]?.numberValue, let size = json["file_size"]?.numberValue,
              chunk >= 1, chunk <= Double(PieceUpload.chunkBytes), size >= 1, size <= Double(PieceUpload.maximumBytes),
              total == (size / chunk).rounded(.up) else { return nil }
        let received = (json["received"]?.items ?? []).compactMap { $0.numberValue.map(Int.init) }
        guard received.count == json["received"]?.items.count, received.allSatisfy({ $0 >= 0 && $0 < Int(total) }) else { return nil }
        self.id = id; chunkSize = Int64(chunk); totalChunks = Int(total); fileSize = Int64(size); self.received = received
        dataset = json["dataset"].flatMap { $0 == .null ? nil : $0 }
        asset = json["asset"].flatMap { $0 == .null ? nil : $0 }
    }

    /// 已完成：服务端状态里带了结果，不再发片也不再调 complete。
    public var finished: Bool { dataset != nil || asset != nil }
    public func size(of index: Int) -> Int64 { max(0, min(chunkSize, fileSize - Int64(index) * chunkSize)) }
    public var missing: [Int] { let done = Set(received); return (0..<totalChunks).filter { !done.contains($0) } }
    public var confirmed: Int64 { Set(received).reduce(0) { $0 + size(of: $1) } }
    /// 与单次上传接口相同形状的结果：资料库是资料记录本身，面试素材是 `{asset}`。
    public var result: JSONValue? {
        if let dataset { return dataset }
        if let asset { return .object(["asset": asset]) }
        return nil
    }
}

/// 分片规则（Web `lib/uploads/sendPieces.ts` 与 `api/client.ts`）：超过一片（4 MiB）的文件走分片，同时发 3 片，
/// 一轮里有片失败就停下这一轮、退避后按服务端记录只补缺的片，最多 6 轮；文件或上传记录本身有问题的错误不重试。
public enum PieceUpload {
    public static let chunkBytes: Int64 = 4 * 1024 * 1024
    public static let threshold: Int64 = 4 * 1024 * 1024
    public static let maximumBytes: Int64 = 512 * 1024 * 1024
    public static let parallel = 3
    public static let maxAttempts = 6
    static let finalStatuses: Set<Int> = [400, 403, 404, 409, 412, 413, 422]

    public static func chunked(size: Int64) -> Bool { size > threshold }

    /// 重试也不会好的错误：业务拒绝、登录失效、本地校验失败。断网、超时、5xx 都重试。
    public static func isFinal(_ error: Error) -> Bool {
        switch error {
        case APIError.server(let status, _): return finalStatuses.contains(status)
        case APIError.unauthorized, APIError.invalidResponse: return true
        default: return false
        }
    }

    public static func cancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// 第 n 轮失败后等 2、4、8、16、30、30… 秒。
    public static func delay(attempt: Int) -> Duration { .seconds(min(30, 2 << max(0, attempt - 1))) }

    public static func contentType(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "application/octet-stream" : UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// 读文件第 `index` 片：按服务端给的片大小定位，读到的字节数必须正好是这一片的大小。
    public static func piece(of file: URL, index: Int, in state: PieceUploadState) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(Int64(index) * state.chunkSize))
        let length = Int(state.size(of: index))
        let data = try handle.read(upToCount: length) ?? Data()
        guard data.count == length, length > 0 else { throw APIError.invalidResponse }
        return data
    }
}

/// 查询、发片、完成三个请求；App 侧接到带登录态的 `APIClient` 上，单测里换成假的。
public protocol PieceTransport: Sendable {
    func state(_ id: String) async throws -> PieceUploadState
    func put(_ id: String, index: Int, data: Data, progress: @escaping @Sendable (Int64) -> Void) async throws
    func complete(_ id: String) async throws -> PieceUploadState
}

/// 发送过程的回调：已确认加在途的字节、进入重试或恢复（attempt 0）、每轮开始时已确认的字节（估速用）。
public struct PieceEvents: Sendable {
    public var progress: @Sendable (Int64, Int64) -> Void = { _, _ in }
    public var retry: @Sendable (Int) -> Void = { _ in }
    public var roundStart: @Sendable (Int64) -> Void = { _ in }
    public init(progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }, retry: @escaping @Sendable (Int) -> Void = { _ in },
                roundStart: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.progress = progress; self.retry = retry; self.roundStart = roundStart
    }
}

/// 一轮里的进度：已确认的字节 + 每片在途的字节；还有这一轮有没有传成过一片（传成过就把重试次数清零）。
private final class PieceRound: @unchecked Sendable {
    private let lock = NSLock()
    private var confirmed: Int64
    private var inflight: [Int: Int64] = [:]
    private var pending: [Int]
    private(set) var progressed = false
    init(confirmed: Int64, pending: [Int]) { self.confirmed = confirmed; self.pending = pending }
    func next() -> Int? { lock.withLock { pending.isEmpty ? nil : pending.removeFirst() } }
    func sending(_ index: Int, _ loaded: Int64) -> Int64 { lock.withLock { inflight[index] = loaded; return total } }
    /// 返回新的总进度，以及这是不是这一轮第一片传成的。
    func done(_ index: Int, _ size: Int64) -> (Int64, Bool) {
        lock.withLock { inflight[index] = nil; confirmed += size; defer { progressed = true }; return (total, !progressed) }
    }
    /// 这一片没传成：在途字节不再算进度，返回新的总进度（等重试时进度条不停在虚高的位置）。
    func dropped(_ index: Int) -> Int64 { lock.withLock { inflight[index] = nil; return total } }
    private var total: Int64 { confirmed + inflight.values.reduce(0, +) }
    var value: Int64 { lock.withLock { total } }
}

public enum PieceSender {
    /// 把 `file` 按服务端记录发完并完成上传，返回完成后的状态。网络类失败退避重试，最多 `maxAttempts` 轮。
    public static func send(_ transport: some PieceTransport, id: String, file: URL, size: Int64,
                            parallel: Int = PieceUpload.parallel, maxAttempts: Int = PieceUpload.maxAttempts,
                            sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                            events: PieceEvents = PieceEvents()) async throws -> PieceUploadState {
        guard UploadRequest.id(id), parallel > 0 else { throw APIError.invalidResponse }
        var attempt = 0
        while true {
            var round: PieceRound?
            do {
                try Task.checkCancellation()
                let state = try await transport.state(id)
                guard state.id == id, state.fileSize == size else { throw APIError.invalidResponse }
                if state.finished { events.progress(size, size); return state }
                let current = PieceRound(confirmed: state.confirmed, pending: state.missing); round = current
                events.progress(current.value, size)
                events.roundStart(current.value)
                let retrying = attempt > 0
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<min(parallel, state.missing.count) {
                        group.addTask {
                            while let index = current.next() {
                                try Task.checkCancellation()
                                let data = try PieceUpload.piece(of: file, index: index, in: state)
                                do {
                                    try await transport.put(id, index: index, data: data) { loaded in
                                        events.progress(current.sending(index, min(loaded, Int64(data.count))), size)
                                    }
                                } catch { events.progress(current.dropped(index), size); throw error }
                                let (total, first) = current.done(index, Int64(data.count))
                                if first, retrying { events.retry(0) }
                                events.progress(total, size)
                            }
                        }
                    }
                    try await group.waitForAll()
                }
                try Task.checkCancellation()
                let finished = try await transport.complete(id)
                guard finished.id == id, finished.finished else { throw APIError.invalidResponse }
                events.progress(size, size)
                return finished
            } catch {
                if PieceUpload.cancelled(error) || Task.isCancelled { throw CancellationError() }
                if round?.progressed == true { attempt = 0 }
                attempt += 1
                if PieceUpload.isFinal(error) || attempt >= maxAttempts { throw error }
                events.retry(attempt)
                try await sleep(PieceUpload.delay(attempt: attempt))
            }
        }
    }
}
