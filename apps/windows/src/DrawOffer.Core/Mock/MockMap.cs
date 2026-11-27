using System.Globalization;
using System.Text.Json.Nodes;

namespace DrawOffer.Core.Models;

/// <summary>模拟面试 V2 的提问路线、场次统计、类型与难度名称、下一场目标选择和日期文案（Web `mock-interview/v2/pathModel.ts`、`homeModel.ts`）。</summary>
public static class MockMap
{
    // MARK: 提问路线（pathModel）

    public sealed record Round(JsonNode Main, List<JsonNode> Turns, string Topic, double From, double To, bool? Ok, bool Skipped, bool Intro);

    internal static double Depth(JsonNode question) => question.Number("depth_level") ?? 0;

    public static bool IsIntro(JsonNode? detail, JsonNode question) =>
        detail.Get("has_intro").Bool() && question.Text("kind") == "main" && (question.Number("plan_index") ?? -1) == 0;

    public static List<Round> Rounds(JsonNode? detail)
    {
        var questions = detail.Items("questions");
        static double Sequence(JsonNode q) => q.Number("sequence_no") ?? 0;
        var mains = questions.Where(x => x.Text("kind") == "main").OrderBy(Sequence).ToList();
        return mains.Select(main =>
        {
            var id = main.Display("id");
            var turns = new List<JsonNode> { main };
            turns.AddRange(questions.Where(x => x.Display("parent_id") == id && id.Length > 0).OrderBy(Sequence));
            var from = Math.Max(1, Depth(main) == 0 ? 1 : Depth(main));
            var deepest = turns.Select(x => Depth(x) == 0 ? from : Depth(x)).DefaultIfEmpty(from).Max();
            var evaluation = main.Get("evaluation");
            var hasEvaluation = evaluation is not null;
            var skipped = main.Text("answer_status") == "skipped";
            var pending = turns.Any(x => x.Text("answer_status") == "pending");
            var achieved = evaluation.Number("achieved_depth") ?? 0;
            var reached = hasEvaluation ? Math.Max(1, achieved == 0 ? 1 : achieved) : deepest;
            var probed = evaluation.Number("probed_depth") ?? deepest;
            bool? ok;
            if (pending && !hasEvaluation && detail.Text("status") == "in_progress") ok = null;
            else if (skipped) ok = false;
            else if (hasEvaluation) ok = evaluation.Text("depth_status") == "met" || reached >= probed;
            else ok = turns[^1].Text("answer_status") == "answered";
            var topic = main.Text("topic").Length == 0 ? MockText.Prefix(main.Text("content"), 8) : main.Text("topic");
            var to = Math.Max(from, hasEvaluation ? Math.Max(reached, ok == true ? reached : probed) : deepest);
            return new Round(main, turns, topic, from, to, ok, skipped, IsIntro(detail, main));
        }).ToList();
    }

    public sealed record Stats(List<Round> Rounds, int Follows, int Answered, int? Minutes);

    public static Stats StatsOf(JsonNode? detail)
    {
        var rounds = Rounds(detail).Where(x => !x.Intro).ToList();
        var follows = detail.Items("questions").Count(x => x.Text("kind") == "follow_up");
        var answered = rounds.Count(x => x.Main.Text("answer_status") == "answered");
        int? minutes = null;
        if (Json.Date(detail.Text("started_at")) is { } start && Json.Date(detail.Text("finished_at")) is { } end)
            minutes = Math.Max(1, (int)Math.Round((end - start).TotalSeconds / 60, MidpointRounding.AwayFromZero));
        return new Stats(rounds, follows, answered, minutes);
    }

    // MARK: 首页模型（homeModel）

    public static readonly Dictionary<string, double> DiffLevel = new() { ["junior"] = 2, ["intermediate"] = 3, ["senior"] = 4 };
    public static readonly Dictionary<string, string> DiffName = new() { ["junior"] = "初级", ["intermediate"] = "中级", ["senior"] = "高级" };
    public static readonly Dictionary<string, string> TypeNames = new() { ["technical"] = "专业面", ["project_deep_dive"] = "项目深挖", ["comprehensive"] = "综合面", ["hr"] = "HR 面" };
    public static string TypeName(JsonNode? item) => item.Text("type_label").NonEmpty() ?? TypeNames.GetValueOrDefault(item.Text("interview_type")) ?? "综合面";

    // MARK: 下一场

    public enum TargetKind { Interview, Application, General }
    public sealed record Target(TargetKind Kind, JsonNode? Application, JsonNode? Session);

    internal static int StageRank(JsonNode application)
    {
        string[] order = ["screening", "assessment", "written_test", "ai_interview", "interview", "hr", "offer"];
        var type = application.Get("current_stage").Text("stage_type").NonEmpty() ?? application.Text("current_stage_type");
        return Math.Max(0, Array.IndexOf(order, type)) * 10 + application.Integer("current_round_no");
    }

    private static bool IsNull(JsonNode? node) => node is null;

    public static Target PickTarget(IReadOnlyList<JsonNode> applications, IReadOnlyList<JsonNode> sessions, DateTimeOffset now, string? chosen)
    {
        if (chosen == "general") return new Target(TargetKind.General, null, null);
        DateTimeOffset Date(string value) => Json.Date(value) ?? DateTimeOffset.MinValue;
        var active = applications.Where(x => x.Text("status") == "active" && IsNull(x.Get("archived_at")) && x.Text("lifecycle_status") != "terminated").ToList();
        var upcoming = sessions.Where(x => x.Text("status") == "scheduled" && Date(x.Text("end_at")) >= now).OrderBy(x => Date(x.Text("start_at"))).ToList();
        if (chosen is not null && (active.FirstOrDefault(x => x.Display("id") == chosen) ?? applications.FirstOrDefault(x => x.Display("id") == chosen)) is { } application)
        {
            var session = upcoming.FirstOrDefault(x => x.Display("application_id") == application.Display("id"));
            return new Target(session is null ? TargetKind.Application : TargetKind.Interview, application, session);
        }
        if (upcoming.FirstOrDefault(item => active.Any(x => x.Display("id") == item.Display("application_id"))) is { } next)
            return new Target(TargetKind.Interview, active.FirstOrDefault(x => x.Display("id") == next.Display("application_id")), next);
        var ranked = active.Where(x => !IsNull(x.Get("job_description_id"))).Select((x, i) => (x, i)).ToList();
        ranked.Sort((a, b) =>
        {
            int x = StageRank(a.x), y = StageRank(b.x);
            if (x != y) return x > y ? -1 : 1;
            string u = a.x.Text("updated_at"), v = b.x.Text("updated_at");
            return u != v ? (MockText.Less(v, u) ? -1 : 1) : a.i.CompareTo(b.i);
        });
        if (ranked.Count > 0) return new Target(TargetKind.Application, ranked[0].x, null);
        return new Target(TargetKind.General, null, null);
    }

    internal static readonly string[] Weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

    /// <summary>两个时刻在 `zone` 里相差的自然日数（Swift 传 Calendar，这里传时区）。</summary>
    public static int DayDiff(DateTimeOffset from, DateTimeOffset to, TimeZoneInfo? zone = null)
    {
        zone ??= Beijing.Zone;
        var a = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(from, zone).DateTime);
        var b = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(to, zone).DateTime);
        return b.DayNumber - a.DayNumber;
    }

    public static string RelativeDay(DateTimeOffset date, DateTimeOffset now, TimeZoneInfo? zone = null)
    {
        zone ??= Beijing.Zone;
        var diff = DayDiff(now, date, zone);
        var local = TimeZoneInfo.ConvertTime(date, zone);
        if (diff == 0) return local.Hour >= 18 ? "今晚" : "今天";
        if (diff == 1) return "明天";
        if (diff > 1 && diff < 7) return Weekdays[(int)local.DayOfWeek];
        return local.Month.ToString(CultureInfo.InvariantCulture) + "·" + local.Day.ToString("00", CultureInfo.InvariantCulture);
    }

    public static string Hhmm(DateTimeOffset date, TimeZoneInfo? zone = null)
    {
        var local = TimeZoneInfo.ConvertTime(date, zone ?? Beijing.Zone);
        return local.Hour.ToString("00", CultureInfo.InvariantCulture) + ":" + local.Minute.ToString("00", CultureInfo.InvariantCulture);
    }

    public static string MmddDot(DateTimeOffset date, TimeZoneInfo? zone = null)
    {
        var local = TimeZoneInfo.ConvertTime(date, zone ?? Beijing.Zone);
        return local.Month.ToString("00", CultureInfo.InvariantCulture) + "·" + local.Day.ToString("00", CultureInfo.InvariantCulture);
    }
    public static string MmddDot(string value, TimeZoneInfo? zone = null) => Json.Date(value) is { } date ? MmddDot(date, zone) : "";
}
