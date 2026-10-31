using System.Text.Json.Nodes;
namespace DrawOffer.Core.Models;

/// <summary>面试日程里的一场安排（`interview-sessions` 的一项）。</summary>
public sealed record ScheduledInterview(JsonNode Raw)
{
    public string Text(string key) => Raw.Text(key);
    public string Id => Raw.Text("id");
    public string ApplicationId => Raw.Text("application_id");
    public string Company => Raw.Text("company_name");
    public string Title => Raw.Text("job_title");
    public string Label => Raw.Text("stage_label");
    public DateTimeOffset Start => CareerApplication.Date(Raw.Text("start_at")) ?? SwiftDates.DistantPast;
    public DateTimeOffset End => CareerApplication.Date(Raw.Text("end_at")) ?? Start;
    public bool OpenWindow => Raw.Text("schedule_kind") == "open_window";
    public bool Editable => Raw.Text("status") == "scheduled";

    /// <summary>开放窗口按「我的作答计划」投到日历上；没有有效计划时为 null。官方起止时间保持不变。</summary>
    public ScheduledInterview? Timed
    {
        get
        {
            if (!OpenWindow) return this;
            if (CareerApplication.Date(Raw.Text("answer_plan_start_at")) is not { } from || CareerApplication.Date(Raw.Text("answer_plan_end_at")) is not { } to || from >= to) return null;
            if (Raw is not JsonObject) return null;
            var copy = Raw.DeepClone();
            copy["start_at"] = Raw.Get("answer_plan_start_at")?.DeepClone();
            copy["end_at"] = Raw.Get("answer_plan_end_at")?.DeepClone();
            return new ScheduledInterview(copy);
        }
    }

    public string Caption => Company + " · " + Label;

    public string Status(DateTimeOffset now)
    {
        if (Raw.Text("status") == "cancelled") return "已取消";
        if (Raw.Text("status") == "completed") return "已完成";
        if (End <= now) return OpenWindow ? "已截止" : "等待结果";
        if (Start <= now) return OpenWindow ? "待完成" : "进行中";
        return OpenWindow ? "未开始" : "已安排";
    }

    /// <summary>半开区间重叠。</summary>
    public bool Overlaps(DateTimeOffset from, DateTimeOffset to) => Start < to && End > from;
}

public static class ScheduleCalendar
{
    /// <summary>所在周的周一零点（按 <paramref name="zone"/>）。</summary>
    public static DateTimeOffset WeekStart(DateTimeOffset date, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? TimeZoneInfo.Local;
        var day = SwiftCalendar.StartOfDay(date, tz);
        var weekday = SwiftCalendar.Weekday(day, tz);
        return SwiftCalendar.AddDays(day, -((weekday + 5) % 7), tz);
    }

    /// <summary>月历格子：从包含 1 日的那周周一到包含月末那周的周日，实际为 4、5 或 6 周。</summary>
    public static List<DateTimeOffset> MonthDays(DateTimeOffset date, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? TimeZoneInfo.Local;
        var local = SwiftCalendar.Local(date, tz);
        var monthStart = SwiftCalendar.Resolve(new DateTime(local.Year, local.Month, 1), tz);
        var next = local.Month == 12 ? new DateTime(local.Year + 1, 1, 1) : new DateTime(local.Year, local.Month + 1, 1);
        var monthEnd = SwiftCalendar.Resolve(next, tz);
        var first = WeekStart(monthStart, tz);
        var last = SwiftCalendar.AddDays(monthEnd, -1, tz);
        var end = SwiftCalendar.AddDays(WeekStart(last, tz), 7, tz);
        var days = new List<DateTimeOffset>();
        for (var current = first; current < end; current = SwiftCalendar.AddDays(current, 1, tz)) days.Add(current);
        return days;
    }

    /// <summary>本地某天某时刻（UI 用），按 <paramref name="zone"/> 解析墙钟时间。</summary>
    public static DateTimeOffset LocalDate(DateOnly date, TimeSpan time = default, TimeZoneInfo? zone = null) =>
        SwiftCalendar.Resolve(date.ToDateTime(TimeOnly.MinValue).Add(time), zone ?? TimeZoneInfo.Local);

    public static List<ScheduledInterview> Conflicts(IEnumerable<ScheduledInterview> items, string? excluding, DateTimeOffset start, DateTimeOffset end) =>
        items.Where(x => x.Id != excluding && x.Editable && !x.OpenWindow && x.Overlaps(start, end)).ToList();

    public static List<ScheduledInterview> Upcoming(IEnumerable<ScheduledInterview> items, DateTimeOffset now) =>
        CareerJson.StableSort(items.Where(x => x.Editable && x.End > now), (a, b) => (a.OpenWindow ? a.End : a.Start).CompareTo(b.OpenWindow ? b.End : b.Start)).Take(3).ToList();

    /// <summary>每组相互重叠的安排各自分道；首尾相接的安排共用一道。</summary>
    public static Dictionary<string, (int Index, int Count)> Lanes(IEnumerable<ScheduledInterview> items)
    {
        var sorted = CareerJson.StableSort(items, (a, b) => a.Start == b.Start ? SwiftText.Compare(a.Id, b.Id) : a.Start.CompareTo(b.Start));
        var result = new Dictionary<string, (int, int)>();
        var group = new List<ScheduledInterview>();
        var boundary = SwiftDates.DistantPast;
        void Flush()
        {
            var ends = new List<DateTimeOffset>(); var indices = new Dictionary<string, int>();
            foreach (var item in group)
            {
                var lane = ends.FindIndex(x => x <= item.Start);
                if (lane < 0) { lane = ends.Count; ends.Add(item.End); } else ends[lane] = item.End;
                indices[item.Id] = lane;
            }
            foreach (var item in group) result[item.Id] = (indices[item.Id], ends.Count);
        }
        foreach (var item in sorted)
        {
            if (item.Start >= boundary && group.Count > 0) { Flush(); group.Clear(); }
            group.Add(item);
            var latest = group.Max(x => x.End);
            boundary = latest > item.End ? latest : item.End;
        }
        if (group.Count > 0) Flush();
        return result;
    }
}
