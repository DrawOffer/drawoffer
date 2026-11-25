import AppKit
import DrawOfferCore
import SwiftUI

/// 对话里点开的岗位、投递和模拟面试（Web `features/assistant/ObjectPreview.tsx`，Figma 02B·09 · 02.10a/b/c）：
/// 顶行状态标签 + 来源 + 唯一主按钮，下面是衬线标题、一行要点和分区信息。
struct ChatObjectPreview: View {
    let tab: ChatPreviewTab
    let onMissing: () -> Void

    var body: some View {
        switch tab.kind {
        case .poolJob: PoolJobPreview(tab: tab, onMissing: onMissing)
        case .job: JobPreview(tab: tab, onMissing: onMissing)
        case .application: ApplicationPreview(tab: tab, onMissing: onMissing)
        case .mockInterview: MockPreview(tab: tab, onMissing: onMissing)
        default: EmptyView()
        }
    }
}

// MARK: - 加载

/// 取数 + 加载 / 不可用 / 失败状态（与简历、资料标签同一套 `PreviewStateView`）。
private struct ObjectLoad<Value, Content: View>: View {
    @Environment(SessionStore.self) private var session
    let missingTitle: String
    let missingDetail: String
    let onMissing: () -> Void
    let load: @MainActor (any APIClient) async throws -> Value
    @ViewBuilder let content: (Value) -> Content
    @State private var value: Value?
    @State private var state = PreviewLoad.loading

    var body: some View {
        Group {
            if let value, state == .ready {
                ScrollView { content(value).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                PreviewStateView(state: state, missingTitle: missingTitle, missingDetail: missingDetail)
            }
        }
        .task {
            state = .loading
            do {
                value = try await load(session.api)
                state = .ready
            } catch is CancellationError {
            } catch {
                if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
                state = previewMissing(error) ? .missing : .failed
                if state == .missing { onMissing() }
            }
        }
    }
}

// MARK: - 时间

private enum ObjTime {
    static func parts(_ iso: String, zone: String = Beijing.identifier) -> (month: Int, day: Int, time: String, weekday: String)? {
        guard let date = CareerApplication.date(iso) else { return nil }
        var calendar = Beijing.calendar
        if let timeZone = TimeZone(identifier: zone) { calendar.timeZone = timeZone }
        let c = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: date)
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        return (c.month ?? 0, c.day ?? 0, String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0), "周" + names[max(0, min(6, (c.weekday ?? 1) - 1))])
    }
    static func monthDay(_ iso: String) -> String? { parts(iso).map { "\($0.month)-\($0.day)" } }
    static func fullDay(_ iso: String) -> String? { parts(iso).map { "\($0.month) 月 \($0.day) 日" } }
    /// 两个时间相差的自然日（中国时间），`from` 到现在。
    static func daysSince(_ iso: String) -> Int? {
        CareerApplication.date(iso).map { Beijing.calendar.dateComponents([.day], from: Beijing.calendar.startOfDay(for: $0), to: Beijing.calendar.startOfDay(for: Date())).day ?? 0 }
    }
    static func until(_ iso: String) -> String {
        let days = -(daysSince(iso) ?? 0)
        return days <= 0 ? "今天" : days == 1 ? "明天" : "\(days) 天后"
    }
}

// MARK: - 共用版式

private enum ObjTone {
    case green, blue, orange, gray
    var background: Color { [ObjTone.green: Color(hex: 0xEAF5EE), .blue: V3.blueSoft, .orange: Color(hex: 0xFBF0E4), .gray: V3.field][self] ?? V3.field }
    var foreground: Color { [ObjTone.green: V3.green, .blue: V3.blue, .orange: Color(hex: 0xC9731F), .gray: V3.sub][self] ?? V3.sub }
}

private let objMuted = Color(hex: 0x8A8A84)

private struct ObjSheet<Action: View, Meta: View, Sections: View>: View {
    var chip: String?
    var tone: ObjTone = .gray
    var source: String?
    var notice: String?
    let title: String
    let action: Action
    let meta: Meta
    let sections: Sections

    init(chip: String? = nil, tone: ObjTone = .gray, source: String? = nil, notice: String? = nil, title: String,
         @ViewBuilder action: () -> Action, @ViewBuilder meta: () -> Meta, @ViewBuilder sections: () -> Sections) {
        self.chip = chip; self.tone = tone; self.source = source; self.notice = notice; self.title = title
        self.action = action(); self.meta = meta(); self.sections = sections()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let chip, !chip.isEmpty {
                    HStack(spacing: 6) {
                        if tone == .green { Circle().fill(tone.foreground).frame(width: 6, height: 6) }
                        Text(chip).font(V3.sans(12.5, weight: .medium)).foregroundStyle(tone.foreground).lineLimit(1)
                    }.padding(.horizontal, 11).frame(height: 23).background(tone.background, in: Capsule()).fixedSize()
                }
                if let source, !source.isEmpty { Text(source).font(V3.sans(13)).foregroundStyle(objMuted).lineLimit(1) }
                Spacer(minLength: 8)
                action
            }.frame(minHeight: 29)
            if let notice { Text(notice).font(V3.sans(12)).foregroundStyle(V3.sub).padding(.top, 8) }
            Text(title).font(V3.serif(26)).fontWeight(.semibold).foregroundStyle(V3.txt).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 22)
            meta.padding(.top, 8)
            sections
        }.padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 40)
    }
}

private extension ObjSheet where Action == EmptyView {
    init(chip: String? = nil, tone: ObjTone = .gray, source: String? = nil, title: String, @ViewBuilder meta: () -> Meta, @ViewBuilder sections: () -> Sections) {
        self.init(chip: chip, tone: tone, source: source, title: title, action: { EmptyView() }, meta: meta, sections: sections)
    }
}

private struct ObjButton: View {
    let label: String
    var dark = true
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(busy ? "处理中…" : label).font(V3.sans(12.5, weight: .medium)).foregroundStyle(dark ? Color.white : V3.txt)
                .padding(.horizontal, 16).frame(height: 29)
                .background(dark ? V3.txt : Color.white, in: Capsule()).overlay(Capsule().stroke(dark ? Color.clear : V3.cl))
                .contentShape(Capsule())
        }.buttonStyle(.plain).disabled(busy)
    }
}

/// 公司标志位：首字方块（与对象卡一致）。
private struct ObjMeta: View {
    var company: String?
    var logo: String = ""
    var parts: [String?]
    var body: some View {
        let rest = parts.compactMap { $0 }.filter { !$0.isEmpty }
        FlowLayout(spacing: 8) {
            if let company, !company.isEmpty {
                PoolLogo(name: company, url: logo, size: 20)
                Text(company).font(V3.sans(13.5)).foregroundStyle(V3.txt)
            }
            if !rest.isEmpty { Text(rest.joined(separator: " · ")).font(V3.sans(13)).foregroundStyle(objMuted) }
        }
    }
}

private struct ObjSection<Content: View>: View {
    let title: String
    var aside: String?
    let content: Content
    init(title: String, aside: String? = nil, @ViewBuilder content: () -> Content) { self.title = title; self.aside = aside; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(V3.sans(16, weight: .medium)).foregroundStyle(V3.txt)
                Spacer(minLength: 12)
                if let aside, !aside.isEmpty { Text(aside).font(V3.sans(12.5)).foregroundStyle(objMuted) }
            }
            content
        }.padding(.top, 32).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private typealias ObjRow = (String, String?)

private struct ObjDivided<Content: View>: View {
    let last: Bool
    let content: Content
    init(last: Bool, @ViewBuilder content: () -> Content) { self.last = last; self.content = content() }
    var body: some View {
        content.padding(.vertical, 8).overlay(alignment: .bottom) { if !last { Rectangle().fill(V3.line).frame(height: 1) } }
    }
}

/// 两列键值表：岗位信息、这场面试。
private struct ObjGrid: View {
    let rows: [ObjRow]
    var body: some View {
        let items: [(String, String)] = rows.compactMap { row in
            guard let value = row.1, !value.isEmpty else { return nil }
            return (row.0, value)
        }
        let lines = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                ObjDivided(last: index == lines.count - 1) {
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(0..<2, id: \.self) { column in
                            if column < line.count { cell(line[column]) } else { Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                }
            }
        }
    }
    private func cell(_ item: (String, String)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.0).font(V3.sans(13)).foregroundStyle(objMuted).frame(width: 52, alignment: .leading)
            Text(item.1).font(V3.sans(13.5)).foregroundStyle(V3.txt).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一列键值表：面试安排、投递材料。值可带点击动作或蓝色。
private struct ObjPairs: View {
    struct Item { let label: String; let value: String?; var blue = false; var action: (() -> Void)? = nil }
    let items: [Item]
    var body: some View {
        let shown = items.filter { !($0.value ?? "").isEmpty }
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                ObjDivided(last: index == shown.count - 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(item.label).font(V3.sans(13)).foregroundStyle(objMuted).frame(width: 60, alignment: .leading)
                        if let action = item.action {
                            Button(action: action) { Text(item.value ?? "").font(V3.sans(13.5)).foregroundStyle(V3.txt).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                        } else {
                            Text(item.value ?? "").font(V3.sans(13.5)).foregroundStyle(item.blue ? V3.blue : V3.txt).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

private struct ObjBullets: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(V3.fnt).frame(width: 4, height: 4).padding(.top, 10)
                    Text(item).font(V3.sans(14)).foregroundStyle(V3.sub).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ObjText: View {
    let text: String
    var body: some View { Text(text).font(V3.sans(14)).foregroundStyle(V3.sub).lineSpacing(5).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }
}

// MARK: - 岗位描述拆成「做什么 / 要什么 / 加分项」

private enum ObjDescription {
    static let headings: [(NSRegularExpression, String)] = [
        ("^(岗位职责|工作职责|职位职责|职位描述|岗位描述|工作内容|你将负责|职责描述)", "做什么"),
        ("^(任职要求|岗位要求|职位要求|任职资格|任职条件|我们希望你|招聘要求|基本要求)", "要什么"),
        ("^(加分项|优先条件|加分|优先考虑|有以下经验者优先)", "加分项"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func split(_ text: String) -> [(title: String, items: [String])] {
        var sections: [(title: String, items: [String])] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            line = line.replacingOccurrences(of: #"^\s*(#+\s*|[-*•·]\s*|\d+[.、)）]\s*|[（(]\d+[)）]\s*)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let head = line.hasSuffix(":") || line.hasSuffix("：") ? String(line.dropLast()) : line
            let range = NSRange(head.startIndex..., in: head)
            if line.count <= 16, let heading = headings.first(where: { $0.0.firstMatch(in: head, range: range) != nil }) {
                sections.append((heading.1, [])); continue
            }
            if sections.isEmpty { sections.append(("岗位描述", [])) }
            sections[sections.count - 1].items.append(line)
        }
        return sections.filter { !$0.items.isEmpty }
    }
}

private struct ObjDescriptionSections: View {
    let text: String
    var body: some View {
        ForEach(Array(ObjDescription.split(text).enumerated()), id: \.offset) { _, section in
            ObjSection(title: section.title) { ObjBullets(items: Array(section.items.prefix(12))) }
        }
    }
}

private struct ObjTags: View {
    let label: String
    let items: [String]
    let tone: ObjTone
    var body: some View {
        if !items.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                Text(label).font(V3.sans(12.5)).foregroundStyle(objMuted).frame(width: 52, alignment: .leading).frame(height: 21)
                FlowLayout(spacing: 6) {
                    ForEach(items.prefix(8), id: \.self) { item in
                        Text(item).font(V3.sans(12.5)).foregroundStyle(tone == .green ? Color(hex: 0x2F7A4A) : tone.foreground)
                            .padding(.horizontal, 8).frame(height: 21).background(tone.background, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }.padding(.top, 8)
        }
    }
}

// MARK: - 岗位广场的岗位

private struct PoolJobPreview: View {
    let tab: ChatPreviewTab
    let onMissing: () -> Void
    var body: some View {
        ObjectLoad(missingTitle: "这个岗位已不可用", missingDetail: "它可能已从岗位广场下架。", onMissing: onMissing, load: { api in
            try await api.careerRequest(path: "/api/job-pool/\(tab.id)", method: "GET", query: [:], body: nil)
        }) { job in PoolJobSheet(job: job) }
    }
}

private struct PoolJobSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let job: JSONValue
    @State private var joined: String?
    @State private var busy = false
    @State private var notice: String?

    private static let type: [String: String] = ["campus": "校招", "experienced": "社招", "internship": "实习", "full_time": "全职", "part_time": "兼职", "contract": "合同工"]

    var body: some View {
        let applicationID = joined ?? job.text("joined_application_id").nonEmptyValue
        let active = job.text("availability_status") == "active"
        let cities = (job["locations"]?["cities"]?.items ?? []).compactMap(\.stringValue)
        let city = (cities.isEmpty ? (job["locations"]?["raw"]?.items ?? []).compactMap(\.stringValue) : cities).joined(separator: "、")
        let kind = [job.text("recruitment_channel"), job.text("employment_type")].filter { $0 != "unknown" }.compactMap { Self.type[$0] }.joined(separator: " · ")
        let published = job.text("published_at")
        let company = job["company"]?.text("name") ?? ""
        ObjSheet(chip: active ? "官网在招" : "已下架", tone: active ? .green : .gray,
                 source: (["岗位广场"] + [ObjTime.monthDay(published).map { "\($0) 发布" }].compactMap { $0 }).joined(separator: " · "),
                 notice: notice, title: job.text("title"), action: {
            if let applicationID { ObjButton(label: "查看求职进程", dark: false) { router?.jump(.application(applicationID)) } }
            else if active { ObjButton(label: "加入求职进程", busy: busy) { Task { await join() } } }
        }, meta: { ObjMeta(company: company, logo: job["company"]?.text("logo_url") ?? "", parts: [city, job.text("salary_text")]) }, sections: {
            ObjSection(title: "岗位信息") {
                ObjGrid(rows: [("方向", job.text("category")), ("部门", job.text("department")), ("类型", kind), ("城市", city),
                               ("薪资", job.text("salary_text")), ("发布", ObjTime.fullDay(published))])
            }
            ObjDescriptionSections(text: job.text("description").nonEmptyValue ?? job.text("summary"))
            ObjSection(title: "关于公司") {
                ObjPairs(items: [.init(label: "公司", value: company), .init(label: "来源", value: job["source"]?.text("name")),
                                 .init(label: "岗位编号", value: job.text("source_job_id"))])
            }
        })
    }

    /// 与岗位广场的「加入求职进程」同一个写接口（`POST /api/job-pool/{id}/join`）。
    private func join() async {
        busy = true; defer { busy = false }
        do {
            let result = try await session.api.careerRequest(path: "/api/job-pool/\(job.text("id"))/join", method: "POST", query: [:], body: nil)
            joined = result.text("application_id").nonEmptyValue
            notice = result["created"]?.bool ?? true ? "已加入求职进程" : "这个岗位已经在求职进程里了"
        } catch {
            if case APIError.unauthorized = error { session.reportAuthenticationFailure() }
            notice = "没能加入求职进程，请稍后再试。"
        }
    }
}

// MARK: - 我的岗位（含匹配度）

private struct JobPreview: View {
    let tab: ChatPreviewTab
    let onMissing: () -> Void
    var body: some View {
        ObjectLoad(missingTitle: "这个岗位已不可用", missingDetail: "它可能已被删除。", onMissing: onMissing, load: { api in
            let job = try await api.careerRequest(path: "/api/job-descriptions/\(tab.id)", method: "GET", query: [:], body: nil)["job_description"] ?? .null
            var match: JobMatch?
            if let resumeID = tab.resumeID, !resumeID.isEmpty,
               let result = try? await api.careerRequest(path: "/api/job-descriptions/\(tab.id)/match", method: "GET", query: ["resume_id": resumeID], body: nil) {
                match = JobMatch(result["match"])
            }
            return (job, match)
        }) { loaded in JobSheet(job: loaded.0, match: loaded.1) }
    }
}

private struct JobSheet: View {
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let job: JSONValue
    let match: JobMatch?

    private static let type = ["internship": "实习", "campus": "校招", "full_time": "全职"]
    private static let mode = ["onsite": "坐班", "hybrid": "混合办公", "remote": "远程"]

    var body: some View {
        let ready = match.flatMap { $0.ready && $0.score != nil ? $0 : nil }
        let short = ready?.score.map { "匹配 \($0)" }
        let gap = ready?.gaps.first.map { "差在\($0)" }
        let matchText = [short, gap].compactMap { $0 }.joined(separator: "，")
        let hasCompany = ["company_industry", "company_size", "company_financing_stage", "company_description"].contains { !job.text($0).isEmpty }
        ObjSheet(chip: "我的岗位", tone: .gray, source: job.text("source_site"), title: job.text("job_title"), action: {
            ObjButton(label: "打开岗位") { router?.jump(.job(.init(id: job.text("id")))) }
        }, meta: {
            ObjMeta(company: job.text("company_name"), logo: job.text("resolved_logo_url").nonEmptyValue ?? job.text("logo_url"), parts: [job.text("work_city"), job.text("salary_text"), matchText])
        }, sections: {
            ObjSection(title: "岗位信息") {
                ObjGrid(rows: [("类型", Self.type[job.text("employment_type")]), ("城市", job.text("work_city")), ("薪资", job.text("salary_text")),
                               ("学历", job.text("education_requirement")), ("经验", job.text("experience_requirement")), ("办公", Self.mode[job.text("work_mode")])])
            }
            if let ready {
                let covered = ready.covered.isEmpty ? ready.hits : ready.covered
                let missing = ready.missing.isEmpty ? ready.gaps : ready.missing
                ObjSection(title: "和你的简历", aside: "\(ready.score ?? 0) 分") {
                    VStack(alignment: .leading, spacing: 0) {
                        if let headline = ready.headline { ObjText(text: headline) }
                        ObjTags(label: "已具备", items: covered, tone: .green)
                        ObjTags(label: "还缺", items: missing, tone: .orange)
                    }
                }
            }
            ObjDescriptionSections(text: job.text("description"))
            if hasCompany {
                ObjSection(title: "关于公司") {
                    VStack(alignment: .leading, spacing: 12) {
                        ObjPairs(items: [.init(label: "行业", value: job.text("company_industry")), .init(label: "规模", value: job.text("company_size")),
                                         .init(label: "融资", value: job.text("company_financing_stage"))])
                        if !job.text("company_description").isEmpty { ObjText(text: job.text("company_description")) }
                    }
                }
            }
        })
    }
}

// MARK: - 投递与面试安排

private struct ApplicationPreview: View {
    let tab: ChatPreviewTab
    let onMissing: () -> Void
    var body: some View {
        ObjectLoad(missingTitle: "这条投递已不可用", missingDetail: "它可能已被删除或归档。", onMissing: onMissing, load: { api in
            let result = try await api.careerRequest(path: "/api/job-applications/\(tab.id)", method: "GET", query: [:], body: nil)
            let application = result["application"] ?? result["job_application"] ?? .null
            let page = try? await api.careerRequest(path: "/api/interview-sessions", method: "GET", query: ["application_id": tab.id, "limit": "50"], body: nil)
            return (application, page?["items"]?.items ?? [])
        }) { loaded in ApplicationSheet(application: loaded.0, sessions: loaded.1) }
    }
}

private struct ApplicationSheet: View {
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let application: JSONValue
    let sessions: [JSONValue]

    private static let mode = ["video": "视频面试", "onsite": "现场面试", "phone": "电话面试", "other": "其他"]

    private var ended: Bool { application.text("lifecycle_status") == "terminated" || application.text("status") != "active" }

    private var next: JSONValue? {
        guard !ended else { return nil }
        let now = Date()
        return sessions.filter { $0.text("status") != "cancelled" && (CareerApplication.date($0.text("end_at")).map { $0 >= now } ?? false) }
            .sorted { $0.text("start_at") < $1.text("start_at") }.first
    }

    var body: some View {
        let next = next
        let at = next.flatMap { ObjTime.parts($0.text("start_at"), zone: $0.text("timezone").nonEmptyValue ?? Beijing.identifier) }
        let end = next.flatMap { ObjTime.parts($0.text("end_at"), zone: $0.text("timezone").nonEmptyValue ?? Beijing.identifier) }
        let stageLabel = next?.text("stage_label") ?? ""
        let applied = application.text("applied_at")
        let stages = (application["stages"]?.items ?? []).filter { $0.text("stage_status") != "cancelled" }.sorted { ($0["sequence_no"]?.numberValue ?? 0) < ($1["sequence_no"]?.numberValue ?? 0) }
        let reviewed = sessions.filter { $0.text("status") == "completed" && !$0.text("review_summary").isEmpty }.sorted { $0.text("start_at") > $1.text("start_at") }.first
        let minutes = reviewed.flatMap { r in CareerApplication.date(r.text("start_at")).flatMap { s in CareerApplication.date(r.text("end_at")).map { Int($0.timeIntervalSince(s) / 60) } } } ?? 0
        let meeting = next?.text("meeting_url") ?? ""
        let isLink = meeting.lowercased().hasPrefix("http://") || meeting.lowercased().hasPrefix("https://")
        let chip = ended ? "已结束" : next.map { "\(stageLabel) · \(ObjTime.until($0.text("start_at")))" } ?? application.text("current_stage_label")
        ObjSheet(chip: chip, tone: ended ? .gray : .blue,
                 source: (["求职记录"] + [ObjTime.daysSince(applied).map { "投递 \($0) 天" }].compactMap { $0 }).joined(separator: " · "),
                 title: next != nil && at != nil ? "\(at!.weekday) \(at!.time)，\(stageLabel)。" : application.text("job_title_snapshot"), action: {
            if !ended { ObjButton(label: "模拟这场面试") { router?.jump(.mockFor(application: application.text("id"))) } }
        }, meta: {
            ObjMeta(company: application.text("company_name_snapshot"), logo: application.text("company_logo_url"), parts: [application.text("job_title_snapshot"), next.map { Self.mode[$0.text("mode")] ?? "" } ?? application.text("current_stage_label")])
        }, sections: {
            if let next, let at, let end {
                ObjSection(title: "\(stageLabel)安排") {
                    ObjPairs(items: [
                        .init(label: "时间", value: "\(ObjTime.fullDay(next.text("start_at")) ?? "") \(at.weekday) \(at.time)–\(end.time)"),
                        .init(label: "形式", value: Self.mode[next.text("mode")]),
                        .init(label: isLink ? "会议链接" : "会议号", value: meeting, blue: true,
                              action: isLink ? { if let url = URL(string: meeting) { NSWorkspace.shared.open(url) } } : nil),
                        .init(label: "地点", value: next.text("location")),
                        .init(label: "面试官", value: [next.text("interviewer_name"), next.text("interviewer_title")].filter { !$0.isEmpty }.joined(separator: " · ")),
                        .init(label: "备注", value: next.text("preparation_note")),
                    ])
                }
            }
            if !stages.isEmpty {
                ObjSection(title: "进度", aside: ObjTime.daysSince(applied).map { "从投递到现在 \($0) 天" }) { ObjTimeline(stages: stages, ended: ended) }
            }
            if let reviewed {
                let lines = reviewed.text("review_summary").components(separatedBy: CharacterSet(charactersIn: "\n。"))
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*•· 0123456789.、\t")) }.filter { !$0.isEmpty }
                ObjSection(title: "\(reviewed.text("stage_label"))回顾",
                           aside: [ObjTime.fullDay(reviewed.text("start_at")), minutes > 0 ? "\(minutes) 分钟" : nil].compactMap { $0 }.joined(separator: " · ")) {
                    ObjBullets(items: Array(lines.prefix(6)))
                }
            }
            ObjSection(title: "投递材料") {
                ObjPairs(items: [
                    .init(label: "简历", value: application.text("resume_title_snapshot")),
                    .init(label: "渠道", value: [application.text("applied_channel"), ObjTime.fullDay(applied) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")),
                    .init(label: "岗位", value: application.text("job_title_snapshot"), action: application.text("job_description_id").isEmpty ? nil : { router?.jump(.job(.init(id: application.text("job_description_id"), applicationID: application.text("id")))) }),
                ])
            }
        })
    }
}

/// 进度：一条横线串起各阶段，当前一步蓝色空心圈，还没到的灰色。
private struct ObjTimeline: View {
    let stages: [JSONValue]
    let ended: Bool

    private struct Step { let id: String; let label: String; let date: String?; let state: String }

    private var steps: [Step] {
        var result = stages.enumerated().map { index, stage in
            Step(id: "\(index)", label: stage.text("stage_label"), date: ObjTime.monthDay(stage.text("entered_at")),
                 state: stage["current_marker"] != nil && stage["current_marker"] != .null && !ended ? "current" : "done")
        }
        if !stages.contains(where: { $0.text("stage_type") == "offer" }) && !ended { result.append(Step(id: "offer", label: "Offer", date: nil, state: "next")) }
        return result
    }

    var body: some View {
        let steps = steps
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 0) {
                    Text(step.label).font(V3.sans(13, weight: step.state == "current" ? .medium : .regular))
                        .foregroundStyle(step.state == "current" ? V3.blue : step.state == "next" ? V3.fnt : V3.txt).lineLimit(1)
                    if let date = step.date { Text(date).font(V3.sans(11)).foregroundStyle(V3.fnt) }
                }.padding(.top, 18).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            if index < steps.count - 1 {
                                Rectangle().fill(step.state == "done" ? V3.txt : V3.cl).frame(height: 1).padding(.top, 4)
                            }
                            switch step.state {
                            case "current": Circle().fill(.white).overlay(Circle().stroke(V3.blue, lineWidth: 1.5)).frame(width: 11, height: 11).offset(x: -2, y: -1)
                            case "next": Circle().fill(.white).overlay(Circle().stroke(V3.fnt2)).frame(width: 7, height: 7).offset(y: 1)
                            default: Circle().fill(V3.txt).frame(width: 7, height: 7).offset(y: 1)
                            }
                        }
                    }
            }
        }
    }
}

// MARK: - 模拟面试报告

private struct MockPreview: View {
    let tab: ChatPreviewTab
    let onMissing: () -> Void
    var body: some View {
        ObjectLoad(missingTitle: "这场模拟面试已不可用", missingDetail: "它可能已被删除。", onMissing: onMissing, load: { api in
            let detail = try await api.careerRequest(path: "/api/mock-interviews/\(tab.id)", method: "GET", query: [:], body: nil)["mock_interview"] ?? .null
            let context = try? await api.careerRequest(path: "/api/mock-interviews/review-context", method: "GET", query: ["kind": "mock", "id": tab.id], body: nil)
            return (detail, context)
        }) { loaded in MockSheet(detail: loaded.0, context: loaded.1) }
    }
}

private struct MockSheet: View {
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let detail: JSONValue
    let context: JSONValue?
    @State private var allQuestions = false

    var body: some View {
        let stage = detail.text("stage_label").nonEmptyValue ?? MockMap.typeName(detail)
        let title = [detail.text("company_name").nonEmptyValue ?? "通用练习", stage].joined(separator: " ")
        if let view = MockRV.view(detail, context: context) {
            report(view, title: title)
        } else {
            ObjSheet(chip: "还没有报告", tone: .gray, source: "模拟面试", title: title, meta: { EmptyView() }, sections: {
                ObjText(text: "这场还在进行或评估中，完成后这里会显示得分和逐题情况。").padding(.top, 24)
            })
        }
    }

    @ViewBuilder private func report(_ view: MockRV.View, title: String) -> some View {
        let report = detail["report"] ?? .null
        let stats = MockMap.stats(detail)
        let weak = MockRV.suggestions(view.questions)
        let level = report["verdict"]?.text("level") ?? ""
        let tone: ObjTone = ["likely_pass", "meets"].contains(level) ? .blue : ["promising", "borderline"].contains(level) ? .orange : .gray
        let score = view.score ?? Int((report["total_score"]?.numberValue ?? 0).rounded())
        let role = detail.text("job_title").nonEmptyValue ?? detail.text("target_role").nonEmptyValue
        let type = MockMap.typeName(detail)
        let shown = allQuestions ? view.questions : Array(view.questions.prefix(5))
        let improvements = (report["improvements"]?.items ?? []).compactMap(\.stringValue)
        let gaps = improvements.isEmpty ? weak.map(MockRV.advice) : improvements
        let abilities = Array(view.abilities.prefix(6))
        let finished = detail.text("finished_at").nonEmptyValue ?? detail.text("created_at")
        ObjSheet(chip: ["\(score) 分", MockRV.verdictName[level]].compactMap { $0 }.joined(separator: " · "), tone: tone,
                 source: ["模拟面试", ObjTime.monthDay(finished)].compactMap { $0 }.joined(separator: " · "), title: title, action: {
            // Web `startPractice`：带着没答好的题、原来的面试类型、难度、作答方式和简历进面试设置。
            if !weak.isEmpty {
                ObjButton(label: "练没答好的 \(weak.count) 处") {
                    router?.jump(.mockPractice(MockPracticePlan(back: title, items: weak.map(MockRV.practiceItem),
                                                                applicationID: detail.display("job_application_id").nonEmptyValue,
                                                                interviewType: detail.text("interview_type").nonEmptyValue, difficulty: detail.text("difficulty").nonEmptyValue,
                                                                mode: detail.text("answer_mode").nonEmptyValue, resumeID: detail.display("resume_id").nonEmptyValue)))
                }
            }
        }, meta: {
            ObjMeta(parts: [role, type, view.compare])
        }, sections: {
            ObjSection(title: "这场面试") {
                ObjGrid(rows: [
                    ("时长", stats.minutes.map { "\($0) 分钟" }),
                    ("题数", ["\(stats.rounds.count) 题", stats.follows > 0 ? "追问 \(stats.follows) 次" : nil].compactMap { $0 }.joined(separator: " · ")),
                    ("岗位", [detail.text("company_name"), role ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")),
                    ("轮次", [detail.text("stage_label"), type].filter { !$0.isEmpty }.joined(separator: " · ")),
                ])
            }
            if abilities.count >= 3 {
                ObjSection(title: "各项得分") {
                    HStack(alignment: .center, spacing: 16) {
                        ObjRadar(abilities: abilities)
                        VStack(alignment: .leading, spacing: 8) {
                            legend(dashed: false, "这一场 \(score)")
                            if abilities.allSatisfy({ $0.past != nil }) { legend(dashed: true, "以往平均") }
                            let low = abilities.filter { $0.score < 60 }.map(\.label)
                            if !low.isEmpty { Text("\(low.joined(separator: "、"))偏弱").font(V3.sans(12)).foregroundStyle(V3.fnt).padding(.top, 4) }
                        }.font(V3.sans(12)).foregroundStyle(V3.sub)
                    }
                }
            }
            if !view.questions.isEmpty {
                ObjSection(title: "逐题") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, question in
                            ObjDivided(last: index == shown.count - 1) {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(String(format: "%02d", question.no)).font(V3.number(12, weight: .regular)).foregroundStyle(V3.fnt)
                                    Text(question.title).font(V3.sans(14)).foregroundStyle(V3.txt).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    if question.weak { Text(MockRV.outcomeText(question)).font(V3.sans(12)).foregroundStyle(V3.orange) }
                                    if let score = question.score {
                                        Text("\(score)").font(V3.serif(16)).foregroundStyle(question.weak ? V3.orange : V3.txt).frame(minWidth: 24, alignment: .trailing)
                                    }
                                }
                            }
                        }
                        if view.questions.count > shown.count {
                            Button { allQuestions = true } label: { Text("还有 \(view.questions.count - shown.count) 题").font(V3.sans(12)).foregroundStyle(V3.fnt) }
                                .buttonStyle(.plain).padding(.top, 4)
                        }
                    }
                }
            }
            if !gaps.isEmpty { ObjSection(title: "还差在哪") { ObjBullets(items: Array(gaps.prefix(5))) } }
        })
    }

    private func legend(dashed: Bool, _ text: String) -> some View {
        HStack(spacing: 8) {
            Path { $0.move(to: .zero); $0.addLine(to: CGPoint(x: 16, y: 0)) }
                .stroke(dashed ? V3.fnt : V3.txt, style: StrokeStyle(lineWidth: dashed ? 1 : 1.5, dash: dashed ? [3, 3] : [])).frame(width: 16, height: 2)
            Text(text)
        }
    }
}

/// 各项得分的雷达图：这一场实线浅底，以往平均灰色虚线，弱项（不到 60）标橙。
private struct ObjRadar: View {
    let abilities: [MockRV.Ability]
    private let size = CGSize(width: 250, height: 210)
    private let radius: CGFloat = 66

    private func point(_ index: Int, _ value: Double, scale: CGFloat = 1) -> CGPoint {
        let angle = -Double.pi / 2 + Double(index) * 2 * Double.pi / Double(abilities.count)
        let r = CGFloat(max(0, min(100, value)) / 100) * radius * scale
        return CGPoint(x: size.width / 2 + r * CGFloat(cos(angle)), y: size.height / 2 + r * CGFloat(sin(angle)))
    }

    private func polygon(_ values: [Double]) -> Path {
        Path { path in
            for (index, value) in values.enumerated() { index == 0 ? path.move(to: point(index, value)) : path.addLine(to: point(index, value)) }
            path.closeSubpath()
        }
    }

    var body: some View {
        let count = abilities.count
        let hasPast = abilities.allSatisfy { $0.past != nil }
        ZStack(alignment: .topLeading) {
            ForEach([25.0, 50, 75, 100], id: \.self) { level in
                polygon(Array(repeating: level, count: count)).stroke(V3.line, lineWidth: 1)
            }
            ForEach(0..<count, id: \.self) { index in
                Path { $0.move(to: CGPoint(x: size.width / 2, y: size.height / 2)); $0.addLine(to: point(index, 100)) }.stroke(V3.line, lineWidth: 1)
            }
            if hasPast { polygon(abilities.map { $0.past ?? 0 }).stroke(V3.fnt, style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
            polygon(abilities.map { Double($0.score) }).fill(Color(hex: 0x1D1D1B).opacity(0.06))
            polygon(abilities.map { Double($0.score) }).stroke(V3.txt, lineWidth: 1.5)
            ForEach(Array(abilities.enumerated()), id: \.offset) { index, item in
                Circle().fill(item.score < 60 ? V3.orange : V3.txt).frame(width: 5, height: 5)
                    .position(point(index, Double(item.score)))
            }
            ForEach(Array(abilities.enumerated()), id: \.offset) { index, item in
                let anchor = point(index, 100, scale: 1.3)
                let dx = anchor.x - size.width / 2
                VStack(spacing: 1) {
                    Text(item.label).font(V3.sans(11)).foregroundStyle(V3.sub)
                    Text("\(item.score)").font(V3.sans(11, weight: .medium)).foregroundStyle(item.score < 60 ? V3.orange : V3.txt)
                }.fixedSize().position(x: anchor.x + (abs(dx) < 4 ? 0 : dx > 0 ? 24 : -24), y: anchor.y)
            }
        }.frame(width: size.width, height: size.height)
            .accessibilityElement().accessibilityLabel(abilities.map { "\($0.label) \($0.score)" }.joined(separator: "，"))
    }
}
