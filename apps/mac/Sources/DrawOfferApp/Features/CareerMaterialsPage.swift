import AppKit
import UniformTypeIdentifiers
import DrawOfferCore
import SwiftUI

/// 07.01 · 一条投递的全部资料：统一返回、衬线标题、一个黑按钮，按轮次分组排缩略图。
/// 每张只有文件名和大小；不写时间、不放投递详情入口，也不重复面试记录和复盘。点开就是预览，⋯ 里移动、移除。
/// 笔试轮保留「笔试题」入口，展开逐题查看（原资料页能力不丢）。
/// 07.02 · 拖进文件或点「上传资料」以后：底部浮出一块，逐个选放进哪一轮、怎么处理；这时黑色给「开始处理」，「上传资料」变白
/// （Figma 07 页 82:26647，业务同 Web `MaterialsPage` 的待处理浮层）。
struct CareerMaterialsPage: View {
    let application: JSONValue
    let deck: CareerDeck
    let details: [String: JSONValue]
    let initialSessionID: String?
    let api: any APIClient
    let back: () -> Void
    let addFromLibrary: (JSONValue) -> Void
    let openResume: () -> Void
    let openJob: () -> Void
    /// 资料移动或移除后让上层重新读取。
    let changed: () -> Void
    /// 资料库里的求职进程项目：左上回资料库，⋯ 里多一个「打开求职进度」。
    var fromLibrary = false
    var openProgress: (() -> Void)? = nil
    /// 从投递详情带过来的文件（「从电脑选」「上传录音」）：打开时直接进底部浮层。
    var intentFiles: [URL] = []
    /// 带着文件进来、全部处理完以后（回到投递详情）。
    var processed: (() -> Void)? = nil

    @State private var pending: [CareerPendingFile] = []
    @State private var processing = false
    @State private var dragOver = false
    @State private var intentSeen = false
    /// 文档读不出文字、没找到面试问题时，这份资料下面写原因。
    @State private var unreadable: [String: String] = [:]
    @State private var writtenOpen = Set<String>()
    @State private var removing: (asset: JSONValue, session: JSONValue)?
    @State private var busy = false
    @State private var notice: String?
    @State private var failure: String?

    private var rounds: [CareerStation] {
        deck.stations.reversed().filter { $0.kind == .apply || ($0.session.map { $0.text("status") != "cancelled" } ?? false) }
    }
    private var sessions: [(CareerStation, JSONValue)] { rounds.compactMap { station in station.session.map { (station, $0) } } }

    var body: some View {
        GeometryReader { geometry in
            let gutter = V3Page<EmptyView>.gutter(card: geometry.size.width)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        top
                        HStack(alignment: .center, spacing: 16) {
                            Text([application.text("company_name_snapshot"), application.text("job_title_snapshot")].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(V3.serif(36)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.tail).frame(height: 48)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            upload
                        }.padding(.top, 26)
                        if let message = failure ?? notice {
                            Text(message).font(V3.sans(12.5)).foregroundStyle(failure == nil ? V3.sub : V3.red).padding(.top, 10)
                        }
                        if rounds.isEmpty {
                            Text("这条投递还没有记录，记下投递后资料会按轮次放在这里。").font(V3.sans(13)).foregroundStyle(V3.fnt).padding(.top, 48)
                        }
                        VStack(alignment: .leading, spacing: 36) {
                            ForEach(rounds) { station in group(station).id(station.id) }
                        }.padding(.top, 48)
                    }
                    .padding(.horizontal, max(gutter, 40)).padding(.top, 40).padding(.bottom, 96)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    if let id = initialSessionID, let station = rounds.first(where: { $0.session?.text("id") == id }) {
                        // 从「笔试题」入口进来时直接展开题目
                        if station.kind == .written && intentFiles.isEmpty { writtenOpen.insert(id) }
                        proxy.scrollTo(station.id, anchor: .top)
                    }
                    if !intentSeen, !intentFiles.isEmpty { intentSeen = true; addFiles(intentFiles) }
                }
            }
        }
        .background(.white)
        .overlay {
            // 拖文件进来时整页描一圈虚线，松手后进底部浮层
            if dragOver { RoundedRectangle(cornerRadius: 14).stroke(PD.blue.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).padding(12).allowsHitTesting(false) }
        }
        .overlay(alignment: .bottom) {
            if !pending.isEmpty { tray.padding(.bottom, 40).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.easeOut(duration: 0.2), value: pending.isEmpty)
        .onDrop(of: [UTType.fileURL], isTargeted: $dragOver) { providers in
            CareerDrop.files(providers) { urls in addFiles(urls) }
            return true
        }
        .centeredConfirmation("把这份资料从这一轮移除？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移除", role: .destructive) { if let removing { Task { await remove(removing.asset, from: removing.session) } } }
            Button("取消", role: .cancel) { removing = nil }
        } message: {
            Text("文件仍保留在资料库里，只是不再挂在这一轮。")
        }
    }

    // MARK: 页头

    private var top: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                HStack(spacing: 4) { Image(systemName: "arrow.left").font(.system(size: 11)); Text(fromLibrary ? "资料库" : "求职进度") }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(fromLibrary ? "返回资料库" : "返回求职进度")
            if fromLibrary { Text("/").accessibilityHidden(true); Text("求职进程") }
            Spacer(minLength: 12)
            Menu {
                if let openProgress { Button("打开求职进度", action: openProgress) }
                if sessions.count == 1 { Button("从资料库选") { addFromLibrary(sessions[0].1) } }
                else if !sessions.isEmpty {
                    Menu("从资料库选") { ForEach(sessions, id: \.0.id) { item in Button(item.0.short) { addFromLibrary(item.1) } } }
                }
            } label: {
                Text("⋯").font(V3.sans(15)).foregroundStyle(V3.fnt).frame(width: 24, height: 20).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("更多操作")
            .disabled(openProgress == nil && sessions.isEmpty)
        }
        .font(V3.sans(13)).foregroundStyle(V3.fnt).frame(height: 20)
    }

    /// 「上传资料」：选好的文件先进底部浮层；浮层里有能处理的文件时「开始处理」是唯一的黑按钮，这里变白。
    private var upload: some View {
        Button("上传资料") { choose() }
            .buttonStyle(V3ButtonStyle(kind: readyCount > 0 ? .ghost : .dark, height: 36, width: 94))
            .disabled(defaultSessionID == nil || processing)
    }

    // MARK: 一轮

    @ViewBuilder private func group(_ station: CareerStation) -> some View {
        let session = station.session
        let detail = session.flatMap { details[$0.text("id")] }
        let assets = detail?["assets"]?.items ?? []
        let applyFiles = station.kind == .apply ? applyTiles : []
        let count = station.kind == .apply ? applyFiles.count : assets.count
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(station.short).font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt)
                Text("\(count)").font(V3.number(12.5, weight: .medium)).foregroundStyle(V3.fnt)
                if station.kind == .written, let session {
                    let questions = (detail?["session"] ?? session)["written_questions"]?.items.count ?? 0
                    if questions > 0 {
                        let key = session.text("id")
                        Button(writtenOpen.contains(key) ? "收起笔试题" : "笔试题 \(questions) 道 ›") {
                            if writtenOpen.contains(key) { writtenOpen.remove(key) } else { writtenOpen.insert(key) }
                        }.buttonStyle(.plain).font(V3.sans(12.5)).foregroundStyle(V3.link).padding(.leading, 8)
                    }
                }
            }
            if station.kind == .apply {
                if applyFiles.isEmpty { empty("投递时没有记录简历和岗位资料。") }
                else { tiles { ForEach(applyFiles, id: \.name) { file in Button(action: file.open) { tile(name: file.name, meta: file.meta, preview: CareerFilePreview(kind: .document, label: "")) }.buttonStyle(.plain) } } }
            } else if let session {
                if detail == nil { empty("正在读取这一轮的资料…") }
                else if assets.isEmpty { empty(station.kind == .written ? "还没有资料。把题目文档拖到这里，或点「上传资料」。" : "还没有资料。把录音、笔记拖到这里，或点「上传资料」。") }
                else { tiles { ForEach(assets, id: \.self) { asset in assetTile(asset, session: session, detail: detail ?? .null) } } }
                if station.kind == .written, writtenOpen.contains(session.text("id")), let detail { written(detail) }
            }
        }
    }

    private func empty(_ text: String) -> some View { Text(text).font(V3.sans(12.5)).foregroundStyle(V3.fnt) }

    private func tiles<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 188, maximum: 188), spacing: 24, alignment: .topLeading)], alignment: .leading, spacing: 20) { content() }
    }

    private var applyTiles: [(name: String, meta: String, open: () -> Void)] {
        var files: [(name: String, meta: String, open: () -> Void)] = []
        if !application.text("resume_id").isEmpty { files.append((application.text("resume_title_snapshot").nonEmptyValue ?? "投递简历", "投递简历", openResume)) }
        if !application.text("job_description_id").isEmpty { files.append(("岗位 JD", "岗位描述", openJob)) }
        return files
    }

    // MARK: 缩略图

    private func assetTile(_ asset: JSONValue, session: JSONValue, detail: JSONValue) -> some View {
        let name = asset.text("original_file_name").nonEmptyValue ?? "未命名文件"
        let type = asset.text("asset_type")
        let ext = name.contains(".") ? String(name.split(separator: ".").last ?? "").uppercased() : ""
        let media = type == "audio" || type == "video" || (type != "document" && !type.isEmpty)
        let image = ["PNG", "JPG", "JPEG", "WEBP", "GIF", "HEIC"].contains(ext)
        let ms = asset["duration_ms"]?.integer ?? 0
        let duration = ms > 0 ? String(format: "%02d:%02d", ms / 1000 / 60, ms / 1000 % 60) : ""
        let bytes = asset["file_size"]?.integer ?? 0
        let size = bytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) : ""
        let transcription = (detail["session"]?["transcriptions"]?.items ?? []).first { $0.text("dataset_id") == asset.text("id") }
        let status = !media ? unreadable[asset.text("id")] : ["queued", "running"].contains(transcription?.text("status") ?? "") ? "正在转文字" : transcription?.text("status") == "failed" ? "没能转成文字" : nil
        let preview = CareerFilePreview(kind: media ? .audio(asset.text("id")) : image ? .image : .document, label: media ? duration : ext)
        let others = sessions.filter { $0.1.text("id") != session.text("id") }
        return CareerMaterialTile(open: { open(asset) }, menu: {
            Button("打开") { open(asset) }
            if !others.isEmpty {
                Menu("移到其他轮") { ForEach(others, id: \.0.id) { item in Button(item.0.short) { Task { await move(asset, from: session, to: item.1) } } } }
            }
            Divider()
            Button("从这一轮移除") { removing = (asset, session) }
        }) {
            tile(name: name, meta: [size, status].compactMap { $0?.nonEmptyValue }.joined(separator: " · "), preview: preview)
        }.disabled(busy)
    }

    private func tile(name: String, meta: String, preview: CareerFilePreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            preview.frame(width: 188, height: 112).clipShape(RoundedRectangle(cornerRadius: 10))
            Text(name).font(V3.sans(13.5)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.middle).frame(height: 18).padding(.top, 10).help(name)
            Text(meta.isEmpty ? " " : meta).font(V3.sans(12)).foregroundStyle(V3.fnt).lineLimit(1).frame(height: 14)
        }.frame(width: 188, alignment: .leading).contentShape(Rectangle())
    }

    // MARK: 笔试题

    private func written(_ detail: JSONValue) -> some View {
        let questions = detail["session"]?["written_questions"]?.items ?? []
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, item in
                let mark = ["correct": "答对", "wrong": "答错", "unsure": "不确定"][item.text("correctness")] ?? "先不标"
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.display("question_no")). \(item.text("question_text"))").font(V3.sans(13.5, weight: .medium)).foregroundStyle(V3.txt).fixedSize(horizontal: false, vertical: true)
                    Text("我的答案：" + (item.text("answer").nonEmptyValue ?? "没记答案。") + " · " + mark).font(V3.sans(12.5)).foregroundStyle(V3.sub)
                }
                .padding(.vertical, 10).frame(maxWidth: 640, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(V3.line).frame(height: 1) }
            }
        }.padding(.top, 4)
    }

    // MARK: 07.02 底部浮层：放进哪一轮、怎么处理

    private var readyCount: Int { pending.filter { $0.error == nil }.count }
    private var targets: [(id: String, label: String)] {
        sessions.filter { details[$0.1.text("id")] != nil }.map { ($0.1.text("id"), $0.0.short) }
    }
    /// 默认放进哪一轮：带过来的那一轮，否则当前这一轮，否则最近的一轮。
    private var defaultSessionID: String? {
        if let id = initialSessionID, details[id] != nil { return id }
        return sessions.first { $0.0.current && details[$0.1.text("id")] != nil }?.1.text("id") ?? targets.first?.id
    }
    private func hasRecord(_ sessionID: String) -> Bool { !InterviewRecord.parse(details[sessionID]?["session"]?.text("questions_markdown")).isEmpty }
    private func isWritten(_ sessionID: String) -> Bool { rounds.first { $0.session?.text("id") == sessionID }?.kind == .written }

    /// 默认怎么处理（Web `suggest`）：面试记录只在第一次生成；笔试轮的文档先提取笔试题。
    private func suggest(_ media: Bool, into sessionID: String) -> CareerUploadChoice {
        if media { return hasRecord(sessionID) || isWritten(sessionID) ? .save : .record }
        if isWritten(sessionID) { return (details[sessionID]?["session"]?["written_questions"]?.items ?? []).isEmpty ? .written : .save }
        return hasRecord(sessionID) ? .save : .record
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = (CareerPendingFile.media + CareerPendingFile.documents).compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    private func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let target = defaultSessionID else { failure = "这条投递还没有安排过面试或笔试，资料要放进某一轮。"; return }
        failure = nil
        pending += urls.map { url in
            let file = CareerPendingFile(url: url, sessionID: target)
            var item = file
            item.choice = suggest(file.media, into: target)
            return item
        }
    }

    private var tray: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(readyCount > 0 ? "\(readyCount) 个文件，放进哪一轮？" : "\(pending.count) 个文件没传上去").font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt)
                .frame(height: 18).padding(.bottom, 10)
            VStack(spacing: 0) {
                ForEach(pending) { item in trayRow(item).overlay(alignment: .top) { Rectangle().fill(V3.cl).frame(height: 1) } }
            }
            Text("一轮只整理一次面试记录，之后再传的文件只保存。").font(V3.sans(12)).foregroundStyle(PD.mute)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            HStack(spacing: 20) {
                Spacer()
                CareerJourneyTextButton(title: "取消", color: PD.body) { pending = [] }.disabled(processing)
                if readyCount > 0 {
                    Button(processing ? "正在处理…" : "开始处理") { Task { await process() } }
                        .buttonStyle(V3ButtonStyle(kind: .dark, height: 32, width: 94)).disabled(processing).keyboardShortcut(.defaultAction)
                }
            }.padding(.top, 14)
        }
        .padding(.horizontal, 24).padding(.top, 21).padding(.bottom, 21)
        .frame(width: 660)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.10), radius: 24, y: 10)
        .accessibilityElement(children: .contain).accessibilityLabel("待处理的文件")
    }

    private func trayRow(_ item: CareerPendingFile) -> some View {
        let options: [(CareerUploadChoice, String)] = item.media
            ? [(.record, "整理成面试记录"), (.save, "只保存")]
            : [(.record, "整理成面试记录"), (.written, "提取笔试题"), (.save, "只保存")]
        let recorded = hasRecord(item.sessionID)
        return HStack(spacing: 12) {
            Image(systemName: item.media ? "mic" : "doc.text").font(.system(size: 13)).foregroundStyle(PD.body)
                .frame(width: 30, height: 30).background(Color(hex: 0xF2F2EE), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(V3.sans(14)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.middle).help(item.name)
                Text(item.error ?? item.sizeLabel).font(V3.sans(11.5)).foregroundStyle(item.error == nil ? PD.mute : PD.red).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.error == nil {
                CareerTrayPicker(label: targets.first { $0.id == item.sessionID }?.label ?? "选择", width: 76) {
                    ForEach(targets, id: \.id) { entry in
                        Button(entry.label) { update(item.id) { $0.sessionID = entry.id; $0.choice = suggest($0.media, into: entry.id) } }
                    }
                }.accessibilityLabel("放进哪一轮")
                CareerTrayPicker(label: options.first { $0.0 == item.choice }?.1 ?? "只保存", width: 132) {
                    ForEach(options, id: \.0) { option in
                        Button(option.1) { update(item.id) { $0.choice = option.0 } }.disabled(option.0 == .record && recorded)
                    }
                }.accessibilityLabel(item.media ? "这段录音要怎么处理" : "这份文档要怎么处理")
            }
            Button { pending.removeAll { $0.id == item.id } } label: {
                Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(PD.mute).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(processing).accessibilityLabel("移除 \(item.name)")
        }
        .frame(height: 58)
        .disabled(processing)
    }

    private func update(_ id: UUID, _ change: (inout CareerPendingFile) -> Void) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        change(&pending[index])
    }

    /// 开始处理（Web `process`）：逐个传进那一轮；录音按选择决定转不转文字；
    /// 文档要整理成面试记录或提取笔试题时，等解析完再交给 AI，读不出来就只当资料保存。
    private func process() async {
        guard !processing else { return }
        processing = true; failure = nil; notice = nil
        var left = pending.filter { $0.error != nil }
        for item in pending where item.error == nil {
            do {
                var upload = try DatasetUpload.snapshot(item.url, session: item.sessionID, limit: Int64(item.media ? CareerPendingFile.maxMediaBytes : CareerPendingFile.maxDocumentBytes))
                upload.transcribe = item.media && item.choice == .record
                defer { upload.discard() }
                let response = try await api.uploadDataset(upload)
                let assetID = response["asset"]?.text("id") ?? response.text("id")
                guard !item.media, item.choice != .save, !assetID.isEmpty else { continue }
                guard await waitForParse(assetID) else { unreadable[assetID] = "读不出文字，已保存为资料"; continue }
                if item.choice == .record {
                    do {
                        let draft = try await api.careerRequest(path: "/api/interview-sessions/\(item.sessionID)/record:structure", method: "POST", query: [:],
                                                                body: .object(["source": .string("dataset"), "dataset_id": .string(assetID)]))
                        let fresh = try await api.careerRequest(path: "/api/interview-sessions/\(item.sessionID)", method: "GET", query: [:], body: nil)
                        let markdown = InterviewRecord.serialize(InterviewRecord.draft(draft))
                        _ = try await api.careerRequest(path: "/api/interview-sessions/\(item.sessionID)", method: "PUT", query: [:],
                                                        body: .object(["questions_markdown": markdown.isEmpty ? .null : .string(markdown), "base_lock_version": fresh["session"]?["lock_version"] ?? .number(1)]))
                    } catch APIError.server(_, "INTERVIEW_QUESTIONS_NOT_FOUND") {
                        unreadable[assetID] = "没找到面试问题，已保存为资料"
                    } catch { unreadable[assetID] = "没能整理成面试记录，已保存为资料"; notice = CareerErrors.message(error) }
                } else {
                    do {
                        let extracted = try await api.careerRequest(path: "/api/interview-sessions/\(item.sessionID)/written-questions:extract", method: "POST", query: [:],
                                                                    body: .object(["source": .string("dataset"), "dataset_id": .string(assetID)]))
                        let fresh = try await api.careerRequest(path: "/api/interview-sessions/\(item.sessionID)", method: "GET", query: [:], body: nil)
                        let lock = fresh["session"]?["lock_version"] ?? .number(1)
                        let questions: [JSONValue] = (extracted["questions"]?.items ?? []).map { entry in
                            .object(["text": .string(entry.text("text")), "answer": entry.text("answer").isEmpty ? .null : .string(entry.text("answer")),
                                     "result": entry.text("result").isEmpty ? .null : .string(entry.text("result"))])
                        }
                        do {
                            _ = try await api.careerRequest(path: "/api/interview-sessions/\(item.sessionID)/written-questions", method: "PUT", query: [:],
                                                            body: .object(["questions": .array(questions), "base_lock_version": lock]))
                        } catch APIError.server(403, _) {
                            // 服务端还没对桌面开放逐题保存时，只保存题目文字
                            _ = try await api.careerRequest(path: "/api/interview-sessions/\(item.sessionID)", method: "PUT", query: [:],
                                                            body: .object(["questions_markdown": extracted["markdown"] ?? .null, "base_lock_version": lock]))
                        }
                    } catch { unreadable[assetID] = "没能提取笔试题，已保存为资料"; notice = CareerErrors.message(error) }
                }
            } catch {
                var failed = item
                failed.error = CareerErrors.message(error)
                left.append(failed)
            }
        }
        pending = left
        processing = false
        changed()
        if left.isEmpty { processed?() }
    }

    /// 文档解析是异步的：最多等 60 秒。
    private func waitForParse(_ id: String) async -> Bool {
        for _ in 0..<30 {
            if let dataset = try? await api.careerRequest(path: "/api/datasets/\(id)", method: "GET", query: [:], body: nil) {
                if dataset.text("parse_status") == "succeeded" { return true }
                if dataset.text("parse_status") == "failed" { return false }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    // MARK: 行为

    private func open(_ asset: JSONValue) {
        Task {
            do {
                failure = nil
                let file = try await api.downloadDataset(id: asset.text("id"), limit: 512 * 1024 * 1024)
                let name = asset.text("original_file_name")
                let named = name.isEmpty ? file.url : file.url.deletingLastPathComponent().appendingPathComponent(name)
                if named != file.url { try? FileManager.default.moveItem(at: file.url, to: named) }
                NSWorkspace.shared.open(FileManager.default.fileExists(atPath: named.path) ? named : file.url)
            } catch { failure = CareerErrors.message(error) }
        }
    }

    /// 移动：先解除旧关联再挂到新一轮（与资料库「调整关联」相同顺序）；只当资料保存，不重新转写。
    private func move(_ asset: JSONValue, from: JSONValue, to: JSONValue) async {
        guard !busy else { return }
        busy = true; failure = nil; notice = nil
        defer { busy = false }
        let id = asset.text("id")
        do {
            _ = try await api.careerRequest(path: "/api/interview-sessions/\(from.text("id"))/assets/\(id)", method: "DELETE", query: [:], body: nil)
        } catch { failure = CareerErrors.message(error); return }
        do {
            _ = try await api.careerRequest(path: "/api/interview-sessions/\(to.text("id"))/assets/attach", method: "POST", query: [:],
                                            body: .object(["dataset_id": .string(id), "transcribe": .bool(false)]))
            notice = "已移到\(rounds.first { $0.session?.text("id") == to.text("id") }?.short ?? "其他轮")。"
        } catch {
            // 挂到新一轮失败时放回原来那一轮，文件本身一直在资料库里。
            _ = try? await api.careerRequest(path: "/api/interview-sessions/\(from.text("id"))/assets/attach", method: "POST", query: [:],
                                             body: .object(["dataset_id": .string(id), "transcribe": .bool(false)]))
            failure = "没能移过去：" + CareerErrors.message(error)
        }
        changed()
    }

    private func remove(_ asset: JSONValue, from session: JSONValue) async {
        removing = nil
        guard !busy else { return }
        busy = true; failure = nil; notice = nil
        defer { busy = false }
        do {
            _ = try await api.careerRequest(path: "/api/interview-sessions/\(session.text("id"))/assets/\(asset.text("id"))", method: "DELETE", query: [:], body: nil)
            notice = "已从这一轮移除，文件仍在资料库里。"
            changed()
        } catch { failure = CareerErrors.message(error) }
    }
}

/// 资料缩略图（07.01 188×112）：录音是灰色波形 + 右下时长，文档是一页白纸，截图是带标题条的页面；左下角写扩展名。
struct CareerFilePreview: View {
    enum Kind { case audio(String), document, image }
    let kind: Kind
    let label: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(hex: 0xF4F4F1)
            switch kind {
            case .audio:
                wave.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !label.isEmpty {
                    Text(label).font(V3.number(11, weight: .medium)).foregroundStyle(Color(hex: 0x6C6C65))
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 8).padding(.bottom, 10)
                }
            case .document:
                // 96×124 的白纸，左右居中、顶端离缩略图 18，下半截被裁掉；标题条 52×5，下面 3 高的灰行每 8 一行。
                page(width: 96, top: 18) {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: 0x1D1D1B).opacity(0.45)).frame(width: 52, height: 5).offset(x: 12, y: 12)
                        ForEach(0..<9, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: 0xDEDED9)).frame(width: index % 4 == 3 ? 40 : 72, height: 3).offset(x: 12, y: CGFloat(24 + index * 8))
                        }
                    }
                }
                ext
            case .image:
                // 132×92 的页面截图：14 高标题条 + 三行文字 + 两个 40×16 的按钮。
                page(width: 132, top: 20) {
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color(hex: 0xDEDED9)).frame(width: 132, height: 14)
                        ForEach(Array([70, 100, 88].enumerated()), id: \.offset) { index, w in
                            RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: 0xDEDED9)).frame(width: CGFloat(w), height: 4).offset(x: 10, y: CGFloat(24 + index * 10))
                        }
                        ForEach(0..<2, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0xE4E4E0)).frame(width: 40, height: 16).offset(x: CGFloat(10 + index * 46), y: 58)
                        }
                    }
                }
                ext
            }
        }
        .accessibilityHidden(true)
    }

    private var ext: some View {
        Text(label).font(V3.sans(10, weight: .medium)).foregroundStyle(V3.fnt).padding(.leading, 12).padding(.bottom, 10)
    }

    private func page<Content: View>(width: CGFloat, top: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        content().frame(width: width, height: 112 - top, alignment: .topLeading).background(.white, in: RoundedRectangle(cornerRadius: width > 100 ? 4 : 3))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Figma 07.01 的波形：25 根 3 宽、间距 3.2、半透明墨色的圆角条，高度固定（装饰，不代表真实音量）。
    private var wave: some View {
        let heights: [CGFloat] = [10, 18, 30, 22, 40, 26, 14, 34, 46, 30, 20, 38, 28, 16, 24, 36, 22, 12, 28, 18, 10, 20, 32, 24, 14]
        return HStack(spacing: 3.2) { ForEach(Array(heights.enumerated()), id: \.offset) { RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: 0x1D1D1B).opacity(0.28)).frame(width: 3, height: $0.element) } }
    }
}

/// 一张可点开的资料：悬停只在右上角露出 ⋯（不加灰底），菜单里打开、移动、移除。
private struct CareerMaterialTile<MenuContent: View, TileLabel: View>: View {
    let open: () -> Void
    @ViewBuilder let menu: () -> MenuContent
    @ViewBuilder let label: () -> TileLabel
    @State private var hover = false

    var body: some View {
        Button(action: open) { label() }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                SwiftUI.Menu { menu() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(V3.sub)
                        .frame(width: 26, height: 22).background(.white, in: Capsule()).contentShape(Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .padding(8).opacity(hover ? 1 : 0).accessibilityLabel("资料操作")
            }
            .onHover { hover = $0 }
            .contextMenu { menu() }
    }
}

/// 07.02 浮层里一份文件怎么处理。
enum CareerUploadChoice: Hashable { case record, save, written }

/// 07.02 浮层里待处理的一份文件；格式或大小本地就不对时带 `error`，不会上传。
struct CareerPendingFile: Identifiable {
    /// Web `DEFAULT_DATASET_LIMITS`：录音视频 500MB，文档 10MB。
    static let media = ["webm", "m4a", "mp3", "wav", "ogg", "mp4", "mov"]
    static let documents = ["pdf", "docx", "md", "txt"]
    static let maxMediaBytes = 500 * 1024 * 1024
    static let maxDocumentBytes = 10 * 1024 * 1024

    let id = UUID()
    let url: URL
    let name: String
    let size: Int
    let media: Bool
    var sessionID: String
    var choice: CareerUploadChoice = .save
    var error: String?

    init(url: URL, sessionID: String) {
        self.url = url
        self.sessionID = sessionID
        name = url.lastPathComponent
        size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let ext = url.pathExtension.lowercased()
        media = Self.media.contains(ext)
        let limit = media ? Self.maxMediaBytes : Self.maxDocumentBytes
        if !media && !Self.documents.contains(ext) {
            error = "没传上去：不支持 \(ext.isEmpty ? "这种" : "." + ext) 格式 · 导出成 PDF 再传；支持录音、视频、PDF、DOCX、Markdown、TXT"
        } else if size <= 0 {
            error = "没传上去：读不到这个文件"
        } else if size > limit {
            error = "没传上去：超过 \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))"
                + (media ? " · 可以只导出音频（m4a / mp3）再传，转文字只需要声音" : " · 导出成 PDF 再传")
        }
    }

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}

/// 07.02 浮层里的小下拉：浅灰底、圆角 6、右侧小箭头（不加悬停底色）。
private struct CareerTrayPicker<Items: View>: View {
    let label: String
    let width: CGFloat
    @ViewBuilder let items: () -> Items
    var body: some View {
        Menu { items() } label: {
            HStack(spacing: 6) {
                Text(label).font(V3.sans(13)).foregroundStyle(V3.txt).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium)).foregroundStyle(PD.mute)
            }
            .padding(.horizontal, 10).frame(width: width, height: 28)
            .background(Color(hex: 0xF2F2EE), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}
