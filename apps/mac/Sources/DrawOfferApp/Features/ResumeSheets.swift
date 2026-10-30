import AppKit
import DrawOfferCore
import SwiftUI
import UniformTypeIdentifiers

/// 重命名（Web `RenameResumeDialog`）与复制为新简历。重命名只改列表标题，不写入正文；
/// 复制携带固定的 `client_request_id`，结果不确定时重试不会多复制一份。
struct ResumeTitleSheet: View {
    enum Mode { case rename, copy }
    @Environment(SessionStore.self) private var session
    let mode: Mode
    let resume: ResumeSummary
    let close: () -> Void
    let done: (String) -> Void
    @State private var title = ""
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID().uuidString.lowercased()

    private var normalized: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .rename ? "重命名简历" : "复制为新简历").font(V3.serif(20))
            Text(mode == .rename ? "只修改列表中用于识别的名称，不会改动简历正文。" : "基于「\(resume.title)」的当前版本复制一份，原简历不受影响。")
                .font(V3.sans(13)).foregroundStyle(V3.sub).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("简历名称").font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub)
                TextField("简历名称", text: $title).textFieldStyle(.roundedBorder).onSubmit { submit() }
                    .onChange(of: title) { _, _ in if mode == .copy { requestID = UUID().uuidString.lowercased() } }
            }
            if let error { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost)).disabled(busy).keyboardShortcut(.cancelAction)
                Button(busy ? "正在保存…" : mode == .rename ? "保存" : "确认复制", action: submit)
                    .buttonStyle(V3ButtonStyle(kind: .dark))
                    .disabled(busy || normalized.isEmpty || (mode == .rename && normalized == resume.title))
            }
        }.padding(24).frame(width: 440)
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

/// 分享简历（Web `features/home/SharePanel.tsx`）：生成只读链接，设置谁可以查看、有效期与是否允许下载 PDF，
/// 支持复制、重新生成和删除链接。链接为 `{站点 origin}/share/{token}`。
struct ResumeShareSheet: View {
    private enum Expiry: String, CaseIterable, Identifiable {
        case week = "7 天", month = "30 天", forever = "永久"
        var id: String { rawValue }
        func date(now: Date = Date()) -> Date? {
            switch self {
            case .week: now.addingTimeInterval(7 * 86_400)
            case .month: now.addingTimeInterval(30 * 86_400)
            case .forever: nil
            }
        }
    }

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
    @State private var createExpiry = Expiry.week
    @State private var createAllowDownload = true
    @State private var confirmRegenerate = false
    @State private var confirmDelete = false

    private var origin: URL? { (session.api as? HTTPAPIClient)?.origin }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("分享简历").font(V3.serif(20))
            Text("为「\(resume.title)」生成只读链接，对方不用登录就能查看。").font(V3.sans(13)).foregroundStyle(V3.sub)
            if !loaded && !loadFailed {
                ProgressView("正在读取分享状态…").font(V3.sans(13)).frame(maxWidth: .infinity, minHeight: 120)
            } else if loadFailed {
                HStack {
                    Text("分享状态读取失败，请稍后重试。").font(V3.sans(13)).foregroundStyle(V3.red)
                    Spacer()
                    Button("重试") { Task { await load() } }.buttonStyle(V3ButtonStyle(kind: .ghost))
                }.frame(minHeight: 80)
            } else if let share { existing(share) }
            else { creation }
            if let error { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                if loaded && share == nil {
                    Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost)).keyboardShortcut(.cancelAction)
                    Button(busy ? "正在创建…" : "创建分享链接") { Task { await create() } }.buttonStyle(V3ButtonStyle(kind: .dark)).disabled(busy)
                } else {
                    Button("完成", action: close).buttonStyle(V3ButtonStyle(kind: .ghost)).keyboardShortcut(.cancelAction)
                }
            }
        }.padding(24).frame(width: 500)
            .task { await load() }
            .confirmationDialog("重新生成分享链接？", isPresented: $confirmRegenerate) {
                Button("确认重新生成") { Task { await regenerate() } }
            } message: {
                Text("重新生成后旧链接将立即失效，已转发的旧地址无法再访问。「\(resume.title)」的可见性与下载权限会保留。")
            }
            .confirmationDialog("删除分享链接？", isPresented: $confirmDelete) {
                Button("确认删除", role: .destructive) { Task { await deleteShare() } }
            } message: {
                Text("删除后旧地址将显示「分享链接已失效」，之后可重新创建。「\(resume.title)」本身不受影响。")
            }
    }

    private var creation: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("谁可以查看", hint: createPublic ? "公开后，拿到链接的人都能打开" : "仅自己登录后可以打开") {
                Picker("访问权限", selection: $createPublic) { Text("公开").tag(true); Text("仅自己").tag(false) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            row("链接有效期", hint: "到期后链接自动失效，可以重新生成") {
                Picker("有效期", selection: $createExpiry) { ForEach(Expiry.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            }
            row("允许下载 PDF", hint: createAllowDownload ? "关闭后，公开页面不显示下载入口" : "关闭后，任何访问者（包括分享者）均不可下载") {
                Toggle("允许下载 PDF", isOn: $createAllowDownload).toggleStyle(.switch).labelsHidden()
            }
        }.disabled(busy)
    }

    private func existing(_ share: ResumeShare) -> some View {
        let expired = share.isExpired()
        let link = origin.map { share.url(origin: $0).absoluteString } ?? ""
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(expired ? "该分享链接已失效，访客将无法继续访问简历" : link)
                    .font(V3.sans(12.5)).foregroundStyle(expired ? V3.fnt : V3.txt).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                Button(expired ? "不可复制" : copied ? "已复制" : "复制链接") { copy(link) }
                    .buttonStyle(V3ButtonStyle(kind: .ghost)).disabled(expired || link.isEmpty)
            }.padding(12).background(V3.field, in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 6) {
                Circle().fill(expired ? V3.red : V3.green).frame(width: 6, height: 6)
                Text(expired ? "链接已过期" : "链接可用").font(V3.sans(12, weight: .medium))
                Text("· " + expiryLabel(share)).font(V3.sans(12)).foregroundStyle(V3.fnt)
            }
            row("谁可以查看", hint: share.isPublic ? "公开后，拿到链接的人都能打开" : "仅自己登录后可以打开") {
                Picker("访问权限", selection: Binding(get: { share.isPublic }, set: { value in
                    Task { await update(["visibility": .string(value ? "public" : "private")]) }
                })) { Text("公开").tag(true); Text("仅自己").tag(false) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            row("链接有效期", hint: "到期后链接自动失效，可以重新生成") {
                Menu("调整为…") {
                    ForEach(Expiry.allCases) { option in
                        Button(option.rawValue) { Task { await update(["expires_at": ResumeShare.encode(option.date())]) } }
                    }
                }.fixedSize()
            }
            row("允许下载 PDF", hint: share.allowDownload ? "关闭后，公开页面不显示下载入口" : "关闭后，任何访问者（包括分享者）均不可下载") {
                Toggle("允许下载 PDF", isOn: Binding(get: { share.allowDownload }, set: { value in
                    Task { await update(["allow_download": .bool(value)]) }
                })).toggleStyle(.switch).labelsHidden()
            }
            HStack(spacing: 16) {
                Button { confirmRegenerate = true } label: { Label("重新生成链接", systemImage: "arrow.clockwise") }.buttonStyle(.link)
                Button("删除链接") { confirmDelete = true }.buttonStyle(.link).foregroundStyle(V3.red)
            }.font(V3.sans(12.5))
        }.disabled(busy)
    }

    private func row<Control: View>(_ title: String, hint: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(V3.sans(13, weight: .medium))
                Text(hint).font(V3.sans(11.5)).foregroundStyle(V3.fnt)
            }
            Spacer(minLength: 8)
            control()
        }
    }

    private func expiryLabel(_ share: ResumeShare) -> String {
        guard let expiresAt = share.expiresAt else { return "永久有效" }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let label = formatter.string(from: expiresAt)
        return share.isExpired() ? "已于 \(label) 过期" : "有效至 \(label)"
    }

    private func copy(_ link: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(link, forType: .string) {
            copied = true
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

/// 新建简历（Web `ResumeCreateDialog`，02.1a）：大预览 + 左右切换模板（← → 键）、简历名称，创建后直接进入编辑器。
struct ResumeCreateSheet: View {
    @Environment(SessionStore.self) private var session
    var initialTemplateID: String? = nil
    let close: () -> Void
    let created: (String) -> Void
    @State private var templates: [ResumeTemplate] = []
    @State private var index = 0
    @State private var title = ""
    @State private var loading = true
    @State private var loadFailed = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    private var selected: ResumeTemplate? { templates.indices.contains(index) ? templates[index] : nil }

    /// Web `ResumeCreateDialog`（`.hv3-create.is-preview`）：760 宽、高 min(900, 窗口 − 48)；标题 29 高，下方模板名与最多 3 个标签；
    /// 点阵舞台撑满中间（外边距 20/31），A4 纸面上下 24、左右 76 内缩，36 圆形翻页钮距边 20；名称区 20/32/24，输入框 44 高；
    /// 页脚左侧「第 N / M 套」与提示，取消 80、提交 148。
    var body: some View {
        V3Dialog(width: 760, closable: !busy, close: close) {
            VStack(alignment: .leading, spacing: 0) {
                Text("新建简历").font(.system(size: 20, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 29).padding(.trailing, 40)
                HStack(spacing: 6) {
                    if let selected {
                        Text(selected.name).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.tail).frame(maxWidth: 360, alignment: .leading).fixedSize().padding(.trailing, 4)
                        ForEach(Array((selected.styleCategories + selected.useCases).prefix(3)), id: \.self) { V3Chip(label: $0) }
                    } else {
                        Text("选一套模板，再起个名字，创建后直接进入编辑器。").font(V3.sans(14)).foregroundStyle(V3.sub)
                    }
                }.frame(height: 20).padding(.top, 7)
            }.padding(.horizontal, 32).padding(.top, 28)
            stage.padding(.top, 20).padding(.horizontal, 31)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("简历名称").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                    Spacer()
                    Text("只给自己看，方便在列表里区分").font(V3.sans(11.5)).foregroundStyle(V3.fnt)
                }.frame(height: 20)
                TextField("", text: $title, prompt: Text("例如：后端工程师 · 字节跳动").foregroundStyle(V3.fnt2))
                    .textFieldStyle(.plain).font(V3.sans(13.5)).foregroundStyle(V3.txt).focused($titleFocused).accessibilityLabel("简历名称")
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(error != nil ? V3.red : titleFocused ? V3.txt : V3.cl))
                    .disabled(busy).onSubmit { submit() }
                    .onChange(of: title) { if title.count > 255 { title = String(title.prefix(255)) }; error = nil }
                if let error { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red).fixedSize(horizontal: false, vertical: true) }
            }.padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 24)
        } left: {
            if !templates.isEmpty {
                Text("第 \(index + 1) / \(templates.count) 套").font(V3.sans(11.5, weight: .medium)).foregroundStyle(V3.sub).lineLimit(1)
                    .accessibilityLabel("当前模板位置")
            }
            Text("模板之后可以在编辑器里随时切换").font(V3.sans(11.5)).foregroundStyle(V3.fnt).lineLimit(1)
        } foot: {
            Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36, width: 80)).disabled(busy)
            Button(busy ? "正在创建…" : "创建并进入编辑器", action: submit).buttonStyle(V3ButtonStyle(kind: .dark, height: 36, width: 148))
                .disabled(busy || loading || loadFailed || selected == nil)
        }
        .bodyPadding(false)
        .frame(height: min(900, (NSApp.mainWindow?.contentLayoutRect.height ?? 948) - 48))
        .onKeyPress(.leftArrow) { guard !titleFocused else { return .ignored }; move(-1); return .handled }
        .onKeyPress(.rightArrow) { guard !titleFocused else { return .ignored }; move(1); return .handled }
        .onAppear { titleFocused = true }
        .task { await load() }
    }

    private var stage: some View {
        V3DotStage(height: nil) {
            if loading { Text("正在加载简历模板…").font(V3.sans(12.5)).foregroundStyle(V3.sub) }
            else if loadFailed {
                VStack(spacing: 12) {
                    Text("模板暂时无法加载，请检查网络后重试。").font(V3.sans(12.5)).foregroundStyle(V3.sub)
                    Button { Task { await load() } } label: { Label("重新加载", systemImage: "arrow.clockwise") }.buttonStyle(V3ButtonStyle(kind: .ghost))
                }
            } else if templates.isEmpty {
                Text("当前没有可用模板，暂时无法新建简历。").font(V3.sans(12.5)).foregroundStyle(V3.sub)
            } else if let selected {
                TemplateThumbnail(template: selected, guest: false).id(selected.id)
                    .aspectRatio(210.0 / 297, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4)).shadow(color: .black.opacity(0.08), radius: 12, y: 8)
                    .padding(.vertical, 24).padding(.horizontal, 76)
                    .accessibilityElement(children: .ignore).accessibilityLabel("\(selected.name)，已选择")
                HStack {
                    navButton("chevron.left", "上一个模板") { move(-1) }
                    Spacer()
                    navButton("chevron.right", "下一个模板") { move(1) }
                }.padding(.horizontal, 20)
            }
        }.frame(maxHeight: .infinity)
    }

    private func navButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(V3.sub)
                .frame(width: 36, height: 36).background(.white, in: Circle()).overlay(Circle().stroke(V3.cl))
                .shadow(color: .black.opacity(0.06), radius: 3, y: 2).contentShape(Circle())
        }.buttonStyle(.plain).disabled(busy || templates.count < 2).opacity(busy || templates.count < 2 ? 0.4 : 1).accessibilityLabel(label)
    }

    private func move(_ direction: Int) {
        guard templates.count > 1 else { return }
        index = (index + direction + templates.count) % templates.count
        error = nil
    }

    private func load() async {
        loading = true; loadFailed = false
        defer { loading = false }
        do {
            templates = try await session.api.listResumeTemplates().filter { !ResumeRequest.retiredTemplateKeys.contains($0.key) }
            index = max(0, initialTemplateID.flatMap { id in templates.firstIndex { $0.id == id } } ?? 0)
        } catch { loadFailed = true }
    }

    private func submit() {
        guard !busy else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "请输入简历名称。"; titleFocused = true; return }
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
                titleFocused = true
            }
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
            V3DialogHead(title: "导入简历", sub: "AI 会把文件拆成可编辑的模块，之后可以随时修改。")
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
            V3TextInput(label: "简历名称", placeholder: "例如：张三｜产品经理", text: $title, error: error, disabled: busy, submit: submit)
                .onChange(of: title) { error = nil }.padding(.top, 24)
        } left: {
            Text(file == nil ? "未选择文件" : "默认使用文件名（不含扩展名），可修改").font(V3.sans(11.5)).foregroundStyle(V3.fnt).lineLimit(1)
        } foot: {
            FeatureCostLabel(code: "resume_import")
            Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36, width: 80)).disabled(busy)
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
                Button("移除文件") { self.file = nil; title = "" }.buttonStyle(.plain).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.sub).disabled(busy)
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
