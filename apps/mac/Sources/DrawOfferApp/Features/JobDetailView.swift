import AppKit
import DrawOfferCore
import SwiftUI

/// 10 · 岗位详情（Figma 07 页 84:1298 10.01；Web `features/jobs/JobDetailPage.tsx` + `JobMatchCard.tsx`）：
/// 从投递详情右上角进入，左上角「← 公司 · 岗位」回到这条投递；不放「查看求职进程」按钮。
/// 页头是来源、衬线标题、⋯（编辑 / 删除）和一行事实，没填的合成一个虚线「补充」入口；
/// 下面左栏是岗位描述（长了收起，「展开全文」）与核心技能，右栏是简历匹配、公司和个人备注，栏间只用细线分开。
/// 匹配度由服务端按简历对照岗位直接算；还在算时每 3 秒轮询，最多 20 次。
struct JobDetailView: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let jobID: String
    /// 打开详情的求职进程；用于返回文字、关联简历与显示当前阶段。
    let application: JSONValue?
    let back: () -> Void
    let deleted: () -> Void

    @State private var job: JSONValue?
    @State private var app: JSONValue?
    @State private var loading = true
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var editingNotes = false
    @State private var notesDraft = ""
    @State private var resumes: [ResumeSummary] = []
    @State private var defaultResumeID: String?
    @State private var resumesLoaded = false
    @State private var match: JobMatch?
    @State private var matchLoading = false
    @State private var analyzing = false
    @State private var matchError: String?
    @State private var expanded = false
    @State private var bodyHeight: CGFloat = 0
    @State private var reload = UUID()

    private static let collapsedHeight: CGFloat = 430
    private var api: any APIClient { session.api }
    private var current: JSONValue? { app ?? application }
    private var linkedResumeID: String { current?.text("resume_id") ?? "" }
    /// 投递时关联了简历就用那一份，否则用默认简历（Web `defaultResumeOf`）。
    private var matchResume: (id: String, title: String, linked: Bool)? {
        if !linkedResumeID.isEmpty {
            return (linkedResumeID, current?.text("resume_title_snapshot").nonEmptyValue ?? resumes.first { $0.id == linkedResumeID }?.title ?? "投递简历", true)
        }
        return ResumeRequest.defaultResume(resumes, defaultResumeID).map { ($0.id, $0.title, false) }
    }
    private var resumeID: String { matchResume?.id ?? "" }
    private var hasDescription: Bool { !(job?.text("description").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    private var matchScope: String { "\(jobID)|\(resumeID)|\(hasDescription)" }

    var body: some View {
        GeometryReader { geometry in
            let width = min(860, max(0, geometry.size.width - 80))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if loading && job == nil {
                        topRow(nil)
                        V3Loading("正在加载岗位详情…").font(V3.sans(12)).frame(maxWidth: .infinity, minHeight: 240)
                    } else if let job {
                        content(job, width: width)
                    } else {
                        topRow(nil)
                        VStack(spacing: 10) {
                            Text("无法打开这个岗位").font(V3.serif(20)).foregroundStyle(V3.txt)
                            Text(error ?? "岗位服务暂时不可用，请稍后重试。").font(V3.sans(13)).foregroundStyle(V3.sub)
                            Button("重试") { reload = UUID() }.buttonStyle(V3ButtonStyle(kind: .ghost))
                        }.frame(maxWidth: .infinity, minHeight: 260)
                    }
                }
                .frame(width: width, alignment: .leading)
                .padding(.top, 52).padding(.bottom, 60).frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(V3.txt)
        .overlay(alignment: .top) { TextNoticeToast(text: $notice) }
        .task(id: reload) { await load() }
        .task(id: matchScope) { await loadMatch() }
        .centeredSheet(isPresented: $editing) {
            if let job { JobFieldsSheet(job: job, close: { editing = false }, saved: { updated in self.job = updated; editing = false; notice = "岗位信息已保存" }) }
        }
        .centeredConfirmation("永久删除这个岗位？", isPresented: $confirmDelete) {
            Button(busy ? "正在删除…" : "永久删除", role: .destructive) { Task { await deleteJob() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(job?.text("job_title") ?? "") · \(job?.text("company_name") ?? "") · 删除后无法恢复。求职进程、阶段、复盘和面试排期会一起删除；面试里上传的文件也会一起删除。")
        }
    }

    // MARK: - 页头

    private var backLabel: String {
        guard let current else { return "投递看板" }
        return [current.text("company_name_snapshot"), current.text("job_title_snapshot")].filter { !$0.isEmpty }.joined(separator: " · ").nonEmptyValue ?? "求职进度"
    }

    private func topRow(_ job: JSONValue?) -> some View {
        HStack(spacing: 12) {
            CareerJourneyTextButton(title: "← " + backLabel, color: V3.sub, action: back).accessibilityLabel("返回 " + backLabel)
            Spacer(minLength: 16)
            if let job {
                let source = job.text("source_type") == "external_import" ? "插件导入" : job.text("source_type") == "manual" ? "手工创建" : "智能导入"
                HStack(spacing: 6) {
                    Image(systemName: job.text("source_type") == "external_import" ? "puzzlepiece.extension" : "doc").font(.system(size: 10)).foregroundStyle(V3.fnt)
                    Text(([source, job.text("source_site")].filter { !$0.isEmpty } + ["更新于 " + CareerFormat.monthDay(job.text("updated_at"))]).joined(separator: " · "))
                        .font(V3.sans(11.5)).foregroundStyle(V3.fnt).lineLimit(1)
                    if let url = URL(string: job.text("source_url")), ["http", "https"].contains(url.scheme ?? "") {
                        Button { NSWorkspace.shared.open(url) } label: {
                            HStack(spacing: 3) { Text("打开来源"); Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)) }
                                .font(V3.sans(11.5, weight: .medium)).foregroundStyle(V3.link).contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.leading, 8)
                    }
                }
            }
        }.frame(height: 16)
    }

    private func content(_ job: JSONValue, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow(job)
            HStack(alignment: .top, spacing: 16) {
                Text(job.text("job_title")).font(V3.serif(28)).foregroundStyle(V3.txt).lineSpacing(2).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 580, alignment: .leading)
                Spacer(minLength: 0)
                Menu {
                    Button { editing = true } label: { Label("编辑岗位信息", systemImage: "pencil") }
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("删除岗位", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(V3.sub)
                        .frame(width: 33, height: 33).background(.white, in: Circle()).overlay(Circle().stroke(V3.cl))
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(busy).accessibilityLabel("更多岗位操作")
            }.padding(.top, 14)
            facts(job).padding(.top, 10)
            if let error { Text(error).font(V3.sans(12.5)).foregroundStyle(V3.red).padding(.top, 10) }
            Rectangle().fill(V3.line).frame(height: 1).padding(.top, 22)
            if width >= 760 {
                HStack(alignment: .top, spacing: 0) {
                    descriptionColumn(job).frame(width: min(520, width - 340), alignment: .topLeading)
                    Spacer(minLength: 40)
                    rail(job).frame(width: 267, alignment: .topLeading)
                }.padding(.top, 22)
            } else {
                VStack(alignment: .leading, spacing: 32) { descriptionColumn(job); rail(job) }.padding(.top, 22)
            }
        }
    }

    /// 阶段、薪资、地点、分类……只排有内容的；薪资、学历、经验没填的合成一个虚线入口。
    private func facts(_ job: JSONValue) -> some View {
        let stage = current.flatMap { app -> String? in
            guard app.text("status") == "active" else { return nil }
            return app["current_stage"]?.text("stage_label").nonEmptyValue ?? app.text("current_stage_label").nonEmptyValue ?? "待投递"
        }
        let salary = job.text("salary_text").nonEmptyValue ?? salaryRange(job)
        let items = [salary, job.text("work_city").nonEmptyValue, label(JobDescriptionFields.employment, job.text("employment_type")).nonEmptyValue,
                     job.text("education_requirement").nonEmptyValue, job.text("experience_requirement").nonEmptyValue,
                     label(JobDescriptionFields.workMode, job.text("work_mode")).nonEmptyValue].compactMap { $0 }
        let missing = [salary == nil ? "薪资" : nil, job.text("education_requirement").isEmpty ? "学历" : nil, job.text("experience_requirement").isEmpty ? "经验" : nil].compactMap { $0 }
        return FlowLayout(spacing: 10) {
            if let stage { Text(stage).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.txt).frame(height: 21) }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 10) {
                    if index > 0 { Text("·").foregroundStyle(V3.fnt2) }
                    Text(item).foregroundStyle(V3.sub)
                }.font(V3.sans(13)).frame(height: 21)
            }
            if !missing.isEmpty { CareerAddChip(title: "补充" + missing.joined(separator: "、")) { editing = true }.disabled(busy) }
        }
    }

    private func salaryRange(_ job: JSONValue) -> String? {
        let low = job.text("salary_min"), high = job.text("salary_max")
        guard !low.isEmpty || !high.isEmpty else { return nil }
        return [low, high].filter { !$0.isEmpty }.joined(separator: "-") + (job.text("salary_currency").isEmpty ? "" : " " + job.text("salary_currency"))
    }

    // MARK: - 岗位描述

    @ViewBuilder private func descriptionColumn(_ job: JSONValue) -> some View {
        let skills = (job["skills"]?.items ?? []).compactMap(\.stringValue)
        VStack(alignment: .leading, spacing: 0) {
            Text("岗位描述").font(V3.sans(15, weight: .medium)).frame(height: 18)
            if hasDescription {
                let overflowing = bodyHeight > Self.collapsedHeight + 1
                NativeMarkdownView(source: job.text("description"), size: 13.5, line: 24, softBreaks: true).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .background { GeometryReader { proxy in Color.clear.onAppear { bodyHeight = proxy.size.height }.onChange(of: proxy.size.height) { _, height in bodyHeight = height } } }
                    .frame(maxHeight: expanded ? nil : Self.collapsedHeight, alignment: .top).clipped()
                    .padding(.top, 22)
                if overflowing || expanded {
                    Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
                        HStack(spacing: 5) { Text(expanded ? "收起" : "展开全文"); Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)) }
                            .font(V3.sans(12.5)).foregroundStyle(V3.sub).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.top, 22).accessibilityAddTraits(expanded ? .isSelected : [])
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("核心技能").font(V3.sans(13, weight: .medium))
                    if skills.isEmpty { Text("未填写").font(V3.sans(12.5)).foregroundStyle(V3.fnt) }
                    else {
                        FlowLayout(spacing: 6) {
                            ForEach(Array(skills.enumerated()), id: \.offset) { _, skill in
                                Text(skill).font(V3.sans(11.5)).foregroundStyle(V3.txt).padding(.horizontal, 8).frame(height: 20).background(V3.field, in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                    if !job.text("work_schedule").isEmpty || !job.text("work_address").isEmpty {
                        HStack(alignment: .top, spacing: 32) {
                            info("工作安排", job.text("work_schedule"))
                            info("详细地址", job.text("work_address"))
                        }.padding(.top, 10)
                    }
                }
                .padding(.top, 17).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
                .padding(.top, 22)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("还没有岗位描述").font(V3.serif(18))
                    Text("把招聘网站上的岗位职责和任职要求粘贴过来。有了描述，就能用你的简历算出匹配度，模拟面试也会按它出题。")
                        .font(V3.sans(13)).foregroundStyle(V3.sub).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    Button("补充岗位信息") { editing = true }.buttonStyle(V3ButtonStyle(kind: .ghost)).disabled(busy).padding(.top, 4)
                    Text("也可以在右上角「⋯」→ 编辑岗位信息里一次填完所有字段。").font(V3.sans(11.5)).foregroundStyle(V3.fnt)
                }.padding(.top, 22)
            }
        }
    }

    // MARK: - 右栏

    private func rail(_ job: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            matchSection
            company(job).padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
                .padding(.top, 24)
            notes(job).padding(.top, 24).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
        }
    }

    private var resumeLabel: String {
        guard let matchResume else { return "" }
        return (matchResume.linked ? "投递简历" : "默认简历") + " · " + matchResume.title
    }

    @ViewBuilder private var matchSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("简历匹配").font(V3.sans(12)).foregroundStyle(V3.sub).fixedSize()
                Spacer(minLength: 8)
                if application != nil && !resumes.isEmpty {
                    Menu {
                        ForEach(resumes) { resume in
                            Button(resume.title + (resume.id == linkedResumeID ? " ✓" : "")) { Task { await linkResume(resume) } }.disabled(resume.id == linkedResumeID)
                        }
                    } label: { Text(resumeLabel.nonEmptyValue ?? "选择投递简历").font(V3.sans(12)).foregroundStyle(V3.sub).lineLimit(1).truncationMode(.middle) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true).disabled(busy).help("换一份投递简历").accessibilityLabel("投递简历")
                } else if !resumeLabel.isEmpty {
                    Text(resumeLabel).font(V3.sans(12)).foregroundStyle(V3.sub).lineLimit(1).truncationMode(.middle).help(resumeLabel)
                }
            }.frame(height: 14)
            if matchResume == nil {
                if !resumesLoaded {
                    if hasDescription { readingResumes } else { Text("正在读取简历…").font(V3.sans(12.5)).foregroundStyle(V3.fnt).padding(.top, 14) }
                } else {
                    Text("还没有简历").font(V3.serif(16)).padding(.top, 16)
                    Text("创建第一份简历后，打开岗位就会自动对照岗位描述算出匹配度。").font(V3.sans(12.5)).foregroundStyle(V3.sub).lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    Button { router?.jump(.section(.resumes)) } label: { HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 11)); Text("去创建简历") }.frame(maxWidth: .infinity) }
                        .buttonStyle(CareerRailButtonStyle()).padding(.top, 16)
                }
            } else if !hasDescription {
                Text("补充岗位描述后自动计算").font(V3.serif(16)).padding(.top, 16)
                Text("会用这份简历对照岗位要求，算出匹配度和还缺的经历。").font(V3.sans(12.5)).foregroundStyle(V3.sub).lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            } else {
                matchBody
            }
        }
    }

    private var matchBody: some View {
        let ready = match?.ready == true && !analyzing ? match : nil
        let failedCode = !analyzing && match?.status == "failed" ? match?.errorCode : nil
        let failure = matchError ?? failedCode.map { JobMatch.errorMessage($0) }
        let title: String, note: String?
        if matchLoading { title = "正在计算匹配度…"; note = nil }
        else if analyzing { title = "正在计算匹配度…"; note = "正在对照岗位要求逐条检查这份简历。" }
        else if let failure { title = "匹配度没有算出来"; note = failure }
        else if let ready { title = ready.headline.map { "还缺：\($0)" } ?? "已覆盖主要要求"; note = ready.stale ? "简历或岗位描述已变化，这个分数可能已过期。" : nil }
        else { title = "还没有匹配度"; note = "补充岗位描述或核心技能后自动计算。" }
        let score = ready?.score
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(score.map(String.init) ?? "—").font(V3.serif(46)).foregroundStyle(V3.txt)
                if score != nil { Text("/ 100").font(V3.sans(12)).foregroundStyle(V3.fnt) }
            }.frame(height: 57).padding(.top, 13)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(V3.field)
                    Capsule().fill(V3.blue).frame(width: proxy.size.width * CGFloat(max(0, min(100, score ?? 0))) / 100)
                }
            }.frame(width: 260, height: 6).padding(.top, 2).accessibilityHidden(true)
            Text(title).font(V3.serif(16)).foregroundStyle(V3.txt).fixedSize(horizontal: false, vertical: true).padding(.top, 17)
            if let note { Text(note).font(V3.sans(12.5)).foregroundStyle(V3.sub).fixedSize(horizontal: false, vertical: true).padding(.top, 6) }
            if matchLoading || analyzing { matchPlaceholders }
            if let ready {
                if !ready.hits.isEmpty { matchLine("已覆盖", ready.hits).padding(.top, 14) }
                if !ready.gaps.isEmpty { matchLine("还缺", ready.gaps).padding(.top, 14) }
            }
            Button { router?.jump(.editResume(resumeID)) } label: {
                HStack(spacing: 6) { Image(systemName: "pencil.line").font(.system(size: 12)); Text("按 JD 优化这份简历") }.frame(maxWidth: .infinity)
            }.buttonStyle(CareerRailButtonStyle()).disabled(resumeID.isEmpty).padding(.top, 18)
            HStack(spacing: 8) {
                Text("简历或岗位描述改动后，会提示重新分析").font(V3.sans(11)).foregroundStyle(V3.fnt)
                if failure != nil || ready?.stale == true {
                    Button("重新分析") { Task { await analyze() } }.buttonStyle(.plain).font(V3.sans(11, weight: .medium)).foregroundStyle(V3.link).disabled(matchLoading || analyzing)
                }
            }.padding(.top, 14)
        }
    }

    /// 匹配结果还没到：已覆盖 / 还缺两行的位置先放骨架，结果到了不跳动。
    private var matchPlaceholders: some View {
        VStack(alignment: .leading, spacing: 6) {
            V3Skeleton(height: 11, radius: 3).frame(width: 260 * 0.74, height: 20, alignment: .leading)
            V3Skeleton(height: 11, radius: 3).frame(width: 260 * 0.56, height: 20, alignment: .leading)
        }.padding(.top, 10).accessibilityHidden(true)
    }

    /// 简历还在读、岗位已有描述：分数卡先按最终形状占位（Web 同一状态），按钮不可点。
    private var readingResumes: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("—").font(V3.serif(46)).foregroundStyle(V3.txt).frame(height: 57).padding(.top, 13)
            Capsule().fill(V3.field).frame(width: 260, height: 6).padding(.top, 2).accessibilityHidden(true)
            Text("正在读取简历…").font(V3.serif(16)).foregroundStyle(V3.txt).padding(.top, 17)
            matchPlaceholders
            Button {} label: {
                HStack(spacing: 6) { Image(systemName: "pencil.line").font(.system(size: 12)); Text("按 JD 优化这份简历") }.frame(maxWidth: .infinity)
            }.buttonStyle(CareerRailButtonStyle()).disabled(true).padding(.top, 18)
            Text("简历或岗位描述改动后，会提示重新分析").font(V3.sans(11)).foregroundStyle(V3.fnt).padding(.top, 14)
        }
    }

    /// 已覆盖 / 还缺各用一行文字列出（最多 6 项，多了写「等 N 项」）。
    private func matchLine(_ label: String, _ words: [String]) -> some View {
        let shown = words.prefix(6).joined(separator: "、") + (words.count > 6 ? " 等 \(words.count) 项" : "")
        return (Text(label + "　").foregroundColor(V3.fnt) + Text(shown).foregroundColor(V3.sub))
            .font(V3.sans(12.5)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
    }

    private func company(_ job: JSONValue) -> some View {
        let facts: [(String, String)] = [("行业", job.text("company_industry")), ("规模", job.text("company_size")), ("融资阶段", job.text("company_financing_stage")),
                                         ("招聘者", [job.text("recruiter_name"), job.text("recruiter_title")].filter { !$0.isEmpty }.joined(separator: " · "))]
        let shown = facts.filter { !$0.1.isEmpty }
        let missing = [("行业", job.text("company_industry")), ("规模", job.text("company_size")), ("招聘者", facts[3].1)].filter { $0.1.isEmpty }.map(\.0)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(String(job.text("company_name").prefix(1))).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.sub)
                    .frame(width: 32, height: 32).background(V3.field, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.text("company_name")).font(V3.sans(13.5, weight: .medium)).lineLimit(1)
                    Text(job.text("company_legal_name").nonEmptyValue ?? "公司全称未填写").font(V3.sans(11)).foregroundStyle(V3.fnt).lineLimit(1)
                }
            }
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(shown, id: \.0) { item in
                        (Text(item.0 + "　").foregroundColor(V3.fnt) + Text(item.1).foregroundColor(V3.sub)).font(V3.sans(12.5))
                    }
                }
            }
            if !job.text("company_description").isEmpty {
                Text(job.text("company_description")).font(V3.sans(12.5)).foregroundStyle(V3.sub).lineSpacing(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !missing.isEmpty { CareerAddChip(title: "补充" + missing.joined(separator: "、")) { editing = true }.disabled(busy) }
        }
    }

    private func notes(_ job: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("个人备注").font(V3.sans(12)).foregroundStyle(V3.sub)
                Spacer()
                if !editingNotes {
                    Button { notesDraft = job.text("notes"); editingNotes = true } label: { Image(systemName: "pencil").font(.system(size: 11)).frame(width: 18, height: 18).contentShape(Rectangle()) }
                        .buttonStyle(.plain).foregroundStyle(V3.sub).disabled(busy).accessibilityLabel("编辑备注")
                }
            }.frame(height: 14)
            if editingNotes {
                TextEditor(text: $notesDraft).font(V3.sans(13.5)).scrollContentBackground(.hidden).frame(minHeight: 96)
                    .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(V3.cl))
                HStack(spacing: 8) {
                    Spacer()
                    Button("取消") { editingNotes = false }.buttonStyle(V3ButtonStyle(kind: .text)).disabled(busy).keyboardShortcut(.cancelAction)
                    Button(busy ? "保存中…" : "保存") { Task { await save(["notes": notesDraft]) { editingNotes = false } } }.buttonStyle(V3ButtonStyle(kind: .ghost)).disabled(busy)
                }
            } else if job.text("notes").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("添加备注，比如内推人、投递时间").font(V3.sans(13.5)).foregroundStyle(V3.fnt)
                    .onTapGesture { notesDraft = ""; editingNotes = true }
            } else {
                Text(job.text("notes")).font(V3.sans(13.5)).foregroundStyle(V3.txt).lineSpacing(5).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(V3.sans(11.5)).foregroundStyle(V3.fnt)
            Text(value.nonEmptyOr("未填写")).font(V3.sans(13)).foregroundStyle(value.isEmpty ? V3.fnt : V3.txt)
        }
    }

    private func label(_ options: [(String, String)], _ value: String) -> String { options.first { $0.0 == value }?.1 ?? value }

    // MARK: - Actions

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await api.careerRequest(path: "/api/job-descriptions/\(jobID)", method: "GET", query: [:], body: nil)
            job = result["job_description"]
            if let id = application?.text("id"), !id.isEmpty,
               let latest = try? await api.careerRequest(path: "/api/job-applications/\(id)", method: "GET", query: [:], body: nil) {
                app = latest["application"] ?? latest["job_application"] ?? app
            }
            await loadResumes()
        } catch is CancellationError {
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            self.error = JobDescriptionFields.errorMessage(error, fallback: "岗位服务暂时不可用，请稍后重试。")
        }
    }

    private func loadResumes() async {
        guard let result = try? await api.careerRequest(path: "/api/resumes", method: "GET", query: [:], body: nil) else { resumesLoaded = true; return }
        let data = (try? JSONEncoder().encode(result["resumes"] ?? .array([]))) ?? Data("[]".utf8)
        resumes = (try? JSONDecoder().decode([ResumeSummary].self, from: data)) ?? []
        defaultResumeID = result["default_resume_id"]?.stringValue
        resumesLoaded = true
    }

    private func loadMatch() async {
        match = nil; matchError = nil; analyzing = false
        guard !resumeID.isEmpty, hasDescription else { return }
        let scope = matchScope
        matchLoading = true
        defer { if scope == matchScope { matchLoading = false } }
        do {
            let result = try await api.careerRequest(path: "/api/job-descriptions/\(jobID)/match", method: "GET", query: ["resume_id": resumeID], body: nil)
            guard scope == matchScope else { return }
            match = JobMatch(result["match"])
            if match?.pending == true { matchLoading = false; await poll(scope) }
        } catch is CancellationError {
        } catch { if scope == matchScope { matchError = JobMatch.errorMessage(nil) } }
    }

    private func analyze() async {
        guard !resumeID.isEmpty, hasDescription, !analyzing else { return }
        let scope = matchScope
        matchError = nil; analyzing = true
        do {
            let result = try await api.careerRequest(path: "/api/job-descriptions/\(jobID)/match:analyze", method: "POST", query: [:],
                                                     body: .object(["resume_id": .string(resumeID)]))
            guard scope == matchScope else { return }
            match = JobMatch(result["match"]); analyzing = false
            if match?.pending == true { await poll(scope) }
        } catch is CancellationError {
        } catch {
            guard scope == matchScope else { return }
            if case APIError.server(_, "JOB_MATCH_IN_PROGRESS") = error { await poll(scope); return }
            analyzing = false
            if case APIError.server(_, let code) = error { matchError = JobMatch.errorMessage(code) } else { matchError = JobMatch.errorMessage(nil) }
        }
    }

    private func poll(_ scope: String) async {
        analyzing = true
        defer { if scope == matchScope { analyzing = false } }
        for _ in 0..<JobMatch.pollLimit {
            do { try await Task.sleep(for: JobMatch.pollInterval) } catch { return }
            guard scope == matchScope else { return }
            guard let result = try? await api.careerRequest(path: "/api/job-descriptions/\(jobID)/match", method: "GET", query: ["resume_id": resumeID], body: nil) else { return }
            guard scope == matchScope else { return }
            match = JobMatch(result["match"])
            if match?.pending != true { return }
        }
    }

    private func linkResume(_ resume: ResumeSummary) async {
        guard let current, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let result = try await api.careerRequest(path: "/api/job-applications/\(current.text("id"))", method: "PUT", query: [:],
                body: .object(["resume_id": .string(resume.id), "base_lock_version": .number(Double(current["lock_version"]?.integer ?? 1))]))
            app = result["application"] ?? result["job_application"]
            notice = "已关联「\(resume.title)」"
            if app == nil { reload = UUID() }
        } catch { notice = CareerErrors.message(error).replacingOccurrences(of: "操作失败", with: "关联简历失败") }
    }

    private func save(_ changes: [String: String], then: () -> Void) async {
        guard let job, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await api.careerRequest(path: "/api/job-descriptions/\(jobID)", method: "PUT", query: [:],
                                                     body: JobDescriptionFields.payload(record: job, changes: changes))
            self.job = result["job_description"] ?? job
            then()
        } catch { self.error = JobDescriptionFields.errorMessage(error, fallback: "保存岗位失败，请稍后重试。") }
    }

    private func deleteJob() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            _ = try await api.careerRequest(path: "/api/job-descriptions/\(jobID)", method: "DELETE", query: [:], body: nil)
            deleted()
        } catch { self.error = JobDescriptionFields.errorMessage(error, fallback: "删除岗位失败，请稍后重试。") }
    }
}

/// 虚线「+ 补充…」小胶囊：没填的信息合成一个入口，点开编辑。
struct CareerAddChip: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                Text(title).font(V3.sans(11.5))
            }
            .foregroundStyle(hover ? V3.txt : V3.sub).padding(.horizontal, 10).frame(height: 21)
            .overlay(Capsule().stroke(V3.sk2, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Capsule())
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}

/// 右栏里的白底细边胶囊按钮（「按 JD 优化这份简历」）。
struct CareerRailButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.txt)
            .frame(height: 33)
            .background(configuration.isPressed ? V3.field : .white, in: Capsule())
            .overlay(Capsule().stroke(V3.cl))
            .opacity(enabled ? 1 : 0.45).contentShape(Capsule())
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    /// 每行靠右排（`justify-content: flex-end`）。
    var trailing = false
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var current: [Int] = [], x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.isEmpty && x + size.width > width {
                rows.append((current, y, x - spacing, height)); y += height + spacing
                current = []; x = 0; height = 0
            }
            current.append(index); x += size.width + spacing; height = max(height, size.height)
        }
        if !current.isEmpty { rows.append((current, y, x - spacing, height)) }
        return rows
    }
}

/// 完整岗位字段编辑（Web 详情页的逐项编辑合并为一张表单）；PUT 提交完整字段与 base_lock_version。
private struct JobFieldsSheet: View {
    @Environment(SessionStore.self) private var session
    let job: JSONValue
    let close: () -> Void
    let saved: (JSONValue) -> Void
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var error: String?

    private func binding(_ key: String) -> Binding<String> { Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("编辑岗位").font(LibraryTypography.serif(20)).padding(24)
            Form {
                Section("岗位") {
                    TextField("职位名称（必填）", text: binding("job_title"))
                    TextField("公司名称（必填）", text: binding("company_name"))
                    picker("求职分类", "employment_type", JobDescriptionFields.employment)
                    TextField("工作地点", text: binding("work_city"))
                    picker("工作方式", "work_mode", JobDescriptionFields.workMode)
                    TextField("学历要求", text: binding("education_requirement"))
                    TextField("经验要求", text: binding("experience_requirement"))
                    TextField("工作安排", text: binding("work_schedule"))
                    TextField("详细地址", text: binding("work_address"))
                }
                Section("薪资") {
                    TextField("薪资原文（页头显示）", text: binding("salary_text"))
                    HStack {
                        TextField("最低", text: binding("salary_min"))
                        TextField("最高", text: binding("salary_max"))
                        TextField("币种", text: binding("salary_currency")).frame(width: 90)
                    }
                    picker("计薪周期", "salary_period", JobDescriptionFields.salaryPeriod)
                    TextField("年薪月数", text: binding("salary_months_per_year"))
                }
                Section("岗位描述（支持 Markdown，## 开头是小标题）") {
                    TextEditor(text: binding("description")).font(LibraryTypography.sans(13)).frame(minHeight: 180)
                    TextField("核心技能（用逗号分隔）", text: binding("skills"))
                }
                Section("公司") {
                    TextField("公司全称", text: binding("company_legal_name"))
                    TextField("公司 Logo URL", text: binding("logo_url"))
                    TextField("行业", text: binding("company_industry"))
                    TextField("公司规模", text: binding("company_size"))
                    TextField("融资阶段", text: binding("company_financing_stage"))
                    TextField("招聘者姓名", text: binding("recruiter_name"))
                    TextField("招聘者职位", text: binding("recruiter_title"))
                    TextEditor(text: binding("company_description")).font(LibraryTypography.sans(13)).frame(minHeight: 80)
                }
            }.formStyle(.grouped)
            if let error { Text(error).font(LibraryTypography.sans(12.5)).foregroundStyle(CareerPalette.red).padding(.horizontal, 24) }
            HStack {
                Spacer()
                Button("取消", action: close).buttonStyle(CareerActionStyle()).disabled(busy).keyboardShortcut(.cancelAction)
                Button(busy ? "保存中…" : "保存", action: submit).buttonStyle(CareerActionStyle(kind: .primary)).disabled(busy)
            }.padding(24)
        }.frame(width: 640, height: 720)
            .onAppear {
                var initial: [String: String] = [:]
                for key in ["job_title", "company_name", "description"] + JobDescriptionFields.optionalText { initial[key] = job.text(key) }
                initial["skills"] = (job["skills"]?.items ?? []).compactMap(\.stringValue).joined(separator: ", ")
                initial["salary_months_per_year"] = job["salary_months_per_year"]?.numberValue.map { String(Int($0)) } ?? ""
                values = initial
            }
    }

    private func picker(_ title: String, _ key: String, _ options: [(String, String)]) -> some View {
        Picker(title, selection: binding(key)) {
            Text("未填写").tag("")
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
    }

    private func submit() {
        guard !busy else { return }
        guard !(values["job_title"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
              !(values["company_name"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { error = "职位名称和公司名称为必填项。"; return }
        if let months = values["salary_months_per_year"], !months.trimmingCharacters(in: .whitespaces).isEmpty, Int(months.trimmingCharacters(in: .whitespaces)) == nil {
            error = "年薪月数需要填写整数。"; return
        }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await session.api.careerRequest(path: "/api/job-descriptions/\(job.text("id"))", method: "PUT", query: [:],
                                                                 body: JobDescriptionFields.payload(record: job, changes: values))
                saved(result["job_description"] ?? job)
            } catch { self.error = JobDescriptionFields.errorMessage(error, fallback: "保存岗位失败，请稍后重试。") }
        }
    }
}
