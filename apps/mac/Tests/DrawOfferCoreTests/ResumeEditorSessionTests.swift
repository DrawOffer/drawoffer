import Foundation
import Testing
@testable import DrawOfferCore

// 编辑器顶栏 I 区、手动保存与本地草稿、小绘段旁对话（Web a667ae1ba / 96117ada3，upstream c42dbeae9）

@Test func editorHeadMenuMatchesWeb() {
    let items = ResumeEditorMenu.items(canUndo: true, canRedo: false, openCard: .template, exporting: false,
                                       typeDisabled: false, templateDisabled: false, exportDisabled: false)
    #expect(items.map(\.label) == ["撤销", "重做", "", "排版", "模板", "", "导出 PDF"])
    #expect(items.map(\.command) == [.undo, .redo, nil, .type, .template, nil, .export])
    #expect(items[0].hint == "⌘Z" && items[1].hint == "⇧⌘Z")
    #expect(items[0].enabled && !items[1].enabled)
    #expect(!items[3].checked && items[4].checked)
    // 387df9a5d：排版、模板不带省略号
    #expect(!items.contains { $0.label.contains("…") })
    let busy = ResumeEditorMenu.items(canUndo: false, canRedo: false, openCard: nil, exporting: true,
                                      typeDisabled: true, templateDisabled: true, exportDisabled: true)
    #expect(busy[6].label == "导出中…" && !busy[6].enabled)
    #expect(!busy[3].enabled && !busy[4].enabled && !busy[3].checked && !busy[4].checked)
}

@Test func saveButtonOnlyWhenDirty() {
    #expect(ResumeSave.buttonLabel(.idle) == "保存")
    #expect(ResumeSave.buttonLabel(.error) == "保存")
    #expect(ResumeSave.buttonLabel(.saving) == "保存中…")
    #expect(ResumeSave.buttonEnabled(loaded: true, dirty: true, status: .idle, pending: false))
    #expect(ResumeSave.buttonEnabled(loaded: true, dirty: true, status: .error, pending: false))
    #expect(!ResumeSave.buttonEnabled(loaded: true, dirty: false, status: .idle, pending: false))
    #expect(!ResumeSave.buttonEnabled(loaded: true, dirty: true, status: .saving, pending: false))
    #expect(!ResumeSave.buttonEnabled(loaded: true, dirty: true, status: .idle, pending: true))
    #expect(!ResumeSave.buttonEnabled(loaded: false, dirty: true, status: .idle, pending: false))
    #expect(ResumeSave.needsLeaveConfirmation(dirty: true, uploading: false))
    #expect(ResumeSave.needsLeaveConfirmation(dirty: false, uploading: true))
    #expect(!ResumeSave.needsLeaveConfirmation(dirty: false, uploading: false))
    #expect(ResumeSave.failureMessage(code: "RESUME_EDIT_CONFLICT").contains("其他地方修改"))
    #expect(ResumeSave.failureMessage(code: "RESUME_PDF_ASSET_TOO_LARGE") == "图片不能超过 10MB")
    #expect(ResumeSave.failureMessage(code: nil) == "改动还在本页，先别关闭或退出。")
    #expect(ResumeSave.pdfExportError(code: "RESUME_PDF_SNAPSHOT_STALE", status: 409) == "简历内容已变化，请重新导出")
    #expect(ResumeSave.pdfExportError(code: "X", status: 409) == "简历内容已变化，请重新导出")
    #expect(ResumeSave.pdfExportError(code: nil, status: nil) == "PDF 生成失败，请稍后重试")
    #expect(ResumeSave.leaveTitle == "修改还没保存")
    #expect(ResumeSave.leaveDiscard == "暂不保存" && ResumeSave.leaveConfirm == "保存并离开")
}

private func tempStore() -> ResumeDraftStore {
    ResumeDraftStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true))
}

private func draft(user: String = "u1", resume: String = "42", lock: Int = 3, title: String = "虚构简历") -> ResumeLocalDraft {
    ResumeLocalDraft(userID: user, resumeID: resume, baseLockVersion: lock, title: title,
                     data: .object(["sections": .array([])]), style: .object(["template_snapshot": .object([:])]))
}

@Test func localDraftRoundTripsOnlyForSameLockVersion() {
    let store = tempStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    store.write(draft())
    #expect(store.read(user: "u1", resume: "42", lockVersion: 3)?.title == "虚构简历")
    // 别的账号读不到
    #expect(store.read(user: "u2", resume: "42", lockVersion: 3) == nil)
    // 服务端版本变了：草稿作废并删掉
    #expect(store.read(user: "u1", resume: "42", lockVersion: 4) == nil)
    #expect(store.read(user: "u1", resume: "42", lockVersion: 3) == nil)
}

@Test func localDraftDropsCorruptFilesAndClearsPerUser() throws {
    let store = tempStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let url = store.file(user: "u1", resume: "7")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{bad".utf8).write(to: url)
    #expect(store.read(user: "u1", resume: "7", lockVersion: 1) == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    store.write(draft(resume: "1")); store.write(draft(resume: "2")); store.write(draft(user: "u2", resume: "1"))
    store.clearAll(user: "u1")
    #expect(store.read(user: "u1", resume: "1", lockVersion: 3) == nil)
    #expect(store.read(user: "u2", resume: "1", lockVersion: 3) != nil)
    // 路径里不会拼出上级目录
    #expect(!ResumeDraftStore.component("../x").contains("/"))
}

@MainActor @Test func draftKeeperWritesOncePerIntervalAndClearsAfterSave() {
    let store = tempStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let keeper = ResumeDraftKeeper(store: store)
    #expect(keeper.note(draft(title: "第一版")))
    // 计时开始后再改不重新计时
    #expect(!keeper.note(draft(title: "第二版")))
    #expect(store.read(user: "u1", resume: "42", lockVersion: 3) == nil)
    keeper.flush()
    #expect(!keeper.armed && keeper.pending == nil)
    #expect(store.read(user: "u1", resume: "42", lockVersion: 3)?.title == "第二版")
    // 已保存：本地草稿删掉
    #expect(keeper.note(draft(title: "第三版")))
    keeper.clear(user: "u1", resume: "42")
    keeper.flush()
    #expect(store.read(user: "u1", resume: "42", lockVersion: 3) == nil)
    // 换了一份简历：上一份立刻写出去
    keeper.note(draft(resume: "1", title: "甲"))
    keeper.note(draft(resume: "2", title: "乙"))
    #expect(store.read(user: "u1", resume: "1", lockVersion: 3)?.title == "甲")
}

@Test func orbHintAndSelection() {
    #expect(ResumeOrb.hint("项目经历 · 虚构调度平台") == "想改「虚构调度平台」这段？")
    #expect(ResumeOrb.hintAction == "点我改")
    #expect(ResumeOrb.hintAllowed(cursorUnit: true, dismissed: false, open: false, typing: false, away: false, disabled: false,
                                  layoutBusy: false, hasSelection: false, saying: false))
    #expect(!ResumeOrb.hintAllowed(cursorUnit: true, dismissed: false, open: false, typing: true, away: false, disabled: false,
                                   layoutBusy: false, hasSelection: false, saying: false))
    #expect(!ResumeOrb.hintAllowed(cursorUnit: true, dismissed: false, open: false, typing: false, away: false, disabled: false,
                                   layoutBusy: false, hasSelection: true, saying: false))
    #expect(ResumeOrb.takesSelection(hasSelection: true, lineID: "l1", layoutBusy: false))
    #expect(!ResumeOrb.takesSelection(hasSelection: true, lineID: "l1", layoutBusy: true))
    #expect(!ResumeOrb.takesSelection(hasSelection: false, lineID: "l1", layoutBusy: false))
    #expect(ResumeOrb.Action.deepenAll.label == "挑一段来改")
}

@Test func editorChatDirectionsFollowWeb() {
    #expect(ResumeEditorChat.directions(nonExperience: false).map(\.label) == ["深化这一段", "诊断这一段", "直接精修"])
    #expect(ResumeEditorChat.directions(nonExperience: false).map(\.action) == [.deepen, .diagnose, .polish])
    #expect(ResumeEditorChat.directions(nonExperience: true).map(\.label) == ["检查这一栏写法", "精修这一栏"])
    #expect(ResumeEditorChat.isNonExperience(semanticKind: "skills", label: "专业技能"))
    #expect(ResumeEditorChat.isNonExperience(semanticKind: "custom", label: "自我评价"))
    #expect(!ResumeEditorChat.isNonExperience(semanticKind: "projects", label: "项目经历 · 虚构平台"))
}

@Test func editorChatFailureTexts() {
    let credit = ResumeEditorChat.failure(APIError.server(status: 402, code: "CREDIT_INSUFFICIENT"), failures: 0)
    #expect(credit.credit && credit.text == "积分不够，这段没改，简历还是原样。")
    #expect(ResumeEditorChat.failure(APIError.server(status: 403, code: "PAID_CREDIT_REQUIRED"), failures: 0).text == "当前额度不能使用这项功能。")
    #expect(ResumeEditorChat.failure(APIError.invalidResponse, failures: 1).text == "刚才没连上，这段没改成，简历还是原样。")
    #expect(ResumeEditorChat.failure(APIError.invalidResponse, failures: 2).text == "现在有点忙，还是没改成，过一会儿再试。")
    // 桌面端未开放（403 DESKTOP_ROUTE_FORBIDDEN）按普通失败
    #expect(!ResumeEditorChat.failure(APIError.server(status: 403, code: "DESKTOP_ROUTE_FORBIDDEN"), failures: 1).credit)
    #expect(ResumeEditorChat.lineFailure(APIError.invalidResponse, failures: 1).text == "刚才没连上，这句没改成，简历还是原样。")
    #expect(ResumeEditorChat.lineFailure(APIError.server(status: 402, code: "CREDIT_INSUFFICIENT"), failures: 0).text == "积分不够，这句没改，简历还是原样。")
}

@Test func editorChatPendingCardsAndBody() {
    let card: JSONValue = .object([
        "id": .string("c1"), "type": .string("resume_rewrite"), "entry_id": .string("e1"),
        "lines": .array([
            .object(["line_id": .string("l1"), "before": .string("负责虚构模块"), "text": .string("主导虚构模块重构，耗时降 30%"),
                     "marks": .array([.object(["origin": .string("verify"), "text": .string("30%")])])]),
            .object(["line_id": .string("l2"), "before": .string("没变"), "text": .string("没变")]),
        ]),
    ])
    let messages: [JSONValue] = [
        .object(["role": .string("user"), "content": .string(ResumeEditorChat.kickoff), "sequence_no": .number(1)]),
        .object(["role": .string("assistant"), "content": .string("改好了"), "sequence_no": .number(2), "cards": .array([card])]),
        .object(["role": .string("assistant"), "message_type": .string("compaction"), "content": .string("x"), "sequence_no": .number(3)]),
    ]
    let visible = ResumeEditorChat.visible(messages)
    #expect(visible.count == 1)
    let paper = ["l1": "负责虚构模块", "l2": "没变"]
    let pending = ResumeEditorChat.latestPending(visible, dismissed: [], current: { paper[$0] })
    #expect(pending?.card.id == "c1" && pending?.lines.map(\.lineID) == ["l1"])
    #expect(pending?.lines.first?.risky == ["30%"])
    // 纸上已换过 / 放弃了：没有待换上的
    #expect(ResumeEditorChat.latestPending(visible, dismissed: ["c1"], current: { paper[$0] }) == nil)
    #expect(ResumeEditorChat.latestPending(visible, dismissed: [], current: { _ in "主导虚构模块重构，耗时降 30%" }) == nil)

    let body = ResumeEditorChat.messageBody(content: "深化这一段", idempotencyKey: "k", entryID: "e1", lineIDs: ["l1", "l2"], action: .deepen, draftCardID: "c1")
    #expect(body["editor_action"] == .string("deepen"))
    #expect(body["editor_entry_id"] == .string("e1"))
    #expect(body["editor_line_ids"]?.items.count == 2)
    #expect(body["editor_draft_card_id"] == .string("c1"))
    #expect(body["reply_to_sequence_no"] == nil)
    let chat = ResumeEditorChat.chatPath(resumeID: "9", entryID: "e1")
    #expect(chat.path == "/api/resumes/9/editor-chat" && chat.query == ["entry_id": "e1"])
    #expect(ResumeEditorChat.chatPath(resumeID: "9", entryID: "e1", restart: true).path == "/api/resumes/9/editor-chat/restart")
}

@Test func editorChatRoutesAreWhitelisted() {
    #expect(ResumeRequest.allowed(path: "/api/resumes/9/editor-chat", method: "GET"))
    #expect(ResumeRequest.allowed(path: "/api/resumes/9/editor-chat/restart", method: "POST"))
    #expect(!ResumeRequest.allowed(path: "/api/resumes/9/editor-chat/job", method: "PUT"))
    #expect(ResumeRequest.allowed(path: "/api/resumes/9/experience/blk_abc123/applied", method: "POST"))
    #expect(!ResumeRequest.allowed(path: "/api/resumes/9/experience/blk_abc123/doc", method: "GET"))
    #expect(!ResumeRequest.allowed(path: "/api/resumes/9/experience/a.b/applied", method: "POST"))
}
