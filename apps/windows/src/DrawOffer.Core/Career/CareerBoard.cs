using System.Globalization;
using System.Text.Json.Nodes;
namespace DrawOffer.Core.Models;

/// <summary>一条投递在看板与列表上的文案。对应 Web `applicationProgress.ts` 与 `ApplicationsBoard.tsx` 的卡片辅助函数，两端标签一致。</summary>
public sealed record CareerBoardProjection(string Column, string StageLabel, string StatusLabel, string? SupportingLabel, bool IsWaiting);

public static class CareerBoard
{
    internal static readonly HashSet<string> Scheduled = ["assessment", "written_test", "interview"];

    static bool HasCurrent(JsonNode raw) => raw.Get("current_stage") is not null;

    /// <summary>`normalizeApplicationStageLabel`。</summary>
    public static string StageLabel(JsonNode raw)
    {
        if (raw.Get("current_stage") is { } current) return current.Text("stage_label");
        var label = SwiftText.TrimWhitespaces(raw.Text("current_stage_label"));
        var type = raw.Text("current_stage_type");
        if (type == "offer") return "Offer";
        if (type != "screening") return label.Length == 0 ? "当前阶段" : label;
        if (label == "测评中") return "测评";
        if (label == "笔试中") return "笔试";
        if (SwiftText.Contains(label, "笔试") || SwiftText.Contains(label, "测评") || SwiftText.Contains(SwiftText.Lower(label), "assessment")) return label.Length == 0 ? "当前阶段" : label;
        return label == "待投递" ? "待投递" : "筛选中";
    }

    public static string StableType(JsonNode raw)
    {
        if (raw.Get("current_stage") is { } current && current.Text("stage_type").Length > 0) return current.Text("stage_type");
        var type = raw.Text("current_stage_type");
        if (type == "hr") return "interview";
        if (type != "screening") return type;
        var label = SwiftText.Lower(raw.Text("current_stage_label"));
        if (SwiftText.Contains(label, "笔试")) return "written_test";
        if (SwiftText.Contains(label, "测评") || SwiftText.Contains(label, "assessment")) return "assessment";
        return "screening";
    }

    internal static bool Active(JsonNode raw) => raw.Text("lifecycle_status") != "terminated" && raw.Text("status") == "active" && raw.Text("archived_at").Length == 0;

    internal static string? TerminalLabel(JsonNode raw)
    {
        if (raw.Text("archived_at").Length > 0) return "已归档";
        if (raw.Text("lifecycle_status") == "terminated")
            return raw.Text("termination_reason") switch { "company_rejected" => "未通过", "user_withdrew" or "offer_declined" => "已主动结束", _ => "已终止" };
        return raw.Text("status") switch
        {
            "rejected" => "未通过",
            "withdrawn" => "已主动结束",
            "closed" => raw.Text("offer_status") == "declined" ? "已主动结束" : "已结束",
            _ => null,
        };
    }

    /// <summary>`projectApplicationProgress`。</summary>
    public static CareerBoardProjection Projection(JsonNode raw)
    {
        var label = StageLabel(raw);
        var stable = StableType(raw);
        var isActive = Active(raw);
        var phase = raw.Text("phase").Length == 0
            ? (raw.Text("applied_at").Length > 0 || HasCurrent(raw) || raw.Text("current_stage_type") != "screening" ? "applied" : "pending")
            : raw.Text("phase");
        if (raw.Text("archived_at").Length == 0 && raw.Text("status") == "closed" && raw.Text("offer_status") == "accepted")
            return new("offer", label, "已收到 Offer", null, false);
        if (TerminalLabel(raw) is { } terminal) return new("ended", label, terminal, null, false);
        if (isActive && phase == "pending") return new("pending", "待投递", "待投递", "等待确认投递", false);
        if (isActive && stable is "offer" or "oc")
        {
            var status = stable == "oc" ? "口头意向" : raw.Text("offer_status") == "none" ? "Offer 状态待确认" : raw.Text("offer_status") == "declined" ? "已主动结束" : "已收到 Offer";
            return new("offer", label, status, null, false);
        }
        var column = stable is "screening" or "assessment" or "written_test" ? stable : "interview";
        var state = raw.Text("stage_state");
        var statusLabel = state == "awaiting_schedule" ? "等待安排" : state == "awaiting_result" ? "等待结果" : "进行中";
        var waiting = isActive && state == "awaiting_result" && stable is "interview" or "hr" or "ai_interview";
        return new(column, label, statusLabel, null, waiting);
    }

    /// <summary>`applicationScheduleStatusLabel`：已排期阶段的倒计时文案。</summary>
    public static string? ScheduleLabel(JsonNode raw, bool completed, DateTimeOffset? now = null)
    {
        var at = now ?? Beijing.Now;
        if (!Scheduled.Contains(Projection(raw).Column)) return null;
        if (completed) return "已完成";
        if (CareerApplication.Date(raw.Text("next_session_start_at")) is not { } start || CareerApplication.Date(raw.Text("next_session_end_at")) is not { } end || end <= start) return null;
        if (at >= end) return "等待结果";
        if (at >= start) return "正在进行";
        var until = (start - at).TotalSeconds;
        if (until <= 24 * 3600) return $"{Math.Max(1, (int)Math.Ceiling(until / 3600))} 小时后";
        return $"{(int)Math.Ceiling(until / 86400)} 天后";
    }

    /// <summary>`applicationCardStatusLabel`。</summary>
    public static string CardStatus(JsonNode raw, bool completed, DateTimeOffset? now = null)
    {
        var value = Projection(raw);
        if (value.Column == "ended") return "结束阶段：" + value.StageLabel;
        return ScheduleLabel(raw, completed, now) ?? value.SupportingLabel ?? value.StatusLabel;
    }

    /// <summary>`applicationProgressLabel`：列表视图的进度单元格。</summary>
    public static string ProgressLabel(JsonNode raw, bool completed, DateTimeOffset? now = null)
    {
        var value = Projection(raw);
        if (value.Column == "offer" || raw.Text("current_stage_type") == "offer") return value.StatusLabel;
        if (value.SupportingLabel is { } supporting) return value.StageLabel + " · " + supporting;
        if (value.Column != "ended" && ScheduleLabel(raw, completed, now) is { } schedule) return value.StageLabel + " · " + schedule;
        return value.StageLabel + " · " + value.StatusLabel;
    }

    /// <summary>`applicationProgressToneClass` 折到共用色调：蓝为已排期 / 进行中，橙为等待，绿为 Offer / 成功，红为未通过，灰为弱化。</summary>
    public static CareerTone Tone(JsonNode raw, bool completed, DateTimeOffset? now = null)
    {
        var value = Projection(raw);
        if (raw.Text("status") == "closed" && raw.Text("offer_status") == "accepted") return CareerTone.Green;
        if (value.Column == "ended") return raw.Text("status") == "rejected" ? CareerTone.Red : CareerTone.Gray;
        if (value.Column == "offer") return CareerTone.Green;
        if (completed && Scheduled.Contains(value.Column)) return CareerTone.Green;
        if (ScheduleLabel(raw, completed, now) is { } schedule) return schedule == "等待结果" ? CareerTone.Orange : CareerTone.Blue;
        if (raw.Text("stage_state") == "negotiating") return CareerTone.Green;
        return value.IsWaiting ? CareerTone.Orange : CareerTone.Blue;
    }

    static string HourMinute(DateTimeOffset date, TimeZoneInfo zone)
    {
        var local = SwiftCalendar.Local(date, zone);
        return CareerFormat.Two(local.Hour) + ":" + CareerFormat.Two(local.Minute);
    }

    /// <summary>`applicationCardTimeLabel`：卡片状态下方的悬停文字。</summary>
    public static string CardTime(JsonNode raw, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? Beijing.Zone;
        var value = Projection(raw);
        string? Stamp(string field) => CareerApplication.Date(raw.Text(field)) is { } date ? DateTime(date, tz) : null;
        switch (value.Column)
        {
            case "pending": return Stamp("created_at") is { } created ? "创建于 " + created : "创建时间待确认";
            case "assessment" or "written_test": return Stamp("next_session_end_at") is { } due ? "截止 " + due : "尚未安排时间";
            case "interview":
                if (CareerApplication.Date(raw.Text("next_session_start_at")) is not { } start || CareerApplication.Date(raw.Text("next_session_end_at")) is not { } end || end <= start) return "尚未安排时间";
                return DateTime(start, tz) + "–" + (SwiftCalendar.SameDay(start, end, tz) ? HourMinute(end, tz) : DateTime(end, tz));
            case "offer":
                var current = raw.Get("current_stage");
                if (current.Text("stage_type") != "offer" || CareerApplication.Date(current.Text("entered_at")) is not { } entered) return "Offer 时间待确认";
                return DateTime(entered, tz) + " 获得 Offer";
            case "ended": return Stamp("terminated_at") is { } ended ? "结束于 " + ended : "结束时间待确认";
            default: return Stamp("applied_at") is { } applied ? "投递于 " + applied : "投递时间待确认";
        }
    }

    /// <summary>`formatApplicationSessionRange`：列表视图的「最近安排」单元格。</summary>
    public static string SessionRange(JsonNode session, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? Beijing.Zone;
        if (CareerApplication.Date(session.Text("start_at")) is not { } start || CareerApplication.Date(session.Text("end_at")) is not { } end) return "—";
        return DateTime(start, tz) + "–" + (SwiftCalendar.SameDay(start, end, tz) ? HourMinute(end, tz) : DateTime(end, tz));
    }

    /// <summary>`todayScheduleLabel`：今天稍后开始的阶段显示黑色「今天 HH:mm」。</summary>
    public static string? Today(JsonNode raw, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var at = now ?? Beijing.Now; var tz = zone ?? Beijing.Zone;
        if (!Scheduled.Contains(Projection(raw).Column) || CareerApplication.Date(raw.Text("next_session_start_at")) is not { } start || start <= at || !SwiftCalendar.SameDay(start, at, tz)) return null;
        return "今天 " + HourMinute(start, tz);
    }

    /// <summary>`formatApplicationUpdatedAt`：今天 / 昨天 / M月d日。</summary>
    public static string? RelativeDay(string text, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var at = now ?? Beijing.Now; var tz = zone ?? Beijing.Zone;
        if (CareerApplication.Date(text) is not { } date) return null;
        var time = HourMinute(date, tz);
        if (SwiftCalendar.SameDay(date, at, tz)) return "今天 " + time;
        if (SwiftCalendar.SameDay(date, SwiftCalendar.AddDays(at, -1, tz), tz)) return "昨天 " + time;
        var local = SwiftCalendar.Local(date, tz);
        return $"{local.Month}月{local.Day}日";
    }

    internal static string DateTime(DateTimeOffset date, TimeZoneInfo zone)
    {
        var local = SwiftCalendar.Local(date, zone);
        return $"{local.Month}月{local.Day}日 " + CareerFormat.Two(local.Hour) + ":" + CareerFormat.Two(local.Minute);
    }

    /// <summary>卡片菜单「推进流程」的预填（`applicationAdvanceAction`）：流程中的下一步。</summary>
    public static (string Stage, string Label)? AdvanceStage(CareerApplication app)
    {
        if (!app.Movable) return null;
        return Projection(app.Raw).Column switch
        {
            "pending" => null,
            "screening" => ("assessment", "测评"),
            "assessment" => ("written_test", "笔试"),
            "written_test" => ("interview", "一面"),
            _ => ("interview", ""),
        };
    }
}
