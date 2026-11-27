import SwiftUI
import DrawOfferCore

/// 岗位广场（Web `features/jobs/OpportunitiesPage.tsx`）：岗位优先的列表（可切到按公司看）→ 公司页 → 岗位详情。
/// macOS 稿 06 · 岗位广场 01 分区（210:698）：01.01 列表、01.02 意向、01.03–01.06 筛选下拉、01.07/01.12/01.13 骨架、01.08 按公司。
struct JobPoolView: View {
    /// 公司页的条件：公司页只按一个城市、一个方向筛。
    struct Query: Hashable {
        var keyword = "", city = "", category = "", type = ""
        /// 岗位排序：`published` 最新发布（默认）/ `collected` 最新收录；不算筛选条件。
        var sort = "published"
        var filtered: Bool { !keyword.isEmpty || !city.isEmpty || !category.isEmpty || !type.isEmpty }
    }
    enum Route: Hashable { case company(String, Query), job(String) }

    let openApplication: (String) -> Void
    var openCareerProfile: () -> Void = {}
    @State private var path: [Route] = []
    /// 广场条件放在这一层：进出公司页与详情时保留，详情里「同方向岗位 · 全部」也从这里改。
    @State private var plaza = PoolPlaza()
    /// 推荐流的种子：本次进入广场固定，看完详情回来顺序不变。
    @State private var seed = JobPool.newSeed()

    var body: some View {
        ZStack {
            // 广场一直挂着、只是藏起来：返回时列表、已翻到的页与滚动位置都还在（Web 用会话内记忆做同一件事）。
            JobPoolPlaza(plaza: $plaza, seed: seed,
                         openCompany: { path = [.company($0, $1)] }, openJob: { path = [.job($0)] },
                         openApplication: openApplication, openCareerProfile: openCareerProfile)
                .opacity(path.isEmpty ? 1 : 0).allowsHitTesting(path.isEmpty).accessibilityHidden(!path.isEmpty)
            switch path.last {
            case nil: EmptyView()
            case .company(let id, let query)?:
                JobPoolCompany(companyID: id, initial: query, root: { path = [] }, openJob: { path.append(.job($0)) }, openApplication: openApplication)
                    .id(id + "\(query.hashValue)").background(.white)
            case .job(let id)?:
                JobPoolJob(jobID: id, root: { path = [] },
                           openCompany: { company, query in path = [.company(company, query)] },
                           openJob: { path.append(.job($0)) },
                           openPlaza: { next in plaza = next; path = [] },
                           openApplication: openApplication)
                    .id(id).background(.white)
            }
        }
    }
}

// MARK: - 共用

extension JSONValue {
    func with(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = self else { return self }
        fields[key] = value
        return .object(fields)
    }
}

/// `PoolCompanyLogo`：公开的公司图标，缺图或加载失败时回退首字。
struct PoolLogo: View {
    @Environment(SessionStore.self) private var session
    let name: String
    let url: String
    var size: CGFloat = 24
    /// 列表、公司卡片与详情侧栏的首字底为 #F4F4F2、无描边；其余位置白底细描边。
    var filled = false
    private var radius: CGFloat { [20: 5, 24: 6, 32: 8, 36: 8, 40: 9, 48: 10, 56: 12, 64: 12][size] ?? 6 }
    private var fontSize: CGFloat { [20: 10, 24: 12, 32: 14, 36: 14, 40: 16, 48: 19, 56: 22, 64: 24][size] ?? 12 }
    private var source: URL? {
        guard url.hasPrefix("/api/company-logos/"), let origin = (session.api as? HTTPAPIClient)?.origin else { return nil }
        return URL(string: url, relativeTo: origin)?.absoluteURL
    }
    private var initial: String { String(name.trimmingCharacters(in: .whitespaces).prefix(1)).nonEmptyValue ?? "企" }
    var body: some View {
        AsyncImage(url: source) { phase in
            if let image = phase.image { image.resizable().scaledToFit() }
            else { Text(initial).font(V3.sans(fontSize, weight: .medium)).foregroundStyle(filled ? V3.txt : Color(hex: 0x454842)) }
        }
        .frame(width: size, height: size).background(filled ? V3.field : .white)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(filled ? .clear : V3.cl))
        .accessibilityHidden(true)
    }
}

/// 面包屑：「岗位广场 / 公司 / 当前页」11.5px，前几级灰色可点、当前页墨黑。
struct PoolCrumbs: View {
    let back: () -> Void
    var trail: [(String, () -> Void)] = []
    var current: String?
    var body: some View {
        HStack(spacing: 8) {
            Button("岗位广场", action: back).buttonStyle(.plain).foregroundStyle(V3.fnt).accessibilityLabel("返回岗位广场")
            ForEach(Array(trail.enumerated()), id: \.offset) { _, item in
                Text("/").foregroundStyle(V3.fnt2).accessibilityHidden(true)
                Button(item.0, action: item.1).buttonStyle(.plain).foregroundStyle(V3.fnt).lineLimit(1).fixedSize()
            }
            if let current, !current.isEmpty {
                Text("/").foregroundStyle(V3.fnt2).accessibilityHidden(true)
                Text(current).foregroundStyle(V3.txt).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(V3.sans(11.5)).frame(height: 14)
    }
}

/// `.pool-tabs`：招聘类型下划线 tab，数量灰色小字；数量还没到时放一小段骨架，不让 tab 宽度跳。
struct PoolTabs: View {
    let items: [(value: String, label: String, count: Int?)]
    let selection: String
    var loading = false
    let change: (String) -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(items, id: \.value) { item in
                let active = item.value == selection
                Button { change(item.value) } label: {
                    HStack(spacing: 5) {
                        Text(item.label).font(V3.sans(14, weight: active ? .medium : .regular)).foregroundStyle(active ? V3.txt : V3.sub)
                        if let count = item.count { Text(JobPool.grouped(count)).font(V3.number(12, weight: .regular)).foregroundStyle(V3.fnt) }
                        else if loading { V3Skeleton(width: 26, height: 12, radius: 3) }
                    }
                    .frame(height: 30, alignment: .top)
                    .overlay(alignment: .bottom) { if active { RoundedRectangle(cornerRadius: 1).fill(V3.txt).frame(height: 2) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : []).accessibilityLabel(item.label)
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("招聘类型")
    }
}

/// 关键词命中处蓝字浅蓝底（Web `.pool-hit`）。
func poolHighlight(_ text: String, _ keyword: String) -> Text {
    JobPool.highlight(text, keyword: keyword).reduce(Text("")) { result, part in
        guard part.hit else { return result + Text(part.text) }
        var hit = AttributedString(part.text)
        hit.foregroundColor = V3.blue; hit.backgroundColor = V3.blueSoft
        return result + Text(hit)
    }
}

/// 岗位标题「岗位名 - 团队」。
func poolTitle(_ job: JSONValue, _ keyword: String = "") -> Text {
    let department = job.text("department")
    return poolHighlight(job.text("title"), keyword) + (department.isEmpty ? Text("") : Text(" - ") + poolHighlight(department, keyword))
}

/// 竖线分隔的一行元信息（`.pool-row-meta`）。
struct PoolMetaLine: View {
    let parts: [AnyView]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Rectangle().fill(V3.cl).frame(width: 1, height: 11).padding(.leading, 8).padding(.trailing, 5) }
                part
            }
        }.lineLimit(1)
    }
}

/// `.pool-new`：今日新增 / 本轮未发现 小标签。
struct PoolBadge: View {
    let text: String
    var warn = false
    var body: some View {
        Text(text).font(V3.sans(10.5, weight: .medium)).foregroundStyle(warn ? Color(hex: 0x8A4D12) : V3.blue)
            .padding(.horizontal, 7).frame(height: 17).background(warn ? V3.orangeSoft : V3.blueSoft, in: RoundedRectangle(cornerRadius: 4)).fixedSize()
    }
}

/// `.pool-note`：浅色提示条，警告时为橙色。
struct PoolNote<Trailing: View>: View {
    let text: String
    var warn = true
    var icon = false
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 8) {
            if icon { Image(systemName: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(V3.orange) }
            Text(text).frame(minHeight: 22)
            trailing()
        }
        .font(V3.sans(12.5)).foregroundStyle(warn ? Color(hex: 0x8A4D12) : V3.sub)
        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
        .background(warn ? V3.orangeSoft : V3.field, in: RoundedRectangle(cornerRadius: 8))
    }
}

extension PoolNote where Trailing == EmptyView {
    init(text: String, warn: Bool = true, icon: Bool = false) { self.init(text: text, warn: warn, icon: icon, trailing: { EmptyView() }) }
}

/// `.pool-state` 里的空状态、失败与不存在卡片。
struct PoolState<Art: View, Actions: View>: View {
    let title: String
    let message: String
    var width: CGFloat = 400
    var stage: CGFloat = 156
    @ViewBuilder var art: () -> Art
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        V3EmptyCard(title: title, message: message, stageHeight: stage, width: width, actionsTop: 22, art: art, actions: actions)
            .frame(width: width).frame(maxWidth: .infinity).padding(.top, 52).padding(.bottom, 40)
    }
}

struct PoolError: View {
    let title: String
    let message: String
    let retry: () -> Void
    var body: some View {
        V3EmptyCard(title: title, message: message, stageHeight: 128, width: 440, art: {
            Image(systemName: "icloud.slash").font(.system(size: 30, weight: .light)).foregroundStyle(Color(hex: 0x96968F))
        }, actions: {
            Button(action: retry) { Image(systemName: "arrow.clockwise").font(.system(size: 12)); Text("重新加载") }
                .buttonStyle(V3ButtonStyle(kind: .ghost, height: 36))
        })
        .frame(width: 440).frame(maxWidth: .infinity).padding(.top, 52).padding(.bottom, 40)
    }
}

/// 列表底：滚到这里自动取下一页（`onAppear`，Web 用 IntersectionObserver 提前 240px）；失败时给重试。
struct PoolListFoot: View {
    let hasMore: Bool
    let loading: Bool
    let failed: Bool
    let noun: String
    let more: () -> Void
    var body: some View {
        Group {
            if failed {
                HStack(spacing: 0) {
                    Text("加载失败，")
                    Button("重试", action: more).buttonStyle(.plain).font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.link)
                }
            } else if loading { Text("正在加载更多\(noun)…") }
            else if hasMore { Text("下滑加载更多").onAppear(perform: more) }
            else { Text("没有更多了") }
        }
        .font(V3.sans(12.5)).foregroundStyle(V3.fnt).frame(maxWidth: .infinity, minHeight: 64)
    }
}

// MARK: - 插图（坐标照 Web `PoolArt.tsx`）

/// `SearchBlankArt`：带当前条件的搜索框 + 清除角标，下面三行虚线空位。
struct PoolEmptyArt: View {
    let summary: String
    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 9))
                Text(summary).font(V3.sans(9.5)).lineLimit(1)
            }
            .foregroundStyle(V3.sub).padding(.horizontal, 12).frame(width: 180, height: 28, alignment: .leading)
            .background(.white, in: Capsule()).overlay(Capsule().stroke(V3.cl)).shadow(color: .black.opacity(0.06), radius: 3, y: 2)
            .offset(x: 30, y: 24)
            ArtBadge(x: 196, y: 14)
            ForEach([64, 92, 120] as [CGFloat], id: \.self) { top in
                ZStack(alignment: .topLeading) {
                    ArtBar(x: 8, y: 9, w: 10, h: 4, r: 2)
                    ArtBar(x: 24, y: 9, w: top == 92 ? 64 : 84, h: 4, r: 2)
                }
                .frame(width: 180, height: 22, alignment: .topLeading)
                .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(V3.sk2, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .offset(x: 30, y: top)
            }
        }
        .frame(width: 240, height: 150, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
    }
}

/// `PoolUnavailableArt`：卡片 + 状态标签 + 禁止角标（岗位不存在、已下线共用）。
struct PoolUnavailableArt: View {
    let tag: String
    var body: some View {
        ZStack(alignment: .topLeading) {
            ArtPaper(x: 30, y: 12, w: 150, h: 66) {
                ArtBar(x: 14, y: 14, w: 20, h: 20, r: 5, color: Color(hex: 0x8D8D87))
                ArtBar(x: 44, y: 16, w: 70, h: 6, r: 3)
                ArtBar(x: 44, y: 28, w: 44, h: 4, r: 2)
                ArtBar(x: 14, y: 48, w: 100, h: 4, r: 2)
            }
            HStack(spacing: 5) {
                Circle().fill(Color(hex: 0x8D8D87)).frame(width: 6, height: 6)
                Text(tag).font(V3.sans(9.5, weight: .medium)).foregroundStyle(V3.sub)
            }
            .padding(.horizontal, 8).frame(height: 20).background(.white, in: Capsule()).overlay(Capsule().stroke(V3.cl))
            .shadow(color: .black.opacity(0.06), radius: 3, y: 2).fixedSize().offset(x: 120, y: 0)
            ArtBadge(x: 166, y: 60, size: 26, symbol: "nosign", fill: .white, color: V3.sub, border: V3.cl)
        }
        .frame(width: 220, height: 96, alignment: .topLeading).padding(.top, 16).frame(maxHeight: .infinity, alignment: .top)
    }
}

/// `PoolJoinFailedArt`：岗位卡片 → 求职进程空位，红色失败角标。
private struct PoolJoinFailedArt: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            ArtPaper(x: 40, y: 28, w: 128, h: 70) {
                ArtBar(x: 12, y: 14, w: 26, h: 26, r: 6, color: V3.txt)
                ArtBar(x: 48, y: 16, w: 50, h: 6, r: 3)
                ArtBar(x: 48, y: 29, w: 32, h: 4, r: 2)
                ArtBar(x: 12, y: 48, w: 28, h: 10, r: 3)
            }
            Path { path in path.move(to: CGPoint(x: 2, y: 7)); path.addLine(to: CGPoint(x: 34, y: 7)) }
                .stroke(Color(hex: 0xB9B9B3), style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                .frame(width: 44, height: 14).offset(x: 184, y: 56)
            Path { path in path.move(to: CGPoint(x: 34, y: 3)); path.addLine(to: CGPoint(x: 39, y: 7)); path.addLine(to: CGPoint(x: 34, y: 11)) }
                .stroke(Color(hex: 0xB9B9B3), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 44, height: 14).offset(x: 184, y: 56)
            ArtPaper(x: 246, y: 20, w: 92, h: 88, shadow: false, fill: Color(hex: 0xFAFAF8)) {
                ArtBar(x: 10, y: 12, w: 6, h: 6, r: 3, color: Color(hex: 0x8D8D87))
                ArtBar(x: 22, y: 13, w: 40, h: 4, r: 2)
                ForEach([30, 56] as [CGFloat], id: \.self) { top in
                    RoundedRectangle(cornerRadius: 5).stroke(V3.sk2, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 74, height: 20).offset(x: 8, y: top)
                }
            }
            ArtBadge(x: 314, y: 88, size: 26, fill: V3.redSoft, color: V3.red, border: V3.red)
        }
        .frame(width: 330, height: 128, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 加入求职进程（Web `usePoolJoin`）

@MainActor @Observable final class PoolJoin {
    struct Notice: Equatable { let application: String; let created: Bool }
    struct Failure: Identifiable { let id = UUID(); let job: JSONValue; let message: String; let closed: Bool }
    var joiningID: String?
    var notice: Notice?
    var failure: Failure?

    /// 成功时就地提示；失败或岗位已下线时弹窗。已加入的岗位直接打开求职进程。
    func join(_ job: JSONValue, api: any APIClient, open: (String) -> Void, joined: (String, String) -> Void, closed: (String) -> Void) async {
        if let existing = job.text("joined_application_id").nonEmptyValue { open(existing); return }
        guard joiningID == nil, job.text("availability_status") != "closed" else { return }
        let id = job.text("id")
        joiningID = id
        defer { joiningID = nil }
        do {
            let result = try await api.careerRequest(path: "/api/job-pool/\(id)/join", method: "POST", query: [:], body: nil)
            let application = result.text("application_id")
            joined(id, application)
            failure = nil
            notice = Notice(application: application, created: result["created"]?.bool ?? true)
        } catch APIError.server(_, let code) where code == "JOB_POOL_CLOSED" {
            closed(id)
            failure = Failure(job: job, message: "这个岗位已从企业官网下线，无法再加入；已有求职记录不受影响。", closed: true)
        } catch APIError.server(_, let code) {
            failure = Failure(job: job, message: JobPool.error(code) + "岗位信息和已有记录均已保留。", closed: false)
        } catch {
            failure = Failure(job: job, message: JobPool.error("") + "岗位信息和已有记录均已保留。", closed: false)
        }
    }
}

struct PoolJoinFeedback: ViewModifier {
    @Bindable var join: PoolJoin
    let open: (String) -> Void
    let retry: (JSONValue) -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice = join.notice {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(V3.green).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(notice.created ? "已加入求职进程" : "这个岗位已经加入").font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt)
                            Text(notice.created ? "可以在求职进程里继续管理投递和面试。" : "你已有这个岗位的求职记录。").font(V3.sans(12)).foregroundStyle(V3.sub)
                        }
                        Spacer(minLength: 0)
                        Button(notice.created ? "查看" : "查看已有记录") { open(notice.application) }
                            .buttonStyle(V3ButtonStyle(kind: .text))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14).frame(minWidth: 320).fixedSize()
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.cl))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 8)
                    .padding(.top, 28)
                    .task(id: notice) { try? await Task.sleep(for: .seconds(3)); if join.notice == notice { join.notice = nil } }
                }
            }
            .centeredSheet(item: $join.failure) { failure in
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        V3DotStage(height: 128) {
                            if failure.closed { PoolUnavailableArt(tag: "官网已下线") } else { PoolJoinFailedArt() }
                        }.padding(.bottom, 20)
                        Text(failure.closed ? "岗位已下线" : "加入失败").font(.system(size: 18, weight: .semibold)).foregroundStyle(V3.txt)
                        Text(failure.message).font(V3.sans(14)).foregroundStyle(V3.sub).lineHeight(14, 22)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    }.padding(.horizontal, 24).padding(.top, 24)
                    HStack(spacing: 12) {
                        if failure.closed {
                            Button { join.failure = nil } label: { Text("知道了").frame(maxWidth: .infinity) }
                                .buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).keyboardShortcut(.defaultAction)
                        } else {
                            Button { join.failure = nil } label: { Text("取消").frame(maxWidth: .infinity) }
                                .buttonStyle(V3ButtonStyle(kind: .ghost, height: 36)).keyboardShortcut(.cancelAction)
                            Button { retry(failure.job) } label: { Text(join.joiningID != nil ? "正在加入…" : "重新加入").frame(maxWidth: .infinity) }
                                .buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).disabled(join.joiningID != nil)
                        }
                    }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
                }.frame(width: 420)
            }
    }
}

// MARK: - A · 岗位广场：岗位优先，可切到按公司看；两种看法共用同一组筛选

/// 一种看法已取到的列表：岗位按游标翻页，公司按页码翻页。
private struct PoolList {
    let key: String
    var items: [JSONValue]
    var cursor: String?
    var page: Int?
    var hasMore: Bool { cursor != nil || page != nil }
}

private struct PoolFilterAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

private struct JobPoolPlaza: View {
    @Environment(SessionStore.self) private var session
    @Binding var plaza: PoolPlaza
    let seed: String
    let openCompany: (String, JobPoolView.Query) -> Void
    let openJob: (String) -> Void
    let openApplication: (String) -> Void
    let openCareerProfile: () -> Void

    /// 防抖 300ms 后的关键词（去掉首尾空白）；与输入框不一致时还在输入，不发列表请求。
    @State private var debounced = ""
    @State private var summary: JSONValue?
    @State private var summaryFailed = false
    @State private var categories: [String] = []
    @State private var categoriesLoading = true
    @State private var counts: JSONValue?
    @State private var countsLoading = true
    @State private var list: PoolList?
    @State private var failedKey: String?
    @State private var loadingMore: String?
    @State private var moreFailed: String?
    @State private var revision = 0
    @State private var panelOpen = false
    @State private var join = PoolJoin()
    /// J1：求职进程里一个岗位都还没有（Web `useNoApplicationsYet`）；读不到时为 nil，不出引导。
    @State private var noApplications: Bool?

    private var trimmed: String { plaza.q.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var keyword: String { PoolPlaza.keyword(debounced) }
    private var pendingSearch: Bool { trimmed != debounced }
    private var filterQuery: [String: String] { plaza.filter(keyword: keyword) }
    private var listQuery: [String: String] {
        plaza.mode == .job ? plaza.listQuery(keyword: keyword, seed: seed)
            : filterQuery.merging(["page_size": "\(JobPool.companyPageSize)"]) { $1 }
    }
    private var listKey: String? { pendingSearch ? nil : "\(plaza.mode.rawValue)#\(revision)#" + ReadCache.key(path: "", query: listQuery) }
    private var data: PoolList? { list?.key == listKey && listKey != nil ? list : nil }
    private var failed: Bool { listKey != nil && failedKey == listKey }
    private var intent: PoolIntent? { counts.map { PoolIntent($0["intent"]) } }
    private var firstVisit: CoachSlot { CoachSlot(id: "plaza-first", user: session.coachUser) }
    private var showFirstVisit: Bool { firstVisit.open && noApplications == true && plaza.mode == .job && !(data?.items.isEmpty ?? true) }

    var body: some View {
        V3Page(top: 50) {
            VStack(alignment: .leading, spacing: 0) {
                head
                toolbar.padding(.top, 20).zIndex(1)
                content
            }
        }
        .overlayPreferenceValue(PoolFilterAnchor.self) { anchor in
            GeometryReader { proxy in
                if panelOpen, let anchor {
                    let rect = proxy[anchor]
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001).onTapGesture { panelOpen = false }.accessibilityHidden(true)
                        PoolFilterPanel(value: plaza.panel, base: plaza.base(keyword: keyword), categories: categories, categoriesLoading: categoriesLoading) { value in
                            panelOpen = false; plaza.panel = value
                        }
                        .offset(x: max(8, rect.maxX - PoolFilterPanel.width), y: rect.maxY + 6)
                    }
                    .onExitCommand { panelOpen = false }
                }
            }
        }
        .task(id: plaza.q) {
            let next = plaza.q.trimmingCharacters(in: .whitespacesAndNewlines)
            guard next != debounced else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            debounced = next
        }
        .task { await loadExtras() }
        .task(id: pendingSearch ? nil : ReadCache.key(path: "", query: filterQuery)) { await loadCounts() }
        .task(id: listKey) { await loadFirst() }
        .task(id: firstVisit.open) {
            guard firstVisit.open else { return }
            let list = try? await session.api.careerRequest(path: "/api/job-applications", method: "GET", query: ["scope": "all", "limit": "1"], body: nil)
            noApplications = list.map { ($0["items"]?.items ?? []).isEmpty }
        }
        .modifier(PoolJoinFeedback(join: join, open: openApplication, retry: { job in Task { await joinJob(job) } }))
        .coachMarkHost()
    }

    // MARK: 页头

    /// 眉题 + 衬线标题；右侧收录公司、在招岗位、今日新增三个数（失败时整块不显示）。
    private var head: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("OPPORTUNITIES").font(V3.sans(11)).tracking(0.4)
                    Text("·").foregroundStyle(V3.fnt2)
                    Text("企业官网直招").font(V3.sans(11))
                }.foregroundStyle(V3.sub).frame(height: 14)
                Text("岗位广场").font(V3.serif(28)).foregroundStyle(V3.txt).frame(height: 40).padding(.top, 6)
            }
            Spacer(minLength: 0)
            if !summaryFailed {
                HStack(spacing: 0) {
                    stat("收录公司", summary?["company_count"]?.integer, width: 44)
                    Rectangle().fill(V3.cl).frame(width: 1, height: 32).padding(.horizontal, 23).padding(.top, 9)
                    stat("在招岗位", summary?["open_count"]?.integer, width: 52)
                    Rectangle().fill(V3.cl).frame(width: 1, height: 32).padding(.horizontal, 23).padding(.top, 9)
                    stat("今日新增", summary?["today_new"]?.integer, width: 36, today: true)
                }.padding(.top, 2)
            }
        }
    }

    private func stat(_ label: String, _ value: Int?, width: CGFloat, today: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Group {
                if let value {
                    Text(today && value > 0 ? "+" + JobPool.grouped(value) : JobPool.grouped(value))
                        .font(V3.number(24)).foregroundStyle(today && value > 0 ? V3.blue : V3.txt)
                } else { V3Skeleton(width: width, height: 24, radius: 5) }
            }.frame(height: 30)
            Text(label).font(V3.sans(12)).foregroundStyle(V3.fnt).frame(height: 18)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 工具栏

    /// 左侧类型 tab；右侧「只看符合我意向的」、按岗位/按公司、筛选按钮与搜索框；底部一条分隔线。
    private var toolbar: some View {
        let types = counts?["types"]
        let tabs: [(value: String, label: String, count: Int?)] = [("", "全部", counts?["all"]?.integer)]
            + JobPool.types.map { (value: $0.value, label: $0.label, count: types?[$0.value]?.integer) }
        return HStack(alignment: .bottom, spacing: 16) {
            PoolTabs(items: tabs, selection: plaza.type, loading: countsLoading) { plaza.type = $0 }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                PoolIntentToggle(checked: plaza.intent, intent: intent, openCareerProfile: openCareerProfile) { plaza.intent = $0 }
                    .padding(.trailing, 8)
                V3Segmented(options: [(PoolPlaza.Mode.job, "按岗位"), (.company, "按公司")],
                            selection: Binding(get: { plaza.mode }, set: { plaza.mode = $0 }), height: 32)
                    .accessibilityElement(children: .contain).accessibilityLabel("查看方式")
                filterButton
                PoolSearchBox(text: $plaza.q, placeholder: "岗位、公司或地点", width: 180).accessibilityLabel("搜索岗位、公司或地点")
            }.padding(.bottom, 6)
        }
        .frame(minHeight: 44, alignment: .bottom)
        .overlay(alignment: .bottom) { Rectangle().fill(V3.cl).frame(height: 1) }
    }

    private var filterButton: some View {
        Button { panelOpen.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 12))
                Text(plaza.filterLabel).lineLimit(1).truncationMode(.tail)
                Image(systemName: panelOpen ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
            .padding(.leading, 12).padding(.trailing, 10).frame(maxWidth: 280).frame(height: 32)
            .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
            .contentShape(Rectangle()).fixedSize()
        }
        .buttonStyle(.plain).accessibilityLabel("筛选").accessibilityValue(plaza.filterLabel)
        .anchorPreference(key: PoolFilterAnchor.self, value: .bounds) { $0 }
    }

    // MARK: 列表

    @ViewBuilder private var content: some View {
        if failed {
            PoolError(title: plaza.mode == .job ? "岗位暂时无法加载" : "公司暂时无法加载", message: "网络不稳定或服务暂时不可用，筛选条件已保留。") { revision += 1 }
        } else if let data {
            if data.items.isEmpty { empty }
            else if plaza.mode == .job { jobs(data) }
            else { companies(data) }
        } else {
            skeleton
        }
    }

    @ViewBuilder private var empty: some View {
        let noun = plaza.mode == .job ? "岗位" : "公司"
        if plaza.filtered {
            PoolState(title: "没有符合条件的\(noun)", message: "换个关键词，或减少城市、方向、发布时间的筛选试试。",
                      art: { PoolEmptyArt(summary: plaza.emptySummary) }) {
                Button { plaza = plaza.cleared() } label: { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)); Text("清除筛选") }
                    .buttonStyle(V3ButtonStyle(kind: .ghost))
            }
        } else {
            PoolState(title: "暂时还没有收录岗位", message: "企业官网的岗位同步后会出现在这里，稍后再来看看。",
                      art: { PoolEmptyArt(summary: "企业官网直招") }) { EmptyView() }
        }
    }

    private func jobs(_ data: PoolList) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(data.items.enumerated()), id: \.element) { index, job in
                PlazaJobRow(job: job, keyword: keyword, joining: join.joiningID,
                            open: { firstVisit.dismiss(); openJob(job.text("id")) }, openApplication: openApplication,
                            join: { Task { await joinJob(job) } })
                    .coachTarget(index == 0 && showFirstVisit, label: "岗位广场引导",
                                 message: "点开岗位，看官网正在招什么；\n看中哪个，就点「加入求职进程」。",
                                 actions: [CoachAction(label: "知道了")], corner: 12) { firstVisit.dismiss() }
            }
            PoolListFoot(hasMore: data.hasMore, loading: loadingMore == data.key, failed: moreFailed == data.key, noun: "岗位") { Task { await loadMore() } }
        }
        .padding(.horizontal, -16).padding(.top, 10)
    }

    private func companies(_ data: PoolList) -> some View {
        let carry = plaza.carry(keyword: keyword)
        let query = JobPoolView.Query(keyword: carry.keyword, city: carry.city, category: carry.category, type: carry.type)
        return VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 12) {
                ForEach(data.items, id: \.self) { company in
                    PoolCompanyCard(company: company) { openCompany(company.text("id"), query) }
                }
            }.padding(.top, 26)
            PoolListFoot(hasMore: data.hasMore, loading: loadingMore == data.key, failed: moreFailed == data.key, noun: "公司") { Task { await loadMore() } }
        }
    }

    /// 01.07 / 01.12：列表与公司卡片的骨架，越往下越淡；超过 8 秒补一行慢加载提示（01.13）。
    @ViewBuilder private var skeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            if plaza.mode == .job {
                ForEach(0..<6, id: \.self) { index in
                    HStack(alignment: .top, spacing: 14) {
                        V3Skeleton(width: 36, height: 36, radius: 8)
                        VStack(alignment: .leading, spacing: 0) {
                            V3Skeleton(height: 14).frame(maxWidth: [354, 432, 512, 354, 432, 512][index]).padding(.top, 4)
                            V3Skeleton(height: 11).frame(maxWidth: [276, 374, 276, 276, 374, 276][index]).padding(.top, 13)
                            V3Skeleton(height: 11).frame(maxWidth: 848).padding(.top, 15)
                            V3Skeleton(height: 11).frame(maxWidth: [552, 632, 710, 552, 632, 710][index]).padding(.top, 15)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16).frame(height: 136, alignment: .top)
                    .opacity([1, 1, 1, 1, 0.55, 0.25][index])
                }.padding(.top, 26).padding(.horizontal, -16)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 12) {
                    ForEach(0..<9, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 12) {
                                V3Skeleton(width: 32, height: 32, radius: 8)
                                VStack(alignment: .leading, spacing: 8) { V3Skeleton(width: 96, height: 12); V3Skeleton(width: 56, height: 9) }
                            }.frame(height: 40)
                            HStack { V3Skeleton(width: 80, height: 16); Spacer(); V3Skeleton(width: 96, height: 10) }.frame(height: 24).padding(.top, 16)
                        }
                        .padding(15).frame(height: 112).overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.line))
                        .opacity(index < 6 ? 1 : 0.4)
                    }
                }.padding(.top, 26)
            }
            V3SlowLoadHint(retry: { revision += 1 }).padding(.top, 24)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(plaza.mode == .job ? "正在加载岗位…" : "正在加载公司…")
    }

    // MARK: 请求

    /// 页头数字与方向列表都是附加信息：失败时直接不显示。
    private func loadExtras() async {
        async let summaryValue = try? session.api.careerRequest(path: "/api/job-pool/companies/page", method: "GET", query: ["page_size": "1"], body: nil)
        async let filtersValue = try? session.api.careerRequest(path: "/api/job-pool/filters", method: "GET", query: [:], body: nil)
        let (summaryResult, filtersResult) = await (summaryValue, filtersValue)
        if let summaryResult { summary = summaryResult["summary"] } else { summaryFailed = true }
        categories = JobPool.sortCategories((filtersResult?["categories"]?.items ?? []).compactMap(\.stringValue))
        categoriesLoading = false
    }

    /// tab 数字与意向说明；新数字到之前保留旧的，tab 不闪空。
    private func loadCounts() async {
        guard !pendingSearch else { return }
        countsLoading = true
        let value = try? await session.api.careerRequest(path: "/api/job-pool/count", method: "GET", query: filterQuery, body: nil)
        guard !Task.isCancelled else { return }
        if let value { counts = value }
        countsLoading = false
    }

    private func loadFirst() async {
        guard let key = listKey, list?.key != key else { return }
        failedKey = nil; loadingMore = nil; moreFailed = nil
        let query = listQuery, mode = plaza.mode
        do {
            if mode == .job {
                let page = try await session.api.careerRequest(path: "/api/job-pool", method: "GET", query: query, body: nil)
                guard key == listKey else { return }
                list = PoolList(key: key, items: page["items"]?.items ?? [], cursor: page.text("next_cursor").nonEmptyValue)
            } else {
                let page = try await session.api.careerRequest(path: "/api/job-pool/by-company", method: "GET", query: query.merging(["page": "1"]) { $1 }, body: nil)
                guard key == listKey else { return }
                list = PoolList(key: key, items: page["items"]?.items ?? [],
                                page: JobPool.nextPage(1, pageSize: page["page_size"]?.integer ?? JobPool.companyPageSize, total: page["total"]?.integer ?? 0))
            }
        }
        catch is CancellationError {}
        catch APIError.unauthorized { if key == listKey { session.reportAuthenticationFailure(); failedKey = key } }
        catch { if !Task.isCancelled, key == listKey { failedKey = key } }
    }

    private func loadMore() async {
        guard let current = data, current.hasMore, loadingMore != current.key else { return }
        loadingMore = current.key; moreFailed = nil
        defer { if loadingMore == current.key { loadingMore = nil } }
        do {
            var query = listQuery
            if let cursor = current.cursor { query["cursor"] = cursor }
            if let page = current.page { query["page"] = "\(page)" }
            let page = try await session.api.careerRequest(path: plaza.mode == .job ? "/api/job-pool" : "/api/job-pool/by-company", method: "GET", query: query, body: nil)
            guard var latest = list, latest.key == current.key, latest.cursor == current.cursor, latest.page == current.page else { return }
            let known = Set(latest.items.map { $0.text("id") })
            latest.items += (page["items"]?.items ?? []).filter { !known.contains($0.text("id")) }
            if current.cursor != nil { latest.cursor = page.text("next_cursor").nonEmptyValue }
            if let number = current.page {
                latest.page = JobPool.nextPage(number, pageSize: page["page_size"]?.integer ?? JobPool.companyPageSize, total: page["total"]?.integer ?? 0)
            }
            list = latest
        } catch { if list?.key == current.key { moreFailed = current.key } }
    }

    private func joinJob(_ job: JSONValue) async {
        func patch(_ id: String, _ change: (JSONValue) -> JSONValue) {
            guard var latest = list else { return }
            latest.items = latest.items.map { $0.text("id") == id ? change($0) : $0 }
            list = latest
        }
        await join.join(job, api: session.api, open: openApplication,
            joined: { id, application in patch(id) { $0.with("joined_application_id", .string(application)) } },
            closed: { id in patch(id) { $0.with("availability_status", .string("closed")) } })
    }
}

/// 工具栏搜索框（`.pool-bar-search`）：白底细边框、圆角 8、32 高。
struct PoolSearchBox: View {
    @Binding var text: String
    let placeholder: String
    var width: CGFloat = 180
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(V3.fnt)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(V3.fnt)).textFieldStyle(.plain)
                .font(V3.sans(13)).foregroundStyle(V3.txt).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(V3.fnt2) }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10).frame(width: width, height: 32)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? V3.fnt2 : V3.cl))
    }
}

/// 01.01 岗位行：Logo 36 + 标题（今日新增 / 本轮未发现 / 已下线）、元信息行、两行摘要；
/// 悬停整行浮起为白底卡片，右上出现「去官网 ↗」与黑色胶囊「加入求职进程」；已加入的常显绿色「✓ 已加入求职进程 ›」。
private struct PlazaJobRow: View {
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
            HStack(alignment: .top, spacing: 14) {
                PoolLogo(name: job["company"]?.text("name") ?? "", url: job["company"]?.text("logo_url") ?? "", size: 36, filled: true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        poolTitle(job, keyword).font(V3.sans(15))
                            .foregroundStyle(closed ? V3.fnt : hover ? V3.blue : V3.txt).lineLimit(1)
                        if JobPool.isToday(job.text("new_at")) && !closed { badge("今日新增", V3.blue) }
                        if job.text("availability_status") == "missing" { badge("本轮未发现", V3.orange) }
                        if closed { badge("已下线", V3.fnt) }
                    }
                    .frame(height: 22).padding(.trailing, 240)
                    meta
                    if let summary = job.text("summary").nonEmptyValue {
                        poolHighlight(summary, keyword).font(V3.sans(13)).foregroundStyle(V3.fnt).lineSpacing(21 - 13 * 1.2).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("官网暂未提供岗位正文").font(V3.sans(13)).foregroundStyle(V3Skeleton.faint).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(hover ? Color.white : .clear)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(hover ? V3.line : .clear))
                .shadow(color: .black.opacity(hover ? 0.06 : 0), radius: 8, y: 3)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 16) {
                if let joined {
                    Button { openApplication(joined) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                            Text("已加入求职进程")
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        }.font(V3.sans(14)).foregroundStyle(Color(hex: 0x2E8B4E)).frame(height: 32)
                    }.buttonStyle(.plain).accessibilityLabel("已加入求职进程，打开求职记录")
                } else if hover {
                    if let url = URL(string: job.text("source_url")) {
                        Link(destination: url) {
                            HStack(spacing: 3) { Text("去官网"); Image(systemName: "arrow.up.right.square").font(.system(size: 11)) }
                                .font(V3.sans(14)).foregroundStyle(V3.txt)
                        }.buttonStyle(.plain)
                    }
                    if !closed {
                        Button(action: join) {
                            Text(joining == job.text("id") ? "正在加入…" : "加入求职进程").font(V3.sans(14, weight: .medium)).foregroundStyle(.white)
                                .padding(.horizontal, 16).frame(height: 32).background(V3.txt, in: Capsule())
                        }.buttonStyle(.plain).disabled(joining != nil).opacity(joining != nil && joining != job.text("id") ? 0.5 : 1)
                    }
                }
            }.padding(.top, 12).padding(.trailing, 16)
        }
        .onHover { hover = $0 }.animation(.easeOut(duration: 0.14), value: hover)
        .accessibilityElement(children: .contain)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(V3.sans(11.5, weight: .medium)).foregroundStyle(color).fixedSize()
    }

    /// 公司 | 📍城市 | 招聘类型 | 方向 | 发布时间：公司与城市为墨色，时间最淡。
    private var meta: some View {
        let company = job["company"]?.text("name") ?? ""
        let category = job.text("category")
        let time = JobPool.relative(job.text("published_at"))
        var parts: [AnyView] = [
            AnyView(poolHighlight(company, keyword).foregroundStyle(V3.txt)),
            AnyView(HStack(spacing: 3) {
                Image(systemName: "mappin").font(.system(size: 10))
                poolHighlight(JobPool.cityLabel(JobPool.cities(job)), keyword)
            }.foregroundStyle(V3.txt).help(JobPool.cities(job).joined(separator: "、"))),
            AnyView(Text(JobPool.recruitment(job))),
        ]
        if !category.isEmpty { parts.append(AnyView(Text(category))) }
        if !time.isEmpty { parts.append(AnyView(Text(time).foregroundStyle(V3.fnt))) }
        return PoolMetaLine(parts: parts).font(V3.sans(13)).foregroundStyle(V3.sub).frame(height: 18)
    }
}

/// 01.08 按公司看：Logo 32 + 公司名 / 行业，右上有新增时蓝字「今日 +N」；下行左侧符合条件的岗位数，右侧前三个城市各自的数量。
private struct PoolCompanyCard: View {
    let company: JSONValue
    let open: () -> Void
    @State private var hover = false
    var body: some View {
        let today = company["today_new"]?.integer ?? 0
        Button(action: open) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    PoolLogo(name: company.text("name"), url: company.text("logo_url"), size: 32, filled: true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(company.text("name")).font(V3.sans(14, weight: .medium)).foregroundStyle(hover ? V3.blue : V3.txt).lineLimit(1).frame(height: 22)
                        Text(company.text("industry")).font(V3.sans(12)).foregroundStyle(V3.fnt).lineLimit(1).frame(height: 18)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if today > 0 { Text("今日 +\(JobPool.grouped(today))").font(V3.sans(12)).foregroundStyle(V3.blue).fixedSize() }
                }.frame(height: 40)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(JobPool.grouped(company["match_count"]?.integer ?? 0)).font(V3.number(18, weight: .medium)).foregroundStyle(V3.txt)
                        Text("个符合").font(V3.sans(12)).foregroundStyle(V3.fnt)
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        ForEach(Array((company["cities"]?.items ?? []).prefix(3).enumerated()), id: \.offset) { _, city in
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(city.text("name")).foregroundStyle(V3.fnt)
                                Text(JobPool.grouped(city["count"]?.integer ?? 0)).font(V3.number(12, weight: .medium)).foregroundStyle(V3.sub)
                            }
                        }
                    }.font(V3.sans(12))
                }.frame(height: 24)
            }
            .padding(15).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(hover ? V3.cl : V3.line))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).onHover { hover = $0 }.animation(.easeOut(duration: 0.14), value: hover)
        .accessibilityLabel(company.text("name"))
    }
}
