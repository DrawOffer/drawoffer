import Foundation
import DrawOfferCore
import SwiftUI

/// 全部面试记录（Figma 09 · 04 · 04.01 按岗位分组、04.02 展开中途放弃、04.03 空态、04.04 筛选；Web `v2/RecordsPage.tsx`）：
/// 右上按全部 / 真实面试 / 模拟练习筛选；按投递分组成卡片，组头是公司、岗位和接下来最近的一场，没挂投递的归“专项与通用练习”；
/// 中途放弃的收在最后，展开后是同样的卡片，可以按原设置重新开始。
struct MockRecordsV2: View {
    @Environment(SessionStore.self) private var session
    /// 后台导入推进了一步就重读（Web `subscribeMockInterviews`）。
    @Environment(RecordImports.self) private var recordImports: RecordImports?
    let back: () -> Void
    let openReport: (String) -> Void
    let open: (String) -> Void
    /// 真实面试的复盘在投递那一边（会话 id、投递 id）。
    var openReal: (String, String?) -> Void = { _, _ in }
    var startFirst: () -> Void = {}

    @State private var overview: JSONValue?
    @State private var failed = false
    @State private var unfolded = false
    @State private var filter = "all"
    /// 打开导入弹窗；带着会话 id 时先选中那一场（「补录面试题」）
    @State private var importing: MockImportRequest?
    @State private var notice: MockNotice?
    @State private var tick = 0

    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }
    private static let tabs = [("all", "全部"), ("real", "真实面试"), ("mock", "模拟练习")]

    var body: some View {
        let empty = overview.map { MockRecords.kept($0).isEmpty && MockRecords.abandoned($0, filter: "all").isEmpty } ?? false
        GeometryReader { geometry in
            let barWidth = min(991, geometry.size.width - 160), bodyWidth = min(760, geometry.size.width - 48)
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        MockBackCrumb(label: "模拟面试", action: back)
                        Spacer(minLength: 0)
                        Button("导入真实面试") { importing = MockImportRequest() }.buttonStyle(MockLinkStyle(size: 13, color: Color(hex: 0x57534E))).fontWeight(.medium)
                    }
                    .frame(width: barWidth, height: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 24) {
                            Text("全部面试记录").font(V3.serif(30)).foregroundStyle(MockPalette.ink).lineHeight(30, 40, .serif)
                            Spacer(minLength: 0)
                            if let overview, !empty { tabs(MockRecords.counts(overview)).frame(maxHeight: .infinity, alignment: .bottom) }
                        }
                        .frame(height: 58, alignment: .top)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xECEBE9)).frame(height: 1) }
                        if overview == nil && !failed {
                            V3Loading("正在加载面试记录…").frame(maxWidth: .infinity).padding(.top, 120)
                        } else if failed && overview == nil {
                            HStack(spacing: 4) {
                                Text("记录没有加载出来。").font(V3.sans(14)).foregroundStyle(Color(hex: 0x8C8680))
                                Button("重新加载") { tick += 1 }.buttonStyle(MockLinkStyle(size: 14, color: Color(hex: 0x2563EB)))
                            }.padding(.top, 24)
                        } else if let overview {
                            if empty { emptyState } else { list(overview) }
                        }
                    }
                    .frame(width: bodyWidth).padding(.top, 20)
                }
                .frame(maxWidth: .infinity).padding(.top, 38).padding(.bottom, 56)
            }
        }
        .background(.white)
        .overlay { MockNoticeToast(notice: $notice) }
        .task(id: "\(account):\(tick)") { await load() }
        .onChange(of: recordImports?.changed) { _, _ in tick += 1 }
        .centeredPanel(item: $importing) { request in
            MockImportDialog(sessionID: request.sessionID, close: { importing = nil }, done: {
                importing = nil
                // Web `onDone`：关弹窗、重读；进度在铃铛里，页面不再弹提示
                tick += 1
            })
        }
    }

    private func tabs(_ counts: [String: Int]) -> some View {
        HStack(spacing: 20) {
            ForEach(Self.tabs, id: \.0) { key, label in
                let on = filter == key
                Button { filter = key } label: {
                    Text(verbatim: "\(label) \(counts[key] ?? 0)").font(V3.sans(13, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? MockPalette.ink : Color(hex: 0x8C8680)).frame(height: 18).padding(.top, 6).frame(height: 32, alignment: .top)
                        .overlay(alignment: .bottom) { Rectangle().fill(on ? MockPalette.ink : .clear).frame(height: 2) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .offset(y: 1)
    }

    @ViewBuilder private func list(_ overview: JSONValue) -> some View {
        let sections = MockRecords.sections(overview, filter: filter)
        let abandoned = MockRecords.abandoned(overview, filter: filter)
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sections, id: \.key) { section in
                let title = MockRecords.splitTitle(section.title)
                MockRecordGroup {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: title.company).font(V3.sans(15, weight: .bold)).foregroundStyle(MockPalette.ink)
                        if let job = title.job { Text(verbatim: job).font(V3.sans(13)).foregroundStyle(Color(hex: 0x57534E)).lineLimit(1) }
                    }
                    Spacer(minLength: 24)
                    if let next = MockRecords.nextLabel(section.next) {
                        HStack(spacing: 5) {
                            if next.soon { Circle().fill(Color(hex: 0xD97706)).frame(width: 5, height: 5) }
                            Text(verbatim: next.text).font(V3.sans(12, weight: next.soon ? .medium : .regular)).foregroundStyle(Color(hex: next.soon ? 0x57534E : 0x8C8680))
                        }
                    }
                } rows: {
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { index, record in
                        MockRecordRow(record: record, divider: index > 0) { tap(record) }
                    }
                }
                .accessibilityLabel(section.title)
            }
            if !abandoned.isEmpty {
                if unfolded {
                    MockRecordGroup {
                        Text(verbatim: "中途放弃的 \(abandoned.count) 场").font(V3.sans(13)).foregroundStyle(Color(hex: 0x57534E))
                        Spacer(minLength: 24)
                        foldButton("收起", up: true) { unfolded = false }
                    } rows: {
                        ForEach(Array(abandoned.enumerated()), id: \.offset) { index, record in
                            MockRecordOffRow(record: record, divider: index > 0) { Task { await repeatInterview(record.text("id")) } }
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        Text(verbatim: "另有 \(abandoned.count) 场中途放弃").font(V3.sans(12.5)).foregroundStyle(Color(hex: 0xA8A29E))
                        foldButton("展开", up: false) { unfolded = true }
                    }
                    .padding(.leading, 4).padding(.top, 4)
                }
            }
        }
        .padding(.top, 21)
    }

    private func foldButton(_ title: String, up: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) { Text(verbatim: title); Image(systemName: up ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)) }
                .font(V3.sans(12.5, weight: .medium)).foregroundStyle(Color(hex: 0x2563EB)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 空态（Figma 09 · 04.03）。
    private var emptyState: some View {
        VStack(spacing: 0) {
            Text("还没有面试记录").font(V3.serif(18)).foregroundStyle(MockPalette.ink).lineHeight(18, 26, .serif)
            Text("练完一场模拟面试或导入真实面试后，会在这里按岗位归档。").font(V3.sans(12.5)).foregroundStyle(Color(hex: 0x8C8680)).padding(.top, 10)
            Button("开始第一场模拟面试", action: startFirst).buttonStyle(MockPillStyle(height: 40, padding: 24, size: 13)).padding(.top, 16)
        }
        .frame(maxWidth: .infinity).frame(minHeight: 420)
    }

    private func tap(_ record: JSONValue) {
        if record.text("kind") == "real" && record["unrecorded"]?.bool == true { importing = MockImportRequest(sessionID: record.display("id")); return }
        // 复盘还没生成，详情页没有可看的内容，留在列表里提示
        if record.text("status") == "reviewing" { notice = MockNotice(kind: .queued, title: "复盘还在生成", message: "好了这一行会显示分数，到时再点开看"); return }
        if record.text("kind") == "mock" { openReport(record.text("id")) } else { openReal(record.text("id"), record.text("application_id").nonEmptyValue) }
    }

    private func load() async {
        guard !account.isEmpty else { return }
        do {
            let value = try await session.api.careerRequest(path: "/api/mock-interviews/overview", method: "GET", query: [:], body: nil)
            if Task.isCancelled { return }
            overview = value; failed = false
        } catch { if !Task.isCancelled { failed = true } }
    }

    private func repeatInterview(_ id: String) async {
        do {
            let result = try await session.api.careerRequest(path: "/api/mock-interviews/\(id)/repeat", method: "POST", query: [:], body: nil)
            open(result["mock_interview"]?.display("id") ?? "")
        } catch { notice = MockNotice(title: "没有开始新的一场", message: MockInterviewText.error(error)) }
    }
}

/// 打开导入弹窗的请求；sessionID 是要先选中的那一场。
struct MockImportRequest: Identifiable {
    let id = UUID()
    var sessionID: String? = nil
}

/// `.mr3-group`：圆角 12 的卡片，43 高的浅底组头，下面一行行记录。
private struct MockRecordGroup<Head: View, Rows: View>: View {
    @ViewBuilder var head: () -> Head
    @ViewBuilder var rows: () -> Rows
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) { head() }.padding(.horizontal, 20).frame(height: 43)
                .background(Color(hex: 0xFAFAF8)).overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xF0EFEA)).frame(height: 1) }
            rows()
        }
        .background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xEAE8E3)))
        .accessibilityElement(children: .contain)
    }
}

/// 记录里的一行：标题 + 真实面试 / 模拟练习标签，下面日期、类型、题数、卡在哪；右边分数和与上一场的分差。
/// 一题都没答的没有复盘可看，这一行不能点。
private struct MockRecordRow: View {
    let record: JSONValue
    let divider: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        let blank = record["answered"]?.bool == false
        let unrecorded = record["unrecorded"]?.bool == true
        let real = record.text("kind") == "real"
        let score = record["score"]?.numberValue
        Button(action: action) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(verbatim: MockRecords.rowTitle(record)).font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.ink).lineLimit(1)
                        MockRecordTag(text: real ? "真实面试" : "模拟练习", real: real)
                    }
                    Text(verbatim: unrecorded ? "\(MockHome.mmdd(record.text("at"))) · 还没记录被问到的题" : MockRecords.rowSub(record))
                        .font(V3.sans(12.5)).foregroundStyle(Color(hex: unrecorded ? 0xB45309 : 0x8C8680)).lineLimit(1).frame(height: 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if blank { wait("没有作答") }
                else if unrecorded { Text("补录面试题 ›").font(V3.sans(12.5, weight: .medium)).foregroundStyle(Color(hex: 0x2563EB)) }
                else if record.text("status") == "reviewing" { wait("复盘生成中…") }
                else if let score {
                    let delta = record["delta"]?.numberValue.map { Int($0) } ?? 0
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(verbatim: "\(Int(score))").font(V3.sans(17, weight: .semibold)).foregroundStyle(Int(score) < MockRecords.lowScore ? Color(hex: 0xC27803) : MockPalette.ink)
                        Text("分").font(V3.sans(12)).foregroundStyle(Color(hex: 0xA8A29E))
                        if delta != 0 {
                            Text(verbatim: delta > 0 ? "+\(delta)" : "\(delta)").font(V3.sans(12, weight: .medium)).foregroundStyle(Color(hex: delta > 0 ? 0x15803D : 0x8C8680)).padding(.leading, 6)
                        }
                        Text("›").font(V3.sans(14)).foregroundStyle(Color(hex: 0xC4C0BA)).padding(.leading, 6)
                    }
                } else { wait("—") }
            }
            .padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 66)
            .background(hover && !blank ? Color(hex: 0xFCFCFB) : .white)
            .overlay(alignment: .top) { if divider { Rectangle().fill(Color(hex: 0xF4F3F1)).frame(height: 1).padding(.horizontal, 20) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(blank).onHover { hover = $0 }
        .accessibilityElement(children: .combine)
    }
    private func wait(_ text: String) -> some View { Text(verbatim: text).font(V3.sans(12.5)).foregroundStyle(Color(hex: 0xA8A29E)) }
}

/// 中途放弃的一行：灰标题 + 未完成，模拟面试可以按原设置重新开始。
private struct MockRecordOffRow: View {
    let record: JSONValue
    let divider: Bool
    let restart: () -> Void
    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: record.text("title")).font(V3.sans(14)).foregroundStyle(Color(hex: 0x57534E)).lineLimit(1)
                    MockRecordTag(text: "未完成", real: false)
                }
                Text(verbatim: [MockHome.mmdd(record.text("at")), record.text("type_label").nonEmptyValue, "中途放弃"].compactMap { $0 }.joined(separator: " · "))
                    .font(V3.sans(12.5)).foregroundStyle(Color(hex: 0x8C8680)).lineLimit(1).frame(height: 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if record.text("kind") == "mock" {
                Button("按原设置重新开始 ›", action: restart).buttonStyle(MockLinkStyle(size: 12.5, color: Color(hex: 0x2563EB))).fontWeight(.medium)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 66).background(.white)
        .overlay(alignment: .top) { if divider { Rectangle().fill(Color(hex: 0xF4F3F1)).frame(height: 1).padding(.horizontal, 20) } }
    }
}

private struct MockRecordTag: View {
    let text: String
    let real: Bool
    var body: some View {
        Text(verbatim: text).font(V3.sans(11, weight: .medium)).foregroundStyle(Color(hex: real ? 0xB45309 : 0x57534E))
            .padding(.horizontal, 7).frame(height: 20).background(Color(hex: real ? 0xFEF7EC : 0xF4F3F0), in: RoundedRectangle(cornerRadius: 5)).fixedSize()
    }
}
