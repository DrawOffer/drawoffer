import Foundation
import Testing
@testable import DrawOfferCore

private func record(_ fields: [String: JSONValue]) -> DatasetRecord { DatasetRecord(.object(fields)) }

@Test func viewerSortsKindsAndEditability() {
    let md = record(["file_format": .string("md"), "asset_kind": .string("document"), "upload_status": .string("succeeded"), "parse_status": .string("succeeded")])
    #expect(DatasetViewer.kind(md) == .markdown && DatasetViewer.editable(md))
    let parsing = record(["file_format": .string("txt"), "upload_status": .string("succeeded"), "parse_status": .string("processing")])
    #expect(DatasetViewer.kind(parsing) == .text && DatasetViewer.textMode(parsing) && !DatasetViewer.editable(parsing) && DatasetViewer.pending(parsing))
    #expect(DatasetViewer.kind(record(["file_format": .string("PDF")])) == .pdf)
    #expect(DatasetViewer.kind(record(["file_format": .string("docx")])) == .docx)
    #expect(DatasetViewer.kind(record(["file_format": .string("png"), "asset_kind": .string("image")])) == .image)
    #expect(DatasetViewer.kind(record(["file_format": .string("m4a"), "asset_kind": .string("audio")])) == .audio)
    #expect(DatasetViewer.kind(record(["file_format": .string("mp4"), "asset_kind": .string("video")])) == .video)
    #expect(DatasetViewer.pending(record(["upload_status": .string("uploading")])))
    let review = record(["file_format": .string("md"), "source_resume_id": .string("7"), "source_entry_id": .string("e1")])
    #expect(DatasetViewer.experienceSource(review)?.entry == "e1")
    #expect(DatasetViewer.experienceSource(record(["file_format": .string("pdf"), "source_resume_id": .string("7"), "source_entry_id": .string("e1")])) == nil)
}

@Test func viewerMetaFollowsWebOrder() {
    let pdf = record(["file_format": .string("pdf"), "file_size": .number(2.4 * 1024 * 1024), "created_at": .string("2026-10-12T02:00:00Z"),
                      "interview_label": .string("二面"), "upload_status": .string("succeeded"), "parse_status": .string("succeeded")])
    #expect(DatasetViewer.meta(pdf, pages: 4) == ["2.4 MB", "4 页", "10-12 上传", "已关联 二面"])
    let audio = record(["file_format": .string("m4a"), "asset_kind": .string("audio"), "file_size": .number(38 * 1024 * 1024), "created_at": .string("2026-10-14T20:00:00Z"), "parse_status": .string("processing")])
    // 北京时间已是 10-15；音频转写中不写「正在解析」
    #expect(DatasetViewer.meta(audio, duration: 2530) == ["38 MB", "42:10", "10-15 上传"])
    let image = record(["file_format": .string("png"), "asset_kind": .string("image"), "file_size": .number(860 * 1024), "created_at": .string("2026-10-18T01:00:00Z")])
    #expect(DatasetViewer.meta(image, imageSize: CGSize(width: 1920, height: 1080)) == ["860 KB", "1920×1080", "10-18 上传"])
    let parsing = record(["file_format": .string("md"), "file_size": .number(100), "created_at": .string("2026-10-08T01:00:00Z"), "parse_status": .string("queued")])
    #expect(DatasetViewer.meta(parsing).last == "正在解析…")
    let review = record(["file_format": .string("md"), "source_resume_id": .string("7"), "source_entry_id": .string("e1"), "created_at": .string("2026-09-01T01:00:00Z"), "content_updated_at": .string("2026-10-03T01:00:00Z")])
    #expect(DatasetViewer.meta(review) == ["10-03 更新"])
    #expect(DatasetViewer.saveLabel(.saving) == "正在保存…" && DatasetViewer.saveLabel(.idle) == nil && DatasetViewer.saveLabel(.conflict) == "已在别处修改，点此重新载入")
}

@Test func viewerZoomClockSpeedAndWave() {
    #expect(DatasetViewer.zoomIn(1) == 1.1 && DatasetViewer.zoomOut(1) == 0.9)
    #expect(DatasetViewer.zoomIn(4) == 4 && DatasetViewer.zoomOut(0.25) == 0.25)
    #expect(DatasetViewer.zoomIn(0.62) == 0.67 && DatasetViewer.zoomOut(0.62) == 0.5)
    #expect(abs(DatasetViewer.fitWidth(available: 692, widest: 596) - 1) < 0.001)
    #expect(DatasetViewer.fitImage(stage: CGSize(width: 1100, height: 730), image: CGSize(width: 1920, height: 1080), rotated: false) < 0.5)
    #expect(DatasetViewer.fitImage(stage: CGSize(width: 2000, height: 2000), image: CGSize(width: 100, height: 100), rotated: true) == 1)
    #expect(DatasetViewer.formatClock(2530) == "42:10" && DatasetViewer.formatClock(3725) == "1:02:05" && DatasetViewer.formatClock(.nan) == "00:00")
    #expect(DatasetViewer.nextSpeed(1) == 1.25 && DatasetViewer.nextSpeed(0.75) == 1)
    #expect(DatasetViewer.speedLabel(1) == "1.0×" && DatasetViewer.speedLabel(1.25) == "1.25×" && DatasetViewer.speedLabel(1.5) == "1.5×")
    let bars = DatasetViewer.waveform(seed: "9801", count: 120)
    #expect(bars.count == 120 && bars.allSatisfy { (6...26).contains($0) } && bars == DatasetViewer.waveform(seed: "9801", count: 120))
    #expect(bars != DatasetViewer.waveform(seed: "9802", count: 120))
}

@Test func viewerTranscriptAndOutline() {
    let turns = DatasetViewer.transcript("说话人 1：你好，先介绍一下。\n\n说话人 2: 好的。\n第二行\n\n\n没有说话人的一段\n\n这一段的冒号离开头太远了太远了太远了太远了：不算")
    #expect(turns.count == 4)
    #expect(turns[0] == .init(speaker: "说话人 1", text: "你好，先介绍一下。"))
    #expect(turns[1] == .init(speaker: "说话人 2", text: "好的。\n第二行"))
    #expect(turns[2].speaker == nil && turns[3].speaker == nil)
    let source = "# Redis 高频面试题\n\n## 1. 缓存击穿\n```\n## 不是标题\n```\n### 细节\n#### 太深\n## 2. 分布式锁 ##\n#没空格"
    let headings = DatasetViewer.headings(source)
    #expect(headings.map(\.text) == ["Redis 高频面试题", "1. 缓存击穿", "细节", "太深", "2. 分布式锁"])
    #expect(headings[1].line == 2)
    #expect(DatasetViewer.outline(headings).map(\.level) == [2, 3, 2])
    #expect(DatasetViewer.outline(DatasetViewer.headings("# 一\n### 三\n#### 四")).map(\.level) == [1, 3])
    #expect(DatasetViewer.normalizedText(Data("\u{FEFF}a\r\nb\rc".utf8)) == "a\nb\nc")
}

@Test func viewerTextSaveSplitsRevisionIntoIfMatch() {
    let body = DatasetViewer.textBody(text: "新的正文", revision: "3")
    let saved = DatasetViewer.textSave(path: "/api/datasets/42/text", body: body)
    #expect(saved?.0 == "\"dataset-42-3\"" && saved?.1 == .object(["text": .string("新的正文")]))
    #expect(DatasetViewer.textSave(path: "/api/datasets/42/text", body: DatasetViewer.textBody(text: "x", revision: "3\"x")) == nil)
    #expect(DatasetViewer.textSave(path: "/api/datasets/042/text", body: body) == nil)
    #expect(DatasetViewer.textSave(path: "/api/datasets/42/text", body: .object(["text": .string("x")])) == nil)
    #expect(CareerRequest.allowed(path: "/api/datasets/42/text", method: "PUT") && CareerRequest.allowed(path: "/api/datasets/42/transcribe", method: "POST"))
    #expect(!CareerRequest.allowed(path: "/api/datasets/42/text", method: "POST"))
}

@Test func viewerErrorsFollowWebLabels() {
    #expect(DatasetViewer.actionError(APIError.server(status: 404, code: "DATASET_NOT_FOUND"), fallback: "x") == "这份资料不存在或你无权操作。")
    #expect(DatasetViewer.actionError(APIError.server(status: 503, code: "HTTP_503"), fallback: "x") == "服务暂时不可用，请稍后重试。")
    #expect(DatasetViewer.actionError(APIError.server(status: 403, code: "CLIENT_NOT_ALLOWED"), fallback: "提交转写失败，请稍后重试。") == "提交转写失败，请稍后重试。")
    #expect(DatasetViewer.missing(APIError.server(status: 404, code: "NOT_FOUND")) && !DatasetViewer.missing(APIError.invalidResponse))
    let failed = record(["parse_status": .string("failed"), "failure_reason": .string("content_invalid")])
    #expect(DatasetViewer.transcriptionMessage(failed) == "未识别到有效语音，请检查音频后重试。")
    #expect(DatasetViewer.transcriptionMessage(record([:])) == "这份音频还没有文字稿，可开始转写。")
}

@Test func viewerReadsMarkdownLineByLine() {
    let lines = DatasetViewer.lines("# 标题\n整理自面经。\n\n- 击穿：**互斥锁**\n- [x] 已复习\n2. 第二条\n> 追问：怎么办？\n```lua\nSET lock\n```\n| | RDB | AOF |\n|---|---|---|\n| 恢复速度 | 快 | 慢 |\n---")
    #expect(lines == [
        .heading(level: 1, text: "标题", line: 0), .text("整理自面经。"), .blank,
        .item(marker: "•", text: "击穿：**互斥锁**", checked: nil, indent: 0), .item(marker: "•", text: "已复习", checked: true, indent: 0),
        .item(marker: "2.", text: "第二条", checked: nil, indent: 0), .quote("追问：怎么办？"), .code(language: "lua", text: "SET lock"),
        .table([["", "RDB", "AOF"], ["恢复速度", "快", "慢"]]), .rule,
    ])
}
