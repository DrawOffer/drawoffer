import Foundation
import DrawOfferCore
import SwiftUI

/// 全部记录（Figma 09 · 08.01 列表、08.02 空状态、08.03 展开放弃的场次；Web `v2/RecordsPage.tsx`）：
/// 模拟和真实面试放在一张表里，每一场卡在哪都能看到；开始后放弃的场次合成最后一行，展开后可以用同样设置重来。
/// 版式跟其他列表页一样走公共页面宽度，从顶部往下排。
struct MockRecordsV2: View {
    @Environment(SessionStore.self) private var session
    let back: () -> Void
    let openReport: (String) -> Void
    let open: (String) -> Void
    /// 真实面试的复盘在投递那一边（会话 id、投递 id）。
    var openReal: (String, String?) -> Void = { _, _ in }
    var startFirst: () -> Void = {}

    @State private var overview: JSONValue?
    @State private var failed = false
    @State private var unfolded = false
    @State private var importing = false
    @State private var notice: MockNotice?
    @State private var tick = 0

    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }

    var body: some View {
        let records = overview?["records"]?.items ?? []
        let rows = records.filter { $0.text("status") != "abandoned" }
        let abandoned = records.filter { $0.text("status") == "abandoned" }
        let empty = overview != nil && rows.isEmpty && abandoned.isEmpty
        V3Page {
            VStack(alignment: .leading, spacing: 0) {
                MockBackCrumb(label: "模拟面试", action: back).padding(.bottom, 20)
                HStack(alignment: .bottom, spacing: 24) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: overview.map { heading(rows, $0["tallies"]?["score"]) } ?? "全部记录").font(V3.serif(28)).foregroundStyle(MockPalette.ink).lineHeight(28, 36, .serif)
                        Text("每一场卡在哪，都在这里。").font(V3.sans(14)).foregroundStyle(MockPalette.sub).frame(height: 22).padding(.top, 8)
                    }
                    Spacer(minLength: 0)
                    Button("导入面试记录") { importing = true }.buttonStyle(MockPillStyle(kind: .ghost, height: 32, padding: 21, size: 13))
                }
                if overview == nil && !failed {
                    V3Loading("正在加载练习记录…").frame(maxWidth: .infinity).padding(.top, 120)
                } else if empty {
                    emptyState.padding(.top, 40)
                } else {
                    table(rows, abandoned)
                }
            }
        }
        .background(.white)
        .overlay { MockNoticeToast(notice: $notice) }
        .task(id: "\(account):\(tick)") { await load() }
        .centeredSheet(isPresented: $importing) {
            MockImportDialog(close: { importing = false }, done: {
                importing = false
                notice = MockNotice(kind: .queued, title: "已开始生成复盘", message: "好了会出现在这里，也会记进长期记忆")
                tick += 1
            })
        }
    }

    // MARK: 表格

    private func table(_ rows: [JSONValue], _ abandoned: [JSONValue]) -> some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    head("时间", x: 0); head("面试", x: w * 0.1163); head("卡在", x: w * 0.4581)
                    Text("分数").font(V3.sans(12.5)).foregroundStyle(MockPalette.fnt).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 54)
                }
                .frame(height: 26, alignment: .top)
                .overlay(alignment: .bottom) { Rectangle().fill(MockPalette.cl).frame(height: 1) }
                if failed && overview == nil {
                    HStack(spacing: 8) {
                        Text("记录没有加载出来。").font(V3.sans(13)).foregroundStyle(MockPalette.fnt)
                        Button("重新加载") { tick += 1 }.buttonStyle(MockLinkStyle(blue: true))
                    }.padding(.top, 20)
                }
                ForEach(rows, id: \.self) { item in MockRecordRow(item: item, width: w) { tap(item) } }
                if !abandoned.isEmpty {
                    Button(unfolded ? "收起" : "另有 \(abandoned.count) 场开始后放弃 · 展开") { unfolded.toggle() }
                        .buttonStyle(MockLinkStyle()).frame(height: 46)
                        .accessibilityValue(unfolded ? "已展开" : "已收起")
                }
                if unfolded {
                    ForEach(abandoned, id: \.self) { item in
                        ZStack(alignment: .topLeading) {
                            Text(verbatim: MockHomeV2.mmdd(item.text("at"))).font(V3.sans(13.5)).foregroundStyle(MockPalette.mute).offset(y: 22)
                            Text(verbatim: item.text("title")).font(V3.sans(14)).foregroundStyle(MockPalette.fnt).lineLimit(1)
                                .frame(width: w * 0.4884, alignment: .leading).offset(x: w * 0.1163, y: 12)
                            Text(verbatim: item.text("subtitle")).font(V3.sans(13)).foregroundStyle(MockPalette.mute).lineLimit(1).offset(x: w * 0.1163, y: 34)
                            Button("用同样设置重来 ›") { Task { await repeatInterview(item.text("id")) } }.buttonStyle(MockLinkStyle(blue: true))
                                .frame(maxWidth: .infinity, alignment: .trailing).offset(y: 22)
                        }
                        .frame(height: 64, alignment: .topLeading)
                        .overlay(alignment: .bottom) { Rectangle().fill(MockPalette.line).frame(height: 1) }
                    }
                }
            }
        }
        .frame(height: 26 + CGFloat(rows.count) * 72 + (abandoned.isEmpty ? 0 : 46) + (unfolded ? CGFloat(abandoned.count) * 64 : 0) + (failed && overview == nil ? 40 : 0))
        .padding(.top, 40)
    }

    private func head(_ text: String, x: CGFloat) -> some View {
        Text(verbatim: text).font(V3.sans(12.5)).foregroundStyle(MockPalette.fnt).offset(x: x)
    }

    /// 空列表（Figma 09 · 08.02）：一张空的记录表，三行等着填。
    private var emptyState: some View {
        V3EmptyCard(title: "还没有面试记录", message: "练完一场模拟面试，这里就会多一行。\n面过的真实面试，可以用右上角「导入面试记录」补进来。", stageHeight: 160) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(.white).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MockPalette.cl))
                RoundedRectangle(cornerRadius: 2).fill(MockPalette.ink).frame(width: 36, height: 4).offset(x: 12, y: 12)
                ForEach([28.0, 48, 68], id: \.self) { y in
                    RoundedRectangle(cornerRadius: 3).strokeBorder(MockPalette.cl, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 106, height: 13).offset(x: 12, y: y)
                }
            }
            .frame(width: 132, height: 92)
        } actions: {
            Button("开始第一场模拟面试", action: startFirst).buttonStyle(MockPillStyle(height: 34, padding: 18, size: 13))
        }
    }

    private func heading(_ rows: [JSONValue], _ score: JSONValue?) -> String {
        if rows.isEmpty { return "全部记录" }
        if let score, score != .null, (score["count"]?.integer ?? 0) >= 2 {
            return "\(rows.count) 场面试，从 \(score["first"]?.integer ?? 0) 分到 \(score["latest"]?.integer ?? 0) 分。"
        }
        return "\(rows.count) 场面试。"
    }

    private func tap(_ item: JSONValue) {
        // 复盘还没生成，详情页没有可看的内容，留在列表里提示
        if item.text("status") == "reviewing" { notice = MockNotice(kind: .queued, title: "复盘还在生成", message: "好了这一行会显示分数，到时再点开看"); return }
        if item.text("kind") == "mock" { openReport(item.text("id")) } else { openReal(item.text("id"), item.text("application_id").nonEmptyValue) }
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

/// `.mi3-rec`：72 高的一行，列位置按 860 宽设计稿换成百分比；悬停只换浅底。
private struct MockRecordRow: View {
    let item: JSONValue
    let width: CGFloat
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        let reviewing = item.text("status") == "reviewing"
        let stuck = item["stuck"].flatMap { $0 == .null ? nil : $0 }
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                Text(verbatim: MockHomeV2.mmdd(item.text("at"))).font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.ink).frame(height: 22).offset(y: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.text("title")).font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.ink).lineLimit(1).frame(height: 22)
                    Text(verbatim: item.text("subtitle")).font(V3.sans(13)).foregroundStyle(MockPalette.sub).lineLimit(1).frame(height: 20)
                }
                .frame(width: width * 0.314, alignment: .leading).offset(x: width * 0.1163, y: 15)
                if let stuck {
                    Circle().fill(MockPalette.orange).frame(width: 6, height: 6).offset(x: width * 0.4581, y: 23)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: stuck.text("topic")).font(V3.sans(14, weight: .medium)).foregroundStyle(MockPalette.ink).lineLimit(1).frame(height: 22)
                        Text(verbatim: stuck.text("detail")).font(V3.sans(13)).foregroundStyle(MockPalette.sub).lineLimit(1).frame(height: 20)
                    }
                    .frame(width: max(0, width * 0.4186 - 14), alignment: .leading).offset(x: width * 0.4581 + 14, y: 15)
                }
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if let score = item["score"]?.numberValue {
                        Text(verbatim: "\(Int(score))").font(V3.serif(22)).foregroundStyle(MockPalette.ink).frame(height: 30).padding(.top, 22)
                    } else {
                        Text(verbatim: reviewing ? "复盘中" : "—").font(V3.sans(13)).foregroundStyle(MockPalette.mute).frame(height: 20).padding(.top, 26)
                    }
                    Text(verbatim: "›").font(V3.sans(16)).foregroundStyle(MockPalette.mute).frame(width: 50, alignment: .trailing).padding(.trailing, 4).padding(.top, 25)
                        .opacity(reviewing ? 0 : 1)
                }
            }
            .frame(width: width, height: 72, alignment: .topLeading)
            .background(hover && !reviewing ? MockPalette.rowHover : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(MockPalette.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .accessibilityElement(children: .combine)
    }
}
