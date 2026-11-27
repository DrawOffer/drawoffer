import SwiftUI
import DrawOfferCore

/// 岗位广场 B · 公司页（Web `CompanyView`；macOS 稿 01.14 公司页 · 岗位类型与标签）：
/// 面包屑 → 公司头（Logo、行业、官网、在招总数）→ 方向胶囊与本公司搜索 → 分隔线 → 类型 tab、城市与排序 → 岗位列表。
struct JobPoolCompany: View {
    @Environment(SessionStore.self) private var session
    let companyID: String
    let initial: JobPoolView.Query
    let root: () -> Void
    let openJob: (String) -> Void
    let openApplication: (String) -> Void

    @State private var query = JobPoolView.Query()
    @State private var keyword = ""
    @State private var keywordError = false
    @State private var company: JSONValue?
    @State private var companyState = "loading"
    @State private var jobs: [JSONValue] = []
    @State private var cursor: String?
    @State private var loading = true
    @State private var loadingMore = false
    @State private var failed = false
    @State private var moreFailed = false
    @State private var revision = 0
    @State private var started = false
    @State private var listSettled = false
    @State private var join = PoolJoin()

    var body: some View {
        Group {
            if companyState == "missing" {
                V3Page(top: 38) {
                    VStack(alignment: .leading, spacing: 0) {
                        PoolCrumbs(back: root, current: "公司不存在")
                        PoolState(title: "没有找到这家公司", message: "公司可能已不再收录，或链接不完整。", width: 314, stage: 96,
                                  art: { PoolUnavailableArt(tag: "链接已失效") }) {
                            Button("返回岗位广场", action: root).buttonStyle(.plain).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.link)
                        }
                    }
                }
            } else if companyState == "loading" || (companyState == "ready" && !listSettled) {
                // 公司信息和第一页岗位都到了才显示页面；之后换筛选只刷新岗位列表。
                V3Loading("正在加载公司…", retry: { revision += 1 }).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { page }
        }
        .onAppear { if !started { started = true; query = initial; keyword = initial.keyword } }
        .task(id: revision) { await loadCompany() }
        .task(id: "\(query.hashValue)-\(revision)") { await loadJobs() }
        .modifier(PoolJoinFeedback(join: join, open: openApplication, retry: { job in Task { await joinJob(job) } }))
    }

    private var name: String { company?.text("name") ?? "" }

    /// 公司头城市标签：已加载岗位里出现最多的工作城市。
    private var mainCity: String? {
        var counts: [String: Int] = [:]
        for job in jobs { for city in JobPool.cities(job) { counts[city, default: 0] += 1 } }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// 公司头「HH:mm 同步」：岗位所属官网来源最近一次完整同步时间（`source.last_complete_at`）。
    private var syncedAt: String? {
        jobs.compactMap { $0["source"]?.text("last_complete_at").nonEmptyValue }.max().flatMap(PoolSync.text)
    }

    private var page: some View {
        V3Page(top: 38) {
            VStack(alignment: .leading, spacing: 0) {
                PoolCrumbs(back: root, current: name.isEmpty ? "公司" : name)
                head.padding(.top, 18)
                HStack(alignment: .center, spacing: 16) {
                    categoryChips.frame(maxWidth: .infinity, alignment: .leading)
                    companySearch
                }.padding(.top, 30)
                Rectangle().fill(V3.line).frame(height: 1).padding(.top, 18)
                resultBar
                if keywordError { PoolNote(text: JobPool.keywordError).padding(.top, 12) }
                list
            }
        }
    }

    @ViewBuilder private var head: some View {
        HStack(alignment: .top, spacing: 24) {
            if let company {
                HStack(alignment: .top, spacing: 18) {
                    PoolLogo(name: company.text("name"), url: company.text("logo_url"), size: 56)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(company.text("name")).font(.system(size: 24, weight: .regular)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 31)
                        HStack(spacing: 8) {
                            if let industry = company.text("industry").nonEmptyValue { V3Chip(label: industry, height: 18, size: 11.5) }
                            if let city = mainCity { V3Chip(label: city, height: 18, size: 11.5) }
                            if let careers = company.text("careers_url").nonEmptyValue, let url = URL(string: careers) {
                                Link(destination: url) { Text(JobPool.host(careers) + " ↗") }.font(V3.sans(11.5)).foregroundStyle(V3.sub)
                            }
                        }.padding(.top, 7)
                    }.padding(.top, -2)
                }
                Spacer(minLength: 0)
                PoolStats(count: company["open_count"]?.integer ?? 0, today: company["today_new"]?.integer ?? 0, extra: syncedAt.map { "\($0) 同步" }).padding(.top, 3)
            } else {
                PoolNote(text: "公司信息暂时无法加载。") {
                    Button("重试") { revision += 1 }.buttonStyle(.plain).font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.sub)
                }
            }
        }.frame(minHeight: 56, alignment: .top)
    }

    /// 方向胶囊：选中墨黑底白字，其余白底细边框，数量灰色小字。
    private var categoryChips: some View {
        let items = [(name: "", label: "全部方向", count: Int?.none)]
            + (company?["categories"]?.items ?? []).map { (name: $0.text("name"), label: $0.text("name"), count: Optional($0["count"]?.integer ?? 0)) }
        return FlowLayout(spacing: 8) {
            ForEach(items, id: \.name) { item in
                let active = query.category == item.name
                Button { query.category = item.name } label: {
                    HStack(spacing: 6) {
                        Text(item.label)
                        if let count = item.count { Text(JobPool.grouped(count)).font(V3.number(11.5, weight: .regular)).foregroundStyle(active ? .white.opacity(0.7) : V3.fnt) }
                    }
                    .font(V3.sans(12.5, weight: active ? .medium : .regular)).foregroundStyle(active ? .white : V3.txt)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(active ? V3.txt : .white, in: Capsule()).overlay(Capsule().stroke(active ? .clear : V3.cl))
                    .contentShape(Capsule()).fixedSize()
                }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("按方向筛选")
    }

    private var tabs: [(value: String, label: String, count: Int?)] {
        // 各 tab 互斥；「未分类」放官网没标类型的岗位，有才出现。
        let unclassified = company?["counts"]?["unclassified"]?.integer ?? 0
        var items: [(value: String, label: String, count: Int?)] = [(value: "", label: "全部", count: company?["open_count"]?.integer)]
        items += JobPool.types.map { (value: $0.value, label: $0.label, count: company?["counts"]?[$0.value]?.integer) }
        if unclassified > 0 || query.type == "unclassified" { items.append((value: "unclassified", label: "未分类", count: unclassified)) }
        return items
    }

    private var cityOptions: [String] {
        let counted = (company?["city_counts"]?.items ?? []).map { $0.text("name") }.filter { !$0.isEmpty }
        return counted.isEmpty ? (company?["cities"]?.items ?? []).compactMap(\.stringValue) : counted
    }

    /// 类型 tab（下划线）与右侧清除筛选、城市、排序。
    private var resultBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            PoolTabs(items: tabs, selection: query.type) { query.type = $0 }
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                if query.filtered {
                    Button("清除筛选", action: clear).buttonStyle(.plain).font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.sub)
                }
                PoolMenu(label: "城市", value: query.city.isEmpty ? "城市" : query.city,
                         options: [("", "全部城市")] + cityOptions.map { ($0, $0) }) { query.city = $0 }
                // `GET /api/job-pool?sort=published|collected`
                PoolMenu(label: "排序", value: query.sort == "collected" ? "最新收录" : "最新发布",
                         options: [("published", "最新发布"), ("collected", "最新收录")]) { query.sort = $0 }
            }.padding(.bottom, 8)
        }
        .padding(.top, 10)
    }

    /// 本公司搜索（灰底胶囊，回车提交）。
    private var companySearch: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(V3.fnt)
            TextField("", text: $keyword, prompt: Text(name.isEmpty ? "搜索本公司岗位" : "搜索\(name)的岗位").foregroundStyle(V3.fnt))
                .textFieldStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.txt)
                .onSubmit(submit).onChange(of: keyword) { keywordError = false }
        }
        .padding(.horizontal, 12).frame(width: 210, height: 30)
        .background(V3.field, in: Capsule())
        .accessibilityLabel("搜索本公司岗位")
    }

    @ViewBuilder private var list: some View {
        if failed {
            PoolError(title: "岗位暂时无法加载", message: "网络不稳定或服务暂时不可用，筛选条件已保留。") { revision += 1 }
        } else if loading {
            V3Loading("正在加载岗位…", retry: { revision += 1 }).frame(maxWidth: .infinity).padding(.top, 80)
        } else if jobs.isEmpty {
            let summary = [query.keyword, query.category, JobPool.types.first { $0.value == query.type }?.label ?? "", query.city].filter { !$0.isEmpty }.joined(separator: " · ")
            PoolState(title: query.filtered ? "没有符合条件的岗位" : "这家公司暂时没有在招岗位",
                      message: query.filtered ? "换个关键词，或减少方向、类型、城市的筛选条件试试。" : "官网的岗位同步后会出现在这里，稍后再来看看。",
                      art: { PoolEmptyArt(summary: summary.isEmpty ? name : summary) }) {
                if query.filtered {
                    Button(action: clear) { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)); Text("清除筛选") }
                        .buttonStyle(V3ButtonStyle(kind: .ghost))
                }
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(jobs, id: \.self) { job in
                    PoolJobRow(job: job, keyword: query.keyword, joining: join.joiningID, open: { openJob(job.text("id")) },
                               openApplication: openApplication, join: { Task { await joinJob(job) } })
                }
                PoolListFoot(hasMore: cursor != nil, loading: loadingMore, failed: moreFailed, noun: "岗位") { Task { await loadMore() } }
            }.padding(.top, 10).padding(.horizontal, -20)
        }
    }

    private func clear() { keyword = ""; keywordError = false; let sort = query.sort; query = JobPoolView.Query(); query.sort = sort }

    private func submit() {
        let text = keyword.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty && (text.count < 2 || text.count > 100) { keywordError = true; return }
        keywordError = false
        query.keyword = text
    }

    private func params(cursor: String? = nil) -> [String: String] {
        var result = ["company_ids": companyID, "sort": query.sort]
        if !query.keyword.isEmpty { result["keyword"] = query.keyword }
        if !query.city.isEmpty { result["city"] = query.city }
        if !query.category.isEmpty { result["job_category"] = query.category }
        if !query.type.isEmpty { result["recruitment_type"] = query.type }
        if let cursor { result["cursor"] = cursor }
        return result
    }

    private func loadCompany() async {
        if company == nil { companyState = "loading" }
        do {
            company = try await session.api.careerRequest(path: "/api/job-pool/companies/\(companyID)", method: "GET", query: [:], body: nil)
            companyState = "ready"
        } catch is CancellationError {}
        catch APIError.server(_, let code) where code == "JOB_POOL_COMPANY_NOT_FOUND" { companyState = "missing" }
        catch { companyState = "error" }
    }

    private func loadJobs() async {
        guard started else { return }
        loading = true; loadingMore = false; failed = false; moreFailed = false; cursor = nil; jobs = []
        do {
            let page = try await session.api.careerRequest(path: "/api/job-pool", method: "GET", query: params(), body: nil)
            try Task.checkCancellation()
            jobs = page["items"]?.items ?? []
            cursor = page.text("next_cursor").nonEmptyValue
        } catch is CancellationError { return }
        catch { failed = true }
        loading = false; listSettled = true
    }

    private func loadMore() async {
        guard let current = cursor, !loadingMore else { return }
        let snapshot = query
        loadingMore = true; moreFailed = false
        defer { if snapshot == query { loadingMore = false } }
        do {
            let page = try await session.api.careerRequest(path: "/api/job-pool", method: "GET", query: params(cursor: current), body: nil)
            guard snapshot == query else { return }
            let known = Set(jobs.map { $0.text("id") })
            jobs += (page["items"]?.items ?? []).filter { !known.contains($0.text("id")) }
            cursor = page.text("next_cursor").nonEmptyValue
        } catch { if snapshot == query { moreFailed = true } }
    }

    private func joinJob(_ job: JSONValue) async {
        await join.join(job, api: session.api, open: openApplication,
            joined: { id, application in jobs = jobs.map { $0.text("id") == id ? $0.with("joined_application_id", .string(application)) : $0 } },
            closed: { id in jobs = jobs.map { $0.text("id") == id ? $0.with("availability_status", .string("closed")) : $0 } })
    }
}

/// `.pool-figure`：在招总数，下面一行今日新增。
private struct PoolStats: View {
    let count: Int
    let today: Int
    var extra: String?
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(JobPool.grouped(count)).font(V3.number(28)).foregroundStyle(V3.txt)
                Text("个在招岗位").font(V3.sans(12.5)).foregroundStyle(V3.fnt)
            }.frame(height: 31)
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(today > 0 ? V3.blue : V3.fnt2).frame(width: 6, height: 6)
                    Text("今日新增 \(JobPool.grouped(today))").fixedSize()
                }.foregroundStyle(today > 0 ? V3.blue : V3.fnt)
                if let extra { Text(" · " + extra).foregroundStyle(V3.fnt).fixedSize() }
            }.font(V3.sans(12)).frame(height: 23)
        }.fixedSize()
    }
}

/// 01.14「城市 ▾」「最新发布 ▾」：无边框文字菜单。
private struct PoolMenu: View {
    let label: String
    let value: String
    let options: [(String, String)]
    let change: (String) -> Void
    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in Button(option.1) { change(option.0) } }
        } label: {
            HStack(spacing: 3) {
                Text(value)
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 5))
            }.font(V3.sans(12.5)).foregroundStyle(V3.sub)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel(label)
    }
}

/// 公司页岗位条目：标题「岗位名 - 团队」17 常规 + 今日新增；竖线分隔的属性行（方向放灰底小框，今天发布用蓝字）；灰色简介最多两行。
/// 列表无分隔线、靠留白区分；悬停整条浮起为白底圆角 12 卡片，右侧出现「官网 ↗」与黑色胶囊「加入求职进程」；
/// 已加入的条目右侧常显灰色「✓ 已加入求职进程」。
private struct PoolJobRow: View {
    let job: JSONValue
    let keyword: String
    let joining: String?
    let open: () -> Void
    let openApplication: (String) -> Void
    let join: () -> Void
    @State private var hover = false

    var body: some View {
        let closed = job.text("availability_status") == "closed"
        let joined = job.text("joined_application_id").nonEmptyValue
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    poolTitle(job, keyword).font(V3.sans(17))
                        .foregroundStyle(closed ? V3.fnt : hover ? V3.blue : V3.txt).lineLimit(1).frame(height: 24)
                    if JobPool.isToday(job.text("new_at")) { PoolBadge(text: "今日新增") }
                    if job.text("availability_status") == "missing" { PoolBadge(text: "本轮未发现", warn: true) }
                }
                meta.padding(.top, 12)
                Group {
                    if let summary = job.text("summary").nonEmptyValue {
                        poolHighlight(summary, keyword).foregroundStyle(V3.fnt).lineLimit(2)
                    } else {
                        Text("官网暂未提供岗位正文").foregroundStyle(V3Skeleton.faint).lineLimit(1)
                    }
                }
                .font(V3.sans(12.5)).lineSpacing(21 - 12.5 * 1.2).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            }
            .padding(.trailing, 230)
            .padding(.horizontal, 20).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if hover {
                RoundedRectangle(cornerRadius: 12).fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.line))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 9) {
                if let joined {
                    Button { openApplication(joined) } label: {
                        Text("✓ 已加入求职进程").font(V3.sans(11.5)).foregroundStyle(V3.fnt)
                            .padding(.horizontal, 10).frame(height: 24).background(V3.field, in: Capsule()).overlay(Capsule().stroke(V3.cl))
                    }.buttonStyle(.plain).accessibilityLabel("已加入求职进程，打开求职记录")
                } else if hover {
                    if let url = URL(string: job.text("source_url")) {
                        Link(destination: url) {
                            Text("官网 ↗").font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.txt)
                                .padding(.horizontal, 14).frame(height: 31).background(.white, in: Capsule()).overlay(Capsule().stroke(V3.cl))
                        }.buttonStyle(.plain)
                    }
                    if !closed {
                        Button(action: join) {
                            Text(joining == job.text("id") ? "正在加入…" : "加入求职进程").font(V3.sans(12.5, weight: .medium)).foregroundStyle(.white)
                                .padding(.horizontal, 16).frame(height: 32).background(V3.txt, in: Capsule())
                        }.buttonStyle(.plain).disabled(joining != nil).opacity(joining != nil && joining != job.text("id") ? 0.5 : 1)
                    }
                }
            }.padding(.top, 16).padding(.trailing, 20)
        }
        .onHover { hover = $0 }.animation(.easeOut(duration: 0.14), value: hover)
        .accessibilityElement(children: .contain)
    }

    /// Web `JobMeta`：地点、招聘类型、方向、薪资、发布时间。
    private var meta: some View {
        let category = job.text("category")
        let time = JobPool.relative(job.text("published_at"))
        var parts: [AnyView] = [AnyView(poolHighlight(JobPool.cityLabel(JobPool.cities(job)), keyword).foregroundStyle(V3.txt)),
                                AnyView(Text(JobPool.recruitment(job)))]
        if !category.isEmpty {
            parts.append(AnyView(Text(category).font(V3.sans(11.5)).padding(.horizontal, 6).frame(height: 19).background(V3.field, in: RoundedRectangle(cornerRadius: 4))))
        }
        if let salary = job.text("salary_text").nonEmptyValue { parts.append(AnyView(Text(salary))) }
        if !time.isEmpty { parts.append(AnyView(Text(time).foregroundStyle(time == "今天" ? V3.blue : V3.sub))) }
        return PoolMetaLine(parts: parts).font(V3.sans(13)).foregroundStyle(V3.sub).frame(height: 19)
    }
}

/// 公司页同步时间的展示。
enum PoolSync {
    /// 今天只写「HH:mm」，其余写「今天/昨天/日期 HH:mm」（`JobPool.date`）。
    static func text(_ value: String) -> String? {
        guard let date = CareerApplication.date(value) else { return nil }
        return Beijing.calendar.isDateInToday(date) ? CareerDeckFormat.clock(date) : JobPool.date(value)
    }
}
