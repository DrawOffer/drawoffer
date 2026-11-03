using System.Text.Json.Nodes;

namespace DrawOffer.Core.Models;

/// <summary>
/// `GET /api/resumes` 的列表项（apps/web/src/api/client.ts `ResumeSummary`），对应 Mac `Models.swift` 的 `ResumeSummary`。
/// `Preview` 已是后端编译好的 presentation 与 layout_plan，原生层原样转交纸面。
/// </summary>
public sealed record ResumeSummary(string Id, string Title, string SourceType, int LockVersion, string CreatedAt, string UpdatedAt, ResumeSummary.PreviewData? Preview)
{
    /// <summary>列表项里的预览快照。</summary>
    public sealed record PreviewData(JsonNode? Data, JsonNode? Style, JsonNode? LayoutPlan);

    /// <summary>
    /// 与 Swift `Decodable` 的必填字段一致：id、title、source_type、lock_version、created_at、updated_at 缺失或类型不符时返回 null；
    /// preview 为 null 或缺失时没有预览。
    /// </summary>
    public static ResumeSummary? From(JsonNode? json)
    {
        if (json is not JsonObject) return null;
        var id = json["id"].String(); var title = json["title"].String(); var source = json["source_type"].String();
        var created = json["created_at"].String(); var updated = json["updated_at"].String();
        var lockNumber = json["lock_version"].Number();
        if (id is null || title is null || source is null || created is null || updated is null || lockNumber is not { } lockValue
            || lockValue != Math.Floor(lockValue) || lockValue is < int.MinValue or > int.MaxValue) return null;
        PreviewData? preview = null;
        if (json["preview"] is JsonObject raw)
        {
            if (!raw.ContainsKey("data") || !raw.ContainsKey("style")) return null;
            preview = new PreviewData(raw["data"]?.DeepClone(), raw["style"]?.DeepClone(), raw["layout_plan"]?.DeepClone());
        }
        else if (json["preview"] is not null) return null;
        return new ResumeSummary(id, title, source, (int)lockValue, created, updated, preview);
    }

    /// <summary>没有预览快照（旧数据或编译失败）时返回 null，界面显示“预览不可用”。</summary>
    public ResumeRenderRequest? ToRenderRequest() =>
        Preview is null ? null : new ResumeRenderRequest(Title, Preview.Data?.DeepClone()!, Preview.Style?.DeepClone()!, Preview.LayoutPlan?.DeepClone());

    /// <summary>
    /// 与 Web `formatUpdatedAt` 同一口径：今天显示时刻，昨天显示“昨天”，今年显示月-日，更早显示年-月-日。
    /// 后端返回不带时区的 UTC 时间，按 UTC 解析后换算到 `zone`（Swift 的 calendar，默认本机时区）。
    /// </summary>
    public string UpdatedLabel(DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var tz = zone ?? TimeZoneInfo.Local;
        var current = now ?? DateTimeOffset.UtcNow;
        if (ParseTimestamp(UpdatedAt) is not { } date) return "—";
        static string Pad(int value) => value.ToString("00", System.Globalization.CultureInfo.InvariantCulture);
        var parts = SwiftCompat.Local(date, tz);
        var startOfToday = SwiftCompat.StartOfDay(current, tz);
        if (date >= startOfToday) return $"今天 {Pad(parts.Hour)}:{Pad(parts.Minute)}";
        if (date >= SwiftCompat.Adding(startOfToday, -86_400)) return "昨天";
        if (parts.Year != SwiftCompat.Local(current, tz).Year) return $"{parts.Year}-{Pad(parts.Month)}-{Pad(parts.Day)}";
        return $"{Pad(parts.Month)}-{Pad(parts.Day)}";
    }

    /// <summary>不带时区时按 UTC 读；带或不带小数秒都接受（Swift `ISO8601DateFormatter`）。</summary>
    public static DateTimeOffset? ParseTimestamp(string value) => SwiftCompat.ParseTimestamp(value);
}
