import AppKit
import Foundation
import DrawOfferCore
import SwiftUI
import UniformTypeIdentifiers

/// 导入真实面试（Figma 09N · 09.10a–e；Web `v2/ImportDialog.tsx`）：录音、文件或粘贴文字，挂到一场已结束的面试，
/// 或者在已有投递下补一轮（选轮次和日期，不推进投递）。那一场已经有记录时先确认替换，替换后按新记录重新生成复盘。
/// 建好记录后弹窗就关：文字和文档交给 `RecordImports` 在后台拆题、生成复盘；录音交给 `BackgroundUploads` 后台上传，传完等转写、转好自动复盘。
struct MockImportDialog: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    @Environment(BackgroundUploads.self) private var uploads: BackgroundUploads?
    @Environment(RecordImports.self) private var imports: RecordImports?
    var sessionID: String? = nil
    let close: () -> Void
    let done: () -> Void

    private static let media = ["mp3", "m4a", "wav", "webm", "ogg", "mp4", "mov", "aac"]
    private static let documents = ["pdf", "docx", "doc", "txt", "md"]

    @State private var targets: JSONValue?
    @State private var target: MockRecords.Target?
    @State private var round = "1"
    @State private var date = Date()
    @State private var paste = false
    @State private var file: URL?
    @State private var text = ""
    @State private var over = false
    @State private var busy = false
    @State private var failed: String?
    @State private var menu = false
    @State private var confirmReplace = false
    /// 失败后重试不再建一条新的面试记录
    @State private var created: (key: String, sessionID: String, applicationID: String)?

    private var nothing: Bool { targets.map { ($0["sessions"]?.items ?? []).isEmpty && ($0["applications"]?.items ?? []).isEmpty } ?? false }
    private var future: Bool { if case .application = target { return day > Self.day(Date()) }; return false }
    private var ready: Bool { target != nil && !future && (paste ? !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : file != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("导入真实面试").font(V3.serif(20)).foregroundStyle(MockPalette.ink).lineHeight(20, 29, .serif)
                Text("支持录音或文字稿，导入后会生成复盘并更新长期记忆。").font(V3.sans(14)).foregroundStyle(MockPalette.mute).lineHeight(14, 21)
            }
            MockSeg(label: "导入方式", options: [("file", "文件导入", false), ("paste", "粘贴文字", false)], current: paste ? "paste" : "file", pill: true) { paste = $0 == "paste" }
                .padding(.top, 20)
            if paste {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text).font(V3.sans(13)).foregroundStyle(MockPalette.sub).scrollContentBackground(.hidden).padding(.horizontal, 9).padding(.vertical, 8)
                        .accessibilityLabel("面试文字稿")
                    if text.isEmpty {
                        Text("面试官：介绍一下你做的项目。\n我：这个项目主要负责……").font(V3.sans(13)).foregroundStyle(MockPalette.mute).lineSpacing(4)
                            .padding(.horizontal, 14).padding(.vertical, 12).allowsHitTesting(false)
                    }
                }
                .frame(height: 140).background(MockPalette.field, in: RoundedRectangle(cornerRadius: 10)).padding(.top, 14)
            } else {
                Button(action: pick) {
                    VStack(spacing: 6) {
                        Text(verbatim: file?.lastPathComponent ?? "拖入录音或文字稿，或点击选择").font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.ink)
                            .lineLimit(1).truncationMode(.middle)
                        Text(verbatim: file == nil ? "mp3、m4a、wav、PDF、Word" : "点击换一个文件").font(V3.sans(12.5)).foregroundStyle(MockPalette.fnt)
                    }
                    .padding(.horizontal, 16).frame(maxWidth: .infinity).frame(height: 104)
                    .background(MockPalette.rowHover, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(over ? MockPalette.blue : MockPalette.faint, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).padding(.top, 14).accessibilityLabel("选择录音或文字稿")
                .onDrop(of: [.fileURL], isTargeted: $over) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url, Self.allowed(url) { DispatchQueue.main.async { file = url } }
                    }
                    return true
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                row("场次") {
                    if nothing {
                        Text("还没有可选的面试或岗位").font(V3.sans(14)).foregroundStyle(MockPalette.mute)
                        Spacer(minLength: 12)
                        Button("去添加岗位 ›") { close(); router?.jump(.section(.jobs)) }.buttonStyle(MockLinkStyle(blue: true, size: 14))
                    } else {
                        Text(verbatim: target?.label ?? (targets == nil ? "正在读取…" : "")).font(V3.sans(14, weight: .medium))
                            .foregroundStyle(MockPalette.ink).lineLimit(1).help(target?.label ?? "")
                        Spacer(minLength: 12)
                        Button("更换") { menu.toggle() }.buttonStyle(MockLinkStyle(blue: true, size: 14)).disabled(targets == nil || busy)
                    }
                }
                .zIndex(menu ? 2 : 0)
                .overlay(alignment: .topTrailing) { if menu, let targets { targetMenu(targets).offset(x: 8, y: 42) } }
                if case .application = target {
                    row("轮次") {
                        MockSeg(label: "轮次", options: [("1", "一面", false), ("2", "二面", false), ("3", "三面", false), ("hr", "HR 面", false)], current: round, pill: true) { round = $0 }
                    }
                    row("面试日期") {
                        DatePicker("面试日期", selection: $date, displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                            .environment(\.timeZone, Beijing.calendar.timeZone).disabled(busy)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.top, 14).zIndex(1)
            HStack(spacing: 12) {
                Group {
                    if let note = failed ?? (future ? "面试日期不能晚于今天" : nil) {
                        Text(verbatim: note).font(V3.sans(13)).foregroundStyle(MockPalette.orange).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("取消", action: close).buttonStyle(MockDialogButton(dark: false)).disabled(busy)
                Button(busy ? "正在导入…" : "开始导入") { Task { await run() } }.buttonStyle(MockDialogButton(dark: true)).disabled(!ready || busy)
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 24)
        .frame(width: 462, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.white).shadow(color: .black.opacity(0.08), radius: 14, y: 8)
                if menu { Color.white.opacity(0.001).onTapGesture { menu = false } }
            }
        }
        .background { Button("", action: { if menu { menu = false } else if !busy { close() } }).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
        .overlay {
            if confirmReplace, case .session(let picked) = target {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.06))
                    MockSessionConfirm(title: "替换这场的记录？", desc: "\(picked.text("title"))已经有面试记录，替换后会按新记录重新生成复盘。", confirm: "替换并重新复盘",
                                       onConfirm: { Task { await run(replace: true) } }, onCancel: { confirmReplace = false })
                        .background(.white, in: RoundedRectangle(cornerRadius: 14)).shadow(color: .black.opacity(0.12), radius: 20, y: 10)
                }
            }
        }
        .task { await loadTargets() }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: label).font(V3.sans(14)).foregroundStyle(MockPalette.mute).frame(width: 84, alignment: .leading)
            content()
        }.frame(minHeight: 36)
    }

    /// 选场次：已结束的面试（已有记录的标出来），再是「在已有岗位下新增一轮」，最后去投递看板添加岗位。
    private func targetMenu(_ targets: JSONValue) -> some View {
        let sessions = targets["sessions"]?.items ?? [], applications = targets["applications"]?.items ?? []
        return MockPopMenu(width: 380) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !sessions.isEmpty { group("已结束的面试") }
                    ForEach(sessions, id: \.self) { item in
                        MockPopRow(on: target == .session(item), title: item.text("title"),
                                   sub: "\(MockHome.mmdd(item.text("at"))) · \(item.text("job_title"))\(item["has_record"]?.bool == true ? " · 已有记录" : "")") { choose(.session(item)) }
                    }
                    if !applications.isEmpty {
                        if !sessions.isEmpty { Rectangle().fill(Color(hex: 0xF0EFEC)).frame(height: 1).padding(.vertical, 2) }
                        group("在已有岗位下新增一轮")
                    }
                    ForEach(applications, id: \.self) { item in
                        MockPopRow(on: target == .application(item), title: "\(item.text("company_name")) · \(item.text("job_title"))", sub: item.text("stage_hint").nonEmptyValue) { choose(.application(item)) }
                    }
                    Button { close(); router?.jump(.section(.jobs)) } label: {
                        Text("没有找到？去投递看板添加岗位 ›").font(V3.sans(14)).foregroundStyle(MockPalette.blue).padding(.horizontal, 15).padding(.top, 10).padding(.bottom, 8)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .frame(maxHeight: 320)
        }
    }
    private func group(_ title: String) -> some View {
        Text(verbatim: title).font(V3.sans(12)).foregroundStyle(MockPalette.mute).padding(.horizontal, 15).padding(.top, 8).padding(.bottom, 4)
    }

    private func choose(_ next: MockRecords.Target) {
        target = next
        if case .application(let application) = next { round = MockRecords.defaultRound(application) }
        menu = false
    }

    private func loadTargets() async {
        let value = (try? await request("/api/mock-interviews/import-targets")) ?? .object(["sessions": .array([]), "applications": .array([])])
        targets = value
        if let picked = MockRecords.defaultTarget(value, sessionID: sessionID) { choose(picked) }
    }

    private static func allowed(_ url: URL) -> Bool { (media + documents).contains(url.pathExtension.lowercased()) }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = (Self.media + Self.documents).compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { file = url; failed = nil }
    }

    private var day: String { Self.day(date) }
    private static func day(_ date: Date) -> String {
        let parts = Beijing.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func request(_ path: String, _ method: String = "GET", _ body: JSONValue? = nil) async throws -> JSONValue {
        try await session.api.careerRequest(path: path, method: method, query: [:], body: body)
    }

    private func run(replace: Bool = false) async {
        guard let target else { return }
        if case .session(let picked) = target, picked["has_record"]?.bool == true, !replace { confirmReplace = true; return }
        confirmReplace = false
        busy = true; failed = nil
        do {
            let body = MockRecords.importBody(target, replace: replace, round: round, day: day)
            let key = String(describing: body)
            if created?.key != key {
                let record = try await request("/api/mock-interviews/imports", "POST", body)
                created = (key, record.display("session_id"), record.display("application_id"))
            }
            guard let created else { return }
            let company: String = { if case .session(let picked) = target { return picked.text("title") }; if case .application(let item) = target { return item.text("company_name") }; return "" }()
            if !paste, let file, Self.media.contains(file.pathExtension.lowercased()), let uploads {
                // 录音交给后台分片上传（断网可续传），弹窗立刻关闭；传完转写、转好自动复盘，进度都在铃铛里（Web `startRecordingUpload` + `showImportProgress`）
                var hadRecord = false
                if case .session(let picked) = target { hadRecord = picked["has_record"]?.bool == true }
                try await uploads.start(session: created.sessionID, application: created.applicationID, file: file, transcribe: true,
                                        review: BackgroundUpload.Review(title: company, replace: hadRecord))
                close(); uploads.reveal(); return
            }
            // 文字和文档交给后台拆题、生成复盘，弹窗立刻关闭；进度和结果在铃铛里（Web `startRecordImport` + `showImportProgress`）
            guard let imports else { return }
            if !paste, let file {
                let sessionID = created.sessionID
                let snapshot = try await Task.detached { try DatasetUpload.snapshot(file, session: sessionID, limit: 512 * 1024 * 1024) }.value
                imports.start(session: created.sessionID, company: company, source: .file(snapshot))
            } else {
                imports.start(session: created.sessionID, company: company, source: .text(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            done(); uploads?.reveal()
        } catch {
            failed = MockInterviewText.error(error)
            busy = false
        }
    }
}
