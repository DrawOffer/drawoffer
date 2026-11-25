import Foundation
import DrawOfferCore
import SwiftUI

/// 复盘报告「练这几题 / 练这一处」带到配置页的内容（Figma 09 · 10.08、10.09；Web `practicePlan.ts`）。
struct MockPracticeItem: Equatable {
    var label: String
    var question: String
    var signals: [String]
    var note: String?
    var tag: String?
    /// 上次到哪
    var last: String
    /// 这次要到
    var goal: String
}

struct MockPracticePlan: Equatable {
    var back: String
    var items: [MockPracticeItem]
    var applicationID: String?
    var interviewType: String?
    var difficulty: String?
    var mode: String?
    var resumeID: String?
}

/// 这一场怎么练（Figma 09 · 02.01 面试配置、02.02 选岗位、02.03 选简历、02.04 面试类型、02.05 更多设置；
/// 首页页 61:2382「H5 第一场：设置已替用户选好」——没有任何记录时每项设置下多一行灰字说明）。Web `v2/ConfigPage.tsx`。
/// 画布 1151 × 828 等比缩放，左上返回放在缩放层外，与其他页面同一位置。
struct MockConfigPage: View {
    @Environment(SessionStore.self) private var session
    var applicationID: String? = nil
    var focus: PracticeFocus? = nil
    var practice: MockPracticePlan? = nil
    let back: () -> Void
    let open: (String) -> Void
    var showBoard: () -> Void = {}
    var showOpportunities: () -> Void = {}

    private static let width: CGFloat = 1151, height: CGFloat = 828
    private static let continueCount = 3, fullCount = 8, firstCount = 3, perQuestion = 5
    private static let types = ["technical", "project_deep_dive", "comprehensive", "hr"]
    private static let typeHints = [
        "technical": "考专业知识的原理与实际情境处理",
        "project_deep_dive": "只追问简历里的经历，层层深挖",
        "comprehensive": "专业、项目与软素质各问一些",
        "hr": "动机、职业规划、协作与薪资期望",
    ]
    // 右列每行的位置：画布 y=273 起，行距 44；第一场每行下面多一行灰字，行距放宽到 64（稿 H5 61:2382：分隔线在行顶 +52.5，灰字 12 / #87867F）
    private static let setTop: CGFloat = 273, setStep: CGFloat = 44, firstStep: CGFloat = 64

    enum Plan { case first, resume, full }
    enum Panel { case resume, type, jobs, more }

    struct ConfigData {
        var list: [JSONValue] = []
        var overview: JSONValue?
        var applications: [JSONValue] = []
        var sessions: [JSONValue] = []
        var resumes: [JSONValue] = []
        var speech = false
        var voices: [JSONValue] = []
        var defaultVoices: [String: String] = [:]
        var targetRole: String?
        var prices: [JSONValue] = []
    }

    @State private var data: ConfigData?
    @State private var failed = false
    @State private var now = Date()
    @State private var chosen: String?
    @State private var plan: Plan?
    @State private var type: String?
    @State private var difficulty = "intermediate"
    @State private var mode = "voice"
    @State private var voice = "male"
    @State private var voiceIDs: [String: String] = [:]
    @State private var language = "zh"
    @State private var followUp = true
    @State private var resume = ""
    @State private var panel: Panel?
    @State private var submitting = false
    @State private var notice: MockNotice?
    @State private var applied = false
    /// K1（Figma 02A · 61:3075）：从岗位广场「对着这个岗位练一场」进来，面试岗位已预选刚加入的那个
    @State private var fromJoin = false

    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }
    private func get(_ path: String, query: [String: String] = [:]) async throws -> JSONValue {
        try await session.api.careerRequest(path: path, method: "GET", query: query, body: nil)
    }

    // MARK: 派生

    private var target: MockMap.Target {
        guard let data else { return MockMap.Target(kind: .general, application: nil, session: nil) }
        return MockMap.pickTarget(applications: data.applications, sessions: data.sessions, now: now, chosen: chosen ?? applicationID ?? practice?.applicationID ?? "general")
    }
    private var stuck: JSONValue? { data?.overview?["stuck"].flatMap { $0 == .null ? nil : $0 } }
    private var topic: String? { focus?.label ?? stuck?.text("topic").nonEmptyValue }
    private var canContinue: Bool { topic != nil }
    /// 这个账号还没有任何能算数的面试：第一场按 H5 出说明，默认 3 题先走一遍
    private var firstTime: Bool {
        guard let data, practice == nil, focus == nil else { return false }
        return !data.list.contains { ["in_progress", "evaluating", "evaluation_failed", "completed"].contains($0.text("status")) }
    }
    private var activePlan: Plan { plan ?? (firstTime ? .first : canContinue ? .resume : .full) }
    private var count: Int {
        if let practice { return practice.items.count }
        return activePlan == .first ? Self.firstCount : activePlan == .resume ? Self.continueCount : Self.fullCount
    }
    private var step: CGFloat { firstTime ? Self.firstStep : Self.setStep }
    private var shift: CGFloat { 6 * (step - Self.setStep) }
    private var stageLabel: String { target.session?.text("stage_label").nonEmptyValue ?? target.application?.text("current_stage_label") ?? "" }
    private var activeType: String { type ?? (stageLabel.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("HR") ? "hr" : "comprehensive") }
    private var blocking: JSONValue? { data?.list.first { ["in_progress", "preparing", "evaluating", "evaluation_failed"].contains($0.text("status")) } }
    private var selectedResume: JSONValue? { data?.resumes.first { $0.display("id") == resume } }
    private var jobLabel: String {
        if target.kind == .general, firstTime, let role = data?.targetRole { return "\(role) · 按简历" }
        return target.kind == .general ? "只按简历出题"
            : [MockMap.companyName(target), target.application?.text("job_title_snapshot") ?? "", stageLabel].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var cost: String? {
        let price = { (code: String) in data?.prices.first { $0.text("featureCode") == code } }
        let text = price("mock_interview"), voicePrice = mode == "voice" ? price("mock_interview_voice") : nil
        let unit = { (value: JSONValue?) in value?["unitPoints"]?.numberValue ?? value?["unitPoints"]?.stringValue.flatMap(Double.init) }
        switch text?.text("priceMode") {
        case "free": return "本次免费"
        case "usage": return "按实际用量计积分"
        case "fixed":
            guard let base = unit(text) else { return nil }
            if voicePrice?.text("priceMode") == "free" { return "本次免费" }
            let each = voicePrice?.text("priceMode") == "fixed" ? unit(voicePrice) ?? base : base
            let total = (each * Double(count) * 100).rounded() / 100
            return "消耗 \(total == total.rounded() ? String(Int(total)) : String(total)) 积分"
        default: return nil
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MockStage(width: Self.width, height: Self.height) { canvas }
            GeometryReader { geometry in
                MockBackCrumb(label: practice?.back ?? "模拟面试", action: back)
                    .padding(.leading, V3Page<EmptyView>.gutter(card: geometry.size.width)).padding(.top, 52)
            }
            MockNoticeToast(notice: $notice)
        }
        .task(id: account) { await load() }
        // 选了语音作答就开始在后台准备本机识别资源，开场第一题就能本机识别
        .task(id: mode) { if mode == "voice" { await LocalSpeech.prepare() } }
        .centeredSheet(isPresented: Binding(get: { panel == .jobs }, set: { if !$0 { panel = nil } })) {
            MockJobDialog(jobs: boardJobs, sessions: data?.sessions ?? [], now: now, current: target.kind == .general ? nil : target.application?.display("id"),
                          close: { panel = nil }, pick: { id in chosen = id ?? "general"; panel = nil; applyDefaults() },
                          showBoard: { panel = nil; showBoard() }, showOpportunities: { panel = nil; showOpportunities() })
        }
        .centeredSheet(isPresented: Binding(get: { panel == .more }, set: { if !$0 { panel = nil } })) {
            MockMoreDialog(language: language, followUp: followUp, voice: voice, voices: mode == "voice" ? data?.voices ?? [] : [],
                           voiceIDs: (data?.defaultVoices ?? [:]).merging(voiceIDs) { $1 },
                           close: { panel = nil },
                           save: { value in language = value.language; followUp = value.followUp; voiceIDs = value.voiceIDs; panel = nil })
        }
    }

    private var boardJobs: [JSONValue] { (data?.applications ?? []).filter { $0.text("status") == "active" && $0.text("archived_at").isEmpty } }

    // MARK: 画布

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            Text(verbatim: title).font(V3.serif(40)).foregroundStyle(MockPalette.ink).lineLimit(1)
                .frame(width: 860, height: 54, alignment: .leading).offset(x: 146, y: 142)
            Text(verbatim: desc).font(V3.sans(15)).foregroundStyle(MockPalette.sub).frame(height: 26).offset(x: 146, y: 202)
            if failed {
                Text("设置没有加载出来，请刷新后重试。").font(V3.sans(13)).foregroundStyle(MockPalette.fnt).offset(x: 146, y: 262)
            }
            if let data {
                if let practice { MockPracticeCard(items: practice.items).offset(x: 146, y: 262) } else { plans }
                setRow(0, "面试岗位") { pick(.jobs, jobLabel, "面试岗位") }
                setRow(1, "简历") { pick(.resume, selectedResume?.text("title") ?? "未选择", "简历") }
                setRow(2, "面试类型") { pick(.type, MockMap.typeNames[activeType] ?? "综合面", "面试类型") }
                setRow(3, "难度") {
                    MockSeg(label: "难度", options: ["junior", "intermediate", "senior"].map { ($0, MockMap.diffName[$0] ?? "", false) }, current: difficulty) { difficulty = $0 }
                }
                setRow(4, "答题方式") {
                    MockSeg(label: "答题方式", options: [("voice", "语音", !data.speech), ("text", "文字", false)], current: mode) { mode = $0 }
                }
                setRow(5, "面试官声音", off: mode != "voice") {
                    MockSeg(label: "面试官声音", options: [("male", "男声", false), ("female", "女声", false)], current: voice, disabled: mode != "voice") { voice = $0 }
                }
                Rectangle().fill(MockPalette.line).frame(width: 860, height: 1).offset(x: 146, y: 538 + shift)
                Text(verbatim: ["\(count) 题，约 \(count * Self.perQuestion) 分钟", cost].compactMap { $0 }.joined(separator: " · "))
                    .font(V3.sans(13)).foregroundStyle(MockPalette.fnt).frame(height: 20).offset(x: 146, y: 574 + shift)
                Button("更多设置 ›") { panel = .more }.buttonStyle(MockLinkStyle()).frame(height: 20).offset(x: 815, y: 574 + shift)
                Button(submitting ? "正在准备…" : blocking != nil ? "继续上一场" : "开始面试") { Task { await start() } }
                    .buttonStyle(MockPillStyle()).disabled(submitting)
                    .frame(width: 112, alignment: .trailing).offset(x: 1006 - 112, y: 565 + shift)
            } else if !failed {
                ProgressView().controlSize(.small).offset(x: 146, y: 262)
            }
            menus
        }
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
    }

    private var title: String {
        if let practice { return practice.items.count > 1 ? "接着练这 \(practice.items.count) 题" : "练这一处：\(practice.items.first?.label ?? "")" }
        return firstTime ? "第一场，先这样练" : "这一场怎么练？"
    }
    private var desc: String {
        if let practice { return practice.items.count > 1 ? "从你上次停下的地方问起，设置沿用上一场，也可以改。" : "只问这一处，从上次停下的地方接着追问。" }
        if firstTime { return "第一次练，每一项都按你的情况选好了，右边写了为什么。" }
        return canContinue ? "默认从你卡住的地方接着问，其他都可以改。" : "第一场先走一遍完整流程，其他都可以改。"
    }

    @ViewBuilder private var plans: some View {
        if firstTime {
            planCard(top: 262, on: activePlan == .first, title: "第一次练", meta: "\(Self.firstCount) 题，约 \(Self.firstCount * Self.perQuestion) 分钟",
                     text: target.kind == .general ? "先自我介绍，再问两道简历里的事；\n走完一遍就有第一份报告。"
                                                   : "先自我介绍，再按这个岗位的要求，\n从你的项目里挑两道问。") { plan = .first }
        } else {
            let others = (data?.overview?["tallies"]?["open"]?["examples"]?.items ?? []).compactMap(\.stringValue).filter { $0 != topic }.prefix(2)
            let text: String = {
                guard let topic else { return "练完一场以后，\n这里会从你卡住的地方接着问。" }
                let spaced = topic.last.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true ? " " : ""
                guard !others.isEmpty else { return "从 \(topic)\(spaced)问起。" }
                let all = others.joined(separator: "和")
                let also = all.count <= 22 ? all : "\(others.first ?? "") 等 \(others.count) 处"
                let lead = also.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true ? " " : ""
                return "从 \(topic)\(spaced)问起，\n再补\(lead)\(also)。"
            }()
            planCard(top: 262, on: activePlan == .resume, title: "接着练", meta: "\(Self.continueCount) 题，约 \(Self.continueCount * Self.perQuestion) 分钟", text: text, disabled: !canContinue) { plan = .resume }
        }
        planCard(top: 398, on: activePlan == .full, title: "完整模拟", meta: "\(Self.fullCount) 题，约 \(Self.fullCount * Self.perQuestion) 分钟",
                 text: "先自我介绍，再按岗位走完一整场，\n卡住的地方也会问到。") { plan = .full }
    }

    /// `.mi3-plan`：392 × 120，选中墨黑描边。
    private func planCard(top: CGFloat, on: Bool, title: String, meta: String, text: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                Text(verbatim: title).font(V3.sans(16, weight: .medium)).foregroundStyle(disabled ? MockPalette.mute : MockPalette.ink).frame(height: 24)
                Text(verbatim: meta).font(V3.sans(13)).foregroundStyle(MockPalette.sub).frame(height: 20).frame(maxWidth: .infinity, alignment: .trailing).offset(y: 2)
                Text(verbatim: text).font(V3.sans(13)).foregroundStyle(disabled ? MockPalette.mute : MockPalette.sub).lineHeight(13, 21).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).offset(y: 36)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(width: 392, height: 120, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? MockPalette.ink : MockPalette.cl, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).disabled(disabled)
        .accessibilityAddTraits(on ? .isSelected : [])
        .offset(x: 146, y: top)
    }

    private static let firstHintsTail = ["就用你刚写好的这份", "技术和项目都会问，最容易看出哪里要补", "按你的经验定的，答不上来也没关系"]
    private func firstHint(_ index: Int) -> String {
        switch index {
        case 0: return target.kind == .general ? "还没导入岗位，先按简历里的方向出题" : applicationID != nil || fromJoin ? "就按你刚加入的这个岗位出题" : "按这个岗位的要求出题"
        case 1, 2, 3: return Self.firstHintsTail[index - 1]
        case 4: return mode == "voice" ? "最接近真实面试；不方便说话可以换成文字" : "用文字答；方便说话时换成语音更接近真实面试"
        default: return "只是声音不同，不影响出题"
        }
    }

    /// `.mi3-set`：右列一行，418 宽、44 高，左标签右控件，下面一条细线（最后一行没有）。
    private func setRow<Control: View>(_ index: Int, _ label: String, off: Bool = false, @ViewBuilder control: () -> Control) -> some View {
        ZStack(alignment: .topLeading) {
            Text(verbatim: label).font(V3.sans(14)).foregroundStyle(MockPalette.sub).frame(height: 22)
            control().frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, index < 3 ? 7 : 0).offset(y: index < 3 ? 0 : -4)
            if firstTime { Text(verbatim: firstHint(index)).font(V3.sans(12)).foregroundStyle(MockPalette.hint).lineLimit(1).frame(height: 18).offset(y: 24) }
            if index < 5 { Rectangle().fill(MockPalette.line).frame(height: 1).offset(y: firstTime ? 52.5 : 33) }
        }
        .frame(width: 418, height: firstTime ? Self.firstStep : Self.setStep, alignment: .topLeading)
        .opacity(off ? 0.4 : 1)
        .offset(x: 588, y: Self.setTop + CGFloat(index) * step)
    }

    private func pick(_ name: Panel, _ text: String, _ label: String) -> some View {
        Button { panel = panel == name ? nil : name } label: {
            HStack(spacing: 6) {
                Text(verbatim: text).font(V3.sans(14)).foregroundStyle(MockPalette.ink).lineLimit(1).truncationMode(.tail)
                MockCaret()
            }.frame(maxWidth: 322, alignment: .trailing).frame(height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(text).accessibilityLabel("\(label)：\(text)")
    }

    /// 简历、面试类型两个下拉：钉在对应行下面，点外面收起。
    @ViewBuilder private var menus: some View {
        if panel == .resume || panel == .type {
            Color.black.opacity(0.001).frame(width: Self.width, height: Self.height).onTapGesture { panel = nil }
            let top = Self.setTop + step * (panel == .resume ? 1 : 2) + (firstTime ? 46 : 25)
            VStack(alignment: .leading, spacing: 2) {
                if panel == .resume {
                    ForEach(data?.resumes ?? [], id: \.self) { item in
                        menuRow(on: item.display("id") == resume, height: 41) {
                            HStack(spacing: 12) {
                                Text(verbatim: item.text("title")).font(V3.sans(13.5, weight: item.display("id") == resume ? .medium : .regular)).foregroundStyle(MockPalette.ink).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(verbatim: MockMap.mmddDot(item.text("updated_at")).replacingOccurrences(of: "·", with: "-")).font(V3.sans(12)).foregroundStyle(MockPalette.mute)
                            }
                        } action: { resume = item.display("id"); panel = nil }
                    }
                } else {
                    ForEach(Self.types, id: \.self) { value in
                        menuRow(on: value == activeType, height: 56) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: MockMap.typeNames[value] ?? "").font(V3.sans(13.5, weight: value == activeType ? .medium : .regular)).foregroundStyle(MockPalette.ink)
                                Text(verbatim: Self.typeHints[value] ?? "").font(V3.sans(12.5)).foregroundStyle(MockPalette.fnt)
                            }
                        } action: { type = value; panel = nil }
                    }
                }
            }
            .padding(6).frame(width: panel == .resume ? 260 : 300)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MockPalette.cl))
            .shadow(color: .black.opacity(0.14), radius: 20, y: 16)
            .offset(x: panel == .resume ? 746 : 706, y: top)
            .accessibilityElement(children: .contain).accessibilityLabel(panel == .resume ? "选择简历" : "面试类型")
        }
    }

    private func menuRow<Label: View>(on: Bool, height: CGFloat, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label().padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
                .background(on ? MockPalette.hover : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: 加载与开始

    private func load() async {
        guard !account.isEmpty else { return }
        if let joined = CoachGuide.shared.takePendingMockApplication() { chosen = joined; fromJoin = true }
        let since = ISO8601DateFormatter().string(from: ReadCache.floor(Date(), minutes: 5).addingTimeInterval(-6 * 3600))
        do {
            async let list = get("/api/mock-interviews", query: ["limit": "100"])
            async let overview = try? get("/api/mock-interviews/overview")
            async let applications = try? get("/api/job-applications", query: ["scope": "active", "limit": "200"])
            async let sessions = try? get("/api/interview-sessions", query: ["status": "scheduled", "start_at": since, "limit": "500"])
            async let resumes = get("/api/resumes")
            async let capability = try? get("/api/mock-interviews/speech-capability")
            async let profile = try? get("/api/account/user-profile")
            async let prices = try? get("/api/billing/feature-prices")
            var next = ConfigData()
            next.list = try await list["items"]?.items ?? []
            next.resumes = try await resumes["resumes"]?.items ?? []
            next.overview = await overview
            next.applications = await applications?["items"]?.items ?? []
            next.sessions = await sessions?["items"]?.items ?? []
            let speech = await capability
            next.speech = speech?["stt"]?.bool == true && speech?["tts"]?.bool == true
            next.voices = speech?["voices"]?.items ?? []
            if case .object(let defaults)? = speech?["default_voices"] { next.defaultVoices = defaults.compactMapValues(\.stringValue) }
            let role = await profile
            next.targetRole = role?["profile"]?.text("target_role").nonEmptyValue ?? role?.text("target_role").nonEmptyValue
            next.prices = await prices?["items"]?.items ?? []
            if Task.isCancelled { return }
            now = Date(); data = next; failed = false
            if !applied {
                applied = true
                if let practice {
                    type = practice.interviewType; difficulty = practice.difficulty ?? difficulty; mode = practice.mode ?? mode
                    if let id = practice.resumeID { resume = id }
                }
                if !next.speech { mode = "text" }
            }
            applyDefaults()
        } catch { if !Task.isCancelled { failed = true } }
    }

    /// 岗位关联的简历优先，否则最近更新的一份。
    private func applyDefaults() {
        guard let data, !data.resumes.isEmpty else { return }
        let linked = target.application?.display("resume_id") ?? ""
        if practice?.resumeID == nil, !linked.isEmpty, data.resumes.contains(where: { $0.display("id") == linked }) { resume = linked; return }
        if !data.resumes.contains(where: { $0.display("id") == resume }) {
            resume = data.resumes.sorted { $0.text("updated_at") > $1.text("updated_at") }.first?.display("id") ?? ""
        }
    }

    private func practiceFocus() -> JSONValue? {
        let free = { (label: String) in String("free:\(label)".prefix(128)) }
        if let practice, let first = practice.items.first {
            return .object([
                "kind": .string("topic"), "ref": .string(free(first.label)), "label": .string(first.label), "origin": .string("settings"),
                "mode": .string("continue"), "question": .string(first.question),
                "items": .array(practice.items.map { .object(["label": .string($0.label), "question": .string($0.question), "signals": .array($0.signals.map { .string($0) })]) }),
            ])
        }
        if activePlan == .full && focus == nil { return nil }
        if let focus {
            return .object(["kind": .string(focus.kind), "ref": .string(focus.ref.isEmpty ? free(focus.label) : focus.ref), "label": .string(focus.label), "origin": .string("outline")])
        }
        guard let stuck, let label = stuck.text("topic").nonEmptyValue else { return nil }
        var fields: [String: JSONValue] = ["kind": .string("topic"), "ref": .string(stuck.text("node").nonEmptyValue ?? free(label)), "label": .string(label), "origin": .string("settings")]
        if let question = stuck.text("question").nonEmptyValue { fields["mode"] = .string("continue"); fields["question"] = .string(question) }
        return .object(fields)
    }

    private func start() async {
        guard let data, !submitting else { return }
        if let blocking { open(blocking.display("id")); return }
        guard !resume.isEmpty else { notice = MockNotice(title: "这场没有开始", message: "先导入或新建一份简历，面试官按简历出题。"); return }
        submitting = true
        var body: [String: JSONValue] = [
            "resume_id": .string(resume), "interview_type": .string(activeType), "difficulty": .string(difficulty), "question_count": .number(Double(count)),
            "follow_up_enabled": .bool(followUp), "language": .string(language), "answer_mode": .string(mode),
        ]
        if target.kind != .general, let id = target.application?.display("id") { body["job_application_id"] = .string(id) }
        if target.kind == .general, let role = data.targetRole { body["target_role"] = .string(role) }
        if mode == "voice" {
            body["interviewer_voice"] = .string(voice)
            if let id = voiceIDs[voice] { body["interviewer_voice_id"] = .string(id) }
        }
        if let focus = practiceFocus() { body["practice_focus"] = focus }
        do {
            let result = try await session.api.careerRequest(path: "/api/mock-interviews", method: "POST", query: [:], body: .object(body))
            open(result["mock_interview"]?.display("id") ?? "")
        } catch {
            notice = MockNotice(title: "这场没有开始", message: MockInterviewText.error(error))
        }
        submitting = false
    }
}

/// 全站统一的左上返回（`BackCrumb`）：← 上一页 / 当前。
struct MockBackCrumb: View {
    let label: String
    var current: String? = nil
    var disabled = false
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 6) { Image(systemName: "arrow.left").font(.system(size: 13)); Text(verbatim: label) }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(disabled).accessibilityLabel("返回\(label)")
            if let current {
                Text("/").accessibilityHidden(true)
                Text(verbatim: current).foregroundStyle(MockPalette.ink).lineLimit(1)
            }
        }
        .font(V3.sans(16)).foregroundStyle(MockPalette.fnt).frame(height: 20).fixedSize()
    }
}

/// 左边要练的内容（Figma 09 · 10.08 多题、10.09 一处）。
struct MockPracticeCard: View {
    let items: [MockPracticeItem]
    var body: some View {
        Group {
            if items.count > 1 {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(verbatim: item.label).font(V3.sans(15, weight: .medium)).foregroundStyle(MockPalette.ink).lineLimit(1)
                                Spacer(minLength: 0)
                                if let tag = item.tag { Text(verbatim: tag).font(V3.sans(12)).foregroundStyle(MockPalette.fnt) }
                            }
                            if let note = item.note { Text(verbatim: note).font(V3.sans(13)).foregroundStyle(MockPalette.sub).lineLimit(1) }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { if index < items.count - 1 { Rectangle().fill(MockPalette.line).frame(height: 1) } }
                    }
                }
                .padding(.horizontal, 20)
            } else if let item = items.first {
                VStack(alignment: .leading, spacing: 22) {
                    if !item.signals.isEmpty {
                        section("要补") {
                            HStack(spacing: 6) {
                                ForEach(item.signals.prefix(3), id: \.self) { signal in
                                    Text(verbatim: signal).font(V3.sans(12)).foregroundStyle(MockPalette.sub).lineLimit(1)
                                        .padding(.horizontal, 10).frame(height: 26).background(MockPalette.chip, in: RoundedRectangle(cornerRadius: 6)).help(signal)
                                }
                            }
                        }
                    }
                    section("上次到哪") { Text(verbatim: item.last).font(V3.sans(13)).foregroundStyle(MockPalette.sub).lineHeight(13, 21).lineLimit(2) }
                    section("这次要到") { Text(verbatim: item.goal).font(V3.sans(13)).foregroundStyle(MockPalette.sub).lineHeight(13, 21).lineLimit(2) }
                }
                .padding(.horizontal, 20).padding(.vertical, 20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 392, height: 256)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MockPalette.cl))
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).font(V3.sans(12)).foregroundStyle(MockPalette.fnt)
            content()
        }
    }
}

/// 选择面试岗位（Figma 09 · 02.02）：搜索 + 列表，没有 JD 的岗位去补；左下去投递看板添加。
struct MockJobDialog: View {
    let jobs: [JSONValue]
    let sessions: [JSONValue]
    let now: Date
    let current: String?
    let close: () -> Void
    let pick: (String?) -> Void
    let showBoard: () -> Void
    let showOpportunities: () -> Void
    @State private var query = ""
    @State private var picked: String??

    var body: some View {
        let chosen: String? = picked ?? current
        let keyword = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = jobs.filter { keyword.isEmpty || ($0.text("company_name_snapshot") + $0.text("job_title_snapshot")).lowercased().contains(keyword) }
        MockFormCard(title: "选择面试岗位", sub: "面试官按这个岗位的 JD 出题。", close: close, footLine: false, footTop: 22, footBottom: 25) {
            TextField("", text: $query).textFieldStyle(.plain).font(V3.sans(13))
                .overlay(alignment: .leading) { if query.isEmpty { Text("搜公司或岗位").font(V3.sans(13)).foregroundStyle(MockPalette.mute).allowsHitTesting(false) } }
                .padding(.horizontal, 14).frame(height: 38).background(MockPalette.field, in: RoundedRectangle(cornerRadius: 10)).padding(.top, 16)
                .accessibilityLabel("搜公司或岗位")
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(shown, id: \.self) { item in
                        let id = item.display("id")
                        let usable = !item.text("job_description_id").isEmpty
                        let session = sessions.first { $0.display("application_id") == id && (CareerApplication.date($0.text("end_at")) ?? .distantPast) >= now }
                        let sub = session.flatMap { s in CareerApplication.date(s.text("start_at")).map { "\(s.text("stage_label")) · \(MockMap.relativeDay($0, now: now)) \(MockMap.hhmm($0))" } } ?? item.text("current_stage_label")
                        row(on: chosen == id, title: "\(item.text("company_name_snapshot")) · \(item.text("job_title_snapshot"))", sub: sub,
                            trailing: usable ? ("JD 已上传", false) : ("还没有 JD · 去补 ›", true)) {
                            if usable { picked = .some(id) } else { showOpportunities() }
                        }
                    }
                    if keyword.isEmpty || "不选岗位".contains(keyword) {
                        row(on: chosen == nil, title: "不选岗位", sub: "只按简历出题", trailing: nil) { picked = .some(nil) }
                    }
                }
            }
            .frame(height: 241).padding(.top, 12)
        } left: {
            Button("去投递看板添加 ›", action: showBoard).buttonStyle(MockLinkStyle())
        } foot: {
            Button("取消", action: close).buttonStyle(MockPillStyle(kind: .ghost, height: 32, padding: 21, size: 13))
            Button(chosen != nil ? "用这个岗位练" : "不选岗位练") { pick(chosen) }.buttonStyle(MockPillStyle(height: 38, padding: 24))
        }
    }

    private func row(on: Bool, title: String, sub: String, trailing: (String, Bool)?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: title).font(V3.sans(14, weight: .medium)).foregroundStyle(trailing?.1 == true ? MockPalette.mute : MockPalette.ink).lineLimit(1)
                    Text(verbatim: sub).font(V3.sans(12.5)).foregroundStyle(MockPalette.fnt).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let trailing { Text(verbatim: trailing.0).font(V3.sans(12.5)).foregroundStyle(trailing.1 ? MockPalette.blue : MockPalette.fnt) }
            }
            .padding(.horizontal, 14).frame(height: 55)
            .background(on ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? MockPalette.ink : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 更多设置（Figma 09 · 02.05）：面试语言、面试官音色（语音作答时）、允许追问。
struct MockMoreDialog: View {
    struct Value { var language: String; var followUp: Bool; var voiceIDs: [String: String] }
    let language: String
    let followUp: Bool
    let voice: String
    let voices: [JSONValue]
    let voiceIDs: [String: String]
    let close: () -> Void
    let save: (Value) -> Void
    @State private var lang: String?
    @State private var follow: Bool?
    @State private var picked: [String: String]?

    var body: some View {
        let options = voices.filter { $0.text("gender") == voice }
        let ids = picked ?? voiceIDs
        MockFormCard(title: "更多设置", close: close, footLine: false, footTop: 19, footBottom: 20) {
            VStack(spacing: 0) {
                option("面试语言", "面试官提问和报告使用的语言") {
                    MockSeg(label: "面试语言", options: [("zh", "中文", false), ("en", "英文", false)], current: lang ?? language, pill: true) { lang = $0 }
                }
                if !options.isEmpty {
                    option("面试官音色", "这一场选的是\(voice == "male" ? "男声" : "女声")") {
                        Picker("面试官音色", selection: Binding(get: { ids[voice] ?? "" }, set: { var next = ids; next[voice] = $0; picked = next })) {
                            ForEach(options, id: \.self) { Text(verbatim: $0.text("name")).tag($0.text("id")) }
                        }.labelsHidden().pickerStyle(.menu).frame(width: 120)
                    }
                }
                option("允许追问", "每道主问题最多追问 2 次，关掉就一题一答") {
                    Toggle("允许追问", isOn: Binding(get: { follow ?? followUp }, set: { follow = $0 })).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(MockPalette.ink)
                }
            }.padding(.top, 6)
        } left: {
            EmptyView()
        } foot: {
            Button("取消", action: close).buttonStyle(MockPillStyle(kind: .ghost, height: 32, padding: 21, size: 13))
            Button("保存") { save(Value(language: lang ?? language, followUp: follow ?? followUp, voiceIDs: ids)) }.buttonStyle(MockPillStyle(height: 38, padding: 24))
        }
    }

    private func option<Control: View>(_ title: String, _ sub: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title).font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.ink).frame(height: 22)
                Text(verbatim: sub).font(V3.sans(12.5)).foregroundStyle(MockPalette.fnt).frame(height: 20)
            }
            Spacer(minLength: 0)
            control()
        }
        .padding(.vertical, 15).frame(minHeight: 72)
        .overlay(alignment: .top) { Rectangle().fill(MockPalette.line).frame(height: 1).opacity(title == "面试语言" ? 0 : 1) }
    }
}
