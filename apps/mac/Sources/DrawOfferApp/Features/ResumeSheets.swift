import AppKit
import DrawOfferCore
import SwiftUI
import UniformTypeIdentifiers

/// 重命名（Figma 03 页 02.1e，Web `RenameResumeDialog`）与复制为新简历。重命名只改列表标题，不写入正文；
/// 复制携带固定的 `client_request_id`，结果不确定时重试不会多复制一份。
struct ResumeTitleSheet: View {
    enum Mode { case rename, copy }
    @Environment(SessionStore.self) private var session
    let mode: Mode
    let resume: ResumeSummary
    let close: () -> Void
    let done: (String) -> Void
    /// 02.1e 下方「想按另一个岗位改？复制为新简历 →」：给了才显示。
    var copy: (() -> Void)? = nil
    @State private var title = ""
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID().uuidString.lowercased()

    private var normalized: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 480 宽、内边距 32：标题 20/600 + 一句说明，96 高点阵舞台（小纸 + 正在改的名称签），「简历名称」灰字标签与 40 高灰底输入框；
    /// 重命名时下面一块「想按另一个岗位改？」带「复制为新简历 →」；右下取消 + 墨黑保存。
    var body: some View {
        ResumeSheetFrame(width: 480, close: close, closable: !busy) {
            ResumeSheetHead(title: mode == .rename ? "重命名简历" : "复制为新简历",
                            sub: mode == .rename ? "名称只给自己看，方便在列表里区分。" : "基于「\(resume.title)」的当前版本复制一份，原简历不受影响。")
            V3DotStage(height: 96) { ResumeRenameArt(name: normalized.isEmpty ? resume.title : normalized, copy: mode == .copy) }.padding(.top, 23)
            ResumeSheetField(label: "简历名称", placeholder: "例如：后端工程师 · 字节跳动", text: $title, error: error, disabled: busy, submit: submit)
                .onChange(of: title) { _, _ in error = nil; if mode == .copy { requestID = UUID().uuidString.lowercased() } }
                .padding(.top, 20)
            if mode == .rename, let copy {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("想按另一个岗位改？").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                        Text("复制后得到独立简历，两份内容互不影响。").font(V3.sans(11)).foregroundStyle(ResumeSheetStyle.hint)
                    }
                    Spacer()
                    Button(action: copy) {
                        HStack(spacing: 5) { Text("复制为新简历").font(V3.sans(12, weight: .medium)); Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)) }
                            .foregroundStyle(V3.txt).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(busy)
                }
                .padding(.horizontal, 17).frame(height: 59)
                .background(.white, in: RoundedRectangle(cornerRadius: 11.5)).overlay(RoundedRectangle(cornerRadius: 11.5).stroke(V3.cl))
                .padding(.top, 24)
            }
        } foot: {
            Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36, width: 79)).disabled(busy).keyboardShortcut(.cancelAction)
            Button(busy ? "正在保存…" : mode == .rename ? "保存名称" : "确认复制", action: submit)
                .buttonStyle(V3ButtonStyle(kind: .dark, height: 36))
                .disabled(busy || normalized.isEmpty || (mode == .rename && normalized == resume.title))
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

    /// Figma 03 页 02.1d：520 宽、内边距 32。标题 + 说明，116 高点阵舞台（简历 → 公开页），44 高灰底链接行（链接图标 + 地址 + 墨黑「复制链接」），
    /// 一行状态（绿点「链接可用 · 有效至…」），圆角 12 的设置块（谁可以查看 / 链接有效期 / 允许下载 PDF）；
    /// 左下「重新生成链接」「删除链接」，右下「完成」。还没有链接时设置块在前，右下「取消」+「创建分享链接」。
    var body: some View {
        ResumeSheetFrame(width: 520, close: close, closable: !busy) {
            ResumeSheetHead(title: "分享简历", sub: "为「\(resume.title)」生成只读链接，对方不用登录就能查看。")
            V3DotStage(height: 116) { ResumeShareArt(isPublic: share?.isPublic ?? createPublic) }.padding(.top, 23)
            if !loaded && !loadFailed {
                V3Loading("正在读取分享状态…").font(V3.sans(13)).frame(maxWidth: .infinity, minHeight: 120)
            } else if loadFailed {
                HStack {
                    Text("分享状态读取失败，请稍后重试。").font(V3.sans(13)).foregroundStyle(V3.red)
                    Spacer()
                    Button("重试") { Task { await load() } }.buttonStyle(V3ButtonStyle(kind: .ghost))
                }.frame(minHeight: 80)
            } else if let share { existing(share) }
            else { creation.padding(.top, 20) }
            if let error { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red).fixedSize(horizontal: false, vertical: true).padding(.top, 12) }
        } left: {
            if loaded, share != nil {
                Button { confirmRegenerate = true } label: {
                    HStack(spacing: 6) { Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .medium)); Text("重新生成链接") }
                }.buttonStyle(.plain).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub).disabled(busy)
                Button("删除链接") { confirmDelete = true }.buttonStyle(.plain).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.red).disabled(busy)
            }
        } foot: {
            if loaded && share == nil {
                Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36, width: 79)).keyboardShortcut(.cancelAction)
                Button(busy ? "正在创建…" : "创建分享链接") { Task { await create() } }.buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).disabled(busy)
            } else {
                Button("完成", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36, width: 87)).keyboardShortcut(.cancelAction)
            }
        }
            .task { await load() }
            .centeredConfirmation("重新生成分享链接？", isPresented: $confirmRegenerate) {
                Button("确认重新生成") { Task { await regenerate() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("重新生成后旧链接将立即失效，已转发的旧地址无法再访问。「\(resume.title)」的可见性与下载权限会保留。")
            }
            .centeredConfirmation("删除分享链接？", isPresented: $confirmDelete) {
                Button("确认删除", role: .destructive) { Task { await deleteShare() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后旧地址将显示「分享链接已失效」，之后可重新创建。「\(resume.title)」本身不受影响。")
            }
    }

    private var creation: some View {
        settings {
            row("谁可以查看", hint: createPublic ? "公开后，拿到链接的人都能打开" : "仅自己登录后可以打开") {
                ResumeShareSegment(options: [(true, "公开"), (false, "仅自己")], selection: createPublic) { createPublic = $0 }
            }
            row("链接有效期", hint: "到期后链接自动失效，可以重新生成") {
                ResumeShareSegment(options: Expiry.allCases.map { ($0, $0.rawValue) }, selection: createExpiry) { createExpiry = $0 }
            }
            row("允许下载 PDF", hint: createAllowDownload ? "关闭后，公开页面不显示下载入口" : "关闭后，任何访问者（包括分享者）均不可下载") {
                Toggle("允许下载 PDF", isOn: $createAllowDownload).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
        }.disabled(busy)
    }

    private func existing(_ share: ResumeShare) -> some View {
        let expired = share.isExpired()
        let link = origin.map { share.url(origin: $0).absoluteString } ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "link").font(.system(size: 11)).foregroundStyle(V3.sub)
                Text(expired ? "该分享链接已失效，访客将无法继续访问简历" : link.replacingOccurrences(of: "https://", with: ""))
                    .font(V3.sans(13)).foregroundStyle(expired ? V3.fnt : V3.txt).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                Button(expired ? "不可复制" : copied ? "已复制" : "复制链接") { copy(link) }
                    .buttonStyle(V3ButtonStyle(kind: .dark, height: 36, width: 100)).disabled(expired || link.isEmpty)
            }.padding(.leading, 16).padding(.trailing, 4).frame(height: 44).background(V3.field, in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 6) {
                Circle().fill(expired ? V3.red : V3.green).frame(width: 6, height: 6)
                Text(expired ? "链接已过期" : "链接可用").font(V3.sans(11.5, weight: .medium)).foregroundStyle(V3.sub)
                Text(expiryLabel(share)).font(V3.sans(11.5)).foregroundStyle(ResumeSheetStyle.hint)
            }.padding(.leading, 14).padding(.top, 12)
            settings {
                row("谁可以查看", hint: share.isPublic ? "公开后，拿到链接的人都能打开" : "仅自己登录后可以打开") {
                    ResumeShareSegment(options: [(true, "公开"), (false, "仅自己")], selection: share.isPublic) { value in
                        Task { await update(["visibility": .string(value ? "public" : "private")]) }
                    }
                }
                row("链接有效期", hint: "到期后链接自动失效，可以重新生成") {
                    // 已有链接按剩余时长对应到最接近的一档；点哪档就从现在起重新算
                    ResumeShareSegment(options: Expiry.allCases.map { ($0, $0.rawValue) }, selection: Self.closest(share)) { option in
                        Task { await update(["expires_at": ResumeShare.encode(option.date())]) }
                    }
                }
                row("允许下载 PDF", hint: share.allowDownload ? "关闭后，公开页面不显示下载入口" : "关闭后，任何访问者（包括分享者）均不可下载") {
                    Toggle("允许下载 PDF", isOn: Binding(get: { share.allowDownload }, set: { value in
                        Task { await update(["allow_download": .bool(value)]) }
                    })).toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
            }.padding(.top, 21)
        }.disabled(busy).padding(.top, 20)
    }

    /// 设置块：白底、#e4e4e0 细边、圆角 12，三行之间细线分隔。
    private func settings<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 17)
            .background(.white, in: RoundedRectangle(cornerRadius: 11.5)).overlay(RoundedRectangle(cornerRadius: 11.5).stroke(V3.cl))
    }

    private func row<Control: View>(_ title: String, hint: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                Text(hint).font(V3.sans(11)).foregroundStyle(ResumeSheetStyle.hint)
            }
            Spacer(minLength: 8)
            control()
        }.frame(height: 60)
    }

    private static func closest(_ share: ResumeShare) -> Expiry {
        guard let expiresAt = share.expiresAt else { return .forever }
        return expiresAt.timeIntervalSinceNow > 8 * 86_400 ? .month : .week
    }

    private func expiryLabel(_ share: ResumeShare) -> String {
        guard let expiresAt = share.expiresAt else { return "永久有效" }
        let formatter = Beijing.formatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
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

    /// Figma 03 页 02.1a：760×660、内边距 32。标题 20/600 + 一句说明；①「选择模板」右侧「1 / 8」，276 高点阵舞台里
    /// 168×222 的白卡放模板缩略图、下方模板名，左右 36 圆形翻页钮（← → 键）；②「简历名称」右侧一句说明，43 高输入框（聚焦墨黑边），
    /// 下方常用写法；分隔线下左侧提示，右侧取消 79 与墨黑「创建并进入编辑器」148。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ResumeSheetHead(title: "新建简历", sub: "选一套模板，再起个名字，创建后直接进入编辑器。")
                stepTitle(1, "选择模板", active: true) {
                    if !templates.isEmpty {
                        Text("\(index + 1) / \(templates.count)").font(V3.number(11.5, weight: .medium)).foregroundStyle(ResumeSheetStyle.hint)
                            .accessibilityLabel("当前模板位置")
                    }
                }.padding(.top, 27)
                stage.padding(.top, 12)
                stepTitle(2, "简历名称", active: false) {
                    Text("只给自己看，方便在列表里区分").font(V3.sans(11.5)).foregroundStyle(ResumeSheetStyle.hint)
                }.padding(.top, 28)
                TextField("", text: $title)
                    .textFieldStyle(.plain).font(V3.sans(13.5)).foregroundStyle(V3.txt).focused($titleFocused).accessibilityLabel("简历名称")
                    .overlay(alignment: .leading) {
                        if title.isEmpty { Text("例如：后端工程师 · 字节跳动").font(V3.sans(13.5)).foregroundStyle(V3.fnt2).allowsHitTesting(false) }
                    }
                    .padding(.horizontal, 13).frame(height: 43)
                    .background(.white, in: RoundedRectangle(cornerRadius: 9.25))
                    .overlay(RoundedRectangle(cornerRadius: 9.25).stroke(error != nil ? V3.red : titleFocused ? V3.txt : V3.cl))
                    .disabled(busy).onSubmit { submit() }
                    .onChange(of: title) { if title.count > 255 { title = String(title.prefix(255)) }; error = nil }
                    .padding(.top, 13)
                Text(error ?? "常用写法：岗位 · 公司，例如「产品经理 · 美团」").font(V3.sans(11)).foregroundStyle(error != nil ? V3.red : ResumeSheetStyle.hint)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }.padding(.horizontal, 32).padding(.top, 31)
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                Text("模板之后可以在编辑器里随时切换").font(V3.sans(11.5)).foregroundStyle(ResumeSheetStyle.hint).lineLimit(1)
                Spacer()
                Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36, width: 79)).disabled(busy).keyboardShortcut(.cancelAction)
                Button(busy ? "正在创建…" : "创建并进入编辑器", action: submit).buttonStyle(V3ButtonStyle(kind: .dark, height: 36, width: 148))
                    .disabled(busy || loading || loadFailed || selected == nil)
            }
            .padding(.horizontal, 32).frame(height: 88)
            .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
        }
        .frame(width: 760, height: 660)
        .onKeyPress(.leftArrow) { guard !titleFocused else { return .ignored }; move(-1); return .handled }
        .onKeyPress(.rightArrow) { guard !titleFocused else { return .ignored }; move(1); return .handled }
        .onAppear { titleFocused = true }
        .task { await load() }
    }

    /// 步骤标题：20 圆形序号（当前一步墨黑底白字，其余灰底），13/500 标题，右侧补充。
    private func stepTitle<Trailing: View>(_ number: Int, _ title: String, active: Bool, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Text("\(number)").font(V3.number(10.5, weight: .semibold)).foregroundStyle(active ? .white : V3.sub)
                .frame(width: 20, height: 20).background(active ? V3.txt : V3.field, in: Circle())
            Text(title).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
            Spacer()
            trailing()
        }.frame(height: 20)
    }

    private var stage: some View {
        V3DotStage(height: 276) {
            if loading { Text("正在加载简历模板…").font(V3.sans(12.5)).foregroundStyle(V3.sub) }
            else if loadFailed {
                VStack(spacing: 12) {
                    Text("模板暂时无法加载，请检查网络后重试。").font(V3.sans(12.5)).foregroundStyle(V3.sub)
                    Button { Task { await load() } } label: { Label("重新加载", systemImage: "arrow.clockwise") }.buttonStyle(V3ButtonStyle(kind: .ghost))
                }
            } else if templates.isEmpty {
                Text("当前没有可用模板，暂时无法新建简历。").font(V3.sans(12.5)).foregroundStyle(V3.sub)
            } else if let selected {
                VStack(spacing: 10) {
                    TemplateThumbnail(template: selected, guest: false).id(selected.id)
                        .frame(width: 139)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(V3.cl))
                        .accessibilityElement(children: .ignore).accessibilityLabel("\(selected.name)，已选择")
                    Text(([selected.name] + selected.styleCategories.prefix(1)).joined(separator: " · ")).font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
                }.padding(.top, 2)
                HStack(spacing: 216) {
                    navButton("chevron.left", "上一个模板") { move(-1) }
                    navButton("chevron.right", "下一个模板") { move(1) }
                }.offset(y: -8)
            }
        }
    }

    private func navButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(V3.sub)
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

/// 03 页弹窗外框：内边距 32（上 31），正文在上；底部左侧文字链、右侧按钮（取消 + 墨黑主按钮），不画分隔线。
/// Esc 关闭（不画右上角 ×，与 `V3Dialog` 一致）。
struct ResumeSheetFrame<Content: View, Left: View, Foot: View>: View {
    let width: CGFloat
    let close: () -> Void
    var closable = true
    @ViewBuilder var content: () -> Content
    @ViewBuilder var left: () -> Left
    @ViewBuilder var foot: () -> Foot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) { content() }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                HStack(spacing: 20) { left() }
                Spacer(minLength: 12)
                foot()
            }.padding(.top, 32)
        }
        .padding(.horizontal, 32).padding(.top, 31).padding(.bottom, 32)
        .frame(width: width)
        .background {
            if closable { Button("", action: close).keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
        }
    }
}

extension ResumeSheetFrame where Left == EmptyView {
    init(width: CGFloat, close: @escaping () -> Void, closable: Bool = true,
         @ViewBuilder content: @escaping () -> Content, @ViewBuilder foot: @escaping () -> Foot) {
        self.init(width: width, close: close, closable: closable, content: content, left: { EmptyView() }, foot: foot)
    }
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

/// 分享设置里的分段：30 高 #f4f4f2 底、圆角 8，选中项 24 高白块、圆角 6、12/500。
struct ResumeShareSegment<Value: Hashable>: View {
    let options: [(Value, String)]
    let selection: Value
    let change: (Value) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.0 == selection
                Button { if !on { change(option.0) } } label: {
                    Text(option.1).font(V3.sans(12, weight: on ? .medium : .regular)).foregroundStyle(on ? V3.txt : V3.sub)
                        .padding(.horizontal, 12).frame(height: 24)
                        .background(on ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(on ? 0.06 : 0), radius: 1, y: 0.5)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }.padding(3).background(V3.field, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 一张小简历纸（标题条 + 几道灰线），弹窗插图用。
private struct ResumeSheetPaper: View {
    var width: CGFloat = 50
    var height: CGFloat = 68
    var body: some View {
        VStack(alignment: .leading, spacing: height * 0.05) {
            RoundedRectangle(cornerRadius: 1).fill(V3.txt).frame(width: width * 0.42, height: max(3, height * 0.06))
            RoundedRectangle(cornerRadius: 1).fill(Color(hex: 0xDCDCD8)).frame(width: width * 0.6, height: 2)
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1).fill(V3.line).frame(width: width * (index == 3 ? 0.45 : 0.7), height: 2)
            }
        }
        .padding(width * 0.14).frame(width: width, height: height, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).stroke(V3.cl))
    }
}

/// 02.1e 插图：小纸 + 正在改的名称签（墨黑细边）+ 右上一个笔形角标。
private struct ResumeRenameArt: View {
    let name: String
    var copy = false
    var body: some View {
        HStack(spacing: 16) {
            ResumeSheetPaper()
            Text(name).font(V3.sans(11.5, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 12).frame(width: 160, height: 34, alignment: .leading)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 7.25).stroke(V3.txt))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: copy ? "plus.square.on.square" : "pencil").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(V3.txt, in: Circle()).offset(x: 10, y: -12)
                }
        }.accessibilityHidden(true)
    }
}

/// 02.1d 插图：简历纸 → 虚线箭头 → 公开页（顶部地址栏），右上「公开 / 仅自己」小签。
private struct ResumeShareArt: View {
    let isPublic: Bool
    var body: some View {
        HStack(spacing: 14) {
            ResumeSheetPaper(width: 62, height: 84)
            Canvas { context, _ in
                var line = Path(); line.move(to: CGPoint(x: 2, y: 4)); line.addLine(to: CGPoint(x: 31, y: 4))
                context.stroke(line, with: .color(Color(hex: 0xB9B9B3)), style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                var head = Path(); head.move(to: CGPoint(x: 31, y: 0.5)); head.addLine(to: CGPoint(x: 35, y: 4)); head.addLine(to: CGPoint(x: 31, y: 7.5))
                context.stroke(head, with: .color(Color(hex: 0xB9B9B3)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }.frame(width: 37, height: 8)
            VStack(spacing: 0) {
                HStack {
                    Text("drawoffer.cn/s/…").font(.system(size: 7)).foregroundStyle(ResumeSheetStyle.hint)
                        .padding(.horizontal, 6).frame(width: 108, height: 10, alignment: .leading).background(.white, in: Capsule())
                }.frame(maxWidth: .infinity).frame(height: 18).background(V3.field)
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 1).fill(V3.txt).frame(width: 40, height: 4)
                    ForEach(0..<4, id: \.self) { index in RoundedRectangle(cornerRadius: 1).fill(V3.line).frame(width: index == 3 ? 60 : 110, height: 2) }
                }.padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(width: 156, height: 80, alignment: .top)
            .background(.white).clipShape(RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(V3.cl))
            .overlay(alignment: .topTrailing) {
                Text(isPublic ? "公开" : "仅自己").font(V3.sans(10, weight: .medium)).foregroundStyle(V3.sub)
                    .padding(.horizontal, 10).frame(height: 20).background(.white, in: Capsule()).overlay(Capsule().stroke(V3.cl))
                    .offset(x: 26, y: -10)
            }
        }.accessibilityHidden(true)
    }
}

/// 删除确认（Figma 03 页 02.1f · NSAlert）：420 宽、内边距 24；128 高点阵舞台（三张纸、中间一张压垃圾桶角标），
/// 居中标题 18/600 与「名称 · 删除后无法恢复」，灰底影响清单（分享链接失效 / 求职记录解除关联 / 其他简历不受影响），
/// 底部等宽「取消」与红色「删除」。
struct ResumeDeleteSheet: View {
    let resume: ResumeSummary
    let busy: Bool
    let delete: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            V3DotStage(height: 128) {
                ZStack {
                    ResumeSheetPaper().offset(x: -61, y: 4).opacity(0.85)
                    ResumeSheetPaper().offset(x: 61, y: 4).opacity(0.85)
                    ResumeSheetPaper(width: 58, height: 80)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "trash").font(.system(size: 10, weight: .medium)).foregroundStyle(V3.red)
                                .frame(width: 30, height: 30).background(.white, in: Circle()).overlay(Circle().stroke(Color(hex: 0xF3D6D6)))
                                .offset(x: 13, y: 10)
                        }
                }.accessibilityHidden(true)
            }
            Text("删除这份简历？").font(.system(size: 18, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 26).padding(.top, 23)
            Text("\(resume.title) · 删除后无法恢复").font(V3.sans(12.5)).foregroundStyle(V3.sub).lineLimit(2).multilineTextAlignment(.center).padding(.top, 3)
            VStack(alignment: .leading, spacing: 12) {
                impact("link", "公开分享链接会立即失效")
                impact("briefcase", "关联的求职记录会解除关联")
                impact("doc.text", "其他简历不受影响")
            }
            .padding(.horizontal, 18).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
            .background(V3.field, in: RoundedRectangle(cornerRadius: 10)).padding(.top, 17)
            HStack(spacing: 12) {
                Button("取消", action: cancel).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36, fill: true)).disabled(busy).keyboardShortcut(.cancelAction)
                Button(busy ? "正在删除…" : "删除", action: delete).buttonStyle(V3ButtonStyle(kind: .danger, height: 36, fill: true)).disabled(busy)
            }.padding(.top, 31)
        }
        .padding(24).frame(width: 420)
    }

    private func impact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(V3.sub).frame(width: 12)
            Text(text).font(V3.sans(12)).foregroundStyle(V3.sub)
        }
    }
}
