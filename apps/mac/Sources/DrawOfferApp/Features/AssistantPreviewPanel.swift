import AppKit
import DrawOfferCore
import DrawOfferRender
import SwiftUI

/// 对话右侧文件预览（Web `features/assistant/PreviewPanel.tsx`）：简历纸面、资料库文本、AI 生成文档与本地截图，最多 6 个标签。
/// 简历标签把待确认修改的原文所在段落标黄（与 Web `HighlightedContent` 同样按段落/列表项文字匹配）。
struct ChatPreviewTab: Equatable {
    enum Kind: String { case resume, dataset, generated, image }
    let kind: Kind
    let id: String
    var label: String
    var content = ""
    var pending: [String] = []
    var saved = false
    /// 截图标签的 PNG 数据，只在本机内存中。
    var imageData: Data?
    var key: String { kind.rawValue + ":" + id }

    static let maximum = 6

    /// 同一文件只保留一个标签，内容有变化时就地更新；超出上限时丢掉最早打开的。
    static func open(_ tabs: [ChatPreviewTab], _ tab: ChatPreviewTab) -> [ChatPreviewTab] {
        if let index = tabs.firstIndex(where: { $0.key == tab.key }) {
            var next = tabs; next[index] = tab; return next
        }
        return Array((tabs + [tab]).suffix(maximum))
    }

    /// 消息上下文（`resume` / `resume_version` / `dataset`）对应的标签；其他类型不可预览。
    static func forContext(_ context: JSONValue) -> ChatPreviewTab? {
        switch context.text("type") {
        case "resume", "resume_version":
            let id = context.text("resume_id").nilIfEmpty ?? context.text("id")
            return id.isEmpty ? nil : ChatPreviewTab(kind: .resume, id: id, label: context.text("label"))
        case "dataset":
            return context.text("id").isEmpty ? nil : ChatPreviewTab(kind: .dataset, id: context.text("id"), label: context.text("label"))
        default: return nil
        }
    }
}

struct ChatPreviewPanel: View {
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let tabs: [ChatPreviewTab]
    let active: String?
    let unavailable: Set<String>
    let activate: (String) -> Void
    let closeTab: (String) -> Void
    let close: () -> Void
    let save: (ChatPreviewTab) -> Void
    let markUnavailable: (String) -> Void
    /// 全屏查看 / 恢复面板大小（Web `PreviewPanel` 的全屏切换）。
    var fullscreen: Binding<Bool> = .constant(false)
    @Environment(SessionStore.self) private var session
    @State private var downloading = false
    @State private var downloadError: String?
    @State private var reload = UUID()
    @State private var copied = false

    private var current: ChatPreviewTab? { tabs.first { $0.key == active } ?? tabs.last }

    var body: some View {
        VStack(spacing: 0) {
            // 页眉（02B·06 · 59:2060）：左侧标签 28 高，右侧 ⋯ / 全屏 / 关闭三个细线图标
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) { ForEach(tabs, id: \.key) { tab in tabButton(tab) } }
                }
                HStack(spacing: 4) {
                    Menu {
                        Button("重新加载") { reload = UUID() }
                        Button("关闭其他标签") { tabs.filter { $0.key != current?.key }.forEach { closeTab($0.key) } }.disabled(tabs.count < 2)
                    } label: { Image(systemName: "ellipsis").font(.system(size: 12)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 26, height: 26).accessibilityLabel("更多操作")
                    headerIcon(fullscreen.wrappedValue ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               label: fullscreen.wrappedValue ? "恢复面板大小" : "全屏查看") { fullscreen.wrappedValue.toggle() }
                    headerIcon("xmark", label: "关闭预览", action: close).keyboardShortcut(.cancelAction)
                }.foregroundStyle(V3.sub)
            }.padding(.leading, 11).padding(.trailing, 8).frame(height: 50)
            Rectangle().fill(V3.line).frame(height: 1)
            Group {
                if let current {
                    switch current.kind {
                    case .resume: ChatResumePreview(resumeID: current.id, highlights: current.pending, onMissing: { markUnavailable(current.key) })
                    case .image: ChatImagePreview(data: current.imageData, label: current.label)
                    case .dataset: ChatDatasetPreview(datasetID: current.id, onMissing: { markUnavailable(current.key) })
                    case .generated: ScrollView { NativeMarkdownView(source: current.content, size: 13.5, line: 24).textSelection(.enabled).padding(24).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
            }.id((current?.key ?? "") + reload.uuidString).frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(V3.line).frame(height: 1)
            if let current { footer(current).padding(.leading, 18).padding(.trailing, 14).frame(height: 54) }
        }
        .background(.white)
    }

    private func headerIcon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11)).frame(width: 26, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    /// 页脚按钮（02B·06）：白底细边、圆角 7.5、29 高，图标 + 12 号字。
    private func footButton(_ title: String, symbol: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
                Text(title).font(V3.sans(12, weight: .medium))
            }.foregroundStyle(V3.txt).padding(.horizontal, 14).frame(height: 29)
                .background(.white, in: RoundedRectangle(cornerRadius: 7.5)).overlay(RoundedRectangle(cornerRadius: 7.5).stroke(V3.cl))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func status(_ text: String, dot: Bool = false) -> some View {
        HStack(spacing: 6) {
            if dot { Circle().fill(V3.blue).frame(width: 6, height: 6) }
            Text(text).font(V3.sans(12)).foregroundStyle(V3.sub).lineLimit(1)
        }
    }

    /// 下载资料原文件（Web `downloadDatasetSource`）：先让用户选位置，再经桌面会话下载并移动过去。
    private func download(_ tab: ChatPreviewTab) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tab.label.nilIfEmpty ?? "资料"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        downloading = true; downloadError = nil
        defer { downloading = false }
        do {
            let file = try await session.api.downloadDataset(id: tab.id, limit: 512 * 1024 * 1024)
            defer { file.discard() }
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: file.url, to: target)
        } catch {
            if case APIError.server(404, _) = error { markUnavailable(tab.key) }
            downloadError = "下载失败，请重试。"
        }
    }

    /// 标签（02B·06）：当前标签 #F4F4F2 底、圆角 7，显示完整名称；其余只显示图标 + 截断名称，悬停显示全名。
    private func tabButton(_ tab: ChatPreviewTab) -> some View {
        let selected = tab.key == current?.key
        let symbol = ["resume": "doc.text", "generated": "doc.richtext", "image": "photo"][tab.kind.rawValue] ?? "doc"
        return HStack(spacing: 8) {
            Button { activate(tab.key) } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(V3.sub)
                    Text(tab.label.nilIfEmpty ?? "未命名").font(V3.sans(12.5, weight: selected ? .medium : .regular)).lineLimit(1)
                        .frame(maxWidth: selected ? 200 : 96, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(unavailable.contains(tab.key) ? V3.fnt : V3.txt)
            Button { closeTab(tab.key) } label: { Image(systemName: "xmark").font(.system(size: 7.5, weight: .semibold)).foregroundStyle(V3.fnt).frame(width: 14, height: 14).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel("关闭 \(tab.label)")
        }.padding(.leading, 10).padding(.trailing, 6).frame(height: 28)
            .background(selected ? V3.field : .clear, in: RoundedRectangle(cornerRadius: 7)).help(tab.label)
    }

    /// 页脚（02B·06 / 02B·08）：左边只读或保存状态，右边动作；生成文档的「保存到资料库」是这一页唯一的黑色按钮。
    @ViewBuilder private func footer(_ tab: ChatPreviewTab) -> some View {
        HStack(spacing: 8) {
            switch tab.kind {
            case .resume:
                status(tab.pending.isEmpty ? "只读预览" : "只读预览 · AI 本次引用了 \(tab.pending.count) 处内容", dot: !tab.pending.isEmpty)
                Spacer()
                footButton("在编辑器中打开", symbol: "arrow.up.forward.square") { router?.jump(.editResume(tab.id)) }
                    .disabled(unavailable.contains(tab.key))
            case .dataset:
                status("只读预览")
                Spacer()
                if let downloadError { Text(downloadError).font(V3.sans(11)).foregroundStyle(V3.red) }
                footButton(downloading ? "正在下载…" : "下载文件", symbol: "arrow.down.circle") { Task { await download(tab) } }
                    .disabled(downloading || unavailable.contains(tab.key))
                footButton("在资料库中打开", symbol: "arrow.up.forward.square") { router?.jump(.section(.datasets)) }
            case .image:
                status("截图 · 仅在本次对话中可见")
                Spacer()
            case .generated:
                status(tab.saved ? "已保存到资料库" : "未保存 · 仅在本次对话中可见", dot: tab.saved)
                Spacer()
                footButton(copied ? "已复制" : "复制", symbol: "doc.on.doc") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(tab.content, forType: .string)
                    copied = true; Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                if tab.saved {
                    footButton("在资料库中打开", symbol: "arrow.up.forward.square") { router?.jump(.section(.datasets)) }
                } else {
                    Button("保存到资料库") { save(tab) }.buttonStyle(V3ButtonStyle(kind: .dark))
                }
            }
        }
    }
}

private enum PreviewLoad { case loading, ready, missing, failed }

private func previewMissing(_ error: Error) -> Bool {
    if case APIError.server(let status, let code) = error { return [403, 404].contains(status) || code.contains("NOT_FOUND") || code.contains("FORBIDDEN") }
    return false
}

private struct PreviewStateView: View {
    let state: PreviewLoad
    var unsupported = false
    var body: some View {
        VStack(spacing: 8) {
            if state == .loading { ProgressView().controlSize(.small) }
            else {
                Text(unsupported ? "暂不支持预览此格式" : state == .missing ? "这个文件已不可用" : "预览加载失败").font(V3.sans(13.5, weight: .medium)).foregroundStyle(V3.txt)
                Text(unsupported ? "Word、图片等格式请在资料库下载后查看；AI 已读取其中的文字内容。" : state == .missing ? "它可能已被删除或移动，对话中的引用保留为灰色。" : "网络异常或文件解析未完成，可以从“更多操作”重新加载。")
                    .font(V3.sans(12)).foregroundStyle(V3.fnt).multilineTextAlignment(.center)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 简历标签：取列表中的预览快照（与“我的简历”卡片同源），在纸面 WebView 中按面板宽度缩放显示。
private struct ChatResumePreview: View {
    @Environment(SessionStore.self) private var session
    let resumeID: String
    var highlights: [String] = []
    let onMissing: () -> Void
    @State private var paper: ResumeRenderRequest?
    @State private var height: CGFloat = 1123
    @State private var state = PreviewLoad.loading

    var body: some View {
        GeometryReader { geometry in
            let scale = max(0.3, (geometry.size.width - 32) / 794)
            ScrollView {
                if let paper, state == .ready {
                    ResumePaperView(request: paper, highlights: highlights, onRendered: { height = max(1123, $0) }, onError: { _ in state = .failed })
                        .frame(width: 794, height: height).allowsHitTesting(false)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: 794 * scale, height: height * scale, alignment: .topLeading)
                        .padding(16)
                } else { PreviewStateView(state: state).frame(height: geometry.size.height) }
            }.background(Tokens.Color.stage)
        }
        .task {
            state = .loading
            do {
                let resumes = try await session.api.listResumes()
                guard let resume = resumes.first(where: { $0.id == resumeID }) else { state = .missing; onMissing(); return }
                guard let request = resume.renderRequest() else { state = .failed; return }
                paper = try await session.api.preparePaper(request).request
                state = .ready
            } catch is CancellationError {
            } catch {
                if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
                state = previewMissing(error) ? .missing : .failed
                if state == .missing { onMissing() }
            }
        }
    }
}

/// 资料标签：`GET /api/datasets/{id}/content` 的解析文本；只预览 md/txt/pdf 的文字内容。
private struct ChatDatasetPreview: View {
    @Environment(SessionStore.self) private var session
    let datasetID: String
    let onMissing: () -> Void
    @State private var markdown = ""
    @State private var unsupported = false
    @State private var state = PreviewLoad.loading

    var body: some View {
        Group {
            if state == .ready && !unsupported {
                ScrollView { NativeMarkdownView(source: markdown).textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading) }
            } else { PreviewStateView(state: unsupported ? .failed : state, unsupported: unsupported) }
        }
        .task {
            state = .loading; unsupported = false
            do {
                let content = try await session.api.careerRequest(path: "/api/datasets/\(datasetID)/content", method: "GET", query: [:], body: nil)
                let format = content.text("file_format").lowercased()
                unsupported = !["md", "markdown", "txt", "pdf"].contains(format)
                markdown = content.text("markdown")
                state = .ready
            } catch is CancellationError {
            } catch {
                if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
                state = previewMissing(error) ? .missing : .failed
                if state == .missing { onMissing() }
            }
        }
    }
}

/// 截图标签（Web `ImageBody`）：25%–300% 缩放查看。
private struct ChatImagePreview: View {
    let data: Data?
    let label: String
    @State private var zoom = 100

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer()
                Button { zoom = max(25, zoom - 25) } label: { Image(systemName: "minus") }.disabled(zoom <= 25).accessibilityLabel("缩小图片")
                Button("\(zoom)%") { zoom = 100 }.font(V3.number(11.5, weight: .regular)).accessibilityLabel("恢复图片大小")
                Button { zoom = min(300, zoom + 25) } label: { Image(systemName: "plus") }.disabled(zoom >= 300).accessibilityLabel("放大图片")
            }.buttonStyle(.borderless).padding(.horizontal, 12).frame(height: 32)
            if let data, let image = NSImage(data: data) {
                GeometryReader { geometry in
                    ScrollView([.vertical, .horizontal]) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: max(40, (geometry.size.width - 32) * CGFloat(zoom) / 100)).padding(16)
                    }
                }.background(Tokens.Color.stage)
            } else { PreviewStateView(state: .failed) }
        }.accessibilityLabel(label)
    }
}
