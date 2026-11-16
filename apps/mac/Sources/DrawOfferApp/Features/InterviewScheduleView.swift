import AppKit
import DrawOfferCore
import SwiftUI

private struct ScheduleAction: Identifiable {
    let id = UUID()
    var kind: String
    var interview: ScheduledInterview?
    var start: Date
    var end: Date
}

/// 月视图格子里的一条日程（作答窗口在开放日和截止日各占一条）。
private struct ScheduleMonthChip: Identifiable {
    let id: String
    let item: ScheduledInterview
    let text: String
    let color: Color
    let time: Date
}

/// 08 · 面试日程（Figma `5:20`）：01 月视图 / 周视图，日历占满整页（与 Web 一致，已去掉日历下方的「接下来」和空状态卡）；
/// 02.01 没有可推进流程的新建面试，03–06 日程详情弹窗在 ScheduleDialogs.swift。
struct InterviewScheduleView: View {
    @Environment(SessionStore.self) private var session
    let requireAccount: () -> Void
    @State private var anchor = Date()
    @State private var mode = "week"
    @State private var interviews: [ScheduledInterview] = []
    @State private var applications: [CareerApplication] = []
    @State private var action: ScheduleAction?
    @State private var pending: ScheduleAction?
    @State private var detail: ScheduledInterview?
    @State private var selectedID: String?
    @State private var record: CareerApplication?
    @State private var recordAction: JobAction?
    @State private var refresh = UUID()
    @State private var loading = false
    @State private var failure: String?
    @State private var datePicker = false
    @State private var overflow: Date?
    @State private var showAllWindows = false
    @State private var pageGutter: CGFloat = 32
    private let calendar = Beijing.calendar
    /// 周视图每小时 56 高；时间刻度居中压在整点线上，网格顶部留 6。
    private static let hourHeight: CGFloat = 56
    private static let gridInset: CGFloat = 6
    private static let gutter: CGFloat = 52
    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }
    private var meInitial: String { if case .signedIn(let user) = session.phase, let first = user.nickname.first { return String(first) }; return "我" }
    private var week: Date { ScheduleCalendar.weekStart(anchor) }
    private var month: Date { calendar.dateInterval(of: .month, for: anchor)!.start }
    private var visible: [ScheduledInterview] { interviews.filter { $0.raw.text("status") != "cancelled" } }
    private func plus(_ date: Date, _ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: date)! }
    private func format(_ date: Date, _ pattern: String) -> String { ScheduleInk.format(date, pattern) }
    private func at(_ day: Date, minute: Int) -> Date { calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)! }
    private var periodStart: Date { mode == "month" ? month : week }
    private var periodEnd: Date { mode == "month" ? calendar.date(byAdding: .month, value: 1, to: month)! : plus(week, 7) }
    private var periodCount: Int { visible.filter { $0.overlaps(periodStart, periodEnd) }.count }
    /// `canAddScheduledStage`：已投递、上一阶段已结束、还没进 Offer 的流程才能直接加一场。
    private static func canAddStage(_ item: CareerApplication) -> Bool {
        item.raw.text("status") == "active" && item.raw.text("archived_at").isEmpty && !item.raw.text("applied_at").isEmpty
            && item.raw.text("stage_state") == "awaiting_result" && item.raw.text("current_stage_type") != "offer"
    }
    private var eligible: [CareerApplication] { applications.filter(Self.canAddStage) }
    private var excluded: [CareerApplication] { applications.filter { $0.raw.text("status") == "active" && $0.raw.text("archived_at").isEmpty && !Self.canAddStage($0) } }
    /// 2026 年 9 月 / 9 月 21 日 – 27 日.
    private var heading: String {
        if mode == "month" { return "\(calendar.component(.year, from: month)) 年 \(calendar.component(.month, from: month)) 月" }
        let end = plus(week, 6)
        let (m1, d1, m2, d2) = (calendar.component(.month, from: week), calendar.component(.day, from: week), calendar.component(.month, from: end), calendar.component(.day, from: end))
        return m1 == m2 ? "\(m1) 月 \(d1) 日 – \(d2) 日" : "\(m1) 月 \(d1) 日 – \(m2) 月 \(d2) 日"
    }
    private var subtitle: String {
        guard !account.isEmpty else { return "游客模式 · 登录后管理面试安排" }
        let today = visible.filter { !$0.openWindow && calendar.isDateInToday($0.start) }.count
        return "\(mode == "month" ? "本月" : "本周") \(periodCount) 个日程" + (today > 0 ? " · 今天 \(today) 场面试" : "")
    }

    var body: some View {
        Group {
            if let record {
                CareerApplicationDetailView(application: record, api: session.api, back: { self.record = nil; refresh = UUID() }, perform: { kind, app in
                    recordAction = JobAction(kind: kind, application: app,
                        stage: kind == "apply" ? "screening" : kind == "schedule-current" ? app.stage : CareerStage.nextStages(app).first(where: { $0 == "interview" }) ?? CareerStage.nextStages(app).first ?? "screening",
                        label: kind == "stage" ? JobsBoardView.roundLabel((app.raw["current_round_no"]?.integer ?? 0) + 1) : app.stageLabel,
                        round: kind == "schedule-current" ? app.raw["current_round_no"]?.integer : nil)
                })
            } else {
                page
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: account + refresh.uuidString) { await load() }
        .onChange(of: account) { _, id in
            interviews = []; applications = []; action = nil; overflow = nil; detail = nil; record = nil; selectedID = nil
            if id.isEmpty { pending = nil }
            else if let value = pending { action = value; pending = nil }
        }
        .centeredSheet(item: $action) { value in
            if value.kind == "create" && eligible.isEmpty {
                // 02.01 没有可推进的流程：主按钮带着选中的时间去新建求职流程
                ScheduleNoStageDialog(start: value.start, end: value.end, excluded: excluded, close: { action = nil },
                                      createProcess: { action = ScheduleAction(kind: "create-process", start: value.start, end: value.end) },
                                      openRecord: { app in action = nil; record = app })
            } else if value.kind == "create" || value.kind == "create-process" {
                CareerForm(action: JobAction(kind: "schedule", application: nil, start: value.start, end: value.end), applications: applications, api: session.api,
                           completed: { action = nil; refresh = UUID() }, close: { action = nil }).frame(width: 880, height: 780)
            } else {
                ScheduleSessionForm(action: value, interviews: interviews, api: session.api, completed: { action = nil; refresh = UUID() }, close: { action = nil }).frame(width: 560, height: 560)
            }
        }
        .centeredSheet(item: $detail) { item in
            ScheduleDetailDialog(interview: item, api: session.api, meInitial: meInitial, close: { detail = nil }, changed: { detail = nil; refresh = UUID() }, openRecord: {
                detail = nil
                record = applications.first { $0.id == item.applicationID }
            })
        }
        .centeredSheet(item: $recordAction) { item in
            CareerForm(action: item, applications: applications, api: session.api, completed: { recordAction = nil; refresh = UUID() }, close: { recordAction = nil })
                .frame(width: item.compact ? 480 : 880, height: item.compact ? nil : 780)
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            if let failure {
                HStack(spacing: 10) {
                    Text(failure).font(V3.sans(12.5)).foregroundStyle(V3.red)
                    Button("重试") { refresh = UUID() }.buttonStyle(CareerActionStyle(kind: .link))
                }.padding(.top, 10)
            }
            Group { if mode == "month" { monthView } else { weekView } }
                .frame(minHeight: 280, maxHeight: .infinity, alignment: .top).padding(.top, 14)
                .overlay(alignment: .topTrailing) { if loading { ProgressView().controlSize(.small).padding(6) } }
        }
        .padding(.top, 64).padding(.bottom, 32)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, max(0, pageGutter))
        .background { GeometryReader { geometry in Color.clear.onAppear { pageGutter = V3Page<EmptyView>.gutter(card: geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in pageGutter = V3Page<EmptyView>.gutter(card: width) } } }
        .background { Button("") { create(start: at(calendar.startOfDay(for: anchor), minute: 9 * 60)) }.keyboardShortcut("n", modifiers: .command).opacity(0) }
    }

    // MARK: Head（01：11 号眉题、28 号衬线标题、13 号说明；右侧分段 + 前后翻页 + 今天）

    private var head: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                // 与 Web 05.1/05.2 页头一致：「SCHEDULE · 2026 年 · 月视图」，标题右侧带 ⌄ 打开日期选择
                Text(verbatim: "SCHEDULE · " + String(calendar.component(.year, from: periodStart)) + " 年 · " + (mode == "month" ? "月视图" : "周视图"))
                    .font(V3.sans(11)).foregroundStyle(ScheduleInk.faint).frame(height: 13)
                Button { datePicker.toggle() } label: {
                    HStack(spacing: 8) {
                        Text(heading).font(V3.serif(28)).foregroundStyle(V3.txt)
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium)).foregroundStyle(V3.sub)
                    }.frame(height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.top, 13).help("选择其他日期").accessibilityLabel("\(heading)，选择其他日期")
                .popover(isPresented: $datePicker, arrowEdge: .bottom) {
                    DatePicker(mode == "month" ? "选择月份" : "选择周", selection: Binding(get: { anchor }, set: { anchor = $0; datePicker = false }), displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden().padding(16).frame(width: 300)
                }
                Text(subtitle).font(V3.sans(13)).foregroundStyle(V3.sub).frame(height: 16).padding(.top, 2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 9) {
                V3Segmented(options: [("month", "月"), ("week", "周")], selection: $mode).accessibilityElement(children: .contain).accessibilityLabel("日程视图")
                HStack(spacing: 5) {
                    navButton(systemImage: "chevron.left", label: "上一周期") { shift(-1) }
                    Button("今天") { anchor = Date(); overflow = nil }.buttonStyle(ScheduleNavStyle())
                    navButton(systemImage: "chevron.right", label: "下一周期") { shift(1) }
                }
            }.frame(height: 30).padding(.top, 32)
        }
    }
    private func navButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemImage).font(.system(size: 9, weight: .semibold)) }
            .buttonStyle(ScheduleNavStyle(square: true)).accessibilityLabel(label)
    }
    private func shift(_ amount: Int) {
        anchor = calendar.date(byAdding: mode == "month" ? .month : .day, value: mode == "month" ? amount : 7 * amount, to: anchor)!
        overflow = nil
    }
    private func create(start: Date, end: Date? = nil) {
        let value = ScheduleAction(kind: "create", start: start, end: end ?? start.addingTimeInterval(3600))
        if account.isEmpty { pending = value; requireAccount() } else { action = value }
    }
    private func open(_ item: ScheduledInterview) {
        selectedID = item.id
        detail = interviews.first { $0.id == item.id } ?? item
    }
    private func move(_ item: ScheduledInterview, kind: String, start: Date, end: Date) {
        action = ScheduleAction(kind: kind, interview: item, start: start, end: end)
    }
    /// Web `INTERVIEW_CALENDAR_COLORS`; a third interview round without a colour shows purple,
    /// and the month view spreads grey events over the palette.
    static func color(_ item: ScheduledInterview, month: Bool = false) -> Color {
        var key = item.raw.text("calendar_color")
        if item.raw.text("stage_type") == "interview" && item.raw["round_no"]?.integer == 3 && key == "gray" { key = "purple" }
        if month && (key == "gray" || key.isEmpty) {
            let fallback = ["red", "orange", "green", "blue", "purple"]
            key = fallback[item.id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % fallback.count]
        }
        return Color(hex: ["red": 0xD64545, "orange": 0xD9822B, "yellow": 0xC4A236, "green": 0x3D8B67, "blue": 0x3F6FD8, "purple": 0x8B6BC8, "gray": 0x96968F][key] ?? 0x3F6FD8)
    }
    /// `meetingLabel`.
    static func meetingLabel(_ raw: JSONValue) -> String {
        if raw.text("mode") == "onsite" { return [raw.text("location"), "现场"].filter { !$0.isEmpty }.joined(separator: " · ") }
        let url = raw.text("meeting_url")
        let platform = url.contains("feishu.cn") || url.contains("larksuite.com") ? "飞书会议" : url.contains("meeting.tencent.com") ? "腾讯会议" : url.contains("nowcoder.com") ? "牛客网" : nil
        let stage = raw.text("stage_type")
        // 笔试 / 测评 / AI 面试只写平台（稿：「牛客网」）
        if ["written_test", "assessment", "ai_interview"].contains(stage) || raw.text("schedule_kind") == "open_window" { return platform ?? "线上" }
        let mode = raw.text("mode") == "video" ? "视频" : raw.text("mode") == "phone" ? "电话" : "其他方式"
        return [mode, platform].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Month（01.01：每格左上 10.5 号日期，今天蓝圈 + 5% 蓝底；日程条 20 高、圆角 5）

    private func chips(_ day: Date) -> [ScheduleMonthChip] {
        let start = calendar.startOfDay(for: day), end = plus(start, 1)
        var list: [ScheduleMonthChip] = []
        for item in visible {
            let color = Self.color(item, month: true)
            if item.openWindow {
                let opens = calendar.isDate(item.start, inSameDayAs: day)
                let closes = calendar.isDate(item.end.addingTimeInterval(-1), inSameDayAs: day)
                if opens { list.append(ScheduleMonthChip(id: item.id + "-open", item: item, text: item.company + " " + item.label + "开放", color: color, time: item.start)) }
                if closes { list.append(ScheduleMonthChip(id: item.id + "-close", item: item, text: item.company + " " + item.label + "截止", color: V3.red, time: item.end)) }
            } else if item.overlaps(start, end) {
                let text = item.company + " " + item.label + (calendar.isDateInToday(day) ? " " + format(item.start, "HH:mm") : "")
                list.append(ScheduleMonthChip(id: item.id, item: item, text: text, color: color, time: item.start))
            }
        }
        return list.sorted { $0.time < $1.time }
    }
    private var monthView: some View {
        let days = ScheduleCalendar.monthDays(anchor)
        let rows = max(1, days.count / 7)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["周一", "周二", "周三", "周四", "周五", "周六", "周日"], id: \.self) { name in
                    Text(name).font(V3.sans(10.5)).foregroundStyle(ScheduleInk.faint).padding(.leading, 8).padding(.top, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.frame(height: 30).overlay(alignment: .bottom) { Rectangle().fill(V3.line).frame(height: 1) }
            GeometryReader { viewport in
                let height = max(84, viewport.size.height / CGFloat(rows))
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(0..<rows, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<7, id: \.self) { column in monthCell(days[row * 7 + column], column: column, height: height) }
                            }.overlay(alignment: .bottom) { Rectangle().fill(V3.line).frame(height: 1) }
                        }
                    }
                }.scrollDisabled(height * CGFloat(rows) <= viewport.size.height + 1).scrollIndicators(.never)
            }
        }
    }
    private func monthCell(_ day: Date, column: Int, height: CGFloat) -> some View {
        let events = chips(day)
        let today = calendar.isDateInToday(day)
        let inside = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let capacity = max(1, Int((height - 42) / 24))
        let shown = events.count > capacity ? Array(events.prefix(capacity - 1)) : events
        return ZStack(alignment: .topLeading) {
            if today { Rectangle().fill(V3.blue.opacity(0.05)) }
            HStack(spacing: 0) {
                Button { anchor = day; mode = "week" } label: {
                    Text("\(calendar.component(.day, from: day))").font(.system(size: 10.5, weight: today ? .semibold : .medium).monospacedDigit())
                        .foregroundStyle(today ? .white : inside ? V3.txt : V3.fnt2)
                        .padding(.leading, today ? 0 : 4)
                        .frame(width: 22, height: 22, alignment: today ? .center : .leading)
                        .background(today ? V3.blue : .clear, in: Circle()).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(format(day, "M月d日") + "，查看这一周")
                Spacer(minLength: 0)
                if events.count > shown.count {
                    Button("另有 \(events.count - shown.count) 项") { overflow = day }
                        .buttonStyle(.plain).font(V3.sans(10)).foregroundStyle(ScheduleInk.faint).frame(height: 22)
                        .popover(isPresented: Binding(get: { overflow == day }, set: { if !$0 { overflow = nil } })) { overflowList(day, events) }
                }
            }.padding(.leading, 5).padding(.trailing, 6).padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(shown) { chip in monthEvent(chip, today: today) }
            }.padding(.top, 38).padding(.horizontal, 5)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).frame(height: height, alignment: .topLeading)
        .overlay(alignment: .leading) { if column > 0 { Rectangle().fill(V3.line).frame(width: 1) } }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { create(start: at(day, minute: 9 * 60)) }
        .dropDestination(for: String.self) { ids, _ in
            guard let item = interviews.first(where: { $0.id == ids.first }), item.editable, !item.openWindow else { return false }
            let parts = calendar.dateComponents([.hour, .minute], from: item.start)
            let from = at(day, minute: (parts.hour ?? 9) * 60 + (parts.minute ?? 0))
            move(item, kind: "reschedule", start: from, end: from.addingTimeInterval(item.end.timeIntervalSince(item.start))); return true
        }
    }
    private func monthEvent(_ chip: ScheduleMonthChip, today: Bool) -> some View {
        let item = chip.item
        let selected = selectedID == item.id
        return HStack(spacing: 6) {
            Circle().fill(chip.color).frame(width: 5, height: 5)
            Text(chip.text).font(V3.sans(10, weight: today ? .medium : .regular)).foregroundStyle(today ? V3.link : V3.sub).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6).padding(.trailing, 4).frame(maxWidth: .infinity).frame(height: 20)
        .background(today ? V3.blue.opacity(0.12) : V3.field, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? V3.txt : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { open(item) }
        .draggable(item.editable && !item.openWindow ? item.id : "")
        .help(item.company + " " + item.title + " " + item.label)
    }
    private func overflowList(_ day: Date, _ events: [ScheduleMonthChip]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(format(day, "M月d日 · EEE")).font(V3.sans(12, weight: .medium)).foregroundStyle(ScheduleInk.faint).padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 8)
            ForEach(events) { chip in
                Button { overflow = nil; open(chip.item) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(chip.color).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chip.text).font(V3.sans(12, weight: .semibold)).foregroundStyle(V3.txt)
                            Text(format(chip.item.start, "HH:mm") + "–" + format(chip.item.end, "HH:mm") + " · " + chip.item.title).font(V3.sans(11)).foregroundStyle(ScheduleInk.faint)
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 8).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(8).frame(width: 256)
    }

    // MARK: Week（01.02：表头星期 10.5 + 日期 14，今天 30 圆；全天行放作答窗口；每小时 56 高）

    private var weekView: some View {
        let windows = visible.filter { $0.openWindow && $0.overlaps(week, plus(week, 7)) }.sorted { $0.end < $1.end }
        let shownWindows = showAllWindows ? windows : Array(windows.prefix(3))
        return GeometryReader { box in VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.gutter)
                ForEach(0..<7, id: \.self) { index in
                    let day = plus(week, index)
                    let today = calendar.isDateInToday(day)
                    VStack(spacing: 0) {
                        Text(format(day, "EEE")).font(V3.sans(10.5, weight: today ? .medium : .regular)).foregroundStyle(today ? V3.txt : ScheduleInk.faint).frame(height: 13).padding(.top, 8)
                        Text("\(calendar.component(.day, from: day))").font(.system(size: 14, weight: today ? .semibold : .medium).monospacedDigit())
                            .foregroundStyle(today ? .white : V3.txt).frame(width: 30, height: 30).background(today ? V3.blue : .clear, in: Circle()).padding(.top, 5)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity).frame(height: 64)
                }
            }.frame(height: 64).overlay(alignment: .bottom) { Rectangle().fill(V3.line).frame(height: 1) }
            if !windows.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                Text("全天").font(V3.sans(10)).foregroundStyle(ScheduleInk.faint).frame(width: Self.gutter, alignment: .leading).padding(.top, 10)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(shownWindows) { item in windowBar(item) }
                    if windows.count > 3 {
                        Button(showAllWindows ? "收起更多项目" : "还有 \(windows.count - 3) 项待完成 · 展开查看") { showAllWindows.toggle() }
                            .buttonStyle(.plain).font(V3.sans(10, weight: .medium)).foregroundStyle(V3.sub)
                            .frame(maxWidth: .infinity).frame(height: 20).background(V3.field, in: RoundedRectangle(cornerRadius: 5))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                .background(alignment: .leading) { weekColumnLines }
            }.frame(minHeight: 34).overlay(alignment: .bottom) { Rectangle().fill(V3.line).frame(height: 1) }
            }
            timeGrid.frame(maxHeight: .infinity)
        }
        .frame(width: box.size.width, height: box.size.height, alignment: .top) }
    }
    /// 全天行里的竖分隔线（与下方时间网格对齐）。
    private var weekColumnLines: some View {
        GeometryReader { geometry in
            ForEach(0..<7, id: \.self) { index in
                Rectangle().fill(V3.line).frame(width: 1, height: geometry.size.height + 12).offset(x: CGFloat(index) * geometry.size.width / 7, y: -6)
            }
        }
    }
    private func windowBar(_ item: ScheduledInterview) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width / 7
            let first = max(0, calendar.dateComponents([.day], from: week, to: calendar.startOfDay(for: item.start)).day ?? 0)
            let endDay = calendar.startOfDay(for: item.end.addingTimeInterval(-1))
            let last = min(6, calendar.dateComponents([.day], from: week, to: endDay).day ?? 6)
            let color = Self.color(item, month: true)
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2, height: 12)
                Text(item.company + " " + item.label + "开放").font(V3.sans(10, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 4).frame(width: max(width, CGFloat(last - first + 1) * width) - 8, height: 22)
            .background(Color.white.mix(with: color, by: 0.10), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selectedID == item.id ? color.opacity(0.45) : .clear))
            .offset(x: CGFloat(first) * width + 4)
            .contentShape(Rectangle())
            .onTapGesture { open(item) }
        }.frame(height: 22)
    }
    private var timeGrid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                GeometryReader { viewport in
                    let width = (viewport.size.width - Self.gutter) / 7
                    ZStack(alignment: .topLeading) {
                        // 整点线只画在日期列里，刻度居中压线
                        ForEach(0..<24, id: \.self) { hour in
                            let y = Self.gridInset + CGFloat(hour) * Self.hourHeight
                            Rectangle().fill(V3.line).frame(width: viewport.size.width - Self.gutter, height: 1).offset(x: Self.gutter, y: y)
                            Text(String(format: "%02d:00", hour)).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(ScheduleInk.faint)
                                .frame(height: 12).offset(y: y - 6)
                        }
                        // 滚动定位锚点（offset 不改布局位置，锚点单独按行排）
                        VStack(spacing: 0) { ForEach(0..<24, id: \.self) { hour in Color.clear.frame(width: 1, height: Self.hourHeight).id("hour\(hour)") } }.padding(.top, Self.gridInset)
                        HStack(spacing: 0) {
                            Color.clear.frame(width: Self.gutter)
                            ForEach(0..<7, id: \.self) { index in dayColumn(plus(week, index), width: width) }
                        }
                        ForEach(0..<7, id: \.self) { index in dayEvents(plus(week, index), index: index, width: width) }
                        if let index = (0..<7).first(where: { calendar.isDateInToday(plus(week, $0)) }) {
                            let now = Date()
                            let minute = CGFloat(calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now))
                            let y = Self.gridInset + minute / 60 * Self.hourHeight
                            Rectangle().fill(V3.red).frame(width: width, height: 2).offset(x: Self.gutter + CGFloat(index) * width, y: y - 1)
                            Circle().fill(V3.red).frame(width: 7, height: 7).offset(x: Self.gutter + CGFloat(index) * width - 3.5, y: y - 3.5)
                        }
                    }
                }.frame(height: Self.hourHeight * 24 + Self.gridInset * 2)
            }
            .scrollIndicators(.never)
            .task(id: week) {
                // 与 Web 一致默认从 08:00 开始看；本周有更早的安排时滚到那一小时。等一帧布局完成再滚，否则停在 00:00。
                let earliest = visible.filter { !$0.openWindow && $0.start >= week && $0.start < plus(week, 7) }.map { calendar.component(.hour, from: $0.start) }.min() ?? 8
                try? await Task.sleep(for: .milliseconds(60))
                proxy.scrollTo("hour\(min(8, earliest))", anchor: .top)
            }
        }
    }
    private func dayColumn(_ day: Date, width: CGFloat) -> some View {
        Rectangle().fill(Color.clear).frame(width: width, height: Self.hourHeight * 24 + Self.gridInset * 2)
            .overlay(alignment: .leading) { Rectangle().fill(V3.line).frame(width: 1) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 8).onEnded { selection in
                let from = at(day, minute: snap(min(selection.startLocation.y, selection.location.y), upper: 1425))
                let until = at(day, minute: max(15, snap(max(selection.startLocation.y, selection.location.y), upper: 1439)))
                if until > from { create(start: from, end: until) }
            })
            .onTapGesture(count: 2) { point in let from = at(day, minute: snap(point.y, upper: 1425)); create(start: from, end: from.addingTimeInterval(3600)) }
            .dropDestination(for: String.self) { ids, point in
                guard let original = interviews.first(where: { $0.id == ids.first }), let item = original.timed, item.editable else { return false }
                let from = at(day, minute: snap(point.y, upper: 1425))
                move(original, kind: item.openWindow ? "answer-plan" : "reschedule", start: from, end: from.addingTimeInterval(item.end.timeIntervalSince(item.start))); return true
            }
    }
    private func snap(_ y: CGFloat, upper: Int) -> Int { min(upper, max(0, Int(((y - Self.gridInset) / Self.hourHeight * 60 / 15).rounded()) * 15)) }
    private func dayEvents(_ day: Date, index: Int, width: CGFloat) -> some View {
        let events = visible.compactMap(\.timed).filter { $0.overlaps(day, plus(day, 1)) }
        let lanes = ScheduleCalendar.lanes(events)
        return ForEach(events) { item in
            let lane = lanes[item.id] ?? (0, 1)
            let start = max(day, item.start), end = min(plus(day, 1), item.end)
            let minute = CGFloat(calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start))
            let height = max(22, end.timeIntervalSince(start) / 3600 * Self.hourHeight) - 4
            let color = Self.color(item)
            let selected = selectedID == item.id
            // 事件块：10% 色底、左侧 2px 色条；时间 10 号着色 → 标题 11.5 中粗 → 次要 10 号
            VStack(alignment: .leading, spacing: 2) {
                Text(format(item.start, "HH:mm") + " – " + format(item.end, "HH:mm")).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(color).frame(height: 12)
                Text(item.company + " · " + item.label).font(V3.sans(11.5, weight: .medium)).foregroundStyle(V3.txt).lineLimit(1).frame(height: 14)
                if height >= 44 { Text(item.openWindow ? "我的作答计划" : Self.meetingLabel(item.raw)).font(V3.sans(10)).foregroundStyle(V3.sub).lineLimit(1).frame(height: 12) }
                Spacer(minLength: 0)
            }
            .padding(.top, 5).padding(.leading, 12).padding(.trailing, 6)
            .frame(width: max(12, width / CGFloat(lane.count) - 8), height: height, alignment: .topLeading)
            .background(Color.white.mix(with: color, by: selected ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2).padding(.vertical, 6).padding(.leading, 4) }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? color.opacity(0.45) : .clear, lineWidth: 1))
            .overlay(alignment: .top) { if item.editable { resizeHandle(item, top: true) } }
            .overlay(alignment: .bottom) { if item.editable { resizeHandle(item, top: false) } }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { open(item) }
            .onTapGesture { selectedID = item.id }
            .draggable(item.editable ? item.id : "")
            .offset(x: Self.gutter + CGFloat(index) * width + CGFloat(lane.index) * width / CGFloat(lane.count) + 4, y: Self.gridInset + minute / 60 * Self.hourHeight + 2)
        }
    }
    private func resizeHandle(_ item: ScheduledInterview, top: Bool) -> some View {
        Color.clear.frame(maxWidth: .infinity).frame(height: 5).contentShape(Rectangle())
            .gesture(DragGesture().onEnded { drag in
                let minutes = Int((drag.translation.height / Self.hourHeight * 60 / 15).rounded()) * 15
                let from = top ? item.start.addingTimeInterval(Double(minutes) * 60) : item.start
                let until = top ? item.end : item.end.addingTimeInterval(Double(minutes) * 60)
                if until.timeIntervalSince(from) >= 900 { move(interviews.first { $0.id == item.id } ?? item, kind: item.openWindow ? "answer-plan" : "reschedule", start: from, end: until) }
            })
            .help(top ? "拖动调整开始时间" : "拖动调整结束时间")
    }

    private func load() async {
        guard !account.isEmpty else { loading = false; failure = nil; return }
        loading = true; failure = nil
        do {
            var items: [JSONValue] = []; var cursor = ""; var seen = Set<String>()
            repeat {
                var query = ["limit": "500"]; if !cursor.isEmpty { query["cursor"] = cursor }
                let page = try await session.api.careerRequest(path: "/api/interview-sessions", method: "GET", query: query, body: nil)
                try Task.checkCancellation(); items += page["items"]?.items ?? []; cursor = page.text("next_cursor")
                if !cursor.isEmpty && !seen.insert(cursor).inserted { throw APIError.invalidResponse }
            } while !cursor.isEmpty
            var jobs: [CareerApplication] = []; cursor = ""; seen = []
            repeat {
                var query = ["scope": "all", "limit": "200"]; if !cursor.isEmpty { query["cursor"] = cursor }
                let page = try await session.api.careerRequest(path: "/api/job-applications", method: "GET", query: query, body: nil)
                try Task.checkCancellation(); jobs += (page["items"]?.items ?? []).map { CareerApplication($0) }; cursor = page.text("next_cursor")
                if !cursor.isEmpty && !seen.insert(cursor).inserted { throw APIError.invalidResponse }
            } while !cursor.isEmpty
            interviews = items.map(ScheduledInterview.init); applications = jobs
        } catch { if !Task.isCancelled { failure = "排期加载失败，请检查连接或重新登录后重试。" } }
        if !Task.isCancelled { loading = false }
    }
}

/// 01 右上翻页按钮：29 方形 / 「今天」51 宽，白底 #E4E4E0 描边、圆角 6.5。
private struct ScheduleNavStyle: ButtonStyle {
    var square = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(V3.sans(12, weight: .medium)).foregroundStyle(V3.txt)
            .padding(.horizontal, square ? 0 : 13).frame(width: square ? 29 : nil, height: 29)
            .background(configuration.isPressed ? V3.field : .white, in: RoundedRectangle(cornerRadius: 6.5))
            .overlay(RoundedRectangle(cornerRadius: 6.5).strokeBorder(V3.cl))
            .contentShape(Rectangle())
    }
}

private struct ScheduleSessionForm: View {
    let action: ScheduleAction
    let interviews: [ScheduledInterview]
    let api: any APIClient
    let completed: () -> Void
    let close: () -> Void
    @State private var item: ScheduledInterview?
    @State private var kind = "detail"
    @State private var start = Date()
    @State private var end = Date()
    @State private var reason = ""
    @State private var mode = "video"
    @State private var meeting = ""
    @State private var location = ""
    @State private var interviewer = ""
    @State private var interviewerTitle = ""
    @State private var note = ""
    @State private var questions = ""
    @State private var review = ""
    @State private var improvement = ""
    @State private var removePlan = false
    @State private var allowConflict = false
    @State private var busy = false
    @State private var failure: String?
    @State private var frozen: JSONValue?
    private var heading: String { ["detail": "面试安排", "reschedule": "确认改期", "answer-plan": "个人作答计划", "complete": "完成面试", "cancel": "取消安排", "edit": "编辑安排"][kind] ?? "面试安排" }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(heading).font(V3.serif(20)).foregroundStyle(V3.txt)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(V3.fnt) }.buttonStyle(.plain).accessibilityLabel("关闭").disabled(busy)
            }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let item {
                        Text(item.company + " · " + item.title).font(.headline)
                        Text(item.label + " · " + item.status(at: Date())).font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(item.openWindow ? "开放作答窗口" : "固定面试场次").font(.system(size: 12)).foregroundStyle(.secondary)
                        if kind == "detail" {
                            Text(display(item.start) + " — " + display(item.end))
                            Text(["video": "视频面试", "onsite": "现场面试", "phone": "电话面试", "other": "其他方式"][item.raw.text("mode")] ?? "其他方式")
                            if !item.raw.text("meeting_url").isEmpty { Text("会议 / 作答链接：" + item.raw.text("meeting_url")).textSelection(.enabled) }
                            if !item.raw.text("location").isEmpty { Text("地点：" + item.raw.text("location")) }
                            if !item.raw.text("interviewer_name").isEmpty { Text("面试官：" + item.raw.text("interviewer_name") + " " + item.raw.text("interviewer_title")) }
                            if !item.raw.text("preparation_note").isEmpty { Text("准备备注：" + item.raw.text("preparation_note")).textSelection(.enabled) }
                            if let plan = item.timed, item.openWindow { Text("个人作答计划：" + display(plan.start) + " — " + display(plan.end)) }
                            ForEach(["questions_markdown", "review_summary", "improvement_markdown"], id: \.self) { key in
                                if !item.raw.text(key).isEmpty { Text(item.raw.text(key)).textSelection(.enabled) }
                            }
                            if item.editable {
                                HStack {
                                    Button("编辑信息") { begin("edit") }
                                    if !item.openWindow { Button("改期") { begin("reschedule") } }
                                    if item.openWindow { Button("作答计划") { begin("answer-plan") } }
                                    Button("完成") { begin("complete") }
                                    Button("取消安排") { begin("cancel") }
                                }
                            }
                        } else if ["reschedule", "answer-plan"].contains(kind) {
                            if kind == "answer-plan" { Toggle("清除个人作答计划", isOn: $removePlan).disabled(frozen != nil) }
                            if !removePlan {
                                DatePicker("开始时间", selection: $start).disabled(frozen != nil)
                                DatePicker("结束时间", selection: $end).disabled(frozen != nil)
                            }
                            if kind == "reschedule" {
                                let conflicts = ScheduleCalendar.conflicts(interviews, excluding: item.id, start: start, end: end)
                                if !conflicts.isEmpty { Text("与 \(conflicts.count) 场安排重叠，请确认时间。").foregroundStyle(.orange); ForEach(conflicts) { Text($0.caption).font(.system(size: 12)) } }
                                Toggle("确认仍保存有时间冲突的安排", isOn: $allowConflict).disabled(frozen != nil)
                            }
                        } else if kind == "edit" {
                            Picker("面试方式", selection: $mode) { Text("视频").tag("video"); Text("现场").tag("onsite"); Text("电话").tag("phone"); Text("其他").tag("other") }
                            field("会议或作答链接", $meeting); field("地点", $location)
                            field("面试官姓名", $interviewer); field("面试官职位", $interviewerTitle)
                            field("准备备注", $note)
                        } else if kind == "complete" {
                            Text("确认标记完成；可同时记录面试问题和复盘。")
                            field("面试问题（可选）", $questions); field("复盘总结（可选）", $review); field("改进计划（可选）", $improvement)
                        } else if kind == "cancel" { Text("确认取消这场安排，历史记录仍会保留。"); field("取消原因（可选）", $reason) }
                    }
                    if let failure { Text(failure).foregroundStyle(.red).font(.system(size: 13)).textSelection(.enabled) }
                }.padding(24)
            }
            HStack(spacing: 10) {
                if kind != "detail" && action.kind == "detail" { Button("返回详情") { kind = "detail"; frozen = nil }.buttonStyle(CareerActionStyle(kind: .text)).disabled(busy) }
                Spacer()
                Button("取消", action: close).buttonStyle(V3ButtonStyle(kind: .ghost, height: 36)).disabled(busy)
                if kind != "detail" { Button(busy ? "保存中…" : "确认保存") { Task { await save() } }.buttonStyle(V3ButtonStyle(kind: .dark, height: 36)).disabled(busy || item == nil) }
            }.padding(.horizontal, 28).frame(height: 76).overlay(alignment: .top) { Rectangle().fill(V3.line).frame(height: 1) }
        }.interactiveDismissDisabled(busy).task {
            item = nil; kind = action.kind; start = action.start; end = action.end; busy = true
            do {
                let data = try await api.careerRequest(path: "/api/interview-sessions/\(action.interview!.id)", method: "GET", query: [:], body: nil)
                try Task.checkCancellation()
                item = ScheduledInterview(data["session"] ?? .null)
                fill()
            } catch { failure = explain(error) }
            busy = false
        }
    }
    private func display(_ date: Date) -> String { let f = Beijing.formatter(); f.dateFormat = "M月d日 HH:mm"; return f.string(from: date) }
    private func field(_ label: String, _ value: Binding<String>) -> some View { VStack(alignment: .leading, spacing: 6) { Text(label).font(.system(size: 12)); TextField(label, text: value, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder) }.disabled(frozen != nil) }
    private func fill() {
        guard let item else { return }
        mode = item.raw.text("mode"); meeting = item.raw.text("meeting_url"); location = item.raw.text("location")
        interviewer = item.raw.text("interviewer_name"); interviewerTitle = item.raw.text("interviewer_title"); note = item.raw.text("preparation_note")
        questions = item.raw.text("questions_markdown"); review = item.raw.text("review_summary"); improvement = item.raw.text("improvement_markdown")
    }
    private func begin(_ command: String) {
        guard let item else { return }; kind = command; failure = nil; frozen = nil; removePlan = false
        start = CareerApplication.date(item.raw.text(command == "answer-plan" ? "answer_plan_start_at" : "start_at")) ?? item.start
        end = CareerApplication.date(item.raw.text(command == "answer-plan" ? "answer_plan_end_at" : "end_at")) ?? item.end
        fill()
    }
    private func save() async {
        guard let item, item.editable, !busy else { return }
        if ["reschedule", "answer-plan"].contains(kind) && !removePlan && end <= start { failure = "结束时间须晚于开始时间。"; return }
        if kind == "answer-plan" && !removePlan && (start < item.start || end > item.end) { failure = "个人作答计划必须位于开放窗口内。"; return }
        busy = true; failure = nil
        do {
            if frozen == nil {
                var body: [String: JSONValue] = ["base_lock_version": item.raw["lock_version"] ?? .number(1)]
                let f = ISO8601DateFormatter()
                switch kind {
                case "reschedule":
                    body["start_at"] = .string(f.string(from: start)); body["end_at"] = .string(f.string(from: end)); body["timezone"] = .string(Beijing.identifier); body["allow_conflict"] = .bool(allowConflict)
                case "answer-plan":
                    body["answer_plan_start_at"] = removePlan ? .null : .string(f.string(from: start)); body["answer_plan_end_at"] = removePlan ? .null : .string(f.string(from: end))
                case "complete":
                    body["questions_markdown"] = .string(questions); body["review_summary"] = .string(review); body["improvement_markdown"] = .string(improvement)
                case "cancel": body["reason"] = reason.isEmpty ? .null : .string(reason)
                case "edit":
                    body["mode"] = .string(mode); body["meeting_url"] = meeting.isEmpty ? .null : .string(meeting); body["location"] = location.isEmpty ? .null : .string(location)
                    body["interviewer_name"] = interviewer.isEmpty ? .null : .string(interviewer); body["interviewer_title"] = interviewerTitle.isEmpty ? .null : .string(interviewerTitle); body["preparation_note"] = note.isEmpty ? .null : .string(note)
                default: throw APIError.invalidResponse
                }
                frozen = .object(body)
            }
            let path = "/api/interview-sessions/\(item.id)" + (kind == "edit" ? "" : "/\(kind)")
            _ = try await api.careerRequest(path: path, method: ["edit", "answer-plan"].contains(kind) ? "PUT" : "POST", query: [:], body: frozen)
            completed()
        } catch {
            if case APIError.server(let status, let code) = error, [400, 422, 409].contains(status), code != "INTERVIEW_EDIT_CONFLICT" { frozen = nil }
            failure = explain(error)
        }
        busy = false
    }
    private func explain(_ error: Error) -> String {
        if case APIError.unauthorized = error { return "登录已失效，请重新登录。"}
        if case APIError.server(let status, let code) = error {
            if status == 409 { return "时间或版本冲突（\(code)）。请确认时间；若记录已变化，请关闭并刷新。" }
            return "保存失败（\(code)），输入已保留。"
        }
        return "连接失败，结果尚未确认。重试会保留原版本，不会覆盖其他修改。"
    }
}
