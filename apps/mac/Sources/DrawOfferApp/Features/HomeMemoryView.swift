import AppKit
import DrawOfferCore
import DrawOfferRender
import SwiftUI
import UniformTypeIdentifiers

/// 工作区首页（macOS 设计稿 02A 页，Web `assistant/home/HomeMemory.tsx`）：
/// 没有简历 → 01 新用户（左边欢迎、右边一张能点能拖的简历纸）；有简历、第一份报告看完之前 → 03 / 06（练一场模拟面试，跟新手引导开关走）；
/// 之后一律是 07（最近进展 + 知识图谱 + 六个入口），缺图谱节点或缺进展时只换那一块。
struct HomeMemoryView: View {
    @Environment(SessionStore.self) private var session
    let editResume: (String) -> Void
    let practice: (PracticeFocus?) -> Void
    let openMock: (String, Bool) -> Void
    let navigate: (WorkspaceSection) -> Void
    /// 图谱「聊一聊」侧栏右上 ↗：在对话页打开这条对话（`WorkspaceView` 里设 `ChatTarget(sessionID:)` 再切到助手）；nil 时侧栏不显示 ↗
    var openChat: ((String) -> Void)? = nil
    /// 侧栏里新建或更新了对话：让侧栏“最近对话”重新读取
    var chatsChanged: (() -> Void)? = nil

    @State private var graph: HomeGraph?
    @State private var mocks: HomeMockProgress?
    @State private var failed = false
    @State private var loaded = false
    @State private var request = 0

    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }
    private var reportSeenKey: String { "home.firstReportSeen.\(account)" }

    var body: some View {
        Group {
            if failed && graph == nil {
                VStack(spacing: 14) {
                    Text("首页信息暂时无法读取").font(V3.sans(17, weight: .medium)).foregroundStyle(V3.txt)
                    Button("重试") { Task { await load() } }.buttonStyle(V3ButtonStyle())
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let graph, loaded, graph.resumeID == nil || CoachGuide.shared.ready {
                switch HomeStage.pick(graph: graph, mocks: mocks, reportSeen: UserDefaults.standard.bool(forKey: reportSeenKey), guideOn: CoachGuide.shared.enabled) {
                case .newUser:
                    HomeCanvas { NewUserHome(reload: { Task { await load() } }, editResume: { id in HomePaperHandoff.armed = true; editResume(id) }) }
                case .firstSteps(let mode):
                    HomeCanvas {
                        FirstStepsHome(graph: graph, mode: mode, mockID: mocks?.firstID,
                                       open: { id in
                                           if mode == .report { UserDefaults.standard.set(true, forKey: reportSeenKey) }
                                           if let id { openMock(id, mode == .report) } else { practice(nil) }
                                       },
                                       jobs: { navigate(.opportunities) }, changed: { Task { await load() } })
                    }
                case .feedback:
                    FeedbackHome(graph: graph, editResume: editResume, practice: practice, openMock: openMock, navigate: navigate,
                                 openChat: openChat, chatsChanged: chatsChanged)
                }
            } else {
                // Web `HomeMemory`：数据到达前首页本身就是一张空白画布（路由骨架同样留白），不画转圈或吉祥物
                Color.white.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityLabel("正在读取首页…")
            }
        }
        .background(.white)
        .task(id: account) { await load() }
    }

    private func load() async {
        request += 1
        let own = request
        failed = false
        async let graphJSON = try? session.api.careerRequest(path: "/api/memory/home/graph", method: "GET", query: [:], body: nil)
        async let mockJSON = try? session.api.careerRequest(path: "/api/mock-interviews", method: "GET", query: [:], body: nil)
        async let guide: Void = CoachGuide.shared.refresh(api: session.api)
        let (g, m, _) = await (graphJSON, mockJSON, guide)
        guard own == request else { return }
        if let g { graph = HomeGraph(json: g) } else { failed = true }
        mocks = m.map(HomeMockProgress.init(json:))
        loaded = true
    }
}

/// 未登录时的首页：同一张新用户首页，点任何入口先登录。
struct GuestHomeView: View {
    let requireAccount: () -> Void
    var body: some View {
        HomeCanvas { NewUserHome(reload: {}, editResume: { _ in }, guest: requireAccount) }.background(.white)
    }
}

// MARK: 1151×828 设计画布（Web DesignStage）：等比缩放、居中

private struct HomeCanvas<Content: View>: View {
    static var size: CGSize { CGSize(width: 1151, height: 828) }
    @ViewBuilder let content: Content
    var body: some View {
        GeometryReader { geometry in
            // 只缩不放：scaleEffect 是位图缩放，放大会把字拉糊；窗口比设计画布大时居中留白。
            let scale = min(geometry.size.width / Self.size.width, geometry.size.height / Self.size.height, 1)
            content.frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }.clipped()
    }
}

/// 首页里的墨黑胶囊主按钮（一页只有一个黑按钮）。
private struct HomePillStyle: ButtonStyle {
    var height: CGFloat = 44
    var font: CGFloat = 15
    /// 设计稿里固定宽度的胶囊（新用户首页「导入简历」128×44）
    var width: CGFloat? = nil
    var leading: CGFloat = 22
    var trailing: CGFloat = 20
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(font, weight: .medium))
            .foregroundStyle(enabled ? .white : Color(hex: 0x87867F))
            .padding(.leading, width == nil ? leading : 0).padding(.trailing, width == nil ? trailing : 0).frame(width: width, height: height)
            .background(enabled ? (hovering || configuration.isPressed ? Color(hex: 0x2F2F2C) : V3.txt) : Color(hex: 0xE7E6E0), in: Capsule())
            .onHover { hovering = $0 }
    }
}

private extension View {
    /// 设计稿里的文字框：左上角在 (x, y)，高度 = 字号 × 1.2，文字在框里垂直居中；给了宽度就在框里居中或靠左。
    func slot(_ x: CGFloat, _ y: CGFloat, size: CGFloat, width: CGFloat? = nil, center: Bool = false) -> some View {
        fixedSize().frame(width: width, height: (size * 1.2).rounded(), alignment: center ? .center : .leading).offset(x: x, y: y)
    }
    /// 同上，但给的是文字框的竖直中心。
    func slotC(_ x: CGFloat, _ cy: CGFloat, size: CGFloat, width: CGFloat? = nil, center: Bool = false) -> some View {
        slot(x, cy - (size * 1.2).rounded() / 2, size: size, width: width, center: center)
    }
}

private struct HomeTextLinkStyle: ButtonStyle {
    var size: CGFloat = 15
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(size)).foregroundStyle(hovering ? V3.txt : V3.sub).onHover { hovering = $0 }
    }
}

private struct BrandMark: View {
    var body: some View {
        if let url = Bundle.module.url(forResource: "mark", withExtension: "png", subdirectory: "Branding"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        } else { AppIconImage() }
    }
}

// MARK: 01 新用户首页（Figma 02A·01 P1–P5）

private struct NewUserHome: View {
    @Environment(SessionStore.self) private var session
    let reload: () -> Void
    let editResume: (String) -> Void
    /// 游客：所有入口先登录，不读接口
    var guest: (() -> Void)? = nil

    private enum Mode { case idle, open, drag }
    @State private var mode: Mode = .idle
    @State private var hovering = false
    @State private var importFile: URL?
    @State private var importOpen = false
    @State private var readingID: String?
    @State private var read = 0
    @State private var busy = false
    @State private var notice: String?

    private static let parts = ["基本信息", "教育经历", "实习经历", "项目经历", "技能"]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.contentShape(Rectangle()).onTapGesture { if mode == .open { mode = .idle } }
            HStack(spacing: 10) {
                BrandMark().frame(width: 28, height: 28)
                Text("欢迎来到职绘").font(V3.sans(18, weight: .medium)).foregroundStyle(V3.txt)
            }.offset(x: 120, y: 210)
            Text(readingID != nil ? "正在读你的简历" : "从第一份简历开始")
                .font(V3.sans(52, weight: .medium)).foregroundStyle(V3.txt).slot(120, 261.8, size: 52)
            Text(readingID != nil ? "读完以后，经历和技术都会记下来，" : "职绘会记住你写过的经历、练过的题、面过的每一场，")
                .font(V3.sans(17)).foregroundStyle(V3.sub).slot(120, 350.8, size: 17)
            Text(readingID != nil ? "可以先去别处看看，这里会自动更新。" : "之后改简历、练面试、复盘，都接着这些往下帮你。")
                .font(V3.sans(17)).foregroundStyle(V3.sub).slot(120, 380.8, size: 17)
            if readingID == nil {
                HStack(spacing: 24) {
                    Button { if let guest { guest(); return }; importFile = nil; importOpen = true } label: {
                        HStack(spacing: 1) { Text("导入简历"); Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)) }
                            .padding(.leading, 12)
                    }.buttonStyle(HomePillStyle(width: 128))
                    Button(action: writeOne) {
                        HStack(spacing: 8) { Text("没有现成的，写一份"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                    }.buttonStyle(HomeTextLinkStyle()).disabled(busy)
                }.offset(x: 120, y: 446)
            }
            stack.frame(width: 460, height: 600, alignment: .topLeading).offset(x: 600, y: 100)
            if let notice {
                Text(notice).font(V3.sans(13)).foregroundStyle(V3.sub).slot(120, 510, size: 13)
            }
        }
        .frame(width: 1151, height: 828, alignment: .topLeading)
        .onExitCommand { if mode == .open { mode = .idle } }
        .centeredSheet(isPresented: $importOpen) {
            ResumeImportSheet(initialFile: importFile, close: { importOpen = false }, accepted: { _ in
                importOpen = false
                Task { await findReading() }
            })
        }
        .task { if guest == nil { await findReading() } }
        .task(id: readingID) { await pollReading() }
    }

    // 右边的纸（P1–P5，设计稿坐标减去 (600,100)）：默认后面一张、前面一张空白纸；悬停摆正抬起；点开变两个选项；
    // 拖文件变蓝色虚线；正在读按分区依次变深。纸 360×480，圆角 6。
    private var stack: some View {
        let flat = mode != .idle || hovering || readingID != nil
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xF6F5F0))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xE7E5DE)))
                .frame(width: 360, height: 480)
                .opacity(flat ? 0 : 1)
                .offset(x: 10, y: 50)
            paper
                .frame(width: 360, height: 480)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(mode == .drag ? V3.blue : Color(hex: 0xE7E5DE), style: StrokeStyle(lineWidth: mode == .drag ? 1.5 : 1, dash: mode == .drag ? [5, 4] : [])))
                .shadow(color: .black.opacity(flat && readingID == nil ? 0.14 : 0.08), radius: flat && readingID == nil ? 44 : 28, y: flat && readingID == nil ? 22 : 12)
                .offset(x: flat ? 40 : 80, y: flat ? (readingID != nil ? 20 : 10) : 20)
            if let hint {
                Text(hint).font(V3.sans(13)).foregroundStyle(readingID != nil ? V3.blue : Color(hex: 0xA5A39B))
                    .slot(flat ? 40 : 44.5, flat ? 543.2 : 555.2, size: 13, width: 360, center: true)
            }
        }
        .animation(.timingCurve(0.2, 0, 0, 1, duration: 0.32), value: flat)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { mode == .drag }, set: { targeted in
            guard readingID == nil else { return }
            mode = targeted ? .drag : (mode == .drag ? .idle : mode)
        })) { providers in
            if let guest { guest(); return false }
            guard readingID == nil, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in mode = .idle; importFile = url; importOpen = true }
            }
            return true
        }
    }

    private var hint: String? {
        if readingID != nil { return "正在读\(Self.parts[read])…  大约还要 \([40, 32, 20, 12, 6][min(read, 4)]) 秒" }
        switch mode {
        case .open: return "点纸外面收回"
        case .drag: return nil
        case .idle: return hovering ? "支持 PDF、Word、Markdown" : "点这张纸，或者把简历文件拖上来"
        }
    }

    @ViewBuilder private var paper: some View {
        if readingID != nil {
            PaperSkeleton(read: read).background(Color(hex: 0xFCFBF8))
        } else if mode == .drag {
            VStack(spacing: 14) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 30, weight: .light))
                Text("松手，开始读这份简历").font(V3.sans(17, weight: .medium))
            }.foregroundStyle(V3.blue).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: 0xF3F6FD))
        } else if mode == .open {
            ZStack(alignment: .topLeading) {
                Color(hex: 0xFCFBF8)
                Text("放进你的简历").font(V3.sans(20, weight: .medium)).foregroundStyle(V3.txt).slot(36, 47, size: 20)
                Text("选一种开始，之后随时可以再换").font(V3.sans(13)).foregroundStyle(V3.fnt).slot(36, 81.2, size: 13)
                option("square.and.arrow.up", "上传简历文件", "PDF、Word、Markdown 都可以") { mode = .idle; importFile = nil; importOpen = true }
                    .offset(x: 20, y: 132)
                Rectangle().fill(Color(hex: 0xE7E5DE)).frame(width: 288, height: 1).offset(x: 36, y: 246)
                option("pencil", "从空白开始写", "没有现成的，跟着引导一段段写") { mode = .idle; writeOne() }
                    .offset(x: 20, y: 260).disabled(busy)
                Text("也可以直接把文件拖到这张纸上").font(V3.sans(12)).foregroundStyle(Color(hex: 0xA5A39B))
                    .slot(0, 434.8, size: 12, width: 360, center: true)
            }
        } else {
            Button { if let guest { guest(); return }; mode = .open } label: {
                ZStack {
                    PaperSkeleton(read: -1)
                    if hovering {
                        Color.white.opacity(0.6)
                        Text("点一下，放进你的简历").font(V3.sans(17, weight: .medium)).foregroundStyle(V3.txt)
                    }
                }.background(Color(hex: 0xFCFBF8)).contentShape(Rectangle())
            }.buttonStyle(.plain).onHover { hovering = $0 }.accessibilityLabel("放进你的简历")
        }
    }

    /// 选项行 320×84：图标 (20,24)，标题 (56,16.8)，说明 (56,45.2)，右边小箭头；悬停底 #F4F3EE、圆角 10。
    private func option(_ icon: String, _ title: String, _ sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                Color.clear
                Image(systemName: icon).font(.system(size: 18, weight: .light)).foregroundStyle(V3.txt).frame(width: 20, height: 20).offset(x: 20, y: 24)
                Text(title).font(V3.sans(17, weight: .medium)).foregroundStyle(V3.txt).slot(56, 16.8, size: 17)
                Text(sub).font(V3.sans(13)).foregroundStyle(V3.fnt).slot(56, 45.2, size: 13)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Color(hex: 0xA5A39B)).frame(width: 10, height: 12).offset(x: 292, y: 27)
            }.frame(width: 320, height: 84).contentShape(Rectangle())
        }.buttonStyle(OptionStyle())
    }

    private struct OptionStyle: ButtonStyle {
        @State private var hovering = false
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.background(hovering ? Color(hex: 0xF4F3EE) : .clear, in: RoundedRectangle(cornerRadius: 10)).onHover { hovering = $0 }
        }
    }

    /// 首页“写一份”：用默认模板新建（固定名字，重名加序号）并进编辑器引导。
    private func writeOne() {
        if let guest { guest(); return }
        guard !busy else { return }
        busy = true; notice = nil
        Task {
            defer { busy = false }
            for title in ["我的第一份简历", "我的第一份简历 2", "我的第一份简历 3"] {
                do {
                    let result = try await session.api.careerRequest(path: "/api/resumes", method: "POST", query: [:],
                                                                     body: .object(["title": .string(title), "guide": .bool(true)]))
                    let id = (result["resume"] ?? result).display("id")
                    if !id.isEmpty { editResume(id) }
                    return
                } catch APIError.server(_, "RESUME_TITLE_CONFLICT") {
                    continue
                } catch APIError.server(_, let code) {
                    notice = code == "RESUME_LIMIT_REACHED" ? "简历数量已到上限，删掉一份再新建。" : code == "TEMPLATE_INACTIVE" ? "暂时没有可用的模板，稍后再试。" : "没能新建简历，请重试。"
                    return
                } catch { notice = "没能新建简历，请重试。"; return }
            }
            notice = "没能新建简历，请重试。"
        }
    }

    /// 刷新后也要知道还有一份在读：取导入列表里还没读完的一份。
    /// 导入任务只在 `/api/resume-overview` 里（简历列表接口不带）；它不进读缓存，轮询直接查它。
    private func findReading() async {
        guard let result = try? await session.api.careerRequest(path: "/api/resume-overview", method: "GET", query: [:], body: nil) else { return }
        let active = (result["active_imports"]?.items ?? []).first { item in
            !["failed"].contains(item.text("upload_status")) && !["failed", "succeeded"].contains(item.text("parse_status"))
        }
        let wasReading = readingID != nil
        readingID = active.map { $0.display("id") }.flatMap { $0.isEmpty ? nil : $0 }
        if readingID == nil, !(result["resumes"]?.items ?? []).isEmpty {
            if wasReading { await session.api.purgeCache() }
            reload()
        }
    }

    /// P5 正在读：纸上每 2.4 秒亮一段；每 3 秒查一次，读完由首页重新取数换成有简历的首页。
    private func pollReading() async {
        guard readingID != nil else { return }
        read = 0
        var tick = 0
        var parseMark = EventHub.shared.mark("parse_task", nil)
        while !Task.isCancelled, readingID != nil {
            try? await Task.sleep(for: .milliseconds(600))
            tick += 1
            if tick % 4 == 0 { withAnimation(.easeOut(duration: 0.42)) { read = min(read + 1, Self.parts.count - 1) } }
            // 每 3 秒查一次；实时事件连着时只在导入任务有变化或每 30 秒兜底时查。App 不在前台时只走动画不查
            let changed = EventHub.shared.mark("parse_task", nil) != parseMark
            if NSApp.isActive, EventHub.shared.live ? (changed || tick % 50 == 0) : tick % 5 == 0 {
                parseMark = EventHub.shared.mark("parse_task", nil)
                await findReading()
            }
        }
    }
}

/// 纸面骨架（Web `PaperSkeleton`，取自 02A·01 P2）；part：0 抬头 1 教育 2 实习 3 项目 4 技能，“正在读”按 part 依次变深。
private struct PaperSkeleton: View {
    let read: Int
    private enum Kind { case name, role, dot, contact, rule, brand, head, unit, date, bullet, line, tag, avatar }
    private struct Bar { let kind: Kind; let x, y, w, h: CGFloat; let part: Int }
    private static func entry(_ y: CGFloat, _ lines: [CGFloat], _ part: Int) -> [Bar] {
        [Bar(kind: .unit, x: 31, y: y, w: 116, h: 6, part: part), Bar(kind: .date, x: 281, y: y, w: 46, h: 5, part: part)]
            + lines.enumerated().flatMap { i, w in
                [Bar(kind: .bullet, x: 33, y: y + 15 + CGFloat(i) * 12, w: 3, h: 3, part: part), Bar(kind: .line, x: 42, y: y + 14 + CGFloat(i) * 12, w: w, h: 5, part: part)]
            }
    }
    private static let bars: [Bar] = [
        Bar(kind: .name, x: 31, y: 33, w: 132, h: 15, part: 0), Bar(kind: .role, x: 31, y: 57, w: 86, h: 8, part: 0), Bar(kind: .avatar, x: 281, y: 29, w: 46, h: 46, part: 0),
        Bar(kind: .dot, x: 31, y: 81, w: 6, h: 6, part: 0), Bar(kind: .contact, x: 42, y: 81.5, w: 52, h: 5, part: 0),
        Bar(kind: .dot, x: 113, y: 81, w: 6, h: 6, part: 0), Bar(kind: .contact, x: 124, y: 81.5, w: 60, h: 5, part: 0),
        Bar(kind: .dot, x: 195, y: 81, w: 6, h: 6, part: 0), Bar(kind: .contact, x: 206, y: 81.5, w: 44, h: 5, part: 0),
        Bar(kind: .rule, x: 31, y: 105, w: 296, h: 1, part: 0), Bar(kind: .brand, x: 31, y: 104, w: 28, h: 3, part: 0),
        Bar(kind: .head, x: 31, y: 125, w: 54, h: 7, part: 1),
    ] + entry(143, [176.7], 1) + [Bar(kind: .head, x: 31, y: 185, w: 54, h: 7, part: 2)] + entry(203, [262.2, 222.3, 156.75], 2)
      + [Bar(kind: .head, x: 31, y: 269, w: 54, h: 7, part: 3)] + entry(287, [250.8, 199.5], 3) + entry(331, [228], 3)
      + [Bar(kind: .head, x: 31, y: 373, w: 40, h: 7, part: 4)]
      + [(31, 44), (82, 58), (147, 38), (192, 52), (251, 46)].map { Bar(kind: .tag, x: $0.0, y: 391, w: $0.1, h: 15, part: 4) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                shape(bar).frame(width: bar.w, height: bar.h).offset(x: bar.x, y: bar.y)
            }
        }.frame(width: 360, height: 480, alignment: .topLeading).accessibilityHidden(true)
    }

    @ViewBuilder private func shape(_ bar: Bar) -> some View {
        let on = bar.part <= read
        switch bar.kind {
        case .avatar, .dot, .bullet: Circle().fill(color(bar.kind, on))
        case .tag: RoundedRectangle(cornerRadius: 8).fill(.white).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color(hex: 0xBDBBB3) : Color(hex: 0xD6D4CC)))
        case .rule: Rectangle().fill(color(bar.kind, on))
        case .name, .role: RoundedRectangle(cornerRadius: 4).fill(color(bar.kind, on))
        default: RoundedRectangle(cornerRadius: bar.kind == .head || bar.kind == .brand ? 2 : 3).fill(color(bar.kind, on))
        }
    }

    private func color(_ kind: Kind, _ on: Bool) -> Color {
        switch kind {
        case .name: on ? Color(hex: 0x2D2D2A) : Color(hex: 0xCBC9C0)
        case .role: on ? Color(hex: 0x8F8D86) : Color(hex: 0xDAD8D0)
        case .avatar: on ? Color(hex: 0xDCDAD3) : Color(hex: 0xEBE9E3)
        case .dot, .bullet: on ? Color(hex: 0x8F8D86) : Color(hex: 0xD3D1C9)
        case .contact: on ? Color(hex: 0xB3B1A9) : Color(hex: 0xDDDBD4)
        case .rule: Color(hex: 0xE7E5DE)
        case .brand: on ? V3.blue : Color(hex: 0x9FB6EA)
        case .head: on ? Color(hex: 0x2D2D2A) : Color(hex: 0xC2C0B7)
        case .unit: on ? Color(hex: 0x6F6E68) : Color(hex: 0xD3D1C9)
        case .date: on ? Color(hex: 0xAEACA4) : Color(hex: 0xE0DED7)
        case .line: on ? Color(hex: 0xCFCDC5) : Color(hex: 0xE4E2DC)
        case .tag: .white
        }
    }
}

// MARK: 03 / 06 第一份报告之前（Figma 02A·03 H3 / H2、02A·06 K2a / K2b）

/// 新手首页进编辑器写完简历、回到首页时，首页那张简历纸从编辑器那一页的位置落到后面（Web `navigateWithPaper`，Figma H2）。
@MainActor enum HomePaperHandoff {
    static var armed = false
    static func consume() -> Bool { defer { armed = false }; return armed }
}

private struct FirstStepsHome: View {
    @Environment(SessionStore.self) private var session
    let graph: HomeGraph
    let mode: HomeStage.FirstSteps
    let mockID: String?
    let open: (String?) -> Void
    let jobs: () -> Void
    let changed: () -> Void
    @State private var detail: JSONValue?
    /// H2：纸刚从编辑器落回首页，左边先淡着、纸在中间，随后落位
    @State private var arriving = false

    private var copy: (greet: String, title: String, intro: [String], button: String, now: Int) {
        let report = detail?["report"]
        let rows = (report?["questions"]?.items ?? []).filter { $0["is_intro"]?.bool != true && $0["skipped"]?.bool != true }
        let reached = rows.filter { $0.text("outcome") == "reached" }.count
        switch mode {
        case .start: return ("简历记下了", "练一场模拟面试", ["题目按你简历里写的经历来出，大约 15 分钟。", "练完会记下你答得好和卡住的地方，", "第一份报告就从这里来。"], "开始模拟面试", 1)
        case .ongoing: return ("第一场还没练完", "接着练完第一场", ["回答都保存着，从上次停下的那题接着答。", "答完就出第一份报告。"], "继续这一场", 1)
        case .evaluating: return ("第一场练完了", "报告在整理", ["面试官在把笔记整理成你的第一份报告，大约 1 分钟。", "好了这里会亮起来，等的时候可以先去看看岗位。"], "整理中 · 约 1 分钟", 2)
        case .failed: return ("第一场练完了", "报告没整理出来", ["评估时出了点问题，你的回答都还在。", "点开这一场重新整理，再等一分钟就好。"], "去重新整理", 2)
        case .report:
            let first = report.flatMap { $0["total_score"]?.numberValue }.map { "\(rows.count) 题答到位 \(reached) 题，\(Int($0.rounded())) 分。" } ?? "分数和每道题的结论都出来了。"
            return ("第一份报告好了", "看看你答得怎么样", [first, "答得好和卡住的地方，都记进了你的长期记忆。"], "看第一份报告", 2)
        }
    }

    var body: some View {
        let copy = copy
        ZStack(alignment: .topLeading) {
            Color.white
            papers.frame(width: 560, height: 600, alignment: .topLeading).offset(x: 560, y: 110)
            Group {
                HStack(spacing: 10) {
                    BrandMark().frame(width: 28, height: 28)
                    Text(copy.greet).font(V3.sans(18, weight: .medium)).foregroundStyle(V3.txt)
                }.offset(x: 120, y: 210)
                Text(copy.title).font(V3.sans(52, weight: .medium)).foregroundStyle(V3.txt).slot(120, 261.8, size: 52)
                ForEach(Array(copy.intro.enumerated()), id: \.offset) { index, line in
                    Text(line).font(V3.sans(17)).foregroundStyle(V3.sub).slot(120, 350.8 + 30 * CGFloat(index), size: 17)
                }
                HStack(spacing: 24) {
                    Button { open(mockID) } label: {
                        HStack(spacing: 1) { Text(copy.button); if mode != .evaluating { Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)) } }
                    }.buttonStyle(mode == .evaluating ? HomePillStyle(leading: 22, trailing: 22) : HomePillStyle(leading: 34, trailing: 23)).disabled(mode == .evaluating)
                    Button(action: jobs) {
                        HStack(spacing: 8) { Text("导入岗位"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                    }.buttonStyle(HomeTextLinkStyle())
                }.offset(x: 120, y: 476)
                steps(now: copy.now).offset(x: 120, y: 576)
            }.opacity(arriving ? 0.35 : 1)
            if arriving { handoffArrow }
        }
        .frame(width: 1151, height: 828, alignment: .topLeading)
        .task(id: "\(mockID ?? "")|\(mode.rawValue)") { await loadDetail() }
        .task(id: mode == .evaluating ? mockID : nil) { await pollEvaluating() }
        .task { await playHandoff() }
    }

    private func playHandoff() async {
        guard mode == .start, HomePaperHandoff.consume() else { return }
        arriving = true
        try? await Task.sleep(for: .milliseconds(450))
        withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.7)) { arriving = false }
    }

    /// H2 右上角那条蓝色虚线箭头：纸往后面飞。
    private var handoffArrow: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 902, y: 98))
                path.addQuadCurve(to: CGPoint(x: 1052, y: 91), control: CGPoint(x: 975, y: 58))
            }.stroke(V3.blue, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [4, 3]))
            Path { path in
                path.move(to: CGPoint(x: 1042, y: 83)); path.addLine(to: CGPoint(x: 1053, y: 91)); path.addLine(to: CGPoint(x: 1042, y: 99))
            }.stroke(V3.blue, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }.transition(.opacity).allowsHitTesting(false)
    }

    /// 走到哪一步：简历 — 模拟面试 — 第一份报告，三段之间 24 宽的细线。
    private func steps(now: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(["简历", "模拟面试", "第一份报告"].enumerated()), id: \.offset) { index, label in
                if index > 0 { Rectangle().fill(Color(hex: 0xDCDAD2)).frame(width: 24, height: 1).padding(.horizontal, 10) }
                HStack(spacing: 6) {
                    if index < now { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(V3.fnt) }
                    else if index == now { Circle().fill(V3.blue).frame(width: 7, height: 7) }
                    else { Circle().strokeBorder(V3.fnt2, lineWidth: 1.2).frame(width: 6, height: 6) }
                    Text(label).font(V3.sans(13, weight: index == now ? .medium : .regular)).foregroundStyle(index == now ? V3.txt : V3.fnt)
                }
            }
        }.frame(height: 20).accessibilityElement(children: .combine).accessibilityLabel("走到哪一步")
    }

    /// 右边两张纸（设计稿坐标减去 (560,110)）：后面是真实简历 340×481，前面是第一场面试或第一份报告 360×480；跟 Web `.hfs-resume` / `.hfs-sheet`，以左上角为轴，简历往右倾 6°，面试纸往左倾 3°。
    private var papers: some View {
        ZStack(alignment: .topLeading) {
            if let id = graph.resumeID {
                HomeResumePaper(resumeID: id)
                    .frame(width: 340, height: 481)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xE7E5DE)))
                    .shadow(color: .black.opacity(0.09), radius: 24, y: 18)
                    .rotationEffect(.degrees(arriving ? 0 : 6), anchor: .topLeading)
                    .offset(x: arriving ? -180 : 30, y: arriving ? -50 : 40)
            }
            Button { open(mockID) } label: { mode == .report ? AnyView(reportSheet) : AnyView(interviewSheet) }
                .buttonStyle(SheetStyle())
                .rotationEffect(.degrees(-3), anchor: .topLeading)
                .offset(x: 170, y: 18)
                .opacity(arriving ? 0 : 1)
                .disabled(mode == .evaluating)
            Text(mode == .report ? "点这张纸，看报告" : mode == .evaluating ? "报告好了会出现在这里" : "点这张纸，开始第一场")
                .font(V3.sans(13)).foregroundStyle(V3.fnt).slot(170, 553.2, size: 13, width: 360, center: true)
                .opacity(arriving ? 0 : 1)
        }
    }

    private struct SheetStyle: ButtonStyle {
        @State private var hovering = false
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(width: 360, height: 480)
                .background(Color(hex: 0xFCFBF8))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xE7E5DE)))
                .shadow(color: .black.opacity(hovering ? 0.12 : 0.09), radius: hovering ? 28 : 24, y: hovering ? 22 : 18)
                .offset(y: hovering ? -2 : 0)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.16), value: hovering)
        }
    }

    /// 面试纸（H3 / K2a）：坐标是纸内（0,0）起的设计稿位置；纸只露前两道题，下沿渐隐。
    private var interviewSheet: some View {
        let main = (detail?["questions"]?.items ?? []).filter { $0.text("kind") == "main" && !$0.text("content").isEmpty }
        let total = Int(detail?["question_count"]?.numberValue ?? 3)
        let firstText = main.first?.text("content") ?? graph.topics.first.map { "讲讲你在「\($0)」里做的事，为什么这样设计？" } ?? "先做个自我介绍，再挑一段你最熟的经历讲讲。"
        let secondText = main.dropFirst().first?.text("content") ?? graph.topics.dropFirst().first.map { "「\($0)」里最难的一处是怎么解决的？" } ?? "这段经历里最难的一处是怎么解决的？"
        let answer = main.first?.text("answer_text").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let answered = mode != .start && !answer.isEmpty
        let status: String = switch mode {
        case .start: "第一场 · \(total) 题 · 约 15 分钟"
        case .ongoing: "第一场 · 答到第 \(max(1, Int(detail?["answered_main_questions"]?.numberValue ?? 0) + 1)) 题"
        case .failed: "报告没整理出来 · 回答都还在"
        default: "报告整理中，约 1 分钟"
        }
        let faint = Color(hex: 0xA5A39B)
        return ZStack(alignment: .topLeading) {
            Text("第 1 题 · 来自你的简历").font(V3.sans(11)).foregroundStyle(V3.fnt).slotC(33, 43, size: 11)
            Text(firstText).font(V3.serif(21)).fontWeight(.semibold).lineHeight(21, 31, .serif).foregroundStyle(V3.txt)
                .frame(width: 296, alignment: .topLeading).fixedSize(horizontal: false, vertical: true).offset(x: 32, y: 60.5)
            Wave(live: answered).frame(width: 296).offset(x: 32, y: 149)
            if answered {
                Text("你答").font(V3.sans(11)).foregroundStyle(V3.fnt).slotC(33, 214, size: 11)
                (Text(String(answer.prefix(26))).foregroundStyle(V3.txt) + Text(String(answer.dropFirst(26).prefix(34)) + (answer.count > 60 ? "……" : "")).foregroundStyle(faint))
                    .font(V3.sans(13)).lineHeight(13, 18).frame(width: 296, alignment: .topLeading).fixedSize(horizontal: false, vertical: true).offset(x: 33, y: 229)
            } else {
                Text(mode == .start ? "轮到你时，直接开口说就行" : "还没答到这一题").font(V3.sans(11.5)).foregroundStyle(V3.fnt).slotC(33, 211, size: 11.5)
            }
            Rectangle().fill(Color(hex: 0xEFEEE9)).frame(width: 296, height: 1).offset(x: 32, y: answered ? 296 : 250)
            Text(mode == .start ? "第 2 题 · 来自你的简历" : "第 2 题").font(V3.sans(11)).foregroundStyle(faint).slotC(33, answered ? 330 : 282, size: 11)
            Text(secondText).font(V3.serif(15)).fontWeight(.semibold).foregroundStyle(V3.sub)
                .frame(width: 296, alignment: .topLeading).fixedSize(horizontal: false, vertical: true).offset(x: 33, y: (answered ? 352 : 307) - 11)
            if mode == .start { Text("第 3 题 · 开始后，接着你的回答追问").font(V3.sans(11)).foregroundStyle(faint).slotC(33, 355, size: 11) }
            fade
            Text(status).font(V3.sans(11.5)).foregroundStyle(V3.fnt).slotC(33, 434, size: 11.5)
        }.frame(width: 360, height: 480, alignment: .topLeading)
    }

    /// 报告纸（K2b）：分数和前几题的结论是真实的，下沿渐隐，只写“还有几题 / 看完整报告 →”。
    private var reportSheet: some View {
        let report = detail?["report"]
        let rows = (report?["questions"]?.items ?? []).filter { $0["is_intro"]?.bool != true && $0["skipped"]?.bool != true }
        let reached = rows.filter { $0.text("outcome") == "reached" }.count
        let weak = rows.filter { ["one_short", "missed"].contains($0.text("outcome")) }.count
        let company = detail.map { d in d.text("company_name").isEmpty ? d.text("target_role") : [d.text("company_name"), d.text("job_title")].filter { !$0.isEmpty }.joined(separator: " · ") } ?? ""
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Text(report?["total_score"]?.numberValue.map { "\(Int($0.rounded()))" } ?? "—").font(V3.serif(50)).fontWeight(.semibold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text([company, "第一场"].filter { !$0.isEmpty }.joined(separator: " · ")).font(V3.sans(11)).foregroundStyle(V3.fnt)
                        Text("\(rows.count) 题答到位 \(reached) 题，\(weak) 处要补").font(V3.sans(13, weight: .medium))
                    }
                }
                Rectangle().fill(Color(hex: 0xEFEEE9)).frame(height: 1).padding(.top, 6)
                Text("每道题").font(V3.serif(15)).fontWeight(.semibold).padding(.top, 19)
                VStack(spacing: 0) {
                    ForEach(Array(rows.prefix(4).enumerated()), id: \.offset) { index, row in
                        if index > 0 { Rectangle().fill(Color(hex: 0xEFEEE9)).frame(height: 1) }
                        HStack(spacing: 12) {
                            Text("\(Int((row["score"]?.numberValue ?? 0).rounded()))").font(V3.serif(22)).fontWeight(.semibold).frame(width: 34, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.text("topic")).font(V3.sans(13, weight: .medium)).lineLimit(1)
                                Text(row["highlights"]?.items.first?.stringValue ?? row["weaknesses"]?.items.first?.stringValue ?? "").font(V3.sans(11)).foregroundStyle(V3.fnt).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            let outcome = ["reached": "答到位", "one_short": "差一点", "missed": "没答上"][row.text("outcome")] ?? ""
                            Text(outcome).font(V3.sans(11.5, weight: outcome == "答到位" ? .regular : .medium)).foregroundStyle(outcome == "答到位" ? V3.fnt : Color(hex: 0xC9651B))
                        }.padding(.vertical, 13)
                    }
                }.padding(.top, 10)
            }.foregroundStyle(V3.txt).frame(width: 296, alignment: .leading).offset(x: 34, y: 38)
            fade
            HStack {
                Text(rows.count > 4 ? "还有 \(rows.count - 4) 题 · \(weak) 处建议补" : "\(weak) 处建议补").font(V3.sans(11.5)).foregroundStyle(V3.fnt)
                Spacer()
                Text("看完整报告 →").font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.blue)
            }.frame(width: 296).offset(x: 33, y: 424)
        }.frame(width: 360, height: 480, alignment: .topLeading)
    }

    private var fade: some View {
        LinearGradient(stops: [.init(color: Color(hex: 0xFCFBF8).opacity(0), location: 0), .init(color: Color(hex: 0xFCFBF8), location: 0.6)], startPoint: .top, endPoint: .bottom)
            .frame(width: 360, height: 174).offset(y: 305.6).allowsHitTesting(false)
    }

    private func loadDetail() async {
        guard let mockID else { detail = nil; return }
        detail = try? await session.api.careerRequest(path: "/api/mock-interviews/\(mockID)", method: "GET", query: [:], body: nil)["mock_interview"]
    }

    /// 报告整理中：4 秒起逐步放慢到 20 秒查一次，好了首页原地换成“报告好了”。
    private func pollEvaluating() async {
        guard mode == .evaluating, let mockID else { return }
        var attempt = 0
        while await Polling.wait(attempt, first: 4, cap: 20, topic: "mock_interview", ref: mockID) {
            attempt += 1
            if let value = try? await session.api.careerRequest(path: "/api/mock-interviews/\(mockID)", method: "GET", query: [:], body: nil)["mock_interview"],
               value.text("status") != "evaluating" { await session.api.purgeCache(); changed(); return }
        }
    }
}

/// 面试纸上的声波：56 根竖条，答过后变蓝。
private struct Wave: View {
    let live: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(0..<56, id: \.self) { index in
                let envelope = sin(Double.pi * Double(index) / 55)
                let height = max(2, (26 * envelope * (0.45 + 0.55 * abs(sin(Double(index) * 0.9 + 1.3) * cos(Double(index) * 0.7)))).rounded())
                if index > 0 { Spacer(minLength: 0) }
                RoundedRectangle(cornerRadius: 1.1).fill(live ? V3.blue : Color(hex: 0xCCC9C2)).frame(width: 2.2, height: height)
            }
        }.frame(height: 28).accessibilityHidden(true)
    }
}

/// 首页右边那页真实简历（与编辑器同一页的第一页）。
struct HomeResumePaper: View {
    @Environment(SessionStore.self) private var session
    let resumeID: String
    @State private var paper: ResumeRenderRequest?
    @State private var image: NSImage?

    /// 首页后面这张纸：网页视图不受 SwiftUI 裁剪和层级约束（会溢出纸面、盖到前面的面试纸上），所以先在原地（透明）按第一页模式渲染，截成图片后由 SwiftUI 缩放、裁剪，并卸掉网页视图。
    var body: some View {
        GeometryReader { geometry in
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: geometry.size.width, height: geometry.size.width * 1123 / 794)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            } else if let paper {
                ResumePaperView(request: paper, onError: { _ in }, onSnapshot: { image = $0 })
                    .frame(width: geometry.size.width, height: geometry.size.width * 1123 / 794)
                    .opacity(0.001)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .clipped()
                    .allowsHitTesting(false)
            }
        }.background(.white).accessibilityHidden(true)
            .task(id: resumeID) {
                image = nil
                guard let resume = try? await session.api.listResumes().first(where: { $0.id == resumeID }),
                      let request = resume.renderRequest() else { return }
                paper = try? await session.api.preparePaper(request.firstPage()).request
            }
    }
}

// MARK: 07 日常首页（Figma 02A·07、5:7·01.04–01.07，Web FeedbackHome）

private struct FeedbackHome: View {
    @Environment(SessionStore.self) private var session
    let graph: HomeGraph
    let editResume: (String) -> Void
    let practice: (PracticeFocus?) -> Void
    let openMock: (String, Bool) -> Void
    let navigate: (WorkspaceSection) -> Void
    /// 图谱「聊一聊」侧栏右上 ↗：在对话页打开同一条对话；nil 时不显示 ↗
    var openChat: ((String) -> Void)? = nil
    /// 侧栏里新建或更新了对话：侧栏“最近对话”重新读取
    var chatsChanged: (() -> Void)? = nil
    @State private var picked = 0
    @State private var expanded = false
    /// 小图和展开大图的坐标：节点多时排布要算一会儿，放到后台
    @State private var stage: HomeGraphStage?
    /// 展开的图谱右边正在聊的节点（Figma 02A·10 ②）
    @State private var chat: HomeChatTopic?
    /// 同一个知识点再点「聊一聊」接着上次那段聊（只在这次打开页面期间记得）
    @State private var chatSessions: [String: String] = [:]
    /// 图谱区域（`.hf-slot`）的实际大小：小图按它等比缩放，左边列表按它对齐
    @State private var slot: CGSize = .zero
    /// 最近进展列表的高度：窗口变了才重新取（Web `listHeight`），切换条目时图不跟着跳
    @State private var listHeight: Double?
    @State private var listNow: Double = 0

    private struct ListKey: Hashable { let size: CGSize; let items: Int
        func hash(into hasher: inout Hasher) { hasher.combine(size.width); hasher.combine(size.height); hasher.combine(items) }
    }

    /// 有节点就画图谱，不等掌握结论；一个节点都没有时右边换成一句话
    private var graphReady: Bool { !graph.nodes.isEmpty }
    private var hasTimeline: Bool { !graph.timeline.isEmpty }
    /// K4（Figma 02A·06 61:3081）：第一次进记忆首页（只练过一场）时压暗，只亮知识图谱，浮层解释长期记忆
    private var coach: CoachSlot { CoachSlot(id: "memory-home-first", user: session.coachUser) }
    private var showCoach: Bool { coach.open && !expanded && graphReady && graph.sources.mocks <= 1 }

    var body: some View {
        GeometryReader { geometry in
            // Web 的 vw / vh 是视口：这里取窗口内容区（首页贴着窗口右下角，全局坐标的右下角就是窗口宽高）
            let global = geometry.frame(in: .global)
            let layout = HomeFeedbackLayout(window: CGSize(width: global.maxX, height: global.maxY), container: geometry.size)
            Group {
                if layout.narrow {
                    // ≤980：页面不再铺满一屏，单栏往下排、整页滚动（Web `.hf-root { position: relative }`）
                    ScrollView { page(layout) }
                } else {
                    page(layout).frame(maxHeight: .infinity)
                }
            }
            .opacity(expanded ? 0 : 1)
            .overlay {
                if expanded {
                    expandedLayer.transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            // 窗口变了，列表高度重新量（Web 的 onResize 里 listHeight = null）
            .task(id: ListKey(size: geometry.size, items: graph.timeline.count)) {
                listHeight = nil
                try? await Task.sleep(for: .milliseconds(120))
                if listHeight == nil { listHeight = listNow }
            }
        }
        .task(id: graph) {
            let graph = graph
            stage = await Task.detached(priority: .userInitiated) { HomeGraphStage(graph: graph) }.value
        }
        .onExitCommand {
            if chat != nil { withAnimation(.easeOut(duration: 0.2)) { chat = nil } }
            else if expanded { withAnimation { expanded = false } }
        }
    }

    /// `.hf-page > .hf-inner`：上面首屏（左进展、右图谱）占满剩余高度，下面六个入口。
    private func page(_ l: HomeFeedbackLayout) -> some View {
        VStack(spacing: 0) {
            hero(l).frame(maxHeight: l.narrow ? nil : .infinity)
            strips(l).padding(.top, l.rowTop)
        }
        .frame(width: l.innerWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, l.padX).padding(.top, l.padTop).padding(.bottom, l.padBottom)
    }

    /// `.hf-hero`：两栏 1fr : 1.2fr、间距 40，竖直方向拉满；≤980 单栏。
    private func hero(_ l: HomeFeedbackLayout) -> some View {
        let k = l.scale
        let fit = graphFit(l)
        let stack = l.narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: l.heroGap)) : AnyLayout(HStackLayout(alignment: .top, spacing: l.heroGap))
        return stack {
            // 最近进展为空或图谱没有节点时，左栏不再跟图谱对齐，竖直居中（`.hf-left.is-centered`）
            Group {
                if hasTimeline {
                    timeline(l)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: Double.self, of: { Double($0.size.height) }) { height in
                            listNow = height
                            if listHeight == nil { listHeight = height }
                        }
                        .padding(.top, graphReady ? fit.listTop ?? 0 : 0)
                } else { summary(l) }
            }
            .frame(width: l.leftWidth, alignment: .leading)
            .frame(maxHeight: l.narrow ? nil : .infinity, alignment: hasTimeline && graphReady ? .topLeading : .leading)
            VStack(spacing: 0) {
                // `.hf-slotfoot`：行高 22，下边距 4
                HStack(spacing: 22 * k) {
                    Spacer()
                    (Text("知识图谱").foregroundStyle(V3.txt).fontWeight(.medium) +
                     Text(graphReady ? (graph.weakPoints > 0 ? "   \(graph.points) 个知识点，\(graph.weakPoints) 个还不牢" : "   \(graph.points) 个知识点") : "").foregroundStyle(V3.fnt))
                        .font(V3.sans(13 * k))
                    if graphReady {
                        Button { withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.6)) { expanded = true } } label: {
                            HStack(spacing: 6 * k) { Text("展开"); Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11 * k, weight: .medium)) }
                        }.buttonStyle(.plain).font(V3.sans(13 * k, weight: .medium)).foregroundStyle(V3.txt)
                    }
                }.frame(height: 22 * k).padding(.bottom, 4 * k)
                if graphReady {
                    // `.hf-slot`：min-height 240、flex 1；≤980 时页面不定高，只剩最小高度
                    HomeGraphCanvas(graph: graph, stage: stage, scale: k, stretch: fit.stretch)
                        .frame(minHeight: 240 * k, maxHeight: l.narrow ? 240 * k : .infinity)
                        .onGeometryChange(for: CGSize.self, of: { $0.size }) { slot = $0 }
                        .onTapGesture(count: 2) { withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.6)) { expanded = true } }
                } else {
                    // 一个节点都没有（记忆还没读到简历，或刚清空过）：`.hf-pending`
                    VStack(alignment: .leading, spacing: 10 * k) {
                        Text("图谱里还没有内容").font(V3.sans(22 * k, weight: .medium)).foregroundStyle(V3.txt)
                        Text("简历里的经历和技术、练过的面试，都会画在这里。").font(V3.sans(14 * k)).lineHeight(14 * k, 24 * k).foregroundStyle(V3.sub)
                            .frame(maxWidth: 440 * k, alignment: .leading).padding(.bottom, 22 * k)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240 * k, maxHeight: l.narrow ? nil : .infinity, alignment: .leading)
                    .padding(.horizontal, l.pendingPad)
                }
            }.frame(width: l.rightWidth)
                .frame(maxHeight: l.narrow ? nil : .infinity, alignment: .top)
                .coachTarget(showCoach, label: "长期记忆引导", message: "这是你的长期记忆。简历、面试和岗位里的东西\n都连在这里，每练一场都会更新。",
                             actions: [CoachAction(label: "知道了")], padding: 8, corner: 12) { coach.dismiss() }
        }
    }

    /// 小图的竖直拉伸，和左边列表要往下让的距离（Web `feedbackStage.ts` 收起态的 align）：
    /// 列表顶对齐图上最高的节点，图上下拉伸到和列表一样高（0.8…1.32 倍）。≤980 或没有节点时不对齐。
    private func graphFit(_ l: HomeFeedbackLayout) -> (stretch: Double, listTop: Double?) {
        guard !l.narrow, let stage, slot.width > 0, slot.height > 0 else { return (1, nil) }
        let byID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let spots = stage.home.compactMap { id, spot in byID[id].map { (y: spot.y, half: HomeGraphCanvas.halfHeight($0, scale: l.scale)) } }
        guard let top = spots.min(by: { $0.y < $1.y }), let bottom = spots.max(by: { $0.y < $1.y }) else { return (1, nil) }
        let stretch = HomeGraphFit.stretch(size: slot, top: top.y, bottom: bottom.y, topHalf: top.half, bottomHalf: bottom.half,
                                           list: listHeight ?? (listNow > 0 ? listNow : nil), scale: l.scale)
        guard let edge = HomeGraphFit.topEdge(size: slot, spots: spots, stretch: stretch) else { return (stretch, nil) }
        // 图谱区域在首屏里的顶 = 标题行 22 + 4
        return (stretch, max(0, 26 * l.scale + edge - 3 * l.scale))
    }

    /// 展开：铺满整页，左边图谱卡片，右边对话栏（点「聊一聊」才出现）。
    private var expandedLayer: some View {
        HStack(spacing: 0) {
            HomeGraphExpandedView(graph: graph, stage: stage, compact: chat != nil, chatKey: chat?.key,
                                  collapse: { withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.5)) { chat = nil; expanded = false } },
                                  chat: { topic in withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.4)) { chat = topic } })
                .padding(.leading, 24).padding(.vertical, 24).padding(.trailing, chat == nil ? 24 : 16)
            if let chat {
                HomeGraphChatPanel(topic: chat, sessionID: chatSessions[chat.key],
                                   created: { id in chatSessions[chat.key] = id; chatsChanged?() },
                                   sessionsChanged: { chatsChanged?() },
                                   expand: openChat,
                                   close: { withAnimation(.easeOut(duration: 0.2)) { self.chat = nil } })
                    .id(chat.key)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }.background(.white)
    }

    /// R2（Figma 5:7·01.07）：最近进展为空时左边直接说结论（最稳、最该补的一处）；还没有结论时只说接着练。
    private func summary(_ l: HomeFeedbackLayout) -> some View {
        let k = l.scale
        let summary = HomeSummary.of(graph)
        let lastMock = graph.entries?.mockLastID
        return HStack(alignment: .top, spacing: 16 * k) {
            Circle().fill(V3.blue).frame(width: 10 * k, height: 10 * k).padding(.top, 6 * k)
            VStack(alignment: .leading, spacing: 0) {
                Text(summary.eyebrow).font(V3.sans(13 * k)).tracking(0.5 * k).lineHeight(13 * k, 22 * k).foregroundStyle(V3.fnt).padding(.bottom, 14 * k)
                Text(summary.title.joined(separator: "\n")).font(V3.sans(l.title, weight: .semibold)).lineHeight(l.title, l.title * 1.32).foregroundStyle(V3.txt).minimumScaleFactor(0.6)
                Text(summary.desc).font(V3.sans(16 * k)).lineHeight(16 * k, 28 * k).foregroundStyle(V3.sub).frame(maxWidth: 544 * k, alignment: .leading).padding(.top, 14 * k).padding(.bottom, 22 * k)
                HStack(spacing: 22 * k) {
                    if graph.hasConclusions, let weakest = graph.weakest {
                        pill("练\(weakest.name.components(separatedBy: "（").first ?? weakest.name)", k) { practice(PracticeFocus(kind: "topic", ref: weakest.key, label: weakest.name, origin: "assistant")) }
                    } else {
                        pill("再练一场", k) { practice(nil) }
                    }
                    if let lastMock {
                        Button { openMock(lastMock, true) } label: {
                            HStack(spacing: 2 * k) { Text("看最近一场的报告"); Image(systemName: "chevron.right").font(.system(size: 11 * k)) }
                        }.buttonStyle(HomeTextLinkStyle(size: 14 * k))
                    }
                }.padding(.bottom, 18 * k)
                Text("之后练面试、改简历、投岗位，进展会记在这里").font(V3.sans(13.5 * k)).lineHeight(13.5 * k, 22 * k).foregroundStyle(Color(hex: 0x87867F)).padding(.top, 22 * k)
            }
        }
    }

    // 最近进展：选中的一条展开成大标题、说明和按钮，其余收成一行
    private func timeline(_ l: HomeFeedbackLayout) -> some View {
        let k = l.scale
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(graph.timeline.enumerated()), id: \.element.id) { index, item in
                let text = HomeProgressText.text(item, weakPoints: graph.weakPoints, hasConclusions: graph.hasConclusions)
                let on = index == picked
                HStack(alignment: .top, spacing: 16 * k) {
                    ZStack(alignment: .top) {
                        if index < graph.timeline.count - 1 {
                            Rectangle().fill(Color(hex: 0xD5D3C9)).frame(width: 1).padding(.top, (on ? 17 : 31) * k).frame(maxHeight: .infinity)
                        }
                        Circle().fill(on ? V3.blue : .white).overlay(Circle().strokeBorder(on ? V3.blue : Color(hex: 0xBDBBB2)))
                            .frame(width: (on ? 10 : 8) * k, height: (on ? 10 : 8) * k).padding(.top, (on ? 6 : 20) * k)
                    }.frame(width: 10 * k)
                    if on { expandedItem(item, text, l) } else {
                        Button { withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.55)) { picked = index } } label: {
                            HStack(alignment: .top, spacing: 16 * k) {
                                Text(HomeProgressText.when(item.date, today: graph.today)).font(V3.sans(13 * k)).foregroundStyle(V3.fnt).monospacedDigit().frame(width: 52 * k, alignment: .leading)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(text.short).font(V3.sans(15 * k)).lineHeight(15 * k, 24 * k).foregroundStyle(V3.txt).lineLimit(1)
                                    Text(item.source).font(V3.sans(12 * k)).lineHeight(12 * k, 18 * k).foregroundStyle(V3.fnt)
                                }
                                Spacer(minLength: 0)
                            }.padding(.vertical, 12 * k).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func expandedItem(_ item: HomeGraph.Progress, _ text: HomeProgressText.Text, _ l: HomeFeedbackLayout) -> some View {
        let k = l.scale
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(HomeProgressText.when(item.date, today: graph.today))  ·  \(item.source)").font(V3.sans(13 * k)).tracking(0.5 * k).lineHeight(13 * k, 22 * k).foregroundStyle(V3.fnt).padding(.bottom, 14 * k)
            text.lines.enumerated().reduce(Text("")) { result, pair in
                let (before, mark, after) = pair.element
                let line = Text(before) + Text(mark).foregroundColor(text.weak ? V3.orange : V3.blue) + Text(after)
                return pair.offset == 0 ? line : result + Text("\n") + line
            }
            // `.hf-title`：clamp(26px, 2.7vw, 40px)，行高 1.32
            .font(V3.sans(l.title, weight: .semibold)).lineHeight(l.title, l.title * 1.32).foregroundStyle(V3.txt).minimumScaleFactor(0.6)
            Text(text.desc).font(V3.sans(16 * k)).lineHeight(16 * k, 28 * k).foregroundStyle(V3.sub).frame(maxWidth: 544 * k, alignment: .leading).padding(.top, 14 * k).padding(.bottom, 22 * k)
            HStack(spacing: 22 * k) {
                if item.kind == .resume, let id = graph.resumeID {
                    pill("打开简历", k) { editResume(id) }
                } else if let label = item.practiceLabel ?? graph.weakest?.name {
                    // 练经历且给了延伸点：带上简历和延伸点，整段从这一点问起（Web `focusPath`）
                    let focus = item.practiceRef.map { ref in
                        item.practiceKind == "experience" && item.practiceHook != nil
                            ? PracticeFocus(kind: "experience", ref: ref, label: label, resumeID: item.practiceResumeID, scope: "all", hook: item.practiceHook, origin: "assistant")
                            : PracticeFocus(kind: item.practiceKind ?? "topic", ref: ref, label: label, origin: "assistant")
                    }
                        ?? graph.weakest.map { PracticeFocus(kind: "topic", ref: $0.key, label: $0.name) }
                    pill("练\(label.components(separatedBy: "（").first ?? label)", k) { practice(focus) }
                } else {
                    pill("再练一场", k) { practice(nil) }
                }
                if item.kind == .mock {
                    Button { openMock(item.sourceID, true) } label: {
                        HStack(spacing: 2 * k) { Text("看这一场的报告"); Image(systemName: "chevron.right").font(.system(size: 11 * k)) }
                    }.buttonStyle(HomeTextLinkStyle(size: 14 * k))
                }
            }.padding(.bottom, 18 * k)
        }.transition(.opacity)
    }

    private func pill(_ title: String, _ k: Double, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8 * k) { Text(title).lineLimit(1); Image(systemName: "arrow.right").font(.system(size: 12 * k, weight: .medium)) }
        }.buttonStyle(HomePillStyle(height: 38 * k, font: 14 * k, leading: 22 * k, trailing: 18 * k))
    }

    // 底部六个入口（`.hf-row`）：三列两行，≤980 两列；≤1100 收起每条后半句的补充（`.hf-strip-more`）
    private func strips(_ l: HomeFeedbackLayout) -> some View {
        let k = l.scale
        let entries = graph.entries
        let overstated = graph.nodes.filter(\.overstated)
        let interview: (String, String) = {
            guard let entries, let start = entries.interviewStart, let date = HomeStageDate.monthDay(start) else { return ("还没有排面试", "") }
            return ("\(date) \(entries.interviewCompany ?? "")\(entries.interviewStage ?? "面试")", entries.interviewCount > 1 ? "，共 \(entries.interviewCount) 场" : "")
        }()
        let mock: (String, String) = (entries?.mockCount ?? 0) > 0
            ? ("练过 \(entries!.mockCount) 场", entries?.mockLastScore.map { "，上一场 \(Int($0.rounded())) 分" } ?? "") : ("开始第一场", "")
        let saved: (String, String) = {
            guard let entries else { return ("还没有收藏岗位", "") }
            let base = entries.applicationsOpen > 0 ? "\(entries.applicationsOpen) 个在进行" : entries.jobsSaved > 0 ? "\(entries.jobsSaved) 个岗位" : "还没有收藏岗位"
            return (base, entries.applicationsAwaiting > 0 ? "，\(entries.applicationsAwaiting) 个等结果" : "")
        }()
        let more = { (pair: (String, String)) in Text(pair.0 + (l.showMore ? pair.1 : "")) }
        let resume = overstated.isEmpty ? Text(graph.resumeTitle)
            : l.showMore ? Text("\(overstated.count) 处写高了，") + Text(overstated[0].label).foregroundColor(Color(hex: 0xB5651A)) : Text("\(overstated.count) 处写高了")
        let items: [(String, String, Text, () -> Void)] = [
            ("calendar", "面试日程", more(interview), { navigate(.schedule) }),
            ("mic", "模拟面试", more(mock), { navigate(.mock) }),
            ("doc.text", "我的简历", resume, { if let id = graph.resumeID { editResume(id) } else { navigate(.resumes) } }),
            ("briefcase", "推荐岗位", Text("按你的简历挑岗位"), { navigate(.opportunities) }),
            ("square.split.1x2", "收藏的岗位", more(saved), { navigate(.jobs) }),
            ("folder", "资料库", Text((entries?.datasets ?? 0) > 0 ? "\(entries!.datasets) 份资料" : "还没有资料"), { navigate(.datasets) }),
        ]
        let columns = l.rowColumns
        // 每条高 52（上下 4 + 18 + 2 + 24 + 4），行距 clamp(12px, 2vh, 18px)，列距 clamp(24px, 3.4vw, 44px)
        return Grid(horizontalSpacing: l.columnGap, verticalSpacing: l.rowGap) {
            ForEach(0..<(items.count + columns - 1) / columns, id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        if row * columns + column < items.count {
                            let item = items[row * columns + column]
                            Button(action: item.3) {
                                HStack(spacing: 12 * k) {
                                    Image(systemName: item.0).font(.system(size: 19 * k, weight: .light)).foregroundStyle(V3.sub).frame(width: 26 * k, height: 26 * k)
                                    VStack(alignment: .leading, spacing: 6 * k) {
                                        Text(item.1).font(V3.sans(13 * k)).foregroundStyle(V3.fnt)
                                        HStack(spacing: 2 * k) {
                                            item.2.font(V3.sans(15 * k, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
                                            Image(systemName: "chevron.right").font(.system(size: 11 * k, weight: .medium)).foregroundStyle(Color(hex: 0xA5A39B))
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 4 * k).contentShape(Rectangle())
                            }.buttonStyle(.plain).frame(maxWidth: .infinity)
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }
}

private enum HomeStageDate {
    static func monthDay(_ iso: String) -> String? {
        let full = ISO8601DateFormatter(); full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = full.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let parts = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0)/\(parts.day ?? 0)"
    }
}

/// 首页右边的小图（Web `homeSkeleton`）：只画骨架——经历、服务的业务、多段经历共用的技术和最近几场面试；
/// 经历衬线粗体，业务前带小方块，场次前带话筒，还不牢橙色、刚练稳蓝色。
/// 坐标按 Web `feedbackStage.ts`：760 × 520 的设计稿按区域等比缩放（`HomeGraphFit`），竖直方向再按左边列表拉伸；字号只随放大倍数变。
private struct HomeGraphCanvas: View {
    let graph: HomeGraph
    let stage: HomeGraphStage?
    /// 放大倍数（`HomeFeedbackLayout.scale`）
    var scale: Double = 1
    var stretch: Double = 1
    @State private var hover: String?

    /// 节点标签半高（Web `bh`：标签上下各留 5，行高约 1.2 倍字号）
    static func halfHeight(_ node: HomeGraph.Node, scale: Double) -> Double {
        let size: Double = switch node.kind {
        case .experience: 15
        case .technology, .session: 13
        case .highlight, .point: 12
        }
        return (size * 1.2 + 10) * scale / 2
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let point = { (id: String) -> CGPoint? in
                stage?.home[id].map { HomeGraphFit.point(x: $0.x, y: $0.y, in: size, stretch: stretch) }
            }
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in stage?.homeLines ?? [] {
                        guard let a = point(edge.src), let b = point(edge.dst) else { continue }
                        var path = Path(); path.move(to: a); path.addLine(to: b)
                        let lit = hover != nil && (edge.src == hover || edge.dst == hover)
                        context.stroke(path, with: .color(lit ? Color(hex: 0xA5A39B) : Color(hex: 0xE2E0D8)), lineWidth: 1)
                    }
                }
                ForEach(graph.nodes.filter { stage?.home[$0.id] != nil }) { node in
                    if let at = point(node.id) {
                        HomeGraphLabel(node: node, large: false, core: false, scale: scale)
                            .padding(.horizontal, 6 * scale).padding(.vertical, 5 * scale)
                            .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 4 * scale))
                            .fixedSize()
                            .help(node.label)
                            .onHover { hover = $0 ? node.id : (hover == node.id ? nil : hover) }
                            .position(at)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("知识图谱，\(stage?.home.count ?? 0) 个节点")
    }
}

/// 图上的一个节点名（首页小图与展开大图共用）：经历衬线、业务前小方块、场次前话筒。
struct HomeGraphLabel: View {
    let node: HomeGraph.Node
    let large: Bool
    /// 多段经历共用的技术：展开后字更大
    let core: Bool
    var scale: CGFloat = 1
    var picked = false

    var body: some View {
        let color = tint
        HStack(spacing: node.kind == .session ? 4 : 6) {
            if node.business { Rectangle().fill(color).frame(width: 6 * scale, height: 6 * scale) }
            if node.kind == .session { Image(systemName: "mic").font(.system(size: (large ? 11 : 10) * scale)).foregroundStyle(color) }
            Text(node.short).font(font).foregroundStyle(color)
        }
    }

    private var font: Font {
        let grow: CGFloat = picked ? 1.15 : 1
        let k = scale * grow
        switch node.kind {
        case .experience: return V3.serif((large ? 19 : 15) * k).weight(.semibold)
        case .technology: return V3.sans((large ? (core ? 20 : 14) : 13) * k, weight: core && large ? .regular : .medium)
        case .session: return V3.sans((large ? 13 : 13) * k, weight: large ? .regular : .medium)
        case .highlight: return V3.sans((large ? 13 : 12) * k, weight: node.business ? .medium : .regular)
        case .point: return V3.sans((large ? 13 : 12) * k, weight: node.tone == .plain ? .regular : .medium)
        }
    }

    private var tint: Color {
        switch node.tone {
        case .hot: return V3.orange
        case .new: return V3.blue
        case .plain:
            switch node.kind {
            case .experience, .technology, .session: return V3.txt
            case .highlight: return node.business ? V3.txt : Color(hex: 0x87867F)
            case .point: return Color(hex: 0x87867F)
            }
        }
    }
}
