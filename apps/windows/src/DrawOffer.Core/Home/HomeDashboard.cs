using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using S = DrawOffer.Core.Models.SwiftCompat;

namespace DrawOffer.Core.Home;

/// <summary>
/// 首页卡片规则（Web `features/assistant/homeDashboard.ts`，Figma“01.1 首页 · 状态变体”）：
/// 三个卡片位各自按顺序取第一个满足条件的候选；没有简历的账号固定三张引导卡。规则只读数据，不经过 AI。
/// 位置 2 的完整度由 <see cref="ResumeCompleteness"/> 按 Web 同一规则从最近编辑简历的预览正文计算。
/// Swift 的 `calendar` 参数在这里是 `zone`（默认本机时区）。
/// </summary>
public sealed class HomeDashboard
{
    public enum DashboardVariant { New, Offer, Today, Deadline, Idle }

    /// <summary>卡片候选（Swift `enum Card` 的各个 case）。</summary>
    public abstract record Card
    {
        public sealed record FirstResume : Card;
        public sealed record Target : Card;
        public sealed record Plugin : Card;
        public sealed record Offer(string Company, string ApplicationID, string? ReplyDueOn) : Card;
        public sealed record Today(JsonNode? Session, int Others) : Card;
        public sealed record Deadline(JsonNode? Session, int DaysLeft) : Card;
        public sealed record Week(IReadOnlyList<JsonNode?> Sessions) : Card;
        public sealed record Compare(IReadOnlyList<JsonNode?> Offers) : Card;
        public sealed record ResumeTodo(ResumeSummary Resume, int Score, string Missing) : Card;
        public sealed record ResumeRecent(ResumeSummary Resume, int? Score) : Card;
        public sealed record Jobs : Card;
        public sealed record Pipeline(IReadOnlyList<JsonNode?> Applications, string Hint) : Card;
    }

    public DashboardVariant Variant { get; }
    public IReadOnlyList<Card> Cards { get; }
    public int TodayCount { get; }
    public string? OfferCompany { get; }
    public (string Company, int DaysLeft)? Deadline { get; }

    HomeDashboard(DashboardVariant variant, IReadOnlyList<Card> cards, int todayCount, string? offerCompany, (string, int)? deadline)
    {
        Variant = variant; Cards = cards; TodayCount = todayCount; OfferCompany = offerCompany; Deadline = deadline;
    }

    const int DeadlineDays = 3;
    /// <summary>Web `RESUME_TODO_THRESHOLD`。</summary>
    const int ResumeTodoThreshold = 90;
    const double Day = 86_400;

    public static HomeDashboard Build(DateTimeOffset now, IReadOnlyList<ResumeSummary> resumes, IReadOnlyList<JsonNode?> sessions, IReadOnlyList<JsonNode?> applications, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? TimeZoneInfo.Local;
        if (LatestResume(resumes) is not { } recent)
            return new HomeDashboard(DashboardVariant.New, [new Card.FirstResume(), new Card.Target(), new Card.Plugin()], 0, null, null);
        var todayStart = S.StartOfDay(now, tz);
        var tomorrowStart = S.Adding(todayStart, Day);
        var weekStart = StartOfWeek(now, tz);
        var weekEnd = S.Adding(weekStart, 7 * Day);
        var scheduled = sessions.Where(x => x.Text("status") == "scheduled")
            .OrderBy(x => Date(x.Text("start_at")) ?? S.DistantFuture).ToList();
        var today = scheduled.Where(x => Date(x.Text("start_at")) is { } start && start >= todayStart && start < tomorrowStart).ToList();
        var deadlineSession = scheduled.FirstOrDefault(session =>
            IsWrittenTest(session) && DeadlineOf(session) is { } end && end >= now && end < S.Adding(todayStart, (DeadlineDays + 1) * Day));
        var active = applications.Where(IsActive).ToList();
        var offers = active.Where(x => x.Text("offer_status") == "received")
            .OrderBy(x => OfferDate(x.Text("offer_reply_due_on"), tz) ?? S.DistantFuture).ToList();

        Card first;
        DashboardVariant variant;
        (string, int)? deadline = null;
        if (offers.Count > 0)
        {
            var offer = offers[0];
            first = new Card.Offer(offer.Text("company_name_snapshot"), offer.Text("id"), offer.Get("offer_reply_due_on").String());
            variant = DashboardVariant.Offer;
        }
        else if (today.Count > 0)
        {
            first = new Card.Today(today[0], today.Count - 1); variant = DashboardVariant.Today;
        }
        else if (deadlineSession is not null && DeadlineOf(deadlineSession) is { } end)
        {
            var days = Math.Max(0, (int)S.Round(S.Since(S.StartOfDay(end, tz), todayStart) / Day));
            first = new Card.Deadline(deadlineSession, days); variant = DashboardVariant.Deadline;
            deadline = (deadlineSession.Text("company_name"), days);
        }
        else
        {
            first = new Card.Week(scheduled.Where(x => Date(x.Text("start_at")) is { } start && start >= weekStart && start < weekEnd).ToList());
            variant = DashboardVariant.Idle;
        }
        var completeness = recent.Preview is { } preview ? ResumeCompleteness.Evaluate(preview.Data) : null;
        Card second;
        if (offers.Count >= 2) second = new Card.Compare(offers.Take(2).ToList());
        else if (completeness is not null && completeness.Score < ResumeTodoThreshold && completeness.Missing is { } missing) second = new Card.ResumeTodo(recent, completeness.Score, missing);
        else second = new Card.ResumeRecent(recent, completeness?.Score);
        Card third;
        if (first is Card.Week) third = new Card.Jobs();
        else if (active.Count == 0) third = new Card.Jobs();
        else third = new Card.Pipeline(active, PipelineHint(active, now));
        return new HomeDashboard(variant, [first, second, third], today.Count, offers.Count > 0 ? offers[0].Text("company_name_snapshot") : null, deadline);
    }

    /// <summary>Web `homeCopy`：没有 AI 问候接口，按位置 1 的主题给固定文案。</summary>
    public (string Title, string Subtitle, IReadOnlyList<string> Chips) Copy => Variant switch
    {
        DashboardVariant.New => ("先准备第一份简历吧。", "也可以直接在下面告诉我你的经历，我来起草。", ["帮我写第一版简历", "简历该写几页", "我适合什么岗位"]),
        DashboardVariant.Offer => ($"{OfferCompany ?? ""}的 Offer 还没回复。", "对比一下手上的机会，再决定怎么回复。", ["比较手上的 Offer", "帮我写回复邮件", "谈薪建议"]),
        DashboardVariant.Today => ("今天想推进什么？", $"今天有 {TodayCount} 场面试或笔试。", ["帮我准备今天的面试", "模拟一轮面试", "按 JD 改简历"]),
        DashboardVariant.Deadline => ("今天想推进什么？",
            Deadline is { } d ? (d.DaysLeft == 0 ? $"{d.Company}的笔试今天截止。" : $"{d.Company}的笔试 {d.DaysLeft} 天后截止。") : "",
            ["帮我准备笔试", "按 JD 改简历", "复盘上周面试"]),
        _ => ("今天没有安排。", "适合补一段项目经历，或者看看新岗位。", ["帮我找合适的岗位", "润色项目经历", "复盘上周面试"]),
    };

    /// <summary>岗位看板插图的四列：待投递 / 笔试 / 面试 / Offer。</summary>
    public static (int Pending, int Test, int Interview, int Offer) PipelineColumns(IEnumerable<JsonNode?> applications)
    {
        int pending = 0, test = 0, interview = 0, offer = 0;
        foreach (var application in applications)
        {
            var stage = application.Get("current_stage") is { } current ? current.Text("stage_type") : "";
            if (application.Text("offer_status") != "none" && application.Text("offer_status").Length > 0 || application.Text("current_stage_type") == "offer") offer += 1;
            else if (application.Text("phase") == "pending") pending += 1;
            else if (stage is "written_test" or "assessment") test += 1;
            else interview += 1;
        }
        return (pending, test, interview, offer);
    }

    /// <summary>最近更新的简历；并列时取最先出现的一份（Swift `max(by:)`）。</summary>
    public static ResumeSummary? LatestResume(IReadOnlyList<ResumeSummary> resumes) =>
        S.MaxBy(resumes, (a, b) => (Date(a.UpdatedAt) ?? S.DistantPast) < (Date(b.UpdatedAt) ?? S.DistantPast));

    /// <summary>本周一零点（`zone` 本地）。</summary>
    public static DateTimeOffset StartOfWeek(DateTimeOffset date, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? TimeZoneInfo.Local;
        var start = S.Local(date, tz).Date;
        var weekday = (int)start.DayOfWeek + 1; // 1 = Sunday
        var offset = (weekday + 5) % 7; // Monday = 0
        return S.FromLocal(start.AddDays(-offset), tz);
    }

    public static DateTimeOffset? Date(string value) => value.Length == 0 ? null : ResumeSummary.ParseTimestamp(value);

    internal static bool IsActive(JsonNode? application) =>
        application.Text("status") == "active" && application.Text("lifecycle_status") != "terminated" && application.Text("archived_at").Length == 0;

    internal static bool IsWrittenTest(JsonNode? session)
    {
        var label = session.Text("stage_label");
        return new[] { "笔试", "测评", "测试" }.Any(x => S.Has(label, x)) || session.Text("schedule_kind") == "open_window";
    }

    internal static DateTimeOffset? DeadlineOf(JsonNode? session) => Date(session.Text("answer_plan_end_at")) ?? Date(session.Text("end_at"));

    /// <summary>Offer 日期是不带时间的 YYYY-MM-DD，按本地日期解析（分量超出范围时顺延，与 Calendar 相同）。</summary>
    internal static DateTimeOffset? OfferDate(string value, TimeZoneInfo zone)
    {
        var parts = S.SplitCharacters(value, "-").Select(S.Int).OfType<long>().ToList();
        if (parts.Count != 3) return null;
        return S.FromComponents(parts[0], parts[1], parts[2], 0, zone);
    }

    internal static string PipelineHint(IReadOnlyList<JsonNode?> active, DateTimeOffset now)
    {
        if (active.FirstOrDefault(x => x.Text("offer_status") == "received") is { } offer) return $"{offer.Text("company_name_snapshot")} Offer 待回复";
        if (active.FirstOrDefault(x => x.Text("stage_state") == "awaiting_result") is { } waiting)
            return $"{waiting.Text("company_name_snapshot")}{waiting.Text("current_stage_label")}结果待出";
        var weekAgo = S.Adding(now, -7 * Day);
        var fresh = active.Count(x => (Date(x.Text("applied_at")) ?? S.DistantPast) >= weekAgo);
        return fresh > 0 ? $"本周新增 {fresh} 个投递" : "按阶段查看每个岗位";
    }
}
