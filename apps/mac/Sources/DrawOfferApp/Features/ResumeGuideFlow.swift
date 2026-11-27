import DrawOfferCore
import SwiftUI

/// 新建简历引导（Web `GuideFlow`，Figma 5:10 分区 214:6470 A2）：编辑器整页换成引导——顶栏是返回、标题与六步进度、「不用引导」；
/// 左边是纸面，右边一列一次只问一件事。服务端记步骤（`PATCH /guide`），每步写纸用 `guide/writes` 或各 compose 接口，
/// 写完的简历交回编辑器重新载入纸面。顶栏和右列共用这一个状态。
@MainActor @Observable
final class ResumeGuideFlow {


    let resumeID: String
    @ObservationIgnored let api: any APIClient
    var guide: JSONValue
    var busy = false
    var notice: String?
    /// wrap_up 里“个人优势”说完、到了成稿
    var finishing = false
    var seenFinish = false
    /// 中途离开再回来：先问接着写还是回到第一步
    var welcome: Bool
    /// 点了「不用引导」，等确认
    var leaving = false
    /// 开头问“用求职画像填好这份简历？”（还没开始写、画像里有东西时）
    var opening: Bool
    var filled = false
    var profile: JSONValue?
    var portrait: GuideModel.Portrait?
    var loaded = false
    var templateID: String?
    var templateSample: JSONValue?
    var stage: GuideModel.Stage {
        didSet { UserDefaults.standard.set(stage.rawValue, forKey: Self.stageKey(resumeID)) }
    }
    /// 写作品链接要临时切到基本信息一步，界面不跟着跳
    var pinned = false
    /// 基本信息改到一半去了别的步骤，回来接着改
    var basicsDraft: (info: GuideModel.BasicInfo, educations: [GuideModel.EducationForm], removed: [String])?
    /// 经历一步：停在哪一类、写到一半还没写上去的段（按“类别:段”记）
    var category: String?
    var segmentDrafts: [String: GuideModel.Segment] = [:]

    /// 编辑器当前的纸面正文（编辑器在正文变化时写进来），各步按它读已经写上的内容。
    var paper: JSONValue = .null
    func document() -> JSONValue { paper }
    @ObservationIgnored var applied: (JSONValue) -> Void = { _ in }
    @ObservationIgnored var saveFirst: () async -> Bool = { true }
    @ObservationIgnored var restore: (JSONValue) -> Void = { _ in }
    @ObservationIgnored var applyTemplate: (ResumeTemplate) async -> String? = { _ in nil }
    @ObservationIgnored var finished: () -> Void = {}

    static func stageKey(_ id: String) -> String { "drawoffer.guide-stage.\(id)" }

    init(resumeID: String, guide: JSONValue, templateID: String?, api: any APIClient) {
        self.resumeID = resumeID
        self.api = api
        self.guide = guide
        self.templateID = templateID
        welcome = GuideModel.resuming(guide)
        opening = GuideModel.untouched(guide)
        stage = UserDefaults.standard.string(forKey: Self.stageKey(resumeID)).flatMap(GuideModel.Stage.init(rawValue:)) ?? .graduate
    }

    var samples: Set<String> { GuideModel.sampleIDs(guide) }
    var current: String { pinned ? "experience" : guide.text("current_step") }
    var step: GuideModel.Step { GuideModel.step(current: current, finishing: finishing) }

    func reached(_ target: GuideModel.Step) -> Bool { GuideModel.reached(target, current: step, guide: guide, seenFinish: seenFinish) }

    // MARK: 读

    func load() async {
        async let user = try? api.careerRequest(path: "/api/account/user-profile", method: "GET", query: [:], body: nil)
        async let career = try? api.careerRequest(path: "/api/account/career-profile", method: "GET", query: [:], body: nil)
        let (loadedProfile, loadedCareer) = await (user, career)
        profile = loadedProfile
        if UserDefaults.standard.string(forKey: Self.stageKey(resumeID)) == nil, profile?.text("candidate_status") == "experienced" { stage = .worked }
        portrait = GuideModel.portrait(career: loadedCareer, profile: profile)
        if portrait == nil { opening = false }
        loaded = true
        if let templateID, let template = try? await api.careerRequest(path: "/api/resume-templates/\(templateID)", method: "GET", query: [:], body: nil) {
            templateSample = template["template"]?["data"]
        }
    }

    // MARK: 步骤

    func change(_ action: String, step target: String? = nil, datasets: [String]? = nil) async throws {
        var body: [String: JSONValue] = ["expected_version": guide["version"] ?? .number(1), "action": .string(action)]
        if let target { body["step"] = .string(target) }
        if let datasets { body["dataset_ids"] = .array(datasets.map(JSONValue.string)) }
        do {
            let result = try await api.careerRequest(path: "/api/resumes/\(resumeID)/guide", method: "PATCH", query: [:], body: .object(body))
            if let next = result["guide"] { guide = next }
        } catch {
            if case APIError.server(409, _) = error,
               let fresh = try? await api.careerRequest(path: "/api/resumes/\(resumeID)/guide", method: "GET", query: [:], body: nil)["guide"] { guide = fresh }
            throw error
        }
    }

    /// 走到某一步：写过或跳过的直接跳回去，没到的一步步往下走（中间没写的算跳过）。
    func reach(_ target: String) async throws {
        for _ in 0..<(GuideModel.Step.allCases.count + 2) {
            guard let next = GuideModel.reachAction(guide, target: target) else { return }
            try await change(next.action, step: next.step)
        }
    }

    /// 顶部进度点回某一步。
    func go(to target: GuideModel.Step) {
        guard !busy, target != step, reached(target) else { return }
        welcome = false; notice = nil
        if target == .finish { finishing = true } else if target == .skills { finishing = false }
        Task {
            do { try await reach(target.serverStep) } catch { notice = "没切过去，请重试。" }
        }
    }

    // MARK: 写

    static func code(_ error: Error) -> String {
        if case APIError.server(_, let code) = error { return code }
        return (error as? LocalizedError)?.errorDescription ?? ""
    }

    /// 写上纸：失败时在右列底下说一句，简历没有改动。
    @discardableResult
    func write(_ run: () async throws -> Void) async -> Bool {
        busy = true; notice = nil
        defer { busy = false }
        do {
            guard await saveFirst() else { notice = "左边的修改还没保存上，请稍后再试。"; return false }
            try await run()
            return true
        } catch {
            notice = GuideModel.failureText(Self.code(error))
            return false
        }
    }

    /// 返回 resume 与 guide 的写请求：更新引导、把简历交回编辑器。
    @discardableResult
    func post(_ action: String, _ body: JSONValue?) async throws -> JSONValue {
        let result = try await api.careerRequest(path: "/api/resumes/\(resumeID)/guide/\(action)", method: "POST", query: [:], body: body)
        if let next = result["guide"], next != .null { guide = next }
        if let resume = result["resume"], resume != .null { applied(resume) }
        return result
    }

    func writeOperations(_ operations: [JSONValue]) async throws {
        guard !operations.isEmpty else { return }
        try await post("writes", .object(["step": .string(guide.text("current_step")), "operations": .array(operations)]))
    }

    func fillFromPortrait() async {
        guard await write({ try await post("portrait:fill", nil) }) else { return }
        filled = true; opening = false
    }

    /// 你的情况：方向写进画像（409 时按最新画像再存一次）和纸面标题行，再确认这一步。
    func confirmSituation(_ chosen: GuideModel.Stage, role: String) async {
        stage = chosen
        await write {
            if !role.isEmpty {
                for attempt in 0..<2 {
                    let latest = try await api.careerRequest(path: "/api/account/user-profile", method: "GET", query: [:], body: nil)
                    let current = latest
                    do {
                        let saved = try await api.careerRequest(path: "/api/account/user-profile", method: "PUT", query: [:],
                                                                body: GuideModel.profileUpdate(current, ["target_role": .string(role)]))
                        profile = saved
                        break
                    } catch {
                        guard case APIError.server(409, _) = error, attempt == 0 else { throw error }
                    }
                }
                try await writeOperations([.object(["op": .string("set_identity"), "headline": .string(role)])])
            }
            try await change("confirm_profile")
        }
    }

    func saveBasics(_ info: GuideModel.BasicInfo, educations: [GuideModel.EducationForm], removed: [String]) async -> [GuideModel.EducationForm]? {
        var written: [GuideModel.EducationForm]?
        let ok = await write {
            try await reach("basics")
            try await writeOperations(GuideModel.basicInfoOperations(info, own: GuideModel.basicInfo(document(), samples: samples)))
            try await change("next")
            let operations = GuideModel.educationsOperations(educations, removed: removed, title: GuideModel.sectionTitle([templateSample], kind: "education"), document: document())
            if !operations.isEmpty {
                try await writeOperations(operations)
                written = GuideModel.educations(document(), profile: nil, samples: samples).filter { $0.entryID != nil }
            }
            try await change("next")
        }
        if ok { basicsDraft = nil }
        return ok ? (written ?? educations) : nil
    }

    func next() async { await write { try await change("next") } }
    func skip() async { await write { try await change("skip_step") } }

    /// 用户没换掉的模板示例，成稿时一起拿掉。
    func dropSamples() async {
        let ids = (guide["samples"]?.items ?? []).map { $0.text("node_id") }
        if !ids.isEmpty { try? await writeOperations([.object(["op": .string("remove_samples"), "node_ids": .array(ids.map(JSONValue.string))])]) }
    }

    /// 打开简历：走到成稿、拿掉示例、完成引导，回到编辑器。
    func finish() async {
        let ok = await write {
            try await reach("wrap_up")
            await dropSamples()
            try await change("complete")
        }
        if ok { segmentDrafts = [:]; finished() } else { notice = "没完成，简历已经保存，再点一次试试。" }
    }

    /// 不用引导：留下已经写上的内容，进普通编辑器；之后打开这份简历不再出现。
    func dismiss() async {
        let ok = await write { try await change("dismiss") }
        leaving = false
        if ok { segmentDrafts = [:]; finished() } else { notice = "没关上，请重试。" }
    }
}

// MARK: - 顶栏

/// 引导顶栏（`.gf-head`）：左「← 写第一份简历」，中间六步（当前 28 宽墨黑短线，走过的灰线可点回），右「不用引导」。
struct ResumeGuideHead: View {
    @Bindable var flow: ResumeGuideFlow
    let back: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                Button(action: back) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left").font(.system(size: 13))
                        Text("写第一份简历").font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt)
                    }.frame(height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help("返回").accessibilityLabel("返回")
                Spacer(minLength: 16)
                Button("不用引导") { flow.leaving = true }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.sub).disabled(flow.busy)
            }
            HStack(spacing: 16) {
                ForEach(ResumeGuideModel.Step.allCases, id: \.self) { item in
                    let current = item == flow.step
                    let done = !current && flow.reached(item)
                    Button { flow.go(to: item) } label: {
                        HStack(spacing: 8) {
                            Capsule().fill(current ? V3.txt : done ? Color(hex: 0xC4C4BD) : Color(hex: 0xE6E6E0)).frame(width: current ? 28 : 22, height: 2)
                            Text(item.label).font(V3.sans(12.5, weight: current ? .medium : .regular))
                                .foregroundStyle(current ? V3.txt : done ? Color(hex: 0x55554F) : Color(hex: 0xB4B4AD))
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!done || flow.busy)
                    .accessibilityLabel(item.label).accessibilityAddTraits(current ? .isSelected : [])
                }
            }
        }
        .centeredSheet(isPresented: $flow.leaving) {
            V3StandardDialog(title: "不用引导了？", subtitle: "写上的都留着，接下来在编辑器里自己改。", close: { flow.leaving = false }) {
                Text("这份简历以后不会再出现引导。").foregroundStyle(V3.sub)
            } note: { EmptyView() } actions: {
                Button("接着填") { flow.leaving = false }.buttonStyle(V3ButtonStyle(kind: .ghost, height: 36)).disabled(flow.busy)
                Button("去编辑器") { Task { await flow.dismiss() } }.buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).disabled(flow.busy)
            }
        }
    }
}

// MARK: - 右列

/// 引导右列（`.gf`）：440 宽，上留 72，一屏一件事；底下一行失败提示。
struct ResumeGuideColumn: View {
    @Bindable var flow: ResumeGuideFlow
    static let width: CGFloat = 440

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                screen.id(flow.step.rawValue + (flow.welcome ? "-welcome" : "") + (flow.opening ? "-opening" : ""))
                    .transition(.opacity.combined(with: .offset(y: 8)))
                if let notice = flow.notice {
                    Text(notice).font(V3.sans(13)).foregroundStyle(V3.red).padding(.top, 14).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 72).padding(.bottom, 48).padding(.horizontal, 2)
            .frame(width: Self.width, alignment: .leading)
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.36), value: flow.step)
        }
        .scrollIndicators(.never)
        .task { if !flow.loaded { await flow.load() } }
    }

    @ViewBuilder private var screen: some View {
        let index = (ResumeGuideModel.Step.allCases.firstIndex(of: flow.step) ?? 0) + 1
        if flow.welcome && flow.guide.text("status") == "active" {
            GuideScreen(kicker: "第 \(index) 步 · \(flow.step.label)", title: "接着上次写？", note: "上次写到“\(flow.step.label)”这一步。前面写好的都在左边。") {
                GuideActions(primary: "接着写", disabled: flow.busy, link: index > 1 ? "回到第一步" : nil, onLink: {
                    flow.welcome = false; flow.go(to: .situation)
                }) { flow.welcome = false }
            }
        } else if flow.opening && flow.step == .situation {
            if let portrait = flow.portrait {
                GuideScreen(kicker: "开始之前", title: "用求职画像填好这份简历？", note: "画像里有\(portrait.text)。先填进去，后面每一步都能改、能删、能再加。") {
                    GuideActions(primary: flow.busy ? "正在填…" : "填进简历", disabled: flow.busy, link: "不用，自己填", onLink: { flow.opening = false }) {
                        Task { await flow.fillFromPortrait() }
                    }
                }
            } else if !flow.loaded {
                GuideScreen(kicker: "开始之前", title: "正在看你的求职画像…") { EmptyView() }
            }
        } else {
            switch flow.step {
            case .situation: GuideSituationStep(flow: flow)
            case .materials: GuideMaterialsStep(flow: flow)
            case .basics: GuideBasicsStep(flow: flow)
            case .experience: GuideExperienceStep(flow: flow)
            case .skills: if flow.current == "skills" { GuideSkillsStep(flow: flow) } else { GuideStrengthStep(flow: flow) }
            case .finish: GuideFinishStep(flow: flow)
            }
        }
    }
}

// MARK: - 公用

/// 一屏：灰色小字（第几步）、28 号衬线标题、可选的类别标签、15 号灰色说明，下面是这一步的内容。
struct GuideScreen<Content: View, Tabs: View>: View {
    let kicker: String
    let title: String
    var note: String? = nil
    @ViewBuilder var tabs: () -> Tabs
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kicker).font(V3.sans(13)).foregroundStyle(GuideStyle.ter).padding(.bottom, 10)
            Text(title).font(V3.serif(28)).foregroundStyle(V3.txt).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            tabs()
            if let note, !note.isEmpty { GuideNote(text: note).padding(.top, 12) }
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension GuideScreen where Tabs == EmptyView {
    init(kicker: String, title: String, note: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(kicker: kicker, title: title, note: note, tabs: { EmptyView() }, content: content)
    }
}

enum GuideStyle {
    static let sec = Color(hex: 0x55554F)
    static let ter = Color(hex: 0x96968F)
    static let line = Color(hex: 0xE2E2DC)
    static let blue = Color(hex: 0x346EE6)
    static let control = Color(hex: 0xE6E6E1)
}

struct GuideNote: View {
    let text: String
    var body: some View {
        Text(text).font(V3.sans(15)).foregroundStyle(GuideStyle.sec).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
    }
}

struct GuideHint: View {
    let text: String
    var color: Color = GuideStyle.ter
    var body: some View {
        Text(text).font(V3.sans(13)).foregroundStyle(color).lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
    }
}

/// 一组小标题（13 灰），右边可放「删掉」。
struct GuideGroupHead<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack {
            Text(title).font(V3.sans(13)).foregroundStyle(GuideStyle.sec)
            Spacer(minLength: 12)
            trailing()
        }.padding(.top, 20).padding(.bottom, 10)
    }
}

/// 黑色胶囊主按钮 + 一个灰字链接。
struct GuideActions: View {
    let primary: String
    var disabled = false
    var primaryDisabled = false
    var link: String? = nil
    var onLink: () -> Void = {}
    var extra: AnyView? = nil
    let onPrimary: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Button(action: onPrimary) {
                Text(primary).font(V3.sans(14, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 20).frame(height: 36).background(V3.txt.opacity(disabled || primaryDisabled ? 0.35 : 1), in: Capsule())
                    .contentShape(Capsule())
            }.buttonStyle(.plain).disabled(disabled || primaryDisabled).keyboardShortcut(.defaultAction)
            if let link { GuideLink(title: link, action: onLink).disabled(disabled) }
            if let extra { extra }
        }.padding(.top, 24)
    }
}

struct GuideLink: View {
    let title: String
    var color: Color = GuideStyle.sec
    var size: CGFloat = 14
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) { Text(title).font(V3.sans(size)).foregroundStyle(enabled ? color : V3.fnt2).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
}

/// 白底圆角列表（`.gf-panel`）：行与行之间细线。
struct GuidePanel<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 列表里一行：标签 72 宽在左，内容在右，最少 50 高；`divider` 是上面那条细线。
struct GuideField<Content: View>: View {
    let label: String
    var divider = true
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 16) {
            Text(label).font(V3.sans(14)).foregroundStyle(GuideStyle.sec).frame(width: 72, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18).frame(minHeight: 50)
        .overlay(alignment: .top) { if divider { Rectangle().fill(GuideStyle.line).frame(height: 1) } }
    }
}

/// 列表里的输入框：无边框，空着时灰字。
struct GuideInput: View {
    let placeholder: String
    @Binding var text: String
    var maxLength = 120
    var submit: () -> Void = {}
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain).font(V3.sans(15)).foregroundStyle(V3.txt)
            .overlay(alignment: .leading) {
                if text.isEmpty { Text(placeholder).font(V3.sans(15)).foregroundStyle(Color(hex: 0xA8A8A1)).allowsHitTesting(false) }
            }
            .onSubmit(submit)
            .onChange(of: text) { if text.count > maxLength { text = String(text.prefix(maxLength)) } }
            .accessibilityLabel(placeholder)
    }
}

/// 列表里一行可点的（资料库里的一份、空经历时的建议）：左文字，右灰字 ›。
struct GuideRow: View {
    let title: String
    var side: String = "›"
    var divider = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).font(V3.sans(15)).foregroundStyle(V3.txt).lineLimit(1)
                Spacer(minLength: 8)
                Text(side).font(V3.sans(13)).foregroundStyle(GuideStyle.ter)
            }.padding(.horizontal, 18).frame(minHeight: 50).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { if divider { Rectangle().fill(GuideStyle.line).frame(height: 1) } }
    }
}
