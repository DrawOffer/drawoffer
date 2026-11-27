import AppKit
import DrawOfferCore
import SwiftUI
import UniformTypeIdentifiers

/// A3.2 重命名简历（统一弹窗 462 宽，Web `RenameResumeDialog`）与复制为新简历（同一弹窗换文案）。
/// 重命名只改列表标题，不写入正文；复制携带固定的 `client_request_id`，结果不确定时重试不会多复制一份。
struct ResumeTitleSheet: View {
    enum Mode { case rename, copy }
    @Environment(SessionStore.self) private var session
    let mode: Mode
    let resume: ResumeSummary
    let close: () -> Void
    let done: (String) -> Void
    /// 「想按另一个岗位改？复制为新简历」：给了才显示。
    var copy: (() -> Void)? = nil
    @State private var title = ""
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID().uuidString.lowercased()

    private var normalized: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        V3StandardDialog(title: mode == .rename ? "重命名简历" : "复制为新简历",
                         subtitle: mode == .rename ? "名称只给自己看，方便在列表里区分。" : "复制后得到独立简历，两份内容互不影响。",
                         close: { if !busy { close() } }) {
            VStack(alignment: .leading, spacing: 16) {
                ResumeDialogInput(label: "简历名称", placeholder: "例如：后端工程师 · 字节跳动", text: $title, error: error, disabled: busy, submit: submit)
                    .onChange(of: title) { _, _ in error = nil; if mode == .copy { requestID = UUID().uuidString.lowercased() } }
                if mode == .rename, let copy {
                    HStack(spacing: 6) {
                        Text("想按另一个岗位改？").foregroundStyle(V3.fnt)
                        V3TextLink(title: "复制为新简历", chevron: false, action: copy).disabled(busy)
                    }
                }
            }
        } note: {
            EmptyView()
        } actions: {
            Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36)).disabled(busy)
            Button(busy ? "正在保存…" : mode == .rename ? "保存名称" : "创建副本", action: submit)
                .buttonStyle(V3ButtonStyle(kind: .dark, height: 36))
                .disabled(busy || normalized.isEmpty || normalized.count > 255)
        }
        .onAppear { title = mode == .rename ? resume.title : "\(resume.title) 副本" }
    }

    private func submit() {
        let name = normalized
        guard !busy, !name.isEmpty else { return }
        guard name.count <= 255, !name.contains(where: \.isNewline) else { error = "名称无效，请输入 1–255 个字符且不含换行。"; return }
        if mode == .rename && name == resume.title { close(); return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                switch mode {
                case .rename:
                    _ = try await session.api.careerRequest(path: "/api/resumes/\(resume.id)", method: "PUT", query: [:],
                        body: .object(["title": .string(name), "base_lock_version": .number(Double(resume.lockVersion))]))
                case .copy:
                    _ = try await session.api.careerRequest(path: "/api/resumes/\(resume.id)/copy", method: "POST", query: [:],
                        body: .object(["title": .string(name), "base_lock_version": .number(Double(resume.lockVersion)), "client_request_id": .string(requestID)]))
                }
                done(name)
            } catch {
                if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
                let fallback = mode == .rename ? "保存名称失败，请刷新列表后重试。" : "复制失败，请检查名称、简历数量或刷新后重试。"
                if case APIError.server = error { self.error = ResumeRequest.errorMessage(error, fallback: fallback) }
                else if case APIError.unauthorized = error { self.error = ResumeRequest.errorMessage(error, fallback: fallback) }
                else { self.error = mode == .copy ? "网络中断，结果尚未确认。可以直接重试，不会重复复制。" : "网络中断，结果尚未确认，请重试。" }
            }
        }
    }
}

/// A3.3 分享简历（统一弹窗 520 宽，Web `SharePanel`）：链接行（灰底地址 + 墨黑「复制链接」）、一行状态，
/// 设置三行（谁可以查看 / 有效期 / 下载 PDF，左 84 灰标签）；左下「重新生成链接 · 删除链接」，右下「完成」。
/// 还没有链接时只有设置三行，右下「取消」+「创建分享链接」。链接为 `{站点 origin}/share/{token}`。
struct ResumeShareSheet: View {
    @Environment(SessionStore.self) private var session
    let resume: ResumeSummary
    let close: () -> Void
    @State private var share: ResumeShare?
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false
    @State private var createPublic = true
    @State private var createExpiry = ResumeShare.Expiry.forever
    @State private var createAllowDownload = true
    @State private var confirmRegenerate = false
    @State private var confirmDelete = false

    private var origin: URL? { (session.api as? HTTPAPIClient)?.origin }

    var body: some View {
        V3StandardDialog(title: "分享简历", subtitle: "为「\(resume.title)」生成只读链接，对方不用登录就能查看。", width: 520, close: close) {
            if !loaded && !loadFailed {
                V3Loading("正在读取分享状态…").frame(maxWidth: .infinity, minHeight: 150)
            } else if loadFailed {
                VStack(spacing: 12) {
                    Text("分享状态读取失败，请稍后重试。").foregroundStyle(V3.red)
                    Button("重试") { Task { await load() } }.buttonStyle(V3ButtonStyle(kind: .ghost))
                }.frame(maxWidth: .infinity, minHeight: 150)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    if let share { link(share) }
                    settings(share)
                    if let error { Text(error).font(V3.sans(12)).foregroundStyle(V3.red).fixedSize(horizontal: false, vertical: true) }
                }.disabled(busy)
            }
        } note: {
            if loaded, share != nil {
                HStack(spacing: 6) {
                    Button("重新生成链接") { confirmRegenerate = true }.buttonStyle(.plain).foregroundStyle(V3.sub)
                    Text("·").foregroundStyle(V3.sub)
                    Button("删除链接") { confirmDelete = true }.buttonStyle(.plain).foregroundStyle(V3.red)
                }.disabled(busy)
            }
        } actions: {
            if loaded && share == nil {
                Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36))
                Button(busy ? "正在创建…" : "创建分享链接") { Task { await create() } }.buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).disabled(busy)
            } else {
                Button("完成", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36))
            }
        }
        .task { await load() }
        .centeredConfirmation("重新生成分享链接？", isPresented: $confirmRegenerate) {
            Button("确认重新生成") { Task { await regenerate() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重新生成后旧链接将立即失效，已转发的旧地址无法再访问。「\(resume.title)」的可见性与下载权限会保留。\(regenerationNote)")
        }
        .centeredConfirmation("删除分享链接？", isPresented: $confirmDelete) {
            Button("确认删除", role: .destructive) { Task { await deleteShare() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后旧地址将显示「分享链接已失效」，之后可重新创建。「\(resume.title)」本身不受影响。")
        }
    }

    /// 链接行：36 高灰底地址（链接图标 + 地址，末尾省略）+ 132 宽墨黑「复制链接」；下面一行绿点状态。
    private func link(_ share: ResumeShare) -> some View {
        let expired = share.isExpired()
        let url = origin.map { share.url(origin: $0).absoluteString } ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "link").font(.system(size: 12)).foregroundStyle(expired ? V3.fnt : V3.sub)
                    Text(expired ? "该分享链接已失效，访客将无法继续访问简历" : url)
                        .foregroundStyle(expired ? V3.fnt : V3.txt).lineLimit(1).truncationMode(.tail).textSelection(.enabled).help(expired ? "" : url)
                }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).background(V3.field, in: RoundedRectangle(cornerRadius: 8))
                Button(expired ? "不可复制" : copied ? "已复制" : "复制链接") { copy(url) }
                    .buttonStyle(V3ButtonStyle(kind: .dark, height: 36, width: 132)).disabled(busy || expired || url.isEmpty)
            }
            HStack(spacing: 6) {
                Circle().fill(expired ? V3.red : V3.green).frame(width: 6, height: 6)
                Text("\(expired ? "链接已过期" : "链接可用") · \(share.expiryLabel())").font(V3.sans(12)).foregroundStyle(V3.fnt)
            }
        }
    }

    private func settings(_ share: ResumeShare?) -> some View {
        let allowDownload = share?.allowDownload ?? createAllowDownload
        return VStack(alignment: .leading, spacing: 12) {
            row("谁可以查看") {
                V3Segmented(options: [(true, "公开"), (false, "仅自己")], selection: Binding(get: { share?.isPublic ?? createPublic }, set: { value in
                    if let share { if value != share.isPublic { Task { await update(["visibility": .string(value ? "public" : "private")]) } } } else { createPublic = value }
                }), segmentWidth: 88)
            }
            row("有效期") {
                V3Segmented(options: ResumeShare.Expiry.allCases.map { (Optional($0), $0.rawValue) },
                            selection: Binding(get: { share.map { $0.expiry() } ?? createExpiry }, set: { value in
                                guard let value else { return }
                                if share != nil { Task { await update(["expires_at": ResumeShare.encode(value.date())]) } } else { createExpiry = value }
                            }), segmentWidth: 88)
            }
            row("下载 PDF") {
                Toggle("允许下载 PDF", isOn: Binding(get: { allowDownload }, set: { value in
                    if share != nil { Task { await update(["allow_download": .bool(value)]) } } else { createAllowDownload = value }
                })).toggleStyle(.switch).controlSize(.small).tint(V3.txt).labelsHidden()
                Text(allowDownload ? "关闭后，分享页不显示下载入口" : "关闭后，任何访问者（包括分享者）均不可下载").font(V3.sans(12)).foregroundStyle(V3.fnt)
            }
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(V3.fnt).frame(width: 84, alignment: .leading)
            control()
        }.frame(minHeight: 30)
    }

    private var regenerationNote: String {
        guard let share, share.isExpired() else { return "现有到期时间会保留。" }
        if let created = share.createdAt, let expires = share.expiresAt, created < expires { return "新链接按原有效时长重新计算到期时间。" }
        return "原有效时长无法确定，新链接默认有效 7 天。"
    }

    private func copy(_ link: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(link, forType: .string) {
            copied = true; error = nil
            Task { try? await Task.sleep(for: .seconds(2)); copied = false }
        } else { error = "复制失败，请手动复制链接。" }
    }

    private func path() -> String { "/api/resumes/\(resume.id)/share" }

    private func load() async {
        loadFailed = false; error = nil
        do {
            let result = try await session.api.careerRequest(path: path(), method: "GET", query: [:], body: nil)
            share = ResumeShare(result["share"]); loaded = true
        } catch is CancellationError {
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            loadFailed = true
        }
    }

    private func run(_ method: String, body: JSONValue?, failure: String) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await session.api.careerRequest(path: path(), method: method, query: [:], body: body)
            share = method == "DELETE" ? nil : ResumeShare(result["share"])
            if method == "DELETE" { createPublic = true; createExpiry = .forever; createAllowDownload = true }
        } catch is CancellationError {
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            self.error = ResumeRequest.errorMessage(error, fallback: failure)
            if case APIError.server(404, "SHARE_LINK_UNAVAILABLE") = error { share = nil }
        }
    }

    private func create() async {
        await run("POST", body: .object([
            "visibility": .string(createPublic ? "public" : "private"),
            "expires_at": ResumeShare.encode(createExpiry.date()),
            "allow_download": .bool(createAllowDownload),
        ]), failure: "生成分享链接失败，请稍后重试。")
    }

    private func regenerate() async {
        guard let share else { return }
        await run("POST", body: .object([
            "visibility": .string(share.isPublic ? "public" : "private"),
            "expires_at": ResumeShare.encode(share.regeneratedExpiry()),
            "allow_download": .bool(share.allowDownload),
        ]), failure: "重新生成分享链接失败，请稍后重试。")
    }

    private func update(_ fields: [String: JSONValue]) async {
        await run("PATCH", body: .object(fields), failure: "更新链接配置失败，请稍后重试。")
    }

    private func deleteShare() async {
        await run("DELETE", body: nil, failure: "删除分享链接失败，请稍后重试。")
    }
}

/// A3.1 新建简历（统一弹窗 720 宽，Web `ResumeCreateDialog`）：「选模板」+ 岗位分段，5 列模板缩略图（160 高灰底格、选中墨黑描边与右上对勾），
/// 「简历名称」输入；底部左侧「共 N 套，之后可在编辑器里换」，右侧取消 +「创建并进入编辑器」。创建后进编辑器的新建引导。
struct ResumeCreateSheet: View {
    @Environment(SessionStore.self) private var session
    var initialTemplateID: String? = nil
    let close: () -> Void
    let created: (String) -> Void
    @State private var templates: [ResumeTemplate] = []
    @State private var category = ResumeCreatePicker.all
    @State private var selectedID: String?
    @State private var title = ""
    @State private var loading = true
    @State private var loadFailed = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var gridFocused: Bool

    private static let columns = 5
    private var visible: [ResumeTemplate] { ResumeCreatePicker.visible(templates, category: category) }
    private var selected: ResumeTemplate? { templates.first { $0.id == selectedID } }

    var body: some View {
        V3StandardDialog(title: "新建简历", subtitle: "选一套模板、起个名字，创建后跟着引导一步步写。", width: 720, close: { if !busy { close() } }) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Text("选模板").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                    Spacer(minLength: 0)
                    let options = ResumeCreatePicker.categories(templates)
                    if options.count > 1 {
                        V3Segmented(options: options.map { ($0.value, $0.label) }, selection: Binding(get: { category }, set: { change($0) }))
                            .disabled(busy).accessibilityLabel("岗位筛选")
                    }
                }
                grid
                ResumeDialogInput(label: "简历名称", placeholder: "例如：后端工程师 · 字节跳动", text: $title, error: error, disabled: busy, focusOnAppear: false, submit: submit)
                    .onChange(of: title) { _, _ in error = nil }
            }
        } note: {
            if !visible.isEmpty { Text("共 \(visible.count) 套，之后可在编辑器里换") }
        } actions: {
            Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36)).disabled(busy)
            Button(busy ? "正在创建…" : "创建并进入编辑器", action: submit).buttonStyle(V3ButtonStyle(kind: .dark, height: 36))
                .disabled(busy || loading || loadFailed || selected == nil)
        }
        .task { await load() }
    }

    /// 5 列、行高 186（格 160 + 名称），行距 14、列距 12；两行高，多了在里面滚。
    @ViewBuilder private var grid: some View {
        let height: CGFloat = 386
        if loading {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: Self.columns), spacing: 14) {
                ForEach(0..<10, id: \.self) { _ in
                    VStack(spacing: 8) {
                        V3Skeleton(height: 160, radius: 8)
                        V3Skeleton(width: 56, height: 8)
                    }
                }
            }.frame(height: height, alignment: .top).accessibilityLabel("正在加载简历模板…")
        } else if loadFailed {
            VStack(spacing: 12) {
                Text("模板暂时无法加载，请检查网络后重试。").foregroundStyle(V3.sub)
                Button("重新加载") { Task { await load() } }.buttonStyle(V3ButtonStyle(kind: .ghost))
            }.frame(maxWidth: .infinity).frame(height: 186)
        } else if templates.isEmpty {
            Text("当前没有可用模板，暂时无法新建简历。").foregroundStyle(V3.sub).frame(maxWidth: .infinity).frame(height: 186)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: Self.columns), spacing: 14) {
                        ForEach(visible) { template in option(template).id(template.id) }
                    }.padding(.trailing, 2)
                }
                .scrollIndicators(.automatic)
                .frame(height: height)
                .focusable().focused($gridFocused).focusEffectDisabled()
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    let key: ResumeCreatePicker.Key = switch press.key {
                    case .leftArrow: .left
                    case .rightArrow: .right
                    case .upArrow: .up
                    default: .down
                    }
                    guard !busy else { return .ignored }
                    select(ResumeCreatePicker.move(visible.map(\.id), current: selectedID, columns: Self.columns, key: key))
                    return .handled
                }
                .onChange(of: selectedID) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
                .onAppear { if let selectedID { proxy.scrollTo(selectedID) } }
                .id(category)
            }
        }
    }

    private func option(_ template: ResumeTemplate) -> some View {
        let on = template.id == selectedID
        return Button { select(template.id) } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    TemplateThumbnail(template: template, radius: 2).frame(width: 92)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 18, height: 18).background(V3.txt, in: Circle()).padding(6)
                    }
                }
                .frame(height: 160)
                .background(V3.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? V3.txt : .clear, lineWidth: 1.5))
                Text(template.name).font(V3.sans(12, weight: on ? .medium : .regular)).foregroundStyle(on ? V3.txt : V3.sub)
                    .lineLimit(1).truncationMode(.tail).frame(height: 18).help(template.name)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(busy)
        .accessibilityLabel(template.name).accessibilityAddTraits(on ? .isSelected : [])
    }

    private func select(_ id: String?) {
        selectedID = id; error = nil
    }

    private func change(_ next: String) {
        guard !busy else { return }
        category = next
        select(ResumeCreatePicker.selection(after: next, in: templates, current: selectedID))
    }

    private func load() async {
        loading = true; loadFailed = false
        defer { loading = false }
        do {
            templates = try await session.api.listResumeTemplates().filter { !ResumeRequest.retiredTemplateKeys.contains($0.key) }
            selectedID = (initialTemplateID.flatMap { id in templates.first { $0.id == id } } ?? templates.first)?.id
        } catch { loadFailed = true }
    }

    private func submit() {
        guard !busy else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "请输入简历名称。"; return }
        guard let selected else { error = "请先选择一套简历模板。"; return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await session.api.careerRequest(path: "/api/resumes", method: "POST", query: [:],
                    body: .object(["title": .string(name), "template_id": .string(selected.id), "guide": .bool(true)]))
                created((result["resume"] ?? result).display("id"))
            } catch {
                if case APIError.unauthorized = error { session.reportAuthenticationFailure(); return }
                if case APIError.server(_, let code) = error {
                    self.error = code == "INVALID_RESUME_TITLE" ? "请输入 1–255 个字符的简历名称。"
                        : code == "RESUME_TITLE_CONFLICT" ? "该名称已经存在，请换一个名称。"
                        : code == "TEMPLATE_INACTIVE" ? "所选模板已不可用，请重新选择。"
                        : code == "RESUME_LIMIT_REACHED" ? "已达到 \(ResumeRequest.maximumPerUser) 份上限。删除不用的简历后，才能新建或复制。"
                        : "创建简历失败，请稍后重试。"
                } else { self.error = "网络中断，无法确认是否已创建。请先查看简历列表，避免重复创建。" }
            }
        }
    }
}

/// 统一弹窗里的输入（Web `.v3-field` + `.v3-input`）：13 号中粗灰标签，下面 40 高白底、#e4e4e0 细边、圆角 8 的输入框，
/// 聚焦时墨黑边；出错时红边与一行红字。
struct ResumeDialogInput: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var error: String? = nil
    var disabled = false
    var maxLength = 255
    var focusOnAppear = true
    var submit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.sub)
            TextField("", text: $text)
                .textFieldStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.txt).focused($focused)
                .padding(.horizontal, 14).frame(height: 40)
                .overlay(alignment: .leading) {
                    if text.isEmpty { Text(placeholder).font(V3.sans(13)).foregroundStyle(V3.fnt2).padding(.leading, 14).allowsHitTesting(false) }
                }
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(error != nil ? V3.red : focused ? V3.txt : V3.cl))
                .disabled(disabled).onSubmit(submit).accessibilityLabel(label)
                .onAppear { if focusOnAppear { focused = true } }
                .onChange(of: text) { if text.count > maxLength { text = String(text.prefix(maxLength)) } }
            if let error { Text(error).font(V3.sans(12)).foregroundStyle(V3.red).fixedSize(horizontal: false, vertical: true) }
        }
    }
}


/// 导入简历（Web `ResumeImportDialog`）：拖入或选择 Markdown/DOCX/PDF（最大 10 MB），可移除文件、修改名称（默认取文件名），
/// 导入默认版式取管理端排序的第一套模板，上传完成后后端开始解析。
struct ResumeImportSheet: View {
    @Environment(SessionStore.self) private var session
    var initialFile: URL? = nil
    let close: () -> Void
    let accepted: (String) -> Void
    @State private var file: URL?
    @State private var title = ""
    @State private var busy = false
    @State private var error: String?
    @State private var targeted = false

    /// Web `ResumeImportDialog`（02.1b）：560 宽；未选文件时是 184 高的点阵拖放区，选中后是 116 高插图与 64 高文件行；
    /// 页脚左侧提示、积分说明、取消 80 与「导入并开始解析」132。
    var body: some View {
        V3Dialog(width: 560, closable: !busy, close: close) {
            ResumeSheetHead(title: "导入简历", sub: "AI 会把文件拆成可编辑的模块，之后可以随时修改。")
            if let file {
                V3DotStage(height: 116) { ImportArt(single: ImportArt.tag(file.lastPathComponent)) }.padding(.top, 16)
                fileRow(file).padding(.top, 20)
            } else {
                Button(action: pick) {
                    ZStack(alignment: .top) {
                        ImportArt(single: nil).frame(height: 104)
                        Text("拖入简历文件，或点击选择").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).frame(height: 16).offset(y: 120)
                        Text("支持 Markdown、DOCX、PDF，最大 10 MB").font(V3.sans(11)).foregroundStyle(V3.fnt).frame(height: 13).offset(y: 144)
                    }
                    .frame(maxWidth: .infinity).frame(height: 182)
                    .background { V3DotStage(height: nil) { EmptyView() }.opacity(targeted ? 0.85 : 1) }
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(targeted ? Color(hex: 0xDCDCD8) : Color(hex: 0xE9E9E5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(busy).accessibilityLabel("选择 Markdown、DOCX 或 PDF 文件").padding(.top, 16)
                .dropDestination(for: URL.self) { urls, _ in if let first = urls.first { choose(first) }; return !urls.isEmpty } isTargeted: { targeted = $0 }
            }
            ResumeSheetField(label: "简历名称", placeholder: "例如：张三｜产品经理", text: $title, error: error, disabled: busy, submit: submit)
                .onChange(of: title) { error = nil }.padding(.top, 24)
        } left: {
            Text(file == nil ? "未选择文件" : "默认使用文件名（不含扩展名），可修改").font(V3.sans(11.5)).foregroundStyle(V3.fnt).lineLimit(1)
        } foot: {
            FeatureCostLabel(code: "resume_import")
            Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36, width: 79)).disabled(busy).keyboardShortcut(.cancelAction)
            Button(busy ? "正在导入…" : "导入并开始解析", action: submit).buttonStyle(V3ButtonStyle(kind: .dark, height: 36, width: 132)).disabled(busy || file == nil)
        }
        .onAppear { if let initialFile, file == nil { choose(initialFile) } }
    }

    /// `.hv3-file`：圆角 12 的白卡，64 高一行（格式色块 36、名称 13/500、大小 11、「移除文件」链接），导入中下方加进度条。
    private func fileRow(_ file: URL) -> some View {
        let tag = ImportArt.tag(file.lastPathComponent)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(tag.label).font(V3.number(9.5, weight: .bold)).foregroundStyle(tag.color)
                    .frame(width: 36, height: 36).background(tag.soft, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 5) {
                    Text(file.lastPathComponent).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.tail).frame(height: 16)
                    Text(ByteCountFormatter.string(fromByteCount: Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file))
                        .font(V3.number(11, weight: .medium)).foregroundStyle(V3.fnt).frame(height: 13)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("移除文件") { self.file = nil; title = "" }.buttonStyle(.plain).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub).disabled(busy)
            }.padding(.leading, 14).padding(.trailing, 18).frame(height: 64)
            if busy {
                VStack(alignment: .leading, spacing: 10) {
                    Text("正在导入… 上传完成后自动开始解析").font(V3.sans(11.5)).foregroundStyle(V3.sub).frame(height: 14)
                    ProgressView().progressViewStyle(.linear).tint(V3.txt).frame(height: 4)
                        .accessibilityLabel("\(file.lastPathComponent) 正在导入")
                }
                .padding(.top, 11).padding(.bottom, 15).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }.padding(.horizontal, 18)
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.cl))
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf] + ["md", "docx"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(url)
    }

    private func choose(_ url: URL) {
        guard ResumeImportUpload.types[url.pathExtension.lowercased()] != nil else { error = "选择 Markdown、DOCX 或 PDF 文件"; return }
        file = url
        title = url.deletingPathExtension().lastPathComponent
        error = nil
    }

    private func submit() {
        guard !busy else { return }
        guard let file else { error = "请先选择需要导入的文件。"; return }
        if let message = ResumeImportUpload.titleError(title) { error = message; return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let templates = try await session.api.listResumeTemplates()
                guard let template = templates.first else { error = "导入所需的默认版式暂时不可用，请稍后重试。"; return }
                let upload = try ResumeImportUpload(file: file, templateID: template.id, title: title)
                _ = try await session.api.importResume(upload)
                accepted(title.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                if case APIError.unauthorized = error { session.reportAuthenticationFailure(); return }
                self.error = ResumeImportUpload.errorMessage(error)
            }
        }
    }
}


/// Web `ImportArt`：多份文件纸（MD / DOCX / PDF）或单份带格式的纸，经虚线箭头变成分好模块的简历纸，右上一个 spark 角标。
struct ImportArt: View {
    struct Tag { let label: String; let color: Color; let soft: Color }
    let single: Tag?

    static func tag(_ name: String) -> Tag {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": Tag(label: "PDF", color: Color(hex: 0xD9822B), soft: Color(hex: 0xFBEFE3))
        case "docx", "doc": Tag(label: "DOCX", color: V3.blue, soft: V3.blueSoft)
        default: Tag(label: "MD", color: V3.sub, soft: V3.field)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let single {
                paper(x: 168, y: 22, w: 48, h: 62, tag: single.label, color: single.color, rotate: 6)
            } else {
                paper(x: 128, y: 22, w: 46, h: 60, tag: "MD", color: V3.sub, rotate: 10)
                paper(x: 150, y: 18, w: 46, h: 60, tag: "DOCX", color: V3.blue, rotate: 2)
                paper(x: 172, y: 22, w: 46, h: 60, tag: "PDF", color: Color(hex: 0xD9822B), rotate: -6)
            }
            arrow.offset(x: 232, y: 46)
            modules(filled: single == nil ? 3 : 2).offset(x: 284, y: 14)
            Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(V3.txt, in: Circle()).shadow(color: .black.opacity(0.1), radius: 3, y: 2).offset(x: 346, y: 6)
        }
        .frame(width: 496, height: single == nil ? 104 : 116, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }

    private func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color = Color(hex: 0xECECEA), r: CGFloat = 1) -> some View {
        RoundedRectangle(cornerRadius: r).fill(color).frame(width: w, height: h).offset(x: x, y: y)
    }

    private func sheet<C: View>(_ w: CGFloat, _ h: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        ZStack(alignment: .topLeading) { content() }
            .frame(width: w, height: h, alignment: .topLeading)
            .background(.white).clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(V3.cl)).shadow(color: .black.opacity(0.06), radius: 8, y: 6)
    }

    private func paper(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, tag: String, color: Color, rotate: Double) -> some View {
        sheet(w, h) {
            bar(7, 9, w * 0.55, 4, Color(hex: 0xDCDCD8), r: 2)
            bar(7, 18, w * 0.7, 3, r: 2)
            bar(7, 25, w * 0.5, 3, r: 2)
            Text(tag).font(.system(size: 7.5, weight: .bold)).foregroundStyle(.white)
                .frame(width: tag.count > 2 ? 30 : 24, height: 13).background(color, in: RoundedRectangle(cornerRadius: 3)).offset(x: 7, y: h - 20)
        }.rotationEffect(.degrees(rotate)).offset(x: x, y: y)
    }

    private func modules(filled: Int) -> some View {
        sheet(76, 88) {
            bar(9, 9, 30, 5, V3.txt)
            bar(9, 18, 46, 3, Color(hex: 0xDCDCD8))
            ForEach(Array([28.0, 48, 67].enumerated()), id: \.offset) { index, top in
                if index < filled {
                    ZStack(alignment: .topLeading) {
                        bar(5, 3.5, 24, 3, Color(hex: 0xDCDCD8))
                        bar(5, 9, 38, 2.5)
                    }.frame(width: 58, height: 15, alignment: .topLeading).background(V3.field, in: RoundedRectangle(cornerRadius: 3)).offset(x: 9, y: top)
                } else {
                    RoundedRectangle(cornerRadius: 3).stroke(Color(hex: 0xE9E9E5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 58, height: 15).offset(x: 9, y: top)
                }
            }
        }
    }

    private var arrow: some View {
        Canvas { context, _ in
            var line = Path(); line.move(to: CGPoint(x: 2, y: 7)); line.addLine(to: CGPoint(x: 34, y: 7))
            context.stroke(line, with: .color(Color(hex: 0xB9B9B3)), style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
            var head = Path(); head.move(to: CGPoint(x: 34, y: 3)); head.addLine(to: CGPoint(x: 39, y: 7)); head.addLine(to: CGPoint(x: 34, y: 11))
            context.stroke(head, with: .color(Color(hex: 0xB9B9B3)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }.frame(width: 44, height: 14)
    }
}

/// Web `FeatureCost`：后台配置的功能价格（`GET /api/billing/feature-prices`，每次启动读一次），读不到时按用量计。
struct FeatureCostLabel: View {
    @Environment(SessionStore.self) private var session
    let code: String
    @State private var label = "按实际用量消耗积分"
    @MainActor private static var cache: [JSONValue]?

    var body: some View {
        Text(label).font(V3.sans(12)).foregroundStyle(V3.sub).frame(height: 18)
            .task {
                if Self.cache == nil, let result = try? await session.api.careerRequest(path: "/api/billing/feature-prices", method: "GET", query: [:], body: nil) {
                    Self.cache = result["items"]?.items ?? []
                }
                label = Self.label(Self.cache?.first { $0.text("featureCode") == code })
            }
    }

    static func label(_ price: JSONValue?) -> String {
        let points = price?["unitPoints"]?.stringValue.flatMap(Double.init) ?? price?["unitPoints"]?.numberValue
        let text = points.map { value in
            let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 2; formatter.locale = Locale(identifier: "en_US")
            return formatter.string(from: NSNumber(value: value)) ?? String(value)
        }
        switch price?.text("priceMode") {
        case "fixed" where text != nil: return "消耗 \(text!) 积分"
        case "per_minute" where text != nil: return "每分钟 \(text!) 积分"
        case "free": return "本次免费"
        default: return "按实际用量消耗积分"
        }
    }
}

// MARK: - 03 页弹窗公共件（02.1a–02.1f）

enum ResumeSheetStyle {
    /// 稿中标签、提示与计数的浅灰字 #96968F。
    static let hint = Color(hex: 0x96968F)
}

/// 弹窗标题：20/600（29 高）+ 12.5 号说明（距标题 2）。
struct ResumeSheetHead: View {
    let title: String
    var sub: String? = nil
    var body: some View {
        Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 29)
        if let sub {
            Text(sub).font(V3.sans(12.5)).foregroundStyle(V3.sub).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
        }
    }
}

/// 弹窗输入：11 号灰字标签，下面 40 高 #f4f4f2 底、圆角 8 的输入框（聚焦白底细边，出错红边与提示）。
struct ResumeSheetField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var error: String? = nil
    var disabled = false
    var maxLength = 255
    var submit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(V3.sans(11)).foregroundStyle(ResumeSheetStyle.hint).frame(height: 13)
            TextField("", text: $text)
                .textFieldStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.txt).focused($focused)
                .overlay(alignment: .leading) {
                    if text.isEmpty { Text(placeholder).font(V3.sans(13)).foregroundStyle(V3.fnt2).allowsHitTesting(false) }
                }
                .padding(.horizontal, 14).frame(height: 40)
                .background(focused ? Color.white : V3.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(error != nil ? V3.red : focused ? V3.cl : .clear))
                .disabled(disabled).onSubmit(submit).accessibilityLabel(label)
                .onAppear { focused = true }
                .onChange(of: text) { if text.count > maxLength { text = String(text.prefix(maxLength)) } }
            if let error { Text(error).font(V3.sans(12)).foregroundStyle(V3.red).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A3.4 删除简历（统一弹窗 462 宽，Web `DeleteResumeDialog`）：只说会影响什么，红色只给「删除」。
struct ResumeDeleteSheet: View {
    let resume: ResumeSummary
    let busy: Bool
    let delete: () -> Void
    let cancel: () -> Void

    var body: some View {
        V3StandardDialog(title: "删除这份简历？", subtitle: "「\(resume.title)」删除后不能恢复。", close: cancel) {
            Text("公开分享链接会失效，关联的求职记录不再带着这份简历。").foregroundStyle(V3.sub).fixedSize(horizontal: false, vertical: true)
        } note: {
            EmptyView()
        } actions: {
            Button("取消", action: cancel).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36)).disabled(busy)
            Button(busy ? "正在删除…" : "删除", action: delete).buttonStyle(V3ButtonStyle(kind: .danger, height: 36)).disabled(busy)
        }
    }
}
