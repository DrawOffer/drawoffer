import AppKit
import DrawOfferCore
import Foundation

/// 面试录音的后台上传（Web `features/interviews/backgroundUploads.ts`）：导入弹窗把录音交给这里就关。录音先压缩成 m4a（能压的话，
/// 规则见 `AudioCompression`），再走公共上传通道（/api/uploads）按 4 MB 一片、同时 3 片发送，断网或单片失败自动重试；进度与结果都在侧栏铃铛里。
/// 退出 App 后文件快照不留，记录还在：重开后铃铛里提示选回同一个文件——没压缩过的按服务端已收到的分片接着传；
/// 压缩过的重新压缩后另开一次上传（两次压缩的字节不保证一致，不能拼到上次的分片上）。
/// 导入面试记录时（带 `review`）传完不算完：交给 `RecordImports` 等转写、转好自动复盘。
@MainActor @Observable
final class BackgroundUploads {
    private(set) var items: [BackgroundUpload] = []
    /// 第一次后台上传时在铃铛旁提示一句；点过「知道了」或打开过铃铛就不再出现。
    private(set) var hint = false
    /// 导入弹窗交出录音后让铃铛自己展开一次（Web `showImportProgress`）。
    private(set) var revealed: UUID?
    /// 要发送的快照（压缩过的就是压缩后的文件），按上传号。
    @ObservationIgnored private var files: [String: DatasetUpload] = [:]
    /// 还在压缩或压缩阶段失败的条目的原文件快照，按本地临时号；重试时从压缩重新来。
    @ObservationIgnored private var originals: [String: DatasetUpload] = [:]
    /// 录音传完后接着等转写、自动复盘。
    @ObservationIgnored weak var imports: RecordImports?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var account = ""
    @ObservationIgnored private var api: (any APIClient)?

    /// 退出前确认用（App 委托拿不到环境里的对象）。
    static weak var current: BackgroundUploads?
    private static let hintKey = "drawoffer.uploadBellHint.v1"

    init() { Self.current = self }

    var bell: UploadBellState { UploadBellState(items) }
    var running: Bool { items.contains(where: \.running) }

    /// 登录、退出或换账号：停掉手上的上传（服务端分片留着，之后可续传），换成这个账号上次没传完的记录。
    func reset(account: String, api: any APIClient) {
        self.api = api
        guard account != self.account else { return }
        tasks.values.forEach { $0.cancel() }; tasks = [:]
        files.values.forEach { $0.discard() }; files = [:]
        originals.values.forEach { $0.discard() }; originals = [:]
        self.account = account
        items = account.isEmpty ? [] : BackgroundUploadJournal.decode(UserDefaults.standard.data(forKey: BackgroundUploadJournal.key(account: account))).map(\.interrupted)
    }

    /// 导入弹窗建好这场面试后调用（Web `startRecordingUpload`）：开始后台上传，返回时弹窗就可以关了。
    /// 能压缩的录音先在后台压缩，之后开始失败（空间不够等）显示在铃铛里；不压缩的照旧开始失败会抛错，由弹窗提示。
    func start(session sessionID: String, application applicationID: String, file: URL, transcribe: Bool, review: BackgroundUpload.Review? = nil) async throws {
        guard let api, !account.isEmpty else { throw APIError.unauthorized }
        let owner = account
        let source = try BackgroundUpload.Source.of(file)
        var snapshot = try await Task.detached { try DatasetUpload.snapshot(file, session: sessionID, limit: PieceUpload.maximumBytes) }.value
        snapshot.transcribe = transcribe
        guard owner == account else { snapshot.discard(); throw CancellationError() }
        var item = BackgroundUpload(id: BackgroundUpload.localID(), sessionID: sessionID, applicationID: applicationID, fileName: file.lastPathComponent,
                                    fileSize: source.size, source: source, transcribe: transcribe, review: review)
        if AudioCompression.compressible(name: snapshot.name, size: source.size) {
            item.status = .compressing
            items.append(item); originals[item.id] = snapshot
            showHint()
            compress(item.id)
            return
        }
        do {
            let state = try await api.startPieceUpload(try PieceUploadStart.from(snapshot, size: source.size), key: snapshot.id)
            guard owner == account else { snapshot.discard(); Task { try? await api.cancelPieceUpload(state.id) }; throw CancellationError() }
            item.id = state.id
            items.append(item); files[item.id] = snapshot
            journal(item)
            showHint()
            run(item.id)
        } catch { snapshot.discard(); throw error }
    }

    /// 失败后点重试（快照还在）：还没开始上传的从压缩重新来，其余按服务端记录从断点继续。
    func retry(_ id: String) {
        if originals[id] != nil {
            patch(id) { $0.status = .compressing; $0.error = nil; $0.loaded = 0 }
            compress(id)
        } else if files[id] != nil { run(id) }
    }

    /// 重开 App 后选回同一个文件继续；不是同一个文件返回 false。
    func resume(_ id: String, file: URL) async -> Bool {
        guard let item = items.first(where: { $0.id == id }), item.status == .interrupted,
              let source = try? BackgroundUpload.Source.of(file), item.matches(name: file.lastPathComponent, source: source) else { return false }
        let owner = account, sessionID = item.sessionID
        guard var snapshot = try? await Task.detached(operation: { try DatasetUpload.snapshot(file, session: sessionID, limit: PieceUpload.maximumBytes) }).value else { return false }
        snapshot.transcribe = item.transcribe
        guard owner == account, let index = items.firstIndex(where: { $0.id == id }) else { snapshot.discard(); return true }
        if item.compressed {
            // 压缩过的不能接着上次的分片传：丢掉上次的，重新压缩后另开一次
            if let api { Task { try? await api.cancelPieceUpload(id) } }
            forget(id)
            var local = BackgroundUpload(id: BackgroundUpload.localID(), sessionID: item.sessionID, applicationID: item.applicationID, fileName: item.fileName,
                                         fileSize: item.source.size, source: item.source, transcribe: item.transcribe, review: item.review)
            local.status = .compressing
            items[index] = local; originals[local.id] = snapshot
            compress(local.id)
            return true
        }
        files[id]?.discard(); files[id] = snapshot
        run(id)
        return true
    }

    /// 取消或删掉这条：停止上传、不再续传，没传完的通知服务端丢掉已传的分片。
    func dismiss(_ id: String) {
        let item = items.first { $0.id == id }
        tasks[id]?.cancel()
        forget(id)
        items.removeAll { $0.id == id }
        if let item, !item.local, item.status != .done, let api { Task { try? await api.cancelPieceUpload(id) } }
    }

    func reveal() { revealed = UUID() }

    /// 打开铃铛：提示收起；关上时传完、失败和中断的都算看过。
    func opened() { dismissHint() }
    func markSeen() {
        guard items.contains(where: { !$0.seen && !$0.running }) else { return }
        for index in items.indices where !items[index].running { items[index].seen = true }
    }
    private func showHint() { if UserDefaults.standard.bool(forKey: Self.hintKey) == false { hint = true } }
    func dismissHint() {
        guard hint else { return }
        hint = false
        UserDefaults.standard.set(true, forKey: Self.hintKey)
    }

    private func run(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = Task { await send(id) }
    }

    private func compress(_ localID: String) {
        tasks[localID]?.cancel()
        tasks[localID] = Task { await compressThenBegin(localID) }
    }

    /// 先压缩（压缩中可取消），再开始上传；这一步的失败显示在铃铛里（Web `compressThenBegin`）。
    private func compressThenBegin(_ localID: String) async {
        guard let api, let original = originals[localID], let size = items.first(where: { $0.id == localID })?.source.size else { return }
        let owner = account
        do {
            let prepared = try await original.compressingAudio { fraction in
                Task { @MainActor [weak self] in self?.patch(localID) { if $0.status == .compressing { $0.loaded = Int64(Double(size) * min(1, fraction)) } } }
            }
            guard !Task.isCancelled, owner == account, items.contains(where: { $0.id == localID }) else { prepared.dropCompressed(from: original); return }
            patch(localID) { $0.compressed = prepared.isCompressed(from: original); $0.loaded = 0 }
            try await begin(localID, prepared, original: original)
        } catch {
            if PieceUpload.cancelled(error) || Task.isCancelled || owner != account { return }
            tasks[localID] = nil
            let final = PieceUpload.isFinal(error)
            if final { originals.removeValue(forKey: localID)?.discard() }
            patch(localID) { $0.status = .failed; $0.error = BackgroundUpload.errorText(error); $0.retryable = !final; $0.rateFrom = nil; $0.seen = false }
        }
    }

    /// 在服务端开一次上传，把本地条目换成服务端上传号，然后开始发送（Web `begin`）。
    private func begin(_ localID: String, _ upload: DatasetUpload, original: DatasetUpload) async throws {
        guard let api else { return }
        let owner = account
        let size = Int64(try upload.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let state: PieceUploadState
        do { state = try await api.startPieceUpload(try PieceUploadStart.from(upload, size: size), key: upload.id) }
        catch { upload.dropCompressed(from: original); throw error }
        guard owner == account, let index = items.firstIndex(where: { $0.id == localID }) else {
            // 开始请求在路上时用户取消了：服务端这次上传马上丢掉
            Task { try? await api.cancelPieceUpload(state.id) }
            return
        }
        var started = items[index]
        started.id = state.id; started.fileSize = size; started.loaded = 0; started.status = .uploading
        items[index] = started
        originals[localID] = nil; tasks[localID] = nil
        files[state.id] = upload
        journal(started)
        run(state.id)
    }

    private func send(_ id: String) async {
        guard let api, let file = files[id], let item = items.first(where: { $0.id == id }) else { return }
        patch(id) { $0.status = .uploading; $0.error = nil; $0.rateFrom = nil }
        let events = PieceEvents(
            progress: { loaded, _ in Task { @MainActor [weak self] in self?.patch(id) { if $0.running { $0.loaded = loaded } } } },
            retry: { attempt in Task { @MainActor [weak self] in self?.patch(id) { guard $0.running else { return }; $0.status = attempt > 0 ? .retrying : .uploading; if attempt > 0 { $0.rateFrom = nil } } } },
            roundStart: { confirmed in Task { @MainActor [weak self] in self?.patch(id) { $0.rateFrom = (Date(), confirmed) } } })
        do {
            let state = try await PieceSender.send(APIPieceTransport(api: api), id: id, file: file.file, size: item.fileSize, events: events)
            guard !Task.isCancelled else { return }
            forget(id)
            if let review = item.review, let asset = state.asset?.display("id").nonEmptyValue, let imports {
                // 这件事还没完：换成铃铛里的「正在转写」，转好了自动复盘
                items.removeAll { $0.id == id }
                imports.startRecordingReview(session: item.sessionID, application: item.applicationID, dataset: asset, title: review.title, replace: review.replace)
                return
            }
            patch(id) { $0.status = .done; $0.loaded = $0.fileSize; $0.error = nil; $0.rateFrom = nil; $0.seen = false }
        } catch {
            if PieceUpload.cancelled(error) || Task.isCancelled { return }
            tasks[id] = nil
            let final = PieceUpload.isFinal(error)
            if final { forget(id) }
            patch(id) { $0.status = .failed; $0.error = BackgroundUpload.errorText(error); $0.retryable = !final; $0.rateFrom = nil; $0.seen = false }
        }
    }

    private func patch(_ id: String, _ change: (inout BackgroundUpload) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]; change(&item)
        if item != items[index] { items[index] = item }
    }

    private var journalKey: String { BackgroundUploadJournal.key(account: account) }
    private func readJournal() -> [BackgroundUploadJournal] { BackgroundUploadJournal.decode(UserDefaults.standard.data(forKey: journalKey)) }
    private func writeJournal(_ entries: [BackgroundUploadJournal]) {
        if entries.isEmpty { UserDefaults.standard.removeObject(forKey: journalKey) }
        else if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: journalKey) }
    }
    private func journal(_ item: BackgroundUpload) { writeJournal(readJournal().filter { $0.id != item.id } + [BackgroundUploadJournal(item)]) }
    private func forget(_ id: String) {
        writeJournal(readJournal().filter { $0.id != id })
        files.removeValue(forKey: id)?.discard()
        originals.removeValue(forKey: id)?.discard()
        tasks[id] = nil
    }
}
