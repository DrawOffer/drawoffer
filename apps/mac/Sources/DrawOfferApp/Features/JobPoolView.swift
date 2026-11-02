import SwiftUI
import DrawOfferCore

/// 岗位广场（Web `features/jobs/OpportunitiesPage.tsx`，Figma「12 · 官网岗位池」）：公司目录 → 公司岗位列表 → 岗位详情。
struct JobPoolView: View {
    struct Query: Hashable {
        var keyword = "", city = "", category = "", type = ""
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
    private var radius: CGFloat { [20: 5, 24: 6, 32: 7, 40: 9, 48: 10, 64: 12][size] ?? 6 }
    private var fontSize: CGFloat { [20: 10, 24: 12, 32: 14, 40: 16, 48: 19, 64: 24][size] ?? 12 }
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
        .frame(width: size, height: size).background(.white)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(V3.line))
        .accessibilityHidden(true)
    }
}

/// `BackCrumb`：「← 岗位广场 / 公司 / 当前页」。
private struct PoolCrumbs: View {
    let back: () -> Void
    var trail: [(String, () -> Void)] = []
    var current: String?
    var body: some View {
        HStack(spacing: 12) {
            Button(action: back) {
                HStack(spacing: 6) { Image(systemName: "arrow.left").font(.system(size: 13)); Text("岗位广场") }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("返回岗位广场")
            ForEach(Array(trail.enumerated()), id: \.offset) { _, item in
                Text("/").accessibilityHidden(true)
                Button(item.0, action: item.1).buttonStyle(.plain).lineLimit(1).fixedSize()
            }
            if let current, !current.isEmpty {
                Text("/").accessibilityHidden(true)
                Text(current).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(V3.sans(16)).foregroundStyle(V3.fnt).frame(height: 20).padding(.bottom, 12)
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
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.value) { item in
                let active = item.value == selection
                Button { change(item.value) } label: {
                    HStack(spacing: 6) {
                        Text(item.label).font(V3.sans(13, weight: active ? .medium : .regular))
                        if let count = item.count {
                            Text(verbatim: "\(count)").font(V3.number(11.5, weight: .regular)).foregroundStyle(active ? V3.blue.opacity(0.7) : V3.fnt)
                        }
                    }
                    .foregroundStyle(active ? V3.blue : V3.sub).padding(.horizontal, 12).frame(height: 30)
                    .background(active ? V3.blueSoft : .white, in: Capsule())
                    .overlay(Capsule().stroke(active ? V3.blue.opacity(0.35) : V3.cl))
                    .contentShape(Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(label)
    }
}

/// `Select size="sm"`：32 高白底描边下拉。
private struct PoolSelect: View {
    let label: String
    let value: String
    let options: [(String, String)]
    var placeholder: String?
    let change: (String) -> Void
    var body: some View {
        let current = options.first { $0.0 == value }?.1
        Menu {
            ForEach(options, id: \.0) { option in
                Button { change(option.0) } label: {
                    if option.0 == value { Label(option.1, systemImage: "checkmark") } else { Text(option.1) }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(current ?? placeholder ?? "").font(V3.sans(14)).foregroundStyle(current == nil ? V3.fnt2 : V3.txt).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(V3.fnt).frame(width: 12)
            }
            .padding(.horizontal, 12).frame(minWidth: 64, maxWidth: 160, minHeight: 32, maxHeight: 32, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel(label)
    }
}

/// `.pool-new`：今日新增 / 本轮未发现 小标签。
private struct PoolBadge: View {
    let text: String
    var warn = false
    var body: some View {
        Text(text).font(V3.sans(11.5, weight: .medium)).foregroundStyle(warn ? Color(hex: 0x8A4D12) : V3.blue)
            .padding(.horizontal, 7).frame(height: 20).background(warn ? V3.orangeSoft : V3.blueSoft, in: RoundedRectangle(cornerRadius: 4)).fixedSize()
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
            .sheet(item: $join.failure) { failure in
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

// MARK: - A · 公司目录

private struct JobPoolDirectory: View {
    @Environment(SessionStore.self) private var session
    let open: (String) -> Void
    @State private var data: JSONValue?
    @State private var failed = false
    @State private var revision = 0
    @State private var industry = ""
    @State private var text = ""
    @State private var sort = "open"

    private var companies: [JSONValue] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        let items = (data?["items"]?.items ?? []).filter { company in
            (industry.isEmpty || company.text("industry") == industry)
                && (needle.isEmpty || ([company.text("name")] + (company["aliases"]?.items ?? []).compactMap(\.stringValue)).contains { $0.lowercased().contains(needle) })
        }
        let open = { (item: JSONValue) in item["open_count"]?.integer ?? 0 }
        switch sort {
        case "today": return items.sorted { ($0["today_new"]?.integer ?? 0, open($0)) > ($1["today_new"]?.integer ?? 0, open($1)) }
        case "latest": return items.sorted { ($0.text("latest_at"), open($0)) > ($1.text("latest_at"), open($1)) }
        case "name": return items.sorted { $0.text("name").compare($1.text("name"), locale: Locale(identifier: "zh_CN")) == .orderedAscending }
        default: return items
        }
    }

    var body: some View {
        V3Page {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom, spacing: 24) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("OPPORTUNITIES · 企业官网直招").font(V3.sans(12, weight: .medium)).foregroundStyle(V3.fnt).frame(height: 18)
                        Text("岗位广场").font(V3.serif(28)).foregroundStyle(V3.txt).frame(height: 36).padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                    if let total = data?["total"] {
                        PoolStats(count: total["open_count"]?.integer ?? 0, today: total["today_new"]?.integer ?? 0, extra: "收录 \(total["company_count"]?.integer ?? 0) 家公司")
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    PoolChips(items: chipItems, selection: industry, label: "按行业筛选") { industry = $0 }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
                    V3SearchField(text: $text, placeholder: "搜索公司", width: 280, height: 34).accessibilityLabel("搜索公司")
                }.padding(.top, 22)
                content
            }
        }
        .task(id: revision) { await load() }
    }

    private var chipItems: [(value: String, label: String, count: Int?)] {
        let items = data?["items"]?.items ?? []
        let industries = (data?["industries"]?.items ?? []).compactMap(\.stringValue)
            .map { name in (value: name, label: name, count: Optional(items.filter { $0.text("industry") == name }.count)) }
            .filter { ($0.count ?? 0) > 0 }
        return [(value: "", label: "全部", count: data == nil ? nil : items.count)] + industries
    }

    @ViewBuilder private var content: some View {
        if failed {
            PoolError(title: "公司目录暂时无法加载", message: "网络不稳定或服务暂时不可用，稍后重试即可。") { revision += 1 }
        } else if data == nil {
            grid { ForEach(0..<9, id: \.self) { _ in skeletonCard } }.accessibilityLabel("正在加载公司目录…")
        } else if companies.isEmpty {
            let filtered = !industry.isEmpty || !text.trimmingCharacters(in: .whitespaces).isEmpty
            let summary = [industry, text.trimmingCharacters(in: .whitespaces)].filter { !$0.isEmpty }.joined(separator: " · ")
            PoolState(title: filtered ? "没有找到这家公司" : "暂时还没有收录公司",
                      message: filtered ? "换个公司名称，或切换到全部行业试试。" : "企业官网的岗位同步后会出现在这里，稍后再来看看。",
                      art: { PoolEmptyArt(summary: filtered ? summary : "企业官网直招") }) {
                if filtered { Button("清除筛选") { text = ""; industry = "" }.buttonStyle(V3ButtonStyle(kind: .dark)) }
            }
        } else {
            HStack {
                Text("共 \(companies.count) 家公司").font(V3.sans(12.5)).foregroundStyle(V3.fnt)
                Spacer()
                PoolSelect(label: "排序", value: sort, options: JobPool.sorts.map { ($0.value, $0.label) }) { sort = $0 }
            }.frame(minHeight: 44).padding(.top, 14)
            grid { ForEach(companies, id: \.self) { card($0) } }
        }
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: 3), spacing: 16, content: content)
            .padding(.top, 12).padding(.bottom, 40)
    }

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                PoolSkeleton(width: 40, height: 40, radius: 9)
                VStack(alignment: .leading, spacing: 3) { PoolSkeleton(width: 96, height: 14); PoolSkeleton(width: 56, height: 10) }
            }
            GeometryReader { box in PoolSkeleton(width: box.size.width * 0.45, height: 26) }.frame(height: 26)
            PoolSkeleton(width: nil, height: 12)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 16)
        .background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(V3.line))
    }

    private func card(_ company: JSONValue) -> some View {
        CompanyCard(company: company) { open(company.text("id")) }
    }

    private func load() async {
        failed = false
        do { data = try await session.api.careerRequest(path: "/api/job-pool/companies", method: "GET", query: [:], body: nil) }
        catch is CancellationError {}
        catch APIError.unauthorized { session.reportAuthenticationFailure(); failed = true }
        catch { failed = true }
    }
}

private struct CompanyCard: View {
    let company: JSONValue
    let open: () -> Void
    @State private var hover = false
    var body: some View {
        let today = company["today_new"]?.integer ?? 0
        Button(action: open) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    PoolLogo(name: company.text("name"), url: company.text("logo_url"), size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(company.text("name")).font(V3.sans(15, weight: .medium)).foregroundStyle(hover ? V3.blue : V3.txt).lineLimit(1)
                        Text(company.text("industry")).font(V3.sans(12)).foregroundStyle(V3.fnt)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if today > 0 { PoolBadge(text: "今日 +\(today)") }
                    else { Text("今日无新增").font(V3.sans(11.5)).foregroundStyle(V3.fnt2).fixedSize() }
                }
                HStack(alignment: .bottom, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(grouped(company["open_count"]?.integer ?? 0)).font(V3.number(26)).foregroundStyle(V3.txt)
                        Text("个在招岗位").font(V3.sans(12)).foregroundStyle(V3.fnt)
                    }
                    Spacer(minLength: 0)
                    trend((company["daily_new"]?.items ?? []).map(\.integer))
                }.frame(height: 37, alignment: .bottom)
                HStack(spacing: 0) {
                    ForEach(JobPool.types, id: \.value) { type in
                        let count = company["counts"]?[type.value]?.integer ?? 0
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(type.label).font(V3.sans(12)).foregroundStyle(V3.fnt)
                            if count > 0 { Text(grouped(count)).font(V3.number(13, weight: .medium)).foregroundStyle(V3.txt) }
                            else { Text("暂无").font(V3.sans(12)).foregroundStyle(V3.fnt2) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(height: 22).padding(.top, 13).overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(hover ? V3.cl : V3.line))
            .shadow(color: .black.opacity(hover ? 0.04 : 0), radius: 8, y: 4)
            .offset(y: hover ? -1 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).onHover { hover = $0 }.animation(.easeOut(duration: 0.16), value: hover)
        .accessibilityLabel(company.text("name"))
    }

    /// `.pool-trend`：近 7 天新增的小柱图，今天为蓝色。
    private func trend(_ values: [Int]) -> some View {
        let top = max(1, values.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                RoundedRectangle(cornerRadius: 2).fill(index == values.count - 1 ? V3.blue : V3.hl)
                    .frame(maxWidth: .infinity).frame(height: 28 * CGFloat(max(12, Int((Double(value) / Double(top) * 100).rounded()))) / 100)
            }
        }
        .frame(width: 84, height: 28, alignment: .bottom)
        .accessibilityElement().accessibilityLabel("近 7 天新增：" + values.map(String.init).joined(separator: "、"))
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
                V3Page {
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

    private var page: some View {
        V3Page {
            VStack(alignment: .leading, spacing: 0) {
                PoolCrumbs(back: root, current: name.isEmpty ? "公司" : name)
                head
                PoolChips(items: [(value: "", label: "全部方向", count: nil)] + (company?["categories"]?.items ?? []).map { (value: $0.text("name"), label: $0.text("name"), count: Optional($0["count"]?.integer ?? 0)) },
                          selection: query.category, label: "按方向筛选") { query.category = $0 }
                    .padding(.top, 22)
                resultBar
                if keywordError { PoolNote(text: JobPool.keywordError).padding(.top, 12) }
                list
            }
        }
    }

    @ViewBuilder private var head: some View {
        HStack(alignment: .bottom, spacing: 24) {
            if let company {
                HStack(spacing: 14) {
                    PoolLogo(name: company.text("name"), url: company.text("logo_url"), size: 48)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(company.text("name")).font(V3.serif(28)).foregroundStyle(V3.txt).frame(height: 36)
                        HStack(spacing: 10) {
                            Text(company.text("industry")).font(V3.sans(12)).foregroundStyle(V3.sub).padding(.horizontal, 7).frame(height: 20)
                                .background(V3.field, in: RoundedRectangle(cornerRadius: 4))
                            if let careers = company.text("careers_url").nonEmptyValue, let url = URL(string: careers) {
                                Link(destination: url) {
                                    HStack(spacing: 4) { Text(JobPool.host(careers)); Image(systemName: "arrow.up.right.square").font(.system(size: 10)) }
                                }.font(V3.sans(12.5)).foregroundStyle(V3.fnt)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                PoolStats(count: company["open_count"]?.integer ?? 0, today: company["today_new"]?.integer ?? 0)
            } else if companyState == "error" {
                PoolNote(text: "公司信息暂时无法加载。") {
                    Button("重试") { revision += 1 }.buttonStyle(.plain).font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.sub)
                }
            } else {
                HStack(spacing: 14) {
                    PoolSkeleton(width: 48, height: 48, radius: 10)
                    VStack(alignment: .leading, spacing: 8) { PoolSkeleton(width: 140, height: 24); PoolSkeleton(width: 90, height: 12) }
                }.accessibilityHidden(true)
                Spacer(minLength: 0)
            }
        }
    }

    private var tabs: [(value: String, label: String, count: Int?)] {
        let unclassified = company?["counts"]?["unclassified"]?.integer ?? 0
        var items: [(value: String, label: String, count: Int?)] = [(value: "", label: "全部", count: company?["open_count"]?.integer)]
        items += JobPool.types.map { (value: $0.value, label: $0.label, count: company?["counts"]?[$0.value]?.integer) }
        if unclassified > 0 || query.type == "unclassified" { items.append((value: "unclassified", label: "未分类", count: unclassified)) }
        return items
    }

    private var resultBar: some View {
        HStack(alignment: .bottom, spacing: 16) {
            HStack(spacing: 26) {
                ForEach(tabs, id: \.value) { tab in
                    let active = query.type == tab.value
                    Button { query.type = tab.value } label: {
                        HStack(spacing: 5) {
                            Text(tab.label).font(V3.sans(14, weight: active ? .medium : .regular)).foregroundStyle(active ? V3.txt : V3.sub)
                            if let count = tab.count { Text(grouped(count)).font(V3.number(12, weight: .regular)).foregroundStyle(V3.fnt) }
                        }
                        .frame(height: 36)
                        .overlay(alignment: .bottom) { if active { RoundedRectangle(cornerRadius: 1).fill(V3.txt).frame(height: 2) } }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .padding(.bottom, -7)
            .accessibilityElement(children: .contain).accessibilityLabel("招聘类型")
            Spacer(minLength: 0)
            // Web 的城市选择比搜索框低 4px，「清除筛选」顶端比搜索框低 6px，三者并非居中对齐。
            HStack(alignment: .top, spacing: 8) {
                if query.filtered {
                    Button("清除筛选", action: clear).buttonStyle(.plain).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.sub)
                        .frame(height: 20).padding(.top, 6).padding(.trailing, 6)
                }
                companySearch
                PoolSelect(label: "城市", value: query.city.isEmpty ? "" : query.city,
                           options: [("all", "全部城市")] + (company?["cities"]?.items ?? []).compactMap(\.stringValue).map { ($0, $0) },
                           placeholder: "城市") { query.city = $0 == "all" ? "" : $0 }
                    .padding(.top, 4)
            }
        }
        .frame(minHeight: 44, alignment: .bottom).padding(.bottom, 6).padding(.top, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(V3.cl).frame(height: 1) }
    }

    private var companySearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(V3.fnt)
            TextField("", text: $keyword, prompt: Text(name.isEmpty ? "搜索本公司岗位" : "搜索\(name)的岗位").foregroundStyle(V3.fnt))
                .textFieldStyle(.plain).font(V3.sans(14)).foregroundStyle(V3.txt)
                .onSubmit(submit).onChange(of: keyword) { keywordError = false }
        }
        .padding(.horizontal, 10).frame(width: 220, height: 32)
        .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl))
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
                    }.frame(height: 92).padding(.horizontal, 16).padding(.vertical, 20)
                }
            }.padding(.top, 8).padding(.horizontal, -16).accessibilityLabel("正在加载岗位…")
        } else if jobs.isEmpty {
            let summary = [query.keyword, query.category, JobPool.types.first { $0.value == query.type }?.label ?? "", query.city].filter { !$0.isEmpty }.joined(separator: " · ")
            PoolState(title: query.filtered ? "没有符合条件的岗位" : "这家公司暂时没有在招岗位",
                      message: query.filtered ? "换个关键词，或减少方向、类型、城市的筛选条件试试。" : "官网的岗位同步后会出现在这里，稍后再来看看。",
                      art: { PoolEmptyArt(summary: summary.isEmpty ? name : summary) }) {
                if query.filtered { Button("清除筛选", action: clear).buttonStyle(V3ButtonStyle(kind: .dark)) }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(jobs, id: \.self) { job in
                    PoolJobRow(job: job, joining: join.joiningID, open: { openJob(job.text("id")) },
                               openApplication: openApplication, join: { Task { await joinJob(job) } })
                }
            }.padding(.top, 8).padding(.horizontal, -16)
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

    private func clear() { keyword = ""; keywordError = false; query = JobPoolView.Query() }

    private func submit() {
        let text = keyword.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty && (text.count < 2 || text.count > 100) { keywordError = true; return }
        keywordError = false
        query.keyword = text
    }

    private func params(cursor: String? = nil) -> [String: String] {
        var result = ["company_ids": companyID]
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
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    (Text(job.text("title")) + Text(job.text("department").nonEmptyValue.map { " - " + $0 } ?? ""))
                        .font(V3.sans(16, weight: .medium)).foregroundStyle(closed ? V3.fnt : hover ? V3.blue : V3.txt).lineLimit(1).frame(height: 22)
                    if JobPool.isToday(job.text("new_at")) { PoolBadge(text: "今日新增") }
                    if job.text("availability_status") == "missing" { PoolBadge(text: "本轮未发现", warn: true) }
                }.padding(.trailing, 220).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    ForEach(Array(JobPool.meta(job).enumerated()), id: \.offset) { index, part in
                        if index > 0 { Rectangle().fill(V3.cl).frame(width: 1, height: 11).padding(.horizontal, 10) }
                        Text(part)
                    }
                }.font(V3.sans(13)).foregroundStyle(V3.sub).lineLimit(1).frame(height: 22)
                if let summary = job.text("summary").nonEmptyValue {
                    // 两行 × 22 行高（`-webkit-line-clamp: 2`）
                    Text(summary).font(V3.sans(13)).foregroundStyle(V3.fnt).lineSpacing(22 - 13 * 1.2).lineLimit(2)
                        .frame(height: 44, alignment: .center).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hover ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(hover ? 0.06 : 0), radius: 7, y: 2)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 14) {
                if let joined {
                    Button { openApplication(joined) } label: {
                        HStack(spacing: 4) { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)); Text("已加入求职进程") }
                            .font(V3.sans(12, weight: .medium)).foregroundStyle(Color(hex: 0x2E7D50))
                            .padding(.horizontal, 10).padding(.vertical, 3).background(V3.greenSoft, in: Capsule())
                    }.buttonStyle(.plain)
                } else {
                    if let url = URL(string: job.text("source_url")) {
                        Link(destination: url) {
                            HStack(spacing: 3) { Text("官网"); Image(systemName: "arrow.up.right.square").font(.system(size: 10)) }
                        }.font(V3.sans(12.5, weight: .medium)).foregroundStyle(V3.sub)
                    }
                    if !closed {
                        Button(joining == job.text("id") ? "正在加入…" : "加入求职进程", action: join)
                            .buttonStyle(V3ButtonStyle(kind: .dark, height: 28)).font(V3.sans(12)).disabled(joining != nil)
                    }
                }
            }
            .padding(.top, 14).padding(.trailing, 16)
            .opacity(hover || joined != nil ? 1 : 0)
        }
        .onHover { hover = $0 }.animation(.easeOut(duration: 0.16), value: hover)
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
        V3Page(bottom: 48) {
            VStack(alignment: .leading, spacing: 0) {
                switch state {
                case "missing":
                    PoolCrumbs(back: root, current: "岗位不存在")
                    PoolState(title: "没有找到这个岗位", message: "岗位可能已被移除，或链接不完整。", width: 314, stage: 96,
                              art: { PoolUnavailableArt(tag: "链接已失效") }) {
                        Button("返回岗位广场", action: root).buttonStyle(.plain).font(V3.sans(14, weight: .medium)).foregroundStyle(V3.link)
                    }
                case "error":
                    PoolCrumbs(back: root, current: "岗位详情")
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
            HStack(alignment: .top, spacing: 40) {
                main(job, companyID: companyID, companyName: companyName).frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                side(job, companyID: companyID, companyName: companyName).frame(width: 320)
            }
        }
    }

    private func facts(_ job: JSONValue) -> [(String, String)] {
        [("工作城市", JobPool.cities(job).joined(separator: "、")), ("招聘类型", JobPool.jobType(job)), ("岗位方向", job.text("category")),
         ("招聘项目", JobPool.attribute(job, "batch") ?? ""), ("毕业届别", JobPool.attribute(job, "graduation_year") ?? ""),
         ("学历要求", JobPool.attribute(job, "education_requirement") ?? ""), ("经验要求", JobPool.attribute(job, "experience_requirement") ?? ""),
         ("薪资", job.text("salary_text")), ("投递截止", JobPool.attribute(job, "deadline") ?? "")].filter { !$0.1.isEmpty }
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
                    PoolLogo(name: companyName, url: job["company"]?.text("logo_url") ?? "", size: 24)
                    Text(companyName).font(V3.sans(13)).foregroundStyle(V3.sub)
                }
            }.buttonStyle(.plain)
            (Text(job.text("title")) + Text(job.text("department").nonEmptyValue.map { " - " + $0 } ?? ""))
                .font(.system(size: 26, weight: .semibold)).foregroundStyle(V3.txt).lineHeight(26, 37.7)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 18)
            HStack(spacing: 12) {
                if JobPool.isToday(job.text("new_at")) && !closed { PoolBadge(text: "今日新增") }
                HStack(spacing: 6) { Circle().fill(status.0).frame(width: 6, height: 6); Text(status.1).font(V3.sans(12.5, weight: .medium)) }.foregroundStyle(status.0)
                if let published { Text(published).font(V3.sans(12.5)).foregroundStyle(V3.fnt) }
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
                    Button { Task { await joinJob(job) } } label: {
                        if join.joiningID == job.text("id") { Text("正在加入…").frame(maxWidth: .infinity) }
                        else { HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)); Text("加入求职进程") }.frame(maxWidth: .infinity) }
                    }.buttonStyle(V3ButtonStyle(kind: .dark, height: 36, width: 280)).disabled(join.joiningID != nil)
                    if let source { officialButton(source) }
                    hint("加入后在投递看板跟进投递进度、安排面试。", link: nil)
                }
                if deadline != nil || sourceID != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        if let deadline { row("投递截止") { Text(deadline) } }
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
            HStack(spacing: 6) { Text("去官网投递"); Image(systemName: "arrow.up.right.square").font(.system(size: 11)) }
                .font(V3.sans(14, weight: .medium)).foregroundStyle(V3.txt).frame(maxWidth: .infinity).frame(height: 36)
                .background(.white, in: Capsule()).overlay(Capsule().stroke(V3.cl)).contentShape(Capsule())
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
