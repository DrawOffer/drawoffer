import AppKit
import DrawOfferCore
import DrawOfferRender
import SwiftUI

/// 「我的简历」：按 Web `features/home/HomePage.tsx` 的 02.1 列表结构，读取本人简历、预览纸面、导出 PDF，
/// 并提供编辑、导入、重命名、复制、分享与删除。新建经模板页；编辑进入原生编辑器（正文、格式、版式与模板）。
struct ResumesView: View {
    @Environment(SessionStore.self) private var session
    /// 刚创建的简历：列表加载后自动打开预览。
    @Binding var focusResumeID: String?
    /// 正在编辑的简历；首页“继续编辑”也通过它直接进入编辑器。
    @Binding var editResumeID: String?
    /// 首页“选择文件”：每次变化打开一次导入。
    var importRequest: UUID? = nil

    @State private var resumes: [ResumeSummary] = []
    @State private var defaultID: String?
    @State private var creating = false
    @State private var importSheet = false
    @State private var loadedAccount: String?
    @State private var loading = false
    @State private var loadError = false
    @State private var reload = UUID()
    @State private var query = ""
    @State private var preview: ResumeSummary?
    @State private var exportingID: String?
    @State private var notice: (text: String, failed: Bool)?
    @State private var renaming: ResumeSummary?
    @State private var copying: ResumeSummary?
    @State private var sharing: ResumeSummary?
    @State private var deleting: ResumeSummary?
    @State private var deleteBusy = false
    @State private var imports: [JSONValue] = []
    @State private var importPoll: UUID?
    @State private var importTries = 0
    private var atLimit: Bool { loaded && resumes.count >= ResumeRequest.maximumPerUser }

    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }
    private var loaded: Bool { !account.isEmpty && loadedAccount == account }
    private var visible: [ResumeSummary] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? resumes : resumes.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        if let editResumeID, !account.isEmpty {
            ResumeEditorView(resumeID: editResumeID, close: { self.editResumeID = nil; reload = UUID() }).id(editResumeID)
        } else { listPage }
    }

    private var listPage: some View {
        // Figma 03 页 02.1：内容区距顶 64（眉题），标题 28 衬线，说明 13；右上「导入简历」+ 墨黑「新建简历」。
        V3Page(top: 64) {
            VStack(alignment: .leading, spacing: 0) {
                ResumesHead(count: loaded ? "\(resumes.count) 份" : "个人工作区", loading: !loaded && !loadError && !account.isEmpty,
                            subtitle: atLimit ? "已达到 \(ResumeRequest.maximumPerUser) 份上限。删除不用的简历后，才能新建、导入或复制。" : "每份简历独立编辑，需要时复制一份按岗位修改。",
                            warn: atLimit) {
                    if !account.isEmpty {
                        Button { importSheet = true } label: { Label("导入简历", systemImage: "square.and.arrow.up") }
                            .buttonStyle(ResumesPillStyle(dark: false)).disabled(atLimit)
                        Button(action: checkCapacityThenBrowse) { Label("新建简历", systemImage: "plus") }
                            .buttonStyle(ResumesPillStyle(dark: true))
                    }
                }
                if loadError && !loaded { loadFailure }
                else if !loaded { skeleton }
                else if resumes.isEmpty && imports.isEmpty { emptyList }
                else { list }
            }
        }
        .overlay(alignment: .top) {
            TextNoticeToast(text: Binding(get: { notice?.text }, set: { if $0 == nil { notice = nil } }),
                            kind: { text in notice?.text == text && notice?.failed == true ? .failed : .done })
        }
        .task(id: "\(account)|\(reload)") { await load() }
        .task(id: importPoll) { if importPoll != nil { await pollImports() } }
        .task(id: importRequest) { if importRequest != nil, !account.isEmpty { importSheet = true } }
        .centeredSheet(isPresented: $importSheet) {
            ResumeImportSheet(close: { importSheet = false }, accepted: { title in
                importSheet = false
                notice = ("已开始导入「\(title)」，解析完成后会出现在列表中。", false)
                Task { await loadImports(owner: account) }
            })
        }
        .onChange(of: account) { _, _ in
            // 退出或切换账号：清理上一账号的列表、预览与提示
            resumes = []; loadedAccount = nil; preview = nil; exportingID = nil; notice = nil; query = ""; loadError = false; imports = []
        }
        .centeredSheet(item: $preview) { resume in
            ResumePreviewSheet(resume: resume, exporting: exportingID == resume.id,
                               export: { Task { await exportPDF(resume) } },
                               share: { preview = nil; sharing = resume }, edit: { preview = nil; editResumeID = resume.id }, close: { preview = nil })
                .frame(width: 960, height: 720)
        }
        .centeredSheet(item: $renaming) { resume in
            ResumeTitleSheet(mode: .rename, resume: resume, close: { renaming = nil }, done: { title in
                renaming = nil; notice = ("已将简历重命名为「\(title)」", false); reload = UUID()
            }, copy: { renaming = nil; checkCapacity { copying = resume } })
        }
        .centeredSheet(item: $copying) { resume in
            ResumeTitleSheet(mode: .copy, resume: resume, close: { copying = nil }, done: { title in
                copying = nil; notice = ("已复制为「\(title)」", false); reload = UUID()
            })
        }
        .centeredSheet(isPresented: $creating) {
            ResumeCreateSheet(close: { creating = false }, created: { id in
                creating = false; reload = UUID()
                if !id.isEmpty { editResumeID = id }
            })
        }
        .centeredSheet(item: $sharing) { resume in
            ResumeShareSheet(resume: resume, close: { sharing = nil })
        }
        .centeredSheet(item: $deleting) { resume in
            ResumeDeleteSheet(resume: resume, busy: deleteBusy, delete: { Task { await delete(resume) } },
                              cancel: { if !deleteBusy { deleting = nil } })
        }
    }

    /// 02.1 工具行：距头部 32、高 30；「全部简历」16/600（Web `.hv3-toolbar-title` --ui-text-md），数字 11 灰；搜索 220×30、圆角 7、#f4f4f2 底。
    /// 加载中数字是一条 20 宽的文字占位（Web `<LoadingText width={20} />`），搜索框照常显示。
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 0) {
                    Text("全部简历  ").font(V3.sans(16, weight: .semibold)).foregroundStyle(V3.txt)
                    if loaded { Text("\(resumes.count)").font(V3.number(11, weight: .medium)).foregroundStyle(resumesHint) }
                    else { V3LoadingText(width: 20, size: 11) }
                }
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(V3.fnt)
                    TextField("搜索简历…", text: $query).textFieldStyle(.plain).font(V3.sans(12)).accessibilityLabel("搜索简历")
                }.padding(.horizontal, 12).frame(width: 220, height: 30)
                    .background(V3.field, in: RoundedRectangle(cornerRadius: 7))
            }.frame(height: 30).padding(.top, 32)
            Rectangle().fill(V3.line).frame(height: 1).padding(.top, 2)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            if visible.isEmpty {
                // 02.1 ③ 搜索没有结果：三张小纸 + 放大镜，标题 17/500，说明 13，「清除搜索」胶囊
                VStack(spacing: 0) {
                    ResumesSearchArt()
                    Text("没有找到「\(query.trimmingCharacters(in: .whitespaces))」").font(V3.sans(17, weight: .medium)).foregroundStyle(V3.txt).padding(.top, 42)
                    Text("试试更短的关键词，比如公司名或岗位名；也可以回到「全部」查看所有简历。").font(V3.sans(13)).foregroundStyle(V3.sub).padding(.top, 13)
                    Button { query = "" } label: {
                        HStack(spacing: 6) { Image(systemName: "magnifyingglass").font(.system(size: 10)); Text("清除搜索").font(V3.sans(13)) }
                            .foregroundStyle(V3.txt).padding(.horizontal, 16).frame(height: 31)
                            .background(.white, in: Capsule()).overlay(Capsule().stroke(V3.cl)).contentShape(Capsule())
                    }.buttonStyle(.plain).padding(.top, 27)
                }.frame(maxWidth: .infinity).padding(.top, 160)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 199), spacing: 20, alignment: .top)], alignment: .leading, spacing: 37) {
                    if query.isEmpty {
                        ForEach(imports, id: \.self) { task in importCard(task) }
                    }
                    ForEach(visible) { resume in
                        ResumeCard(resume: resume, exporting: exportingID == resume.id, atLimit: atLimit,
                                   isDefault: ResumeRequest.defaultResume(resumes, defaultID)?.id == resume.id,
                                   setDefault: { Task { await setDefault(resume) } },
                                   open: { editResumeID = resume.id }, preview: { preview = resume }, export: { Task { await exportPDF(resume) } },
                                   rename: { renaming = resume }, copy: { checkCapacity { copying = resume } },
                                   share: { sharing = resume }, delete: { deleting = resume })
                    }
                    if query.isEmpty {
                        // 02.1 ② 达到上限时这一格变成「已达 10 份上限」，不能点
                        Button(action: checkCapacityThenBrowse) {
                            // 以虚线纸为底定尺寸（形状会占满列宽），和简历缩略图一样高；只靠文字时按钮会缩成一条
                            RoundedRectangle(cornerRadius: 6).fill(.white).aspectRatio(210.0 / 297, contentMode: .fit)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0xC9C9C3), style: StrokeStyle(lineWidth: 1, dash: [4])))
                                .overlay {
                                    VStack(spacing: 12) {
                                        Image(systemName: "plus").font(.system(size: 14, weight: .light))
                                        Text(atLimit ? "已达 \(ResumeRequest.maximumPerUser) 份上限" : "新建空白简历").font(V3.sans(12))
                                    }.foregroundStyle(atLimit ? resumesHint.opacity(0.7) : resumesHint)
                                }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(atLimit).accessibilityLabel(atLimit ? "已达简历上限" : "新建空白简历")
                    }
                }.padding(.top, 18)
            }
        }
    }

    /// Web「我的简历」数据加载占位：工具行照常显示，下面 4 张卡——#F4F4F2 纸面（同一道扫光）+ 名称 128×14、时间 72×11 两条占位，
    /// 与真实卡片（ResumeCard）同间距。
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 199), spacing: 20, alignment: .top)], alignment: .leading, spacing: 37) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { box in V3Skeleton(width: box.size.width, height: box.size.height, radius: 6, color: V3.field) }
                            .aspectRatio(210.0 / 297, contentMode: .fit)
                        V3Skeleton(width: 128, height: 14, radius: 3).frame(height: 16).padding(.top, 4)
                        V3Skeleton(width: 72, height: 11, radius: 3)
                    }
                }
            }.padding(.top, 18)
        }.accessibilityElement(children: .contain).accessibilityLabel("正在加载我的简历…")
    }

    /// `.hv3-load-error`：分隔线距头部 58，下方 55 处 480 宽的卡片，150 高点阵舞台，112×36 的「重新加载」。
    private var loadFailure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(V3.line).frame(height: 1).padding(.top, 58)
            V3EmptyCard(title: "简历列表没能加载出来", message: "网络不稳定或服务暂时不可用，你的简历都还在，刷新一下试试。",
                        stageHeight: 150, width: 480, inset: 8, messageTop: 8, actionsTop: 13) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").font(.system(size: 18)).foregroundStyle(V3.sub)
                    .frame(width: 56, height: 48).background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(V3.cl)).shadow(color: .black.opacity(0.08), radius: 6, y: 4)
            } actions: {
                Button { reload = UUID() } label: { Label("重新加载", systemImage: "arrow.clockwise") }
                    .buttonStyle(V3ButtonStyle(kind: .ghost, height: 36, width: 112)).disabled(loading)
            }.padding(.top, 55)
        }.accessibilityElement(children: .contain)
    }

    /// 02.1 空列表：分隔线下居中一张小纸（两侧「教育经历」「项目经历」小模块），标题 17/500「还没有简历」，两行 13 号说明；
    /// 入口就是右上角两个按钮，不在空态里重复。
    private var emptyList: some View {
        VStack(spacing: 0) {
            Rectangle().fill(V3.line).frame(height: 1).padding(.top, 24)
            VStack(spacing: 0) {
                ResumesBlankArt()
                Text("还没有简历").font(V3.sans(17, weight: .medium)).foregroundStyle(V3.txt).padding(.top, 36)
                Text("用右上角「新建简历」选一套模板开始，每份简历都能复制一份按岗位修改。\n已有简历文件，可以用「导入简历」直接读进来。")
                    .font(V3.sans(13)).foregroundStyle(V3.sub).multilineTextAlignment(.center).lineSpacing(5).padding(.top, 13)
            }.frame(maxWidth: .infinity).padding(.top, 222)
        }.accessibilityElement(children: .contain)
    }

    private func load() async {
        let owner = account
        guard !owner.isEmpty else { return }
        loading = true; loadError = false
        defer { if owner == account { loading = false } }
        do {
            guard let client = session.api as? HTTPAPIClient else { return }
            // 导入任务卡（`resume-overview`）与简历列表互不依赖：一起读，列表到了先画，任务卡随后补上（Web 一次读 overview 拿到两者）
            async let overview = try? client.careerRequest(path: "/api/resume-overview", method: "GET", query: [:], body: nil)
            let page = try await client.listResumePage()
            let result = page.resumes
            try Task.checkCancellation()
            guard owner == account else { return }
            resumes = result; defaultID = page.defaultID; loadedAccount = owner
            await applyImports(await overview, owner: owner)
            if let current = preview { preview = result.first { $0.id == current.id } }
            if let focus = focusResumeID {
                focusResumeID = nil
                if let created = result.first(where: { $0.id == focus }) {
                    preview = created; notice = ("已创建「\(created.title)」", false)
                }
            }
        } catch is CancellationError {
        } catch {
            guard owner == account else { return }
            if case APIError.unauthorized = error { session.reportAuthenticationFailure(); return }
            loadError = true
            if loaded { notice = ("刷新简历列表失败，当前显示的是上次读取的结果。", true) }
        }
    }

    // MARK: Import

    /// 导入任务卡（`GET /api/resume-overview` 的进行中与失败任务）；有进行中的任务时每 3 秒刷新，完成后刷新列表。
    private func loadImports(owner: String) async {
        await applyImports(try? await session.api.careerRequest(path: "/api/resume-overview", method: "GET", query: [:], body: nil), owner: owner)
    }

    private func applyImports(_ overview: JSONValue?, owner: String) async {
        guard let overview, owner == account else { return }
        let active = overview["active_imports"]?.items ?? []
        let previousActive = imports.filter { $0.text("upload_status") != "failed" && $0.text("parse_status") != "failed" }.count
        imports = active + (overview["failed_imports"]?.items ?? [])
        // 有任务结束（成功生成简历或失败）时刷新简历列表
        if previousActive > active.count { await session.api.purgeCache(); reload = UUID() }
        if active.isEmpty { importTries = 0 } else { importPoll = UUID() }
    }

    private func pollImports() async {
        let owner = account
        guard !owner.isEmpty, !imports.isEmpty else { return }
        // 3 秒起逐步放慢到 20 秒；App 不在前台时暂停
        guard await Polling.wait(importTries, first: 3, cap: 20, topic: "parse_task"), owner == account else { return }
        importTries += 1
        await loadImports(owner: owner)
    }

    /// 02.1c 导入任务卡：#f4f4f2 圆角底里一张白纸，中间一个白色状态签（解析中带转圈）；失败时淡红底、红边、红字，右下「移除记录」。
    private func importCard(_ task: JSONValue) -> some View {
        let failed = task.text("upload_status") == "failed" || task.text("parse_status") == "failed"
        let stage = task.text("upload_status") == "uploading" ? "正在上传" : "正在解析"
        let label = failed ? (task.text("upload_status") == "failed" ? "上传失败" : "解析失败") : (task.text("upload_status") == "uploading" ? "上传中" : "解析中")
        let failLine = Color(hex: 0xF3D6D6)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5).fill(.white).overlay(RoundedRectangle(cornerRadius: 3.5).stroke(V3.cl))
                    .padding(.horizontal, 23).padding(.vertical, 19)
                HStack(spacing: 6) {
                    if !failed { ProgressView().controlSize(.mini) }
                    Text(label).font(V3.sans(11.5, weight: .medium)).foregroundStyle(failed ? V3.red : V3.txt)
                }
                .padding(.horizontal, 14).frame(height: failed ? 28 : 32)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(failed ? failLine : V3.cl))
            }
            .frame(maxWidth: .infinity).aspectRatio(210.0 / 297, contentMode: .fit)
            .background(failed ? Color(hex: 0xFDF5F5) : V3.field, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(failed ? failLine : .clear))
            Text(task.text("source_filename")).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 16).padding(.top, 4)
            HStack {
                Text(failed ? "\(label) · 可以移除后重新导入" : "\(stage) · 请稍候").font(V3.sans(11)).foregroundStyle(failed ? V3.red : resumesHint).lineLimit(1)
                Spacer(minLength: 4)
                if failed {
                    Button("移除记录") { Task { await deleteImport(task) } }.buttonStyle(V3ButtonStyle(kind: .ghost, height: 25, small: true))
                }
            }
        }
    }

    private func deleteImport(_ task: JSONValue) async {
        do {
            _ = try await session.api.careerRequest(path: "/api/resume-imports/\(task.text("id"))", method: "DELETE", query: [:], body: nil)
            imports.removeAll { $0.text("id") == task.text("id") }
            notice = ("已删除「\(task.text("source_filename"))」的失败记录", false)
        } catch { notice = ("删除失败记录失败，请稍后重试。", true) }
    }

    private func exportPDF(_ resume: ResumeSummary) async {
        guard exportingID == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = ResumesView.fileName(resume.title)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let owner = account
        exportingID = resume.id; notice = nil
        defer { if owner == account { exportingID = nil } }
        do {
            let data = try await session.api.downloadResumePDF(id: resume.id, lockVersion: resume.lockVersion)
            guard owner == account else { return }
            try data.write(to: destination, options: .atomic)
            notice = ("已导出「\(resume.title)」", false)
        } catch {
            guard owner == account, !(error is CancellationError) else { return }
            if case APIError.unauthorized = error { session.reportAuthenticationFailure(); return }
            if case APIError.server(_, "RESUME_PDF_SNAPSHOT_STALE") = error {
                notice = ("简历已在其他设备更新，已刷新列表，请重新导出。", true); reload = UUID()
            } else if case APIError.server(_, "RESUME_NOT_FOUND") = error {
                notice = ("这份简历已不存在，已刷新列表。", true); preview = nil; reload = UUID()
            } else if error is CocoaError {
                notice = ("PDF 已生成，但保存到所选位置失败，请换个位置重试。", true)
            } else {
                notice = ("导出 PDF 失败，请稍后重试。", true)
            }
        }
    }

    private func delete(_ resume: ResumeSummary) async {
        guard !deleteBusy else { return }
        let owner = account
        deleteBusy = true
        defer { if owner == account { deleteBusy = false; deleting = nil } }
        do {
            _ = try await session.api.careerRequest(path: "/api/resumes/\(resume.id)", method: "DELETE", query: [:], body: nil)
            guard owner == account else { return }
            resumes.removeAll { $0.id == resume.id }
            if preview?.id == resume.id { preview = nil }
            notice = ("已删除「\(resume.title)」", false); reload = UUID()
        } catch {
            guard owner == account, !(error is CancellationError) else { return }
            if case APIError.unauthorized = error { session.reportAuthenticationFailure(); return }
            if case APIError.server(404, _) = error { notice = ("这份简历已不存在，已刷新列表。", true); reload = UUID(); return }
            notice = ("删除「\(resume.title)」失败，请刷新列表确认后重试。", true)
        }
    }

    /// 设为默认简历（`PUT /api/resumes/{id}/default`）：模拟面试、岗位匹配等默认用它。
    private func setDefault(_ resume: ResumeSummary) async {
        let owner = account
        do {
            _ = try await session.api.careerRequest(path: "/api/resumes/\(resume.id)/default", method: "PUT", query: [:], body: nil)
            guard owner == account else { return }
            defaultID = resume.id
            notice = ("已将「\(resume.title)」设为默认简历", false)
        } catch {
            guard owner == account else { return }
            if case APIError.unauthorized = error { session.reportAuthenticationFailure(); return }
            notice = ("设为默认简历失败，请稍后重试。", true)
        }
    }

    /// 新建前的容量预检（`GET /api/resumes/capacity`）：已达上限时提示，不进入模板页。
    private func checkCapacityThenBrowse() { checkCapacity { creating = true } }

    /// Web `requestCreation`：新建与复制前先查容量，已满或查询失败都只提示、不继续。
    private func checkCapacity(_ proceed: @escaping @MainActor () -> Void) {
        Task {
            do {
                _ = try await session.api.careerRequest(path: "/api/resumes/capacity", method: "GET", query: [:], body: nil)
                proceed()
            } catch APIError.server(_, "RESUME_LIMIT_REACHED") {
                notice = ("简历数量已达上限（\(ResumeRequest.maximumPerUser) 份），请删除不需要的简历后重试。", true)
            } catch {
                notice = ("暂时无法检查简历数量，请稍后重试。", true)
            }
        }
    }

    /// 与后端 Content-Disposition 一致：保留中文标题，只替换文件系统不接受的字符。
    static func fileName(_ title: String) -> String {
        let cleaned = title.map { "/:\\\0".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "resume" : cleaned) + ".pdf"
    }
}

/// `.hv3-card`：A4 缩略纸面 + 标题 + 更新时间；悬停出现 ⋯ 菜单。
private struct ResumeCard: View {
    @Environment(SessionStore.self) private var session
    let resume: ResumeSummary
    let exporting: Bool
    let atLimit: Bool
    var isDefault = false
    var setDefault: () -> Void = {}
    let open: () -> Void
    let preview: () -> Void
    let export: () -> Void
    let rename: () -> Void
    let copy: () -> Void
    let share: () -> Void
    let delete: () -> Void
    @State private var hovered = false

    var body: some View {
        // `.hv3-card-meta`：纸面下 14、名称与时间间隔 6
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Button(action: open) { ResumeThumbnail(resume: resume) }
                    .buttonStyle(.plain).accessibilityLabel("打开 \(resume.title)")
                // 与 Web 同一组菜单：点卡片本身就能打开编辑，这里放「设为默认简历」（已是默认时不显示）
                Menu {
                    if !isDefault { Button("设为默认简历", systemImage: "pin", action: setDefault) }
                    Button("重命名", systemImage: "character.cursor.ibeam", action: rename)
                    Button("复制为新简历", systemImage: "doc.on.doc", action: copy)
                    Button("分享链接", systemImage: "link", action: share)
                    Button(exporting ? "正在导出…" : "导出 PDF", systemImage: "arrow.down.doc", action: export).disabled(exporting)
                    Divider()
                    Button("删除", systemImage: "trash", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(V3.txt).frame(width: 28, height: 28)
                        .background(.white, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(V3.cl))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .padding(8).opacity(hovered || exporting ? 1 : 0)
                    .accessibilityLabel("更多简历操作 \(resume.title)")
            }
            Text(resume.title).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 16).help(resume.title)
                .padding(.top, 4)
            HStack(spacing: 6) {
                if isDefault {
                    Text("默认").font(V3.sans(10.5, weight: .medium)).foregroundStyle(V3.blue)
                        .padding(.horizontal, 5).frame(height: 16).background(V3.blueSoft, in: RoundedRectangle(cornerRadius: 4))
                }
                Text(exporting ? "正在导出 PDF…" : "\(resume.updatedLabel()) · 已保存").font(V3.number(11, weight: .regular)).foregroundStyle(V3.fnt)
            }
        }.onHover { hovered = $0 }
    }
}

private struct ResumeThumbnail: View {
    @Environment(SessionStore.self) private var session
    let resume: ResumeSummary
    @State private var paper: ResumeRenderRequest?
    @State private var failed = false

    var body: some View {
        GeometryReader { geometry in
            if let paper {
                ResumePaperView(request: paper, onError: { _ in failed = true })
                    .frame(width: geometry.size.width, height: geometry.size.width * 1123 / 794)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .allowsHitTesting(false)
            } else if !failed { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
            if failed {
                Text("预览不可用").font(V3.sans(11)).foregroundStyle(V3.fnt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.aspectRatio(210.0 / 297, contentMode: .fit).background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0xD3D3CE)))
            .task(id: "\(resume.id)|\(resume.lockVersion)") {
                paper = nil; failed = false
                guard let request = resume.renderRequest() else { failed = true; return }
                // 同 Web 卡片：只画第一页；开着智能一页的也按不用智能一页时的第一页
                do { let result = try await session.api.preparePaper(request.firstPage()); try Task.checkCancellation(); paper = result.request }
                catch is CancellationError { }
                catch { failed = true }
            }
    }
}

/// 只读预览：连续纸面 + 导出 PDF。私有图片经桌面会话下载后注入，失败时保留正文并提示。
private struct ResumePreviewSheet: View {
    @Environment(SessionStore.self) private var session
    let resume: ResumeSummary
    let exporting: Bool
    let export: () -> Void
    let share: () -> Void
    let edit: () -> Void
    let close: () -> Void
    @State private var paper: ResumeRenderRequest?
    @State private var height: CGFloat = 1123
    @State private var missingImages = 0
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(resume.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text("\(resume.updatedLabel()) · 已保存").font(V3.sans(12)).foregroundStyle(V3.fnt)
                }
                Spacer()
                Button("编辑", action: edit).buttonStyle(V3ButtonStyle(kind: .ghost))
                Button("分享", action: share).buttonStyle(V3ButtonStyle(kind: .ghost))
                Button(exporting ? "正在导出…" : "导出 PDF", action: export).buttonStyle(WebActionStyle()).disabled(exporting)
                Button("关闭", action: close).buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }.padding(20)
            Text("点“编辑”在原生编辑器修改内容、格式、版式与模板。最终排版以 PDF 为准，字体、换行与分页可能不同。")
                .font(V3.sans(12)).foregroundStyle(V3.fnt).padding(.horizontal, 20).padding(.bottom, 12)
            if missingImages > 0 { Text("部分图片不可用，正文仍可预览").font(V3.sans(12)).foregroundStyle(V3.orange).padding(.bottom, 8) }
            if let error { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red).padding(.bottom, 8) }
            ScrollView([.vertical, .horizontal]) {
                if let paper {
                    ResumePaperView(request: paper, onRendered: { height = max(1123, $0) }, onError: { error = $0 })
                        .frame(width: 794, height: height).padding(24)
                } else if error == nil { V3Loading("加载预览…").padding(40) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Tokens.Color.stage)
        }.task(id: "\(resume.id)|\(resume.lockVersion)") {
            paper = nil; error = nil; missingImages = 0; height = 1123
            guard let request = resume.renderRequest() else { error = "这份简历暂时没有可用的预览，请打开编辑器保存一次后重试。"; return }
            do {
                let result = try await session.api.preparePaper(request)
                try Task.checkCancellation()
                paper = result.request; missingImages = result.missingImageCount
            } catch is CancellationError {
            } catch APIError.unauthorized {
                session.reportAuthenticationFailure(); error = "登录已失效，请重新登录。"
            } catch { self.error = "预览加载失败，请重试。" }
        }
    }
}

/// 原生端没有的正文编辑等能力，在默认浏览器打开 Web 对应页面。网页使用自己的登录态，不传递桌面凭据。
enum WebBridge {
    static func open(_ path: String, api: any APIClient) {
        guard let origin = (api as? HTTPAPIClient)?.origin, path.hasPrefix("/"),
              let url = URL(string: path, relativeTo: origin)?.absoluteURL, ["https", "http"].contains(url.scheme ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 02.1 页头：眉题 11 灰「RESUMES · N 份」，标题 28 衬线，说明 13（到上限时橙色）；按钮距顶 32。
private struct ResumesHead<Actions: View>: View {
    let count: String
    /// 首次加载：眉题数量与副标题画文字占位（Web `<LoadingText width={36} />` / `<LoadingText width={320} />`）。
    var loading = false
    let subtitle: String
    var warn = false
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text("RESUMES · ")
                    if loading { V3LoadingText(width: 36, size: 11) } else { Text(count) }
                }.font(V3.sans(11)).foregroundStyle(resumesHint).frame(height: 13)
                Text("我的简历").font(V3.serif(28)).foregroundStyle(V3.txt).frame(height: 40).padding(.top, 13)
                Group {
                    if loading { V3LoadingText(width: 320, size: 13) }
                    else { Text(subtitle).font(V3.sans(13)).foregroundStyle(warn ? V3.orange : V3.sub).lineLimit(1) }
                }.frame(height: 16).padding(.top, 2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) { actions() }.padding(.top, 32)
        }
    }
}

/// 稿中眉题、数量与时间的浅灰字 #96968F。
private let resumesHint = Color(hex: 0x96968F)

/// 02.1 空列表插图：64×88 白纸（标题条 + 三个虚线模块位），左「教育经历」、右「项目经历」两个小模块签。
private struct ResumesBlankArt: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 1).fill(V3.txt).frame(width: 26, height: 4).padding(.top, 10)
                RoundedRectangle(cornerRadius: 1).fill(Color(hex: 0xD9D9D4)).frame(width: 38, height: 2).padding(.top, 4)
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2.5).stroke(Color(hex: 0xD6D6D1), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: 47, height: 12).padding(.top, 6)
                }
            }
            .padding(.leading, 8).frame(width: 64, height: 88, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).stroke(V3.cl))
            .offset(x: 70)
            tag("教育经历").offset(x: 0, y: 18)
            tag("项目经历").offset(x: 140, y: 48)
        }.frame(width: 200, height: 88, alignment: .topLeading).accessibilityHidden(true)
    }
    private func tag(_ text: String) -> some View {
        Text(text).font(V3.sans(10.5, weight: .medium)).foregroundStyle(V3.sub).frame(width: 60, height: 24)
            .background(.white, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(V3.cl))
    }
}

/// 02.1 ③ 搜索没有结果插图：两侧两张小纸、中间一张稍大的纸，右下压一个放大镜。
private struct ResumesSearchArt: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            paper(32, 43).offset(x: 0, y: 3)
            paper(32, 43).offset(x: 49, y: 3)
            paper(35, 47).offset(x: 23, y: 0)
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(V3.sub)
                .frame(width: 17, height: 17).background(.white, in: Circle()).offset(x: 48, y: 25)
        }.frame(width: 81, height: 47, alignment: .topLeading).accessibilityHidden(true)
    }
    private func paper(_ width: CGFloat, _ height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            RoundedRectangle(cornerRadius: 0.5).fill(V3.txt).frame(width: width * 0.4, height: 2)
            ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 0.5).fill(V3.line).frame(width: width * 0.6, height: 1.5) }
        }
        .padding(5).frame(width: width, height: height, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 1.6)).overlay(RoundedRectangle(cornerRadius: 1.6).stroke(V3.cl))
    }
}

/// 02.1 页头按钮：胶囊。「导入简历」31 高白底 #e4e4e0 细边，「新建简历」32 高墨黑；12/500 字、图标 9。
private struct ResumesPillStyle: ButtonStyle {
    let dark: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ResumesPillLabel())
            .font(V3.sans(12, weight: .medium)).foregroundStyle(dark ? Color.white : V3.txt)
            .padding(.horizontal, dark ? 20 : 17).frame(height: dark ? 32 : 31)
            .background(dark ? (configuration.isPressed ? Color(hex: 0x0E0E0D) : V3.txt) : (configuration.isPressed ? V3.field : .white), in: Capsule())
            .overlay(Capsule().stroke(dark ? .clear : V3.cl))
            .opacity(enabled ? 1 : 0.4).contentShape(Capsule())
    }
}

private struct ResumesPillLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) { configuration.icon.font(.system(size: 9, weight: .semibold)); configuration.title }
    }
}
