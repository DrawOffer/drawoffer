import SwiftUI
import DrawOfferCore

/// 岗位广场 C · 岗位详情（Web `JobView`；macOS 稿 01.09 标准多板块、01.10 含键值规格、01.11 空正文与右栏占位）：
/// 左侧标题、标签与正文（正文区单独滚动），右侧公司、同方向岗位，底部固定「加入求职进程」「去官网投递」与投递截止。
struct JobPoolJob: View {
    @Environment(SessionStore.self) private var session
    @Environment(WorkspaceRouter.self) private var router: WorkspaceRouter?
    let jobID: String
    let root: () -> Void
    let openCompany: (String, JobPoolView.Query) -> Void
    let openJob: (String) -> Void
    let openPlaza: (PoolPlaza) -> Void
    let openApplication: (String) -> Void

    @State private var job: JSONValue?
    @State private var state = "loading"
    @State private var company: JSONValue?
    @State private var companyLoading = true
    @State private var related: [JSONValue] = []
    @State private var relatedLoading = true
    @State private var relatedTotal: Int?
    @State private var relatedTotalLoading = true
    @State private var revision = 0
    @State private var join = PoolJoin()
    /// J2 / J3：求职进程里还没有岗位时说明加入有什么用；加入的是第一个岗位时接一句去练面试。
    @State private var noApplications: Bool?
    /// 点「加入」那一刻求职进程里是不是还没有岗位（加入之后再读就不是了）。
    @State private var firstBeforeJoin = false
    @State private var justJoinedFirst: String?

    private var jobFirst: CoachSlot { CoachSlot(id: "plaza-job-first", user: session.coachUser) }
    private var joinedFirst: CoachSlot { CoachSlot(id: "plaza-joined-first", user: session.coachUser) }

    var body: some View {
        Group {
            switch state {
            case "missing":
                V3Page(top: 38) {
                    VStack(alignment: .leading, spacing: 0) {
                        PoolCrumbs(back: root, current: "岗位不存在")
                        PoolState(title: "没有找到这个岗位", message: "岗位可能已被移除，或链接不完整。", width: 314, stage: 96,
                                  art: { PoolUnavailableArt(tag: "链接已失效") }) {
                            Button("返回岗位广场", action: root).buttonStyle(.plain).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.link)
                        }
                    }
                }
            case "error":
                V3Page(top: 38) {
                    VStack(alignment: .leading, spacing: 0) {
                        PoolCrumbs(back: root, current: "岗位详情")
                        PoolError(title: "岗位详情暂时无法加载", message: "网络不稳定或服务暂时不可用，稍后重试即可。") { revision += 1 }
                    }
                }
            default:
                if let job { detail(job) }
                else { V3Loading("正在加载岗位详情…", retry: { revision += 1 }).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .task(id: revision) { await load() }
        .task(id: jobFirst.open || joinedFirst.open) {
            guard jobFirst.open || joinedFirst.open else { return }
            let list = try? await session.api.careerRequest(path: "/api/job-applications", method: "GET", query: ["scope": "all", "limit": "1"], body: nil)
            noApplications = list.map { ($0["items"]?.items ?? []).isEmpty }
            if noApplications == true { firstBeforeJoin = true }
        }
        .modifier(PoolJoinFeedback(join: join, open: openApplication, retry: { job in Task { await joinJob(job) } }))
        .coachMarkHost()
    }

    private func detail(_ job: JSONValue) -> some View {
        let companyID = job["company"]?.text("id") ?? ""
        let companyName = job["company"]?.text("name") ?? ""
        return GeometryReader { proxy in
            let gutter = V3Page<EmptyView>.gutter(card: proxy.size.width)
            VStack(alignment: .leading, spacing: 0) {
                PoolCrumbs(back: root, trail: [(companyName, { openCompany(companyID, JobPoolView.Query()) })], current: job.text("title"))
                HStack(alignment: .top, spacing: 48) {
                    main(job, companyName: companyName).frame(maxWidth: 680, maxHeight: .infinity, alignment: .topLeading)
                    Spacer(minLength: 0)
                    side(job, companyID: companyID, companyName: companyName).frame(width: 300).frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, gutter).padding(.top, 38).padding(.bottom, 28)
        }
    }

    // MARK: 左栏

    private func main(_ job: JSONValue, companyName: String) -> some View {
        let closed = job.text("availability_status") == "closed"
        let sections = JobPool.body(job)
        return VStack(alignment: .leading, spacing: 0) {
            poolTitle(job).font(.system(size: 28, weight: .regular)).foregroundStyle(V3.txt).lineHeight(28, 40, .system)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 28)
            tags(job, closed: closed).padding(.top, 10)
            if !closed && job.text("availability_status") == "missing" {
                PoolNote(text: "本轮同步未发现该岗位，暂时保留；请到官网确认招聘状态。", icon: true).padding(.top, 16)
            }
            if sections.isEmpty {
                emptyBody(companyName: companyName, source: URL(string: job.text("source_url")))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in bodySection(section) }
                        sourceNote(companyName)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 12).padding(.bottom, 4)
                }
            }
            if sections.isEmpty { sourceNote(companyName) }
        }
    }

    /// 01.09 来源说明紧跟正文；正文为空时留在栏底。
    private func sourceNote(_ companyName: String) -> some View {
        Text("内容同步自\(companyName)招聘官网，投递要求与最新状态以官网为准。").font(V3.sans(12)).foregroundStyle(V3.fnt).padding(.top, 20)
    }

    /// 📍城市 | 招聘类型 | 方向 | 学历 | 今日新增（已下线时写「已从官网下线」）。
    private func tags(_ job: JSONValue, closed: Bool) -> some View {
        let education = job.text("education").nonEmptyValue ?? JobPool.attribute(job, "education_requirement")
        var parts: [AnyView] = [AnyView(HStack(spacing: 3) {
            Image(systemName: "mappin").font(.system(size: 11))
            Text(JobPool.cities(job).joined(separator: "、").nonEmptyValue ?? "地点未标明")
        }.foregroundStyle(V3.txt).fontWeight(.medium))]
        for tag in [JobPool.jobType(job), job.text("category"), education ?? ""] where !tag.isEmpty { parts.append(AnyView(Text(tag))) }
        if closed { parts.append(AnyView(Text("已从官网下线").foregroundStyle(V3.fnt))) }
        else if JobPool.isToday(job.text("new_at")) { parts.append(AnyView(Text("今日新增").foregroundStyle(V3.blue))) }
        return PoolMetaLine(parts: parts).font(V3.sans(14)).foregroundStyle(V3.sub).frame(height: 22)
    }

    private func bodySection(_ section: JobPool.Section) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title).font(.system(size: 15, weight: .medium)).foregroundStyle(V3.txt).frame(height: 22)
            ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let line):
                    paragraph(line).padding(.top, 10)
                case .points(let points):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                            HStack(alignment: .top, spacing: 0) {
                                Text(String(format: "%02d", index + 1)).font(V3.number(12, weight: .regular)).foregroundStyle(V3.fnt2)
                                    .frame(width: 26, alignment: .leading).padding(.top, 4)
                                paragraph(point)
                            }
                        }
                    }.padding(.top, 12)
                case .pairs(let pairs):
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                            HStack(alignment: .firstTextBaseline, spacing: 20) {
                                Text(pair.label).font(V3.sans(13.5)).foregroundStyle(V3.fnt).frame(width: 84, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(pair.value).font(V3.sans(14)).foregroundStyle(V3.txt).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                            }.padding(.vertical, 2)
                        }
                    }.padding(.top, 12)
                }
            }
        }
        .padding(.top, 28)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).font(V3.sans(14)).foregroundStyle(Color(hex: 0x3A3A36)).lineSpacing(7).textSelection(.enabled)
            .frame(minHeight: 24).fixedSize(horizontal: false, vertical: true)
    }

    /// 01.11：官网只填了占位符，正文区居中说明并指去官网。
    private func emptyBody(companyName: String, source: URL?) -> some View {
        VStack(spacing: 0) {
            Text("官网暂未提供岗位正文").font(V3.serif(22)).foregroundStyle(V3.txt).frame(height: 32)
            Text("该岗位在\(companyName)招聘官网仅填写了占位符，暂未公开具体职责与任职要求。部分企业会通过海报图片或附件说明详情，建议前往官网核对最新信息。")
                .font(V3.sans(15)).foregroundStyle(V3.fnt).lineSpacing(25 - 15 * 1.2).multilineTextAlignment(.center)
                .frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            if let source {
                Link(destination: source) { Text("前往\(companyName)招聘官网查看 ↗") }.font(V3.sans(15, weight: .medium)).foregroundStyle(V3.blue).padding(.top, 18)
            }
        }
        .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
    }

    // MARK: 右栏

    private func side(_ job: JSONValue, companyID: String, companyName: String) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    companyBlock(job, companyID: companyID, companyName: companyName)
                    relatedBlock(job)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            actions(job)
        }
        .padding(.top, 30)
    }

    private func companyBlock(_ job: JSONValue, companyID: String, companyName: String) -> some View {
        let facts = [company?.text("industry") ?? "", company?.text("company_size") ?? "", company?.text("financing_stage") ?? ""].filter { !$0.isEmpty }
        let hot = Array(((company?["city_counts"]?.items ?? []).map { $0.text("name") }.nonEmptyArray
                         ?? (company?["cities"]?.items ?? []).compactMap(\.stringValue)).prefix(5))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PoolLogo(name: companyName, url: company?.text("logo_url").nonEmptyValue ?? job["company"]?.text("logo_url") ?? "", size: 36, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(companyName).font(V3.sans(16, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 21)
                    if companyLoading { V3Skeleton(width: 56, height: 10, radius: 3).frame(height: 19) }
                    else if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(V3.sans(12)).foregroundStyle(V3.fnt).lineLimit(1).frame(height: 19) }
                }
            }
            if let description = company?.text("description").nonEmptyValue {
                Text(description).font(V3.sans(12.5)).foregroundStyle(V3.sub).lineSpacing(5).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if companyLoading {
                HStack(spacing: 12) { Text("热招城市").foregroundStyle(V3.fnt); V3Skeleton(width: 132, height: 11, radius: 3) }.font(V3.sans(13)).frame(height: 21)
            } else if !hot.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("热招城市").foregroundStyle(V3.fnt)
                    Text(hot.joined(separator: "、")).foregroundStyle(V3.txt).fixedSize(horizontal: false, vertical: true)
                }.font(V3.sans(13))
            }
            Button { openCompany(companyID, JobPoolView.Query()) } label: { Text("查看\(companyName)全部岗位 ›") }
                .buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.blue).pointingHandCursor()
        }
        .padding(.bottom, 28).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(V3.line).frame(height: 1) }
    }

    /// 同方向岗位：所有公司里同一方向的最新三个；「全部 N 个」带着这个方向回到广场。
    @ViewBuilder private func relatedBlock(_ job: JSONValue) -> some View {
        let category = job.text("category")
        if !category.isEmpty && (relatedLoading || !related.isEmpty) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("同方向岗位").font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt).frame(height: 22)
                    Spacer(minLength: 8)
                    if relatedTotalLoading { V3Skeleton(width: 64, height: 11, radius: 3) }
                    else {
                        Button {
                            var next = PoolPlaza(); next.panel.categories = [category]; openPlaza(next)
                        } label: { Text("全部\(relatedTotal.map { $0 > 0 ? " \(JobPool.grouped($0)) 个" : "" } ?? "") ›") }
                            .buttonStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.blue).pointingHandCursor()
                    }
                }.padding(.top, 24).padding(.bottom, 4)
                if relatedLoading {
                    ForEach([0.78, 0.70, 0.62], id: \.self) { ratio in
                        VStack(alignment: .leading, spacing: 4) {
                            V3Skeleton(width: 300 * ratio, height: 13, radius: 3).frame(height: 20)
                            V3Skeleton(width: 300 * (ratio - 0.2), height: 11, radius: 3).frame(height: 18)
                        }.padding(.vertical, 10)
                    }.accessibilityElement(children: .ignore).accessibilityLabel("正在加载同方向岗位…")
                } else {
                    ForEach(related, id: \.self) { item in
                        Button { openJob(item.text("id")) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                poolTitle(item).font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 20)
                                Text([item["company"]?.text("name") ?? "", JobPool.cities(item).first ?? "", JobPool.recruitment(item),
                                      JobPool.relative(item.text("published_at"))].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(V3.sans(12)).foregroundStyle(V3.fnt).lineLimit(1).frame(height: 18)
                            }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.accessibilityElement(children: .contain).accessibilityLabel("同方向岗位")
        }
    }

    private func actions(_ job: JSONValue) -> some View {
        let closed = job.text("availability_status") == "closed"
        let joined = job.text("joined_application_id").nonEmptyValue
        let deadline = job.text("deadline").nonEmptyValue ?? JobPool.attribute(job, "deadline")
        return VStack(spacing: 10) {
            if let joined {
                Button { openApplication(joined) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                        Text("已加入求职进程 · 去投递看板")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(V3.sans(14, weight: .medium)).foregroundStyle(Color(hex: 0x2E8B4E))
                    .frame(maxWidth: .infinity).frame(height: 40).background(V3.greenSoft, in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain)
            } else if closed {
                Text("岗位已从官网下线").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.fnt)
                    .frame(maxWidth: .infinity).frame(height: 40).background(V3.field, in: Capsule())
            } else {
                Button { Task { await joinJob(job) } } label: {
                    Text(join.joiningID == job.text("id") ? "正在加入…" : "加入求职进程").font(V3.sans(14, weight: .medium)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 40).background(V3.txt, in: Capsule()).contentShape(Capsule())
                }.buttonStyle(.plain).disabled(join.joiningID != nil).opacity(join.joiningID != nil ? 0.6 : 1)
            }
            if let url = URL(string: job.text("source_url")) {
                Link(destination: url) {
                    Text("去官网投递 ↗").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).frame(maxWidth: .infinity).frame(height: 40)
                        .background(.white, in: Capsule()).overlay(Capsule().stroke(V3.cl)).contentShape(Capsule())
                }.buttonStyle(.plain)
            }
            if let deadline, !closed, let parsed = JobPool.deadline(deadline) { deadlineText(parsed) }
        }
        .coachTarget(joined == nil && !closed && jobFirst.open && noApplications == true, label: "岗位详情引导",
                     message: "加入后，模拟面试就能对着这个岗位出题，\n投递进度也在投递看板跟进。",
                     actions: [CoachAction(label: "知道了")]) { jobFirst.dismiss() }
        .coachTarget(joined != nil && justJoinedFirst != nil && joinedFirst.open, label: "加入岗位后的下一步",
                     message: "第一个岗位加好了。要不要对着它练一场？\n练完就有第一份报告。",
                     actions: [CoachAction(label: "对着这个岗位练一场") { practiceJoined() }, CoachAction(label: "先接着看岗位")]) {
            joinedFirst.dismiss(); jobFirst.dismiss()
        }
    }

    /// 「11月30日截止，还剩 48 天」：剩余天数橙色；已过期整行灰色。
    private func deadlineText(_ deadline: JobPool.Deadline) -> some View {
        let line: Text
        switch deadline {
        case .past(let date): line = Text("已于 \(date)截止").foregroundColor(V3.fnt)
        case .today: line = Text("今天截止").foregroundColor(V3.orange).fontWeight(.medium)
        case .left(let date, let days): line = Text("\(date)截止，") + Text("还剩 \(days) 天").foregroundColor(V3.orange).fontWeight(.medium)
        }
        return line.font(V3.sans(13)).foregroundStyle(V3.sub).frame(height: 20)
    }

    // MARK: 请求

    private func load() async {
        if job == nil { state = "loading" }
        do {
            let value = try await session.api.careerRequest(path: "/api/job-pool/\(jobID)", method: "GET", query: [:], body: nil)
            job = value; state = "ready"
        } catch is CancellationError { return }
        catch APIError.server(_, let code) where code == "JOB_POOL_NOT_FOUND" { state = "missing"; return }
        catch { state = "error"; return }
        // 侧栏是附加信息：失败时直接不显示。
        let companyID = job?["company"]?.text("id") ?? ""
        let category = job?.text("category") ?? ""
        async let companyValue: JSONValue? = companyID.isEmpty ? nil
            : try? await session.api.careerRequest(path: "/api/job-pool/companies/\(companyID)", method: "GET", query: [:], body: nil)
        async let relatedValue: JSONValue? = category.isEmpty ? nil
            : try? await session.api.careerRequest(path: "/api/job-pool", method: "GET", query: ["job_category": category, "sort": "published"], body: nil)
        async let totalValue: JSONValue? = category.isEmpty ? nil
            : try? await session.api.careerRequest(path: "/api/job-pool/count", method: "GET", query: ["job_category": category], body: nil)
        company = await companyValue; companyLoading = false
        related = Array(((await relatedValue)?["items"]?.items ?? []).filter { $0.text("id") != jobID }.prefix(3)); relatedLoading = false
        relatedTotal = (await totalValue)?["total"]?.integer; relatedTotalLoading = false
    }

    private func joinJob(_ value: JSONValue) async {
        await join.join(value, api: session.api, open: openApplication,
            joined: { _, application in
                job = job?.with("joined_application_id", .string(application))
                if firstBeforeJoin { justJoinedFirst = application }
            },
            closed: { _ in job = job?.with("availability_status", .string("closed")) })
    }

    /// 「对着这个岗位练一场」：进模拟面试设置页，面试岗位预选刚加入的这个（设置页读走 `pendingMockApplication`）。
    private func practiceJoined() {
        guard let application = justJoinedFirst else { return }
        CoachGuide.shared.pendingMockApplication = application
        router?.jump(.mock(nil))
    }
}

private extension Array {
    var nonEmptyArray: [Element]? { isEmpty ? nil : self }
}
