import Foundation

/// 面试录音的后台上传（Web `features/interviews/backgroundUploads.ts` 与 `BackgroundUploadBell.tsx`，Mac 稿 12 页分区 05）：
/// 导入弹窗把录音交给后台就关，进度并到侧栏铃铛——上传中铃铛外圈是进度环，弹层最上面一行进度；
/// 传完、失败和中断变成铃铛里的条目并亮点。这里是不依赖界面的状态与文案。
public struct BackgroundUpload: Identifiable, Sendable, Equatable {
    public enum Status: String, Sendable { case compressing, uploading, retrying, failed, interrupted, done }
    /// 导入面试记录时带上（Web `review`）：传完接着等转写、自动复盘。`replace` 是用户确认过替换原有记录。
    public struct Review: Codable, Sendable, Equatable {
        public var title: String
        public var replace: Bool
        public init(title: String, replace: Bool) { self.title = title; self.replace = replace }
    }
    /// 用户选的原文件，重开 App 后选回文件时按它核对（名字、大小、修改时间）。
    public struct Source: Codable, Sendable, Equatable {
        public var size: Int64
        public var modified: Double
        public init(size: Int64, modified: Double) { self.size = size; self.modified = modified }
        public static func of(_ url: URL) throws -> Source {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return Source(size: Int64(values.fileSize ?? 0), modified: (values.contentModificationDate ?? .distantPast).timeIntervalSince1970.rounded())
        }
    }

    /// 服务端上传号；还在压缩、没开始上传时是本地临时号（`local-…`）。
    public var id: String
    public var sessionID: String
    public var applicationID: String
    public var fileName: String
    public var fileSize: Int64
    public var source: Source
    public var transcribe: Bool
    /// 传的是压缩后的文件：重开 App 后选回文件不能接着上次的分片传，要重新压缩、另开一次上传。
    public var compressed = false
    public var review: Review? = nil
    /// 已确认送达加正在发出的字节；压缩中是压缩进度对应的字节。
    public var loaded: Int64 = 0
    public var status: Status = .uploading
    public var error: String? = nil
    /// 失败后能否点重试（网络类失败可以；文件或上传记录本身有问题不行）。
    public var retryable = false
    /// 这一轮开始发送的时间和当时已确认的字节，用来估算剩余时间。
    public var rateFrom: (at: Date, loaded: Int64)? = nil
    /// 传完、失败或中断后，用户在铃铛里看过没有（看过就不再亮点）。
    public var seen = false

    public init(id: String, sessionID: String, applicationID: String, fileName: String, fileSize: Int64, source: Source, transcribe: Bool,
                review: Review? = nil) {
        self.id = id; self.sessionID = sessionID; self.applicationID = applicationID; self.fileName = fileName
        self.fileSize = fileSize; self.source = source; self.transcribe = transcribe; self.review = review
    }

    /// 还在压缩、服务端还没有这次上传（Web `local-` 开头的临时号）。
    public static func localID() -> String { "local-" + UUID().uuidString.lowercased() }
    public var local: Bool { id.hasPrefix("local-") }

    public static func == (lhs: BackgroundUpload, rhs: BackgroundUpload) -> Bool {
        lhs.id == rhs.id && lhs.loaded == rhs.loaded && lhs.status == rhs.status && lhs.error == rhs.error && lhs.seen == rhs.seen
            && lhs.retryable == rhs.retryable && lhs.rateFrom?.at == rhs.rateFrom?.at && lhs.rateFrom?.loaded == rhs.rateFrom?.loaded && lhs.fileName == rhs.fileName
            && lhs.fileSize == rhs.fileSize && lhs.compressed == rhs.compressed
    }

    /// 正在压缩、上传或重连。
    public var running: Bool { status == .compressing || status == .uploading || status == .retrying }
    public var needsAction: Bool { status == .failed || status == .interrupted }

    /// 0–99：传完前不显示 100。
    public var percent: Int { fileSize > 0 ? min(99, Int(Double(loaded) / Double(fileSize) * 100)) : 0 }

    /// 至少传了 3 秒才估算剩余时间，太早的速度不准。
    public func remaining(now: Date) -> String? {
        guard let from = rateFrom, now.timeIntervalSince(from.at) >= 3, loaded > from.loaded else { return nil }
        let rate = Double(loaded - from.loaded) / now.timeIntervalSince(from.at)
        let seconds = Double(fileSize - loaded) / rate
        return seconds < 60 ? "不到 1 分钟" : "约 \(Int((seconds / 60).rounded())) 分钟"
    }

    /// 进度行标题与下面一行灰字（05.2，Web `RunningRow`）。
    public var runningTitle: String { "\(status == .compressing ? "正在压缩" : "正在上传") \(fileName)" }
    public func runningMeta(now: Date) -> String {
        if status == .compressing { return "已压缩 \(percent)% · 压完再传会快很多 · 可以先去做别的" }
        if status == .retrying { return "网络不稳，正在重连… 已传 \(percent)%" }
        return (["已传 \(percent)%", remaining(now: now), "可以先去做别的"] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }

    /// 传完、失败、中断后在铃铛里的条目（05.3 / 05.4）。
    public var resultTitle: String { status == .done ? "录音已上传" : status == .interrupted ? "录音上传中断了" : "录音没有传完" }
    public func resultBody(mismatch: Bool = false) -> String {
        switch status {
        case .done: return "\(fileName) 正在转写，好了会出现在这场面试的资料里。"
        case .interrupted: return mismatch ? "请选回 \(fileName)，要同一个文件才能接着传。" : "\(fileName) 选回同一个文件，就从断点接着传。"
        default: return error ?? "\(fileName) 没有传完。"
        }
    }
    public var resultAction: String? { status == .done ? "查看" : status == .interrupted ? "选择文件" : retryable ? "重试" : nil }
    public var resultCategory: String { status == .done ? "处理结果" : "需要处理" }

    /// 选回的文件是不是当初那一个。
    public func matches(name: String, source: Source) -> Bool { name == fileName && source == self.source }

    /// Web `errorText`：把上传失败说成人话。
    public static func errorText(_ error: Error) -> String {
        if case APIError.server(_, let code) = error {
            switch code {
            case "DATASET_MEDIA_STORAGE_LIMIT_REACHED": return "录音空间不够了，删掉一些录音或升级会员后再传。"
            case "DATASET_FILE_TOO_LARGE": return "文件太大了，录音最大 500 MB。"
            case "UNSUPPORTED_DATASET_FILE": return "这个格式传不了，换成 mp3、m4a 或 wav 试试。"
            case "UPLOAD_TOO_MANY", "INTERVIEW_UPLOAD_TOO_MANY": return "同时在传的文件太多了，等前面的传完再试。"
            case "UPLOAD_NOT_FOUND", "INTERVIEW_UPLOAD_NOT_FOUND": return "这次上传已过期，请重新导入。"
            default: break
            }
        }
        return "网络一直连不上，稍后点重试从断点继续。"
    }
}

/// 重开 App 后还能接着传的记录（Web `drawoffer.interviewUploads.v1`）：只记上传号、场次、文件名与大小，不记文件内容。
public struct BackgroundUploadJournal: Codable, Sendable, Equatable {
    public var id: String
    public var sessionID: String
    public var applicationID: String
    public var fileName: String
    public var fileSize: Int64
    public var source: BackgroundUpload.Source
    public var transcribe: Bool
    /// 旧版本记的条目没有这两项：传的就是原文件、不自动复盘。
    public var compressed: Bool?
    public var review: BackgroundUpload.Review?

    public init(_ item: BackgroundUpload) {
        id = item.id; sessionID = item.sessionID; applicationID = item.applicationID; fileName = item.fileName
        fileSize = item.fileSize; source = item.source; transcribe = item.transcribe; compressed = item.compressed; review = item.review
    }

    public var valid: Bool { UploadRequest.id(id) && DatasetRequest.id(sessionID) && !fileName.isEmpty && fileSize > 0 }

    /// 重开后列出来，状态为「中断」，等用户选回文件。
    public var interrupted: BackgroundUpload {
        var item = BackgroundUpload(id: id, sessionID: sessionID, applicationID: applicationID, fileName: fileName, fileSize: fileSize, source: source,
                                    transcribe: transcribe, review: review)
        item.compressed = compressed ?? false
        item.status = .interrupted
        return item
    }

    public static func key(account: String) -> String { "drawoffer.interviewUploads.v1." + account }
    public static func decode(_ data: Data?) -> [BackgroundUploadJournal] {
        guard let data, let list = try? JSONDecoder().decode([BackgroundUploadJournal].self, from: data) else { return [] }
        return list.filter(\.valid)
    }
}

/// 铃铛要显示的上传状态：外圈进度（没有在传时为 nil）、点的颜色、弹层标题旁的一句话。
public struct UploadBellState: Equatable, Sendable {
    public enum Dot: Sendable { case warn, info }
    public var progress: Double?
    public var dot: Dot?
    public var summary: String?

    public init(_ uploads: [BackgroundUpload]) {
        let running = uploads.filter(\.running)
        let total = running.reduce(Int64(0)) { $0 + $1.fileSize }
        progress = running.isEmpty ? nil : total > 0 ? Double(running.reduce(Int64(0)) { $0 + $1.loaded }) / Double(total) : 0
        let pending = uploads.filter(\.needsAction).count
        dot = pending > 0 ? .warn : uploads.contains { $0.status == .done && !$0.seen } ? .info : nil
        summary = !running.isEmpty ? "\(running.count) 个正在上传" : pending > 0 ? "\(pending) 条要处理" : nil
    }
}
