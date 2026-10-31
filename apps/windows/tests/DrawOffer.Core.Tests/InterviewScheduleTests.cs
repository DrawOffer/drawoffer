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
        Assert.Equal(["2"], ScheduleCalendar.Conflicts([a, b, c, d], null, from, until).Select(x => x.Id));
        Assert.Empty(ScheduleCalendar.Conflicts([a, b, c, d], "2", from, until));
        Assert.False(a.Overlaps(from, until));
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
        var window = Appointment("4", "2029-12-31T09:00:00Z", "2030-01-02T10:00:00Z", window: true);
        Assert.Equal(["1", "2", "3"], ScheduleCalendar.Upcoming([window, c, a, b], At("2030-01-01T08:00:00Z")).Select(x => x.Id));
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
