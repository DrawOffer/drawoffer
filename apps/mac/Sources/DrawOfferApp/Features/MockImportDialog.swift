import AppKit
import Foundation
import DrawOfferCore
import SwiftUI
import UniformTypeIdentifiers

/// 导入面试记录（Figma 09 · 09.01 弹窗、09.02 粘贴文字；Web `v2/ImportDialog.tsx`）：只要文件或文字、公司和时间，不用先有投递。
/// 文字和文档当场拆题、生成复盘；录音先上传转写，转写好后在这场的面试资料里接着生成。
struct MockImportDialog: View {
    @Environment(SessionStore.self) private var session
    let close: () -> Void
    let done: () -> Void

    private static let media = ["mp3", "m4a", "wav", "webm", "ogg", "mp4", "mov", "aac"]
    private static let documents = ["pdf", "docx", "doc", "txt", "md"]

    @State private var paste = false
    @State private var file: URL?
    @State private var text = ""
    @State private var company = ""
    @State private var date = Date()
    @State private var over = false
    @State private var busy = false
    @State private var failed: String?
    /// 失败后重试不再建一条新的面试记录
    @State private var created: (key: String, sessionID: String, applicationID: String)?
    @State private var upload: DatasetUpload?

    private var ready: Bool { !company.trimmingCharacters(in: .whitespaces).isEmpty && (paste ? !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : file != nil) }

    var body: some View {
        MockFormCard(title: "导入面试记录", sub: "录音或文字稿都可以，导入后会记进你的长期记忆。", serif: true, close: { if !busy { close() } }) {
            if paste {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text).font(V3.sans(13.5)).scrollContentBackground(.hidden).padding(.horizontal, 9).padding(.vertical, 8)
                        .accessibilityLabel("面试文字稿")
                    if text.isEmpty { Text("把面试问答贴在这里").font(V3.sans(13.5)).foregroundStyle(MockPalette.mute).padding(.horizontal, 14).padding(.vertical, 12).allowsHitTesting(false) }
                }
                .frame(height: 160).background(MockPalette.field, in: RoundedRectangle(cornerRadius: 10)).padding(.top, 18)
                Button("‹ 改为上传文件") { paste = false }.buttonStyle(MockLinkStyle(blue: true)).padding(.top, 8)
            } else {
                Button(action: pick) {
                    VStack(spacing: 2) {
                        Text(verbatim: file?.lastPathComponent ?? "拖入录音或文字稿，或点击选择").font(V3.sans(14)).foregroundStyle(MockPalette.ink).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: file == nil ? "mp3、m4a、wav、PDF、Word" : "点击换一个文件").font(V3.sans(13)).foregroundStyle(MockPalette.fnt)
                    }
                    .padding(.horizontal, 16).frame(maxWidth: .infinity).frame(height: 112)
                    .background(MockPalette.rowHover, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(over ? MockPalette.blue : MockPalette.cl, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).padding(.top, 18).accessibilityLabel("选择录音或文字稿")
                .onDrop(of: [.fileURL], isTargeted: $over) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url, Self.allowed(url) { DispatchQueue.main.async { file = url; upload?.discard(); upload = nil } }
                    }
                    return true
                }
                Button("粘贴文字 ›") { paste = true }.buttonStyle(MockLinkStyle(blue: true)).padding(.top, 8)
            }
            HStack(alignment: .top, spacing: 12) {
                field("公司") {
                    TextField("比如云川科技", text: Binding(get: { company }, set: { company = String($0.prefix(100)) })).textFieldStyle(.plain).font(V3.sans(13.5))
                }
                field("时间") {
                    DatePicker("时间", selection: $date, in: ...Date(), displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                        .environment(\.timeZone, Beijing.calendar.timeZone)
                }
            }.padding(.top, 20)
        } left: {
            if let failed { Text(verbatim: failed).font(V3.sans(12.5)).foregroundStyle(MockPalette.orange).frame(maxWidth: 200, alignment: .leading).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            Button("取消", action: close).buttonStyle(MockPillStyle(kind: .ghost, height: 36, padding: 20)).disabled(busy)
            Button(busy ? "正在导入…" : "开始导入") { Task { await run() } }.buttonStyle(MockPillStyle(height: 36, padding: 20)).disabled(!ready || busy)
        }
        .onDisappear { upload?.discard() }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: label).font(V3.sans(13)).foregroundStyle(MockPalette.sub).frame(height: 20)
            content().padding(.horizontal, 12).frame(height: 40)
                .background(.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(MockPalette.cl))
        }.frame(width: 192)
    }

    private static func allowed(_ url: URL) -> Bool { (media + documents).contains(url.pathExtension.lowercased()) }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = (Self.media + Self.documents).compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { file = url; upload?.discard(); upload = nil; failed = nil }
    }

    private var day: String {
        let parts = Beijing.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func request(_ path: String, _ method: String = "GET", _ body: JSONValue? = nil) async throws -> JSONValue {
        try await session.api.careerRequest(path: path, method: method, query: [:], body: body)
    }

    private func run() async {
        busy = true; failed = nil
        do {
            let name = company.trimmingCharacters(in: .whitespaces)
            let key = "\(name)|\(day)"
            if created?.key != key {
                let record = try await request("/api/mock-interviews/imports", "POST", .object(["company_name": .string(name), "occurred_on": .string(day)]))
                created = (key, record.display("session_id"), record.display("application_id"))
            }
            guard let created else { return }
            var source: JSONValue = .object(["source": .string("text"), "text": .string(text.trimmingCharacters(in: .whitespacesAndNewlines))])
            if !paste, let file {
                if upload == nil { upload = try DatasetUpload.snapshot(file, session: created.sessionID, limit: 512 * 1024 * 1024) }
                guard let upload else { return }
                let result = try await session.api.uploadDataset(upload)
                upload.discard(); self.upload = nil
                if Self.media.contains(file.pathExtension.lowercased()) {
                    // 录音交给后台转写：转写好后在这场的面试资料里生成复盘
                    done(); return
                }
                let asset = result["asset"]?.display("id").nonEmptyValue ?? result.display("id")
                guard try await waitForParse(asset) else { throw ImportFailure.unreadable }
                source = .object(["source": .string("dataset"), "dataset_id": .string(asset)])
            }
            let draft = try await request("/api/interview-sessions/\(created.sessionID)/record:structure", "POST", source)
            let markdown = InterviewRecord.serialize(InterviewRecord.draft(draft))
            let before = try await request("/api/interview-sessions/\(created.sessionID)")
            _ = try await request("/api/interview-sessions/\(created.sessionID)", "PUT",
                                  .object(["questions_markdown": markdown.isEmpty ? .null : .string(markdown), "base_lock_version": before["session"]?["lock_version"] ?? .number(1)]))
            let saved = try await request("/api/interview-sessions/\(created.sessionID)")
            _ = try await request("/api/interview-sessions/\(created.sessionID)/review:generate", "POST",
                                  .object(["request_id": .string(UUID().uuidString.lowercased()), "base_lock_version": saved["session"]?["lock_version"] ?? .number(1)]))
            done()
        } catch ImportFailure.unreadable {
            failed = "这个文件读不出文字，换一份试试。"; busy = false
        } catch {
            if case APIError.server(let status, _) = error, (400..<500).contains(status), status != 409 { upload?.discard(); upload = nil }
            failed = { if case APIError.server(_, let code) = error, code == "INTERVIEW_QUESTIONS_NOT_FOUND" { return "没找到面试问题，换一份文字稿试试。" }; return "导入没有完成：" + MockInterviewText.error(error) }()
            busy = false
        }
    }

    private enum ImportFailure: Error { case unreadable }

    private func waitForParse(_ id: String) async throws -> Bool {
        for _ in 0..<30 {
            let dataset = try await request("/api/datasets/\(id)")
            let status = dataset["dataset"]?.text("parse_status").nonEmptyValue ?? dataset.text("parse_status")
            if status == "succeeded" { return true }
            if status == "failed" { return false }
            try await Task.sleep(for: .seconds(2))
        }
        return false
    }
}
