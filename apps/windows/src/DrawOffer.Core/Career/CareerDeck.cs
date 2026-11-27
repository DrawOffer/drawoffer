using System.Text.Json.Nodes;
namespace DrawOffer.Core.Models;

/// <summary>站点类型。</summary>
public enum CareerStationKind { Apply, Screening, Written, Interview, Oc, Offer }

/// <summary>
/// 求职进度页的视图模型，对应 Web `features/interviews/progress/progressDeck.ts` 的 `buildDeck` / `buildLine`：
/// 投递是第 1 站，之后每个记录的阶段一站；左侧站点线的段长跟着每站用掉的天数。
/// </summary>
/// <param name="Short">站点线上的短名：投递 / 筛选 / 笔试 / 一面 / OC …</param>
/// <param name="End">离开这一站的时间；当前站为 null。</param>
/// <param name="Index">从 1 开始，显示为「第 N 站」。</param>
public sealed record CareerStation(string Id, JsonNode? Stage, CareerStationKind Kind, string Short, string Title, DateTimeOffset Start, DateTimeOffset? End, JsonNode? Session, bool Current, string Result, int Index);

public enum CareerDeckEndedKind { Rejected, Accepted, Withdrew, Declined, Other }

public sealed record CareerDeckEnded(CareerDeckEndedKind Kind, DateTimeOffset At);

public static class CareerDeckFormat
{
    public static string Two(int value) => value < 10 ? "0" + value : value.ToString(System.Globalization.CultureInfo.InvariantCulture);

    public static string MonthDay(DateTimeOffset? date, TimeZoneInfo? zone = null)
    {
        if (date is not { } value) return "—";
        var local = SwiftCalendar.Local(value, zone ?? Beijing.Zone);
        return Two(local.Month) + "." + Two(local.Day);
    }

    public static string Clock(DateTimeOffset date, TimeZoneInfo? zone = null)
    {
        var local = SwiftCalendar.Local(date, zone ?? Beijing.Zone);
        return Two(local.Hour) + ":" + Two(local.Minute);
    }

    public static string Weekday(DateTimeOffset date, TimeZoneInfo? zone = null) =>
        "周" + new[] { "日", "一", "二", "三", "四", "五", "六" }[(SwiftCalendar.Weekday(date, zone ?? Beijing.Zone) - 1) % 7];

    public static int DayCount(DateTimeOffset from, DateTimeOffset to, TimeZoneInfo? zone = null) => Math.Max(0, CareerFormat.Days(from, to, zone));

    /// <summary>「还有 2 天 4 小时」；已过返回 null。</summary>
    public static string? Remaining(DateTimeOffset target, DateTimeOffset now, string prefix = "还有")
    {
        var diff = (target - now).TotalSeconds;
        if (diff <= 0) return null;
        const double day = 86_400.0;
        var days = (int)(diff / day);
        var hours = (int)(diff % day / 3600);
        var minutes = Math.Max(1, (int)(diff % 3600 / 60));
        if (days > 0) return hours > 0 ? $"{prefix} {days} 天 {hours} 小时" : $"{prefix} {days} 天";
        if (hours > 0) return $"{prefix} {hours} 小时";
        return $"{prefix} {minutes} 分钟";
    }
}

public sealed class CareerDeck
{
    public IReadOnlyList<CareerStation> Stations { get; }
    public bool Pending { get; }
    public CareerDeckEnded? Ended { get; }
    public string StageState { get; }
    public int Days { get; }
    public string DaysLabel { get; }
    public int Reviews { get; }
    public IReadOnlyList<JsonNode> Sessions { get; }
    public CareerStation? Current => Stations.FirstOrDefault(x => x.Current);
    readonly TimeZoneInfo _zone;

    internal static CareerStationKind Kind(JsonNode stage) => stage.Text("stage_type") switch
    {
        "screening" => CareerStationKind.Screening,
        "written_test" or "assessment" => CareerStationKind.Written,
        "oc" => CareerStationKind.Oc,
        "offer" => CareerStationKind.Offer,
        _ => CareerStationKind.Interview,
    };

    internal static string Short(JsonNode stage)
    {
        switch (stage.Text("stage_type"))
        {
            case "screening": return "筛选";
            case "written_test": return "笔试";
            case "assessment": return "测评";
            case "ai_interview": return "AI 面试";
            case "hr": return "HR 面";
            case "oc": return "OC";
            case "offer": return "Offer";
            default:
                var label = stage.Text("stage_label");
                var first = SwiftText.Split(label, c => c == "·" || SwiftText.IsWhitespace(c)).FirstOrDefault() ?? "";
                return first.Length == 0 ? label : first;
        }
    }

    internal static string Title(JsonNode stage, JsonNode? session)
    {
        var type = stage.Text("stage_type");
        var label = SwiftText.TrimWhitespaces(stage.Text("stage_label"));
        switch (type)
        {
            case "screening": return "简历筛选";
            case "oc": return "OC · 口头意向";
            case "offer": return "Offer";
            case "written_test" or "assessment":
                var kind = type == "written_test" ? "笔试" : "测评";
                if (label.Length > 0 && label != kind) return SwiftText.Contains(label, kind) ? label : $"{kind} · {label}";
                if (session.Text("mode") == "onsite") return $"{kind} · 现场";
                return type == "written_test" ? "笔试 · 在线笔试" : "测评 · 在线测评";
            default: return label.Length == 0 ? Short(stage) : label;
        }
    }

    public static bool HasReview(JsonNode? session)
    {
        if (session is null) return false;
        if (session.Text("review_status") == "ready") return true;
        if (session.Get("review_report") is not null) return true;
        return SwiftText.TrimAll(session.Text("review_summary")).Length > 0;
    }

    public static string? Source(JsonNode app)
    {
        var channel = SwiftText.TrimAll(app.Text("applied_channel"));
        if (channel.Length > 0) return channel;
        var snapshot = app.Get("job_snapshot");
        var value = SwiftText.TrimAll(snapshot.Text("source_platform").Length == 0 ? snapshot.Text("source_channel") : snapshot.Text("source_platform"));
        return value.Length == 0 ? null : value;
    }

    /// <summary>早于阶段历史的记录只保存当前阶段，按它补一站。</summary>
    internal static JsonNode LegacyStage(JsonNode app, bool ended)
    {
        var column = CareerDetailModel.Column(app);
        var currentType = app.Text("current_stage_type");
        var type = currentType == "offer" ? "offer" : column == "written_test" ? "written_test" : column == "assessment" ? "assessment"
            : currentType == "screening" ? "screening" : currentType == "hr" ? "hr" : "interview";
        var label = SwiftText.TrimWhitespaces(app.Text("current_stage_label"));
        return new JsonObject
        {
            ["id"] = "legacy-" + app.Text("id"), ["stage_type"] = type,
            ["stage_label"] = label.Length == 0 ? CareerBoard.StageLabel(app) : label,
            ["sequence_no"] = 1.0, ["stage_result"] = app.Text("status") == "rejected" ? "rejected" : "pending",
            ["current_marker"] = ended ? null : 1.0,
            ["entered_at"] = app.Text("applied_at").Length == 0 ? app.Text("updated_at") : app.Text("applied_at"),
            ["completed_at"] = ended ? app.Text("updated_at") : null, ["updated_at"] = app.Text("updated_at"),
        };
    }

    public CareerDeck(JsonNode app, IEnumerable<JsonNode> all, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var at = now ?? Beijing.Now;
        _zone = zone ?? Beijing.Zone;
        DateTimeOffset Date(string field, string fallback) => CareerApplication.Date(app.Text(field)) ?? CareerApplication.Date(app.Text(fallback)) ?? at;
        var pending = CareerDetailModel.Column(app) == "pending";
        var terminated = app.Text("lifecycle_status") == "terminated" || app.Text("status") != "active";
        var accepted = app.Text("offer_status") == "accepted";
        CareerDeckEnded? ended = null;
        if (terminated || accepted)
        {
            string reason = app.Text("termination_reason"), status = app.Text("status");
            var kind = accepted ? CareerDeckEndedKind.Accepted
                : status == "rejected" || reason == "company_rejected" ? CareerDeckEndedKind.Rejected
                : app.Text("offer_status") == "declined" || reason == "offer_declined" ? CareerDeckEndedKind.Declined
                : status == "withdrawn" || reason == "user_withdrew" ? CareerDeckEndedKind.Withdrew : CareerDeckEndedKind.Other;
            ended = new(kind, Date("terminated_at", "updated_at"));
        }
        var appId = app.Text("id");
        var sessions = CareerJson.StableSort(all.Where(x => x.Text("application_id") == appId).Select(x => CareerSessions.WithEffectiveStatus(x, at)),
            (a, b) => (CareerApplication.Date(a.Text("start_at")) ?? SwiftDates.DistantPast).CompareTo(CareerApplication.Date(b.Text("start_at")) ?? SwiftDates.DistantPast));
        var recorded = CareerJson.StableSort(app.Items("stages"), (a, b) => a.Integer("sequence_no").CompareTo(b.Integer("sequence_no")));
        var stages = recorded.Count > 0 || pending ? recorded : [LegacyStage(app, ended is not null)];
        var currentId = app.Get("current_stage").Text("id").NonEmpty() ?? stages.FirstOrDefault(x => CareerJson.IsInteger(x.Get("current_marker"), 1))?.Text("id");

        var live = sessions.Where(x => x.Text("status") != "cancelled").ToList();
        JsonNode? SessionFor(JsonNode stage, bool current)
        {
            var label = SwiftText.TrimWhitespaces(stage.Text("stage_label"));
            return live.FirstOrDefault(x => x.Text("application_stage_id") == stage.Text("id"))
                ?? live.FirstOrDefault(x => x.Text("application_stage_id").Length == 0 && SwiftText.TrimWhitespaces(x.Text("stage_label")) == label)
                ?? (current ? live.FirstOrDefault(x => x.Text("application_stage_id").Length == 0 && CareerSessions.MatchesCurrentStage(app, x)) : null);
        }

        var applyStart = pending ? Date("created_at", "created_at") : Date("applied_at", "created_at");
        var firstEntered = stages.Count > 0 ? CareerApplication.Date(stages[0].Text("entered_at")) : null;
        var stations = new List<CareerStation>
        {
            new("apply", null, CareerStationKind.Apply, "投递", "投递", applyStart, pending ? null : firstEntered ?? ended?.At, null, pending, pending ? "pending" : "passed", 1),
        };
        for (var position = 0; position < stages.Count; position++)
        {
            var stage = stages[position];
            var isCurrent = ended is null && (currentId is { } id ? stage.Text("id") == id : position == stages.Count - 1);
            var match = SessionFor(stage, isCurrent);
            var next = position + 1 < stages.Count ? stages[position + 1] : null;
            DateTimeOffset? end = isCurrent ? null
                : (next is null ? null : CareerApplication.Date(next.Text("entered_at")))
                  ?? CareerApplication.Date(stage.Text("completed_at")) ?? ended?.At ?? CareerApplication.Date(stage.Text("updated_at"));
            stations.Add(new(stage.Text("id"), stage, Kind(stage), Short(stage), Title(stage, match), CareerApplication.Date(stage.Text("entered_at")) ?? at,
                end, match, isCurrent, stage.Text("stage_result"), position + 2));
        }

        var currentStation = stations.FirstOrDefault(x => x.Current);
        var scheduled = currentStation?.Session.Text("status") == "scheduled";
        var elapsed = currentStation?.Session.Text("status") == "completed";
        var stageState = app.Text("stage_state") == "scheduled" && !scheduled && elapsed ? "awaiting_result" : app.Text("stage_state");
        var daysFrom = pending ? Date("created_at", "created_at") : Date("applied_at", "created_at");

        Stations = stations;
        Pending = pending;
        Ended = ended;
        StageState = stageState;
        Days = CareerDeckFormat.DayCount(daysFrom, ended?.At ?? at, _zone);
        DaysLabel = pending ? "已导入" : ended is not null ? "共投递" : "已投递";
        Reviews = sessions.Count(x => HasReview(x));
        Sessions = sessions;
    }

    // 左侧站点线
}
