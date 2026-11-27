import Foundation

/// 编辑器顶栏右上（Web `ResumeWorkbench` 顶栏 I 区、`WorkbenchHeadMenu`，Figma 04 页 I）：
/// 左上只有返回，简历名在正中，右上“保存”+ 最右“⋯”菜单（撤销 / 重做、排版 / 模板、导出 PDF）。
public enum ResumeEditorMenu {
    public enum Command: String, Sendable { case undo, redo, type, template, export }

    public struct Item: Equatable, Sendable {
        /// nil 是分隔线。
        public let command: Command?
        public let label: String
        /// 快捷键提示（⌘Z / ⇧⌘Z）。
        public let hint: String?
        /// 勾选态：对应卡片开着。
        public let checked: Bool
        public let enabled: Bool
        public static let separator = Item(command: nil, label: "", hint: nil, checked: false, enabled: false)
    }

    /// Web `WorkbenchHeadMenu.items`：撤销 ⌘Z、重做 ⇧⌘Z、分隔、排版、模板（勾选 = 卡片开着）、分隔、导出 PDF / 导出中…（387df9a5d 起不带省略号）。
    public static func items(canUndo: Bool, canRedo: Bool, openCard: Command?, exporting: Bool,
                             typeDisabled: Bool, templateDisabled: Bool, exportDisabled: Bool) -> [Item] {
        [
            Item(command: .undo, label: "撤销", hint: "⌘Z", checked: false, enabled: canUndo),
            Item(command: .redo, label: "重做", hint: "⇧⌘Z", checked: false, enabled: canRedo),
            .separator,
            Item(command: .type, label: "排版", hint: nil, checked: openCard == .type, enabled: !typeDisabled),
            Item(command: .template, label: "模板", hint: nil, checked: openCard == .template, enabled: !templateDisabled),
            .separator,
            Item(command: .export, label: exporting ? "导出中…" : "导出 PDF", hint: nil, checked: false, enabled: !exportDisabled),
        ]
    }
}

/// 保存（Web `saveCurrentResume` 与顶栏“保存”）：只有点“保存”/ ⌘S 才存到服务端；没保存的修改定期写到这台电脑，下次打开时恢复。
public enum ResumeSave {
    public enum Status: Equatable, Sendable { case idle, saving, error }

    /// `.wbs-save`：保存中显示“保存中…”。
    public static func buttonLabel(_ status: Status) -> String { status == .saving ? "保存中…" : "保存" }

    /// Web：`!activeResumeId || !dirty || saveStatus === "saving" || versionOperationPending` 时禁用。
    public static func buttonEnabled(loaded: Bool, dirty: Bool, status: Status, pending: Bool) -> Bool {
        loaded && dirty && status != .saving && !pending
    }

    /// 离开编辑器：有没保存的修改（或图片还在上传）时先问。
    public static func needsLeaveConfirmation(dirty: Bool, uploading: Bool) -> Bool { dirty || uploading }

    /// Web 保存失败常驻提示（Figma 21 · C3）：标题“简历没有保存”，说明按错误码给。
    public static let failureTitle = "简历没有保存"
    /// Web：冲突时“这份简历已在其他地方修改，刷新页面后再编辑。”——桌面端没有“刷新页面”，对应顶栏的“重新载入”。
    public static func failureMessage(code: String?) -> String {
        if let image = imageContractMessage(code) { return image }
        return code == "RESUME_EDIT_CONFLICT" ? "这份简历已在其他地方修改，重新载入后再编辑。" : "改动还在本页，先别关闭或退出。"
    }

    /// Web `resumeImageContractErrorMessage`。
    public static func imageContractMessage(_ code: String?) -> String? {
        switch code {
        case "RESUME_PDF_ASSETS_TOO_LARGE": "简历中引用的图片总大小不能超过 10MB"
        case "RESUME_PDF_ASSET_TOO_LARGE": "图片不能超过 10MB"
        case "RESUME_PDF_IMAGE_UNSUPPORTED": "仅支持 PNG 或 JPEG 图片"
        case "RESUME_PDF_IMAGE_UNAVAILABLE", "RESUME_PDF_ASSET_READ_FAILED": "简历中的图片暂时无法读取，请重新上传后再试"
        default: nil
        }
    }

    /// Web `resumePdfExportErrorMessage`。
    public static func pdfExportError(code: String?, status: Int?) -> String {
        switch code {
        case "RESUME_PDF_SNAPSHOT_STALE": return "简历内容已变化，请重新导出"
        case "RESUME_PDF_PAGE_TOO_TALL": return "简历内容过长，请调整内容后重试"
        case "RESUME_PDF_ASSETS_TOO_LARGE": return "简历中引用的图片总大小不能超过 10MB"
        case "RESUME_PDF_ASSET_TOO_LARGE": return "图片不能超过 10MB"
        case "RESUME_PDF_ASSET_READ_FAILED", "RESUME_PDF_IMAGE_UNAVAILABLE", "RESUME_PDF_IMAGE_UNSUPPORTED": return "PDF 生成失败，请检查简历中的图片后重试"
        case "RESUME_PDF_RATE_LIMITED", "RATE_LIMITED": return "导出太频繁了，请一分钟后再试"
        case "RESUME_PDF_BUSY", "RESUME_PDF_RENDERER_UNAVAILABLE", "RESUME_PDF_RENDER_FAILED", "RESUME_PDF_TIMEOUT": return "PDF 服务暂时不可用，请稍后重试"
        default: return status == 409 ? "简历内容已变化，请重新导出" : "PDF 生成失败，请稍后重试"
        }
    }

    /// 离开确认（Web `ConfirmDialog`）。Web 原文“修改只留在这台电脑的浏览器里”，桌面端存在这台电脑上，去掉“的浏览器”。
    public static let leaveTitle = "修改还没保存"
    public static let leaveMessage = "不保存的话，修改只留在这台电脑上，下次打开这份简历时恢复。"
    public static let leaveDiscard = "暂不保存"
    public static let leaveConfirm = "保存并离开"
    /// 保存并离开没存成：留在本页（Web toast）。
    public static let leaveFailed = "保存失败，已留在当前页面，请重试"

    /// Web `LOCAL_RESUME_DRAFT_WRITE_DELAY_MS`：编辑中的修改每分钟写一次本地。
    public static let draftInterval: Duration = .seconds(60)
}

/// 本地草稿（Web `LocalResumeDraft`，`drawoffer:resume-draft:v1:<用户>:<简历>`）：按账号 + 简历各存一份。
/// 只在服务端版本还是写草稿时那一版（`base_lock_version` 相同）时恢复；对不上或读坏了就删掉。
public struct ResumeLocalDraft: Codable, Equatable, Sendable {
    public var version = 1
    public let userID: String
    public let resumeID: String
    public let baseLockVersion: Int
    public let title: String
    public let data: JSONValue
    public let style: JSONValue
    public let updatedAt: Date

    public init(userID: String, resumeID: String, baseLockVersion: Int, title: String, data: JSONValue, style: JSONValue, updatedAt: Date = Date()) {
        self.userID = userID; self.resumeID = resumeID; self.baseLockVersion = baseLockVersion
        self.title = title; self.data = data; self.style = style; self.updatedAt = updatedAt
    }
}

/// 草稿存在 `~/Library/Application Support/DrawOffer/resume-drafts/<账号>/<简历>.json`（目录只给本人读写）。
public struct ResumeDraftStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func standard() -> ResumeDraftStore? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return ResumeDraftStore(root: support.appendingPathComponent("DrawOffer", isDirectory: true).appendingPathComponent("resume-drafts", isDirectory: true))
    }

    /// 账号、简历 id 只取字母数字和 -_，其余转成 %xx，防止拼出别的路径。
    static func component(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_") ? String(scalar) : String(format: "%%%02X", scalar.value)
        }.joined()
    }

    func directory(user: String) -> URL { root.appendingPathComponent(Self.component(user), isDirectory: true) }
    func file(user: String, resume: String) -> URL { directory(user: user).appendingPathComponent(Self.component(resume) + ".json") }

    public func write(_ draft: ResumeLocalDraft) {
        guard !draft.userID.isEmpty, let data = try? JSONEncoder().encode(draft) else { return }
        let folder = directory(user: draft.userID)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file(user: draft.userID, resume: draft.resumeID), options: .atomic)
        } catch {
            // 磁盘写不进去时照样能存到服务端，不打扰
        }
    }

    /// 读回这份简历的草稿：账号、简历、服务端版本都对得上才用；对不上或读坏了就删。
    public func read(user: String, resume: String, lockVersion: Int) -> ResumeLocalDraft? {
        guard !user.isEmpty else { return nil }
        let url = file(user: user, resume: resume)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let draft = try? JSONDecoder().decode(ResumeLocalDraft.self, from: data), draft.version == 1,
              draft.userID == user, draft.resumeID == resume, draft.baseLockVersion == lockVersion else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return draft
    }

    public func clear(user: String, resume: String) {
        guard !user.isEmpty else { return }
        try? FileManager.default.removeItem(at: file(user: user, resume: resume))
    }

    /// 退出登录：这个账号的草稿全部删掉（Web `clearLocalResumeDraftsForUser`）。
    public func clearAll(user: String) {
        guard !user.isEmpty else { return }
        try? FileManager.default.removeItem(at: directory(user: user))
    }
}

/// Web `scheduleLocalResumeDraft`：有改动就记下最新的一份，第一次改动起一分钟写一次（不随每次编辑重新计时）；
/// 换简历、离开时立刻写；已保存（不再有改动）时删掉本地草稿。
@MainActor
public final class ResumeDraftKeeper {
    public let store: ResumeDraftStore?
    public private(set) var pending: ResumeLocalDraft?
    /// 计时是否已开始（开始后到写入前，再改不重新计时）。
    public private(set) var armed = false

    public init(store: ResumeDraftStore?) { self.store = store }

    /// 记下当前状态。返回 true 表示调用方要开始一分钟的计时。
    @discardableResult
    public func note(_ draft: ResumeLocalDraft) -> Bool {
        if let pending, pending.userID != draft.userID || pending.resumeID != draft.resumeID { flush() }
        pending = draft
        guard !armed else { return false }
        armed = true
        return true
    }

    /// 计时到了、离开、换简历：把记下的写出去。
    public func flush() {
        armed = false
        guard let draft = pending else { return }
        pending = nil
        store?.write(draft)
    }

    /// 已保存或换成了服务端内容：本地草稿不再需要。
    public func clear(user: String, resume: String) {
        if pending?.userID == user, pending?.resumeID == resume { pending = nil; armed = false }
        store?.clear(user: user, resume: resume)
    }
}
