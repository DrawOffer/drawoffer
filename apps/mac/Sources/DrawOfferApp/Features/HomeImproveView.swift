import AppKit
import DrawOfferCore
import SwiftUI

/// 首页 · 哪里要提升，对齐 Web `homeImprove/HomeImproveMap.tsx`：左上结论与先补的几处，右边星图，
/// 底部地平线时间轴与输入框。场景规则见 Core `HomeScene`，摆放见 `HomeLayout`，坐标是 1151×828 设计稿，整体等比缩放。
@MainActor @Observable
final class HomeImproveModel {
    enum State { case loading, failed, ready(HomeInput) }
    private(set) var state: State = .loading
    var profile: JSONValue?
    private var owner = ""
    private var disclosed = ""

    func load(api: any APIClient, account: String) async {
        owner = account
        guard !account.isEmpty else { return }
        state = .loading
        let now = Date()
        let iso = ISO8601DateFormatter()
        do {
            async let resumes = api.listResumes()
            async let datasets = try? api.careerRequest(path: "/api/datasets", method: "GET", query: [:], body: nil)
            async let sessions = try? api.careerRequest(path: "/api/interview-sessions", method: "GET",
                query: ["start_at": iso.string(from: now.addingTimeInterval(-60 * 86_400)), "end_at": iso.string(from: now.addingTimeInterval(30 * 86_400))], body: nil)
            async let home = try? api.careerRequest(path: "/api/memory/home", method: "GET", query: [:], body: nil)
            async let profile = try? api.careerRequest(path: "/api/account/user-profile", method: "GET", query: [:], body: nil)
            let resumeList = try await resumes
            let (datasetJSON, sessionJSON, homeJSON, profileJSON) = await (datasets, sessions, home, profile)
            guard owner == account else { return }
            self.profile = profileJSON
            state = .ready(HomeInput(
                now: now, home: homeJSON.map(MemoryHome.init(json:)),
                resumes: resumeList.map { HomeResume(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) },
                datasets: (datasetJSON?["datasets"]?.items ?? []).map(HomeDataset.init(json:)),
                sessions: (sessionJSON?["items"]?.items ?? []).compactMap(HomeSession.init(json:)),
                directions: (profileJSON?["job_directions"]?.items ?? []).compactMap(\.stringValue),
                targetRole: profileJSON?.text("target_role").nonEmptyOr("")))
        } catch {
            guard owner == account else { return }
            state = .failed
        }
    }

    /// 这一屏列出的问题登记为已告知（同一屏只报一次，失败下次再报）。
    func disclose(api: any APIClient, keys: [String]) {
        let signature = keys.joined(separator: "|")
        guard !keys.isEmpty, signature != disclosed else { return }
        disclosed = signature
        Task {
            do { _ = try await api.careerRequest(path: "/api/memory/home/disclosures", method: "POST", query: [:], body: .object(["issues": .array(keys.map(JSONValue.string))])) }
            catch { if disclosed == signature { disclosed = "" } }
        }
    }

    func updateProfile(_ value: JSONValue) {
        profile = value
        if case .ready(var input) = state {
            input.directions = (value["job_directions"]?.items ?? []).compactMap(\.stringValue)
            input.targetRole = value.text("target_role")
            state = .ready(input)
        }
    }
}

struct HomeImproveView: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router
    @Binding var draft: String
    let send: (String, String?) -> Void
    let practice: (PracticeFocus?) -> Void
    let editResume: (String) -> Void
    let navigate: (WorkspaceSection) -> Void
    let importResume: () -> Void

    @State private var model = HomeImproveModel()
    @State private var suggestion: String?
    @State private var picked: String?
    @State private var toast: String?
    @State private var offsets: [String: CGSize] = [:]
    @State private var dragging: (id: String, start: CGSize)?
    @State private var hover: String?
    @State private var models: [JSONValue] = []
    @State private var modelID: String?

    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / HomeCanvas.width, geometry.size.height / HomeCanvas.height)
            let content = canvas
            content.frame(width: HomeCanvas.width, height: HomeCanvas.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: HomeCanvas.width * scale, height: HomeCanvas.height * scale, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: account) {
            await model.load(api: session.api, account: account)
            if let list = try? await session.api.careerRequest(path: "/api/agent/models", method: "GET", query: [:], body: nil) {
                models = list["models"]?.items ?? []
                modelID = modelID ?? list["defaultModelId"]?.stringValue ?? models.first?.text("id")
            }
        }
    }

    private var scene: HomeScene? { if case .ready(let input) = model.state { return HomeScenes.pick(input) }; return nil }

    @ViewBuilder private var canvas: some View {
        let scene = self.scene
        let layout = scene.map(HomeLayouts.layout)
        ZStack(alignment: .topLeading) {
            HomeBackdrop()
            if let scene, let layout {
                if !scene.mapTitle.isEmpty || !scene.mapNote.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if !scene.mapTitle.isEmpty { Text(scene.mapTitle).font(.system(size: 11, weight: .medium)).tracking(1.5).foregroundStyle(Color(hex: 0x6B6963)) }
                        if !scene.mapNote.isEmpty { Text(scene.mapNote).font(.system(size: 11)).tracking(0.5).foregroundStyle(Color(hex: 0xA8A49A)) }
                    }.offset(x: 580, y: 96)
                }
                StarMapView(scene: scene, layout: layout, offsets: offsets, picked: picked, hover: hover)
                nodeTargets(scene, layout)
                HomeLegend(items: scene.legend).frame(width: HomeCanvas.width - 41, alignment: .trailing).offset(y: 26)
                    .allowsHitTesting(false)
            }
            leftPanel(scene).offset(x: 40, y: 30)
            if let scene, let layout, let picked, let node = scene.nodes.first(where: { $0.id == picked }), let at = layout.at[picked] {
                pickMenu(node, at: at)
            }
            HorizonView()
            if let scene { TimelineView(marks: scene.marks, now: Date()).allowsHitTesting(false) }
            composer(scene).offset(x: 0, y: 708)
            if let toast {
                HStack(spacing: 12) {
                    Text(toast).font(.system(size: 12.5))
                    Button("知道了") { self.toast = nil }.buttonStyle(.link)
                }.padding(.horizontal, 16).padding(.vertical, 10).background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xE6E3DC)))
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                    .frame(width: HomeCanvas.width).offset(y: HomeCanvas.horizonTop - 70)
                    .task(id: toast) { try? await Task.sleep(for: .seconds(4)); self.toast = nil }
            }
        }
        .frame(width: HomeCanvas.width, height: HomeCanvas.height, alignment: .topLeading)
        .clipped()
        .onChange(of: scene?.disclose ?? []) { _, keys in model.disclose(api: session.api, keys: keys) }
        .onAppear { if let keys = scene?.disclose { model.disclose(api: session.api, keys: keys) } }
    }

    // MARK: 左栏

    @ViewBuilder private func leftPanel(_ scene: HomeScene?) -> some View {
        if case .ready = model.state, let scene {
            if scene.key == "start" {
                HomeOnboarding(profile: model.profile, onProfile: { model.updateProfile($0) }, toast: { toast = $0 },
                               guide: { startGuide([]) }, importResume: importResume, navigate: navigate, practice: { practice(nil) })
            } else {
                ScenePanel(scene: scene, run: run, item: { if let focus = $0.focus { practice(focus) } })
            }
        } else {
            let failed: Bool = { if case .failed = model.state { return true }; return false }()
            VStack(alignment: .leading, spacing: 0) {
                Text(failed ? "暂时读不到" : "正在整理").font(.system(size: 12)).foregroundStyle(V3.blue)
                Text(failed ? "首页信息暂时无法读取" : "正在读你的记忆……").font(V3.serif(26)).foregroundStyle(V3.txt).padding(.top, 6)
                Text(failed ? "简历、面试和记忆暂时没有读出来，可以先直接提问。" : "简历、资料和练过的题会画到右边")
                    .font(.system(size: 13)).foregroundStyle(Color(hex: 0x6B6963)).padding(.top, 8)
                if failed {
                    Button("重新加载") { Task { await model.load(api: session.api, account: account) } }
                        .buttonStyle(HomeOutlineButton()).padding(.top, 26)
                }
            }.frame(width: 400, alignment: .leading)
        }
    }

    private func run(_ action: HomeAction) {
        switch action {
        case .mock(let focus): practice(focus)
        case .guide(let ids): startGuide(ids)
        case .chat(let prompt): send(prompt, modelID)
        case .suggest(let text): suggestion = text
        }
    }

    /// 首页“写第一份简历”：用默认模板新建（固定名字，重名加序号）并进编辑器引导，首页已有的资料预选到第一步。
    private func startGuide(_ datasetIDs: [String]) {
        Task {
            for title in ["我的第一份简历", "我的第一份简历 2", "我的第一份简历 3"] {
                var body: [String: JSONValue] = ["title": .string(title), "guide": .bool(true)]
                if !datasetIDs.isEmpty { body["guide_dataset_ids"] = .array(datasetIDs.prefix(10).map(JSONValue.string)) }
                do {
                    let result = try await session.api.careerRequest(path: "/api/resumes", method: "POST", query: [:], body: .object(body))
                    let id = (result["resume"] ?? result).display("id")
                    if !id.isEmpty { editResume(id) }
                    return
                } catch APIError.server(_, "RESUME_TITLE_CONFLICT") {
                    continue
                } catch APIError.server(_, let code) {
                    toast = code == "RESUME_LIMIT_REACHED" ? "简历数量已到上限，删掉一份再新建。" : code == "TEMPLATE_INACTIVE" ? "暂时没有可用的模板，稍后再试。" : "没能新建简历，请重试。"
                    return
                } catch {
                    toast = "没能新建简历，请重试。"; return
                }
            }
            toast = "没能新建简历，请重试。"
        }
    }

    // MARK: 星图交互

    private func position(_ id: String, _ layout: HomeLayout) -> CGPoint? {
        guard let at = layout.at[id] else { return nil }
        let offset = offsets[id] ?? .zero
        return CGPoint(x: at.x + offset.width, y: at.y + offset.height)
    }

    @ViewBuilder private func nodeTargets(_ scene: HomeScene, _ layout: HomeLayout) -> some View {
        ForEach(scene.nodes) { node in
            if let point = position(node.id, layout) {
                let size = node.sym == .anchor ? 40.0 : 28
                Circle().fill(Color.white.opacity(0.001)).frame(width: size, height: size)
                    .position(point)
                    .onHover { hover = $0 ? node.id : (hover == node.id ? nil : hover) }
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            if dragging?.id != node.id { dragging = (node.id, offsets[node.id] ?? .zero) }
                            let start = dragging!.start
                            let delta = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                            let previous = offsets[node.id] ?? .zero
                            offsets[node.id] = delta
                            // 子链跟着走（越往下越松）
                            for (depth, child) in descendants(node.id, scene).enumerated() {
                                let factor = pow(0.68, Double(depth / 3 + 1))
                                let old = offsets[child] ?? .zero
                                offsets[child] = CGSize(width: old.width + (delta.width - previous.width) * factor, height: old.height + (delta.height - previous.height) * factor)
                            }
                        }
                        .onEnded { _ in dragging = nil })
                    .onTapGesture {
                        guard node.focus != nil || node.ask != nil else { return }
                        picked = picked == node.id ? nil : node.id
                    }
                    .accessibilityElement().accessibilityLabel(node.label).accessibilityAddTraits(.isButton)
                    .accessibilityAction { if node.focus != nil || node.ask != nil { picked = node.id } }
            }
        }
        .background(Color.white.opacity(0.001).onTapGesture(count: 2) { withAnimation(.spring(duration: 0.5)) { offsets = [:] } })
    }

    private func descendants(_ id: String, _ scene: HomeScene) -> [String] {
        var out: [String] = [], queue = [id]
        while let current = queue.first {
            queue.removeFirst()
            for child in scene.nodes where child.parent == current { out.append(child.id); queue.append(child.id) }
        }
        return out
    }

    private func pickMenu(_ node: HomeMapNode, at: HomePlaced) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let focus = node.focus {
                Button { picked = nil; practice(focus) } label: { Text("带着它去练").frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(HomeMenuRow())
            }
            if let ask = node.ask {
                Button { suggestion = ask; picked = nil } label: {
                    HStack { Text("问问它"); Spacer(); Text("填进下方输入框").font(.system(size: 10.5)).foregroundStyle(Color(hex: 0xA8A49A)) }
                }.buttonStyle(HomeMenuRow())
            }
        }.padding(6).frame(width: 168)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xE6E3DC)))
            .shadow(color: .black.opacity(0.1), radius: 15, y: 10)
            .offset(x: min(HomeCanvas.width - 190, at.x + 16), y: min(HomeCanvas.height - 210, at.y + 14))
            .onExitCommand { picked = nil }
            .accessibilityLabel("\(node.label) 的操作")
    }

    // MARK: 输入框

    private var shownSuggestion: String { suggestion ?? scene?.suggestion ?? "" }

    /// 对齐 Web `.hm-input-row`（顶 708、宽 458、间距 14）与 `.hm-hint`（顶 770、10px、#9b978c）：
    /// 输入为居中的 19px 衬线；输入为空时有建议也能直接发送，发出的是建议本身。
    private func composer(_ scene: HomeScene?) -> some View {
        let placeholder = scene?.key == "start" ? "没有简历？说说你做过什么，我来写第一版" : "有什么想问的？"
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = typed.isEmpty ? shownSuggestion : typed
        let submit = { if !outgoing.isEmpty { send(outgoing, modelID) } }
        return ZStack(alignment: .top) {
            HStack(spacing: 14) {
                HomeComposerField(text: $draft, suggestion: shownSuggestion, placeholder: placeholder, submit: submit)
                    .frame(maxWidth: 400).frame(height: 42)
                Button(action: submit) {
                    ZStack {
                        Circle().fill(.white).overlay(Circle().stroke(Color(hex: 0xE6E3DC)))
                            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                        Circle().fill(outgoing.isEmpty ? Color(hex: 0xC5C1B6) : Color(hex: 0x1D1D1B)).frame(width: 32, height: 32)
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    }.frame(width: 44, height: 44)
                }.buttonStyle(.plain).disabled(outgoing.isEmpty).accessibilityLabel("发送")
            }.frame(width: 458, height: 46)
            HStack(spacing: 0) {
                if !shownSuggestion.isEmpty && draft.isEmpty { Text("Tab 填 入 建 议　·　") }
                Text("回 车 发 送　·　⇧ 回 车 换 行　·　")
                ModelPicker(models: models, selectedID: modelID, inline: true) { modelID = $0 }
                Text("　·　")
                Button("添加资料", action: importResume).buttonStyle(.plain)
            }.font(.system(size: 10)).tracking(0.6).foregroundStyle(Color(hex: 0x9B978C)).frame(height: 14)
                .offset(y: 770 - 708)
        }.frame(width: HomeCanvas.width, alignment: .top)
    }
}

// MARK: - 左栏组件

private struct ScenePanel: View {
    let scene: HomeScene
    let run: (HomeAction) -> Void
    let item: (HomeListItem) -> Void

    var body: some View {
        let actionRow = scene.action != nil && !scene.list.contains(where: { $0.focus != nil }) ? scene.action : nil
        VStack(alignment: .leading, spacing: 0) {
            // 行高对齐 Web：眉题 16、标题 26px × 1.4、说明 20、列表标题 16。
            if !scene.eyebrow.isEmpty { Text(scene.eyebrow).font(.system(size: 12)).foregroundStyle(HomeColors.tone(scene.eyebrowTone)).lineHeight(12, 16).padding(.bottom, 4) }
            Text(scene.title).font(V3.serif(26)).foregroundStyle(V3.txt).lineHeight(26, 36.4).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            Text(scene.sub).font(.system(size: 13)).foregroundStyle(Color(hex: 0x6B6963)).lineHeight(13, 20).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            if !scene.list.isEmpty || actionRow != nil {
                if !scene.list.isEmpty && !scene.listTitle.isEmpty {
                    Text(scene.listTitle).font(.system(size: 12)).foregroundStyle(Color(hex: 0x6B6963)).lineHeight(12, 16).padding(.top, 32).padding(.bottom, 6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(scene.list) { row in ListRow(item: row, open: { item(row) }) }
                    if let actionRow, !scene.list.isEmpty { Rectangle().fill(Color(hex: 0xE6E3DE)).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 6) }
                    if let actionRow {
                        Button { run(actionRow.run) } label: {
                            HStack(spacing: 10) {
                                Color.clear.frame(width: 24, height: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(actionRow.label).font(.system(size: 14, weight: .medium)).foregroundStyle(V3.txt)
                                    if let hint = actionRow.hint { Text(hint).font(.system(size: 12)).foregroundStyle(Color(hex: 0x6B6963)).lineLimit(1) }
                                }
                                Spacer()
                                HStack(spacing: 4) { Text(actionRow.verb ?? "去练").font(.system(size: 12.5, weight: .medium)); Text("›").font(.system(size: 17)) }.foregroundStyle(V3.txt)
                            }.padding(.vertical, 9).padding(.leading, 10).padding(.trailing, 12).contentShape(Rectangle())
                        }.buttonStyle(HomeRowStyle())
                    }
                }.frame(width: 340).padding(.horizontal, -10).padding(.top, scene.list.isEmpty ? 26 : 0)
            }
            if let secondary = scene.secondary {
                Button(secondary.label) { run(secondary.run) }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Color(hex: 0x6B6963)).padding(.top, 14)
            }
        }.frame(width: 400, alignment: .leading)
    }
}

private struct ListRow: View {
    let item: HomeListItem
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let content = HStack(spacing: 10) {
            ZStack {
                if let badge = item.badge {
                    Text("\(badge)").font(.system(size: 11, weight: .medium)).foregroundStyle(.white).frame(width: 18, height: 18).background(HomeColors.orange, in: Circle())
                } else {
                    Canvas { context, size in
                        HomeSymbols.draw(item.sym, at: CGPoint(x: size.width / 2, y: size.height / 2), level: item.level ?? 2, scale: item.sym == .planet ? 0.65 : 1, in: &context)
                    }.frame(width: 24, height: 22)
                }
            }.frame(width: 24, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 14, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 19)
                Text(item.sub).font(.system(size: 12)).foregroundStyle(Color(hex: 0x6B6963)).lineLimit(1).truncationMode(.tail).frame(height: 16)
            }
            Spacer(minLength: 4)
            if let right = item.right { Text(right).font(.system(size: 12)).foregroundStyle(HomeColors.orange) }
            if item.focus != nil {
                HStack(spacing: 4) {
                    if hovering { Text("去练").font(.system(size: 12.5, weight: .medium)) }
                    Text("›").font(.system(size: 17))
                }.foregroundStyle(hovering ? V3.txt : Color(hex: 0xA8A49A))
            }
        }.padding(.vertical, 9).padding(.leading, 10).padding(.trailing, 12)
        if item.focus != nil {
            Button(action: open) { content.contentShape(Rectangle()) }.buttonStyle(HomeRowStyle()).onHover { hovering = $0 }
                .accessibilityLabel("\(item.title)，去练")
        } else {
            content
        }
    }
}

/// ① 起步的三步引导，对齐 Web `homeImprove/Onboarding.tsx`。
private struct HomeOnboarding: View {
    @Environment(SessionStore.self) private var session
    let profile: JSONValue?
    let onProfile: (JSONValue) -> Void
    let toast: (String) -> Void
    let guide: () -> Void
    let importResume: () -> Void
    let navigate: (WorkspaceSection) -> Void
    let practice: () -> Void
    @State private var role = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    static let roles: [(String, String?)] = [
        ("新媒体运营", "operations"), ("产品经理", "product"), ("管培生", nil), ("销售", "marketing"),
        ("财务 / 审计", "finance"), ("人力资源", "hr"), ("教师", "teacher"), ("软件开发", "rd"),
    ]
    private var saved: String { profile?.text("target_role") ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("欢迎来到职绘").font(.system(size: 12)).foregroundStyle(V3.blue)
            Text("先让我认识你").font(V3.serif(26)).foregroundStyle(V3.txt).padding(.top, 6)
            Text("首页会画出你会什么、哪里要补。三步就能开始，随时可以跳过。").font(.system(size: 13)).foregroundStyle(Color(hex: 0x6B6963)).padding(.top, 8)
            VStack(alignment: .leading, spacing: 0) {
                step(1, state: saved.isEmpty ? "now" : "done", title: "你想找什么工作") {
                    HStack(spacing: 10) {
                        TextField("比如 新媒体运营、管培生、Java 后端", text: $role).textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                            .onSubmit { save(role, nil) }.disabled(busy).accessibilityLabel("想找的岗位")
                            .onChange(of: role) { if role.count > 64 { role = String(role.prefix(64)) } }
                            .onChange(of: focused) { if !focused, role.trimmingCharacters(in: .whitespaces) != saved { save(role, nil) } }
                        Text(role.trimmingCharacters(in: .whitespaces).isEmpty ? "什么专业、岗位都可以" : role.trimmingCharacters(in: .whitespaces) == saved ? "已保存" : "回车保存")
                            .font(.system(size: 11)).foregroundStyle(Color(hex: 0xA8A49A))
                    }.padding(.horizontal, 14).frame(height: 36)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.blue.opacity(0.55), lineWidth: 0.8)).padding(.top, 12)
                    FlowRow(spacing: 8) {
                        Text("常见岗位").font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xA8A49A))
                        ForEach(Self.roles, id: \.0) { name, id in
                            let on = role.trimmingCharacters(in: .whitespaces) == name
                            Button(name) { role = name; save(name, id) }.buttonStyle(.plain).font(.system(size: 12)).disabled(busy)
                                .padding(.horizontal, 10).frame(height: 26)
                                .foregroundStyle(on ? .white : V3.sub)
                                .background(on ? V3.txt : .white, in: Capsule()).overlay(Capsule().stroke(on ? .clear : Color(hex: 0xE4E1DA)))
                                .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }.padding(.top, 12)
                }
                step(2, state: saved.isEmpty ? "later" : "now", title: "有材料就交给我，写出第一份简历") {
                    HStack(spacing: 12) {
                        Canvas { context, size in HomeSymbols.draw(.planet, at: CGPoint(x: size.width / 2, y: size.height / 2), level: 3, scale: 1, in: &context) }.frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("把旧简历拖到这里").font(.system(size: 13, weight: .medium))
                            Text("PDF、Word 都行，直接转成可编辑的简历").font(.system(size: 11.5)).foregroundStyle(Color(hex: 0x6B6963))
                        }
                        Spacer()
                        Button("选择文件", action: importResume).buttonStyle(HomeOutlineButton())
                    }.padding(.horizontal, 16).padding(.vertical, 18)
                        .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xCCC9C2), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .padding(.top, 12)
                        .onDrop(of: [.fileURL], isTargeted: nil) { _ in importResume(); return true }
                    HStack(spacing: 0) {
                        Text("没有简历？")
                        Button("跟着引导写第一份 →", action: guide).buttonStyle(.plain).foregroundStyle(V3.blue).disabled(busy)
                    }.font(.system(size: 11.5)).foregroundStyle(Color(hex: 0x6B6963)).padding(.top, 10)
                    HStack(spacing: 0) {
                        Text("也可以把课程报告、作品集")
                        Button("放进资料库") { navigate(.datasets) }.buttonStyle(.plain).foregroundStyle(V3.blue)
                        Text("，或")
                        Button("从模板开始") { navigate(.templates) }.buttonStyle(.plain).foregroundStyle(V3.blue)
                    }.font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xA8A49A)).padding(.top, 6)
                }
                step(3, state: "later", title: "练一场模拟面试") {
                    Text("有了第一份简历就能练；答完右边会亮起第一批点，告诉你哪里要补").font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xA8A49A)).padding(.top, 10)
                    Button("先看看模拟面试 →", action: practice).buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(V3.blue).padding(.top, 6)
                }
            }.padding(.top, 34)
        }.frame(width: 400, alignment: .leading)
            .onAppear { role = saved }
    }

    private func step<Content: View>(_ n: Int, state: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(.white).overlay(Circle().stroke(state == "now" ? V3.blue : Color(hex: 0xCCC9C2)))
                Text(state == "done" ? "✓" : "\(n)").font(.system(size: 11, weight: .medium)).foregroundStyle(state == "now" ? V3.blue : Color(hex: 0xA8A49A))
            }.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(state == "later" ? Color(hex: 0x6B6963) : V3.txt)
                content()
            }
        }.padding(.bottom, 26)
    }

    /// 存岗位：带方向时放到第一位（最多三个）；并发改过画像（409）或网络失败时重新读一次再存。
    private func save(_ next: String, _ direction: String?) {
        let value = next.trimmingCharacters(in: .whitespaces)
        guard let profile, !busy, !value.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do { onProfile(try await put(profile, value, direction)) }
            catch {
                do {
                    let latest = try await session.api.careerRequest(path: "/api/account/user-profile", method: "GET", query: [:], body: nil)
                    onProfile(try await put(latest, value, direction))
                } catch { toast("没有保存成功，请稍后再试") }
            }
        }
    }

    private func put(_ profile: JSONValue, _ role: String, _ direction: String?) async throws -> JSONValue {
        guard case .object(var body) = profile else { throw APIError.invalidResponse }
        let held = (body["job_directions"]?.items ?? []).compactMap(\.stringValue)
        for key in ["lock_version", "created_at", "updated_at", "job_directions"] { body.removeValue(forKey: key) }
        body["base_lock_version"] = profile["lock_version"] ?? .number(0)
        body["target_role"] = .string(role)
        if let direction { body["job_directions"] = .array(([direction] + held.filter { $0 != direction }).prefix(3).map(JSONValue.string)) }
        return try await session.api.careerRequest(path: "/api/account/user-profile", method: "PUT", query: [:], body: .object(body))
    }
}

/// 换行排布的简易流式布局（常见岗位标签）。
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x = 0.0, y = 0.0, line = 0.0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing; line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line = 0.0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y + (line > 0 ? 0 : 0)), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}

// MARK: - 画布

enum HomeColors {
    static let ink = Color(hex: 0x1D1D1B)
    static let blue = Color(hex: 0x3F6FD8)
    static let orange = Color(hex: 0xD9822B)
    static let soft = Color(hex: 0xA8A49A)
    static func tone(_ tone: HomeTone) -> Color {
        switch tone { case .ink: ink; case .blue: blue; case .orange: orange; case .soft: soft }
    }
}

enum HomeSymbols {
    static let levels: [Double] = [2.6, 3.6, 4.8, 6.2, 7.8]
    static func radius(_ sym: HomeSym, level: Int = 3) -> Double {
        let lv = levels[min(5, max(1, level)) - 1]
        switch sym {
        case .mastered, .due: return lv + 3
        case .weak: return lv + 9
        case .anchor: return 19
        case .planet: return 17
        case .topic: return 5
        case .pending: return 7
        case .untested: return 10
        }
    }

    static func rays(_ center: CGPoint, _ a: Double, _ b: Double) -> Path {
        var path = Path()
        for (dx, dy) in [(0.0, -1.0), (0, 1), (-1, 0), (1, 0)] {
            path.move(to: CGPoint(x: center.x + dx * a, y: center.y + dy * a))
            path.addLine(to: CGPoint(x: center.x + dx * b, y: center.y + dy * b))
        }
        return path
    }

    static func draw(_ sym: HomeSym, at center: CGPoint, level: Int, scale: Double = 1, tail: Double = atan2(-0.6, -1), in context: inout GraphicsContext) {
        let r = levels[min(5, max(1, level == 0 ? 3 : level)) - 1] * scale
        let circle = { (radius: Double) in Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)) }
        switch sym {
        case .mastered: context.fill(circle(r), with: .color(HomeColors.blue))
        case .weak:
            context.fill(circle(r), with: .color(HomeColors.orange))
            context.stroke(rays(center, r + 3, r + 8), with: .color(HomeColors.orange), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        case .pending:
            context.fill(circle(4.6), with: .color(.white))
            context.stroke(circle(4.6), with: .color(HomeColors.soft), lineWidth: 1.4)
        case .untested: context.stroke(rays(center, 3.5, 9), with: .color(HomeColors.soft), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        case .topic: context.fill(circle(2.6), with: .color(HomeColors.ink))
        case .due:
            let ux = cos(tail), uy = sin(tail)
            var tailPath = Path()
            tailPath.move(to: CGPoint(x: center.x - uy * r, y: center.y + ux * r))
            tailPath.addLine(to: CGPoint(x: center.x + ux * 28, y: center.y + uy * 28))
            tailPath.addLine(to: CGPoint(x: center.x + uy * r, y: center.y - ux * r))
            context.fill(tailPath, with: .linearGradient(Gradient(colors: [HomeColors.blue.opacity(0.38), HomeColors.blue.opacity(0)]),
                                                         startPoint: center, endPoint: CGPoint(x: center.x + ux * 28, y: center.y + uy * 28)))
            context.fill(circle(r), with: .color(HomeColors.blue))
        case .anchor:
            context.stroke(rays(center, 7, 17), with: .color(HomeColors.ink), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            var diagonal = Path()
            let k = 0.7071
            for (dx, dy) in [(k, k), (k, -k), (-k, k), (-k, -k)] {
                diagonal.move(to: CGPoint(x: center.x + dx * 5.5, y: center.y + dy * 5.5))
                diagonal.addLine(to: CGPoint(x: center.x + dx * 9, y: center.y + dy * 9))
            }
            context.stroke(diagonal, with: .color(HomeColors.ink), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            context.fill(circle(4.6), with: .color(HomeColors.ink))
        case .planet:
            let ring = Path(ellipseIn: CGRect(x: center.x - 15 * scale, y: center.y - 4.5 * scale, width: 30 * scale, height: 9 * scale))
                .applying(CGAffineTransform(translationX: -center.x, y: -center.y).concatenating(CGAffineTransform(rotationAngle: -20 * .pi / 180)).concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
            context.stroke(ring, with: .color(HomeColors.ink), lineWidth: 1.1)
            context.fill(circle(7 * scale), with: .color(.white))
            context.stroke(circle(7 * scale), with: .color(HomeColors.ink), lineWidth: 1.3)
        }
    }
}

private struct HomeBackdrop: View {
    var body: some View {
        Canvas { context, _ in
            let origin = CGPoint(x: 575, y: 1500)
            func point(_ angle: Double, _ radius: Double) -> CGPoint {
                CGPoint(x: origin.x + radius * cos(angle * .pi / 180), y: origin.y + radius * sin(angle * .pi / 180))
            }
            for radius in [880.0, 940, 1000, 1060, 1110, 1145, 1180, 1215, 1250, 1285, 1320, 1360] {
                let dashed = radius > 1100 && radius < 1330
                context.stroke(Path(ellipseIn: CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)),
                               with: .color(HomeColors.ink.opacity(Int(radius) % 2 == 1 ? 0.05 : 0.07)),
                               style: StrokeStyle(lineWidth: 1, dash: dashed ? [1, 5] : []))
            }
            var meridians = Path()
            for angle in stride(from: -140.0, through: -40, by: 6) { meridians.move(to: point(angle, 880)); meridians.addLine(to: point(angle, 1400)) }
            context.stroke(meridians, with: .color(HomeColors.ink.opacity(0.035)), lineWidth: 1)
        }.frame(width: HomeCanvas.width, height: HomeCanvas.height).allowsHitTesting(false)
    }
}

private struct StarMapView: View {
    let scene: HomeScene
    let layout: HomeLayout
    let offsets: [String: CGSize]
    let picked: String?
    let hover: String?

    var body: some View {
        let at = currentPositions()
        let lit = hover.map { litSet(around: $0) }
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                drawRegion(at, &context, dim: lit.map { set in !(scene.region?.members.contains(where: set.contains) ?? false) } ?? false)
                drawEdges(at, lit, &context)
                for node in scene.nodes {
                    guard let point = at[node.id] else { continue }
                    var layer = context
                    if let lit, !lit.contains(node.id) { layer.opacity = 0.25 }
                    HomeSymbols.draw(node.sym, at: point, level: node.level ?? 3, tail: tailFor(node, at), in: &layer)
                    if picked == node.id {
                        let ring = HomeSymbols.radius(node.sym, level: node.level ?? 3) + 4
                        layer.stroke(Path(ellipseIn: CGRect(x: point.x - ring, y: point.y - ring, width: ring * 2, height: ring * 2)), with: .color(HomeColors.blue.opacity(0.6)), lineWidth: 1)
                    }
                }
                for planet in scene.planets {
                    guard let point = at[planet.id] else { continue }
                    var layer = context
                    if let lit, !lit.contains(planet.id) { layer.opacity = 0.25 }
                    HomeSymbols.draw(.planet, at: point, level: 3, in: &layer)
                }
            }
            ForEach(scene.nodes) { node in
                if let point = at[node.id], !node.label.isEmpty {
                    NodeLabel(label: node.label, sub: node.sub, subTone: node.subTone, badge: node.badge, sym: node.sym, level: node.level ?? 3,
                              point: point, side: layout.at[node.id]?.side ?? .r)
                        .opacity(lit.map { $0.contains(node.id) ? 1 : 0.25 } ?? 1)
                }
            }
            ForEach(scene.planets) { planet in
                if let point = at[planet.id] {
                    NodeLabel(label: planet.label, sub: planet.sub, subTone: planet.subTone, badge: nil, sym: .planet, level: 3,
                              point: point, side: layout.at[planet.id]?.side ?? .r)
                        .opacity(lit.map { $0.contains(planet.id) ? 1 : 0.25 } ?? 1)
                }
            }
            if let region = regionNow(at), let title = scene.region?.title {
                Text(title).font(.system(size: 10.5, weight: .medium)).tracking(2).foregroundStyle(HomeColors.orange)
                    .fixedSize().position(x: region.cx, y: region.titleY - 4)
            }
        }.frame(width: HomeCanvas.width, height: HomeCanvas.height, alignment: .topLeading).allowsHitTesting(false)
            .accessibilityElement(children: .ignore).accessibilityLabel(scene.title.isEmpty ? scene.mapTitle : scene.title)
    }

    private func currentPositions() -> [String: CGPoint] {
        var out: [String: CGPoint] = [:]
        for (id, placed) in layout.at {
            let offset = offsets[id] ?? .zero
            out[id] = CGPoint(x: placed.x + offset.width, y: placed.y + offset.height)
        }
        return out
    }

    private func litSet(around id: String) -> Set<String> {
        var out: Set<String> = [id]
        for edge in scene.edges { if edge.from == id { out.insert(edge.to) }; if edge.to == id { out.insert(edge.from) } }
        for planet in scene.planets {
            if planet.id == id { out.formUnion(planet.links) }
            if planet.links.contains(id) { out.insert(planet.id) }
        }
        return out
    }

    private func regionNow(_ at: [String: CGPoint]) -> (cx: Double, cy: Double, rx: Double, ry: Double, titleY: Double)? {
        var placed: [String: HomePlaced] = [:]
        for (id, point) in at { placed[id] = HomePlaced(x: point.x, y: point.y, side: layout.at[id]?.side ?? .r) }
        return offsets.isEmpty ? layout.region : HomeLayouts.region(scene, placed)
    }

    private func drawRegion(_ at: [String: CGPoint], _ context: inout GraphicsContext, dim: Bool) {
        guard let region = regionNow(at) else { return }
        var layer = context
        if dim { layer.opacity = 0.25 }
        let ellipse = Path(ellipseIn: CGRect(x: region.cx - region.rx, y: region.cy - region.ry, width: region.rx * 2, height: region.ry * 2))
        layer.fill(ellipse, with: .color(HomeColors.orange.opacity(0.035)))
        layer.stroke(ellipse, with: .color(HomeColors.orange.opacity(0.75)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }

    private func trimmed(_ a: CGPoint, _ b: CGPoint, _ ra: Double, _ rb: Double) -> (CGPoint, CGPoint, Double, Double) {
        let dx = b.x - a.x, dy = b.y - a.y, length = max(hypot(dx, dy), 1)
        let ux = dx / length, uy = dy / length
        return (CGPoint(x: a.x + ux * ra, y: a.y + uy * ra), CGPoint(x: b.x - ux * rb, y: b.y - uy * rb), ux, uy)
    }

    private func drawEdges(_ at: [String: CGPoint], _ lit: Set<String>?, _ context: inout GraphicsContext) {
        let byId = Dictionary(scene.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func radius(_ id: String) -> Double { byId[id].map { HomeSymbols.radius($0.sym, level: $0.level ?? 3) } ?? HomeSymbols.radius(.planet) }
        for edge in scene.edges {
            guard let a = at[edge.from], let b = at[edge.to] else { continue }
            let (start, end, ux, uy) = trimmed(a, b, radius(edge.from) + 2, radius(edge.to) + 2)
            let on = lit.map { $0.contains(edge.from) && $0.contains(edge.to) && (edge.from == hover || edge.to == hover) } ?? false
            var layer = context
            if lit != nil && !on { layer.opacity = 0.25 }
            if edge.prereq {
                var line = Path(); line.move(to: start); line.addLine(to: CGPoint(x: end.x - ux * 6, y: end.y - uy * 6))
                layer.stroke(line, with: .color(HomeColors.orange), lineWidth: 1.2)
                let px = -uy, py = ux
                var head = Path()
                head.move(to: end)
                head.addLine(to: CGPoint(x: end.x - ux * 7 + px * 3.2, y: end.y - uy * 7 + py * 3.2))
                head.addLine(to: CGPoint(x: end.x - ux * 7 - px * 3.2, y: end.y - uy * 7 - py * 3.2))
                head.closeSubpath()
                layer.fill(head, with: .color(HomeColors.orange))
                layer.draw(Text("前置").font(.system(size: 10.5)).foregroundColor(HomeColors.orange),
                           at: CGPoint(x: (start.x + end.x) / 2 + px * 12, y: (start.y + end.y) / 2 + py * 12))
                continue
            }
            var line = Path(); line.move(to: start); line.addLine(to: end)
            if on { layer.stroke(line, with: .color(HomeColors.blue.opacity(0.85)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round)) }
            else {
                layer.stroke(line, with: .linearGradient(Gradient(stops: [
                    .init(color: HomeColors.soft.opacity(0.9), location: 0), .init(color: HomeColors.soft.opacity(0.5), location: 0.55),
                    .init(color: HomeColors.soft.opacity(0.18), location: 1)]), startPoint: start, endPoint: end), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            }
        }
        for planet in scene.planets {
            guard let a = at[planet.id] else { continue }
            for target in planet.links {
                guard let b = at[target] else { continue }
                let (start, end, _, _) = trimmed(a, b, HomeSymbols.radius(.planet) + 2, radius(target) + 2)
                let on = lit.map { $0.contains(planet.id) && $0.contains(target) } ?? false
                var layer = context
                if lit != nil && !on { layer.opacity = 0.25 }
                var line = Path(); line.move(to: start); line.addLine(to: end)
                layer.stroke(line, with: .color(on ? HomeColors.blue.opacity(0.85) : HomeColors.soft.opacity(0.7)),
                             style: StrokeStyle(lineWidth: on ? 1 : 0.8, lineCap: .round, dash: on ? [3, 3] : [1, 4]))
            }
        }
    }

    private func tailFor(_ node: HomeMapNode, _ at: [String: CGPoint]) -> Double {
        guard let me = at[node.id] else { return atan2(-0.6, -1) }
        let avoid = node.parent.flatMap { at[$0] }.map { atan2($0.y - me.y, $0.x - me.x) }
        let options = [atan2(-0.6, -1), atan2(-0.6, 1), atan2(0.6, 1), atan2(0.6, -1)]
        func diff(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi); return d > .pi ? 2 * .pi - d : d }
        return options.first { avoid == nil || diff($0, avoid!) > 0.9 } ?? options[0]
    }
}

private struct NodeLabel: View {
    let label: String, sub: String?, subTone: HomeTone?, badge: Int?, sym: HomeSym, level: Int
    let point: CGPoint
    let side: HomeSide

    var body: some View {
        let big = sym == .anchor
        let gap = HomeSymbols.radius(sym, level: level) + (big ? 4 : 5)
        let alignment: HorizontalAlignment = side == .r ? .leading : side == .l ? .trailing : .center
        let text = VStack(alignment: alignment, spacing: 1) {
            HStack(spacing: 5) {
                if let badge {
                    Text("\(badge)").font(.system(size: 10, weight: .medium)).foregroundStyle(.white).frame(width: 15, height: 15).background(HomeColors.orange, in: Circle())
                }
                Text(label).font(big ? V3.serif(20) : .system(size: 12, weight: .medium)).foregroundStyle(HomeColors.ink)
            }
            if let sub { Text(sub).font(.system(size: big ? 11 : 10.5)).foregroundStyle(HomeColors.tone(subTone ?? .soft)) }
        }.fixedSize()
        let nameHeight = (big ? 20.0 : 12) * 1.35
        switch side {
        case .r: text.alignmentGuide(.leading) { _ in 0 }.position(x: 0, y: 0).offset(x: point.x + gap, y: point.y - nameHeight / 2)
            .frame(width: 0, height: 0, alignment: .topLeading).modifier(TopLeadingAnchor(x: point.x + gap, y: point.y - nameHeight / 2, anchor: .topLeading))
        case .l: text.modifier(TopLeadingAnchor(x: point.x - gap, y: point.y - nameHeight / 2, anchor: .topTrailing))
        case .t: text.modifier(TopLeadingAnchor(x: point.x, y: point.y - gap, anchor: .bottom))
        case .b: text.modifier(TopLeadingAnchor(x: point.x, y: point.y + gap, anchor: .top))
        }
    }
}

/// 把视图的某个锚点放到画布坐标 (x, y) 上。
private struct TopLeadingAnchor: ViewModifier {
    let x: Double, y: Double
    let anchor: UnitPoint
    func body(content: Content) -> some View {
        content.alignmentGuide(.leading) { $0.width * anchor.x }.alignmentGuide(.top) { $0.height * anchor.y }
            .offset(x: x, y: y).frame(width: HomeCanvas.width, height: HomeCanvas.height, alignment: .topLeading)
    }
}

private struct HomeLegend: View {
    let items: [(HomeSym, String)]
    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Canvas { context, size in
                        HomeSymbols.draw(item.0, at: CGPoint(x: size.width / 2, y: size.height / 2), level: 2,
                                         scale: item.0 == .planet || item.0 == .anchor ? 0.62 : 1, in: &context)
                    }.frame(width: item.0 == .planet ? 26 : 22, height: 22)
                    Text(item.1)
                }
            }
        }.font(.system(size: 10.5)).foregroundStyle(Color(hex: 0x6B6963)).accessibilityElement(children: .combine).accessibilityLabel("图里的符号")
    }
}

private struct HorizonView: View {
    var body: some View {
        Canvas { context, _ in
            let r = 2397.0, top = HomeCanvas.horizonTop, w = HomeCanvas.width
            func arc(_ top: Double) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: HomeCanvas.horizonY(0, top: top)))
                for x in stride(from: 0.0, through: w, by: 8) { path.addLine(to: CGPoint(x: x, y: HomeCanvas.horizonY(x, top: top))) }
                return path
            }
            var fill = arc(top)
            fill.addLine(to: CGPoint(x: w, y: HomeCanvas.height)); fill.addLine(to: CGPoint(x: 0, y: HomeCanvas.height)); fill.closeSubpath()
            context.fill(fill, with: .color(Color(hex: 0xF2F0EA)))
            for (index, offset) in [4.0, 9, 16, 26, 40, 58].enumerated() {
                context.stroke(arc(top + offset), with: .color(Color(hex: 0xCFCABD).opacity(0.9 - Double(index) * 0.12)), lineWidth: 0.8)
            }
            context.stroke(arc(top), with: .color(HomeColors.ink), lineWidth: 1.3)
            var ticks = Path()
            var i = 0
            for x in stride(from: 4.0, to: w, by: 10.4) {
                let y = HomeCanvas.horizonY(x)
                let h = i % 20 == 15 ? 8.0 : i % 4 == 3 ? 5 : i % 2 == 1 ? 3 : 2
                ticks.move(to: CGPoint(x: x, y: y + 1)); ticks.addLine(to: CGPoint(x: x, y: y + 1 + h)); i += 1
            }
            context.stroke(ticks, with: .color(Color(hex: 0xA9A59A)), lineWidth: 0.7)
            _ = r
        }.frame(width: HomeCanvas.width, height: HomeCanvas.height).allowsHitTesting(false)
    }
}

private struct TimelineView: View {
    let marks: [HomeMark]
    let now: Date
    var body: some View {
        let placed = HomeLayouts.placeMarks(marks, now: now)
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let x = HomeLayouts.todayX, y = HomeCanvas.horizonY(x)
                var tick = Path(); tick.move(to: CGPoint(x: x, y: y - 9)); tick.addLine(to: CGPoint(x: x, y: y + 9))
                context.stroke(tick, with: .color(HomeColors.ink), lineWidth: 1.6)
                for (mark, mx) in placed {
                    let my = HomeCanvas.horizonY(mx), color = HomeColors.tone(mark.tone)
                    if mark.future {
                        let outer = Path(ellipseIn: CGRect(x: mx - 5.5, y: my - 5.5, width: 11, height: 11))
                        context.fill(outer, with: .color(.white)); context.stroke(outer, with: .color(color), lineWidth: 1.2)
                        context.fill(Path(ellipseIn: CGRect(x: mx - 2.4, y: my - 2.4, width: 4.8, height: 4.8)), with: .color(color))
                    } else {
                        context.fill(Path(ellipseIn: CGRect(x: mx - 3, y: my - 3, width: 6, height: 6)), with: .color(color))
                    }
                }
            }
            Text("今天").font(.system(size: 10, weight: .medium)).foregroundStyle(HomeColors.ink).fixedSize()
                .position(x: HomeLayouts.todayX, y: HomeCanvas.horizonY(HomeLayouts.todayX) - 21)
            ForEach(placed, id: \.0.id) { mark, x in
                VStack(spacing: 1) {
                    Text(mark.label).font(.system(size: 10, weight: .medium))
                    if let sub = mark.sub { Text(sub).font(.system(size: 9.5)) }
                }.foregroundStyle(HomeColors.tone(mark.tone)).fixedSize()
                    .position(x: x, y: HomeCanvas.horizonY(x) - (mark.sub != nil ? 26 : 17))
            }
        }.frame(width: HomeCanvas.width, height: HomeCanvas.height, alignment: .topLeading)
    }
}

/// 地平线下的输入框：灰字建议按 Tab 填入，回车发送，⇧ 回车换行。
private struct HomeComposerField: NSViewRepresentable {
    @Binding var text: String
    let suggestion: String
    let placeholder: String
    let submit: () -> Void

    /// Web 用 Noto Serif SC 19px，本机没有时与 Web 的字体回退一致落到宋体。
    static let font: NSFont = ["Noto Serif SC", "Source Han Serif SC", "Songti SC"].lazy.compactMap { NSFont(name: $0, size: 19) }.first ?? .systemFont(ofSize: 19)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.font = HomeComposerField.font
        view.alignment = .center
        view.textColor = NSColor(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1B / 255, alpha: 1)
        view.drawsBackground = false
        view.isRichText = false
        view.textContainerInset = NSSize(width: 0, height: 6)
        view.setAccessibilityLabel("告诉助手你想完成什么")
        context.coordinator.view = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        view.setAccessibilityPlaceholderValue(suggestion.isEmpty ? placeholder : suggestion)
        context.coordinator.updatePlaceholder()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HomeComposerField
        weak var view: NSTextView?
        private let hint = NSTextField(labelWithString: "")
        init(parent: HomeComposerField) { self.parent = parent }

        func updatePlaceholder() {
            guard let view else { return }
            if hint.superview == nil {
                hint.textColor = NSColor(red: 0xA2 / 255, green: 0x9E / 255, blue: 0x93 / 255, alpha: 1)
                hint.font = HomeComposerField.font
                hint.alignment = .center
                hint.lineBreakMode = .byTruncatingTail
                view.addSubview(hint)
            }
            hint.stringValue = parent.suggestion.isEmpty ? parent.placeholder : parent.suggestion
            hint.isHidden = !view.string.isEmpty
            hint.frame = NSRect(x: 5, y: 6, width: max(0, view.bounds.width - 10), height: 28)
        }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string
            updatePlaceholder()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)), textView.string.isEmpty, !parent.suggestion.isEmpty {
                textView.string = parent.suggestion
                parent.text = parent.suggestion
                updatePlaceholder()
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { textView.insertNewlineIgnoringFieldEditor(nil); return true }
                if textView.hasMarkedText() { return false }
                parent.submit()
                return true
            }
            return false
        }
    }
}

// MARK: - 样式

private struct HomeRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background((hovering || configuration.isPressed) ? Color(hex: 0xF3F2EE) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}

private struct HomeMenuRow: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12.5)).foregroundStyle(V3.txt).padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
            .background(hovering ? Color(hex: 0xF4F3EF) : .clear, in: RoundedRectangle(cornerRadius: 6)).onHover { hovering = $0 }
    }
}

struct HomeOutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12.5, weight: .medium)).foregroundStyle(V3.txt).padding(.horizontal, 12).frame(height: 28)
            .background(.white, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(.black.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
