using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
namespace DrawOffer.Core.Models;

/// <summary>
/// 岗位广场（Web `features/jobs/OpportunitiesPage.tsx` 与 `jobPoolPresentation.ts`）的展示规则：
/// 招聘类型、列表时间、官网发布时间与岗位正文分段。
/// </summary>
public static class JobPool
{
    /// <summary>岗位广场只提供校招和实习（后端 `OFFERED_BUCKETS`）。</summary>
    public static readonly (string Value, string Label)[] Types = [("campus", "校招"), ("internship", "实习")];
    public static readonly (string Value, string Label)[] Sorts = [("open", "在招最多"), ("today", "今日新增最多"), ("latest", "最近更新"), ("name", "按名称")];
    public const string KeywordError = "关键词需要包含 2～100 个字符。";

    /// <summary>`poolRecruitment`。</summary>
    public static string Recruitment(JsonNode job)
    {
        if (job.Text("employment_type") == "internship") return "实习";
        return job.Text("recruitment_channel") switch { "campus" => "校招", "experienced" => "社招", _ => "招聘类型未标明" };
    }

    /// <summary>详情事实里的「招聘类型」：渠道 · 用工形式，未知项省略。</summary>
    public static string JobType(JsonNode job)
    {
        var channel = job.Text("recruitment_channel") switch { "campus" => "校招", "experienced" => "社招", _ => null };
        var employment = job.Text("employment_type") switch { "internship" => "实习", "full_time" => "正式", "part_time" => "兼职", "contract" => "合同制", _ => null };
        return string.Join(" · ", new[] { channel, employment }.OfType<string>());
    }

    public static List<string> Cities(JsonNode job) => CareerJson.Strings(job.Get("locations").Get("cities"));

    public static string? Attribute(JsonNode job, string key) => job.Get("source_attributes").Get(key).String() is { } value ? SwiftText.TrimAll(value).NonEmpty() : null;

    public static bool IsToday(string value, DateTimeOffset? now = null, TimeZoneInfo? zone = null) =>
        CareerApplication.Date(value) is { } date && SwiftCalendar.SameDay(date, now ?? Beijing.Now, zone ?? Beijing.Zone);

    /// <summary>`poolRelative`：今天 / N 天前 / N 周前，之后为「10月29日」，非今年带年份。</summary>
    public static string Relative(string value, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var at = now ?? Beijing.Now; var tz = zone ?? Beijing.Zone;
        if (CareerApplication.Date(value) is not { } date) return "";
        var days = CareerFormat.Days(date, at, tz);
        if (days <= 0) return "今天";
        if (days < 7) return $"{days} 天前";
        if (days < 28) return $"{days / 7} 周前";
        var local = SwiftCalendar.Local(date, tz);
        var year = local.Year == SwiftCalendar.Local(at, tz).Year ? "" : $"{local.Year}年";
        return $"{year}{local.Month}月{local.Day}日";
    }

    /// <summary>`poolDate`：今天 / 昨天 / 2026/10/29，后接 24 小时制时间。</summary>
    public static string Date(string value, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var at = now ?? Beijing.Now; var tz = zone ?? Beijing.Zone;
        if (CareerApplication.Date(value) is not { } date) return "尚无记录";
        var local = SwiftCalendar.Local(date, tz);
        var day = SwiftCalendar.SameDay(date, at, tz) ? "今天"
            : SwiftCalendar.SameDay(date, SwiftCalendar.AddDays(at, -1, tz), tz) ? "昨天"
            : $"{local.Year}/{local.Month}/{local.Day}";
        return $"{day} {CareerDeckFormat.Clock(date, tz)}";
    }

    /// <summary>列表行的元信息：城市、招聘类型、方向、薪资、发布时间。</summary>
    public static List<string> Meta(JsonNode job, DateTimeOffset? now = null, TimeZoneInfo? zone = null) =>
        new[] { string.Join("、", Cities(job)).NonEmpty() ?? "地点未标明", Recruitment(job), job.Text("category"), job.Text("salary_text"), Relative(job.Text("published_at"), now, zone) }
            .Where(x => x.Length > 0).ToList();

    /// <summary>`URL(string:)?.host() ?? url`：能解析为带主机的绝对地址时取主机名，否则原样返回。</summary>
    public static string Host(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) && !uri.IsFile && uri.HostNameType != UriHostNameType.Unknown && uri.Host.Length > 0
            ? (uri.HostNameType == UriHostNameType.IPv6 ? uri.Host.Trim('[', ']') : url.Substring(url.IndexOf(uri.Host, StringComparison.OrdinalIgnoreCase), uri.Host.Length))
            : url;

    /// <summary>`poolError` 中工作区会遇到的错误码。</summary>
    public static string Error(string code) => code switch
    {
        "JOB_POOL_CLOSED" => "该岗位已下线，无法新加入求职进程。",
        "JOB_POOL_NOT_FOUND" => "未找到该岗位。",
        "JOB_POOL_INVALID_QUERY" => "关键词需要包含 2～100 个字符。",
        "JOB_POOL_INVALID_CURSOR" => "筛选条件已变化，请重新搜索。",
        "JOB_POOL_SOURCE_CONFLICT" => "同一官网岗位已关联其他共享岗位，请打开现有求职记录。",
        _ => "操作未完成，请重试。",
    };

    // 岗位正文

    /// <summary>正文块：段落或对齐的要点。</summary>
    public abstract record Block
    {
        public sealed record Paragraph(string Text) : Block;
        public sealed record Points(IReadOnlyList<string> Items) : Block
        {
            public bool Equals(Points? other) => other is not null && Items.SequenceEqual(other.Items);
            public override int GetHashCode() => Items.Count;
        }
    }

    public sealed record Section(string Title, IReadOnlyList<Block> Blocks)
    {
        public bool Equals(Section? other) => other is not null && Title == other.Title && Blocks.SequenceEqual(other.Blocks);
        public override int GetHashCode() => HashCode.Combine(Title, Blocks.Count);
    }

    static readonly string[] Headings = ["团队介绍", "部门介绍", "工作职责", "岗位职责", "职位描述", "岗位描述", "任职要求", "岗位要求", "职位要求", "加分项", "工作地点"];
    static readonly Regex Point = new(@"^\s*(?:\d{1,2}\s*[.、．)）]|[-•·*])\s*", RegexOptions.CultureInvariant);

    /// <summary>`JobBody`：已知小标题开新段，编号或项目符号行归为对齐的要点；没有正文时返回空列表。</summary>
    public static List<Section> Sections(string text)
    {
        var raw = new List<(string Title, List<string> Lines)>();
        foreach (var line in text.Split('\n').Select(SwiftText.TrimWhitespaces))
        {
            if (Headings.FirstOrDefault(h => SwiftText.HasPrefix(line, h)) is { } heading)
            {
                var rest = SwiftText.DropFirst(line, SwiftText.Count(heading));
                if (SwiftText.HasPrefix(rest, ":") || SwiftText.HasPrefix(rest, "：")) rest = SwiftText.DropFirst(rest, 1);
                var body = SwiftText.TrimWhitespaces(rest);
                // 与 Web 正则 `^(小标题)[:：]?\s*(.*)$` 相同：同行内容短于 120 字才算小标题。
                if (body.Length < 120) { raw.Add((heading, body.Length == 0 ? [] : [body])); continue; }
            }
            if (raw.Count == 0) raw.Add(("岗位描述", []));
            if (line.Length > 0) raw[^1].Lines.Add(line);
        }
        return raw.Where(x => x.Lines.Count > 0).Select(section =>
        {
            var blocks = new List<Block>(); var points = new List<string>();
            void Flush() { if (points.Count > 0) { blocks.Add(new Block.Points(points.ToList())); points.Clear(); } }
            foreach (var line in section.Lines)
            {
                var match = Point.Match(line);
                if (match.Success) points.Add(line[(match.Index + match.Length)..]);
                else { Flush(); blocks.Add(new Block.Paragraph(line)); }
            }
            Flush();
            return new Section(section.Title, blocks);
        }).ToList();
    }
}
