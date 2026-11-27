import AppKit
import DrawOfferCore
import SwiftUI

/// 08 · 面试日程共用的颜色与格式（Figma `5:20`）。
enum ScheduleInk {
    /// 稿里的三级灰字 #96968F（标签、时间刻度、说明）。
    static let faint = Color(hex: 0x96968F)
    static func format(_ date: Date, _ pattern: String) -> String {
        let f = Beijing.formatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = pattern; return f.string(from: date)
    }
}

// MARK: - 场次详情（Web 08 · 09，统一弹窗 560 宽）

/// 去掉插画与状态胶囊，状态并入副标题；信息用 84 宽标签行；只有右上 ×，左下「查看求职记录 ›」，每个弹窗一个墨黑主按钮。
/// 开放作答窗口在未完成且可改时多一段「我的作答计划」：开始时间 + 时长一行，越界当场提示并禁用保存。
struct ScheduleDetailDialog: View {
    let interview: ScheduledInterview
    let canReschedule: Bool
    let api: any APIClient
    let close: () -> Void
    let changed: (String?) -> Void
    let openRecord: () -> Void
    let practice: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var item: ScheduledInterview?
    @State private var loading = false
    @State private var planStart: Date?
    @State private var planMinutes = 120
    @State private var planPicker = false
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false

    private var current: ScheduledInterview { item ?? interview }
    private var model: ScheduleDetail { ScheduleDetail(item: current, canReschedule: canReschedule && current.editable) }
    private var planProblem: String? { ScheduleDetail.planProblem(start: planStart, minutes: planMinutes, window: current) }
    private var meetingURL: URL? {
        let text = model.meeting
        guard !text.isEmpty else { return nil }
        return URL(string: text.contains("://") ? text : "https://" + text).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
    }

    var body: some View {
        let model = self.model
        V3StandardDialog(title: model.title, subtitle: model.subtitle, width: 560, showClose: true, close: close) {
            VStack(alignment: .leading, spacing: 12) {
                V3DialogField(model.timeLabel, model.timeValue)
                if let label = model.personLabel {
                    V3DialogField(label, model.person.isEmpty ? "未填写" : model.person, muted: model.person.isEmpty)
                }
                V3DialogField("形式", model.modeText)
                if !current.raw.text("location").isEmpty { V3DialogField("地点", current.raw.text("location")) }
                if model.showLink {
                    V3DialogField(label: model.linkLabel, value: {
                        Button { if let meetingURL { openURL(meetingURL) } } label: {
                            Text(model.meeting).font(.system(size: 13).monospacedDigit()).foregroundStyle(V3.link).lineLimit(1).truncationMode(.middle)
                        }.buttonStyle(.plain).help(model.meeting)
                    }, action: {
                        V3TextLink(title: copied ? "已复制" : "复制", chevron: false) { copy(model.meeting) }
                    })
                }
                if model.missingVideoLink { V3DialogField("会议链接", "未填写", muted: true) }
                if model.cancelled && !current.raw.text("cancellation_reason").isEmpty { V3DialogField("取消原因", current.raw.text("cancellation_reason")) }
                if model.isWindow && !model.editablePlan { V3DialogField("作答计划", model.planText, muted: current.raw.text("answer_plan_start_at").isEmpty) }
            }
            if model.editablePlan { planSection }
            if let note = model.note { Text(note).foregroundStyle(V3.sub).fixedSize(horizontal: false, vertical: true) }
            if loading && item == nil { Text("正在加载完整面试详情…").font(V3.sans(12)).foregroundStyle(V3.fnt) }
            if let error { Text(error).font(V3.sans(12)).foregroundStyle(V3.red).fixedSize(horizontal: false, vertical: true) }
        } note: {
            if model.showRecordLink { V3TextLink(title: "查看求职记录", action: openRecord) }
        } actions: {
            if model.secondaryPractice { Button("模拟这场面试", action: practice).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36)) }
            switch model.primary {
            case .savePlan:
                Button(busy ? "正在保存…" : "保存作答计划") { Task { await savePlan(clear: false) } }
                    .buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).disabled(busy || planProblem != nil || planStart == nil)
            case .enter(let label):
                Button(label) { if let meetingURL { openURL(meetingURL) } }.buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).disabled(meetingURL == nil)
            case .practice:
                Button("模拟这场面试", action: practice).buttonStyle(V3ButtonStyle(kind: .dark, height: 36))
            case .record:
                Button("查看求职记录", action: openRecord).buttonStyle(V3ButtonStyle(kind: .dark, height: 36))
            }
        }
        .interactiveDismissDisabled(busy)
        .task {
            if let start = CareerApplication.date(interview.raw.text("answer_plan_start_at")) {
                planStart = start
                if let end = CareerApplication.date(interview.raw.text("answer_plan_end_at")) { planMinutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded())) }
            }
            loading = true
            do {
                let data = try await api.careerRequest(path: "/api/interview-sessions/\(interview.id)", method: "GET", query: [:], body: nil)
                try Task.checkCancellation()
                if let session = data["session"], session != .null { item = ScheduledInterview(session) }
            } catch { /* 列表里的副本继续显示 */ }
            loading = false
        }
    }

    // MARK: 我的作答计划

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("我的作答计划").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                    Text("选填 · 只提醒自己，不改官方时间").font(V3.sans(12)).foregroundStyle(V3.fnt)
                }
                Spacer(minLength: 0)
                if !current.raw.text("answer_plan_start_at").isEmpty {
                    V3TextLink(title: "清除", chevron: false) { Task { await savePlan(clear: true) } }.disabled(busy)
                }
            }
            HStack(spacing: 8) {
                Text("作答时间").foregroundStyle(V3.fnt).frame(width: 76, alignment: .leading)
                Button { planPicker = true } label: {
                    fieldLabel(planStart.map { ScheduleInk.format($0, "MM-dd HH:mm") } ?? "选择开始时间", placeholder: planStart == nil, width: 168, invalid: planProblem != nil)
                }
                .buttonStyle(.plain).accessibilityLabel("计划作答时间")
                .popover(isPresented: $planPicker, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        DatePicker("计划作答时间", selection: Binding(get: { planStart ?? max(current.start, Date()) }, set: { planStart = $0; error = nil }),
                                   in: current.start...max(current.start, current.end), displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.graphical).labelsHidden()
                        HStack {
                            Spacer()
                            Button("取消") { planPicker = false }.buttonStyle(V3ButtonStyle(kind: .ghost))
                            Button("确定") { if planStart == nil { planStart = max(current.start, Date()) }; planPicker = false }.buttonStyle(V3ButtonStyle(kind: .dark))
                        }
                    }.padding(16).frame(width: 320)
                }
                Menu {
                    ForEach(Array(Set([30, 45, 60, 90, 120, 180, planMinutes])).sorted(), id: \.self) { minutes in
                        Button { planMinutes = minutes; error = nil } label: {
                            Text("\(minutes) 分钟" + (planStart.map { "  至 " + ScheduleInk.format($0.addingTimeInterval(Double(minutes) * 60), "HH:mm") } ?? ""))
                        }
                    }
                } label: { fieldLabel("\(planMinutes) 分钟", placeholder: false, width: 104, invalid: false) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("作答时长")
                Spacer(minLength: 0)
            }
            if let planProblem { Text(planProblem).font(V3.sans(12)).foregroundStyle(V3.red).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func fieldLabel(_ text: String, placeholder: Bool, width: CGFloat, invalid: Bool) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 13).monospacedDigit()).foregroundStyle(placeholder ? V3.fnt : V3.txt).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(V3.fnt)
        }
        .padding(.horizontal, 10).frame(width: width, height: 28)
        .background(.white, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(invalid ? V3.red : .black.opacity(0.12)))
        .contentShape(Rectangle())
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .milliseconds(1600)); copied = false }
    }

    private func savePlan(clear: Bool) async {
        guard model.editablePlan, !busy else { return }
        guard clear || (planStart != nil && planProblem == nil) else { return }
        busy = true; error = nil
        do {
            let f = ISO8601DateFormatter()
            let start = clear ? nil : planStart
            let end = start?.addingTimeInterval(Double(planMinutes) * 60)
            let body: JSONValue = .object(["base_lock_version": current.raw["lock_version"] ?? .number(1),
                                           "answer_plan_start_at": start.map { .string(f.string(from: $0)) } ?? .null,
                                           "answer_plan_end_at": end.map { .string(f.string(from: $0)) } ?? .null])
            _ = try await api.careerRequest(path: "/api/interview-sessions/\(current.id)/answer-plan", method: "PUT", query: [:], body: body)
            if let start, let end {
                changed("已更新作答计划：\(current.company) · \(ScheduleInk.format(start, "EEE HH:mm"))–\(ScheduleInk.format(end, "HH:mm"))")
            } else {
                changed("已清除作答计划：\(current.company)")
            }
        } catch {
            if let overlap = ScheduleOverlap.message(error, timeZone: TimeZone(identifier: current.raw.text("timezone")) ?? Beijing.timeZone) { self.error = overlap }
            else if case APIError.server(let status, let code) = error { self.error = status == 409 ? "记录已更新，请关闭后刷新再试（\(code)）。" : "保存失败（\(code)）。" }
            else { self.error = "连接失败，作答计划尚未确认保存。" }
        }
        busy = false
    }
}

// MARK: - 新建面试 · 没有能安排的岗位（Web 08 · 09.01 / 09.15）

/// 日程里不建岗位，岗位只从投递看板来：看板上一个岗位都没有 → 去岗位广场 / 去投递看板；有岗位但都不能再加一场 → 去投递看板改。
struct ScheduleEmptyDialog: View {
    let kind: SchedulePage.Empty
    let close: () -> Void
    let go: (WorkspaceSection) -> Void

    var body: some View {
        switch kind {
        case .noJobs:
            V3StandardDialog(title: "还没有岗位", subtitle: "面试要记在某个岗位下。先去投递看板添加收到通知的岗位，或在岗位广场挑一个，之后就能在这里安排。",
                             width: 440, showClose: true, close: close) { EmptyView() } actions: {
                Button("去岗位广场") { go(.opportunities) }.buttonStyle(V3ButtonStyle(kind: .ghost, height: 36))
                Button("去投递看板") { go(.jobs) }.buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).keyboardShortcut(.defaultAction)
            }
        case .noneEligible:
            V3StandardDialog(title: "没有能安排的岗位", subtitle: "投递看板上的岗位都已安排了下一轮或已结束。要改已安排的那一轮，去投递看板里改。",
                             width: 440, showClose: true, close: close) { EmptyView() } actions: {
                Button("去投递看板") { go(.jobs) }.buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - 页头日期选择（Figma 07.3 / 07.4）

/// 周视图点日期：整周选择（周一开头），选中周整行浅蓝、首尾两天蓝底；右上「‹ 本周 ›」。
struct ScheduleWeekGrid: View {
    let selected: Date
    let pick: (Date) -> Void
    @State private var month = Date()
    private let calendar = Beijing.calendar

    var body: some View {
        let days = ScheduleCalendar.monthDays(month)
        let week = ScheduleCalendar.weekStart(selected)
        let thisMonth = calendar.dateInterval(of: .month, for: month)!.start
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("\(String(calendar.component(.year, from: month))) 年 \(calendar.component(.month, from: month)) 月").font(V3.sans(13, weight: .medium)).foregroundStyle(V3.txt)
                Spacer()
                arrow("chevron.left", label: "上个月") { month = calendar.date(byAdding: .month, value: -1, to: month)! }
                Button("本周") { pick(Date()) }.buttonStyle(.plain).font(V3.sans(12, weight: .medium)).foregroundStyle(V3.txt).padding(.horizontal, 12)
                arrow("chevron.right", label: "下个月") { month = calendar.date(byAdding: .month, value: 1, to: month)! }
            }.padding(.leading, 17).padding(.trailing, 15).frame(height: 24).padding(.top, 15)
            HStack(spacing: 2) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(V3.sans(12)).foregroundStyle(V3.fnt).frame(width: 36) }
            }.padding(.top, 12)
            VStack(spacing: 3) {
                ForEach(0..<(days.count / 7), id: \.self) { row in
                    let start = days[row * 7]
                    let on = calendar.isDate(start, inSameDayAs: week)
                    Button { pick(start) } label: {
                        HStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { column in
                                let day = days[row * 7 + column]
                                let inside = calendar.isDate(day, equalTo: thisMonth, toGranularity: .month)
                                let end = on && (column == 0 || column == 6)
                                Text("\(calendar.component(.day, from: day))").font(.system(size: 12, weight: end ? .medium : .regular).monospacedDigit())
                                    .foregroundStyle(end ? .white : inside ? V3.txt : Color(hex: 0xB5B5B0))
                                    .frame(width: 36, height: 30)
                                    .background(end ? V3.blue : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                        .background(on ? V3.blueSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(ScheduleInk.format(start, "M月d日") + " 起的一周").accessibilityAddTraits(on ? .isSelected : [])
                }
            }.padding(.top, 6)
        }
        .padding(.bottom, 13).frame(width: 296)
        .onAppear { month = selected }
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(V3.sub).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }
}
