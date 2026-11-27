import Foundation

public struct ScheduledInterview: Identifiable, Sendable {
    public let raw: JSONValue
    public init(_ raw: JSONValue) { self.raw = raw }
    public var id: String { raw.text("id") }
    public var applicationID: String { raw.text("application_id") }
    public var company: String { raw.text("company_name") }
    public var title: String { raw.text("job_title") }
    public var label: String { raw.text("stage_label") }
    public var start: Date { CareerApplication.date(raw.text("start_at")) ?? .distantPast }
    public var end: Date { CareerApplication.date(raw.text("end_at")) ?? start }
    public var openWindow: Bool { raw.text("schedule_kind") == "open_window" }
    public var editable: Bool { raw.text("status") == "scheduled" }
    public var timed: ScheduledInterview? {
        guard openWindow else { return self }
        guard let from = CareerApplication.date(raw.text("answer_plan_start_at")), let to = CareerApplication.date(raw.text("answer_plan_end_at")), from < to else { return nil }
        guard case .object(var fields) = raw else { return nil }
        fields["start_at"] = raw["answer_plan_start_at"]
        fields["end_at"] = raw["answer_plan_end_at"]
        return ScheduledInterview(.object(fields))
    }
    public var caption: String { company + " · " + label }
    public func status(at now: Date) -> String {
        if raw.text("status") == "cancelled" { return "已取消" }
        if raw.text("status") == "completed" { return "已完成" }
        if end <= now { return openWindow ? "已截止" : "等待结果" }
        if start <= now { return openWindow ? "待完成" : "进行中" }
        return openWindow ? "未开始" : "已安排"
    }
    public func overlaps(_ from: Date, _ to: Date) -> Bool { start < to && end > from }
}

public enum ScheduleCalendar {
    public static func weekStart(_ date: Date, calendar: Calendar = Beijing.calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        return calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: day)!
    }
    public static func monthDays(_ date: Date, calendar: Calendar = Beijing.calendar) -> [Date] {
        let month = calendar.dateInterval(of: .month, for: date)!
        let first = weekStart(month.start, calendar: calendar)
        let last = calendar.date(byAdding: .day, value: -1, to: month.end)!
        let end = calendar.date(byAdding: .day, value: 7, to: weekStart(last, calendar: calendar))!
        var days: [Date] = []; var current = first
        while current < end { days.append(current); current = calendar.date(byAdding: .day, value: 1, to: current)! }
        return days
    }
    public static func conflicts(_ items: [ScheduledInterview], excluding id: String?, start: Date, end: Date) -> [ScheduledInterview] {
        items.filter { $0.id != id && $0.editable && !$0.openWindow && $0.overlaps(start, end) }
    }
    /// Each overlapping connected group gets independent lanes; back-to-back events share a lane.
    public static func lanes(_ items: [ScheduledInterview]) -> [String: (index: Int, count: Int)] {
        let sorted = items.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        var result: [String: (Int, Int)] = [:]; var group: [ScheduledInterview] = []; var boundary = Date.distantPast
        func flush() {
            var ends: [Date] = []; var indices: [String: Int] = [:]
            for item in group {
                let lane = ends.firstIndex { $0 <= item.start } ?? ends.count
                if lane == ends.count { ends.append(item.end) } else { ends[lane] = item.end }
                indices[item.id] = lane
            }
            for item in group { result[item.id] = (indices[item.id]!, ends.count) }
        }
        for item in sorted {
            if item.start >= boundary && !group.isEmpty { flush(); group = [] }
            group.append(item); boundary = max(group.map(\.end).max() ?? item.end, item.end)
        }
        if !group.isEmpty { flush() }
        return result
    }
}

/// 面试日程页头与新建入口（Web `InterviewCenterPage` 的 `ScheduleView` 页头、`canAddScheduledStage`）。
public enum SchedulePage {
    private static func format(_ date: Date, _ pattern: String) -> String { Beijing.formatter(pattern, locale: Locale(identifier: "zh_CN")).string(from: date) }

    /// 翻页组中间的日期：「2026 年 9 月」/「9 月 21 日 – 27 日」/ 跨月「9 月 28 日 – 10 月 4 日」。
    public static func title(month: Bool, anchor: Date, calendar: Calendar = Beijing.calendar) -> String {
        if month {
            let start = calendar.dateInterval(of: .month, for: anchor)!.start
            return "\(calendar.component(.year, from: start)) 年 \(calendar.component(.month, from: start)) 月"
        }
        let start = ScheduleCalendar.weekStart(anchor, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 6, to: start)!
        let (m1, d1, m2, d2) = (calendar.component(.month, from: start), calendar.component(.day, from: start), calendar.component(.month, from: end), calendar.component(.day, from: end))
        return m1 == m2 ? "\(m1) 月 \(d1) 日 – \(d2) 日" : "\(m1) 月 \(d1) 日 – \(m2) 月 \(d2) 日"
    }

    /// 眉题第二段「本月 / 本周 N 个日程」：与这一段时间有交集、没取消的安排。
    public static func rangeCount(_ items: [ScheduledInterview], month: Bool, anchor: Date, calendar: Calendar = Beijing.calendar) -> String {
        let start = month ? calendar.dateInterval(of: .month, for: anchor)!.start : ScheduleCalendar.weekStart(anchor, calendar: calendar)
        let end = month ? calendar.date(byAdding: .month, value: 1, to: start)! : calendar.date(byAdding: .day, value: 7, to: start)!
        let count = items.filter { $0.raw.text("status") != "cancelled" && $0.overlaps(start, end) }.count
        return "\(month ? "本月" : "本周") \(count) 个日程"
    }

    /// 副标题：今天几场面试 + 下一场。只数固定时段（开放作答窗口没有确切开始时间）。
    public static func subtitle(_ items: [ScheduledInterview], now: Date, calendar: Calendar = Beijing.calendar) -> String {
        let today = items.filter { $0.raw.text("status") != "cancelled" && !$0.openWindow && calendar.isDate($0.start, inSameDayAs: now) }.count
        let next = items.filter { !["cancelled", "completed"].contains($0.raw.text("status")) && !$0.openWindow && $0.start > now }.min { $0.start < $1.start }
        var text = today > 0 ? "今天 \(today) 场面试" : "今天没有面试"
        if let next {
            let when = calendar.isDate(next.start, inSameDayAs: now) ? format(next.start, "HH:mm") : format(next.start, "M 月 d 日 HH:mm")
            let role = [next.title, next.label].filter { !$0.isEmpty }.joined(separator: " ")
            text += "，下一场 \(when) " + [next.company, role].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return text
    }

    /// 日程里能直接加一场的岗位：没结束、没归档、没到 Offer，且待投递（后端补记投递时间）或上一轮在等结果。
    public static func canAddStage(_ application: JSONValue) -> Bool {
        guard application.text("status") == "active", application.text("archived_at").isEmpty, application.text("current_stage_type") != "offer" else { return false }
        if application.text("applied_at").isEmpty { return CareerBoard.projection(application).column == "pending" }
        return application.text("stage_state") == "awaiting_result"
    }

    /// 没有能安排的岗位时弹哪一种提示：看板上一个未归档岗位都没有 → `.noJobs`，否则 `.noneEligible`。
    public enum Empty: Equatable, Sendable { case noJobs, noneEligible }
    public static func empty(_ applications: [JSONValue]) -> Empty? {
        if applications.contains(where: canAddStage) { return nil }
        return applications.contains { $0.text("archived_at").isEmpty } ? .noneEligible : .noJobs
    }
}

/// 场次详情弹窗的文案与按钮（Web `InterviewScheduleDialog`，Figma 08 · 09）。
public struct ScheduleDetail: Sendable {
    public enum Primary: Equatable, Sendable { case savePlan, enter(String), practice, record }
    public let item: ScheduledInterview
    /// 场次仍为 scheduled 且所属岗位没归档。
    public let canReschedule: Bool
    public let now: Date
    let calendar: Calendar

    public init(item: ScheduledInterview, canReschedule: Bool, now: Date = Date(), calendar: Calendar = Beijing.calendar) {
        self.item = item; self.canReschedule = canReschedule; self.now = now; self.calendar = calendar
    }

    private func format(_ date: Date, _ pattern: String) -> String { Beijing.formatter(pattern, locale: Locale(identifier: "zh_CN")).string(from: date) }
    private var status: String { item.raw.text("status") }
    public var isWindow: Bool { item.openWindow }
    public var isExam: Bool { item.label.contains("笔试") }
    public var isTest: Bool { item.label.contains("测评") }
    public var isAI: Bool { item.label.range(of: "AI", options: .caseInsensitive) != nil }
    public var cancelled: Bool { status == "cancelled" }
    public var completed: Bool { status == "completed" }
    /// 还没完成也没取消（Web 的 upcoming / active）。
    public var live: Bool { !cancelled && !completed }
    public var active: Bool { live && item.start <= now && item.end > now }
    public var kindWord: String { isExam ? "笔试" : isTest ? "测评" : "面试" }
    public var title: String { item.company + " · " + item.label }

    public var statusLabel: String {
        if completed { return "已完成" }
        if cancelled { return "已取消" }
        if isWindow { return "待完成" }
        if active { return "进行中" }
        return isExam || isTest || isAI ? "待参加" : "待面试"
    }

    /// 相对时间按北京时间自然日算：明天 15:00 是「明天」，不是「2 天后」。
    private func daysUntil(_ date: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }
    public var relative: String {
        if isWindow {
            guard live else { return "" }
            if item.end <= now { return "已截止" }
            let days = daysUntil(item.end)
            return days <= 0 ? "今天截止" : "还剩 \(days) 天截止"
        }
        if active { return format(item.start, "HH:mm") + " 开始" }
        let until = item.start.timeIntervalSince(now)
        if live && until > 0 {
            let days = daysUntil(item.start)
            if days == 0 { return "还有 \(Int(until) / 3600) 小时 \(Int(until) % 3600 / 60) 分" }
            return days == 1 ? "明天" : "\(days) 天后"
        }
        if completed {
            let ago = -daysUntil(item.start)
            if ago >= 0 { return ago == 0 ? "今天" : "\(ago) 天前" }
        }
        return ""
    }
    public var subtitle: String { [item.title, statusLabel, relative].filter { !$0.isEmpty }.joined(separator: " · ") }

    public var timeLabel: String { isWindow ? "官方时段" : cancelled ? "原定时间" : "时间" }
    public var timeValue: String {
        isWindow ? format(item.start, "MM-dd HH:mm") + " – " + format(item.end, "MM-dd HH:mm")
            : format(item.start, "M月d日 EEE HH:mm") + " – " + format(item.end, "HH:mm")
    }

    /// 面试官「李老师（技术负责人）」；笔试、测评、AI 面试写作联系人，没填就不显示。
    public var person: String {
        let name = item.raw.text("interviewer_name"), role = item.raw.text("interviewer_title")
        if name.isEmpty { return role }
        return role.isEmpty ? name : "\(name)（\(role)）"
    }
    public var personLabel: String? {
        if !isExam && !isTest && !isAI { return "面试官" }
        return person.isEmpty ? nil : "联系人"
    }
    public var modeText: String { ["video": "视频面试", "onsite": "现场面试", "phone": "电话面试"][item.raw.text("mode")] ?? "其他方式" }
    public var meeting: String { item.raw.text("meeting_url") }
    public var showLink: Bool { !meeting.isEmpty && live }
    public var missingVideoLink: Bool { meeting.isEmpty && live && !isWindow && item.raw.text("mode") == "video" }
    public var linkLabel: String { isExam ? "笔试链接" : isTest ? "测评链接" : isAI ? "面试链接" : "会议链接" }
    public var planText: String {
        guard let start = CareerApplication.date(item.raw.text("answer_plan_start_at")), let end = CareerApplication.date(item.raw.text("answer_plan_end_at")) else { return "未安排" }
        return format(start, "MM-dd HH:mm") + " · \(max(1, Int((end.timeIntervalSince(start) / 60).rounded()))) 分钟"
    }

    public var note: String? {
        if !isWindow && completed { return "复盘写在求职记录里，这一场不能再改期。" }
        if isWindow && completed { return "已完成的\(kindWord)不能再改作答计划，题目和复盘在求职记录里。" }
        if missingVideoLink { return "会议链接还没填，收到后在求职记录里补上，这里就会出现「进入会议」。" }
        if !isWindow && item.raw.text("mode") == "onsite" && live && !active { return "现场面试没有会议链接，地点和时间在求职记录里改。" }
        return nil
    }

    /// 还没开始的面试可以先模拟一场（笔试、测评不适用）。
    public var canPractice: Bool { live && !isExam && !isTest }
    public var editablePlan: Bool { live && isWindow && canReschedule }
    public var enterLabel: String { isExam ? "进入笔试" : isTest ? "进入测评" : isAI ? "进入 AI 面试" : "进入会议" }
    /// 每个弹窗只有一个黑按钮：保存作答计划 > 进入会议 > 模拟这场面试 > 查看求职记录。
    public var primary: Primary {
        if editablePlan { return .savePlan }
        if live && !meeting.isEmpty { return .enter(enterLabel) }
        if canPractice { return .practice }
        return .record
    }
    /// 主按钮是「进入会议」时，「模拟这场面试」降为描边次按钮。
    public var secondaryPractice: Bool { !editablePlan && live && !meeting.isEmpty && canPractice }
    /// 左下「查看求职记录 ›」：主按钮已经是它时不重复。
    public var showRecordLink: Bool { primary != .record }

    /// 作答计划必须完整落在官方时段内；超出时说明怎么改（保存按钮随之不可点）。
    public static func planProblem(start: Date?, minutes: Int, window: ScheduledInterview) -> String? {
        guard let start else { return nil }
        let stamp = { (date: Date) in Beijing.formatter("MM-dd HH:mm").string(from: date) }
        let end = start.addingTimeInterval(Double(minutes) * 60)
        if start < window.start { return "开始时间早于官方开放时间 \(stamp(window.start))，换晚一点。" }
        if end > window.end { return "会做到 \(stamp(end))，超过了截止时间 \(stamp(window.end))，换早一点或缩短时长。" }
        return nil
    }
}
