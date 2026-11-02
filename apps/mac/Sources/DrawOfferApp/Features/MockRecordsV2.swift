import Foundation
import DrawOfferCore
import SwiftUI

/// 练习记录（Web `mock-interview/v2/RecordsPage.tsx`，Figma 27 · R.02）：只列完成的场次，点一行看报告；
/// 开始后放弃的场次没有报告，合成最后一行，展开后可以用同样设置重来。
struct MockRecordsV2: View {
    @Environment(SessionStore.self) private var session
    let back: () -> Void
    let openReport: (String) -> Void
    let open: (String) -> Void

    @State private var list: [JSONValue]?
    @State private var failed = false
    @State private var showAbandoned = false
    @State private var headlines: [String: String] = [:]
    @State private var toast: String?
    @State private var tick = 0

    private static let week = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    private func when(_ item: JSONValue) -> String { item.text("finished_at").nonEmptyValue ?? item.text("started_at").nonEmptyValue ?? item.text("created_at") }
    private func job(_ item: JSONValue) -> String {
        item.display("job_application_id").isEmpty ? "不挑岗位"
            : [item.text("company_name").nonEmptyValue ?? "未命名公司", item.text("job_title").nonEmptyValue ?? item.text("target_role")].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func settings(_ item: JSONValue) -> String {
        [MockMap.typeName(item), MockMap.diffName[item.text("difficulty")] ?? "", item.text("answer_mode") == "voice" ? "语音" : "文字", "\(item["question_count"]?.integer ?? 0) 题"].joined(separator: " · ")
    }
    private func tone(_ item: JSONValue) -> Color {
        switch MockMap.verdictTone(item.text("verdict").nonEmptyValue) {
        case .blue: return MI.blue
        case .orange: return MI.orange
        default: return MI.sub
        }
    }

    var body: some View {
        let sorted = (list ?? []).sorted { when($0) > when($1) }
        let completed = sorted.filter { $0.text("status") == "completed" }
        let abandoned = sorted.filter { $0.text("status") == "abandoned" }
        let summary = [completed.isEmpty ? nil : "完成 \(completed.count) 场", abandoned.isEmpty ? nil : "另有 \(abandoned.count) 场中途放弃"].compactMap { $0 }.joined(separator: " · ")
        V3Page {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    HStack(spacing: 12) {
                        Button(action: back) {
                            HStack(spacing: 6) { Image(systemName: "arrow.left").font(.system(size: 13)); Text("模拟面试") }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("返回模拟面试")
                        Text("/").accessibilityHidden(true)
                        Text("练习记录")
                    }.font(V3.sans(16)).foregroundStyle(V3.fnt).frame(height: 20)
                    Spacer()
                    Button("练一场新的", action: back).buttonStyle(MockButtonStyle(kind: .dark, size: 13))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("练习记录").font(V3.serif(30)).foregroundStyle(MI.ink).frame(height: 40)
                    if !summary.isEmpty { Text(verbatim: summary).font(V3.sans(14)).foregroundStyle(MI.sub) }
                }.padding(.top, 12)
                if failed && list == nil {
                    VStack(spacing: 10) {
                        Text("练习记录没有加载出来").font(V3.serif(18)).foregroundStyle(MI.ink).frame(height: 22)
                        Button("重新加载") { tick += 1 }.buttonStyle(MockButtonStyle())
                    }.frame(maxWidth: .infinity).padding(.top, 160)
                } else if list != nil && completed.isEmpty && abandoned.isEmpty {
                    VStack(spacing: 10) {
                        Text("还没有练习").font(V3.serif(18)).foregroundStyle(MI.ink).frame(height: 22)
                        Text("练完一场，这里会多一行记录，点开就是这场的报告。").font(V3.sans(13.5)).foregroundStyle(MI.mute).frame(height: 22)
                    }.frame(maxWidth: .infinity).padding(.top, 160)
                } else if list != nil {
                    VStack(alignment: .leading, spacing: 0) {
                        if !completed.isEmpty { Text("完成的 \(completed.count) 场").font(V3.sans(15, weight: .medium)).frame(height: 22).padding(.bottom, 12) }
                        ForEach(completed, id: \.self) { item in row(item) }
                        if !abandoned.isEmpty {
                            Button { showAbandoned.toggle() } label: {
                                HStack {
                                    Text(completed.isEmpty ? "\(abandoned.count) 场都在开始后放弃，没有报告" : "另有 \(abandoned.count) 场开始后放弃，没有报告")
                                    Spacer()
                                    Text(showAbandoned ? "收起 ⌃" : "展开 ⌄")
                                }
                                .font(V3.sans(13.5)).foregroundStyle(MI.mute).frame(minHeight: 56).contentShape(Rectangle())
                                .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xE6E3DC)).frame(height: 1) }
                            }.buttonStyle(.plain).accessibilityValue(showAbandoned ? "已展开" : "已收起")
                            if showAbandoned { ForEach(abandoned, id: \.self) { item in abandonedRow(item) } }
                        }
                    }.padding(.top, 36)
                }
            }
        }
        .background(.white)
        .task(id: tick) { await load() }
        .overlay(alignment: .bottomTrailing) {
            if let toast {
                VStack(alignment: .leading, spacing: 2) {
                    Text("没有开始新的一场").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.red)
                    Text(verbatim: toast).font(V3.sans(12)).foregroundStyle(MI.sub)
                }
                .padding(.horizontal, 16).padding(.vertical, 12).background(.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xE6E3DC))).shadow(color: .black.opacity(0.08), radius: 12, y: 4).padding(24)
                .task(id: toast) { try? await Task.sleep(for: .seconds(5)); self.toast = nil }
            }
        }
    }

    private func dateColumn(_ item: JSONValue, off: Bool = false) -> some View {
        let date = CareerApplication.date(when(item)) ?? Date()
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: MockMap.mmddDot(date)).font(.system(size: 15, weight: .medium)).foregroundStyle(off ? MI.mute : MI.ink)
            Text(verbatim: Self.week[Beijing.calendar.component(.weekday, from: date) - 1]).font(V3.sans(12)).foregroundStyle(MI.mute)
        }.frame(width: 64, alignment: .leading)
    }

    private func copy(_ item: JSONValue, off: Bool = false, headline: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: job(item)).font(V3.sans(15, weight: off ? .regular : .medium)).foregroundStyle(off ? MI.sub : MI.ink).lineLimit(1)
                Text(verbatim: settings(item)).font(V3.sans(13)).foregroundStyle(MI.mute).lineLimit(1)
            }
            if let headline, !headline.isEmpty { Text(verbatim: headline).font(V3.sans(13.5)).foregroundStyle(MI.sub).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ item: JSONValue) -> some View {
        let id = item.text("id")
        let score = item["total_score"]?.numberValue
        return Button { openReport(id) } label: {
            HStack(spacing: 16) {
                dateColumn(item)
                copy(item, headline: headlines[id])
                Text(verbatim: score.map { "\(Int($0.rounded()))" } ?? "—").font(.system(size: 26, weight: .medium)).foregroundStyle(tone(item)).frame(width: 56, alignment: .trailing)
                Text(verbatim: item.text("verdict").nonEmptyValue.flatMap { MockMap.verdictName[$0] } ?? "").font(V3.sans(12.5)).foregroundStyle(tone(item)).lineLimit(1).frame(width: 76, alignment: .leading)
                Text("看报告 ›").font(V3.sans(13.5)).foregroundStyle(MI.blue).frame(width: 64, alignment: .trailing)
            }
            .padding(.vertical, 14).frame(minHeight: 76).contentShape(Rectangle())
            .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xE6E3DC)).frame(height: 1) }
        }.buttonStyle(.plain)
    }

    private func abandonedRow(_ item: JSONValue) -> some View {
        HStack(spacing: 16) {
            dateColumn(item, off: true)
            copy(item, off: true)
            Button("用同样设置重来 ›") { Task { await repeatSession(item.text("id")) } }.buttonStyle(MockButtonStyle(kind: .link, size: 13.5))
        }
        .padding(.vertical, 14).frame(minHeight: 60)
        .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xE6E3DC)).frame(height: 1) }
    }

    private func load() async {
        do {
            var items: [JSONValue] = [], cursor = ""
            repeat {
                var query = ["limit": "100"]; if !cursor.isEmpty { query["cursor"] = cursor }
                let page = try await session.api.careerRequest(path: "/api/mock-interviews", method: "GET", query: query, body: nil)
                items += page["items"]?.items ?? []; cursor = page.text("next_cursor")
            } while !cursor.isEmpty && !Task.isCancelled
            list = items; failed = false
        } catch { if !Task.isCancelled { failed = true }; return }
        // 每行的一句结论在报告里：只读最近的若干场
        for item in (list ?? []).filter({ $0.text("status") == "completed" }).sorted(by: { when($0) > when($1) }).prefix(24) where headlines[item.text("id")] == nil {
            if let detail = try? await session.api.careerRequest(path: "/api/mock-interviews/\(item.text("id"))", method: "GET", query: [:], body: nil) {
                headlines[item.text("id")] = detail["mock_interview"]?["report"]?.text("headline") ?? ""
            }
        }
    }

    private func repeatSession(_ id: String) async {
        do {
            let result = try await session.api.careerRequest(path: "/api/mock-interviews/\(id)/repeat", method: "POST", query: [:], body: nil)
            open(result["mock_interview"]?.text("id") ?? "")
        } catch { toast = MockInterviewText.error(error) }
    }
}
