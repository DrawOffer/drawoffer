using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace DrawOffer.Core.Models;

/// <summary>公告（Web `features/announcements`），对应 Mac `Workspace.swift` 的 `Announcement`。</summary>
public sealed record Announcement(string Id, bool Important, string Category, string Title, string Body, DateTimeOffset? PublishedAt, bool Read)
{
    public static Announcement From(JsonNode? json) => new(json.Text("id"), json.Text("level") == "important", json.Text("category"),
        json.Text("title"), json.Text("body"), Json.Date(json.Text("publishedAt")), json.Bool("read"));

    public string CategoryLabel => Category switch
    {
        "product_update" => "产品更新",
        "service_notice" => "服务通知",
        "promotion" => "活动福利",
        _ => "公告",
    };

    /// <summary>Mac 用 SF Symbols（megaphone / gift / paperplane）；这里给 Segoe Fluent Icons 字形（Megaphone / Gift / Send）。</summary>
    public string CategoryGlyph => Category switch
    {
        "service_notice" => "\uE789",
        "promotion" => "\uE88C",
        _ => "\uE724",
    };

    /// <summary>与 Web `announcementDate` 相同：“10 月 19 日”（本地时区）。</summary>
    public string DateText => PublishedAt is { } date ? $"{date.ToLocalTime().Month} 月 {date.ToLocalTime().Day} 日" : "";

    /// <summary>
    /// 与 Mac `Announcement.summary` 一致的单行摘要：去掉 Markdown 标记并折叠空白。替换顺序按模式字符串排序；
    /// NSRegularExpression 默认不开多行模式，`^` 只匹配全文开头，所以这里也不加 Multiline。
    /// </summary>
    public string Summary
    {
        get
        {
            var text = Body;
            foreach (var (pattern, replacement) in new[]
            {
                (@"\[([^\]]*)\]\([^)]*\)", "$1"), (@"[*_`>#~]+", ""), (@"^\s*[-+]\s+", ""), (@"^\s*\d+\.\s+", ""),
            }.OrderBy(x => x.Item1, StringComparer.Ordinal))
                text = Regex.Replace(text, pattern, replacement);
            return string.Join(" ", text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        }
    }
}

public sealed record AnnouncementList(IReadOnlyList<Announcement> Items, int UnreadCount)
{
    public static AnnouncementList From(JsonNode? json) => new(json.Items("items").Select(Announcement.From).ToList(), json.Integer("unreadCount"));
}

/// <summary>额度摘要（`GET /api/billing/summary`），对应 Mac `BillingSummary`：侧栏个人菜单只展示档位和可用积分。</summary>
public sealed record BillingSummary(string Tier, string Available)
{
    public static BillingSummary From(JsonNode? json) => new(json.Text("tier") is { Length: > 0 } tier ? tier : "none", json.Display("available"));

    public string TierLabel => Tier switch
    {
        "basic" => "基础会员",
        "advanced" => "进阶会员",
        "premium" => "高级会员",
        _ => "免费版",
    };

    public string AvailableText => Credits(Available);
    public bool Exhausted => (double.TryParse(Available, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : 0) <= 0;

    /// <summary>与 Web `formatCredits` 一致：最多两位小数、千分位，负数保留负号。</summary>
    public static string Credits(string value)
    {
        if (!double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) || !double.IsFinite(number)) return "—";
        var text = Math.Abs(number).ToString("#,0.##", CultureInfo.InvariantCulture);
        return number < 0 ? "-" + text : text;
    }
}
