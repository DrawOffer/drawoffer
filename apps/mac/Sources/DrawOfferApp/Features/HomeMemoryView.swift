import AppKit
import DrawOfferCore
import DrawOfferRender
import SwiftUI
import UniformTypeIdentifiers

/// 工作区首页（macOS 设计稿 02A 页，Web `assistant/home/HomeMemory.tsx`）：
/// 没有简历 → 01 新用户（左边欢迎、右边一张能点能拖的简历纸）；有简历、第一份报告看完之前 → 03 / 06（练一场模拟面试）；
/// 有结论 → 07（最近进展 + 知识图谱 + 六个入口）。
struct HomeMemoryView: View {
    @Environment(SessionStore.self) private var session
    let editResume: (String) -> Void
    let practice: (PracticeFocus?) -> Void
    let openMock: (String, Bool) -> Void
    let navigate: (WorkspaceSection) -> Void

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
            } else if let graph, loaded {
                switch HomeStage.pick(graph: graph, mocks: mocks, reportSeen: UserDefaults.standard.bool(forKey: reportSeenKey)) {
                case .newUser:
                    HomeCanvas { NewUserHome(reload: { Task { await load() } }, editResume: editResume) }
                case .firstSteps(let mode):
                    HomeCanvas {
                        FirstStepsHome(graph: graph, mode: mode, mockID: mocks?.firstID,
                                       open: { id in
                                           if mode == .report { UserDefaults.standard.set(true, forKey: reportSeenKey) }
                                           if let id { openMock(id, mode == .report) } else { practice(nil) }
                                       },
                                       jobs: { navigate(.opportunities) }, changed: { Task { await load() } })
                    }
                case .resumeOnly:
                    HomeCanvas {
                        FirstStepsHome(graph: graph, mode: .start, mockID: nil, open: { _ in practice(nil) },
                                       jobs: { navigate(.opportunities) }, changed: { Task { await load() } })
                    }
                case .feedback:
                    FeedbackHome(graph: graph, editResume: editResume, practice: practice, openMock: openMock, navigate: navigate)
                }
            } else {
                V3Loading("正在读取首页…").frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let (g, m) = await (graphJSON, mockJSON)
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
            let scale = min(geometry.size.width / Self.size.width, geometry.size.height / Self.size.height, 1.3)
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
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(font, weight: .medium))
            .foregroundStyle(enabled ? .white : Color(hex: 0x87867F))
            .padding(.leading, 22).padding(.trailing, 20).frame(height: height)
            .background(enabled ? (hovering || configuration.isPressed ? Color(hex: 0x2F2F2C) : V3.txt) : Color(hex: 0xE7E6E0), in: Capsule())
            .onHover { hovering = $0 }
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
            }.offset(x: 146, y: 210)
            Text(readingID != nil ? "正在读你的简历" : "从第一份简历开始")
                .font(V3.sans(52, weight: .medium)).tracking(-0.52).foregroundStyle(V3.txt).fixedSize()
                .offset(x: 146, y: 258)
            Text(readingID != nil ? "读完以后，经历和技术都会记下来，\n可以先去别处看看，这里会自动更新。" : "职绘会记住你写过的经历、练过的题、面过的每一场，\n之后改简历、练面试、复盘，都接着这些往下帮你。")
                .font(V3.sans(17)).lineSpacing(7).foregroundStyle(V3.sub).fixedSize()
                .offset(x: 146, y: 346)
            if readingID == nil {
                HStack(spacing: 24) {
                    Button { if let guest { guest(); return }; importFile = nil; importOpen = true } label: {
                        HStack(spacing: 8) { Text("导入简历"); Image(systemName: "arrow.right").font(.system(size: 13, weight: .medium)) }
                    }.buttonStyle(HomePillStyle())
                    Button(action: writeOne) {
                        HStack(spacing: 3) { Text("没有现成的，写一份"); Image(systemName: "chevron.right").font(.system(size: 12)) }
                    }.buttonStyle(HomeTextLinkStyle()).disabled(busy)
                }.offset(x: 146, y: 446)
            }
            stack.frame(width: 460, height: 600).offset(x: 600, y: 100)
            if let notice {
                Text(notice).font(V3.sans(13)).foregroundStyle(V3.sub).offset(x: 146, y: 520)
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

    // 右边的纸：默认两张叠着略斜；悬停摆正抬起；点开变两个选项；拖文件变蓝色虚线；正在读按分区依次变深。
    private var stack: some View {
        let flat = mode != .idle || hovering || readingID != nil
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xF6F5F0))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xE7E5DE)))
                .shadow(color: .black.opacity(0.05), radius: 9, y: 6)
                .frame(width: 360, height: 480)
                .rotationEffect(.degrees(flat ? -2 : -5)).opacity(flat ? 0 : 1)
                .offset(x: 30.2, y: 33.4)
            paper
                .frame(width: 360, height: 480)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(mode == .drag ? V3.blue : Color(hex: 0xE7E5DE), style: StrokeStyle(lineWidth: mode == .drag ? 1.5 : 1, dash: mode == .drag ? [5, 4] : [])))
                .shadow(color: .black.opacity(flat ? 0.12 : 0.08), radius: flat ? 22 : 14, y: flat ? 22 : 10)
                .rotationEffect(.degrees(flat ? 0 : 4))
                .offset(x: flat ? 40 : 62.8, y: flat ? (readingID != nil ? 20 : 10) : 32)
            if let hint {
                Text(hint).font(V3.sans(13)).foregroundStyle(readingID != nil ? V3.blue : Color(hex: 0xA5A39B))
                    .frame(width: 360).offset(x: 40, y: flat ? 540 : 552)
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
        if readingID != nil { return "正在读\(Self.parts[read])…" }
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
                Image(systemName: "square.and.arrow.up").font(.system(size: 34, weight: .light))
                Text("松手，开始读这份简历").font(V3.sans(17, weight: .medium))
            }.foregroundStyle(V3.blue).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: 0xF3F6FD))
        } else if mode == .open {
            ZStack(alignment: .topLeading) {
                Color(hex: 0xFCFBF8)
                Text("放进你的简历").font(V3.sans(20, weight: .medium)).foregroundStyle(V3.txt).offset(x: 35, y: 43)
                Text("选一种开始，之后随时可以再换").font(V3.sans(13)).foregroundStyle(V3.fnt).offset(x: 35, y: 77)
                option("square.and.arrow.up", "上传简历文件", "PDF、Word、Markdown 都可以") { mode = .idle; importFile = nil; importOpen = true }
                    .offset(x: 19, y: 131)
                Rectangle().fill(Color(hex: 0xE7E5DE)).frame(width: 288, height: 1).offset(x: 35, y: 245)
                option("pencil", "从空白开始写", "没有现成的，跟着引导一段段写") { mode = .idle; writeOne() }
                    .offset(x: 19, y: 259).disabled(busy)
                Text("也可以直接把文件拖到这张纸上").font(V3.sans(12)).foregroundStyle(Color(hex: 0xA5A39B))
                    .frame(width: 360).offset(y: 431)
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

    private func option(_ icon: String, _ title: String, _ sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.system(size: 20, weight: .light)).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(V3.sans(17, weight: .medium)).foregroundStyle(V3.txt)
                    Text(sub).font(V3.sans(13)).foregroundStyle(V3.fnt)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14)).foregroundStyle(Color(hex: 0xA5A39B))
            }.padding(.leading, 16).padding(.trailing, 18).frame(width: 320, height: 84).contentShape(Rectangle())
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
    private func findReading() async {
        guard let result = try? await session.api.careerRequest(path: "/api/resumes", method: "GET", query: [:], body: nil) else { return }
        let imports = (result["imports"]?.items ?? []) + (result["active_imports"]?.items ?? [])
        let active = imports.first { item in
            !["failed"].contains(item.text("upload_status")) && !["failed", "succeeded"].contains(item.text("parse_status"))
        }
        readingID = active.map { $0.display("id") }.flatMap { $0.isEmpty ? nil : $0 }
        if readingID == nil, !(result["resumes"]?.items ?? []).isEmpty { reload() }
    }

    /// P5 正在读：纸上每 2.4 秒亮一段；每 3 秒查一次，读完由首页重新取数换成有简历的首页。
    private func pollReading() async {
        guard readingID != nil else { return }
        read = 0
        var tick = 0
        while !Task.isCancelled, readingID != nil {
            try? await Task.sleep(for: .milliseconds(600))
            tick += 1
            if tick % 4 == 0 { withAnimation(.easeOut(duration: 0.42)) { read = min(read + 1, Self.parts.count - 1) } }
            if tick % 5 == 0 { await findReading() }
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

// MARK: 03 / 06 第一份报告之前（Figma 02A·03 H3、02A·06 K2）

private struct FirstStepsHome: View {
    @Environment(SessionStore.self) private var session
    let graph: HomeGraph
    let mode: HomeStage.FirstSteps
    let mockID: String?
    let open: (String?) -> Void
    let jobs: () -> Void
    let changed: () -> Void
    @State private var detail: JSONValue?

    private var copy: (greet: String, title: String, intro: String, button: String, now: Int) {
        let report = detail?["report"]
        let rows = (report?["questions"]?.items ?? []).filter { $0["is_intro"]?.bool != true && $0["skipped"]?.bool != true }
        let reached = rows.filter { $0.text("outcome") == "reached" }.count
        switch mode {
        case .start: return ("简历记下了", "练一场模拟面试", "题目按你简历里写的经历来出，大约 15 分钟。\n练完会记下你答得好和卡住的地方，出第一份报告。", "开始模拟面试", 1)
        case .ongoing: return ("第一场还没练完", "接着练完第一场", "回答都保存着，从上次停下的那题接着答。\n答完就出第一份报告。", "继续这一场", 1)
        case .evaluating: return ("第一场练完了", "报告在整理", "面试官在把笔记整理成你的第一份报告，大约 1 分钟。\n好了这里会亮起来，等的时候可以先去看看岗位。", "整理中 · 约 1 分钟", 2)
        case .failed: return ("第一场练完了", "报告没整理出来", "评估时出了点问题，你的回答都还在。\n点开这一场重新整理，再等一分钟就好。", "去重新整理", 2)
        case .report:
            let first = report.flatMap { $0["total_score"]?.numberValue }.map { "\(rows.count) 题答到位 \(reached) 题，\(Int($0.rounded())) 分。" } ?? "分数和每道题的结论都出来了。"
            return ("第一份报告好了", "看看你答得怎么样", first + "\n答得好和卡住的地方，都记进了你的长期记忆。", "看第一份报告", 2)
        }
    }

    var body: some View {
        let copy = copy
        ZStack(alignment: .topLeading) {
            Color.white
            papers.frame(width: 560, height: 600).offset(x: 560, y: 110)
            HStack(spacing: 10) {
                BrandMark().frame(width: 28, height: 28)
                Text(copy.greet).font(V3.sans(16, weight: .medium)).foregroundStyle(V3.txt)
            }.offset(x: 146, y: 214)
            Text(copy.title).font(V3.sans(48, weight: .medium)).foregroundStyle(V3.txt).fixedSize().offset(x: 146, y: 252)
            Text(copy.intro).font(V3.sans(15)).lineSpacing(11).foregroundStyle(V3.sub).fixedSize().offset(x: 146, y: 340)
            HStack(spacing: 24) {
                Button { open(mockID) } label: {
                    HStack(spacing: 8) { Text(copy.button); if mode != .evaluating { Image(systemName: "arrow.right").font(.system(size: 13, weight: .medium)) } }
                }.buttonStyle(HomePillStyle(font: 14)).disabled(mode == .evaluating)
                Button(action: jobs) {
                    HStack(spacing: 4) { Text("导入岗位").foregroundStyle(V3.txt); Text("›").foregroundStyle(V3.fnt) }
                }.buttonStyle(.plain).font(V3.sans(15))
            }.offset(x: 146, y: 420)
            steps(now: copy.now).offset(x: 146, y: 516)
        }
        .frame(width: 1151, height: 828, alignment: .topLeading)
        .task(id: "\(mockID ?? "")|\(mode.rawValue)") { await loadDetail() }
        .task(id: mode == .evaluating ? mockID : nil) { await pollEvaluating() }
    }

    private func steps(now: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(["简历", "模拟面试", "第一份报告"].enumerated()), id: \.offset) { index, label in
                if index > 0 { Rectangle().fill(Color(hex: 0xDCDAD2)).frame(width: 24, height: 1).padding(.horizontal, 10) }
                HStack(spacing: 6) {
                    if index < now { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(V3.fnt) }
                    else if index == now { Circle().fill(V3.blue).frame(width: 7, height: 7) }
                    else { Circle().strokeBorder(V3.fnt2, lineWidth: 1.2).frame(width: 7, height: 7) }
                    Text(label).font(V3.sans(13, weight: index == now ? .medium : .regular)).foregroundStyle(index == now ? V3.txt : V3.fnt)
                }
            }
        }.accessibilityElement(children: .combine).accessibilityLabel("走到哪一步")
    }

    private var papers: some View {
        ZStack(alignment: .topLeading) {
            if let id = graph.resumeID {
                HomeResumePaper(resumeID: id)
                    .frame(width: 340, height: 481)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xECEBE6)))
                    .shadow(color: .black.opacity(0.09), radius: 24, y: 18)
                    .rotationEffect(.degrees(6), anchor: .topLeading)
                    .offset(x: 30, y: 40)
            }
            Button { open(mockID) } label: { mode == .report ? AnyView(reportSheet) : AnyView(interviewSheet) }
                .buttonStyle(SheetStyle())
                .rotationEffect(.degrees(-3), anchor: .topLeading)
                .offset(x: 170, y: 18)
                .disabled(mode == .evaluating)
            Text(mode == .report ? "点这张纸，看报告" : mode == .evaluating ? "报告好了会出现在这里" : "点这张纸，开始第一场")
                .font(V3.sans(13)).foregroundStyle(V3.fnt).offset(x: 290, y: 548)
        }
    }

    private struct SheetStyle: ButtonStyle {
        @State private var hovering = false
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(width: 360, height: 480)
                .background(Color(hex: 0xFCFBF8))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(hex: 0xECEBE6)))
                .shadow(color: .black.opacity(hovering ? 0.12 : 0.09), radius: hovering ? 28 : 24, y: hovering ? 22 : 18)
                .offset(y: hovering ? -2 : 0)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.16), value: hovering)
        }
    }

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
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 22) {
                Text("第 1 题 · 来自你的简历").font(V3.sans(11)).foregroundStyle(V3.fnt)
                Text(firstText).font(V3.serif(21)).fontWeight(.semibold).lineSpacing(6).foregroundStyle(V3.txt)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, -12)
                Wave(live: answered)
                if answered {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("你答").font(V3.sans(11)).foregroundStyle(V3.fnt)
                        (Text(String(answer.prefix(26))).foregroundStyle(V3.txt) + Text(String(answer.dropFirst(26).prefix(34)) + (answer.count > 60 ? "……" : "")).foregroundStyle(Color(hex: 0xA5A39B)))
                            .font(V3.sans(13)).lineSpacing(6)
                    }
                } else {
                    Text(mode == .start ? "轮到你时，直接开口说就行" : "还没答到这一题").font(V3.sans(11.5)).foregroundStyle(V3.fnt)
                }
                Rectangle().fill(Color(hex: 0xEFEEE9)).frame(height: 1)
                Text(mode == .start ? "第 2 题 · 来自你的简历" : "第 2 题").font(V3.sans(11)).foregroundStyle(Color(hex: 0xA5A39B)).padding(.bottom, -16)
                Text(secondText).font(V3.serif(15)).fontWeight(.semibold).foregroundStyle(V3.sub).fixedSize(horizontal: false, vertical: true)
                if mode == .start { Text("第 3 题 · 开始后，接着你的回答追问").font(V3.sans(11)).foregroundStyle(Color(hex: 0xA5A39B)).padding(.bottom, -16) }
            }.frame(width: 300, alignment: .leading).offset(x: 30, y: 40)
            fade
            Text(status).font(V3.sans(11.5)).foregroundStyle(V3.fnt).offset(x: 30, y: 432)
        }.frame(width: 360, height: 480, alignment: .topLeading)
    }

    private var reportSheet: some View {
        let report = detail?["report"]
        let rows = (report?["questions"]?.items ?? []).filter { $0["is_intro"]?.bool != true && $0["skipped"]?.bool != true }
        let reached = rows.filter { $0.text("outcome") == "reached" }.count
        let weak = rows.filter { ["one_short", "missed"].contains($0.text("outcome")) }.count
        let company = detail.map { d in d.text("company_name").isEmpty ? d.text("target_role") : [d.text("company_name"), d.text("job_title")].filter { !$0.isEmpty }.joined(separator: " · ") } ?? ""
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Text(report?["total_score"]?.numberValue.map { "\(Int($0.rounded()))" } ?? "—").font(V3.serif(50)).fontWeight(.semibold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text([company, "第一场"].filter { !$0.isEmpty }.joined(separator: " · ")).font(V3.sans(11)).foregroundStyle(V3.fnt)
                        Text("\(rows.count) 题答到位 \(reached) 题，\(weak) 处要补").font(V3.sans(13, weight: .medium))
                    }
                }
                Rectangle().fill(Color(hex: 0xEFEEE9)).frame(height: 1)
                Text("每道题").font(V3.serif(15)).fontWeight(.semibold).padding(.bottom, -10)
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
                        }.padding(.vertical, 10)
                    }
                }
            }.foregroundStyle(V3.txt).frame(width: 300, alignment: .leading).offset(x: 30, y: 40)
            fade
            HStack {
                Text(rows.count > 4 ? "还有 \(rows.count - 4) 题 · \(weak) 处建议补" : "\(weak) 处建议补").font(V3.sans(11.5)).foregroundStyle(V3.fnt)
                Spacer()
                Text("看完整报告 →").font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.blue)
            }.frame(width: 300).offset(x: 30, y: 432)
        }.frame(width: 360, height: 480, alignment: .topLeading)
    }

    private var fade: some View {
        LinearGradient(stops: [.init(color: Color(hex: 0xFCFBF8).opacity(0), location: 0), .init(color: Color(hex: 0xFCFBF8), location: 0.6)], startPoint: .top, endPoint: .bottom)
            .frame(width: 360, height: 170).offset(y: 310).allowsHitTesting(false)
    }

    private func loadDetail() async {
        guard let mockID else { detail = nil; return }
        detail = try? await session.api.careerRequest(path: "/api/mock-interviews/\(mockID)", method: "GET", query: [:], body: nil)["mock_interview"]
    }

    /// 报告整理中：每 4 秒查一次，好了首页原地换成“报告好了”。
    private func pollEvaluating() async {
        guard mode == .evaluating, let mockID else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if let value = try? await session.api.careerRequest(path: "/api/mock-interviews/\(mockID)", method: "GET", query: [:], body: nil)["mock_interview"],
               value.text("status") != "evaluating" { changed(); return }
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
private struct HomeResumePaper: View {
    @Environment(SessionStore.self) private var session
    let resumeID: String
    @State private var paper: ResumeRenderRequest?

    var body: some View {
        GeometryReader { geometry in
            if let paper {
                ResumePaperView(request: paper, onError: { _ in })
                    .frame(width: 794, height: 1123)
                    .scaleEffect(geometry.size.width / 794, anchor: .topLeading)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
        }.background(.white).accessibilityHidden(true)
            .task(id: resumeID) {
                guard let resume = try? await session.api.listResumes().first(where: { $0.id == resumeID }),
                      let request = resume.renderRequest() else { return }
                paper = try? await session.api.preparePaper(request).request
            }
    }
}

// MARK: 07 有记忆（Figma 02A·07，Web FeedbackHome）

private struct FeedbackHome: View {
    let graph: HomeGraph
    let editResume: (String) -> Void
    let practice: (PracticeFocus?) -> Void
    let openMock: (String, Bool) -> Void
    let navigate: (WorkspaceSection) -> Void
    @State private var picked = 0
    @State private var expanded = false

    var body: some View {
        GeometryReader { geometry in
            let padX = min(56, max(28, geometry.size.width * 0.046))
            let padY = min(48, max(24, geometry.size.height * 0.04))
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 40) {
                    timeline.frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(spacing: 4) {
                        HStack(spacing: 22) {
                            Spacer()
                            (Text("知识图谱").foregroundStyle(V3.txt).fontWeight(.medium) + Text("   ") +
                             Text(graph.weakPoints > 0 ? "\(graph.points) 个知识点，\(graph.weakPoints) 个还不牢" : "\(graph.points) 个知识点").foregroundStyle(V3.fnt))
                                .font(V3.sans(13))
                            Button { withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.6)) { expanded = true } } label: {
                                HStack(spacing: 6) { Text("展开"); Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .medium)) }
                            }.buttonStyle(.plain).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                        }
                        HomeGraphCanvas(nodes: graph.nodes.filter(\.onHome), edges: graph.edges, large: false)
                            .frame(minHeight: 240)
                            .onTapGesture(count: 2) { withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.6)) { expanded = true } }
                    }.frame(maxWidth: .infinity).layoutPriority(1.2)
                }.frame(maxHeight: .infinity)
                strips.padding(.top, min(26, max(14, geometry.size.height * 0.03)))
            }
            .frame(maxWidth: 1160).frame(maxWidth: .infinity)
            .padding(.horizontal, padX).padding(.top, padY).padding(.bottom, padY * 0.9)
            .opacity(expanded ? 0 : 1)
            .overlay {
                if expanded {
                    expandedGraph.transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .onExitCommand { if expanded { withAnimation { expanded = false } } }
    }

    // 最近进展：选中的一条展开成大标题、说明和按钮，其余收成一行
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(graph.timeline.enumerated()), id: \.element.id) { index, item in
                let text = HomeProgressText.text(item, weakPoints: graph.weakPoints)
                let on = index == picked
                HStack(alignment: .top, spacing: 16) {
                    ZStack(alignment: .top) {
                        if index < graph.timeline.count - 1 {
                            Rectangle().fill(Color(hex: 0xD5D3C9)).frame(width: 1).padding(.top, on ? 17 : 31).frame(maxHeight: .infinity)
                        }
                        Circle().fill(on ? V3.blue : .white).overlay(Circle().strokeBorder(on ? V3.blue : Color(hex: 0xBDBBB2)))
                            .frame(width: on ? 10 : 9, height: on ? 10 : 9).padding(.top, on ? 5 : 20)
                    }.frame(width: 10)
                    if on { expandedItem(item, text) } else {
                        Button { withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.55)) { picked = index } } label: {
                            HStack(alignment: .top, spacing: 16) {
                                Text(HomeProgressText.when(item.date, today: graph.today)).font(V3.sans(13)).foregroundStyle(V3.fnt).monospacedDigit().frame(width: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(text.short).font(V3.sans(15)).foregroundStyle(V3.txt).lineLimit(1)
                                    Text(item.source).font(V3.sans(12)).foregroundStyle(V3.fnt)
                                }
                                Spacer(minLength: 0)
                            }.padding(.vertical, 12).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.padding(.leading, 0)
    }

    private func expandedItem(_ item: HomeGraph.Progress, _ text: HomeProgressText.Text) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(HomeProgressText.when(item.date, today: graph.today))  ·  \(item.source)").font(V3.sans(13)).tracking(0.5).foregroundStyle(V3.fnt).padding(.bottom, 14)
            text.lines.enumerated().reduce(Text("")) { result, pair in
                let (before, mark, after) = pair.element
                let line = Text(before) + Text(mark).foregroundColor(text.weak ? V3.orange : V3.blue) + Text(after)
                return pair.offset == 0 ? line : result + Text("\n") + line
            }
            .font(V3.sans(40, weight: .semibold)).lineSpacing(10).foregroundStyle(V3.txt).minimumScaleFactor(0.6)
            Text(text.desc).font(V3.sans(16)).lineSpacing(10).foregroundStyle(V3.sub).frame(maxWidth: 544, alignment: .leading).padding(.top, 14).padding(.bottom, 22)
            HStack(spacing: 22) {
                if item.kind == .resume, let id = graph.resumeID {
                    pill("打开简历") { editResume(id) }
                } else if let label = item.practiceLabel ?? graph.weakest?.name {
                    let focus = item.practiceRef.map { PracticeFocus(kind: item.practiceKind ?? "topic", ref: $0, label: label) }
                        ?? graph.weakest.map { PracticeFocus(kind: "topic", ref: $0.key, label: $0.name) }
                    pill("练\(label.components(separatedBy: "（").first ?? label)") { practice(focus) }
                } else {
                    pill("再练一场") { practice(nil) }
                }
                if item.kind == .mock {
                    Button { openMock(item.sourceID, true) } label: {
                        HStack(spacing: 2) { Text("看这一场的报告"); Image(systemName: "chevron.right").font(.system(size: 11)) }
                    }.buttonStyle(HomeTextLinkStyle(size: 14))
                }
            }.padding(.bottom, 18)
        }.transition(.opacity)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { Text(title).lineLimit(1); Image(systemName: "arrow.right").font(.system(size: 12, weight: .medium)) }
        }.buttonStyle(HomePillStyle(height: 38, font: 14))
    }

    // 底部六个入口：三列两行
    private var strips: some View {
        let entries = graph.entries
        let overstated = graph.nodes.filter(\.overstated)
        let interview: String = {
            guard let entries, let start = entries.interviewStart, let date = HomeStageDate.monthDay(start) else { return "还没有排面试" }
            return "\(date) \(entries.interviewCompany ?? "")\(entries.interviewStage ?? "面试")" + (entries.interviewCount > 1 ? "，共 \(entries.interviewCount) 场" : "")
        }()
        let mock = (entries?.mockCount ?? 0) > 0 ? "练过 \(entries!.mockCount) 场" + (entries?.mockLastScore.map { "，上一场 \(Int($0.rounded())) 分" } ?? "") : "开始第一场"
        let saved: String = {
            guard let entries else { return "还没有收藏岗位" }
            let base = entries.applicationsOpen > 0 ? "\(entries.applicationsOpen) 个在进行" : entries.jobsSaved > 0 ? "\(entries.jobsSaved) 个岗位" : "还没有收藏岗位"
            return base + (entries.applicationsAwaiting > 0 ? "，\(entries.applicationsAwaiting) 个等结果" : "")
        }()
        let items: [(String, String, Text, () -> Void)] = [
            ("calendar", "面试日程", Text(interview), { navigate(.schedule) }),
            ("mic", "模拟面试", Text(mock), { navigate(.mock) }),
            ("doc.text", "我的简历", overstated.isEmpty ? Text(graph.resumeTitle) : Text("\(overstated.count) 处写高了，") + Text(overstated[0].label).foregroundColor(Color(hex: 0xB5651A)),
             { if let id = graph.resumeID { editResume(id) } else { navigate(.resumes) } }),
            ("briefcase", "推荐岗位", Text("按你的简历挑岗位"), { navigate(.opportunities) }),
            ("square.split.1x2", "收藏的岗位", Text(saved), { navigate(.jobs) }),
            ("folder", "资料库", Text((entries?.datasets ?? 0) > 0 ? "\(entries!.datasets) 份资料" : "还没有资料"), { navigate(.datasets) }),
        ]
        return Grid(horizontalSpacing: 44, verticalSpacing: 18) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let item = items[row * 3 + column]
                        Button(action: item.3) {
                            HStack(spacing: 12) {
                                Image(systemName: item.0).font(.system(size: 19, weight: .light)).foregroundStyle(V3.sub).frame(width: 26, height: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.1).font(V3.sans(13)).foregroundStyle(V3.fnt)
                                    HStack(spacing: 2) {
                                        item.2.font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
                                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(Color(hex: 0xA5A39B))
                                    }
                                }
                                Spacer(minLength: 0)
                            }.padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // 展开：原地铺满整页，全画；右上「收起」，左上标题与来源，左下图例
    private var expandedGraph: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            HomeGraphCanvas(nodes: graph.nodes, edges: graph.edges, large: true).padding(.horizontal, 48).padding(.top, 84).padding(.bottom, 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("你的知识图谱").font(V3.sans(17, weight: .semibold)).foregroundStyle(V3.txt)
                Text("\(graph.points) 个知识点 · 来自 \(graph.sources.resumes) 份简历、\(graph.sources.mocks) 场练习、\(graph.sources.interviews) 场面试").font(V3.sans(12.5)).foregroundStyle(V3.fnt)
            }.padding(.leading, 48).padding(.top, 28)
            HStack(spacing: 18) {
                legend(V3.orange, "还不牢"); legend(V3.blue, "刚练稳")
                HStack(spacing: 6) { Text("“ ”").foregroundStyle(V3.sub); Text("简历亮点") }
            }.font(V3.sans(12)).foregroundStyle(V3.fnt).frame(maxHeight: .infinity, alignment: .bottomLeading).padding(.leading, 48).padding(.bottom, 24)
            Button { withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.5)) { expanded = false } } label: {
                HStack(spacing: 6) { Text("收起"); Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 11, weight: .medium)) }
            }.buttonStyle(.plain).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 48).padding(.top, 32)
                .keyboardShortcut(.cancelAction)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) { Circle().fill(color).frame(width: 7, height: 7); Text(text) }
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

/// 知识图谱画布：文字节点 + 细线；经历用衬线粗体，技术中号，知识点小号灰色，还不牢橙色、刚练稳蓝色。
private struct HomeGraphCanvas: View {
    let nodes: [HomeGraph.Node]
    let edges: [HomeGraph.Edge]
    let large: Bool
    @State private var layout: [String: (x: Double, y: Double)] = [:]
    @State private var hover: String?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let point = { (id: String) -> CGPoint? in
                layout[id].map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            }
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in edges where edge.kind != "EE" {
                        guard let a = point(edge.src), let b = point(edge.dst) else { continue }
                        var path = Path(); path.move(to: a); path.addLine(to: b)
                        let lit = hover != nil && (edge.src == hover || edge.dst == hover)
                        context.stroke(path, with: .color(lit ? Color(hex: 0xA5A39B) : Color(hex: 0xE2E0D8)),
                                       style: StrokeStyle(lineWidth: 1, dash: edge.kind == "PP" ? [3, 4] : []))
                    }
                }
                ForEach(nodes) { node in
                    if let at = point(node.id) {
                        Text(node.short)
                            .font(font(node))
                            .foregroundStyle(color(node))
                            .padding(.horizontal, 6).padding(.vertical, 5)
                            .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                            .fixedSize()
                            .help(node.label)
                            .onHover { hover = $0 ? node.id : (hover == node.id ? nil : hover) }
                            .position(at)
                    }
                }
            }
        }
        .task(id: nodes.map(\.id)) {
            let nodes = nodes, edges = edges
            layout = await Task.detached(priority: .userInitiated) { HomeGraphLayout.layout(nodes: nodes, edges: edges) }.value
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("知识图谱，\(nodes.count) 个节点")
    }

    private func font(_ node: HomeGraph.Node) -> Font {
        switch node.kind {
        case .experience: V3.serif(large ? 23 : 15).weight(.semibold)
        case .technology, .session: V3.sans(large ? 19 : 13, weight: .medium)
        case .highlight: V3.sans(large ? 14 : 12)
        case .point: V3.sans(large ? 14 : 12, weight: node.tone == .plain ? .regular : .medium)
        }
    }

    private func color(_ node: HomeGraph.Node) -> Color {
        switch node.tone {
        case .hot: return V3.orange
        case .new: return V3.blue
        case .plain:
            switch node.kind {
            case .experience, .technology, .session: return V3.txt
            case .highlight: return V3.sub
            case .point: return Color(hex: 0x87867F)
            }
        }
    }
}
