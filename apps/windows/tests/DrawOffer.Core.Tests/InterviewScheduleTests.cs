using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using Xunit;

namespace DrawOffer.Core.Tests;

/// <summary>移植自 Mac `InterviewScheduleTests.swift`：同名用例、同一组虚构数据、同样的断言。</summary>
public class InterviewScheduleTests
{
    static ScheduledInterview Appointment(string id, string start, string end, string status = "scheduled", bool window = false) =>
        new(new JsonObject { ["id"] = id, ["start_at"] = start, ["end_at"] = end, ["status"] = status, ["schedule_kind"] = window ? "open_window" : "fixed_slot" });

    static DateTimeOffset At(string text) => CareerApplication.Date(text)!.Value;

    [Theory]
    [InlineData(2021, 2, 28)]
    [InlineData(2026, 10, 35)]
    [InlineData(2026, 3, 42)]
    public void MonthCalendarUsesActualFourFiveOrSixWeeksAndMondayStart(int year, int month, int expected)
    {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("Asia/Shanghai");
        var date = new DateTimeOffset(year, month, 15, 0, 0, 0, zone.GetUtcOffset(new DateTime(year, month, 15)));
        var days = ScheduleCalendar.MonthDays(date, zone);
        DateTime Local(DateTimeOffset value) => TimeZoneInfo.ConvertTime(value, zone).DateTime;
        Assert.Equal(expected, days.Count);
        Assert.Equal(DayOfWeek.Monday, Local(days[0]).DayOfWeek);
        Assert.Equal(expected, days.Distinct().Count());
        Assert.Equal(DateTime.DaysInMonth(year, month), days.Count(x => Local(x).Month == month));
    }

    [Fact]
    public void DefaultCalendarAndUnzonedInputUseBeijingTime()
    {
        var date = new DateTimeOffset(2030, 1, 2, 9, 0, 0, TimeSpan.FromHours(8));
        Assert.Equal(date, CareerApplication.Date("2030-01-02T09:00:00"));
        Assert.All(ScheduleCalendar.MonthDays(date), day =>
        {
            Assert.Equal(TimeSpan.FromHours(8), day.Offset);
            Assert.Equal(0, day.Hour);
        });
    }

    [Fact]
    public void MonthCalendarPreservesLocalMidnightAcrossDaylightSaving()
    {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("America/New_York");
        var date = new DateTimeOffset(2026, 3, 15, 0, 0, 0, zone.GetUtcOffset(new DateTime(2026, 3, 15)));
        var days = ScheduleCalendar.MonthDays(date, zone);
        Assert.All(days, x => Assert.Equal(0, TimeZoneInfo.ConvertTime(x, zone).Hour));
        Assert.Contains(days.Zip(days.Skip(1)), pair => (pair.Second - pair.First).TotalSeconds == 23 * 3600);
    }

    [Fact]
    public void ScheduleConflictsUseHalfOpenIntervalsAndIgnoreCancelledAndWindows()
    {
        var from = At("2030-01-01T10:00:00Z");
        var until = from.AddSeconds(3600);
        var a = Appointment("1", "2030-01-01T09:00:00Z", "2030-01-01T10:00:00Z");
        var b = Appointment("2", "2030-01-01T10:30:00Z", "2030-01-01T11:30:00Z");
        var c = Appointment("3", "2030-01-01T10:00:00Z", "2030-01-01T11:00:00Z", status: "cancelled");
        var d = Appointment("4", "2030-01-01T00:00:00Z", "2030-01-02T00:00:00Z", window: true);
        var now = At("2029-12-31T00:00:00Z");
        Assert.Equal(b.Start, ScheduleOverlap.Find([a, b, c, d], "9", from, until, now)?.Start);
        Assert.Null(ScheduleOverlap.Find([a, b, c, d], "2", from, until, now));
        Assert.False(a.Overlaps(from, until));
    }

    // 同一时间只能参加一场（Web `scheduleConflicts.test.ts` · occupied slots，#1560）
    static readonly DateTimeOffset SlotBase = At("2026-10-09T06:00:00Z");
    static string SlotAt(int minutes) => SlotBase.AddMinutes(minutes).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture);
    static ScheduledInterview SlotSession(string id, string company, string stage, int startMin, int endMin, string status = "scheduled") =>
        new(new JsonObject { ["id"] = id, ["company_name"] = company, ["stage_label"] = stage, ["status"] = status, ["schedule_kind"] = "fixed_slot", ["start_at"] = SlotAt(startMin), ["end_at"] = SlotAt(endMin) });

    [Fact]
    public void OccupiedSlotFindsTheCollisionIgnoringTheMovedOneAndTouchingEdges()
    {
        var now = SlotBase.AddDays(-1);
        DateTimeOffset Date(int minutes) => SlotBase.AddMinutes(minutes);
        ScheduledInterview[] sessions = [SlotSession("1", "示例资讯", "一面", 0, 60), SlotSession("2", "示例云", "二面", 120, 180)];
        var hit = ScheduleOverlap.Find(sessions, "2", Date(30), Date(90), now);
        Assert.Equal("示例资讯", hit?.Company); Assert.Equal("一面", hit?.StageLabel);
        Assert.Null(ScheduleOverlap.Find(sessions, "2", Date(60), Date(120), now));
        Assert.Null(ScheduleOverlap.Find(sessions, "1", Date(0), Date(60), now));
        Assert.Null(ScheduleOverlap.Find([SlotSession("1", "示例资讯", "一面", 0, 60, "cancelled")], "2", Date(30), Date(90), now));
        Assert.Null(ScheduleOverlap.Find(sessions, "2", Date(30), Date(90), Date(61)));
        var planned = new ScheduledInterview(new JsonObject { ["id"] = "5", ["company_name"] = "示例云", ["stage_label"] = "笔试", ["status"] = "scheduled", ["schedule_kind"] = "open_window",
            ["start_at"] = SlotAt(-600), ["end_at"] = SlotAt(600), ["answer_plan_start_at"] = SlotAt(200), ["answer_plan_end_at"] = SlotAt(260) });
        Assert.Null(ScheduleOverlap.Find([planned], "2", Date(30), Date(90), now));
        Assert.Equal(Date(200), ScheduleOverlap.Find([planned], "2", Date(230), Date(300), now)?.Start);
    }

    [Fact]
    public void OccupiedSlotSaysWhichArrangementTakesTheTimeAndWhy()
    {
        var text = ScheduleOverlap.Describe(new OccupiedSlot("示例资讯科技", "一面", SlotBase, SlotBase.AddHours(1)));
        Assert.Contains("这个时间你已经安排了示例资讯一面", text);
        Assert.Contains("14:00–15:00", text);
        Assert.Contains("同一时间没法参加两场", text);
        Assert.Equal("这个时间你已经安排了示例资讯一面（10月9日周五 14:00–15:00），同一时间没法参加两场，换个时间吧。", text);
    }

    [Fact]
    public void OccupiedSlotIsReadFromTheServerError()
    {
        var payload = new JsonObject { ["error"] = "INTERVIEW_SCHEDULE_OVERLAP", ["conflict"] = new JsonObject { ["session_id"] = "7", ["company_name"] = "示例云", ["stage_label"] = "笔试", ["start_at"] = SlotAt(0), ["end_at"] = SlotAt(60) } };
        var error = new DrawOffer.Core.Api.ApiException(System.Net.HttpStatusCode.Conflict, "INTERVIEW_SCHEDULE_OVERLAP", payload);
        Assert.Equal("示例云", ScheduleOverlap.Slot(error)?.Company);
        Assert.Contains("示例云笔试", ScheduleOverlap.Message(error));
        Assert.Contains("已经有别的面试或笔试", ScheduleOverlap.Message(new DrawOffer.Core.Api.ApiException(System.Net.HttpStatusCode.Conflict, "INTERVIEW_SCHEDULE_OVERLAP")));
        Assert.Null(ScheduleOverlap.Message(new DrawOffer.Core.Api.ApiException(System.Net.HttpStatusCode.Conflict, "INTERVIEW_EDIT_CONFLICT")));
    }

    [Fact]
    public void OverlappingEventsUseIndependentLanesAndNextArrangementsUseWindowDeadline()
    {
        var a = Appointment("1", "2030-01-01T09:00:00Z", "2030-01-01T10:00:00Z");
        var b = Appointment("2", "2030-01-01T09:30:00Z", "2030-01-01T10:30:00Z");
        var c = Appointment("3", "2030-01-01T10:30:00Z", "2030-01-01T11:30:00Z");
        var lanes = ScheduleCalendar.Lanes([c, b, a]);
        Assert.Equal(2, lanes["1"].Count);
        Assert.Equal(1, lanes["2"].Index);
        Assert.Equal(1, lanes["3"].Count);
    }

    [Fact]
    public void DesktopSessionEditingHasNarrowMethodBoundary()
    {
        Assert.True(CareerRequest.Allowed("/api/interview-sessions/12", "PUT"));
        // 阶段详情（04.C03）可以删除一场安排；归属由后端校验
        Assert.True(CareerRequest.Allowed("/api/interview-sessions/12", "DELETE"));
        Assert.False(CareerRequest.Allowed("/api/interview-sessions/12", "POST"));
        Assert.False(CareerRequest.Allowed("/api/interview-sessions/12", "PATCH"));
    }

    [Fact]
    public void OpenWindowPersonalPlanProjectsWithoutChangingOfficialDates()
    {
        var official = new ScheduledInterview(new JsonObject
        {
            ["id"] = "9", ["schedule_kind"] = "open_window", ["start_at"] = "2030-01-01T00:00:00Z", ["end_at"] = "2030-01-05T00:00:00Z",
            ["answer_plan_start_at"] = "2030-01-02T10:00:00Z", ["answer_plan_end_at"] = "2030-01-02T11:00:00Z",
        });
        Assert.Equal(At("2030-01-02T10:00:00Z"), official.Timed?.Start);
        Assert.Equal(At("2030-01-01T00:00:00Z"), official.Start);
        Assert.Equal(official.Id, official.Timed?.Id);
        Assert.Null(Appointment("1", "2030-01-01T00:00:00Z", "2030-01-05T00:00:00Z", window: true).Timed);
    }
}
