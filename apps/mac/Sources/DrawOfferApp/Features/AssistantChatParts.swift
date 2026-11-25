import AppKit
import DrawOfferCore
import SwiftUI

// AI 对话（Figma「DrawOffer macOS 设计稿」第 35:31 页 02B）的分块视图。主流程与接口调用在 AssistantChatView。

// MARK: - 02B·02 新建对话：一行问句 + 输入框下的快捷输入

/// 品牌山茶花标记（Resources/Branding/mark.png）。
struct AssistantBrandMark: View {
    var size: CGFloat = 30
    private static let image: NSImage? = Bundle.module.url(forResource: "mark", withExtension: "png", subdirectory: "Branding").flatMap(NSImage.init(contentsOf:))
    var body: some View {
        Group {
            if let image = Self.image { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
            else { Circle().fill(V3.orange.opacity(0.85)) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

enum AssistantGreeting {
    struct Prompt: Hashable { let symbol: String; let text: String }

    /// 一行标语（Web `greetingTitle`）：备战时问“先准备哪块”，起步时讲第一步，其他沿用场景标题。
    static func title(_ scene: HomeScene) -> String {
        if scene.key == "start" { return "先说说你做过什么，我来写第一版简历" }
        if scene.key == "prep", !scene.eyebrow.isEmpty { return scene.eyebrow.replacingOccurrences(of: "前$", with: "", options: .regularExpression) + "，先准备哪块？" }
        return scene.title
    }

    /// 按状态给三条快捷输入（Web `greetingPrompts`）。
    static func prompts(_ scene: HomeScene) -> [Prompt] {
        let first = scene.list.first?.title
        let second = scene.list.count > 1 ? scene.list[1].title : nil
        let ask = scene.suggestion.isEmpty ? nil : Prompt(symbol: "questionmark.circle", text: scene.suggestion)
        let review = Prompt(symbol: "clock.arrow.circlepath", text: "最近一次练习，帮我复盘一下")
        let event = scene.eyebrow.replacingOccurrences(of: "前$", with: "", options: .regularExpression)
        let candidates: [Prompt?]
        switch scene.key {
        case "start": candidates = [Prompt(symbol: "pencil", text: "我还没有简历，先跟你说说我做过什么"),
                                    Prompt(symbol: "square.and.arrow.up", text: "我有一份简历，帮我导入进来"),
                                    Prompt(symbol: "questionmark.circle", text: "第一份简历，该先写哪些内容")]
        case "materials": candidates = [scene.suggestion.isEmpty ? nil : Prompt(symbol: "doc.text", text: scene.suggestion),
                                        Prompt(symbol: "pencil", text: "按我上传的资料，写第一份简历"),
                                        Prompt(symbol: "questionmark.circle", text: "写简历之前，还缺哪些信息要补？")]
        case "resume": candidates = [first.map { Prompt(symbol: "mic", text: "模拟面试问问我「\($0)」") }, ask,
                                     Prompt(symbol: "doc.text", text: "我的简历里哪段经历最容易被追问？")]
        case "experience": candidates = [first.map { Prompt(symbol: "mic", text: "陪我练讲「\($0.replacingOccurrences(of: " · $", with: "", options: .regularExpression))」") }, ask,
                                         Prompt(symbol: "doc.text", text: "我的简历里哪段经历最容易被追问？")]
        case "prep": candidates = [Prompt(symbol: "calendar", text: "把\(event)可能问的问题列出来"),
                                   first.map { Prompt(symbol: "mic", text: "出三道「\($0)」的题，我来答") }, ask]
        case "weak": candidates = [first.map { Prompt(symbol: "mic", text: "出三道「\($0)」的题，我来答") },
                                   first.map { Prompt(symbol: "questionmark.circle", text: "讲讲「\($0)」，我再复述一遍") }, ask]
        case "return": candidates = [ask.map { Prompt(symbol: "mic", text: $0.text) },
                                     second.map { Prompt(symbol: "questionmark.circle", text: "「\($0)」我上次答到哪了？") }, review]
        default: candidates = [ask, Prompt(symbol: "mic", text: "再陪我练一场，往深里问"), review]
        }
        var seen = Set<String>()
        return candidates.compactMap { $0 }.filter { !$0.text.isEmpty && seen.insert($0.text).inserted }.prefix(3).map { $0 }
    }
}

/// 标语行（02B·02 · 59:14324）：30 号山茶花 + 26 号思源宋体半粗问句。
struct AssistantGreetingTitle: View {
    let text: String?
    var body: some View {
        HStack(spacing: 12) {
            AssistantBrandMark(size: 30)
            Text(text ?? " ").font(V3.serif(26)).fontWeight(.semibold).foregroundStyle(V3.txt).lineLimit(2)
        }.frame(height: 37).opacity(text == nil ? 0 : 1).animation(.easeOut(duration: 0.2), value: text)
    }
}

/// 快捷输入（02B·02 方案 A）：一列，每行 44 高，图标 + 一句话，行间细线；悬停 #F4F4F1 圆角 8。点一下只填进输入框。
struct AssistantPromptList: View {
    let prompts: [AssistantGreeting.Prompt]
    let pick: (String) -> Void
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(prompts.enumerated()), id: \.element) { index, prompt in
                if index > 0 { Rectangle().fill(Color(hex: 0xECEBE6)).frame(height: 1).padding(.horizontal, 14).opacity(hovered == prompt.text || hovered == prompts[index - 1].text ? 0 : 1) }
                Button { pick(prompt.text) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: prompt.symbol).font(.system(size: 13, weight: .light)).foregroundStyle(V3.sub).frame(width: 15)
                        Text(prompt.text).font(V3.sans(14)).foregroundStyle(Color(hex: 0x3D3D3A)).lineLimit(1)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 17).frame(height: 44)
                        .background(hovered == prompt.text ? Color(hex: 0xF4F4F1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).onHover { hovered = $0 ? prompt.text : (hovered == prompt.text ? nil : hovered) }
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("快捷输入")
    }
}

// MARK: - 02B·04 回复前的准备过程

/// 一轮回复的准备过程（Web `ProcessSnapshot`）：文字过程与工具调用按出现顺序排列；最终正文开始后仍保留，折成回答上方一行。
struct AssistantProcessSnapshot: Equatable {
    enum Entry: Equatable { case text(String), tool(String) }
    struct Activity: Equatable { let callKey: String; var label: String; var status: String; var summary: String }
    var timeline: [Entry] = []
    var activities: [Activity] = []
    var started = Date()
    var ended: Date?

    struct Step: Identifiable, Equatable { let id: String; let tool: Bool; let title: String; let detail: String?; let status: String?; let symbol: String? }

    /// 时间线 → 卡片行（Web `processSteps`）：工具按 callKey 原位更新；文字过程去掉与工具标签重复的行。
    var steps: [Step] {
        let toolLabels = Set(activities.map { Self.head($0.label) })
        return timeline.enumerated().compactMap { index, entry in
            switch entry {
            case .tool(let key):
                guard let activity = activities.first(where: { $0.callKey == key }) else { return nil }
                let label = activity.label.replacingOccurrences(of: "[…。.]+$", with: "", options: .regularExpression)
                let parts = label.components(separatedBy: "：")
                let name = (parts.first ?? label).replacingOccurrences(of: "^正在", with: "", options: .regularExpression)
                let detail = activity.status == "failed" ? "没有成功"
                    : [parts.dropFirst().joined(separator: "："), activity.summary].filter { !$0.isEmpty }.joined(separator: " · ")
                return Step(id: key, tool: true, title: activity.status == "running" ? "正在\(name)…" : name,
                            detail: detail.isEmpty ? nil : detail, status: activity.status, symbol: Self.symbol(name))
            case .text(let text):
                let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !toolLabels.contains(Self.head($0)) }
                return lines.isEmpty ? nil : Step(id: "text:\(index)", tool: false, title: lines.joined(separator: "\n"), detail: nil, status: nil, symbol: nil)
            }
        }
    }

    private static func head(_ label: String) -> String { label.components(separatedBy: CharacterSet(charactersIn: "…：")).first ?? label }

    /// 24 网格线性图标表（02B·04 Tool icons）对应的 SF Symbols。
    static func symbol(_ name: String) -> String? {
        let table: [(String, String)] = [
            ("查看简历", "doc.text"), ("新建简历", "doc.badge.plus"), ("生成修改建议", "pencil"), ("修改任务", "pencil"), ("翻译简历", "character.bubble"),
            ("换模板", "rectangle.split.2x1"), ("查看模板", "square.grid.2x2"), ("生成待写入的简历内容", "square.and.pencil"), ("整理画像建议", "person"),
            ("查看资料库", "folder"), ("检索资料内容", "magnifyingglass"), ("保存附件到资料库", "folder.badge.plus"), ("查看附件", "paperclip"),
            ("查看岗位", "briefcase"), ("搜索岗位广场", "building.2"), ("加入我的岗位", "bookmark"), ("计算匹配度", "gauge.with.dots.needle.33percent"),
            ("查看投递", "paperplane"), ("更新投递进度", "flag"), ("查看日程", "calendar"), ("查看模拟面试", "mic"),
            ("查询求职记忆", "clock.arrow.circlepath"), ("读取写作规则", "book"), ("读取工作流", "book"), ("向用户确认", "questionmark.bubble"),
            ("打开功能页面", "arrow.up.forward.square"), ("查看会员方案", "crown"),
        ]
        return table.first { name.hasPrefix($0.0) }?.1
    }
}

/// 工具卡（02B·04 · 59:11809）：560 宽、白底 15% 墨线细边、圆角 10、轻阴影；一步一行 34 高，图标之间用细线串起来。
/// 默认只露最近两步，下面写「前面还有 N 步 · 展开」。
struct AssistantProcessCard: View {
    let steps: [AssistantProcessSnapshot.Step]
    let expanded: Bool
    var expand: (() -> Void)? = nil

    var body: some View {
        let shown = expanded ? steps : Array(steps.suffix(2))
        let hidden = steps.count - shown.count
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .center, spacing: 0) {
                        glyph(step).frame(width: 20, height: 20)
                            .overlay(alignment: .top) {
                                if index > 0 { Rectangle().fill(Color(hex: 0x0B0B0B).opacity(0.13)).frame(width: 1, height: 14).offset(y: -20) }
                            }
                            .padding(.trailing, 10)
                        Text(step.title).font(V3.sans(13.5))
                            .foregroundStyle(!step.tool || step.status == "running" ? Color(hex: 0x8A8A84) : V3.txt).lineLimit(step.tool ? 1 : 3)
                        if let detail = step.detail {
                            Text(detail).font(V3.sans(12.5)).foregroundStyle(step.status == "failed" ? V3.red : Color(hex: 0xA3A39D)).lineLimit(1).padding(.leading, 10)
                        }
                        Spacer(minLength: 0)
                    }.frame(minHeight: 34)
                }
            }
            .padding(.horizontal, 19).padding(.vertical, 11)
            .frame(width: 560, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0x1F1E1D).opacity(0.15)))
            .shadow(color: .black.opacity(0.05), radius: 6, y: 4)
            if hidden > 0, let expand {
                Button(action: expand) { Text("前面还有 \(hidden) 步  ·  展开").font(V3.sans(12.5)).foregroundStyle(Color(hex: 0x8A8A84)) }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func glyph(_ step: AssistantProcessSnapshot.Step) -> some View {
        if !step.tool { Circle().fill(Color(hex: 0xC4C4BE)).frame(width: 5, height: 5) }
        else if step.status == "running" { ProgressView().controlSize(.mini).tint(V3.orange) }
        else if let symbol = step.symbol { Image(systemName: symbol).font(.system(size: 11, weight: .light)).foregroundStyle(V3.sub) }
        else { Circle().fill(Color(hex: 0xC4C4BE)).frame(width: 5, height: 5) }
    }
}

/// 回复完成后（02B·04 · 01.1d'）：过程折成回答上方的一行「✓ 做了 N 步准备，用时 M 秒 ›」，点开是完整工具卡。
struct AssistantProcessFold: View {
    let snapshot: AssistantProcessSnapshot
    @State private var open = false

    var body: some View {
        let steps = snapshot.steps
        let tools = steps.filter(\.tool).count
        if tools > 0 {
            let seconds = snapshot.ended.map { max(1, Int(($0.timeIntervalSince(snapshot.started)).rounded())) }
            VStack(alignment: .leading, spacing: 10) {
                Button { open.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
                        Text(seconds.map { "做了 \(tools) 步准备，用时 \($0) 秒" } ?? "做了 \(tools) 步准备").font(V3.sans(13))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                    }.foregroundStyle(Color(hex: 0x8A8A84)).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(open ? .isSelected : [])
                if open { AssistantProcessCard(steps: steps, expanded: true) }
            }
        }
    }
}

/// 等待回复（02B·03 / 04）：左侧 30 号山茶花轻轻呼吸，右侧当前一步与已用秒数，下面是工具卡。
struct AssistantThinking: View {
    let phase: String
    let started: Date
    let steps: [AssistantProcessSnapshot.Step]
    @Binding var expanded: Bool
    var compacting = false
    @State private var breathe = false

    var body: some View {
        if compacting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(phase).font(V3.sans(13.5)).foregroundStyle(Color(hex: 0x6E7582))
                seconds
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(phase).font(V3.sans(15)).foregroundStyle(Color(hex: 0x6E7582)).lineLimit(1)
                    seconds
                    if expanded && steps.count > 2 {
                        Button("收起") { expanded = false }.buttonStyle(.plain).font(V3.sans(12.5)).foregroundStyle(Color(hex: 0x8A8A84)).padding(.leading, 4)
                    }
                }.frame(height: 24)
                if !steps.isEmpty { AssistantProcessCard(steps: steps, expanded: expanded, expand: { expanded = true }) }
            }
            .overlay(alignment: .topLeading) {
                AssistantBrandMark(size: 30).scaleEffect(breathe ? 1.06 : 0.94).opacity(breathe ? 1 : 0.75)
                    .offset(x: -54, y: -3)
                    .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true } }
            }
            .accessibilityElement(children: .combine).accessibilityLabel("AI 正在思考：\(phase)")
        }
    }

    private var seconds: some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            Text("\(max(0, Int(context.date.timeIntervalSince(started)))) 秒").font(V3.number(12, weight: .regular)).foregroundStyle(Color(hex: 0x8791A1))
        }
    }
}

// MARK: - 02B·08 / 09 对话卡片

/// 回复下面的卡片（Web `ActionCard`，02B·09 定稿）：白底细边、横排，按内容收宽、多张自动换行；点开的那张描黑边。
/// 回执卡与对象卡在右侧预览或跳到对应页面；跳转卡去功能页；确认卡在卡片内确认。
struct AssistantActionCards: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router
    let cards: [JSONValue]
    let sessionID: String?
    let sequenceNo: Int?
    /// 生成的文档（02B·08 · 02.5）：同一行里一张「AI 文档」卡。
    var document: ChatPreviewTab? = nil
    let activeKey: String?
    let openPreview: (ChatPreviewTab) -> Void
    let changed: (JSONValue) -> Void

    static let actionTypes: Set<String> = ["confirm", "receipt", "handoff", "objects", "jobs"]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                switch card.text("type") {
                case "confirm": AssistantConfirmCard(card: card, sessionID: sessionID, sequenceNo: sequenceNo, changed: changed)
                case "receipt": receipt(card)
                case "handoff": handoff(card)
                case "objects", "jobs": ForEach(Array(objects(card).enumerated()), id: \.offset) { _, item in object(item) }
                default: EmptyView()
                }
            }
            if let document {
                cardButton(symbol: "doc.richtext", title: document.label, subtitle: "AI 文档 · \(document.content.count) 字", active: activeKey == document.key) { openPreview(document) }
            }
        }
    }

    private func receipt(_ card: JSONValue) -> some View {
        let kind = card.text("kind")
        let state = card.text("status") == "processing" ? "解析中" : card.text("status") == "failed" ? "解析失败" : ""
        let subtitle = [card.text("subtitle"), state].filter { !$0.isEmpty }.joined(separator: " · ")
        let tab: ChatPreviewTab? = kind == "resume" ? ChatPreviewTab(kind: .resume, id: card.text("target_id"), label: card.text("title"))
            : kind == "dataset" ? ChatPreviewTab(kind: .dataset, id: card.text("target_id"), label: card.text("title"))
            : kind == "job" && !card.text("target_id").isEmpty ? ChatPreviewTab(kind: .job, id: card.text("target_id"), label: card.text("title")) : nil
        return cardButton(symbol: ["resume": "doc.text", "dataset": "folder", "job": "briefcase"][kind] ?? "doc", title: card.text("title"), subtitle: subtitle,
                          failed: card.text("status") == "failed", active: tab.map { activeKey == $0.key } ?? false) {
            if let tab { openPreview(tab) }
            else if !card.text("application_id").isEmpty { router.jump(.application(card.text("application_id"))) }
            else { router.jump(.section(.jobs)) }
        }
    }

    private func handoff(_ card: JSONValue) -> some View {
        let workflow = card.text("workflow"), params = card["params"] ?? .null
        let symbols = ["mock_interview": "mic", "resume_import": "square.and.arrow.up", "job_import": "square.and.arrow.up", "resume_guide": "doc.text",
                       "section_refine": "pencil", "interview_review": "doc.text", "interview_prep": "target", "interview_record_import": "square.and.arrow.up"]
        return cardButton(symbol: symbols[workflow] ?? "arrow.right", title: card.text("title"), subtitle: card.text("subtitle"), go: true, active: false) {
            switch workflow {
            case "mock_interview": router.jump(.section(.mock))
            case "interview_review", "interview_prep", "interview_record_import":
                if !params.text("application_id").isEmpty { router.jump(.application(params.text("application_id"))) } else { router.jump(.section(.jobs)) }
            case "resume_guide", "section_refine":
                if !params.text("resume_id").isEmpty { router.jump(.editResume(params.text("resume_id"))) } else { router.jump(.section(.resumes)) }
            case "resume_import": router.jump(.section(.resumes))
            case "job_import": router.jump(.section(.jobs))
            default: break
            }
        }
    }

    /// 读工具找到的岗位、投递和模拟面试（旧消息里的岗位列表也按对象卡显示）。
    private func objects(_ card: JSONValue) -> [JSONValue] {
        if card.text("type") == "objects" { return card["items"]?.items ?? [] }
        return (card["items"]?.items ?? []).map { item in
            .object(["kind": .string("pool_job"), "id": .string(item.text("id")), "title": .string(item.text("title")), "company": .string(item.text("company")),
                     "subtitle": .string([item.text("company"), item.text("city")].filter { !$0.isEmpty }.joined(separator: " · "))])
        }
    }

    /// 对象卡（02B·09 · 02.10a）：左边公司首字方块或图标，右边标题 13.5 与一行说明 12。
    private func object(_ item: JSONValue) -> some View {
        let kind = item.text("kind")
        let company = item.text("company").nilIfEmpty ?? item.text("title")
        let tab = Self.objectTab(item)
        let active = tab.map { activeKey == $0.key } ?? false
        return Button {
            if let tab { openPreview(tab); return }
            switch kind {
            case "application": router.jump(.application(item.text("id")))
            case "pool_job": router.jump(.section(.opportunities))
            case "mock_interview": router.jump(.section(.mock))
            default: router.jump(.section(.jobs))
            }
        } label: {
            HStack(spacing: 11) {
                Group {
                    if kind == "mock_interview" { Image(systemName: "mic").font(.system(size: 15, weight: .light)).foregroundStyle(V3.sub) }
                    else if kind == "match" { Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 17, weight: .light)).foregroundStyle(V3.sub) }
                    else {
                        PoolLogo(name: company, url: item.text("logo_url"), size: 32)
                    }
                }.frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind == "match" ? item.text("subtitle").nilIfEmpty ?? item.text("title") : item.text("title")).font(V3.sans(13.5, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
                    if !item.text("subtitle").isEmpty, kind != "match" { Text(item.text("subtitle")).font(V3.sans(12)).foregroundStyle(Color(hex: 0x8A8A84)).lineLimit(1) }
                }
            }.padding(.leading, 11).padding(.trailing, 14).frame(height: 53)
                .background(.white, in: RoundedRectangle(cornerRadius: 9.5)).overlay(RoundedRectangle(cornerRadius: 9.5).stroke(active ? Color(hex: 0x9E9E99) : V3.cl))
                .contentShape(Rectangle())
        }.buttonStyle(AssistantCardHover())
    }

    /// 读工具找到的对象在右侧预览里打开（Web `objectPreview`）；匹配度打开那个岗位并带上简历。
    static func objectTab(_ item: JSONValue) -> ChatPreviewTab? {
        let id = item.text("id")
        guard !id.isEmpty else { return nil }
        let base = { (kind: ChatPreviewTab.Kind, label: String) in
            ChatPreviewTab(kind: kind, id: id, label: label, resumeID: kind == .job ? item.text("resume_id").nonEmptyValue : nil,
                           company: item.text("company").nonEmptyValue, logoURL: item.text("logo_url").nonEmptyValue)
        }
        switch item.text("kind") {
        case "match": return base(.job, item.text("subtitle").nonEmptyValue ?? item.text("title"))
        case "pool_job": return base(.poolJob, item.text("title"))
        case "job": return base(.job, item.text("title"))
        case "application": return base(.application, item.text("title"))
        case "mock_interview": return base(.mockInterview, item.text("title"))
        default: return nil
        }
    }

    private func cardButton(symbol: String, title: String, subtitle: String, failed: Bool = false, go: Bool = false, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .light)).foregroundStyle(V3.sub).frame(width: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 20)
                    if !subtitle.isEmpty { Text(subtitle).font(V3.sans(12)).foregroundStyle(failed ? V3.orange : V3.fnt).lineLimit(1).frame(height: 18) }
                }
                if go { Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(V3.fnt).padding(.leading, 4) }
            }.padding(.leading, 12).padding(.trailing, 16).padding(.vertical, 10)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? V3.txt : V3.cl))
                .contentShape(Rectangle())
        }.buttonStyle(AssistantCardHover())
    }
}

/// 卡片悬停只把描边加深（不加灰底色块）。
private struct AssistantCardHover: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay { if hovering { RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xC9C9C3)).allowsHitTesting(false) } }
            .opacity(configuration.isPressed ? 0.85 : 1).onHover { hovering = $0 }
    }
}

/// 确认卡（02B·08 B）：右侧灰色「不用了」+ 白底细边「确认」；处理完换成一行状态；冲突时卡片下写红字。
private struct AssistantConfirmCard: View {
    @Environment(SessionStore.self) private var session
    let card: JSONValue
    let sessionID: String?
    let sequenceNo: Int?
    let changed: (JSONValue) -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let settled = card.text("status").nilIfEmpty.map { $0 != "pending" } ?? false
        let ready = sessionID != nil && (sequenceNo ?? 0) > 0
        let symbol = ["apply_template": "rectangle.split.2x1", "application_add_stage": "rectangle.3.group", "application_terminate": "flag"][card.text("action")] ?? "pencil"
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16, weight: .light)).foregroundStyle(settled ? Color(hex: 0x96968F) : V3.sub).frame(width: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(card.text("title")).font(V3.sans(14, weight: .medium)).foregroundStyle(settled ? V3.sub : V3.txt).lineLimit(1).frame(height: 20)
                    if !card.text("subtitle").isEmpty { Text(card.text("subtitle")).font(V3.sans(12)).foregroundStyle(V3.fnt).lineLimit(1).frame(height: 18) }
                }
                Spacer(minLength: 12)
                if settled {
                    HStack(spacing: 4) {
                        if card.text("status") == "executed" { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                        Text(card.text("status") == "executed" ? "已完成" : "已取消")
                    }.font(V3.sans(13)).foregroundStyle(card.text("status") == "executed" ? V3.green : V3.fnt)
                } else {
                    Button("不用了") { Task { await resolve("dismissed") } }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.sub).disabled(busy || !ready)
                    Button(busy ? "处理中…" : "确认") { Task { await confirm() } }.buttonStyle(V3ButtonStyle(kind: .ghost)).disabled(busy || !ready).padding(.leading, 6)
                }
            }
            if let error { Text(error).font(V3.sans(12)).foregroundStyle(V3.red).padding(.leading, 44) }
        }
        .padding(.leading, 12).padding(.trailing, 14).padding(.vertical, 10)
        .frame(minWidth: 420, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.cl))
    }

    private static func string(_ value: JSONValue?) -> JSONValue {
        guard let value else { return .null }
        if let number = value.numberValue { return .string(number == number.rounded() ? String(Int(number)) : String(number)) }
        return value.stringValue.map(JSONValue.string) ?? .null
    }

    private static func number(_ value: JSONValue?) -> JSONValue {
        if let number = value?.numberValue { return .number(number) }
        if let text = value?.stringValue, let number = Double(text) { return .number(number) }
        return .null
    }

    /// 卡片代表的产品操作，用用户自己的会话执行（Web `runConfirm`）。
    private func run() async throws {
        let p = card["params"] ?? .null
        switch card.text("action") {
        case "apply_template":
            _ = try await session.api.careerRequest(path: "/api/resumes/\(p.text("resume_id").nilIfEmpty ?? Self.string(p["resume_id"]).stringValue ?? "")/apply-template", method: "POST", query: [:],
                body: .object(["template_id": Self.string(p["template_id"]), "base_lock_version": Self.number(p["base_lock_version"])]))
        case "application_add_stage":
            _ = try await session.api.careerRequest(path: "/api/job-applications/\(Self.string(p["application_id"]).stringValue ?? "")/stages", method: "POST", query: [:],
                body: .object(["client_request_id": Self.string(p["client_request_id"]), "stage_type": Self.string(p["stage_type"]),
                               "stage_label": Self.string(p["stage_label"]), "interview_round_no": Self.number(p["interview_round_no"]),
                               "base_lock_version": Self.number(p["base_lock_version"])]))
        default:
            _ = try await session.api.careerRequest(path: "/api/job-applications/\(Self.string(p["application_id"]).stringValue ?? "")/terminate", method: "POST", query: [:],
                body: .object(["client_request_id": Self.string(p["client_request_id"]), "reason": Self.string(p["reason"]), "base_lock_version": Self.number(p["base_lock_version"])]))
        }
    }

    private func confirm() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await run()
            await resolve("executed", managed: false)
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            if case APIError.server(409, _) = error { self.error = "内容已经变了，这张卡片不能再用，请让助手重新生成。" }
            else { self.error = "这一步没有成功，请稍后再试。" }
        }
    }

    private func resolve(_ status: String, managed: Bool = true) async {
        guard let sessionID, let sequenceNo else { return }
        if managed { busy = true }
        defer { if managed { busy = false } }
        do {
            let result = try await session.api.careerRequest(path: "/api/agent/sessions/\(sessionID)/messages/\(sequenceNo)/cards/\(card.text("id")):resolve",
                                                             method: "POST", query: [:], body: .object(["status": .string(status)]))
            if let next = result["card"], next != .null { changed(next) }
        } catch { self.error = "这一步没有成功，请稍后再试。" }
    }
}

// MARK: - 02B·11 修改建议直接写在回复里

/// 修改建议（Web `SuggestionCard`，02B·11）：同一轮回复里的每一处列在一块容器里，标题栏写处数和进度；
/// 每处先给改后内容，「原文和原因」默认收起；采用、忽略、失败、过期都只换掉这一处右上角的按钮，不收起也不弹窗。
struct AssistantSuggestionList: View {
    let proposals: [JSONValue]
    let busy: String?
    let running: Bool
    let apply: (JSONValue) async -> Bool
    let reject: (JSONValue) async -> Bool
    let rewrite: (String) -> Void
    @State private var open = Set<String>()

    private static let mute = Color(hex: 0x96968F)
    private static let green = Color(hex: 0x2E8C57)

    static func state(_ proposal: JSONValue) -> String {
        if !proposal.text("superseded_by").isEmpty { return "expired" }
        return proposal.text("status").nilIfEmpty ?? "pending"
    }

    private func changes(_ proposal: JSONValue) -> [(before: String, after: String, op: String, section: String, name: String)] {
        let preview = proposal["preview"]?["changes"]?.items ?? []
        if !preview.isEmpty { return preview.map { ($0.text("before"), $0.text("after"), $0.text("op"), $0.text("section"), $0.text("name")) } }
        let operations = proposal["operations"]?.items ?? []
        if !operations.isEmpty {
            return operations.map { ($0["target"]?.text("selected_text").nilIfEmpty ?? "当前定位内容", $0.text("op") == "delete_target" ? "" : $0.text("new_text"), $0.text("op"), "", "") }
        }
        return [("当前简历内容", "候选简历内容", "", "", "")]
    }

    private var progress: String {
        let count = { (state: String) in proposals.filter { Self.state($0) == state }.count }
        let pending = count("pending")
        if pending == proposals.count { return "\(pending) 处待确认" }
        if pending == 0 && count("conflicted") == 0 {
            return (["已处理"] + [("采用", count("applied")), ("忽略", count("rejected")), ("过期", count("expired"))].filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }).joined(separator: " · ")
        }
        return [("已采用", count("applied")), ("已忽略", count("rejected")), ("待确认", pending), ("没能采用", count("conflicted")), ("已过期", count("expired"))]
            .filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    var body: some View {
        let multi = proposals.count > 1
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(V3.sub)
                Text(multi ? "修改建议 · \(proposals.count) 处" : "修改建议").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                if multi { Text(progress).font(V3.sans(13)).foregroundStyle(Self.mute).lineLimit(1) }
                Spacer(minLength: 0)
            }.padding(.horizontal, 20).frame(minHeight: 48).background(Color(hex: 0xFAFAF9))
            ForEach(Array(proposals.enumerated()), id: \.offset) { index, proposal in
                Rectangle().fill(V3.line).frame(height: 1)
                item(proposal, index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.cl))
        .accessibilityElement(children: .contain).accessibilityLabel("修改建议")
    }

    private func item(_ proposal: JSONValue, index: Int) -> some View {
        let state = Self.state(proposal)
        let list = changes(proposal)
        let place = [list.first?.section ?? "", list.first?.name ?? ""].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " · ").nilIfEmpty ?? "第 \(index + 1) 处"
        let tags = (proposal["rationale"]?.items ?? []).map { $0.text("tag").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(2)
        let dim = state == "rejected" || state == "expired"
        let id = proposal.text("id")
        let expanded = open.contains(id)
        let locked = busy != nil
        let reason = proposal.text("summary").trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text(place).font(V3.sans(13, weight: .medium)).foregroundStyle(dim ? Self.mute : V3.sub).lineLimit(1)
                    ForEach(Array(tags), id: \.self) { tag in
                        Text(tag).font(V3.sans(12)).foregroundStyle(V3.sub).padding(.horizontal, 7).padding(.vertical, 1)
                            .background(V3.field, in: RoundedRectangle(cornerRadius: 4)).opacity(dim ? 0.6 : 1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    switch state {
                    case "pending":
                        Button("忽略") { Task { _ = await reject(proposal) } }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.sub).padding(.horizontal, 8).disabled(locked)
                        Button(busy == id ? "正在采用…" : "采用") { Task { _ = await apply(proposal) } }.buttonStyle(AssistantSmallGhost()).disabled(locked || running)
                    case "conflicted":
                        Button("忽略") { Task { _ = await reject(proposal) } }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.sub).padding(.horizontal, 8).disabled(locked)
                        Button("按现在的内容重写") { rewrite(place) }.buttonStyle(AssistantSmallGhost()).disabled(locked || running)
                    case "applied": status("checkmark", "已采用", Self.green)
                    case "rejected": status("minus", "已忽略", Self.mute)
                    default: status("clock", "已过期", Self.mute)
                    }
                }
            }.frame(minHeight: 30)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, change in
                    Text(["delete_target", "delete"].contains(change.op) || change.after.isEmpty ? AttributedString("删除这一条：\(change.before)") : Self.highlight(change.before, change.after, dim: dim))
                        .font(V3.sans(14)).lineHeight(14, 24).foregroundStyle(dim ? Self.mute : V3.txt).textSelection(.enabled)
                }
            }
            if state == "conflicted" {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 12))
                    Text("没能采用：简历里这一段刚被你改过，原文已经对不上。")
                }.font(V3.sans(13)).foregroundStyle(V3.red)
            }
            if state == "expired" {
                Text("简历在这之后改过，这条建议不再适用。").font(V3.sans(13)).foregroundStyle(Self.mute)
            } else {
                Button { if expanded { open.remove(id) } else { open.insert(id) } } label: {
                    HStack(spacing: 2) {
                        Text(expanded ? "收起" : "原文和原因")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                    }.font(V3.sans(12)).foregroundStyle(Self.mute)
                }.buttonStyle(.plain)
                if expanded {
                    VStack(alignment: .leading, spacing: 4) {
                        detail("原文", list.map(\.before).filter { !$0.isEmpty }.joined(separator: "\n").nilIfEmpty ?? "（新增内容）", before: true)
                        if !reason.isEmpty { detail("原因", reason, before: false) }
                    }
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func status(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)); Text(text) }.font(V3.sans(13)).foregroundStyle(color).frame(height: 24)
    }

    private func detail(_ label: String, _ value: String, before: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(V3.sans(12)).foregroundStyle(Self.mute).frame(width: 24, alignment: .leading)
            Text(value).font(V3.sans(13)).foregroundStyle(before ? Self.mute : V3.sub).lineHeight(13, 20).textSelection(.enabled)
        }
    }

    /// 改后内容里新增的关键信息加粗（Web `highlightAdded`）：按词对比原文，连续新增且不只是标点的片段加粗。
    static func highlight(_ before: String, _ after: String, dim: Bool) -> AttributedString {
        func tokens(_ text: String) -> [String] {
            let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9.%+#]+|\\s+|[^A-Za-z0-9.%+#\\s]")
            let ns = text as NSString
            return regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) } ?? [text]
        }
        let a = tokens(before), b = tokens(after)
        guard !dim, !a.isEmpty, !b.isEmpty, a.count * b.count <= 250_000 else { return AttributedString(after) }
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var parts: [(String, Bool)] = []
        func push(_ text: String, _ added: Bool) {
            if let last = parts.last, last.1 == added { parts[parts.count - 1].0 += text } else { parts.append((text, added)) }
        }
        var i = 0, j = 0
        while j < b.count {
            if i < a.count && a[i] == b[j] { push(b[j], false); i += 1; j += 1 }
            else if i < a.count && dp[i + 1][j] >= dp[i][j + 1] { i += 1 }
            else { push(b[j], true); j += 1 }
        }
        let meaningful = { (text: String) in text.trimmingCharacters(in: .whitespaces).count >= 2 && text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
        let marked = parts.map { ($0.0, $0.1 && meaningful($0.0)) }
        if marked.allSatisfy({ $0.1 || $0.0.trimmingCharacters(in: .whitespaces).isEmpty }) { return AttributedString(after) }
        var result = AttributedString()
        for (text, added) in marked {
            var piece = AttributedString(text)
            if added { piece.font = V3.sans(14, weight: .medium) }
            result += piece
        }
        return result
    }
}

/// 小号白底细边按钮（26 高、圆角 13、13 号字），卡片里的「采用」「确认」。
struct AssistantSmallGhost: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
            .padding(.horizontal, 14).frame(height: 26)
            .background(configuration.isPressed ? V3.field : .white, in: Capsule()).overlay(Capsule().stroke(V3.cl))
            .opacity(enabled ? 1 : 0.45).padding(.leading, 2).contentShape(Capsule())
    }
}

// MARK: - 02B·07 添加资料（方案 B · 简化选择面板）

/// 添加资料面板（02B·07 方案 B · 59:11418）：380 宽，贴在输入框上沿；搜索与分类都是纯文字，点一行就加进对话、再点取消，
/// 已加的行右侧打勾；上传放在最后一行，用细线和资料分开。输入 @ 时同一个面板按输入的字筛选。
struct AssistantContextPanel: View {
    let groups: [JSONValue]
    let chosen: [JSONValue]
    let typeLabel: (String) -> String
    /// 输入 @ 时的筛选词；nil 表示从「添加资料」打开（带搜索框和分类）。
    var mention: String? = nil
    let toggle: (JSONValue) -> Void
    let upload: () -> Void
    @State private var query = ""
    @State private var type = ""
    @State private var hovered: JSONValue?

    private func key(_ item: JSONValue) -> String { item.text("type") + ":" + item.text("id") + ":" + item.text("version_id") }
    private func picked(_ item: JSONValue) -> Bool { chosen.contains { key($0) == key(item) } }
    private var types: [String] { groups.map { $0.text("type") }.filter { !$0.isEmpty } }
    private var currentType: String { type.isEmpty ? (types.first ?? "") : type }
    private var search: String { (mention ?? query).trimmingCharacters(in: .whitespaces) }

    private func matches(_ item: JSONValue) -> Bool {
        search.isEmpty || item.text("label").localizedCaseInsensitiveContains(search) || item.text("description").localizedCaseInsensitiveContains(search)
    }
    private func items(_ type: String) -> [JSONValue] { (groups.first { $0.text("type") == type }?["items"]?.items ?? []).filter(matches) }

    /// 每行一行小字（02B·07 B）：说明 + 浅灰日期。
    private func hint(_ item: JSONValue) -> String {
        var parts: [String] = []
        let description = item.text("description")
        if !description.isEmpty, description != "当前简历", description.count <= 16 { parts.append(description) }
        if let date = ResumeSummary.parseTimestamp(item.text("updated_at")) {
            let formatter = Beijing.formatter(); formatter.dateFormat = "MM-dd"; parts.append(formatter.string(from: date))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let list = mention == nil ? items(currentType) : types.flatMap(items)
        VStack(alignment: .leading, spacing: 0) {
            if mention == nil {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Color(hex: 0xA3A39C))
                    TextField("", text: $query, prompt: Text("搜索").foregroundStyle(Color(hex: 0xA3A39C))).textFieldStyle(.plain).font(V3.sans(14))
                }.padding(.horizontal, 20).padding(.top, 14)
                HStack(spacing: 16) {
                    ForEach(types, id: \.self) { value in
                        let count = chosen.filter { $0.text("type") == value }.count
                        Button { type = value } label: {
                            HStack(spacing: 4) {
                                Text(typeLabel(value)).font(V3.sans(13, weight: value == currentType ? .medium : .regular))
                                    .foregroundStyle(value == currentType ? Color(hex: 0x1F1F1D) : Color(hex: 0x8A8A84))
                                if count > 0, value != currentType {
                                    Text("\(count)").font(V3.number(9.5)).foregroundStyle(.white).frame(minWidth: 14, minHeight: 14).background(V3.txt, in: Capsule())
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(value == currentType ? .isSelected : [])
                    }
                }.padding(.horizontal, 17).padding(.top, 12).padding(.bottom, 10)
            }
            ScrollView {
                VStack(spacing: 0) {
                    if list.isEmpty { empty }
                    ForEach(list, id: \.self) { item in row(item) }
                }.padding(.horizontal, 7)
            }.frame(maxHeight: 6 * 36 + 4).fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Color(hex: 0xEDEDEA)).frame(height: 1).padding(.horizontal, 7).padding(.top, 4)
            Button(action: upload) {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 11)).foregroundStyle(V3.sub)
                    Text("上传本地文件").font(V3.sans(14)).foregroundStyle(Color(hex: 0x33332F))
                    Spacer(minLength: 0)
                }.padding(.horizontal, 20).frame(height: 46).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .frame(width: 380)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.cl))
        .shadow(color: .black.opacity(0.07), radius: 10, y: 6)
        .accessibilityElement(children: .contain).accessibilityLabel("添加资料")
    }

    @ViewBuilder private var empty: some View {
        if groups.isEmpty {
            Text("正在读取可引用的资料…").font(V3.sans(13)).foregroundStyle(V3.fnt).padding(.horizontal, 10).frame(height: 36, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // 当前分类没有结果时，提示其他分类的命中数，点一下切过去
            let others = types.filter { $0 != currentType }.map { ($0, items($0).count) }.filter { $0.1 > 0 }
            VStack(alignment: .leading, spacing: 4) {
                Text(search.isEmpty ? "这里还没有可引用的内容" : "没有匹配的资料").font(V3.sans(13)).foregroundStyle(V3.fnt)
                if mention == nil, !search.isEmpty {
                    ForEach(others, id: \.0) { value, count in
                        Button("在「\(typeLabel(value))」里找到 \(count) 项") { type = value }.buttonStyle(.plain).font(V3.sans(12.5)).foregroundStyle(V3.link)
                    }
                }
            }.padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ item: JSONValue) -> some View {
        let added = picked(item)
        return Button { toggle(item) } label: {
            HStack(spacing: 8) {
                Text(item.text("type") == "user_profile" ? "个人画像" : item.text("label")).font(V3.sans(14)).foregroundStyle(Color(hex: 0x1F1F1D)).lineLimit(1)
                Text(mention == nil ? hint(item) : [typeLabel(item.text("type")), hint(item)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(V3.sans(12)).foregroundStyle(Color(hex: 0xA3A39C)).lineLimit(1)
                Spacer(minLength: 8)
                if added { Image(systemName: "checkmark").font(.system(size: 10, weight: .medium)).foregroundStyle(Color(hex: 0x1F1F1D)) }
            }.padding(.horizontal, 10).frame(height: 36)
                .background(hovered == item ? V3.field : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
            .accessibilityAddTraits(added ? .isSelected : [])
    }
}

// MARK: - 02B·12 / 13 上下文用量

/// 上下文用量弹层（02B·13 · 59:11591，按 Claude 的写法列占比）：一行一类，左边颜色和名称，右边用量和占比，最后一行是剩余空间；
/// 用到 80% 以上右上角数字变橙，剩余空间那行提示满了自动压缩。
struct AssistantUsagePanel: View {
    let usage: JSONValue?
    let modelName: String?
    let details: [String: String]
    let compactDisabled: Bool
    let compact: () -> Void

    static let reserve = 16_384.0
    static let maxWindow = 200_000.0
    static let categories: [(String, String, Color)] = [
        ("conversation", "对话记录", Color(hex: 0x3F6FD8)), ("materials", "引用资料", Color(hex: 0xD9822B)), ("memory", "求职记忆", Color(hex: 0x8A5CC7)),
        ("attachments", "附件", Color(hex: 0x3B9A5B)), ("system", "系统指令与工具", Color(hex: 0xB4B4AE)),
    ]

    /// 弹层里的数一律取整到 k（Web `formatTokens`）。
    static func format(_ value: Double) -> String {
        if value < 1000 { return String(Int(value)) }
        if value < 1_000_000 { return "\(Int((value / 1000).rounded()))k" }
        return String(format: "%.1fM", value / 1_000_000)
    }

    var body: some View {
        let window = usage?["context_window"]?.numberValue ?? 0
        let limit = min(window, Self.maxWindow)
        let compactAt = max(1, limit - Self.reserve)
        let tokens = usage?["tokens"]?.numberValue
        let percent = tokens.map { min(100, $0 / compactAt * 100) }
        let high = (percent ?? 0) >= 80
        let breakdown = usage?["breakdown"]
        let rows = Self.categories.filter { (breakdown?[$0.0]?.numberValue ?? 0) > 0 }
        VStack(alignment: .leading, spacing: 0) {
            if let tokens, let percent {
                HStack {
                    Text("上下文").font(V3.sans(13.5, weight: .medium)).foregroundStyle(Color(hex: 0x55554F))
                    Spacer()
                    Text("\(Self.format(tokens)) / \(Self.format(compactAt))（\(Int(percent.rounded()))%）").font(V3.number(13.5, weight: .medium))
                        .foregroundStyle(high ? V3.orange : Color(hex: 0x1D1D1B))
                }.frame(height: 16)
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        if case .object = breakdown {
                            ForEach(rows, id: \.0) { key, _, color in color.frame(width: max(2, geometry.size.width * min(1, (breakdown?[key]?.numberValue ?? 0) / compactAt))) }
                        } else { Color(hex: 0x3F6FD8).frame(width: geometry.size.width * min(1, tokens / compactAt)) }
                        Spacer(minLength: 0)
                    }.background(Color(hex: 0xEFEFEC)).clipShape(Capsule())
                }.frame(height: 6).padding(.top, 12).padding(.bottom, 10)
                ForEach(rows, id: \.0) { key, name, color in
                    let value = breakdown?[key]?.numberValue ?? 0
                    line(color: color, name: name, detail: details[key], value: value, compactAt: compactAt, muted: false)
                }
                line(color: Color(hex: 0xE6E6E2), name: "剩余空间", detail: high ? "满了自动压缩" : nil, value: max(0, compactAt - tokens), compactAt: compactAt, muted: true)
            } else {
                Text("较早的对话已压缩成摘要").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                Text("下次回复后重新计算用量；引用的资料、记忆和附件仍可随时读取。").font(V3.sans(12)).foregroundStyle(V3.sub)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            Rectangle().fill(Color(hex: 0xEEEEEA)).frame(height: 1).padding(.top, 10)
            HStack {
                Text([modelName, "用到 \(Self.format(compactAt)) 时自动压缩"].compactMap { $0 }.joined(separator: " · "))
                    .font(V3.sans(12)).foregroundStyle(Color(hex: 0x8A8A84)).lineLimit(1)
                Spacer(minLength: 8)
                if tokens != nil {
                    Button(action: compact) {
                        Text("压缩上下文").font(V3.sans(12.5, weight: .medium)).foregroundStyle(Color(hex: 0x1D1D1B)).frame(width: 87, height: 27)
                            .background(Color(hex: 0xF2F2EF), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(compactDisabled).opacity(compactDisabled ? 0.45 : 1)
                }
            }.padding(.top, 12)
        }
        .padding(.horizontal, 19).padding(.top, 17).padding(.bottom, 15)
        .frame(width: 340)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0xE6E6E2)))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 6)
        .accessibilityElement(children: .contain).accessibilityLabel("上下文用量")
    }

    private func line(color: Color, name: String, detail: String?, value: Double, compactAt: Double, muted: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 10, height: 10)
            Text(name).font(V3.sans(13.5)).foregroundStyle(muted ? Color(hex: 0x8A8A84) : Color(hex: 0x1D1D1B))
            if let detail { Text(detail).font(V3.sans(12)).foregroundStyle(Color(hex: 0xA3A39D)).lineLimit(1) }
            Spacer(minLength: 8)
            Text(Self.format(value)).font(V3.number(13, weight: .regular)).foregroundStyle(Color(hex: 0x8A8A84)).frame(width: 40, alignment: .trailing)
            Text(String(format: "%.1f%%", min(100, value / compactAt * 100))).font(V3.number(13, weight: .medium))
                .foregroundStyle(muted ? Color(hex: 0x8A8A84) : Color(hex: 0x1D1D1B)).frame(width: 52, alignment: .trailing)
        }.frame(height: 26)
    }
}

/// 输入框底栏的上下文圆环（02B·12）：16 号细环，满格即自动压缩点，80% 以上变橙。点一下由外层打开用量弹层。
struct AssistantUsageRing: View {
    let usage: JSONValue?
    let toggle: () -> Void

    var body: some View {
        if let window = usage?["context_window"]?.numberValue {
            let compactAt = max(1, min(window, AssistantUsagePanel.maxWindow) - AssistantUsagePanel.reserve)
            let percent = usage?["tokens"]?.numberValue.map { min(100, $0 / compactAt * 100) }
            let label = percent.map { "距自动压缩已用 \(Int($0.rounded()))%" } ?? "上下文已压缩，下次回复后更新用量"
            Button(action: toggle) {
                ZStack {
                    Circle().stroke(V3.cl, lineWidth: 1.6)
                    if let percent, percent > 0 {
                        Circle().trim(from: 0, to: max(0.03, percent / 100)).stroke(percent >= 80 ? V3.orange : V3.txt, style: StrokeStyle(lineWidth: 1.6, lineCap: .round)).rotationEffect(.degrees(-90))
                    }
                }.frame(width: 12, height: 12).frame(width: 18, height: 18).contentShape(Rectangle())
            }.buttonStyle(.plain).help(label).accessibilityLabel(label)
        }
    }
}
