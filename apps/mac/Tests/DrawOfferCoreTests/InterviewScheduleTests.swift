import Foundation
import Testing
@testable import DrawOfferCore

private func appointment(_ id: String, _ start: String, _ end: String, status: String = "scheduled", window: Bool = false) -> ScheduledInterview {
    ScheduledInterview(.object(["id": .string(id), "start_at": .string(start), "end_at": .string(end), "status": .string(status), "schedule_kind": .string(window ? "open_window" : "fixed_slot")]))
}
@Test func monthCalendarUsesActualFourFiveOrSixWeeksAndMondayStart() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    for (year, month, expected) in [(2021, 2, 28), (2026, 10, 35), (2026, 3, 42)] {
        let date = calendar.date(from: DateComponents(year: year, month: month, day: 15))!
        let days = ScheduleCalendar.monthDays(date, calendar: calendar)
        #expect(days.count == expected); #expect(calendar.component(.weekday, from: days[0]) == 2)
        #expect(Set(days).count == expected)
        #expect(days.filter { calendar.component(.month, from: $0) == month }.count == calendar.range(of: .day, in: .month, for: date)!.count)
    }
}
@Test func monthCalendarPreservesLocalMidnightAcrossDaylightSaving() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let days = ScheduleCalendar.monthDays(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15))!, calendar: calendar)
    #expect(days.allSatisfy { calendar.component(.hour, from: $0) == 0 })
    #expect(zip(days, days.dropFirst()).contains { $1.timeIntervalSince($0) == 23 * 3600 })
}
@Test func scheduleConflictsUseHalfOpenIntervalsAndIgnoreCancelledAndWindows() {
    let from = CareerApplication.date("2030-01-01T10:00:00Z")!, until = from.addingTimeInterval(3600)
    let a = appointment("1", "2030-01-01T09:00:00Z", "2030-01-01T10:00:00Z")
    let b = appointment("2", "2030-01-01T10:30:00Z", "2030-01-01T11:30:00Z")
    let c = appointment("3", "2030-01-01T10:00:00Z", "2030-01-01T11:00:00Z", status: "cancelled")
    let d = appointment("4", "2030-01-01T00:00:00Z", "2030-01-02T00:00:00Z", window: true)
    #expect(ScheduleCalendar.conflicts([a,b,c,d], excluding: nil, start: from, end: until).map(\.id) == ["2"])
    #expect(ScheduleCalendar.conflicts([a,b,c,d], excluding: "2", start: from, end: until).isEmpty)
    #expect(!a.overlaps(from, until))
}
@Test func overlappingEventsUseIndependentLanes() {
    let a = appointment("1", "2030-01-01T09:00:00Z", "2030-01-01T10:00:00Z")
    let b = appointment("2", "2030-01-01T09:30:00Z", "2030-01-01T10:30:00Z")
    let c = appointment("3", "2030-01-01T10:30:00Z", "2030-01-01T11:30:00Z")
    let lanes = ScheduleCalendar.lanes([c,b,a])
    #expect(lanes["1"]?.count == 2); #expect(lanes["2"]?.index == 1); #expect(lanes["3"]?.count == 1)
}
@Test func desktopSessionEditingHasNarrowMethodBoundary() {
    #expect(CareerRequest.allowed(path: "/api/interview-sessions/12", method: "PUT"))
    // Stage detail (04.C03) deletes a session; the backend keeps ownership checks.
    #expect(CareerRequest.allowed(path: "/api/interview-sessions/12", method: "DELETE"))
    #expect(!CareerRequest.allowed(path: "/api/interview-sessions/12", method: "POST"))
    #expect(!CareerRequest.allowed(path: "/api/interview-sessions/12", method: "PATCH"))
}

@Test func openWindowPersonalPlanProjectsWithoutChangingOfficialDates() {
    let official = ScheduledInterview(.object(["id": .string("9"), "schedule_kind": .string("open_window"), "start_at": .string("2030-01-01T00:00:00Z"), "end_at": .string("2030-01-05T00:00:00Z"), "answer_plan_start_at": .string("2030-01-02T10:00:00Z"), "answer_plan_end_at": .string("2030-01-02T11:00:00Z")]))
    #expect(official.timed?.start == CareerApplication.date("2030-01-02T10:00:00Z"))
    #expect(official.start == CareerApplication.date("2030-01-01T00:00:00Z"))
    #expect(official.timed?.id == official.id)
    #expect(appointment("1", "2030-01-01T00:00:00Z", "2030-01-05T00:00:00Z", window: true).timed == nil)
}

// MARK: 页头与新建入口（Web 08 · 07 / 08 · 09）

private func session(_ id: String, _ start: String, _ end: String, status: String = "scheduled", window: Bool = false, label: String = "一面",
                     company: String = "示例科技", title: String = "后端开发", extra: [String: JSONValue] = [:]) -> ScheduledInterview {
    var fields: [String: JSONValue] = ["id": .string(id), "start_at": .string(start), "end_at": .string(end), "status": .string(status),
                                       "schedule_kind": .string(window ? "open_window" : "fixed_slot"), "stage_label": .string(label),
                                       "company_name": .string(company), "job_title": .string(title)]
    fields.merge(extra) { $1 }
    return ScheduledInterview(.object(fields))
}
private func at(_ text: String) -> Date { CareerApplication.date(text)! }

@Test func scheduleHeadTitleCountsAndSubtitle() {
    let now = at("2026-09-27T06:00:00Z")  // 北京 9 月 27 日（周日）14:00
    #expect(SchedulePage.title(month: true, anchor: now) == "2026 年 9 月")
    #expect(SchedulePage.title(month: false, anchor: now) == "9 月 21 日 – 27 日")
    #expect(SchedulePage.title(month: false, anchor: at("2026-09-30T06:00:00Z")) == "9 月 28 日 – 10 月 4 日")
    let today = session("1", "2026-09-27T08:00:00Z", "2026-09-27T09:00:00Z", label: "三面", company: "字节跳动", title: "后端开发")
    let window = session("2", "2026-09-23T00:00:00Z", "2026-09-30T15:59:00Z", window: true, label: "笔试")
    let cancelled = session("3", "2026-09-27T10:00:00Z", "2026-09-27T11:00:00Z", status: "cancelled")
    let later = session("4", "2026-10-09T06:00:00Z", "2026-10-09T07:00:00Z", label: "二面", company: "阿里")
    let items = [later, window, cancelled, today]
    #expect(SchedulePage.rangeCount(items, month: true, anchor: now) == "本月 2 个日程")
    #expect(SchedulePage.rangeCount(items, month: false, anchor: now) == "本周 2 个日程")
    #expect(SchedulePage.subtitle(items, now: now) == "今天 1 场面试，下一场 16:00 字节跳动 · 后端开发 三面")
    #expect(SchedulePage.subtitle([later], now: now) == "今天没有面试，下一场 10 月 9 日 14:00 阿里 · 后端开发 二面")
    #expect(SchedulePage.subtitle([], now: now) == "今天没有面试")
}

@Test func scheduleAddStageAllowsPendingAndAwaitingResultOnly() {
    func app(_ fields: [String: JSONValue]) -> JSONValue {
        var base: [String: JSONValue] = ["id": .string("a"), "status": .string("active"), "archived_at": .null, "current_stage_type": .string("screening"), "stage_state": .string("awaiting_result"), "applied_at": .string("2026-09-01T00:00:00Z")]
        base.merge(fields) { $1 }
        return .object(base)
    }
    #expect(SchedulePage.canAddStage(app([:])))
    #expect(SchedulePage.canAddStage(app(["applied_at": .null, "phase": .string("pending"), "stage_state": .string("awaiting_schedule")])))
    #expect(!SchedulePage.canAddStage(app(["stage_state": .string("scheduled")])))
    #expect(!SchedulePage.canAddStage(app(["current_stage_type": .string("offer")])))
    #expect(!SchedulePage.canAddStage(app(["archived_at": .string("2026-09-02T00:00:00Z")])))
    #expect(!SchedulePage.canAddStage(app(["status": .string("rejected")])))
    #expect(SchedulePage.empty([]) == .noJobs)
    #expect(SchedulePage.empty([app(["archived_at": .string("2026-09-02T00:00:00Z")])]) == .noJobs)
    #expect(SchedulePage.empty([app(["stage_state": .string("scheduled")])]) == .noneEligible)
    #expect(SchedulePage.empty([app([:])]) == nil)
}

@Test func scheduleDetailRelativeDaysAndButtons() {
    let now = at("2026-09-27T06:00:00Z")  // 北京 14:00
    let video = session("1", "2026-09-27T08:00:00Z", "2026-09-27T09:00:00Z", label: "三面", extra: ["mode": .string("video"), "meeting_url": .string("https://meeting.example.com/abc")])
    let detail = ScheduleDetail(item: video, canReschedule: true, now: now)
    #expect(detail.relative == "还有 2 小时 0 分")
    #expect(detail.subtitle == "后端开发 · 待面试 · 还有 2 小时 0 分")
    #expect(detail.primary == .enter("进入会议")); #expect(detail.secondaryPractice); #expect(detail.showRecordLink)
    #expect(detail.timeValue == "9月27日 周日 16:00 – 17:00")
    // 明天晚上的面试是「明天」，不是按 24 小时算的「2 天后」
    let tomorrow = session("2", "2026-09-28T13:00:00Z", "2026-09-28T14:00:00Z", extra: ["mode": .string("video")])
    let noLink = ScheduleDetail(item: tomorrow, canReschedule: true, now: now)
    #expect(noLink.relative == "明天"); #expect(noLink.primary == .practice); #expect(noLink.missingVideoLink)
    #expect(noLink.note == "会议链接还没填，收到后在求职记录里补上，这里就会出现「进入会议」。")
    #expect(ScheduleDetail(item: session("3", "2026-10-01T06:00:00Z", "2026-10-01T07:00:00Z"), canReschedule: true, now: now).relative == "4 天后")
    let exam = ScheduleDetail(item: session("4", "2026-09-27T05:00:00Z", "2026-09-27T07:00:00Z", label: "笔试", extra: ["mode": .string("other")]), canReschedule: true, now: now)
    #expect(exam.statusLabel == "进行中"); #expect(exam.relative == "13:00 开始"); #expect(!exam.canPractice); #expect(exam.primary == .record); #expect(!exam.showRecordLink)
    #expect(exam.personLabel == nil)
    let done = ScheduleDetail(item: session("5", "2026-09-24T06:00:00Z", "2026-09-24T07:00:00Z", status: "completed", extra: ["interviewer_name": .string("李老师"), "interviewer_title": .string("技术负责人")]), canReschedule: false, now: now)
    #expect(done.subtitle == "后端开发 · 已完成 · 3 天前"); #expect(done.note == "复盘写在求职记录里，这一场不能再改期。"); #expect(done.person == "李老师（技术负责人）")
}

@Test func scheduleDetailAnswerWindowPlan() {
    let now = at("2026-09-27T06:00:00Z")
    let window = session("1", "2026-09-23T00:00:00Z", "2026-09-30T15:59:00Z", window: true, label: "在线笔试")
    let detail = ScheduleDetail(item: window, canReschedule: true, now: now)
    #expect(detail.statusLabel == "待完成"); #expect(detail.relative == "还剩 3 天截止"); #expect(detail.primary == .savePlan)
    #expect(detail.timeValue == "09-23 08:00 – 09-30 23:59")
    #expect(ScheduleDetail(item: window, canReschedule: true, now: at("2026-09-30T02:00:00Z")).relative == "今天截止")
    #expect(ScheduleDetail(item: window, canReschedule: false, now: now).primary == .record)
    #expect(ScheduleDetail.planProblem(start: at("2026-09-28T12:00:00Z"), minutes: 120, window: window) == nil)
    #expect(ScheduleDetail.planProblem(start: at("2026-09-22T12:00:00Z"), minutes: 60, window: window) == "开始时间早于官方开放时间 09-23 08:00，换晚一点。")
    #expect(ScheduleDetail.planProblem(start: at("2026-09-30T15:00:00Z"), minutes: 90, window: window) == "会做到 10-01 00:30，超过了截止时间 09-30 23:59，换早一点或缩短时长。")
    #expect(ScheduleDetail.planProblem(start: nil, minutes: 60, window: window) == nil)
}
