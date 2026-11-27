using System.Net;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DrawOffer.Core.Api;
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
        var tz = zone ?? Beijing.Zone;
        var day = SwiftCalendar.StartOfDay(date, tz);
        var weekday = SwiftCalendar.Weekday(day, tz);
        return SwiftCalendar.AddDays(day, -((weekday + 5) % 7), tz);
    }

    /// <summary>月历格子：从包含 1 日的那周周一到包含月末那周的周日，实际为 4、5 或 6 周。</summary>
    public static List<DateTimeOffset> MonthDays(DateTimeOffset date, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? Beijing.Zone;
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

/// <summary>新时间撞上的那一场：后端 409 `INTERVIEW_SCHEDULE_OVERLAP` 的 `conflict`，或拖动前本地查到的安排；开放窗口给的是作答计划时段。</summary>
public sealed record OccupiedSlot(string Company, string StageLabel, DateTimeOffset Start, DateTimeOffset End);

/// <summary>
/// 同一时间只能参加一场面试或笔试（Web `scheduleConflicts.ts` 的 scheduleOverlapMessage / describeOccupiedSlot / findOccupiedSlot，#1560）。
/// 后端拒绝重叠的安排并带回被占用的那一场；`allow_conflict` 不再放行。
/// </summary>
public static class ScheduleOverlap
{
    public const string Code = "INTERVIEW_SCHEDULE_OVERLAP";
    public const string GenericMessage = "这个时间已经有别的面试或笔试了，同一时间没法参加两场，换个时间吧。";
    static readonly string[] Weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

    /// <summary>Web `shortCompany`：去掉「科技 / 网络 / 集团 / 有限公司」等尾巴，全去掉了就用原名。</summary>
    public static string ShortCompany(string name)
    {
        var shortName = Regex.Replace(name, @"(科技|网络|信息技术|集团|股份|有限公司|（中国）|\(中国\))+$", "");
        return shortName.Length == 0 ? name : shortName;
    }

    /// <summary>「这个时间你已经安排了示例资讯一面（10月9日周五 14:00–15:00），同一时间没法参加两场，换个时间吧。」</summary>
    public static string Describe(OccupiedSlot slot, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? Beijing.Zone;
        var from = TimeZoneInfo.ConvertTime(slot.Start, tz);
        var to = TimeZoneInfo.ConvertTime(slot.End, tz);
        var time = $"{from.Month}月{from.Day}日{Weekdays[(int)from.DayOfWeek]} {from.ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture)}–{to.ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture)}";
        return $"这个时间你已经安排了{ShortCompany(slot.Company)}{slot.StageLabel}（{time}），同一时间没法参加两场，换个时间吧。";
    }

    /// <summary>从服务端错误里读出被占用的那一场；不是重叠错误或没带 `conflict` 时为 null。</summary>
    public static OccupiedSlot? Slot(Exception error)
    {
        if (error is not ApiException { Status: HttpStatusCode.Conflict, Code: Code } api) return null;
        var conflict = api.Payload?["conflict"];
        var company = conflict.Text("company_name");
        if (company.Length == 0 || CareerApplication.Date(conflict.Text("start_at")) is not { } start || CareerApplication.Date(conflict.Text("end_at")) is not { } end) return null;
        return new OccupiedSlot(company, conflict.Text("stage_label"), start, end);
    }

    /// <summary>Web `scheduleOverlapMessage`：是重叠错误就返回提示，否则 null。</summary>
    public static string? Message(Exception error, TimeZoneInfo? zone = null)
    {
        if (error is not ApiException { Status: HttpStatusCode.Conflict, Code: Code }) return null;
        return Slot(error) is { } slot ? Describe(slot, zone) : GenericMessage;
    }

    /// <summary>
    /// Web `findOccupiedSlot`：拖动改期前先在本地判断，最终仍以服务端校验为准。
    /// 只看待进行且未结束的安排；开放窗口按作答计划算，没计划的不占时间；首尾相接不算。
    /// </summary>
    public static OccupiedSlot? Find(IEnumerable<ScheduledInterview> items, string movingId, DateTimeOffset start, DateTimeOffset end, DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        foreach (var item in items)
        {
            if (item.Id == movingId || item.Raw.Text("status") != "scheduled") continue;
            if (item.Timed is not { } range || range.Start >= range.End || range.End <= current || range.Start >= end || range.End <= start) continue;
            return new OccupiedSlot(item.Company, item.Label, range.Start, range.End);
        }
        return null;
    }
}
