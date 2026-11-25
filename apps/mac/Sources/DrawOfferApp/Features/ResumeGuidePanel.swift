import AppKit
import DrawOfferCore
import SwiftUI
import UniformTypeIdentifiers

/// 新建简历的引导（Figma 03 页分区 05「对话版」，Web `guide/ResumeGuidePanel.tsx`）：纸面在左，引导在纸右边一列。
/// 每一步是职绘问一句（头像 + 气泡，补充一句灰字），下面是这一步要填的格子、快捷回答胶囊和输入框；编辑器里不用黑色按钮。表单直写的步骤（求职意向、基本信息、教育、证书与获奖）走 `guide/writes`；
/// 技能、经历、个人简介由 AI 按写作法则写好直接上纸；资料一步把文件交给引导对话读一遍，只用来预填后面的表单。
/// 步骤由服务端记录（`PATCH /api/resumes/{id}/guide`，版本冲突时重新读取）。
struct ResumeGuidePanel: View {
    typealias G = ResumeGuideModel
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router
    let resumeID: String
    @Binding var guide: JSONValue
    /// 纸面当前正文（含未保存的修改）与这份简历使用的模板 id。
    let data: JSONValue
    let templateID: String?
    /// 写入前先保存编辑器里的修改；保存失败时返回 false，不写。
    let saveFirst: () async -> Bool
    /// 服务端写入后返回的最新简历，由编辑器载入；`undoable` 记下写之前的正文，撤销时放回。
    let applied: (JSONValue) -> Void
    let undo: (JSONValue) -> Void
    let exportPDF: () -> Void
    let close: () -> Void

    struct Failure { let kind: String; let retry: () -> Void }
    struct LastWrite { let step: String; let before: JSONValue; let label: String }

    @State private var messages: [JSONValue] = []
    @State private var proposals: [JSONValue] = []
    @State private var running = false
    @State private var streamText = ""
    @State private var failure: Failure?
    @State private var busy = false
    @State private var notice: String?
    @State private var answer = ""
    @State private var welcome = false
    @State private var lastWrite: LastWrite?
    @State private var profile: JSONValue?
    @State private var career: JSONValue?
    @State private var careerReady = false
    @State private var templateSample: JSONValue?
    @State private var confirmed: Set<String> = []
    /// 一次点击里会连着推进几次（写入后再“下一步”），版本号要立即可见，不能等界面刷新（Web `guideRef`）。
    @State private var ref = Latest()
    final class Latest { var guide: JSONValue? }

    @State private var jobIntent: G.JobIntent?
    @State private var basicInfo: G.BasicInfo?
    @State private var education: G.EducationForm?
    @State private var skills: [(name: String, level: String)]?
    @State private var experience: G.ExperienceForm?
    @State private var phase = "form"
    @State private var skillPhase = "form"
    @State private var skillLines: [JSONValue] = []
    @State private var wrapPhase = "main"
    @State private var profileText = ""
    @State private var honors: G.HonorsForm?
    @State private var bullets: [JSONValue] = []
    @State private var unused: Set<String> = []
    @State private var opened: G.ExperienceItem?

    private var step: String { guide.text("current_step").isEmpty ? "materials" : guide.text("current_step") }
    private var sessionID: String { guide.text("session_id") }
    private var samples: Set<String> { G.sampleIDs(guide) }
    private var materials: JSONValue? { G.materialsDocument(proposals) }
    private var experienceItems: [G.ExperienceItem] { G.experienceList(data, materials: materials, samples: samples, unused: unused) }
    private var listMode: Bool { experienceItems.count >= 2 }
    /// 这一步 AI 写好、还没确认的草稿：最近一次（技能、经历自动上纸；资料只用来数“读到了几项”）。
    private var draft: JSONValue? {
        let recentRuns = Set(messages.filter { ($0["sequence_no"]?.numberValue ?? 0) > cutoff }.map { $0.text("run_id") }.filter { !$0.isEmpty })
        return proposals.filter { $0.text("proposal_mode") == "guided_fill" && $0["preview"]?.text("step") == step && $0.text("status") == "pending" && recentRuns.contains($0.text("run_id")) }
            .max { $0.text("created_at") < $1.text("created_at") }
    }
    private var cutoff: Double {
        let applied = Set(proposals.filter { $0.text("proposal_mode") == "guided_fill" && $0["preview"]?.text("step") == step && $0.text("status") == "applied" }.map { $0.text("run_id") })
        return messages.filter { applied.contains($0.text("run_id")) }.map { $0["sequence_no"]?.numberValue ?? 0 }.max() ?? 0
    }
    private var back: (() -> Void)? {
        guard let index = G.steps.firstIndex(of: step), index > 0, guide.text("status") == "active" else { return nil }
        let previous = G.steps[index - 1]
        return G.stepState(guide, previous) == "done" ? { Task { try? await change("goto_step", step: previous) } } : nil
    }

    var body: some View {
        // 分区 05：400 宽一列、没有卡片框和白底；关闭靠纸面上沿「引导」或 Esc。
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                    if let notice { Text(notice).font(V3.sans(12.5)).foregroundStyle(V3.red).padding(.top, 20).padding(.leading, ResumeTalk.indent) }
                    if notice == nil, let lastWrite, !busy, !running {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark").font(.system(size: 11))
                            Text("\(lastWrite.label)已写进左边")
                            Button("撤销") { Task { await undoLast() } }.buttonStyle(.plain).foregroundStyle(V3.blue)
                        }.font(V3.sans(12.5)).foregroundStyle(ResumeTalk.note).padding(.top, 20).padding(.leading, ResumeTalk.indent)
                    }
                }.padding(.top, 12).padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.never)
        }
        .frame(width: ResumeTalk.columnWidth).frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain).accessibilityLabel("引导创建简历")
        .task {
            welcome = guide.text("status") == "active" && step != "materials"
            await reload()
            async let user = try? session.api.careerRequest(path: "/api/account/user-profile", method: "GET", query: [:], body: nil)
            async let careerProfile = try? session.api.careerRequest(path: "/api/account/career-profile", method: "GET", query: [:], body: nil)
            profile = await user; career = await careerProfile; careerReady = true
            prefill()
            if let templateID, let template = try? await session.api.careerRequest(path: "/api/resume-templates/\(templateID)", method: "GET", query: [:], body: nil) {
                templateSample = template["template"]?["data"]
            }
        }
        .onChange(of: step) { prefill() }
        .onChange(of: proposals) { prefill(); autoWrite() }
    }

    // MARK: Step chrome

    /// 一步：顶上一行小字（上一步 · 第几步），职绘问一句（头像 + 白底气泡，补充灰字），下面是这一步的格子与快捷回答（缩进到气泡左缘）。
    private func stepView<Content: View>(_ step: String, title: String, note: String? = nil, thinking: Bool = false,
                                         back: (() -> Void)? = nil, backLabel: String = "上一步", @ViewBuilder content: () -> Content) -> some View {
        let index = (G.steps.firstIndex(of: step) ?? 0) + 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let back { Button("‹ \(backLabel)", action: back).buttonStyle(.plain) } else { Spacer().frame(width: 1) }
                Spacer()
                Text("\(G.labels[step] ?? "") · \(index) / \(G.steps.count)")
            }.font(V3.sans(12)).foregroundStyle(ResumeTalk.note).frame(minHeight: 18).padding(.leading, ResumeTalk.indent)
            ResumeTalkAssistant(text: title, note: note, thinking: thinking).padding(.top, 14)
            VStack(alignment: .leading, spacing: 0) { content() }.padding(.leading, ResumeTalk.indent)
        }
    }

    /// 快捷回答一排：主动作在前，其余是同样的白底胶囊（编辑器里不用黑色按钮）。
    private func actions(left: AnyView? = nil, primary: String? = nil, disabled: Bool = false, onPrimary: (() -> Void)? = nil) -> some View {
        ResumeTalkFlow(spacing: 9) {
            if let primary, let onPrimary { ResumeTalkChip(title: primary, disabled: disabled, action: onPrimary) }
            if let left { left }
        }.padding(.top, 17)
    }

    private func textLink(_ title: String, disabled: Bool = false, _ action: @escaping () -> Void) -> AnyView {
        AnyView(ResumeTalkChip(title: title, disabled: disabled, action: action))
    }

    private func row<Content: View>(_ label: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(label).font(V3.sans(13)).foregroundStyle(V3.sub).frame(width: 72, alignment: .leading)
                content().font(V3.sans(13.5))
                if let hint { Text(hint).font(V3.sans(12)).foregroundStyle(ResumeTalk.note) }
            }.frame(minHeight: 44)
            Divider().overlay(V3.cl)
        }
    }

    private func field(_ placeholder: String, _ text: Binding<String>, limit: Int) -> some View {
        TextField(placeholder, text: Binding(get: { text.wrappedValue }, set: { text.wrappedValue = String($0.prefix(limit)) }))
            .textFieldStyle(.plain).accessibilityLabel(placeholder)
    }

    private func choice(_ label: String, value: String, options: [(String, String)], set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 18) {
            ForEach(options, id: \.0) { option in
                Button(option.1) { set(option.0) }.buttonStyle(.plain)
                    .font(V3.sans(13.5, weight: value == option.0 ? .semibold : .regular))
                    .foregroundStyle(value == option.0 ? V3.txt : V3.fnt2)
                    .accessibilityAddTraits(value == option.0 ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(label)
    }

    private func group(_ text: String) -> some View { Text(text).font(V3.sans(12)).foregroundStyle(V3.fnt).padding(.top, 28).padding(.bottom, 8) }

    /// 输入框（分区 05/12 同一种）：47 高、圆角 13.5、#dcdad2 边，右侧 30 圆形发送钮；回车发送，⇧回车换行。
    private func underline(_ placeholder: String, value: Binding<String>, disabled: Bool = false, send: @escaping (String) -> Void) -> some View {
        let ready = !value.wrappedValue.trimmed.isEmpty && !disabled
        let submit = { guard ready else { return }; let text = value.wrappedValue.trimmed; value.wrappedValue = ""; send(text) }
        return HStack(alignment: .center, spacing: 8) {
            TextField("", text: value, prompt: Text(placeholder).foregroundStyle(ResumeTalk.hint), axis: .vertical)
                .textFieldStyle(.plain).font(V3.sans(13.5)).lineLimit(1...6)
                .disabled(disabled).accessibilityLabel(placeholder)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    submit(); return .handled
                }
            Button(action: submit) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).frame(width: 30, height: 30).background(ready ? V3.txt : ResumeTalk.line, in: Circle()) }
                .buttonStyle(.plain).disabled(!ready).accessibilityLabel("发送")
        }
        .padding(.leading, 16.5).padding(.trailing, 8).padding(.vertical, 8).frame(minHeight: 47)
        .background(.white, in: RoundedRectangle(cornerRadius: 13.5)).overlay(RoundedRectangle(cornerRadius: 13.5).stroke(ResumeTalk.fieldLine))
        .padding(.top, 25)
    }

    private func meta(_ text: String, link: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(text).foregroundStyle(V3.fnt)
            Button(link, action: action).buttonStyle(.plain).foregroundStyle(V3.blue)
        }.font(V3.sans(13)).padding(.top, 16)
    }

    // MARK: Body by step

    @ViewBuilder private var content: some View {
        if guide.text("status") == "completed" {
            stepView("wrap_up", title: "这份简历的引导已经完成", note: "之后直接在纸面上改就行。") { actions(primary: "关闭", onPrimary: close) }
        } else if welcome {
            let counts = G.welcome(guide)
            stepView(step, title: "欢迎回来，还差 \(counts.left.count) 步",
                     note: [counts.done.isEmpty ? "" : "已写好：\(counts.done.joined(separator: "、"))", "还差：\(counts.left.joined(separator: "、"))"].filter { !$0.isEmpty }.joined(separator: "　")) {
                actions(left: textLink("结束引导，自己改") { Task { try? await change("dismiss"); close() } }, primary: "接着写") { welcome = false }
                Text("结束后，可以从纸面上沿的「引导」重新打开。").font(V3.sans(12)).foregroundStyle(ResumeTalk.note).padding(.top, 20)
            }
        } else if let failure {
            stepView(step, title: failure.kind == "credit" ? "积分不够了" : failure.kind == "invalid" ? "这次没写好" : "这次没整理出来",
                     note: failure.kind == "credit" ? "简历没有改动，你填的内容都还在。充值后点重试，接着写。"
                        : failure.kind == "invalid" ? "写出来的不够具体，没有写上去，简历没有改动。可以回去多写一两句做了什么、用了什么，再试一次。"
                        : "没连上或出错了，简历没有改动。你填的内容都还在，重试不用再填一遍。") {
                actions(left: failure.kind == "credit" ? textLink("去充值") { router.jump(.plans) } : textLink("先跳过") {
                    self.failure = nil
                    if step == "experience" { experience = G.nextExperience(data, materials: materials, unused: unused); phase = listMode ? "list" : "form" }
                    else if step == "wrap_up" { wrapPhase = "main" }
                    else { next() }
                }, primary: "重试", onPrimary: failure.retry)
            }
        } else {
            switch step {
            case "materials": GuideMaterialsStep(guide: guide, running: running, found: draft.map { G.foundRows($0).count },
                                                 question: draft == nil && !running ? G.stepQuestion(messages, step: "materials") : nil,
                                                 read: { ids in try await change("set_materials", datasets: ids); await send(G.kickoff, kickoff: true) },
                                                 next: next, chrome: stepChrome)
            case "job_profile": jobProfileStep
            case "basics": basicsStep
            case "education": educationStep
            case "skills": skillsStep
            case "experience": experienceStep
            default: wrapUpStep
            }
        }
    }

    /// 给子视图用的步骤骨架（资料一步）。
    private func stepChrome(_ title: String, _ note: String, _ thinking: Bool, _ body: AnyView) -> AnyView {
        AnyView(stepView("materials", title: title, note: note, thinking: thinking) { body })
    }

    private func loading(_ step: String, _ title: String, _ text: String) -> some View {
        stepView(step, title: title, note: text, thinking: true) { EmptyView() }
    }

    @ViewBuilder private var jobProfileStep: some View {
        if let intent = jobIntent {
            let binding = Binding(get: { jobIntent ?? intent }, set: { jobIntent = $0 })
            stepView("job_profile", title: "你想投什么样的工作？", note: "后面每一步都按它来写，也会记进求职画像。", back: back) {
                VStack(spacing: 0) {
                    row("岗位") { field("比如：后端开发", binding.role, limit: 60) }
                    row("城市") { CityChips(cities: binding.cities) }
                    row("类型") { choice("求职类型", value: intent.type, options: [("campus", "校招"), ("internship", "实习"), ("any", "都可以")]) { jobIntent?.type = $0 }; Spacer() }
                    row("毕业", hint: intent.yearFromResume && (profile?["graduation_year"]?.numberValue == nil) ? "资料里读到" : nil) {
                        HStack(spacing: 4) {
                            TextField("2026", text: Binding(get: { intent.graduationYear }, set: { jobIntent?.graduationYear = String($0.filter(\.isNumber).prefix(4)) }))
                                .textFieldStyle(.plain).frame(width: 56).accessibilityLabel("毕业年份")
                            Text("届").foregroundStyle(V3.fnt)
                            Spacer()
                        }
                    }
                }.padding(.top, 24)
                actions(primary: "确认", disabled: busy || intent.role.trimmed.isEmpty) {
                    Task {
                        let ok = await write("求职意向") {
                            try await saveProfile { G.jobIntentChanges(intent, latest: $0) }
                            try await writeOperations([.object(["op": .string("set_identity"), "headline": .string(G.jobIntentHeadline(intent))])])
                        }
                        if ok { do { try await change("confirm_profile") } catch { notice = "还差想投的岗位。" } }
                    }
                }
            }
        } else { loading("job_profile", "你想投什么样的工作？", "正在读你的求职画像") }
    }

    @ViewBuilder private var basicsStep: some View {
        if let info = basicInfo {
            let binding = Binding(get: { basicInfo ?? info }, set: { basicInfo = $0 })
            stepView("basics", title: "简历上怎么称呼你、怎么联系你？", note: "手机和邮箱至少留一个，也会记进求职资料。", back: back) {
                VStack(spacing: 0) {
                    row("姓名") { field("真实姓名", binding.name, limit: 60) }
                    row("手机") { field("比如 138 0000 0000", binding.phone, limit: 30) }
                    row("邮箱") { field("比如 name@example.com", binding.email, limit: 120) }
                    row("链接") { field("GitHub 或个人主页，选填", binding.link, limit: 300) }
                }.padding(.top, 24)
                actions(left: textLink("先跳过", disabled: busy, skip), primary: "确认", disabled: busy || !G.basicInfoReady(info)) {
                    Task {
                        let ok = await write("基本信息") {
                            try await writeOperations(G.basicInfoOperations(info))
                            try? await saveCareerPersonal(G.basicInfoCareerChanges(info), overwrite: true)
                        }
                        if ok { next() }
                    }
                }
            }
        } else { loading("basics", "简历上怎么称呼你、怎么联系你？", "正在读你的求职资料") }
    }

    @ViewBuilder private var educationStep: some View {
        if let form = education {
            let binding = Binding(get: { education ?? form }, set: { education = $0 })
            stepView("education", title: "在哪里读书？", note: materials != nil && form.entryID == nil ? "资料里读到的已经填好，也会记进求职画像。" : "写进简历的教育经历，也会记进求职画像。", back: back) {
                VStack(spacing: 0) {
                    row("学校") { field("比如：浙江工业大学", binding.school, limit: 100) }
                    row("专业") { field("比如：软件工程", binding.major, limit: 100) }
                    row("学历") { choice("学历", value: form.degree, options: G.degrees.map { ($0, $0) }) { education?.degree = $0 }; Spacer() }
                    row("时间") {
                        HStack(spacing: 8) {
                            field("2022.09", binding.start, limit: 20).frame(width: 88).accessibilityLabel("入学时间")
                            Text("–").foregroundStyle(V3.fnt)
                            field("2026.06", binding.end, limit: 20).frame(width: 88).accessibilityLabel("毕业时间")
                            Spacer()
                        }
                    }
                }.padding(.top, 24)
                group("选填")
                VStack(spacing: 0) {
                    row("GPA") { field("比如 3.6 / 4.0", binding.gpa, limit: 40) }
                    row("主修课程") { field("挑和岗位相关的几门", binding.courses, limit: 200) }
                }
                actions(left: textLink("先跳过", disabled: busy, skip), primary: "确认", disabled: busy || !G.educationReady(form)) {
                    Task {
                        let ok = await write("教育") {
                            let format = G.entryFormat([data, templateSample], kinds: ["education"])
                            try await writeOperations(G.educationOperations(form, format: format, title: G.sectionTitle([templateSample], kind: "education")))
                            try? await saveProfile { G.educationProfileChanges($0, form) }
                        }
                        if ok { next() }
                    }
                }
            }
        } else { loading("education", "在哪里读书？", "正在读你的求职画像") }
    }

    @ViewBuilder private var skillsStep: some View {
        let names = (skills ?? []).map(\.name).joined(separator: "、")
        if skillPhase == "written" {
            let added = G.addedPoints(skillLines)
            stepView("skills", title: "专业技能写好了",
                     note: added.isEmpty ? "按你选的程度分了方向。哪里不准，直接告诉我怎么改。"
                        : added.contains(where: \.weak) ? "按你选的程度分了方向。下面是按常考点补充的知识点，不会的点掉；带圆点的是面试里没答好的。"
                        : "按你选的程度分了方向。下面是按常考点补充的知识点，不会的点掉。") {
                if !added.isEmpty {
                    FlowLayout(spacing: 14) {
                        ForEach(Array(added.enumerated()), id: \.offset) { _, point in
                            Button {
                                let next = G.withoutPoint(skillLines, line: point.line, text: point.text)
                                guard !next.isEmpty else { return }
                                Task {
                                    let ok = await write("专业技能") {
                                        try await writeOperations([.object(["op": .string("replace_section"), "semantic_kind": .string("skills"),
                                                                            "bullets": .array(next.map { .string($0.text("text")) })])])
                                    }
                                    if ok { skillLines = next }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if point.weak { Circle().fill(V3.orange).frame(width: 6, height: 6) }
                                    Text(point.text); Image(systemName: "xmark").font(.system(size: 9))
                                }.font(V3.sans(14)).foregroundStyle(V3.sub)
                            }.buttonStyle(.plain).disabled(busy || (skillLines.count == 1 && added.count == 1))
                                .help(point.weak ? "面试里问到过，没答好" : "")
                                .accessibilityLabel(point.weak ? "去掉 \(point.text)（面试里没答好）" : "去掉 \(point.text)")
                        }
                    }.padding(.top, 20)
                }
                underline("比如“去掉 Kafka，Redis 写深一点”，会整栏重写", value: $answer, disabled: busy) { writeSkills($0) }
                meta(names, link: "改技能和程度") { skillPhase = "form" }
                actions(primary: G.nextLabel("skills"), disabled: busy, onPrimary: next)
            }
        } else if skillPhase == "working" {
            stepView("skills", title: "正在按方向写专业技能", note: "大约半分钟，写好前左边先不能改。", thinking: true) {
                Text(names).font(V3.sans(13)).foregroundStyle(V3.fnt).padding(.top, 16)
            }
        } else if let list = skills {
            SkillLevelsStep(skills: Binding(get: { skills ?? list }, set: { skills = $0 }), busy: busy, back: back,
                            chrome: { title, note, body in AnyView(stepView("skills", title: title, note: note, back: back) { body }) },
                            confirm: { writeSkills(nil) }, skip: skip, actions: { left, primary, disabled, action in AnyView(actions(left: left, primary: primary, disabled: disabled, onPrimary: action)) },
                            textLink: { title, action in textLink(title, action) }, underline: { placeholder, value, send in AnyView(underline(placeholder, value: value, disabled: busy, send: send)) })
        }
    }

    @ViewBuilder private var experienceStep: some View {
        if let form = experience {
            let written = guide["steps"]?["experience"]?.text("status") == "written"
            let pendingNext = experienceItems.first { $0.status == "pending" && $0.form.name != form.name.trimmed }
            let missing = bullets.enumerated().filter { $0.element["missing_result"]?.bool == true }.map { String($0.offset + 1) }
            switch phase {
            case "list": experienceList
            case "written":
                stepView("experience", title: "这段\(form.kindLabel)写好了",
                         note: missing.isEmpty ? "看看左边。哪里不满意，直接告诉我怎么改。" : "第 \(missing.joined(separator: "、")) 条还缺结果。说一句效果（比如快了多少、用的人有多少），我来补上。") {
                    underline(missing.isEmpty ? "比如“第 2 条突出 Kafka”" : "比如“接口从 1 秒降到 200 毫秒”", value: $answer, disabled: busy) { writeExperience(form, $0) }
                    meta(form.summary, link: "编辑") { phase = "form" }
                    actions(left: textLink("＋ 再加一段", disabled: busy) {
                        opened = nil
                        experience = listMode ? G.ExperienceForm() : G.nextExperience(data, materials: materials, unused: unused)
                        phase = "form"
                    }, primary: pendingNext.map { "写下一段：\($0.form.name)" } ?? (listMode ? "回到经历清单" : G.nextLabel("experience")), disabled: busy) {
                        if let pendingNext { opened = pendingNext; experience = pendingNext.form; phase = "form" }
                        else if listMode { phase = "list" } else { next() }
                    }
                }
            case "working":
                stepView("experience", title: "正在按 STAR 写成要点", note: "大约半分钟，写好前左边先不能改。", thinking: true) {
                    Text(form.summary).font(V3.sans(13)).foregroundStyle(V3.fnt).padding(.top, 16)
                }
            default: experienceForm(form, first: !written)
            }
        }
    }

    private var experienceList: some View {
        let items = experienceItems
        let pending = items.filter { $0.status == "pending" }
        let written = items.filter { $0.status == "written" }.count, unusedCount = items.filter { $0.status == "unused" }.count
        let title = pending.isEmpty ? "\(items.count) 段经历都处理好了" : written > 0 ? "还有 \(pending.count) 段没写" : "资料里有 \(items.count) 段经历"
        let note = !pending.isEmpty ? "一段一段写，写好左边马上更新。不放进这份简历的，点进去选“这段不用”。"
            : ["\(written) 段已写进左边", unusedCount > 0 ? "\(unusedCount) 段这份简历不用" : ""].filter { !$0.isEmpty }.joined(separator: "，") + "。点一段可以再改。"
        return stepView("experience", title: title, note: note, back: back) {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    Button { openItem(item) } label: {
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.form.name).font(V3.sans(13.5, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
                                    Text(item.form.meta).font(V3.sans(13)).foregroundStyle(V3.fnt).lineLimit(1)
                                }
                                Spacer()
                                Text(item.status == "unused" ? "不用" : item.status == "pending" ? "待写" : "›")
                                    .font(V3.sans(item.status == "written" ? 17 : 13)).foregroundStyle(item.status == "written" ? V3.fnt2 : V3.fnt)
                            }.padding(.vertical, 14).contentShape(Rectangle())
                            Divider().overlay(V3.cl)
                        }
                    }.buttonStyle(.plain).disabled(busy || running)
                }
            }.padding(.top, 24)
            actions(left: textLink("＋ 再加一段", disabled: busy) { opened = nil; experience = G.ExperienceForm(); phase = "form" },
                    primary: pending.first.map { "写这段：\($0.form.name)" } ?? G.nextLabel("experience"), disabled: busy) {
                if let first = pending.first { openItem(first) }
                else if guide["steps"]?["experience"]?.text("status") == "written" { next() } else { skip() }
            }
        }
    }

    private func openItem(_ item: G.ExperienceItem) {
        if item.status == "unused" { unused.remove(item.form.name) }
        opened = item; experience = item.form; phase = "form"
    }

    private func experienceForm(_ form: G.ExperienceForm, first: Bool) -> some View {
        let binding = Binding(get: { experience ?? form }, set: { experience = $0 })
        let project = form.kind == "project"
        let fromList = listMode
        let heading = fromList && opened != nil && opened?.form.entryID == nil ? opened?.form.name : nil
        let canUnuse = fromList && opened != nil && opened?.form.entryID == nil && form.entryID == nil
        return stepView("experience", title: form.entryID != nil ? "改一改这段经历" : heading ?? (first ? "说说第一段经历" : "再说一段经历"),
                        note: first && form.name.trimmed.isEmpty && form.did.trimmed.isEmpty
                            ? "从最近的一段开始，写大白话就行。没有实习也能写：课程设计、毕业设计、比赛、社团和志愿活动都算。"
                            : "从最近的一段开始。写大白话就行，我来整理成要点。",
                        back: fromList ? { phase = "list" } : (first ? back : nil), backLabel: fromList ? "经历清单" : "上一步") {
            VStack(spacing: 0) {
                row("类型") { choice("经历类型", value: form.kind, options: G.experienceKinds.map { ($0.0, $0.1) }) { experience?.kind = $0 }; Spacer() }
                row(project ? "项目" : "单位") { field(project ? "项目名称" : "公司或组织名称", binding.name, limit: 100) }
                row("角色") { field(project ? "比如：后端负责人" : "比如：后端开发实习生", binding.role, limit: 100) }
                row("时间") {
                    HStack(spacing: 8) {
                        field("2025.07", binding.start, limit: 20).frame(width: 88).accessibilityLabel("开始时间")
                        Text("–").foregroundStyle(V3.fnt)
                        field("至今", binding.end, limit: 20).frame(width: 88).accessibilityLabel("结束时间")
                        Spacer()
                    }
                }
            }.padding(.top, 24)
            group("做了什么")
            VStack(spacing: 0) {
                TextField("比如：订单查询慢，我加了 Redis 缓存和分页，接口快了很多；还参与了压测。", text: Binding(get: { binding.wrappedValue.did }, set: { experience?.did = String($0.prefix(2000)) }), axis: .vertical)
                    .textFieldStyle(.plain).font(V3.sans(13.5)).lineLimit(3...10).padding(.vertical, 14).accessibilityLabel("做了什么")
                Divider().overlay(V3.cl)
                row("效果") { field("选填，比如：接口从 1 秒降到 200 毫秒", binding.result, limit: 500) }
            }
            actions(left: canUnuse ? textLink("这段不用", disabled: busy) {
                if let name = opened?.form.name { unused.insert(name) }
                opened = nil; phase = "list"
            } : fromList ? nil : textLink(first ? "跳过经历" : "不加了，下一步", disabled: busy) { if first { skip() } else { next() } },
                    primary: "写进简历", disabled: busy || !form.ready) { writeExperience(form, nil) }
        }
    }

    @ViewBuilder private var wrapUpStep: some View {
        switch wrapPhase {
        case "profile-working":
            stepView("wrap_up", title: "正在按你已写的内容起草个人简介", note: "大约半分钟，写好前左边先不能改。", thinking: true) { EmptyView() }
        case "profile":
            stepView("wrap_up", title: "个人简介写好了", note: "看看左边。哪里不准，直接告诉我怎么改。") {
                underline("比如“突出比赛获奖”“短一点”", value: $answer, disabled: busy) { writeProfile($0) }
                actions(primary: "好了", disabled: busy) { wrapPhase = "main" }
            }
        case "honors":
            if let form = honors {
                stepView("wrap_up", title: "证书与获奖", note: "一行一项，没有就空着。", back: { wrapPhase = "main" }, backLabel: "收尾") {
                    group("证书")
                    honorsArea("比如：英语六级 560\n计算机二级", Binding(get: { honors?.certificates ?? "" }, set: { honors?.certificates = String($0.prefix(1200)) }), label: "证书")
                    group("获奖")
                    honorsArea("比如：2024 年校一等奖学金\n全国大学生数学建模竞赛省二等奖", Binding(get: { honors?.awards ?? "" }, set: { honors?.awards = String($0.prefix(1200)) }), label: "获奖")
                    actions(primary: "写进简历", disabled: busy) {
                        let kinds = Set((G.sectionKinds(templateSample) + G.sectionKinds(data)))
                        let operations = G.honorsOperations(form, templateKinds: kinds)
                        guard !operations.isEmpty else { wrapPhase = "main"; return }
                        Task { if await write("证书与获奖", { try await writeOperations(operations) }) { wrapPhase = "main" } }
                    }
                }
            }
        default:
            let samplesLeft = (guide["samples"]?.items ?? []).count
            stepView("wrap_up", title: "第一份简历写好了", note: "点“完成”后，技能和经历也会记进求职画像，下一份简历直接带出。") {
                group("还可以")
                VStack(spacing: 0) {
                    linkRow(G.profileWritten(data, samples: samples) ? "重写个人简介" : "写个人简介", "按已写的内容起草 ›", disabled: busy) { writeProfile(nil) }
                    linkRow("填证书与获奖", "六级、奖学金、比赛 ›", disabled: busy) {
                        honors = G.honorsForm(data, materials: materials, profile: profile, samples: samples); wrapPhase = "honors"
                    }
                    if samplesLeft > 0 {
                        linkRow("删掉剩下的 \(samplesLeft) 处模板示例", "›", disabled: busy) {
                            Task { _ = await write("模板示例") { try await writeOperations([.object(["op": .string("remove_samples"), "node_ids": .array((guide["samples"]?.items ?? []).map { .string($0.text("node_id")) })])]) } }
                        }
                    }
                    linkRow("导入一个想投的岗位，按岗位再调一遍", "›") { router.jump(.section(.jobs)) }
                    linkRow("导出 PDF", samplesLeft > 0 ? "还有 \(samplesLeft) 处示例没删 ›" : "›", action: exportPDF)
                }
                actions(primary: "完成", disabled: busy) { Task { await finish() } }
            }
        }
    }

    private func honorsArea(_ placeholder: String, _ text: Binding<String>, label: String) -> some View {
        VStack(spacing: 0) {
            TextField(placeholder, text: text, axis: .vertical).textFieldStyle(.plain).font(V3.sans(13.5)).lineLimit(3...10).padding(.vertical, 14).accessibilityLabel(label)
            Divider().overlay(V3.cl)
        }
    }

    private func linkRow(_ title: String, _ trailing: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack {
                    Text(title).font(V3.sans(13.5, weight: .medium)).foregroundStyle(V3.txt)
                    Spacer()
                    Text(trailing).font(V3.sans(13)).foregroundStyle(V3.fnt)
                }.frame(minHeight: 50).contentShape(Rectangle())
                Divider().overlay(V3.cl)
            }
        }.buttonStyle(.plain).disabled(disabled)
    }

    // MARK: Prefill

    /// 进入一步时按纸面、资料、画像预填一次（Web 同名 useEffect）。
    private func prefill() {
        switch step {
        case "job_profile" where jobIntent == nil && profile != nil:
            jobIntent = G.jobIntent(profile: profile, document: materials ?? data)
        case "basics" where basicInfo == nil && careerReady:
            let own = G.basicInfo(data, personal: G.personal(career), samples: samples)
            let read = G.basicInfo(materials, personal: [:], samples: [])
            var info = G.BasicInfo()
            info.name = own.name.isEmpty ? read.name : own.name; info.phone = own.phone.isEmpty ? read.phone : own.phone
            info.email = own.email.isEmpty ? read.email : own.email; info.link = own.link.isEmpty ? read.link : own.link
            basicInfo = info
        case "education" where education == nil && profile != nil:
            education = G.education(data, materials: materials, profile: profile, samples: samples)
        case "skills" where skills == nil:
            let onPaper = G.skillsOnPaper(data), read = G.skillsOnPaper(materials)
            let saved = (career?["experience"]?["skills"]?.items ?? []).map { (name: $0.text("name"), level: $0["level"]?.stringValue) }
            let names = !onPaper.isEmpty ? onPaper : !read.isEmpty ? read : !saved.isEmpty ? saved
                : (profile?["skills"]?.items ?? []).compactMap(\.stringValue).map { (name: $0, level: String?.none) }
            let known = Dictionary(saved.map { ($0.name.lowercased(), $0.level) }, uniquingKeysWith: { first, _ in first })
            skills = names.map { (name: $0.name, level: $0.level ?? known[$0.name.lowercased()].flatMap { $0 } ?? "familiar") }
        case "experience" where experience == nil:
            experience = G.nextExperience(data, materials: materials, unused: unused)
            phase = G.experienceList(data, materials: materials, samples: samples, unused: unused).count >= 2 ? "list" : "form"
        default: break
        }
    }

    // MARK: Actions

    private func setGuide(_ value: JSONValue) { ref.guide = value; guide = value }

    private func next() { Task { try? await change("next") } }
    private func skip() { Task { try? await change("skip_step") } }

    private func change(_ action: String, step target: String? = nil, datasets: [String]? = nil) async throws {
        var body: [String: JSONValue] = ["expected_version": (ref.guide ?? guide)["version"] ?? .number(1), "action": .string(action)]
        if let target { body["step"] = .string(target) }
        if let datasets { body["dataset_ids"] = .array(datasets.map(JSONValue.string)) }
        do {
            if let next = try await session.api.careerRequest(path: "/api/resumes/\(resumeID)/guide", method: "PATCH", query: [:], body: .object(body))["guide"] { setGuide(next) }
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            if case APIError.server(409, _) = error, let latest = try? await session.api.careerRequest(path: "/api/resumes/\(resumeID)/guide", method: "GET", query: [:], body: nil)["guide"] { setGuide(latest) }
            throw error
        }
    }

    private func reload() async {
        guard !sessionID.isEmpty else { return }
        async let loaded = try? session.api.careerRequest(path: "/api/agent/sessions/\(sessionID)", method: "GET", query: [:], body: nil)
        async let list = try? session.api.careerRequest(path: "/api/agent/proposals", method: "GET",
                                                        query: ["resume_id": resumeID, "session_id": sessionID, "include_history": "true"], body: nil)
        if let value = await loaded { messages = value["session"]?["messages"]?.items ?? messages }
        if let value = await list { proposals = value["proposals"]?.items ?? proposals }
    }

    /// 引导对话：资料一步交给 AI 读一遍；中途换了步骤（409）时重新读引导，不算失败。
    private func send(_ content: String, kickoff: Bool = false) async {
        guard !sessionID.isEmpty, !running else { return }
        running = true; streamText = ""; failure = nil
        var failed: String?
        var body: [String: JSONValue] = ["content": .string(content), "idempotency_key": .string(UUID().uuidString.lowercased()), "guide_step": .string((ref.guide ?? guide).text("current_step"))]
        if kickoff { body["guide_kickoff"] = .bool(true) }
        do {
            try await session.api.streamAgent(path: "/api/agent/sessions/\(sessionID)/messages", method: "POST", body: .object(body)) { event in
                switch event.type {
                case "assistant.delta": streamText += event.data.text("delta")
                case "proposal.created": if let proposal = event.data["proposal"] { proposals = [proposal] + proposals.filter { $0.text("id") != proposal.text("id") } }
                case "run.failed": failed = event.data.text("error").isEmpty ? "failed" : event.data.text("error")
                default: break
                }
            }
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            if case APIError.server(_, "RESUME_GUIDE_STEP_MISMATCH") = error {
                if let latest = try? await session.api.careerRequest(path: "/api/resumes/\(resumeID)/guide", method: "GET", query: [:], body: nil)["guide"] { setGuide(latest) }
            } else if case APIError.server(_, let code) = error { failed = code } else { failed = "failed" }
        }
        await reload()
        streamText = ""; running = false
        if let failed { failure = Failure(kind: ["CREDIT_INSUFFICIENT", "PAID_CREDIT_REQUIRED"].contains(failed) ? "credit" : "failed", retry: { Task { await send(content, kickoff: kickoff) } }) }
    }

    /// 写入：先保存编辑器，再执行服务端写入；记下写之前的正文供撤销。
    @discardableResult
    private func write(_ label: String, onError: ((String) -> Bool)? = nil, _ run: () async throws -> Void) async -> Bool {
        let before = data, written = step
        busy = true; notice = nil
        defer { busy = false }
        guard await saveFirst() else { notice = "简历还没保存好，稍后再试。"; return false }
        do {
            try await run()
            lastWrite = LastWrite(step: written, before: before, label: label)
            return true
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            let code: String = { if case APIError.server(_, let code) = error { return code }; return "" }()
            if onError?(code) == true { return false }
            notice = ["TARGET_STALE", "RESUME_EDIT_CONFLICT"].contains(code) ? "简历刚被改过，请再确认一次。"
                : code == "RESUME_DRAFT_SAVE_FAILED" ? "简历还没保存好，稍后再试。" : "没写进去，简历没有改动，请重试。"
            return false
        }
    }

    private func writeOperations(_ operations: [JSONValue]) async throws {
        let result = try await session.api.careerRequest(path: "/api/resumes/\(resumeID)/guide/writes", method: "POST", query: [:],
                                                         body: .object(["step": .string((ref.guide ?? guide).text("current_step")), "operations": .array(operations)]))
        if let next = result["guide"] { setGuide(next) }
        if let resume = result["resume"] { applied(resume) }
    }

    private func compose(_ path: String, _ body: [String: JSONValue]) async throws -> JSONValue {
        let result = try await session.api.careerRequest(path: "/api/resumes/\(resumeID)/guide/\(path)", method: "POST", query: [:], body: .object(body))
        if let next = result["guide"] { setGuide(next) }
        if let resume = result["resume"] { applied(resume) }
        return result
    }

    private func undoLast() async {
        guard let last = lastWrite else { return }
        undo(last.before)
        lastWrite = nil
        switch last.step {
        case "skills": skillLines = []; skillPhase = "form"
        case "experience": bullets = []; if phase == "written" { phase = "form" }
        case "wrap_up": profileText = ""; wrapPhase = "main"
        default: break
        }
        if last.step != step { try? await change("goto_step", step: last.step) }
    }

    private func writeSkills(_ instruction: String?) {
        guard let list = skills, !list.isEmpty else { return }
        skillPhase = "working"
        Task {
            var body: [String: JSONValue] = ["skills": .array(list.map { .object(["name": .string($0.name), "level": .string($0.level)]) })]
            if let instruction { body["instruction"] = .string(instruction); body["previous"] = .array(skillLines) }
            let ok = await write("专业技能", onError: { code in
                failure = Failure(kind: G.failureKind(code), retry: { failure = nil; writeSkills(instruction) }); return true
            }) { skillLines = try await compose("skills:compose", body)["lines"]?.items ?? [] }
            skillPhase = ok ? "written" : "form"
        }
    }

    private func writeExperience(_ form: G.ExperienceForm, _ instruction: String?) {
        let kind = form.section
        let entryID = form.entryID ?? G.matchingEntry(data, form: form, samples: samples)
        let heading = G.entryLines(G.entryFormat([data, templateSample], kinds: [kind]), name: form.name, start: form.start, end: form.end, detail: form.role)
        phase = "working"
        Task {
            var body: [String: JSONValue] = ["kind": .string(kind), "name": .string(heading.name), "paragraphs": .array(heading.paragraphs.map(JSONValue.string)),
                                             "role": .string(form.role), "start": .string(form.start), "end": .string(form.end), "did": .string(form.did)]
            body["entry_id"] = entryID.map(JSONValue.string) ?? .null
            body["title"] = entryID == nil ? (G.sectionTitle([templateSample], kind: kind).map(JSONValue.string) ?? .null) : .null
            body["result"] = form.result.trimmed.isEmpty ? .null : .string(form.result.trimmed)
            if let instruction { body["instruction"] = .string(instruction); body["previous"] = .array(bullets.map { .string($0.text("text")) }) }
            let ok = await write("经历", onError: { code in
                failure = Failure(kind: G.failureKind(code), retry: { failure = nil; writeExperience(form, instruction) }); return true
            }) {
                let result = try await compose("experience:compose", body)
                var next = form; next.entryID = result["entry_id"]?.stringValue ?? entryID
                experience = next
                bullets = result["bullets"]?.items ?? []
            }
            phase = ok ? "written" : "form"
        }
    }

    private func writeProfile(_ instruction: String?) {
        wrapPhase = "profile-working"
        Task {
            var body: [String: JSONValue] = ["title": G.sectionTitle([templateSample], kind: "profile").map(JSONValue.string) ?? .null]
            if let instruction { body["instruction"] = .string(instruction); body["previous"] = .string(profileText) }
            let ok = await write("个人简介", onError: { code in
                failure = Failure(kind: G.failureKind(code), retry: { failure = nil; writeProfile(instruction) }); return true
            }) { profileText = try await compose("profile:compose", body).text("text") }
            wrapPhase = ok ? "profile" : "main"
        }
    }

    /// 技能、经历 AI 写好的草稿直接上纸（确认提案），写完进入“写好了，不满意说怎么改”。
    private func autoWrite() {
        guard let draft, !running, !busy, ["experience", "skills"].contains(step), !confirmed.contains(draft.text("id")) else { return }
        confirmed.insert(draft.text("id"))
        let skillsStep = step == "skills"
        Task {
            let ok = await write(skillsStep ? "专业技能" : "经历要点") {
                let result = try await session.api.careerRequest(path: "/api/agent/proposals/\(draft.text("id"))/confirm", method: "POST", query: [:],
                                                                 body: .object(["entry": .string("editor")]))
                if let resume = result["resume"] { applied(resume) }
            }
            guard ok else { return }
            if let latest = try? await session.api.careerRequest(path: "/api/resumes/\(resumeID)/guide", method: "GET", query: [:], body: nil)["guide"] { setGuide(latest) }
            await reload()
            if skillsStep { skillPhase = "written" } else { phase = "written" }
        }
    }

    /// 完成：联系方式只填求职资料的空位，资料里还没有经历时把这份简历读进去；画像只追加缺的事实；最后标记完成。
    private func finish() async {
        busy = true; defer { busy = false }
        do {
            if let career {
                let contacts = G.careerContactChanges(data, personal: G.personal(career))
                let readResume = !G.careerHasExperience(career)
                if !contacts.isEmpty { try await saveCareerPersonal(contacts, overwrite: false) }
                if readResume {
                    let latest = try await session.api.careerRequest(path: "/api/account/career-profile", method: "GET", query: [:], body: nil)
                    self.career = try await session.api.careerRequest(path: "/api/account/career-profile/read-resume", method: "POST", query: [:],
                                                                      body: .object(["base_lock_version": latest["lock_version"] ?? .number(0), "resume_id": .string(resumeID)]))
                }
            }
            if profile != nil {
                for attempt in 0..<2 {
                    let latest = try await session.api.careerRequest(path: "/api/account/user-profile", method: "GET", query: [:], body: nil)
                    guard let update = G.profileWrite(data, profile: latest) else { break }
                    do { profile = try await session.api.careerRequest(path: "/api/account/user-profile", method: "PUT", query: [:], body: update); break }
                    catch { if case APIError.server(409, _) = error, attempt == 0 { continue }; throw error }
                }
            }
            try await change("complete")
            close()
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            notice = "没保存上，画像和简历都没有改动，请重试。"
        }
    }

    /// 画像整体保存、带版本号：先读最新画像，在其上合并；版本冲突时再读一次重试。
    private func saveProfile(_ changes: (JSONValue) -> [String: JSONValue]) async throws {
        for attempt in 0..<2 {
            let latest = try await session.api.careerRequest(path: "/api/account/user-profile", method: "GET", query: [:], body: nil)
            do {
                profile = try await session.api.careerRequest(path: "/api/account/user-profile", method: "PUT", query: [:], body: G.profileUpdate(latest, changes(latest)))
                return
            } catch { if case APIError.server(409, _) = error, attempt == 0 { continue }; throw error }
        }
    }

    /// 求职资料的个人信息：`overwrite` 时用户亲手填的覆盖旧值，否则只填空位。
    private func saveCareerPersonal(_ changes: [String: String], overwrite: Bool) async throws {
        guard !changes.isEmpty else { return }
        let latest = try await session.api.careerRequest(path: "/api/account/career-profile", method: "GET", query: [:], body: nil)
        var personal = G.personal(latest)
        for (key, value) in changes where overwrite || (personal[key] ?? "").isEmpty { personal[key] = value }
        career = try await session.api.careerRequest(path: "/api/account/career-profile", method: "PUT", query: [:],
                                                     body: .object(["base_lock_version": latest["lock_version"] ?? .number(0), "personal": .object(personal.mapValues(JSONValue.string))]))
    }
}

// MARK: - 资料（01 / 02）

/// 资料一步：上传（PDF、Word、图片，存进“简历资料”资料夹）或从资料库里选，都处理完后交给引导一次读完。
private struct GuideMaterialsStep: View {
    typealias G = ResumeGuideModel
    @Environment(SessionStore.self) private var session
    let guide: JSONValue
    let running: Bool
    let found: Int?
    let question: String?
    let read: ([String]) async throws -> Void
    let next: () -> Void
    let chrome: (String, String, Bool, AnyView) -> AnyView

    struct File: Identifiable { let id: String; let name: String; var status: String; var datasetID: String? }
    @State private var files: [File] = []
    @State private var library: [JSONValue]?
    @State private var started = false
    @State private var readError: String?
    @State private var dropping = false
    @State private var folderID: String?

    private var reading: Bool { running || files.contains { $0.status == "uploading" || $0.status == "reading" } }
    private var done: Bool { found != nil && !reading }

    var body: some View {
        chrome(done ? "读到了 \(found ?? 0) 项" : reading ? "正在读资料" : question ?? "先给我一些资料吧",
               done ? "后面每一步都会帮你填好，你只需要看一眼、改一改。" : "旧简历、成绩单、项目文档都行。读到的内容会帮你填好后面的每一项，上传的文件也会存进资料库。",
               reading, AnyView(stepBody))
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                Task { await upload(await loadURLs(providers)) }
                return true
            }
            .overlay { if dropping { RoundedRectangle(cornerRadius: 12).stroke(V3.blue, style: StrokeStyle(lineWidth: 1.5, dash: [6])) } }
            .task { await preselected() }
            .onChange(of: files.map(\.status)) { scheduleRead() }
            .onChange(of: running) { scheduleRead() }
    }

    private var stepBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(files) { file in
                    VStack(spacing: 0) {
                        HStack {
                            Text(file.name).font(V3.sans(13.5, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(file.status == "uploading" ? "上传中…" : file.status == "failed" ? "没读出来，换一份试试"
                                 : file.status == "reading" || running ? "已存入资料库 · 正在读…" : "已存入资料库").font(V3.sans(13)).foregroundStyle(file.status == "failed" ? V3.red : V3.fnt)
                            if file.status == "uploading" || file.status == "reading" || (running && file.status == "ready") { ProgressView().controlSize(.mini) }
                        }.frame(minHeight: 50)
                        Divider().overlay(V3.cl)
                    }
                }
                linkRow(files.isEmpty ? "上传文件" : "再加一份", "PDF、Word、图片　›") { pick() }.disabled(reading)
                linkRow("从资料库里选", library == nil ? "›" : "⌃") { Task { await toggleLibrary() } }.disabled(reading)
                if let library {
                    if library.isEmpty { Text("资料库里还没有能读的文件").font(V3.sans(13)).foregroundStyle(V3.fnt).padding(.leading, 16).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                    ForEach(library, id: \.self) { item in
                        Button {
                            self.library = nil
                            guard !files.contains(where: { $0.datasetID == item.text("id") }) else { return }
                            started = false
                            files.append(File(id: item.text("id"), name: item.text("file_name"), status: "ready", datasetID: item.text("id")))
                        } label: {
                            Text(item.text("file_name")).font(V3.sans(13.5)).foregroundStyle(V3.txt).padding(.leading, 16).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(.top, 24)
            if let readError { Text(readError).font(V3.sans(13.5)).foregroundStyle(V3.red).padding(.top, 8) }
            // 05.1：快捷回答胶囊（编辑器里不用黑色按钮）
            HStack(spacing: 9) {
                if done { ResumeTalkChip(title: G.nextLabel("materials"), action: next) }
                else { ResumeTalkChip(title: files.isEmpty ? "没有资料，一栏一栏填" : "不用资料了，一栏一栏填", disabled: running, action: next) }
            }.padding(.top, 17)
        }
    }

    private func linkRow(_ title: String, _ trailing: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack { Text(title).font(V3.sans(13.5, weight: .medium)).foregroundStyle(V3.txt); Spacer(); Text(trailing).font(V3.sans(13)).foregroundStyle(V3.fnt) }
                    .frame(minHeight: 50).contentShape(Rectangle())
                Divider().overlay(V3.cl)
            }
        }.buttonStyle(.plain)
    }

    /// 首页带着资料进来：预选的资料直接列出来并开始读。
    private func preselected() async {
        let ids = (guide["dataset_ids"]?.items ?? []).compactMap(\.stringValue)
        guard !ids.isEmpty, files.isEmpty else { return }
        let datasets = (try? await session.api.careerRequest(path: "/api/datasets", method: "GET", query: [:], body: nil))?["datasets"]?.items ?? []
        files = ids.map { id in File(id: id, name: datasets.first { $0.text("id") == id }?.text("file_name") ?? "资料库里的资料", status: "ready", datasetID: id) }
    }

    private func toggleLibrary() async {
        if library != nil { library = nil; return }
        let datasets = (try? await session.api.careerRequest(path: "/api/datasets", method: "GET", query: [:], body: nil))?["datasets"]?.items ?? []
        library = Array(datasets.filter { $0.text("parse_status") == "succeeded" && !["audio", "video"].contains($0.text("asset_kind")) }.prefix(12))
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["pdf", "docx", "md", "txt", "png", "jpg", "jpeg", "webp"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        Task { await upload(panel.urls) }
    }

    private func loadURLs(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
        }
        return urls
    }

    private func guideFolder() async throws -> String {
        if let folderID { return folderID }
        let list = try await session.api.careerRequest(path: "/api/datasets/folders", method: "GET", query: [:], body: nil)["folders"]?.items ?? []
        var id = list.first { $0.text("name") == G.folderName }?.text("id") ?? ""
        if id.isEmpty {
            id = try await session.api.careerRequest(path: "/api/datasets/folders", method: "POST", query: [:], body: .object(["name": .string(G.folderName)])).text("id")
        }
        folderID = id
        return id
    }

    private func upload(_ urls: [URL]) async {
        started = false
        for url in urls.prefix(max(0, 10 - files.count)) {
            let key = UUID().uuidString
            files.append(File(id: key, name: url.lastPathComponent, status: "uploading"))
            do {
                let folder = try await guideFolder()
                let snapshot = try DatasetUpload.snapshot(url, folder: folder, limit: 50 * 1024 * 1024)
                defer { snapshot.discard() }
                let record = try await session.api.uploadDataset(snapshot)
                let id = record.text("id")
                update(key) { $0.status = "reading"; $0.datasetID = id }
                let ok = await waitParsed(id)
                update(key) { $0.status = ok ? "ready" : "failed" }
            } catch {
                if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
                update(key) { $0.status = "failed" }
            }
        }
    }

    private func update(_ key: String, _ change: (inout File) -> Void) {
        if let index = files.firstIndex(where: { $0.id == key }) { change(&files[index]) }
    }

    private func waitParsed(_ id: String) async -> Bool {
        for _ in 0..<90 {
            let datasets = (try? await session.api.careerRequest(path: "/api/datasets", method: "GET", query: [:], body: nil))?["datasets"]?.items ?? []
            if let record = datasets.first(where: { $0.text("id") == id }) {
                let parse = record["parse_status"]
                if record.text("parse_status") == "succeeded" || ((parse == nil || parse == .null) && record.text("upload_status") == "succeeded") { return true }
                if record.text("parse_status") == "failed" || record.text("upload_status") == "failed" { return false }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    /// 文件都处理完、至少有一份可读：停 1.2 秒后交给引导一次读完。
    private func scheduleRead() {
        guard !started, !running, !files.isEmpty, !files.contains(where: { $0.status == "uploading" || $0.status == "reading" }) else { return }
        var seen = Set<String>()
        let ids = ((guide["dataset_ids"]?.items ?? []).compactMap(\.stringValue) + files.filter { $0.status == "ready" }.compactMap(\.datasetID)).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        started = true
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            readError = nil
            do { try await read(ids) } catch { started = false; readError = "资料没交给引导，稍后再试。" }
        }
    }
}

// MARK: - 技能（06）

private struct SkillLevelsStep: View {
    typealias G = ResumeGuideModel
    @Binding var skills: [(name: String, level: String)]
    let busy: Bool
    let back: (() -> Void)?
    let chrome: (String, String, AnyView) -> AnyView
    let confirm: () -> Void
    let skip: () -> Void
    let actions: (AnyView?, String, Bool, @escaping () -> Void) -> AnyView
    let textLink: (String, @escaping () -> Void) -> AnyView
    let underline: (String, Binding<String>, @escaping (String) -> Void) -> AnyView
    @State private var adding = false
    @State private var more = ""

    var body: some View {
        chrome(skills.isEmpty ? "你会哪些技能？" : "这些技能，你分别到什么程度？",
               skills.isEmpty ? "直接写，用顿号隔开；写完再选熟练程度。" : "选好后，我会按方向把每项展开成具体知识点写进左边，程度照你选的写。",
               AnyView(VStack(alignment: .leading, spacing: 0) {
                   if !skills.isEmpty {
                       VStack(spacing: 0) {
                           ForEach(Array(skills.enumerated()), id: \.element.name) { index, skill in
                               VStack(spacing: 0) {
                                   HStack(spacing: 12) {
                                       Text(skill.name).font(V3.sans(13.5)).frame(width: 120, alignment: .leading).lineLimit(1)
                                       HStack(spacing: 18) {
                                           ForEach(G.skillLevels, id: \.0) { level in
                                               Button(level.1) { skills[index].level = level.0 }.buttonStyle(.plain)
                                                   .font(V3.sans(13.5, weight: skill.level == level.0 ? .semibold : .regular))
                                                   .foregroundStyle(skill.level == level.0 ? V3.txt : V3.fnt2)
                                           }
                                       }.accessibilityElement(children: .contain).accessibilityLabel("\(skill.name) 的熟练度")
                                       Spacer()
                                       Button { skills.remove(at: index) } label: { Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(V3.fnt2).frame(width: 24, height: 24) }
                                           .buttonStyle(.plain).accessibilityLabel("去掉 \(skill.name)")
                                   }.frame(minHeight: 50)
                                   Divider().overlay(V3.cl)
                               }
                           }
                       }.padding(.top, 24)
                   }
                   if adding || skills.isEmpty {
                       underline("比如“Python、Linux”，回车添加", $more) { text in
                           let known = Set(skills.map { $0.name.lowercased() })
                           let added = G.splitSkillNames(text).filter { !known.contains($0.lowercased()) }.map { (name: $0, level: "familiar") }
                           skills = Array((skills + added).prefix(30))
                       }
                   } else {
                       Button("＋ 添加技能") { adding = true }.buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.blue).padding(.top, 16)
                   }
                   actions(skills.isEmpty ? textLink("先跳过", skip) : nil, "写进简历", busy || skills.isEmpty, confirm)
               }))
    }
}

/// 城市：回车或逗号添加，退格删掉最后一个。
private struct CityChips: View {
    @Binding var cities: [String]
    @State private var input = ""
    var body: some View {
        FlowLayout(spacing: 16) {
            ForEach(cities, id: \.self) { city in
                HStack(spacing: 4) {
                    Text(city)
                    Button { cities.removeAll { $0 == city } } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).accessibilityLabel("去掉 \(city)")
                }.font(V3.sans(13.5))
            }
            TextField("输入城市，回车添加", text: Binding(get: { input }, set: { value in
                if value.hasSuffix("，") || value.hasSuffix(",") { input = String(value.dropLast()); add() } else { input = String(value.prefix(20)) }
            })).textFieldStyle(.plain).frame(minWidth: 120).onSubmit(add).accessibilityLabel("城市")
                .onKeyPress(.delete) { if input.isEmpty && !cities.isEmpty { cities.removeLast(); return .handled }; return .ignored }
        }.padding(.vertical, 12)
    }
    private func add() {
        let value = input.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty && !cities.contains(value) { cities = Array((cities + [value]).prefix(5)) }
        input = ""
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
