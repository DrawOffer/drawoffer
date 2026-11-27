import AppKit
import DrawOfferCore
import DrawOfferRender
import SwiftUI

/// 简历模板（Web `features/templates/ResumeTemplatesPage.tsx`）。
/// 读取 `GET /api/resume-templates` 的真实启用模板与使用次数，并可直接创建简历；游客由外壳拦在首页，进不来这一页。
struct TemplatesView: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let onCreated: (ResumeSummary.ID) -> Void

    @State private var templates: [ResumeTemplate] = []
    @State private var source = ""
    @State private var loading = false
    @State private var loadError: String?
    @State private var reload = UUID()
    @State private var preview: ResumeTemplate?
    @State private var createAfterDismiss: ResumeTemplate?
    @State private var creating: ResumeTemplate?
    /// Web `TemplateFilterPopover`：风格与适用场景多选，同组内任一命中、两组同时满足。
    @State private var selectedStyles: [String] = []
    @State private var selectedUses: [String] = []
    @State private var page = 1
    /// 79:2093 排序：默认按热度（`use_count` 降序，同数保持展示顺序），可切回展示顺序。
    @State private var byPopularity = true
    static let pageSize = 20

    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }
    private var filtered: [ResumeTemplate] {
        let items = templates.filter {
            (selectedStyles.isEmpty || !Set(selectedStyles).isDisjoint(with: $0.styleCategories))
                && (selectedUses.isEmpty || !Set(selectedUses).isDisjoint(with: $0.useCases))
        }
        guard byPopularity else { return items }
        return items.enumerated().sorted { ($0.element.useCount ?? 0, -$0.offset) > ($1.element.useCount ?? 0, -$1.offset) }.map(\.element)
    }
    private var pageCount: Int { max(1, (filtered.count + Self.pageSize - 1) / Self.pageSize) }
    private var pageItems: [ResumeTemplate] { Array(filtered.dropFirst((min(page, pageCount) - 1) * Self.pageSize).prefix(Self.pageSize)) }
    private var filterCount: Int { selectedStyles.count + selectedUses.count }

    /// 与 Web 相同的筛选空态文案。
    private var emptyMessage: String {
        let quote = { (values: [String]) in values.map { "「\($0)」" }.joined() }
        return switch (selectedStyles.isEmpty, selectedUses.isEmpty) {
        case (false, true): "\(quote(selectedStyles))风格下没有模板。试试换一个筛选条件。"
        case (true, false): "\(quote(selectedUses))场景下没有模板。试试换一个筛选条件。"
        case (false, false): "\(quote(selectedStyles))风格和\(quote(selectedUses))场景同时选中时没有模板。试试减少一个筛选条件。"
        default: "没有符合条件的模板"
        }
    }
    private var ready: Bool { !account.isEmpty && source == account }

    var body: some View {
        // 05 · 简历模板 79:2093（03.1）：860 宽内容列，眉题距顶 64。
        V3Page(top: 63) {
            VStack(alignment: .leading, spacing: 0) {
                head
                if let loadError, !ready {
                    // 加载失败：沿用空状态排版，按钮重新加载
                    TemplatesBlank(title: "模板暂时无法加载", message: loadError, art: { TemplatesNoneArt() }) {
                        Button { reload = UUID() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)); Text("重新加载") }
                            .buttonStyle(V3ButtonStyle(kind: .ghost, height: 28)).disabled(loading)
                    }
                } else if !ready {
                    // Web：工具条照常显示（数量写「–」），下方画模板网格骨架（SkeletonGrid）
                    toolbar
                    V3SkeletonTemplateGrid().padding(.top, 24)
                } else if templates.isEmpty {
                    // 79:2375 ③ 当前没有可用模板
                    TemplatesBlank(title: "当前没有可用模板", message: "模板启用后会显示在这里，你仍可以从已有简历继续编辑。", art: { TemplatesNoneArt() }) {
                        Button { backToResumes() } label: { Image(systemName: "doc").font(.system(size: 11)); Text("返回全部简历") }
                            .buttonStyle(V3ButtonStyle(kind: .ghost, height: 28))
                    }
                } else { grid }
            }
        }
        .task(id: "\(account)|\(reload)") { await load() }
        .onChange(of: account) { _, _ in templates = []; source = ""; preview = nil; creating = nil; selectedStyles = []; selectedUses = []; page = 1 }
        .onChange(of: selectedStyles) { page = 1 }
        .onChange(of: selectedUses) { page = 1 }
        .onChange(of: byPopularity) { page = 1 }
        .centeredSheet(item: $preview, onDismiss: {
            if let template = createAfterDismiss { createAfterDismiss = nil; use(template) }
        }) { template in
            // Web 预览只在当前这一页里切换上一套 / 下一套
            let list = pageItems
            TemplatePreview(template: template, close: { preview = nil }, use: {
                createAfterDismiss = template
                preview = nil
            }, previous: list.firstIndex { $0.id == template.id }.flatMap { list.count > 1 ? list[($0 - 1 + list.count) % list.count] : nil },
               next: list.firstIndex { $0.id == template.id }.flatMap { list.count > 1 ? list[($0 + 1) % list.count] : nil },
               position: list.firstIndex { $0.id == template.id }.map { ($0, list.count) },
               show: { preview = $0 })
        }
        .centeredSheet(item: $creating) { template in
            CreateResumeSheet(template: template, close: { creating = nil }, created: { id in
                creating = nil
                onCreated(id)
            })
        }
    }

    /// 页头：11px 眉题「TEMPLATES · N 套」、28px 衬线标题、13px 说明。
    private var head: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("TEMPLATES · ")
                // Web：数量没到时是一条 16 宽的文字占位，失败时写「–」
                if ready { Text("\(templates.count)") } else if loadError == nil { V3LoadingText(width: 16, size: 11) } else { Text("–") }
                Text(" 套")
            }.font(V3.sans(11)).foregroundStyle(TemplatesStyle.hint).frame(height: 14)
            Text("简历模板").font(V3.serif(28)).foregroundStyle(V3.txt).frame(height: 40).padding(.top, 12)
            Text("浏览当前可用版式，选择后填写简历名称并进入编辑器。").font(V3.sans(13)).foregroundStyle(V3.sub).lineLimit(1)
                .frame(height: 16).padding(.top, 2)
        }
    }

    /// 工具条：距说明 29、高 29；左摘要与清除筛选，右排序说明与筛选 PopUpButton。加载中数量写「–」。
    private var toolbar: some View {
        HStack(spacing: 0) {
            Text("找到 \(ready ? "\(filtered.count)" : "–") 套模板").font(V3.sans(12)).foregroundStyle(V3.sub)
            if filterCount > 0 {
                Button("清除筛选") { selectedStyles = []; selectedUses = [] }.buttonStyle(.plain)
                    .font(V3.sans(12, weight: .medium)).foregroundStyle(V3.txt).padding(.leading, 23)
            }
            Spacer()
            Menu {
                Picker("排序", selection: $byPopularity) {
                    Text("按热度排序").tag(true)
                    Text("按展示顺序").tag(false)
                }.pickerStyle(.inline).labelsHidden()
            } label: {
                Text(byPopularity ? "按热度排序" : "按展示顺序").font(V3.sans(12)).foregroundStyle(TemplatesStyle.hint)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().padding(.trailing, 16).accessibilityLabel("模板排序")
            TemplateFilter(styles: $selectedStyles, uses: $selectedUses)
        }.frame(height: 29).padding(.top, 29)
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            if filtered.isEmpty {
                // 79:2375 ② 没有符合条件的模板
                TemplatesBlank(title: "没有符合条件的模板", message: emptyMessage, art: { TemplatesFilterArt(count: filterCount) }) {
                    Button { selectedStyles = []; selectedUses = [] } label: {
                        Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)); Text("清除筛选")
                    }.buttonStyle(V3ButtonStyle(kind: .ghost, height: 28))
                }
            } else {
                // 卡片 200 宽、列距 20、行距 32：灰底缩略纸面 → 名称 → 标签与使用次数
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 20, alignment: .top)], alignment: .leading, spacing: 32) {
                    ForEach(pageItems) { template in
                        TemplatesCard(template: template) { preview = template }
                    }
                }.padding(.top, 24)
                if pageCount > 1 { V3Pagination(page: min(page, pageCount), total: filtered.count, pageSize: Self.pageSize) { page = $0 }.padding(.top, 12) }
            }
        }
    }

    private func load() async {
        let owner = account
        loading = true; loadError = nil
        defer { if owner == account { loading = false } }
        do {
            guard !owner.isEmpty else { return }
            let result = try await session.api.listResumeTemplates()
            try Task.checkCancellation()
            guard owner == account else { return }
            templates = result; source = owner
        } catch is CancellationError {
        } catch {
            guard owner == account else { return }
            if case APIError.unauthorized = error { session.reportAuthenticationFailure(); return }
            loadError = "请检查网络后重试，已有简历不会受到影响。"
        }
    }

    private func backToResumes() { router?.jump(.section(.resumes)) }

    private func use(_ template: ResumeTemplate) { creating = template }

    /// Web `formatTemplateUses`：千以下写原数，千以上写成 3.2k。
    static func formatUses(_ count: Int) -> String {
        guard count >= 1000 else { return String(count) }
        let value = (Double(count) / 100).rounded() / 10
        return value == value.rounded() ? "\(Int(value))k" : String(format: "%.1fk", value)
    }
}

/// 缩略纸面。
struct TemplateThumbnail: View {
    @Environment(SessionStore.self) private var session
    let template: ResumeTemplate
    /// 模板页灰底卡片里的纸面用小圆角（稿 2px），编辑器与弹窗沿用 6。
    var radius: CGFloat = 6
    /// 模板页卡片不描边，纸面本身就是卡片。
    var bordered = true
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
            if failed { Text("预览不可用").font(.caption).padding(8).background(.white) }
        }.aspectRatio(210.0 / 297, contentMode: .fit).background(.white)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay { if bordered { RoundedRectangle(cornerRadius: radius).stroke(Color(hex: 0xD3D3CE)) } }
            .task(id: template.id) {
                do {
                    let result = try await session.api.preparePaper(template.previewRequest())
                    try Task.checkCancellation(); paper = result.request
                }
                catch is CancellationError { }
                catch { failed = true }
            }
    }
}

/// 03.1a 模板预览，对齐 Web `TemplatePreviewDialog`（760×900，放不下时随窗口收矮）：标题与标签、使用次数，
/// 点阵舞台里 420 宽（100%）的 A4，两侧圆形切换钮（循环，← → 同样），底部缩放条，页脚「第 n / N 套」、取消与主按钮。
private struct TemplatePreview: View {
    @Environment(SessionStore.self) private var session
    let template: ResumeTemplate
    let close: () -> Void
    let use: () -> Void
    var previous: ResumeTemplate? = nil
    var next: ResumeTemplate? = nil
    var position: (index: Int, count: Int)? = nil
    var show: (ResumeTemplate) -> Void = { _ in }
    @State private var paper: ResumeRenderRequest?
    @State private var height: CGFloat = 1123
    @State private var error: String?
    @State private var zoom = 1.0
    static let minZoom = 0.5, maxZoom = 2.0, step = 0.1
    /// 100% 时纸面宽 420（A4 794 × 0.5292）。
    static let base = 0.5292

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(template.name).font(V3.serif(20)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 29)
                    .padding(.trailing, 40)
                HStack(spacing: 6) {
                    ForEach(template.styleCategories + template.useCases, id: \.self) { V3Chip(label: $0) }
                    if let count = template.useCount {
                        Text("\(TemplatesView.formatUses(count)) 使用").font(V3.number(11, weight: .regular)).foregroundStyle(V3.fnt).padding(.leading, 6)
                    }
                }.frame(height: 20)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 32).padding(.top, 28).frame(height: 100, alignment: .top)
                .overlay(alignment: .topTrailing) {
                    Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                        .buttonStyle(.plain).foregroundStyle(V3.fnt).keyboardShortcut(.cancelAction).accessibilityLabel("关闭").padding(.top, 26).padding(.trailing, 26)
                        .opacity(0).allowsHitTesting(false).accessibilityHidden(true) // macOS Sheet 不显示 ×，只保留 Esc 关闭；可见的关闭在底部按钮行
                }
            ZStack {
                // 79:677：舞台为 #F4F4F2 纯色底（无点阵），圆角 10
                RoundedRectangle(cornerRadius: 10).fill(V3.field)
                ScrollView([.vertical, .horizontal]) {
                    if let paper {
                        let scale = zoom * Self.base
                        ResumePaperView(request: paper, onRendered: { height = max(1123, $0) }, onError: { error = $0 })
                            .frame(width: 794 * scale, height: height * scale)
                            .clipShape(RoundedRectangle(cornerRadius: 4)).shadow(color: .black.opacity(0.08), radius: 12, y: 8)
                            .padding(.top, 34).padding(.horizontal, 76).padding(.bottom, 80)
                            .frame(minWidth: 0, maxWidth: .infinity)
                    } else if let error { Text(error).font(V3.sans(13)).foregroundStyle(V3.red).padding(40) }
                    else { ProgressView().controlSize(.small).padding(40) }
                }
                HStack {
                    navButton(previous, left: true)
                    Spacer()
                    navButton(next, left: false)
                }.padding(.horizontal, 20)
                VStack {
                    Spacer()
                    HStack {
                        zoomButton("−", label: "缩小模板", enabled: zoom > Self.minZoom) { change(-1) }
                        Spacer()
                        Text("\(Int((zoom * 100).rounded()))%").font(V3.number(11.5, weight: .medium)).foregroundStyle(V3.txt).accessibilityLabel("模板预览缩放比例")
                        Spacer()
                        zoomButton("+", label: "放大模板", enabled: zoom < Self.maxZoom) { change(1) }
                    }.padding(.horizontal, 6).frame(width: 132, height: 32)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
                        .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
                        .accessibilityElement(children: .contain).accessibilityLabel("模板预览缩放")
                        .padding(.bottom, 16)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 32).padding(.bottom, 24)
            HStack(spacing: 10) {
                if let position { Text("第 \(position.index + 1) / \(position.count) 套").font(V3.sans(11.5)).foregroundStyle(V3.fnt) }
                Spacer()
                Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36, width: 80))
                Button("创建简历", action: use).buttonStyle(V3ButtonStyle(kind: .dark, height: 36, width: 100))
            }.padding(.horizontal, 32).frame(minHeight: 88).overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
        }
        // Web：760×900，窗口放不下时减去上下各 24 的遮罩留白
        .frame(width: 760, height: min(900, (NSApp.mainWindow?.contentLayoutRect.height ?? 900) - 48))
        .onKeyPress(.leftArrow) { if let previous { show(previous); return .handled }; return .ignored }
        .onKeyPress(.rightArrow) { if let next { show(next); return .handled }; return .ignored }
        .task(id: template.id) {
            paper = nil; error = nil; height = 1123
            do {
                let result = try await session.api.preparePaper(template.previewRequest())
                try Task.checkCancellation(); paper = result.request
            }
            catch is CancellationError { }
            catch { self.error = "预览加载失败，请重试。" }
        }
    }

    private func navButton(_ target: ResumeTemplate?, left: Bool) -> some View {
        Button { if let target { show(target) } } label: {
            Image(systemName: left ? "chevron.left" : "chevron.right").font(.system(size: 12, weight: .medium)).frame(width: 36, height: 36)
                .background(.white, in: Circle()).overlay(Circle().stroke(V3.cl)).shadow(color: .black.opacity(0.06), radius: 3, y: 2)
        }.buttonStyle(.plain).foregroundStyle(V3.sub).disabled(target == nil).opacity(target == nil ? 0.4 : 1)
            .accessibilityLabel(target.map { "\(left ? "上一个" : "下一个")模板：\($0.name)" } ?? (left ? "没有上一个模板" : "没有下一个模板"))
    }

    private func zoomButton(_ title: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 14, weight: .medium)).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(V3.sub).disabled(!enabled).opacity(enabled ? 1 : 0.35).accessibilityLabel(label)
    }

    private func change(_ direction: Double) {
        zoom = min(Self.maxZoom, max(Self.minZoom, ((zoom + direction * Self.step) * 100).rounded() / 100))
    }
}

/// Web 模板页的“创建简历”弹窗：基于所选模板创建，输入一个便于识别的名称。
/// 创建接口没有幂等标识；结果不确定时提示先查看简历列表，避免重复创建。
private struct CreateResumeSheet: View {
    @Environment(SessionStore.self) private var session
    let template: ResumeTemplate
    let close: () -> Void
    let created: (ResumeSummary.ID) -> Void
    @State private var title = ""
    @State private var busy = false
    @State private var error: String?
    @State private var uncertain = false

    var body: some View {
        V3Dialog(closable: !busy, close: close) {
            V3DialogHead(title: "创建简历", sub: "基于“\(template.name)”创建简历，输入一个便于识别的名称。")
            V3TextInput(label: "简历名称", placeholder: "例如：2026 产品经理简历", text: $title, error: error, disabled: busy, submit: submit)
                .padding(.top, 20).onChange(of: title) { if error != nil && !uncertain { error = nil } }
        } foot: {
            Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36)).disabled(busy)
            Button(busy ? "正在创建…" : uncertain ? "查看简历列表" : "确认创建", action: submit)
                .buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).disabled(busy)
        }
    }

    /// Web `createErrorMessage`。
    static func message(_ error: Error) -> String {
        guard case APIError.server(_, let code) = error else { return "创建简历失败，请稍后重试。" }
        switch code {
        case "RESUME_LIMIT_REACHED": return "简历数量已达上限（\(ResumeRequest.maximumPerUser) 份），请删除不需要的简历后重试。"
        case "INVALID_RESUME_TITLE": return "请输入 1–255 个字符的简历名称。"
        case "RESUME_TITLE_CONFLICT": return "该名称已经存在，请换一个名称。"
        case "TEMPLATE_INACTIVE": return "所选模板已不可用，请重新选择。"
        default: return "创建简历失败，请稍后重试。"
        }
    }

    private func submit() {
        guard !busy else { return }
        if uncertain { created(""); return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "请输入简历名称。"; return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await session.api.careerRequest(path: "/api/resumes", method: "POST", query: [:],
                    body: .object(["title": .string(name), "template_id": .string(template.id), "guide": .bool(true)]))
                created(result["resume"]?["id"]?.stringValue ?? "")
            } catch {
                if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
                if case APIError.server = error {
                    self.error = Self.message(error)
                } else if case APIError.unauthorized = error {
                    self.error = ResumeRequest.errorMessage(error, fallback: "")
                } else {
                    uncertain = true
                    self.error = "网络中断，无法确认是否已创建。请先查看简历列表，避免重复创建。"
                }
            }
        }
    }
}


/// 筛选按钮：79:2093 的 macOS PopUpButton（91×29、白底、#E4E4E0 描边、圆角 7.5，漏斗图标 + 「筛选」+ 上下箭头）；
/// 有筛选时写成「筛选 · N」并加深描边（79:2375 ②）。弹层 300 宽（79:346）：标题与重置，风格、适用场景两组 ScopeButton 多选。
/// 模板页与编辑器模板面板共用。
struct TemplateFilter: View {
    @Binding var styles: [String]
    @Binding var uses: [String]
    var height: CGFloat = 29
    @State private var open = false
    static let styleOptions = ["简约", "经典", "现代", "创意"]
    static let useOptions = ["实习", "校招", "社招"]
    private var count: Int { styles.count + uses.count }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(V3.sub)
                Text(count > 0 ? "筛选 · \(count)" : "筛选").font(V3.sans(12, weight: .medium)).foregroundStyle(V3.txt)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(V3.sub)
            }
            .padding(.leading, 12).padding(.trailing, 9).frame(minWidth: 91).frame(height: height).fixedSize()
            .background(open ? V3.field : .white, in: RoundedRectangle(cornerRadius: 7.5))
            .overlay(RoundedRectangle(cornerRadius: 7.5).stroke(count > 0 ? V3.txt : V3.cl))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("筛选简历模板")
            .popover(isPresented: $open, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("筛选简历模板").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                Spacer()
                Button { styles = []; uses = [] } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 22, height: 22) }
                    .buttonStyle(.plain).foregroundStyle(V3.sub).disabled(count == 0).opacity(count == 0 ? 0.4 : 1)
                    .help("重置筛选").accessibilityLabel("重置筛选")
            }.frame(height: 16)
            group("风格", Self.styleOptions, $styles).padding(.top, 20)
            group("适用场景", Self.useOptions, $uses).padding(.top, 22)
        }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 22).frame(width: 300)
            .accessibilityElement(children: .contain).accessibilityLabel("筛选简历模板")
    }

    private func group(_ title: String, _ options: [String], _ values: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title).font(V3.sans(11)).foregroundStyle(TemplatesStyle.hint).frame(height: 13)
            HStack(spacing: 4) {
                ForEach(options, id: \.self) { option in
                    let on = values.wrappedValue.contains(option)
                    V3ScopeButton(label: option, selected: on) {
                        if on { values.wrappedValue.removeAll { $0 == option } } else { values.wrappedValue.append(option) }
                    }
                }
            }
        }
    }
}


// MARK: - 05 · 简历模板 卡片与状态

enum TemplatesStyle {
    /// 稿中眉题、排序说明、使用次数的浅灰字 #96968F。
    static let hint = Color(hex: 0x96968F)
}

/// 模板卡片：A4 纸面铺满卡片宽度（圆角 10，不加灰底和描边，按用户要求偏离 79:2093 的灰底卡）；
/// 名称 13 中粗距纸面 14；标签（10px、20 高、圆角 5）与「N 使用」一行，距名称 4。只靠很淡的投影和页面分开，悬停时投影加深。
struct TemplatesCard: View {
    let template: ResumeTemplate
    let open: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                TemplateThumbnail(template: template, radius: 10, bordered: false)
                    .shadow(color: .black.opacity(hover ? 0.14 : 0.07), radius: hover ? 10 : 6, y: hover ? 4 : 2)
                Text(template.name).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.tail)
                    .frame(height: 16).padding(.top, 14)
                HStack(spacing: 6) {
                    ForEach(template.styleCategories + template.useCases, id: \.self) { V3Chip(label: $0, height: 20, size: 10) }
                    Spacer(minLength: 0)
                    if let count = template.useCount {
                        Text("\(TemplatesView.formatUses(count)) 使用").font(V3.sans(10.5)).foregroundStyle(TemplatesStyle.hint).lineLimit(1)
                    }
                }.frame(height: 20).padding(.top, 4)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.animation(.easeOut(duration: 0.15), value: hover)
        .accessibilityLabel("查看模板：\(template.name)")
    }
}

/// 79:2375 空状态：无卡片，插图 + 衬线标题 + 说明 + 描边按钮，整体在内容区居中。
struct TemplatesBlank<Art: View, Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var art: () -> Art
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(spacing: 0) {
            art().frame(width: 180, height: 100)
            Text(title).font(V3.serif(16)).foregroundStyle(V3.txt).padding(.top, 54)
            Text(message).font(V3.sans(12)).foregroundStyle(V3.sub).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            HStack(spacing: 10) { actions() }.padding(.top, 26)
        }.frame(maxWidth: .infinity).padding(.top, 96).padding(.bottom, 40)
    }
}

/// ③ 没有可用模板：三张虚线空白纸面。
struct TemplatesNoneArt: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { index in
                let x = CGFloat(index) * 54
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 2).fill(V3.line).frame(width: 26, height: 3).offset(x: 8, y: 10)
                    RoundedRectangle(cornerRadius: 2).fill(V3.line).frame(width: 38, height: 2).offset(x: 8, y: 18)
                }
                .frame(width: 60, height: 82, alignment: .topLeading)
                .background(.white)
                .overlay(Rectangle().stroke(V3.line, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .offset(x: x + 12, y: 8)
            }
        }.frame(width: 180, height: 100, alignment: .topLeading).accessibilityHidden(true)
    }
}

/// ② 筛选无结果：三张缩略纸面（两侧带色条、中间墨黑），右下圆形漏斗角标与橙色已选数量。
struct TemplatesFilterArt: View {
    let count: Int
    var body: some View {
        ZStack(alignment: .topLeading) {
            paper(accent: Color(hex: 0x9CC8AE)).offset(x: 6, y: 12).opacity(0.85)
            paper(accent: Color(hex: 0x9DB4E6)).offset(x: 116, y: 12).opacity(0.85)
            paper(accent: V3.txt).offset(x: 58, y: 4).shadow(color: .black.opacity(0.06), radius: 3, y: 2)
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13, weight: .medium)).foregroundStyle(V3.txt)
                .frame(width: 40, height: 40).background(.white, in: Circle()).overlay(Circle().stroke(V3.cl))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2).offset(x: 102, y: 54)
            if count > 0 {
                Text("\(count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 16, height: 16).background(V3.orange, in: Circle()).offset(x: 132, y: 48)
            }
        }.frame(width: 180, height: 100, alignment: .topLeading).accessibilityHidden(true)
    }

    private func paper(accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 1).fill(accent).frame(width: 26, height: 4)
            ForEach(0..<3, id: \.self) { row in
                RoundedRectangle(cornerRadius: 1).fill(accent).frame(width: 14, height: 3).padding(.top, 4)
                RoundedRectangle(cornerRadius: 1).fill(V3.line).frame(width: 40, height: 2)
            }
        }
        .padding(7).frame(width: 60, height: 82, alignment: .topLeading)
        .background(.white).overlay(Rectangle().stroke(V3.line))
    }
}
