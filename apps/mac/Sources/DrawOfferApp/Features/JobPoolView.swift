import SwiftUI
import DrawOfferCore

/// 岗位广场（Web `features/jobs/OpportunitiesPage.tsx`）：公司目录 → 公司岗位列表 → 岗位详情。
/// macOS 稿 06 · 岗位广场：目录按 03「紧凑公司卡片与分页」（82:22919），公司页与详情按 02 重构提案（82:22733 的 B、C）。
struct JobPoolView: View {
    struct Query: Hashable {
        var keyword = "", city = "", category = "", type = ""
        /// 岗位排序：`published` 最新发布（默认）/ `collected` 最新收录；不算筛选条件。
        var sort = "published"
        var filtered: Bool { !keyword.isEmpty || !city.isEmpty || !category.isEmpty || !type.isEmpty }
    }
    enum Route: Hashable { case company(String, Query), job(String) }

    let openApplication: (String) -> Void
    @State private var path: [Route] = []

    var body: some View {
        Group {
            switch path.last {
            case nil:
                JobPoolDirectory(open: { path.append(.company($0, Query())) })
            case .company(let id, let query)?:
                JobPoolCompany(companyID: id, initial: query, root: { path = [] }, openJob: { path.append(.job($0)) }, openApplication: openApplication)
                    .id(id + "\(query.hashValue)")
            case .job(let id)?:
                JobPoolJob(jobID: id, root: { path = [] },
                           openCompany: { company, query in path = [.company(company, query)] },
                           openJob: { path.append(.job($0)) }, openApplication: openApplication)
                    .id(id)
            }
        }
    }
}

// MARK: - 共用

private extension JSONValue {
    func with(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = self else { return self }
        fields[key] = value
        return .object(fields)
    }
}

private func grouped(_ value: Int) -> String {
    let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.locale = Locale(identifier: "zh_CN")
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

/// `PoolCompanyLogo`：公开的公司图标，缺图或加载失败时回退首字。
struct PoolLogo: View {
    @Environment(SessionStore.self) private var session
    let name: String
    let url: String
    var size: CGFloat = 24
    /// 目录紧凑卡片（82:4233）的首字底为 #F4F4F2、无描边；其余位置白底细描边。
    var filled = false
    private var radius: CGFloat { [20: 5, 24: 6, 32: 8, 40: 9, 48: 10, 56: 12, 64: 12][size] ?? 6 }
    private var fontSize: CGFloat { [20: 10, 24: 12, 32: 14, 40: 16, 48: 19, 56: 22, 64: 24][size] ?? 12 }
    private var source: URL? {
        guard url.hasPrefix("/api/company-logos/"), let origin = (session.api as? HTTPAPIClient)?.origin else { return nil }
        return URL(string: url, relativeTo: origin)?.absoluteURL
    }
    private var initial: String { String(name.trimmingCharacters(in: .whitespaces).prefix(1)).nonEmptyValue ?? "企" }
    var body: some View {
        AsyncImage(url: source) { phase in
            if let image = phase.image { image.resizable().scaledToFit() }
            else { Text(initial).font(V3.sans(fontSize, weight: .medium)).foregroundStyle(Color(hex: 0x454842)) }
        }
        .frame(width: size, height: size).background(filled ? V3.field : .white)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(filled ? .clear : V3.cl))
        .accessibilityHidden(true)
    }
}

/// 82:1848 面包屑：「岗位广场 / 公司 / 当前页」11.5px，前几级灰色可点、当前页墨黑。
private struct PoolCrumbs: View {
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

/// `.pool-figure`：在招总数，下面一行今日新增。
private struct PoolStats: View {
    let count: Int
    let today: Int
    var extra: String?
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(grouped(count)).font(V3.number(28)).foregroundStyle(V3.txt)
                Text("个在招岗位").font(V3.sans(12.5)).foregroundStyle(V3.fnt)
            }.frame(height: 31)
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(today > 0 ? V3.blue : V3.fnt2).frame(width: 6, height: 6)
                    Text("今日新增 \(grouped(today))")
                }.foregroundStyle(today > 0 ? V3.blue : V3.fnt)
                if let extra { Text(" · " + extra).foregroundStyle(V3.fnt) }
            }.font(V3.sans(12)).frame(height: 23)
        }.fixedSize()
    }
}

/// `.pool-chips`：胶囊筛选。
private struct PoolChips: View {
    let items: [(value: String, label: String, count: Int?)]
    let selection: String
    let label: String
    let change: (String) -> Void
    var body: some View {
        // macOS 稿：筛选标签是一排 ScopeButton（无描边，选中 10% 黑底），数量并进文字。
        FlowLayout(spacing: 4) {
            ForEach(items, id: \.value) { item in
                V3ScopeButton(label: item.count.map { "\(item.label) \($0)" } ?? item.label, selected: item.value == selection) { change(item.value) }
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(label)
    }
}

/// macOS 稿 PopUpButton：原生 NSPopUpButton（`Picker` + `.menu`），没有值时显示占位。
private struct PoolSelect: View {
    let label: String
    let value: String
    let options: [(String, String)]
    var placeholder: String?
    let change: (String) -> Void
    var body: some View {
        Picker(label, selection: Binding(get: { value }, set: { change($0) })) {
            if !options.contains(where: { $0.0 == value }) { Text(placeholder ?? label).tag(value) }
            ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
        }
        .pickerStyle(.menu).labelsHidden().fixedSize().accessibilityLabel(label)
    }
}

/// `.pool-new`：今日新增 / 本轮未发现 小标签。
private struct PoolBadge: View {
    let text: String
    var warn = false
    var body: some View {
        // 82:22526：17 高、10.5px、圆角 4
        Text(text).font(V3.sans(10.5, weight: .medium)).foregroundStyle(warn ? Color(hex: 0x8A4D12) : V3.blue)
            .padding(.horizontal, 7).frame(height: 17).background(warn ? V3.orangeSoft : V3.blueSoft, in: RoundedRectangle(cornerRadius: 4)).fixedSize()
    }
}

private struct PoolSkeleton: View {
    let width: CGFloat?
    let height: CGFloat
    var radius: CGFloat = 4
    var body: some View {
        RoundedRectangle(cornerRadius: radius).fill(V3.line).frame(width: width, height: height)
    }
}

/// `.pool-note`：浅色提示条，警告时为橙色。
private struct PoolNote<Trailing: View>: View {
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
private struct PoolState<Art: View, Actions: View>: View {
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

private struct PoolError: View {
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

// MARK: - 插图（坐标照 Web `PoolArt.tsx`）

/// `PoolEmptyArt`：带当前条件的搜索框 + 清除角标，下面三行虚线空位。
private struct PoolEmptyArt: View {
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
private struct PoolUnavailableArt: View {
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

private struct PoolJoinFeedback: ViewModifier {
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
                        V3DotStage(height: failure.closed ? 128 : 128) {
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

// MARK: - A · 公司目录（03 · 紧凑公司卡片与分页 82:22920）

private struct JobPoolDirectory: View {
    @Environment(SessionStore.self) private var session
    let open: (String) -> Void
    /// 一次请求的全部条件；`.task(id:)` 以它为键，回包只在键仍是当前条件时生效（最后一次为准）。
    struct DirectoryRequest: Hashable { var page = 1, q = "", industry = "", sort = "open", revision = 0 }
    @State private var data: JSONValue?
    @State private var loadedKey: DirectoryRequest?
    @State private var failedKey: DirectoryRequest?
    @State private var revision = 0
    @State private var industry = ""
    @State private var text = ""
    /// 防抖后真正提交给服务端的搜索词（Web `useDebouncedValue(text.trim(), 250)`）。
    @State private var appliedText = ""
    @State private var sort = "open"
    @State private var page = 1
    /// 82:5188 分页规则：每页 20 家；筛选、搜索或排序后回到第 1 页。分页、搜索、行业与排序都在服务端 `companies/page` 完成。
    static let pageSize = 20

    private var request: DirectoryRequest { DirectoryRequest(page: page, q: appliedText, industry: industry, sort: sort, revision: revision) }
    private var trimmedText: String { String(text.trimmingCharacters(in: .whitespaces).prefix(100)) }
    private var pendingSearch: Bool { trimmedText != appliedText }
    private var failed: Bool { !pendingSearch && failedKey == request }
    private var busy: Bool { pendingSearch || loadedKey != request }
    private var items: [JSONValue] { data?["items"]?.items ?? [] }
    private var total: Int { data?["total"]?.integer ?? 0 }
    private var pageCount: Int { max(1, (total + Self.pageSize - 1) / Self.pageSize) }

    var body: some View {
        V3Page(top: 50) {
            VStack(alignment: .leading, spacing: 0) {
                // 页头：眉题 + 衬线标题；右侧在招总数与今日新增
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("OPPORTUNITIES · 企业官网直招").font(V3.sans(12)).foregroundStyle(V3.sub).frame(height: 14)
                        Text("岗位广场").font(V3.serif(28)).foregroundStyle(V3.txt).frame(height: 40).padding(.top, 14)
                    }
                    Spacer(minLength: 0)
                    if let summary = data?["summary"] {
                        PoolStats(count: summary["open_count"]?.integer ?? 0, today: summary["today_new"]?.integer ?? 0, extra: "收录 \(summary["company_count"]?.integer ?? 0) 家公司")
                            .padding(.top, 22)
                    }
                }
                // 行业 ScopeBar（距标题 47）
                PoolChips(items: chipItems, selection: industry, label: "按行业筛选") { industry = $0; page = 1 }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 47)
                content
            }
        }
        // 搜索输入防抖 250ms；提交新词时回到第 1 页。
        .task(id: trimmedText) {
            let next = trimmedText
            guard next != appliedText else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, next == trimmedText else { return }
            appliedText = next; page = 1
        }
        .task(id: request) { await load(request) }
    }

    private var chipItems: [(value: String, label: String, count: Int?)] {
        // 行业计数描述整份目录，与当前筛选和页码无关（`industries` 只含有公司的行业）。
        let industries = (data?["industries"]?.items ?? []).map { (value: $0.text("name"), label: $0.text("name"), count: Optional($0["count"]?.integer ?? 0)) }
        return [(value: "", label: "全部", count: data?["summary"]?["company_count"]?.integer)] + industries
    }

    /// 结果栏（距 ScopeBar 35）：左「共 N 家公司」，右排序 PopUpButton 与搜索框。
    private var resultBar: some View {
        HStack(spacing: 12) {
            Text(failed ? "公司目录暂时无法加载" : busy ? "正在查询公司…" : "共 \(total) 家公司")
                .font(V3.sans(12.5)).foregroundStyle(V3.fnt)
            Spacer(minLength: 0)
            PoolSelect(label: "排序", value: sort, options: JobPool.sorts.map { ($0.value, $0.label) }) { sort = $0; page = 1 }
            V3SearchField(text: $text, placeholder: "搜索公司名称或别名", width: 260).accessibilityLabel("搜索公司")
        }.frame(height: 28).padding(.top, 33)
    }

    @ViewBuilder private var content: some View {
        resultBar
        if failed {
            PoolError(title: "公司目录暂时无法加载", message: "网络不稳定或服务暂时不可用，筛选条件已保留。") { revision += 1 }
        } else if busy {
            grid { ForEach(0..<9, id: \.self) { _ in skeletonCard } }.accessibilityLabel("正在加载公司目录…")
        } else if items.isEmpty {
            let filtered = !industry.isEmpty || !appliedText.isEmpty
            let summary = [industry, appliedText].filter { !$0.isEmpty }.joined(separator: " · ")
            PoolState(title: filtered ? "没有找到这家公司" : "暂时还没有收录公司",
                      message: filtered ? "换个公司名称，或切换到全部行业试试。" : "企业官网的岗位同步后会出现在这里，稍后再来看看。",
                      art: { PoolEmptyArt(summary: filtered ? summary : "企业官网直招") }) {
                if filtered {
                    Button { text = ""; appliedText = ""; industry = ""; page = 1 } label: { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)); Text("清除筛选") }
                        .buttonStyle(V3ButtonStyle(kind: .ghost))
                }
            }
        } else {
            grid { ForEach(items, id: \.self) { company in CompanyCard(company: company) { open(company.text("id")) } } }
            if pageCount > 1 {
                V3Pagination(page: min(page, pageCount), total: total, pageSize: Self.pageSize) { page = $0 }
                    .padding(.horizontal, 20).padding(.top, 16)
            }
        }
    }

    /// 82:4227：三列 → 两列 → 单列，卡片高 112、间距 12。
    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], spacing: 12, content: content)
            .padding(.top, 14)
    }

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                PoolSkeleton(width: 32, height: 32, radius: 8)
                VStack(alignment: .leading, spacing: 5) { PoolSkeleton(width: 96, height: 13); PoolSkeleton(width: 56, height: 10) }
            }.frame(height: 40)
            HStack { PoolSkeleton(width: 80, height: 18); Spacer(); PoolSkeleton(width: 120, height: 12) }.frame(height: 27).padding(.top, 16)
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12).frame(height: 112)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.cl))
    }

    private func load(_ key: DirectoryRequest) async {
        guard !pendingSearch else { return }
        failedKey = nil
        var query = ["page": "\(key.page)", "page_size": "\(Self.pageSize)", "sort": key.sort]
        if !key.q.isEmpty { query["q"] = key.q }
        if !key.industry.isEmpty { query["industry"] = String(key.industry.prefix(100)) }
        do {
            let value = try await session.api.careerRequest(path: "/api/job-pool/companies/page", method: "GET", query: query, body: nil)
            guard !Task.isCancelled, key == request else { return }
            // 目录在两次翻页之间变短：当前页已越界时退到最后一页重新请求。
            let last = max(1, ((value["total"]?.integer ?? 0) + Self.pageSize - 1) / Self.pageSize)
            if (value["items"]?.items ?? []).isEmpty, last < key.page { page = last; return }
            data = value; loadedKey = key
        }
        catch is CancellationError {}
        catch APIError.unauthorized { if key == request { session.reportAuthenticationFailure(); failedKey = key } }
        catch { if !Task.isCancelled, key == request { failedKey = key } }
    }
}

/// 82:4975 紧凑公司卡片（112 高）：Logo 32 + 公司名 13 / 行业 11，右上仅有新增时显示蓝字「今日 +N」；
/// 下行左侧在招总数，右侧校招 / 实习分项（为零直接写 0）。悬停公司名变蓝，不加底色与阴影。
private struct CompanyCard: View {
    let company: JSONValue
    let open: () -> Void
    @State private var hover = false
    var body: some View {
        let today = company["today_new"]?.integer ?? 0
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    PoolLogo(name: company.text("name"), url: company.text("logo_url"), size: 32, filled: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(company.text("name")).font(V3.sans(13, weight: .medium)).foregroundStyle(hover ? V3.blue : V3.txt).lineLimit(1).frame(height: 17)
                        Text(company.text("industry")).font(V3.sans(11)).foregroundStyle(V3.fnt).lineLimit(1).frame(height: 14)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if today > 0 { Text("今日 +\(grouped(today))").font(V3.sans(11.5)).foregroundStyle(V3.blue).fixedSize() }
                }.frame(height: 40)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(grouped(company["open_count"]?.integer ?? 0)).font(.system(size: 20)).monospacedDigit().foregroundStyle(V3.txt)
                    Text("在招").font(V3.sans(11.5)).foregroundStyle(V3.fnt).padding(.leading, 5)
                    Spacer(minLength: 8)
                    HStack(alignment: .firstTextBaseline, spacing: 13) {
                        ForEach(JobPool.types, id: \.value) { type in
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(type.label).font(V3.sans(11.5)).foregroundStyle(V3.fnt)
                                Text(grouped(company["counts"]?[type.value]?.integer ?? 0)).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(V3.sub)
                            }
                        }
                    }
                }.frame(height: 27).padding(.top, 16)
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(V3.cl))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).onHover { hover = $0 }.animation(.easeOut(duration: 0.12), value: hover)
        .accessibilityLabel(company.text("name"))
    }
}

// MARK: - B · 公司页 · 岗位列表

private struct JobPoolCompany: View {
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

    /// 02 · B 公司页（82:22740）：面包屑距顶 40 → 公司头（Logo 56）→ 方向 ScopeBar 与本公司搜索 → 分隔线 → 类型分段与城市 → 岗位列表。
    private var page: some View {
        V3Page(top: 38) {
            VStack(alignment: .leading, spacing: 0) {
                PoolCrumbs(back: root, current: name.isEmpty ? "公司" : name)
                head.padding(.top, 18)
                HStack(alignment: .center, spacing: 16) {
                    PoolChips(items: [(value: "", label: "全部", count: company?["open_count"]?.integer)] + (company?["categories"]?.items ?? []).map { (value: $0.text("name"), label: $0.text("name"), count: Optional($0["count"]?.integer ?? 0)) },
                              selection: query.category, label: "按方向筛选") { query.category = $0 }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    companySearch
                }.padding(.top, 37)
                Rectangle().fill(V3.line).frame(height: 1).padding(.top, 20)
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
                        Text(company.text("name")).font(.system(size: 24, weight: .semibold)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 31)
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
            } else if companyState == "error" {
                PoolNote(text: "公司信息暂时无法加载。") {
                    Button("重试") { revision += 1 }.buttonStyle(.plain).font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.sub)
                }
            } else {
                HStack(spacing: 18) {
                    PoolSkeleton(width: 56, height: 56, radius: 12)
                    VStack(alignment: .leading, spacing: 10) { PoolSkeleton(width: 140, height: 24); PoolSkeleton(width: 90, height: 12) }
                }.accessibilityHidden(true)
                Spacer(minLength: 0)
            }
        }.frame(minHeight: 56, alignment: .top)
    }

    private var tabs: [(value: String, label: String, count: Int?)] {
        let unclassified = company?["counts"]?["unclassified"]?.integer ?? 0
        var items: [(value: String, label: String, count: Int?)] = [(value: "", label: "全部", count: company?["open_count"]?.integer)]
        items += JobPool.types.map { (value: $0.value, label: $0.label, count: company?["counts"]?[$0.value]?.integer) }
        if unclassified > 0 || query.type == "unclassified" { items.append((value: "unclassified", label: "未分类", count: unclassified)) }
        return items
    }

    /// 类型分段（82:22740 的 Segmented：#F4F4F2 槽、选中白底）与右侧清除筛选、城市 PopUpButton；距分隔线 13。
    private var resultBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element.value) { index, tab in
                    let active = query.type == tab.value
                    let nextActive = index + 1 < tabs.count && query.type == tabs[index + 1].value
                    Button { query.type = tab.value } label: {
                        HStack(spacing: 5) {
                            Text(tab.label).foregroundStyle(V3.txt)
                            if let count = tab.count { Text(grouped(count)).monospacedDigit().foregroundStyle(active ? V3.sub : V3.fnt) }
                        }
                        .font(V3.sans(12.5, weight: active ? .medium : .regular))
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(active ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .shadow(color: .black.opacity(active ? 0.12 : 0), radius: 0.5, y: 0.5)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
                    if index + 1 < tabs.count {
                        Rectangle().fill(active || nextActive ? .clear : V3.sk2).frame(width: 1, height: 12)
                    }
                }
            }
            .padding(2).background(V3.field, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .contain).accessibilityLabel("招聘类型")
            Spacer(minLength: 0)
            if query.filtered {
                Button("清除筛选", action: clear).buttonStyle(.plain).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub).padding(.trailing, 4)
            }
            PoolSelect(label: "城市", value: query.city.isEmpty ? "" : query.city,
                       options: [("all", "全部城市")] + (company?["cities"]?.items ?? []).compactMap(\.stringValue).map { ($0, $0) },
                       placeholder: "城市") { query.city = $0 == "all" ? "" : $0 }
            // 82:22740：城市右侧的排序 PopUpButton（`GET /api/job-pool?sort=published|collected`）
            PoolSelect(label: "排序", value: query.sort, options: [("published", "最新发布"), ("collected", "最新收录")]) { query.sort = $0 }
        }
        .frame(height: 26).padding(.top, 13)
    }

    /// 本公司搜索（macOS SearchField 观感，回车提交）。
    private var companySearch: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(V3.fnt)
            TextField("", text: $keyword, prompt: Text(name.isEmpty ? "搜索本公司岗位" : "搜索\(name)的岗位").foregroundStyle(V3.fnt))
                .textFieldStyle(.plain).font(V3.sans(13)).foregroundStyle(V3.txt)
                .onSubmit(submit).onChange(of: keyword) { keywordError = false }
        }
        .padding(.horizontal, 8).frame(width: 220, height: 28)
        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel("搜索本公司岗位")
    }

    @ViewBuilder private var list: some View {
        if failed {
            PoolError(title: "岗位暂时无法加载", message: "网络不稳定或服务暂时不可用，筛选条件已保留。") { revision += 1 }
        } else if loading {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<6, id: \.self) { _ in
                    GeometryReader { box in
                        VStack(alignment: .leading, spacing: 10) {
                            PoolSkeleton(width: box.size.width * 0.38, height: 16); PoolSkeleton(width: box.size.width * 0.3, height: 12)
                            PoolSkeleton(width: box.size.width * 0.92, height: 12); PoolSkeleton(width: box.size.width * 0.7, height: 12)
                        }
                    }.frame(height: 92).padding(.horizontal, 20).padding(.vertical, 22)
                }
            }.padding(.top, 10).padding(.horizontal, -20).accessibilityLabel("正在加载岗位…")
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(jobs, id: \.self) { job in
                    PoolJobRow(job: job, joining: join.joiningID, open: { openJob(job.text("id")) },
                               openApplication: openApplication, join: { Task { await joinJob(job) } })
                }
            }.padding(.top, 10).padding(.horizontal, -20)
            Group {
                if moreFailed {
                    HStack(spacing: 0) {
                        Text("加载失败，")
                        Button("重试") { Task { await loadMore() } }.buttonStyle(.plain).font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.link)
                    }
                } else if loadingMore { Text("正在加载…") }
                else if cursor != nil { Button("加载更多") { Task { await loadMore() } }.buttonStyle(V3ButtonStyle(kind: .ghost)) }
                else { Text("没有更多了") }
            }
            .font(V3.sans(12.5)).foregroundStyle(V3.fnt).frame(maxWidth: .infinity, minHeight: 64)
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
        companyState = "loading"
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
        loading = false
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

/// 82:1919 岗位条目：标题「岗位名 - 团队」16 中粗 + 今日新增；细竖线分隔的属性行；灰色简介最多两行。
/// 列表无分隔线、靠留白区分；悬停整条浮起为白底圆角 12 卡片，右侧出现「官网 ↗」与唯一黑色胶囊「加入求职进程」；
/// 已加入的条目右侧常显灰色「✓ 已加入求职进程」。
private struct PoolJobRow: View {
    let job: JSONValue
    let joining: String?
    let open: () -> Void
    let openApplication: (String) -> Void
    let join: () -> Void
    @State private var hover = false

    var body: some View {
        let closed = job.text("availability_status") == "closed"
        let joined = job.text("joined_application_id").nonEmptyValue
        let meta = JobPool.meta(job)
        let fresh = JobPool.isToday(job.text("published_at"))
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    (Text(job.text("title")) + Text(job.text("department").nonEmptyValue.map { " - " + $0 } ?? ""))
                        .font(V3.sans(16, weight: .medium)).foregroundStyle(closed ? V3.fnt : hover ? V3.blue : V3.txt).lineLimit(1).frame(height: 22)
                    if JobPool.isToday(job.text("new_at")) { PoolBadge(text: "今日新增") }
                    if job.text("availability_status") == "missing" { PoolBadge(text: "本轮未发现", warn: true) }
                }
                HStack(spacing: 0) {
                    ForEach(Array(meta.enumerated()), id: \.offset) { index, part in
                        if index > 0 { Rectangle().fill(V3.cl).frame(width: 1, height: 11).padding(.horizontal, 10) }
                        // 发布时间是今天时用蓝字点睛
                        Text(part).foregroundStyle(fresh && index == meta.count - 1 ? V3.blue : V3.sub)
                    }
                }.font(V3.sans(13)).lineLimit(1).frame(height: 16).padding(.top, 14)
                if let summary = job.text("summary").nonEmptyValue {
                    // 最多两行（行高 19），超出以省略号截断
                    Text(summary).font(V3.sans(12.5)).foregroundStyle(V3.fnt).lineSpacing(19 - 12.5 * 1.2).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 17)
                }
            }
            .padding(.trailing, 230)
            .padding(.horizontal, 20).padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .leading)
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
        .overlay(alignment: .trailing) {
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
            }.padding(.trailing, 20)
        }
        .onHover { hover = $0 }.animation(.easeOut(duration: 0.14), value: hover)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - C · 岗位详情

private struct JobPoolJob: View {
    @Environment(SessionStore.self) private var session
    let jobID: String
    let root: () -> Void
    let openCompany: (String, JobPoolView.Query) -> Void
    let openJob: (String) -> Void
    let openApplication: (String) -> Void

    @State private var job: JSONValue?
    @State private var state = "loading"
    @State private var company: JSONValue?
    @State private var related: [JSONValue] = []
    @State private var copied = false
    @State private var revision = 0
    @State private var join = PoolJoin()

    var body: some View {
        // 02 · C 岗位详情（82:22736）：左正文 680、右侧吸附操作栏 326，间距 41。
        V3Page(top: 38, bottom: 48) {
            VStack(alignment: .leading, spacing: 0) {
                switch state {
                case "missing":
                    PoolCrumbs(back: root, current: "岗位不存在").padding(.bottom, 12)
                    PoolState(title: "没有找到这个岗位", message: "岗位可能已被移除，或链接不完整。", width: 314, stage: 96,
                              art: { PoolUnavailableArt(tag: "链接已失效") }) {
                        Button("返回岗位广场", action: root).buttonStyle(.plain).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.link)
                    }
                case "error":
                    PoolCrumbs(back: root, current: "岗位详情").padding(.bottom, 12)
                    PoolError(title: "岗位详情暂时无法加载", message: "网络不稳定或服务暂时不可用，稍后重试即可。") { revision += 1 }
                default:
                    if let job { detail(job) } else { skeleton }
                }
            }
        }
        .task(id: revision) { await load() }
        .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(1.6)); copied = false } }
        .modifier(PoolJoinFeedback(join: join, open: openApplication, retry: { job in Task { await joinJob(job) } }))
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            PoolSkeleton(width: 180, height: 12); PoolSkeleton(width: 96, height: 14)
            PoolSkeleton(width: 350, height: 30, radius: 6); PoolSkeleton(width: 245, height: 12)
            PoolSkeleton(width: 700, height: 56); PoolSkeleton(width: 80, height: 16)
            PoolSkeleton(width: 630, height: 12); PoolSkeleton(width: 560, height: 12)
        }.accessibilityLabel("正在加载岗位详情…")
    }

    private func detail(_ job: JSONValue) -> some View {
        let companyID = job["company"]?.text("id") ?? ""
        let companyName = job["company"]?.text("name") ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            PoolCrumbs(back: root, trail: [(companyName, { openCompany(companyID, JobPoolView.Query()) })], current: job.text("title"))
            HStack(alignment: .top, spacing: 41) {
                main(job, companyID: companyID, companyName: companyName).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 24)
                side(job, companyID: companyID, companyName: companyName).frame(width: 326).padding(.top, 18)
            }
        }
    }

    private func facts(_ job: JSONValue) -> [(String, String)] {
        [("工作城市", JobPool.cities(job).joined(separator: "、")), ("招聘类型", JobPool.jobType(job)), ("岗位方向", job.text("category")),
         ("招聘项目", JobPool.attribute(job, "batch") ?? ""), ("毕业届别", JobPool.attribute(job, "graduation_year") ?? ""),
         ("学历要求", JobPool.attribute(job, "education_requirement") ?? ""), ("经验要求", JobPool.attribute(job, "experience_requirement") ?? ""),
         ("薪资", job.text("salary_text")), ("投递截止", JobPool.attribute(job, "deadline").map { PoolSync.deadline($0)?.date ?? $0 } ?? "")].filter { !$0.1.isEmpty }
    }

    private func main(_ job: JSONValue, companyID: String, companyName: String) -> some View {
        let closed = job.text("availability_status") == "closed"
        let missing = job.text("availability_status") == "missing"
        let status: (Color, String) = closed ? (V3.fnt, "已从官网下线") : missing ? (V3.orange, "本轮未发现") : (Color(hex: 0x2E7D50), "官网在招")
        let published = job.text("published_at").nonEmptyValue.map { "官网 \(JobPool.date($0)) 发布" }
        let facts = facts(job)
        return VStack(alignment: .leading, spacing: 0) {
            Button { openCompany(companyID, JobPoolView.Query()) } label: {
                HStack(spacing: 8) {
                    PoolLogo(name: companyName, url: job["company"]?.text("logo_url") ?? "", size: 20)
                    Text(companyName).font(V3.sans(12.5)).foregroundStyle(V3.sub)
                }
            }.buttonStyle(.plain)
            (Text(job.text("title")) + Text(job.text("department").nonEmptyValue.map { " - " + $0 } ?? ""))
                .font(.system(size: 26, weight: .semibold)).foregroundStyle(V3.txt).lineHeight(26, 37.7)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            HStack(spacing: 12) {
                if JobPool.isToday(job.text("new_at")) && !closed { PoolBadge(text: "今日新增") }
                HStack(spacing: 6) { Circle().fill(status.0).frame(width: 6, height: 6); Text(status.1).font(V3.sans(12.5, weight: .medium)) }.foregroundStyle(status.0)
                if let published { Text(published).font(V3.sans(12.5)).foregroundStyle(V3.fnt) }
                if let synced = job["source"]?.text("last_complete_at").nonEmptyValue.flatMap(PoolSync.text) {
                    Text("· 官网 \(synced) 同步").font(V3.sans(12.5)).foregroundStyle(V3.fnt)
                }
            }.frame(height: 22).padding(.top, 10)
            if !closed && missing {
                PoolNote(text: "本轮同步未发现该岗位，暂时保留；请到官网确认招聘状态。", icon: true).padding(.top, 16)
            }
            if !facts.isEmpty {
                FlowLayout(spacing: 0) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fact.0).font(V3.sans(12)).foregroundStyle(V3.fnt).frame(height: 20)
                            Text(fact.1).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).frame(height: 24)
                        }
                        .padding(.leading, index == 0 ? 0 : 20).padding(.trailing, 20)
                        .overlay(alignment: .leading) { if index > 0 { Rectangle().fill(V3.line).frame(width: 1) } }
                    }
                }
                .padding(.vertical, 17).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(V3.line).frame(height: 1) }
                .padding(.top, 22)
            }
            body(job.text("description"))
            HStack(spacing: 16) {
                Text("内容同步自\(companyName)招聘官网，投递要求与最新状态以官网为准。")
                Spacer(minLength: 0)
                if let url = URL(string: job.text("source_url")) {
                    Link(destination: url) { HStack(spacing: 3) { Text("查看原文"); Image(systemName: "arrow.up.right.square").font(.system(size: 10)) } }
                        .font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub)
                }
            }
            .font(V3.sans(12)).foregroundStyle(V3.fnt).frame(height: 21).padding(.top, 15)
            .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
            .padding(.top, 36)
        }
    }

    /// `JobBody`：已知小标题分段，编号行对齐成 01、02 要点。
    @ViewBuilder private func body(_ text: String) -> some View {
        let sections = JobPool.sections(text)
        VStack(alignment: .leading, spacing: 0) {
            if sections.isEmpty {
                section("岗位描述") { paragraph("官网暂未提供岗位正文，请查看招聘官网。") }
            } else {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, item in
                    section(item.title) {
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in
                            switch block {
                            case .paragraph(let line): paragraph(line)
                            case .points(let points):
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                                        HStack(alignment: .top, spacing: 0) {
                                            Text(index + 1 < 10 ? "0\(index + 1)" : "\(index + 1)").font(V3.number(12)).foregroundStyle(V3.fnt2)
                                                .frame(width: 28, alignment: .leading).padding(.top, 4)
                                            Text(point).font(V3.sans(14)).foregroundStyle(Color(hex: 0x3A3A36)).lineSpacing(7)
                                                .frame(minHeight: 24).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }.padding(.top, 12)
                            }
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 22)
            content()
        }.padding(.top, 30)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).font(V3.sans(14)).foregroundStyle(Color(hex: 0x3A3A36)).lineSpacing(7)
            .frame(minHeight: 24).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
    }

    private func side(_ job: JSONValue, companyID: String, companyName: String) -> some View {
        let closed = job.text("availability_status") == "closed"
        let joined = job.text("joined_application_id").nonEmptyValue
        let deadline = JobPool.attribute(job, "deadline")
        let sourceID = job.text("source_job_id").nonEmptyValue
        let source = URL(string: job.text("source_url"))
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                if let joined {
                    statusBlock("已加入求职进程", check: true)
                    if let source { officialButton(source) }
                    hint(closed ? "岗位已从官网下线，已有记录仍可管理。" : "可在投递看板跟进投递和面试。", link: ("在投递看板查看 →", { openApplication(joined) }))
                } else if closed {
                    statusBlock("岗位已从官网下线", check: false)
                    hint("以下为收录时的内容，无法再加入求职进程。", link: ("查看\(companyName)的其他岗位 →", { openCompany(companyID, JobPoolView.Query()) }))
                } else {
                    // 82:1541 操作卡 · 未加入：整宽 40 高墨黑主按钮（圆角 8）
                    Button { Task { await joinJob(job) } } label: {
                        Text(join.joiningID == job.text("id") ? "正在加入…" : "加入求职进程").font(V3.sans(13.5, weight: .medium)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 40).background(V3.txt, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(join.joiningID != nil).opacity(join.joiningID != nil ? 0.6 : 1)
                    if let source { officialButton(source) }
                    hint("加入后在投递看板跟进投递进度、安排面试。", link: nil)
                }
                if deadline != nil || sourceID != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        if let deadline {
                            // 截止日「11月30日 · 还剩 N 天」；无法解析或已过期只写日期
                            let parsed = PoolSync.deadline(deadline)
                            row("投递截止") { Text([parsed?.date ?? deadline, parsed?.left].compactMap { $0 }.joined(separator: " · ")) }
                        }
                        if let sourceID {
                            row("职位 ID") {
                                Text(sourceID).font(V3.number(12.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                                Button(copied ? "已复制" : "复制") {
                                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sourceID, forType: .string); copied = true
                                }.buttonStyle(.plain).font(V3.sans(12)).foregroundStyle(V3.link)
                            }
                        }
                    }
                    .padding(.top, 14).overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }.padding(.top, 6)
                }
            }
            .padding(20).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.line))
            if let company { companyCard(company) }
            if !related.isEmpty { relatedList(job, companyID: companyID) }
        }
    }

    private func statusBlock(_ text: String, check: Bool) -> some View {
        HStack(spacing: 6) {
            if check { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
            Text(text).font(V3.sans(14, weight: .medium))
        }
        .foregroundStyle(check ? Color(hex: 0x2E7D50) : V3.fnt).frame(maxWidth: .infinity).frame(height: 40)
        .background(check ? V3.greenSoft : V3.field, in: RoundedRectangle(cornerRadius: 8))
    }

    private func officialButton(_ url: URL) -> some View {
        Link(destination: url) {
            Text("去官网投递 ↗").font(V3.sans(13.5, weight: .medium)).foregroundStyle(V3.txt).frame(maxWidth: .infinity).frame(height: 40)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private func hint(_ text: String, link: (String, () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).lineHeight(12, 18).fixedSize(horizontal: false, vertical: true)
            if let link { Button(link.0, action: link.1).buttonStyle(.plain).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.link) }
        }.font(V3.sans(12)).foregroundStyle(V3.fnt).padding(.top, 2)
    }

    private func row<Value: View>(_ label: String, @ViewBuilder _ value: () -> Value) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(V3.fnt)
            Spacer(minLength: 0)
            HStack(spacing: 10) { value() }.foregroundStyle(V3.txt).font(V3.sans(12.5, weight: .medium))
        }.font(V3.sans(12.5)).frame(height: 21)
    }

    private func companyCard(_ company: JSONValue) -> some View {
        let today = company["today_new"]?.integer ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                PoolLogo(name: company.text("name"), url: company.text("logo_url"), size: 40)
                VStack(alignment: .leading, spacing: 0) {
                    Text(company.text("name")).font(V3.sans(15, weight: .medium)).foregroundStyle(V3.txt).frame(height: 26)
                    Text(company.text("industry")).font(V3.sans(12)).foregroundStyle(V3.fnt).frame(height: 20)
                }
            }
            HStack(spacing: 12) {
                HStack(spacing: 0) { Text(grouped(company["open_count"]?.integer ?? 0)).font(V3.number(13)).foregroundStyle(V3.txt); Text(" 个在招") }
                if today > 0 { Text("今日 +\(today)").foregroundStyle(V3.blue) }
                Spacer(minLength: 0)
                Button("全部岗位 →") { openCompany(company.text("id"), JobPoolView.Query()) }
                    .buttonStyle(.plain).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.txt)
            }
            .font(V3.sans(12)).foregroundStyle(V3.fnt).frame(height: 22).padding(.top, 13)
            .overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
        }
        .padding(20).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.line))
    }

    private func relatedList(_ job: JSONValue, companyID: String) -> some View {
        let category = job.text("category")
        let same = (company?["categories"]?.items ?? []).first { $0.text("name") == category }?["count"]?.integer
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("同方向岗位").font(.system(size: 14, weight: .semibold)).foregroundStyle(V3.txt).frame(height: 24)
                Spacer()
                if !category.isEmpty {
                    Button("全部\(same.map { " \($0) 个" } ?? "") →") { openCompany(companyID, JobPoolView.Query(category: category)) }
                        .buttonStyle(.plain).font(V3.sans(12)).foregroundStyle(V3.fnt)
                }
            }.padding(.top, 8).padding(.bottom, 4)
            ForEach(Array(related.enumerated()), id: \.offset) { index, item in
                Button { openJob(item.text("id")) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        (Text(item.text("title")) + Text(item.text("department").nonEmptyValue.map { " - " + $0 } ?? ""))
                            .font(V3.sans(13.5)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 23)
                        Text([JobPool.cities(item).first ?? "", JobPool.recruitment(item), JobPool.relative(item.text("published_at"))].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(V3.sans(12)).foregroundStyle(V3.fnt).frame(height: 20)
                    }.padding(.top, 13).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { if index > 0 { Rectangle().fill(V3.line).frame(height: 1) } }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("同方向岗位")
    }

    private func load() async {
        state = "loading"
        do {
            let value = try await session.api.careerRequest(path: "/api/job-pool/\(jobID)", method: "GET", query: [:], body: nil)
            job = value; state = "ready"
        } catch is CancellationError { return }
        catch APIError.server(_, let code) where code == "JOB_POOL_NOT_FOUND" { state = "missing"; return }
        catch { state = "error"; return }
        // 侧栏卡片是附加信息：失败时直接不显示。
        guard let companyID = job?["company"]?.text("id").nonEmptyValue else { return }
        company = try? await session.api.careerRequest(path: "/api/job-pool/companies/\(companyID)", method: "GET", query: [:], body: nil)
        var query = ["company_ids": companyID]
        if let category = job?.text("category").nonEmptyValue { query["job_category"] = category }
        if let page = try? await session.api.careerRequest(path: "/api/job-pool", method: "GET", query: query, body: nil) {
            related = Array((page["items"]?.items ?? []).filter { $0.text("id") != jobID }.prefix(4))
        }
    }

    private func joinJob(_ value: JSONValue) async {
        await join.join(value, api: session.api, open: openApplication,
            joined: { _, application in job = job?.with("joined_application_id", .string(application)) },
            closed: { _ in job = job?.with("availability_status", .string("closed")) })
    }
}


/// 06 · 岗位广场：同步时间与投递截止的展示。
enum PoolSync {
    /// 今天只写「HH:mm」，其余写「今天/昨天/日期 HH:mm」（`JobPool.date`）。
    static func text(_ value: String) -> String? {
        guard let date = CareerApplication.date(value) else { return nil }
        return Beijing.calendar.isDateInToday(date) ? CareerDeckFormat.clock(date) : JobPool.date(value)
    }

    /// `deadline` 为 YYYY-MM-DD：返回「11月30日」与「还剩 N 天 / 今天截止」，已过期时 left 为 nil。
    static func deadline(_ value: String, now: Date = Date()) -> (date: String, left: String?)? {
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        let calendar = Beijing.calendar
        guard parts.count == 3, let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        let left = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: day).day ?? 0
        let thisYear = parts[0] == calendar.component(.year, from: now)
        let text = (thisYear ? "" : "\(parts[0])年") + "\(parts[1])月\(parts[2])日"
        return (text, left > 0 ? "还剩 \(left) 天" : left == 0 ? "今天截止" : nil)
    }
}
