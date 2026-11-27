import AppKit
import AVKit
import DrawOfferCore
import PDFKit
import SwiftUI

/// 资料路径里的一节（「我的项目」「八股整理」…），点了回到那一层。
struct DatasetViewerCrumb: Identifiable {
    let id = UUID()
    let label: String
    let go: () -> Void
}

/// 08 · 资料预览独立页（macOS 稿 5:26 分区 216:1506，Web `DatasetViewerPage`）：一行 56 高页头，
/// 下面按文件类型原样显示——PDF / Word 分页（PDF 左侧页缩略图）、MD / TXT 白底正文可直接改并自动保存、
/// 图片适应窗口可缩放旋转、音频播放条 + 说话人文字稿、视频页内播放。底部浮一条白色胶囊工具条。
struct DatasetViewerPage: View {
    let datasetID: String
    let api: any APIClient
    /// 上层改名 / 移动 / 管理关联以后换一个值，页面重读这份资料。
    let reload: UUID
    let trail: (DatasetRecord) -> [DatasetViewerCrumb]
    let back: () -> Void
    let rename: (DatasetRecord) -> Void
    let move: (DatasetRecord) -> Void
    let associate: (DatasetRecord) -> Void
    let remove: (DatasetRecord) -> Void
    var practice: ((DatasetRecord) -> Void)? = nil

    private enum Load { case loading, ready(DatasetRecord), failed(String, missing: Bool) }
    @State private var state: Load = .loading
    @State private var attempt = UUID()

    var body: some View {
        Group {
            switch state {
            case .loading:
                DatasetViewerState { Text("正在打开资料…") }
            case .failed(let message, let missing):
                VStack(spacing: 0) {
                    HStack { DatasetViewerBack(back: back); Spacer() }.padding(.horizontal, 48).frame(height: 56)
                    DatasetViewerState {
                        Text(message).foregroundStyle(V3.red)
                        if !missing { Button("重新加载") { attempt = UUID() }.buttonStyle(V3ButtonStyle(kind: .ghost)) }
                    }
                }
            case .ready(let record):
                DatasetViewerLoaded(record: record, api: api, trail: trail(record), back: back,
                                    rename: rename, move: move, associate: associate, remove: remove, practice: practice,
                                    changed: { state = .ready($0) }, reloadAll: { attempt = UUID() })
                    .id(record.id)
            }
        }
        .background(.white)
        .task(id: "\(datasetID)|\(reload)|\(attempt)") { await load(showLoading: { if case .ready = state { return false }; return true }()) }
    }

    private func load(showLoading: Bool) async {
        if showLoading { state = .loading }
        do {
            let raw = try await api.careerRequest(path: "/api/datasets/" + datasetID, method: "GET", query: [:], body: nil)
            state = .ready(DatasetRecord(raw))
        } catch is CancellationError {
        } catch {
            let missing = DatasetViewer.missing(error)
            state = .failed(missing ? "这份资料不存在或你无权查看。" : "资料读取失败，请稍后重试。", missing: missing)
        }
    }
}

/// 读到资料以后的整页。
private struct DatasetViewerLoaded: View {
    let record: DatasetRecord
    let api: any APIClient
    let trail: [DatasetViewerCrumb]
    let back: () -> Void
    let rename: (DatasetRecord) -> Void
    let move: (DatasetRecord) -> Void
    let associate: (DatasetRecord) -> Void
    let remove: (DatasetRecord) -> Void
    let practice: ((DatasetRecord) -> Void)?
    let changed: (DatasetRecord) -> Void
    let reloadAll: () -> Void

    @State private var file: DatasetFile?
    /// 改成带扩展名的原文件路径（在 `file` 的私有目录里）。
    @State private var fileURL: URL?
    @State private var fileError = false
    @State private var fileKey = UUID()
    @State private var text: String?
    @State private var pdf: PDFDocument?
    @State private var pdfError = false
    @State private var image: NSImage?
    @State private var pages: Int?
    @State private var duration: Double?
    @State private var saveStatus: DatasetViewer.SaveStatus = .idle
    @State private var saveRetry = UUID()
    @State private var editorKey = UUID()
    @State private var notice: NoticeToastItem?
    @State private var downloading = false

    private var kind: DatasetViewer.Kind { DatasetViewer.kind(record) }
    private var sourceReady: Bool { DatasetViewer.sourceReady(record) }
    private var textMode: Bool { DatasetViewer.textMode(record) }
    private var source: (resume: String, entry: String)? { DatasetViewer.experienceSource(record) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .top) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if [.markdown, .text, .audio].contains(kind) { Rectangle().fill(DSV.rule).frame(height: 1).padding(.horizontal, 48) }
            }
        }
        .overlay(alignment: .top) { NoticeToast(item: $notice).padding(.top, 20) }
        .task(id: "\(record.id)|\(sourceReady)|\(fileKey)") { await loadSource() }
        .task(id: DatasetViewer.pending(record)) { await poll() }
        .onDisappear { file?.discard() }
    }

    // MARK: 页头

    private var header: some View {
        HStack(spacing: 24) {
            HStack(spacing: 4) {
                DatasetViewerBack(back: back)
                ForEach(trail) { crumb in
                    Text("/").foregroundStyle(DSV.faint).accessibilityHidden(true)
                    Button(crumb.label, action: crumb.go).buttonStyle(.plain).foregroundStyle(DSV.crumb).lineLimit(1)
                }
                Text("/").foregroundStyle(DSV.faint).padding(.horizontal, 8).accessibilityHidden(true)
                HStack(spacing: 8) {
                    Text(record.displayName).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.middle).help(record.name)
                    Text(DatasetViewer.formatLabel(record)).font(V3.number(11, weight: .semibold)).foregroundStyle(V3.fnt)
                        .padding(.horizontal, 7).frame(height: 17).background(Color(hex: 0xF1EFEA), in: RoundedRectangle(cornerRadius: 4)).fixedSize()
                }.layoutPriority(1)
            }
            .font(V3.sans(13)).foregroundStyle(DSV.crumb)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    meta
                    Color.clear.frame(width: 0)
                }
                if source != nil, let practice {
                    Button("练这段经历") { practice(record) }.buttonStyle(V3ButtonStyle(kind: .dark, height: 30))
                } else {
                    Button("下载") { Task { await download() } }.buttonStyle(DSVDownloadStyle()).disabled(!sourceReady || downloading)
                }
                Menu {
                    Button("重命名") { rename(record) }
                    if source != nil { Button("下载") { Task { await download() } } }
                    Button("移动到项目") { move(record) }
                    if sourceReady { Button("管理关联") { associate(record) } }
                    Divider()
                    Button("删除资料", role: .destructive) { remove(record) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(V3.fnt).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("「\(record.displayName)」更多操作")
            }.fixedSize()
        }
        .padding(.horizontal, 48).frame(height: 56)
    }

    /// 页头右侧灰字：大小 · 页数 · 尺寸 · 时长 · 上传日 · 已关联 · 保存状态（失败 / 冲突可点）。
    private var meta: some View {
        let items = DatasetViewer.meta(record, pages: pages, imageSize: image.map { $0.pixelSize }, duration: duration)
        return HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Text("·").padding(.horizontal, 5) }
                Text(item)
            }
            if textMode, let label = DatasetViewer.saveLabel(saveStatus) {
                Text("·").padding(.horizontal, 5)
                if saveStatus == .error || saveStatus == .conflict {
                    Button(label) {
                        if saveStatus == .conflict { saveStatus = .idle; editorKey = UUID(); fileKey = UUID(); reloadAll() } else { saveRetry = UUID() }
                    }.buttonStyle(.plain).foregroundStyle(V3.red)
                } else { Text(label) }
            }
        }
        .font(V3.sans(12)).foregroundStyle(DSV.faint).lineLimit(1).fixedSize()
    }

    // MARK: 正文

    @ViewBuilder private var content: some View {
        if !sourceReady {
            DatasetViewerState {
                Text(record.raw.text("upload_status") == "failed" ? "上传失败，请回到资料库重新上传。" : "正在上传…")
                    .foregroundStyle(record.raw.text("upload_status") == "failed" ? V3.red : DSV.state)
            }
        } else if fileError {
            DatasetViewerState {
                Text(textMode ? "资料内容读取失败，请稍后重试。" : "原文件读取失败，请稍后重试。").foregroundStyle(V3.red)
                Button("重新加载") { fileError = false; fileKey = UUID() }.buttonStyle(V3ButtonStyle(kind: .ghost))
            }
        } else {
            switch kind {
            case .markdown, .text:
                if let text {
                    DatasetTextBody(record: record, initial: text, markdown: kind == .markdown, editable: DatasetViewer.editable(record), api: api,
                                    status: $saveStatus, retry: saveRetry, saved: { next in changed(merged(next)) })
                        .id(editorKey)
                } else { DatasetViewerState { Text("正在读取…") } }
            case .audio:
                DatasetAudioBody(record: record, file: fileURL, api: api, duration: $duration, changed: { changed(merged($0)) },
                                 failed: { notice = .failed($0) })
            case .video:
                DatasetVideoBody(file: fileURL, duration: $duration, reload: { fileKey = UUID() })
            case .image:
                if let image { DatasetImageBody(image: image) } else { DatasetViewerState { Text("正在读取原文件…") } }
            case .pdf, .docx:
                if pdfError { DatasetViewerState { Text(kind == .pdf ? "PDF 读取失败，可下载原文件查看。" : "Word 读取失败，可下载原文件查看。").foregroundStyle(V3.red) } }
                else if let pdf { DatasetPagedBody(document: pdf, thumbnails: kind == .pdf) }
                else { DatasetViewerState { Text(file == nil ? "正在读取原文件…" : kind == .pdf ? "正在打开 PDF…" : "正在打开 Word…") } }
            case .other:
                DatasetViewerState { Text("这种格式暂不能在这里预览，可下载原文件查看。") }
            }
        }
    }

    /// 保存 / 转写返回的记录不带项目名，沿用当前的。
    private func merged(_ next: DatasetRecord) -> DatasetRecord {
        guard next.raw.text("folder_name").isEmpty, !record.raw.text("folder_name").isEmpty, case .object(var fields) = next.raw else { return next }
        fields["folder_name"] = record.raw["folder_name"]
        return DatasetRecord(.object(fields))
    }

    // MARK: 读原文件

    private func loadSource() async {
        guard sourceReady, kind != .other else { return }
        fileError = false; pdfError = false
        do {
            let next = try await api.downloadDataset(id: record.id, limit: 512 * 1024 * 1024)
            try Task.checkCancellation()
            // 播放器靠扩展名判断格式
            let named = next.url.deletingLastPathComponent().appendingPathComponent("source." + record.raw.text("file_format").lowercased())
            try? FileManager.default.moveItem(at: next.url, to: named)
            let opened = FileManager.default.fileExists(atPath: named.path) ? named : next.url
            file?.discard(); file = next; fileURL = opened
            switch kind {
            case .markdown, .text: text = DatasetViewer.normalizedText(try Data(contentsOf: opened))
            case .image:
                guard let loaded = NSImage(contentsOf: opened) else { fileError = true; return }
                image = loaded
            case .pdf:
                if let document = PDFDocument(url: opened) { pdf = document; pages = document.pageCount } else { pdfError = true }
            case .docx:
                if let document = DatasetDocx.paginate(opened) { pdf = document; pages = document.pageCount } else { pdfError = true }
            default: break
            }
        } catch is CancellationError {
        } catch { fileError = true }
    }

    /// 解析 / 转写进行中时每 3 秒重读一次，完成后自动换成结果。
    private func poll() async {
        while DatasetViewer.pending(record), !Task.isCancelled {
            try? await Task.sleep(for: .seconds(DatasetViewer.pollSeconds))
            guard !Task.isCancelled else { return }
            if let raw = try? await api.careerRequest(path: "/api/datasets/" + record.id, method: "GET", query: [:], body: nil) {
                let next = DatasetRecord(raw)
                changed(merged(next))
                if !DatasetViewer.pending(next) { return }
            }
        }
    }

    private func download() async {
        let panel = NSSavePanel(); panel.nameFieldStringValue = record.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        downloading = true; defer { downloading = false }
        do {
            var temporary: DatasetFile?
            let local: URL
            if let fileURL, kind != .markdown, kind != .text { local = fileURL } else {
                // MD / TXT 可能刚改过，重新取服务端的原文件
                let fresh = try await api.downloadDataset(id: record.id, limit: 512 * 1024 * 1024); temporary = fresh; local = fresh.url
            }
            defer { temporary?.discard() }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: local, to: destination)
            notice = .done("已保存「\(record.name)」")
        } catch { notice = .failed("下载失败，请稍后重试。") }
    }
}

// MARK: - 公用小件

/// 稿里这一页用到的几种灰。
enum DSV {
    static let faint = Color(hex: 0x9A9A93)
    static let crumb = Color(hex: 0x6C6C65)
    static let state = Color(hex: 0x6C6C65)
    static let rule = Color(hex: 0xE8E6E1)
    static let paged = Color(hex: 0xF2F1ED)
    static let stage = Color(hex: 0xEBEAE6)
    static let body = Color(hex: 0x3C3C38)
}

private struct DatasetViewerBack: View {
    let back: () -> Void
    var body: some View {
        Button(action: back) {
            HStack(spacing: 4) { Image(systemName: "arrow.left").font(.system(size: 11)); Text("资料库") }.contentShape(Rectangle())
        }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(DSV.crumb).accessibilityLabel("返回资料库")
    }
}

/// 居中的一行状态字（读取中 / 失败 + 重新加载）。
private struct DatasetViewerState<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 12) { content() }
            .font(V3.sans(12.5)).foregroundStyle(DSV.state).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
}

/// 「下载」：28 高白底胶囊、#DCDAD5 描边、13 中粗。
private struct DSVDownloadStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).padding(.horizontal, 14).frame(height: 28)
            .background(configuration.isPressed ? V3.field : .white, in: Capsule()).overlay(Capsule().stroke(Color(hex: 0xDCDAD5)))
            .opacity(enabled ? 1 : 0.5).contentShape(Capsule())
    }
}

/// 预览区底部居中的白色胶囊工具条（08.01 / 08.02 / 08.05）：‹ 1 / 4 › | − 100% + | 文字操作。
struct DatasetViewerToolbar: View {
    struct Page { let current: Int; let total: Int; let previous: () -> Void; let next: () -> Void }
    struct Action: Identifiable { var id: String { label }; let label: String; var active = false; let run: () -> Void }
    var page: Page? = nil
    let scale: Double
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    var actions: [Action] = []

    var body: some View {
        HStack(spacing: 14) {
            if let page {
                glyph("‹", "上一页", disabled: page.current <= 1, page.previous)
                Text("\(page.current) / \(page.total)").font(V3.number(12, weight: .medium)).foregroundStyle(V3.txt).frame(minWidth: 25)
                glyph("›", "下一页", disabled: page.current >= page.total, page.next)
                separator
            }
            glyph("−", "缩小", disabled: scale <= DatasetViewer.zoomSteps[0] + 0.001, zoomOut)
            Text("\(Int((scale * 100).rounded()))%").font(V3.number(12, weight: .medium)).foregroundStyle(V3.txt).frame(minWidth: 25)
            glyph("+", "放大", disabled: scale >= DatasetViewer.zoomSteps[DatasetViewer.zoomSteps.count - 1] - 0.001, zoomIn)
            if !actions.isEmpty { separator }
            ForEach(actions) { action in
                Button(action.label, action: action.run).buttonStyle(.plain).font(V3.sans(12))
                    .foregroundStyle(action.active ? V3.fnt : DSV.body).accessibilityAddTraits(action.active ? .isSelected : [])
            }
        }
        .padding(.horizontal, 17).frame(height: 38)
        .background(.white, in: Capsule()).overlay(Capsule().stroke(DSV.rule))
        .shadow(color: Color(hex: 0x1D1D1B).opacity(0.08), radius: 8, y: 4)
        .fixedSize()
        .accessibilityElement(children: .contain).accessibilityLabel("预览工具")
    }

    private var separator: some View { Rectangle().fill(DSV.rule).frame(width: 1, height: 14) }

    private func glyph(_ text: String, _ label: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(text).font(.system(size: 15)).foregroundStyle(V3.fnt).frame(minWidth: 10).contentShape(Rectangle()) }
            .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.35 : 1).accessibilityLabel(label)
    }
}

private extension NSImage {
    /// 位图的真实像素（`size` 是点数，Retina 截图会是一半）。
    var pixelSize: CGSize {
        if let rep = representations.first, rep.pixelsWide > 0 { return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        return size
    }
}

// MARK: - PDF / Word：灰底上原样分页

/// Word 原排版分页：系统读 .docx（字体、加粗、表格），按 A4 排成 PDF 再用同一个分页视图显示。
enum DatasetDocx {
    @MainActor static func paginate(_ url: URL) -> PDFDocument? {
        guard let text = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil) else { return nil }
        let paper = CGSize(width: 595, height: 842), margin: CGFloat = 64
        let storage = NSTextStorage(attributedString: text)
        // 系统导入把 <w:bidi w:val="0"/> 也当成从右到左，中文文档会整段右对齐、标点倒置
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle, style.baseWritingDirection == .rightToLeft else { return }
            let fixed = style.mutableCopy() as! NSMutableParagraphStyle
            fixed.baseWritingDirection = .leftToRight
            if fixed.alignment == .right { fixed.alignment = .left }
            storage.addAttribute(.paragraphStyle, value: fixed, range: range)
        }
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        // 一页一个文本容器，排到所有字形都放下为止
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: CGSize(width: paper.width - margin * 2, height: paper.height - margin * 2))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            layout.ensureLayout(for: container)
        } while NSMaxRange(layout.glyphRange(for: containers[containers.count - 1])) < layout.numberOfGlyphs && containers.count < 500
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for container in containers where layout.glyphRange(for: container).length > 0 {
            pdf.beginPDFPage(nil)
            pdf.translateBy(x: 0, y: paper.height); pdf.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: true)
            let glyphs = layout.glyphRange(for: container)
            layout.drawBackground(forGlyphRange: glyphs, at: CGPoint(x: margin, y: margin))
            layout.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: margin, y: margin))
            NSGraphicsContext.restoreGraphicsState()
            pdf.endPDFPage()
        }
        pdf.closePDF()
        guard let document = PDFDocument(data: data as Data), document.pageCount > 0 else { return nil }
        return document
    }
}

private struct DatasetPagedBody: View {
    let document: PDFDocument
    let thumbnails: Bool
    @State private var scale = 1.0
    @State private var current = 1
    @State private var command: DatasetPDFCanvas.Command?
    @State private var thumbs: [NSImage] = []

    var body: some View {
        HStack(spacing: 0) {
            if thumbnails {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(Array(thumbs.enumerated()), id: \.offset) { index, image in
                            let selected = current == index + 1
                            Button { command = .page(index + 1) } label: {
                                VStack(spacing: 8) {
                                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 72)
                                        .background(.white).clipShape(RoundedRectangle(cornerRadius: 2))
                                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(selected ? V3.txt : DSV.rule, lineWidth: selected ? 1.5 : 1))
                                    Text("\(index + 1)").font(V3.number(11, weight: .medium)).foregroundStyle(selected ? V3.txt : DSV.faint)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("第 \(index + 1) 页").accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }.padding(.top, 24).padding(.bottom, 96)
                }.frame(width: 72).padding(.leading, 28)
            }
            DatasetPDFCanvas(document: document, scale: $scale, current: $current, command: $command)
        }
        .background(DSV.paged)
        .overlay(alignment: .bottom) {
            DatasetViewerToolbar(page: .init(current: current, total: document.pageCount,
                                             previous: { command = .page(max(1, current - 1)) }, next: { command = .page(min(document.pageCount, current + 1)) }),
                                 scale: scale, zoomIn: { scale = DatasetViewer.zoomIn(scale) }, zoomOut: { scale = DatasetViewer.zoomOut(scale) },
                                 actions: [.init(label: "适合宽度") { command = .fit }])
                .padding(.bottom, 24)
        }
        .task(id: ObjectIdentifier(document)) {
            guard thumbnails else { return }
            thumbs = (0..<min(document.pageCount, 300)).compactMap { index in
                guard let page = document.page(at: index) else { return nil }
                let box = page.bounds(for: .cropBox)
                return page.thumbnail(of: NSSize(width: 144, height: 144 * box.height / max(1, box.width)), for: .cropBox)
            }
        }
    }
}

/// PDFKit 分页视图：连续单页、页间 24、左右 48；缩放和当前页与工具条双向同步，⌘ 捏合 / 滚轮缩放由 PDFView 自己处理。
private struct DatasetPDFCanvas: NSViewRepresentable {
    enum Command: Equatable { case page(Int), fit }
    let document: PDFDocument
    @Binding var scale: Double
    @Binding var current: Int
    @Binding var command: Command?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 12, left: 48, bottom: 12, right: 48)
        view.backgroundColor = NSColor(DSV.paged)
        view.minScaleFactor = DatasetViewer.zoomSteps[0]
        view.maxScaleFactor = DatasetViewer.zoomSteps[DatasetViewer.zoomSteps.count - 1]
        view.scaleFactor = 1
        context.coordinator.observe(view)
        // 页面比 100% 时的版心还宽就先适合宽度，避免横向滚动；排好版后停在第一页顶端
        DispatchQueue.main.async {
            context.coordinator.fitIfNarrow(view)
            view.layoutDocumentView()
            view.goToFirstPage(nil)
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if abs(view.scaleFactor - scale) > 0.001 { view.scaleFactor = scale }
        if let command {
            DispatchQueue.main.async {
                switch command {
                case .page(let number): if let page = document.page(at: number - 1) { view.go(to: page); current = number }
                case .fit: scale = context.coordinator.fitScale(view)
                }
                self.command = nil
            }
        }
    }

    final class Coordinator: NSObject {
        var parent: DatasetPDFCanvas
        private var fitted = false
        init(_ parent: DatasetPDFCanvas) { self.parent = parent }

        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)), name: .PDFViewPageChanged, object: view)
            NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged(_:)), name: .PDFViewScaleChanged, object: view)
        }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView, let page = view.currentPage, let document = view.document else { return }
            let number = document.index(for: page) + 1
            if parent.current != number { parent.current = number }
        }

        @objc func scaleChanged(_ note: Notification) {
            guard let view = note.object as? PDFView else { return }
            let value = Double(view.scaleFactor)
            if abs(parent.scale - value) > 0.001 { parent.scale = value }
        }

        func fitScale(_ view: PDFView) -> Double {
            let widest = (0..<(view.document?.pageCount ?? 0)).compactMap { view.document?.page(at: $0)?.bounds(for: .cropBox).width }.max() ?? 0
            return DatasetViewer.fitWidth(available: Double(view.bounds.width), widest: Double(widest))
        }

        func fitIfNarrow(_ view: PDFView) {
            guard !fitted, view.bounds.width > 0 else { return }
            fitted = true
            let widest = view.document?.page(at: 0)?.bounds(for: .cropBox).width ?? 0
            if view.bounds.width - 96 < widest { parent.scale = fitScale(view) }
        }
    }
}

// MARK: - 图片：浅灰舞台，适应窗口

private struct DatasetImageBody: View {
    let image: NSImage
    @State private var fit = true
    @State private var scale = 1.0
    @State private var rotation = 0

    var body: some View {
        GeometryReader { geometry in
            let natural = image.pixelSize
            let turned = rotation % 180 != 0
            let fitScale = DatasetViewer.fitImage(stage: geometry.size, image: natural, rotated: turned)
            let effective = fit ? fitScale : scale
            let box = CGSize(width: (turned ? natural.height : natural.width) * effective, height: (turned ? natural.width : natural.height) * effective)
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: natural.width * effective, height: natural.height * effective)
                    .rotationEffect(.degrees(Double(rotation)))
                    .frame(width: box.width, height: box.height)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .scrollIndicators(fit ? .hidden : .automatic)
            .overlay(alignment: .bottom) {
                DatasetViewerToolbar(scale: effective,
                                     zoomIn: { scale = DatasetViewer.zoomIn(effective); fit = false },
                                     zoomOut: { scale = DatasetViewer.zoomOut(effective); fit = false },
                                     actions: [.init(label: "适应窗口", active: fit) { fit = true },
                                               .init(label: "原始大小", active: !fit && abs(scale - 1) < 0.001) { scale = 1; fit = false },
                                               .init(label: "↻ 旋转") { rotation = (rotation + 90) % 360 }])
                    .padding(.bottom, 24)
            }
            .gesture(MagnifyGesture().onEnded { value in scale = DatasetViewer.clampZoom(effective * value.magnification); fit = false })
        }
        .background(DSV.stage)
    }
}

// MARK: - 视频：页内播放

// SwiftUI 的 VideoPlayer 依赖 _AVKit_SwiftUI，SwiftPM 产物里取不到类型元数据会直接崩溃，改用 AppKit 播放器
private struct DatasetPlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}

private struct DatasetVideoBody: View {
    let file: URL?
    @Binding var duration: Double?
    let reload: () -> Void
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let player {
                DatasetPlayerView(player: player).frame(maxWidth: 960).aspectRatio(16 / 9, contentMode: .fit)
                    .background(.black).clipShape(RoundedRectangle(cornerRadius: 10))
            } else if !failed {
                Text("正在读取视频…").font(V3.sans(12.5)).foregroundStyle(DSV.state)
            }
            if failed {
                HStack(spacing: 10) {
                    Text("视频读取失败，请重新加载；仍无法播放时可下载原文件使用系统播放器。")
                    Button("重新加载") { failed = false; reload() }.buttonStyle(.plain).foregroundStyle(V3.link)
                }.font(V3.sans(12.5)).foregroundStyle(V3.red).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(96).frame(maxWidth: .infinity, maxHeight: .infinity).background(DSV.stage)
        .task(id: file) {
            player?.pause(); player = nil
            guard let file else { return }
            let asset = AVURLAsset(url: file)
            do {
                let seconds = try await asset.load(.duration).seconds
                guard try await asset.load(.isPlayable) else { failed = true; return }
                if seconds.isFinite { duration = seconds }
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            } catch { failed = true }
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - 音频：播放条 + 说话人文字稿

@MainActor @Observable
private final class DatasetAudioPlayer {
    var player: AVPlayer?
    var time = 0.0
    var duration = 0.0
    var playing = false
    var speed = 1.0
    func open(_ url: URL) async throws {
        close()
        let asset = AVURLAsset(url: url)
        let seconds = try await asset.load(.duration).seconds
        guard try await asset.load(.isPlayable) else { throw APIError.invalidResponse }
        if seconds.isFinite { duration = seconds }
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }

    /// 页面每 0.25 秒读一次进度；播到头时停下。
    func tick() {
        guard let player else { return }
        let seconds = player.currentTime().seconds
        time = seconds.isFinite ? seconds : 0
        if playing, player.rate == 0, duration > 0, time >= duration - 0.25 { playing = false }
    }

    func toggle() {
        guard let player else { return }
        if playing { player.pause(); playing = false } else {
            if duration > 0, time >= duration - 0.1 { player.seek(to: .zero) }
            player.playImmediately(atRate: Float(speed)); playing = true
        }
    }

    func seek(_ fraction: Double) {
        guard let player, duration > 0 else { return }
        let target = max(0, min(1, fraction)) * duration
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func cycleSpeed() {
        speed = DatasetViewer.nextSpeed(speed)
        player?.defaultRate = Float(speed)
        if playing { player?.rate = Float(speed) }
    }

    func close() {
        player?.pause(); player = nil; playing = false; time = 0
    }
}

private struct DatasetAudioBody: View {
    let record: DatasetRecord
    let file: URL?
    let api: any APIClient
    @Binding var duration: Double?
    let changed: (DatasetRecord) -> Void
    let failed: (String) -> Void
    @State private var audio = DatasetAudioPlayer()
    @State private var audioError: String?
    @State private var turns: [DatasetViewer.Turn]?
    @State private var transcriptError = false
    @State private var transcriptKey = UUID()
    @State private var submitting = false

    private static let speakerColors = [V3.blue, V3.orange, V3.purple, V3.green]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                player
                if let audioError {
                    HStack(spacing: 10) {
                        Text(audioError)
                        Button("重新加载") { self.audioError = nil; Task { await open() } }.buttonStyle(.plain).foregroundStyle(V3.link)
                    }.font(V3.sans(12.5)).foregroundStyle(V3.red).padding(.top, 12)
                }
                transcript.padding(.top, 28)
            }
            .padding(.horizontal, 48).padding(.top, 28).padding(.bottom, 96)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: file) { await open() }
        .task { while !Task.isCancelled { audio.tick(); try? await Task.sleep(for: .milliseconds(250)) } }
        .task(id: "\(record.raw.text("content_revision"))|\(record.raw["has_transcript"]?.bool == true)|\(transcriptKey)") { await loadTranscript() }
        .onDisappear { audio.close() }
    }

    /// 72 高 #F4F3EF 圆角 14：44 黑色圆形播放键 → 波形（3 宽、间距 4，已播放墨黑）→ 时间 → 倍速白胶囊。
    private var player: some View {
        HStack(spacing: 16) {
            Button { audio.toggle() } label: {
                Image(systemName: audio.playing ? "pause.fill" : "play.fill").font(.system(size: 14)).foregroundStyle(.white)
                    .offset(x: audio.playing ? 0 : 1).frame(width: 44, height: 44).background(V3.txt, in: Circle()).contentShape(Circle())
            }.buttonStyle(.plain).disabled(audio.player == nil).accessibilityLabel(audio.playing ? "暂停" : "播放")
            GeometryReader { geometry in
                let count = max(20, Int(geometry.size.width / 7))
                let bars = DatasetViewer.waveform(seed: record.id, count: count)
                let total = audio.duration > 0 ? audio.duration : (duration ?? 0)
                let progress = total > 0 ? min(1, audio.time / total) : 0
                HStack(alignment: .center, spacing: 4) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { index, height in
                        RoundedRectangle(cornerRadius: 1.5).fill(Double(index) / Double(bars.count) < progress ? V3.txt : Color(hex: 0xCFCDC7))
                            .frame(width: 3, height: CGFloat(height))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading).clipped().contentShape(Rectangle())
                .onTapGesture { location in audio.seek(location.x / max(1, geometry.size.width)) }
            }
            .frame(height: 28)
            .accessibilityElement().accessibilityLabel("播放进度")
            .accessibilityValue("\(DatasetViewer.formatClock(audio.time)) / \(DatasetViewer.formatClock(audio.duration))")
            .accessibilityAdjustableAction { direction in
                guard audio.duration > 0 else { return }
                audio.seek((audio.time + (direction == .increment ? 5 : -5)) / audio.duration)
            }
            Text("\(DatasetViewer.formatClock(audio.time)) / \(DatasetViewer.formatClock(audio.duration > 0 ? audio.duration : (duration ?? 0)))")
                .font(V3.number(12, weight: .medium)).foregroundStyle(V3.fnt).fixedSize()
            Button(DatasetViewer.speedLabel(audio.speed)) { audio.cycleSpeed() }.buttonStyle(.plain)
                .font(V3.number(11, weight: .medium)).foregroundStyle(V3.sub).padding(.horizontal, 6).frame(minWidth: 38).frame(height: 19)
                .background(.white, in: Capsule()).accessibilityLabel("播放速度 \(DatasetViewer.speedLabel(audio.speed))")
        }
        .padding(.horizontal, 16).frame(height: 72)
        .background(Color(hex: 0xF4F3EF), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("文字稿").font(V3.sans(16, weight: .medium)).foregroundStyle(V3.txt)
                if record.raw["has_transcript"]?.bool == true, let day = DatasetViewer.fullDay(record.raw.text("content_updated_at")) {
                    Text("转写于 \(day)").font(V3.sans(12)).foregroundStyle(DSV.faint)
                }
            }.padding(.bottom, 19)
            if record.raw["has_transcript"]?.bool == true {
                if transcriptError {
                    HStack(spacing: 10) {
                        Text("文字稿读取失败，请稍后重试。")
                        Button("重新加载") { transcriptKey = UUID() }.buttonStyle(.plain).foregroundStyle(V3.link)
                    }.font(V3.sans(12.5)).foregroundStyle(V3.red)
                } else if let turns {
                    let order = speakers(turns)
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                            VStack(alignment: .leading, spacing: 4) {
                                if let speaker = turn.speaker {
                                    HStack(spacing: 6) {
                                        Circle().fill(Self.speakerColors[(order[speaker] ?? 0) % Self.speakerColors.count]).frame(width: 6, height: 6)
                                        Text(speaker)
                                    }.font(V3.sans(12)).foregroundStyle(V3.fnt)
                                }
                                Text(turn.text).font(V3.sans(14)).foregroundStyle(DSV.body).lineHeight(14, 25).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else {
                    Text("正在读取文字稿…").font(V3.sans(12.5)).foregroundStyle(V3.fnt)
                }
            } else {
                Text(DatasetViewer.transcriptionMessage(record)).font(V3.sans(12.5))
                    .foregroundStyle(record.raw.text("parse_status") == "failed" ? V3.red : V3.fnt)
                if !DatasetViewer.active(record) {
                    Button(submitting ? "正在提交…" : record.raw.text("parse_status") == "failed" ? "重新转写" : "开始转写") { Task { await transcribe() } }
                        .buttonStyle(V3ButtonStyle(kind: .dark)).disabled(submitting).padding(.top, 16)
                }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private func speakers(_ turns: [DatasetViewer.Turn]) -> [String: Int] {
        var order: [String: Int] = [:]
        for turn in turns { if let speaker = turn.speaker, order[speaker] == nil { order[speaker] = order.count } }
        return order
    }

    private func open() async {
        guard let file else { return }
        do {
            try await audio.open(file)
            if audio.duration > 0 { duration = audio.duration }
        } catch is CancellationError {
        } catch { audioError = "音频读取失败，请重新加载；仍无法播放时可下载原文件使用系统播放器。" }
    }

    private func loadTranscript() async {
        guard record.raw["has_transcript"]?.bool == true else { return }
        transcriptError = false
        do {
            let content = try await api.careerRequest(path: "/api/datasets/\(record.id)/content", method: "GET", query: [:], body: nil)
            turns = DatasetViewer.transcript(content.text("markdown"))
        } catch is CancellationError {
        } catch { transcriptError = true }
    }

    private func transcribe() async {
        submitting = true; defer { submitting = false }
        do {
            let raw = try await api.careerRequest(path: "/api/datasets/\(record.id)/transcribe", method: "POST", query: [:], body: nil)
            changed(DatasetRecord(raw))
        } catch {
            failed(DatasetViewer.actionError(error, fallback: "提交转写失败，请稍后重试。"))
        }
    }
}

// MARK: - MD / TXT：白底正文，直接改，停手 1 秒自动保存

private struct DatasetTextBody: View {
    let record: DatasetRecord
    let initial: String
    let markdown: Bool
    let editable: Bool
    let api: any APIClient
    @Binding var status: DatasetViewer.SaveStatus
    /// 换一个值就立刻重试保存（页头「保存失败，点此重试」）。
    let retry: UUID
    let saved: (DatasetRecord) -> Void

    @State private var text = ""
    @State private var savedText = ""
    @State private var revision = ""
    @State private var editing = false
    @State private var conflict = false
    @State private var inflight = false
    @State private var queued = false
    @State private var timer: Task<Void, Never>?
    @State private var activeHeading: Int?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    Group {
                        if editing || !markdown { editor } else { rendered }
                    }
                    .frame(maxWidth: markdown ? 720 : 760, alignment: .leading)
                    if markdown, !editing, !outline.isEmpty {
                        outlineView(proxy).padding(.leading, 112)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 48).padding(.top, 36).padding(.bottom, 96)
            }
            .coordinateSpace(name: "dsv-text")
            .onPreferenceChange(DatasetHeadingOffsets.self) { offsets in
                activeHeading = outline.last { (offsets[$0.line] ?? .infinity) <= 96 }?.line ?? outline.first?.line
            }
        }
        .onAppear { text = initial; savedText = initial; revision = record.raw.text("content_revision").nonEmptyValue ?? "0" }
        .onChange(of: text) { _, value in
            guard value != savedText, !conflict else { return }
            status = .dirty
            timer?.cancel()
            timer = Task { try? await Task.sleep(for: DatasetViewer.saveDelay); if !Task.isCancelled { await save() } }
        }
        .onChange(of: retry) { Task { await save() } }
        .onChange(of: focused) { _, value in if !value && markdown { editing = false } }
        .onDisappear {
            timer?.cancel()
            // 离开页面时还有没保存的改动：立刻提交一次
            if !conflict, !inflight, text != savedText {
                let api = api, id = record.id, body = DatasetViewer.textBody(text: text, revision: revision)
                Task.detached { _ = try? await api.careerRequest(path: "/api/datasets/\(id)/text", method: "PUT", query: [:], body: body) }
            }
        }
    }

    /// 源码编辑：MD 点进正文以后整篇露出源码（失焦回到阅读排版）；TXT 一直是原文。
    private var editor: some View {
        TextEditor(text: $text)
            .font(markdown ? .system(size: 14, design: .monospaced) : V3.sans(14))
            .foregroundStyle(DSV.body).lineSpacing(markdown ? 10 : 9)
            .scrollContentBackground(.hidden).scrollDisabled(true).scrollIndicators(.never)
            .disabled(!editable || conflict)
            .focused($focused)
            .frame(minHeight: 400, alignment: .topLeading)
            .accessibilityLabel("资料正文")
            .onKeyPress(.escape) { focused = false; return .handled }
            .overlay(alignment: .topLeading) {
                if text.isEmpty { Text("开始写点什么…").font(V3.sans(14)).foregroundStyle(DSV.faint).padding(.leading, 5).allowsHitTesting(false) }
            }
    }

    private var rendered: some View {
        DatasetMarkdownReader(lines: DatasetViewer.lines(text))
            .contentShape(Rectangle())
            .onTapGesture { guard editable, !conflict else { return }; editing = true; DispatchQueue.main.async { focused = true } }
            .accessibilityLabel("资料正文")
            .accessibilityHint(editable ? "点按开始编辑" : "")
    }

    private var outline: [DatasetViewer.Heading] { DatasetViewer.outline(DatasetViewer.headings(text)) }

    private func outlineView(_ proxy: ScrollViewProxy) -> some View {
        let nested = outline.contains { $0.level == 2 }
        return VStack(alignment: .leading, spacing: 12) {
            Text("目录").font(V3.sans(12)).foregroundStyle(DSV.faint).padding(.bottom, 2)
            ForEach(outline, id: \.line) { heading in
                let on = activeHeading == heading.line
                Button(heading.text) { withAnimation { proxy.scrollTo(heading.line, anchor: .top) } }
                    .buttonStyle(.plain).font(V3.sans(13, weight: on ? .medium : .regular)).foregroundStyle(on ? V3.txt : V3.fnt)
                    .lineLimit(1).padding(.leading, heading.level == 3 && nested ? 12 : 0)
            }
        }
        .frame(width: 145, alignment: .leading)
        .accessibilityElement(children: .contain).accessibilityLabel("目录")
    }

    private func save() async {
        timer?.cancel(); timer = nil
        guard !conflict, editable else { return }
        if inflight { queued = true; return }
        let current = text
        guard current != savedText else { return }
        inflight = true; status = .saving
        do {
            let raw = try await api.careerRequest(path: "/api/datasets/\(record.id)/text", method: "PUT", query: [:],
                                                  body: DatasetViewer.textBody(text: current, revision: revision))
            let next = DatasetRecord(raw)
            revision = next.raw.text("content_revision").nonEmptyValue ?? revision
            savedText = current
            saved(next)
            status = text == current ? .saved : .dirty
        } catch APIError.server(412, _) {
            conflict = true; editing = false; status = .conflict
        } catch {
            status = .error
        }
        inflight = false
        if queued { queued = false; await save() }
    }
}

/// 目录高亮：每个标题相对滚动区顶部的位置。
private struct DatasetHeadingOffsets: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// Markdown 阅读排版（08.03）：一级标题 24 衬线、二级 18、三级 16；正文 14 / 24 行高 #3C3C38；
/// 引用左侧 3 宽竖线、代码块 #F6F5F2 圆角 8、表格只画行间细线。
private struct DatasetMarkdownReader: View {
    let lines: [DatasetViewer.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line) }
        }
        .foregroundStyle(DSV.body)
        .textSelection(.enabled)
    }

    @ViewBuilder private func row(_ line: DatasetViewer.Line) -> some View {
        switch line {
        case .blank: Color.clear.frame(height: 12)
        case .heading(let level, let text, let index):
            Group {
                switch level {
                case 1: Text(inline(text)).font(V3.serif(24)).lineHeight(24, 34, .serif)
                case 2: Text(inline(text)).font(V3.sans(18)).lineHeight(18, 28)
                case 3: Text(inline(text)).font(V3.sans(16)).lineHeight(16, 26)
                default: Text(inline(text)).font(V3.sans(14, weight: .semibold)).lineHeight(14, 24)
                }
            }
            .foregroundStyle(V3.txt).fixedSize(horizontal: false, vertical: true)
            .id(index)
            .background(GeometryReader { box in Color.clear.preference(key: DatasetHeadingOffsets.self, value: [index: box.frame(in: .named("dsv-text")).minY]) })
        case .text(let text):
            Text(inline(text)).font(V3.sans(14)).lineHeight(14, 24).fixedSize(horizontal: false, vertical: true)
        case .item(let marker, let text, let checked, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square").font(.system(size: 12)).foregroundStyle(checked ? V3.txt : V3.fnt).padding(.trailing, 8)
                } else {
                    Text(marker).font(V3.sans(14)).foregroundStyle(V3.sub).frame(minWidth: 18, alignment: .leading)
                }
                Text(inline(text)).font(V3.sans(14)).lineHeight(14, 24).fixedSize(horizontal: false, vertical: true)
            }.padding(.leading, CGFloat(indent) * 18)
        case .quote(let text):
            Text(inline(text)).font(V3.sans(13)).foregroundStyle(V3.fnt).lineHeight(13, 22).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 14).padding(.vertical, 6)
                .overlay(alignment: .leading) { Rectangle().fill(DSV.rule).frame(width: 3) }
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(size: 13, design: .monospaced)).lineSpacing(5).fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: 0xF6F5F2), in: RoundedRectangle(cornerRadius: 8)).padding(.vertical, 6)
        case .table(let rows):
            let width = rows.map(\.count).max() ?? 0
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                    HStack(spacing: 0) {
                        ForEach(0..<width, id: \.self) { column in
                            Text(inline(column < cells.count ? cells[column] : "")).font(V3.sans(13, weight: index == 0 ? .medium : .regular))
                                .foregroundStyle(index == 0 ? V3.txt : DSV.body).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
                        }
                    }.overlay(alignment: .bottom) { Rectangle().fill(DSV.rule).frame(height: 1) }
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(DSV.rule).frame(height: 1) }
            .padding(.vertical, 6)
        case .rule:
            Rectangle().fill(DSV.rule).frame(height: 1).padding(.vertical, 16)
        }
    }

    /// 行内的加粗 / 斜体 / 行内代码 / 链接。
    private func inline(_ source: String) -> AttributedString {
        var text = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        for run in text.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                text[run.range].font = .system(size: 12.5, design: .monospaced)
                text[run.range].backgroundColor = V3.field
            }
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { text[run.range].foregroundColor = V3.txt }
            if run.link != nil { text[run.range].foregroundColor = V3.link }
        }
        return text
    }
}
