using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace DrawOffer.Core.Models;

/// <summary>Mac AccountCrop.swift：圆窗的 cover、拖动约束与原图裁剪坐标。</summary>
public static class AvatarCrop
{
    public const double Output = 512, Viewport = 320, Window = 264, MinZoom = 1, MaxZoom = 3;
    public sealed record Draft(double Width, double Height, double Zoom = 1, double OffsetX = 0, double OffsetY = 0);
    public sealed record Layout(double RenderedWidth, double RenderedHeight, double MaxOffsetX, double MaxOffsetY, double Scale);
    public static Layout Measure(Draft draft)
    {
        var scale = Math.Max(Window / draft.Width, Window / draft.Height) * Math.Clamp(draft.Zoom, MinZoom, MaxZoom);
        var width = draft.Width * scale; var height = draft.Height * scale;
        return new(width, height, Math.Max(0, (width - Window) / 2), Math.Max(0, (height - Window) / 2), scale);
    }
    public static Draft Clamp(Draft draft)
    {
        var layout = Measure(draft);
        return draft with { Zoom = Math.Clamp(draft.Zoom, MinZoom, MaxZoom), OffsetX = Math.Clamp(draft.OffsetX, -layout.MaxOffsetX, layout.MaxOffsetX), OffsetY = Math.Clamp(draft.OffsetY, -layout.MaxOffsetY, layout.MaxOffsetY) };
    }
    public static (double X, double Y, double Size) Source(Draft draft)
    {
        draft = Clamp(draft); var layout = Measure(draft); var size = Window / layout.Scale;
        return (Math.Clamp((layout.RenderedWidth / 2 - Window / 2 - draft.OffsetX) / layout.Scale, 0, draft.Width - size), Math.Clamp((layout.RenderedHeight / 2 - Window / 2 - draft.OffsetY) / layout.Scale, 0, draft.Height - size), size);
    }
}

/// <summary>Mac CareerProfileRules：账号求职资料的行目录、经历分组与技能投影。</summary>
public static class CareerProfileRules
{
    public sealed record Row(string Key, string Label, string[]? Options = null, string? Hint = null);
    public static readonly Row[] Basic = [new("name", "姓名"), new("gender", "性别", ["男", "女", "其他", "不愿透露"]), new("birth_date", "出生日期", Hint: "填到日，例如 2003-05-18；只知道年月就填 2003-05"), new("phone", "手机号"), new("email", "邮箱")];
    public static readonly Row[] Links = [new("github", "GitHub", Hint: "填主页地址或用户名"), new("website", "个人网站", Hint: "以 http:// 或 https:// 开头"), new("portfolio_url", "作品集", Hint: "以 http:// 或 https:// 开头")];
    public static readonly Row[] Identity = [new("ethnicity", "民族"), new("political_status", "政治面貌", ["中共党员", "中共预备党员", "共青团员", "群众", "其他"]), new("native_place", "籍贯"), new("home_city", "家庭所在城市")];
    public static readonly string[] Common = ["name", "gender", "birth_date", "phone", "email", "ethnicity", "political_status", "native_place"];
    public static readonly Dictionary<string, string[]> EntryFields = new() { ["education"] = ["学校", "专业", "学历学位", "开始时间", "结束时间"], ["work"] = ["单位", "职位", "开始时间", "结束时间"], ["project"] = ["项目名称", "角色", "开始时间", "结束时间"], ["other"] = ["名称", "开始时间", "结束时间"] };
    public static readonly Dictionary<string, string[]> EntrySupplements = new() { ["education"] = ["gpa", "major_rank", "courses", "study_mode", "advisor"], ["work"] = ["department"], ["project"] = [], ["other"] = [] };
    public static readonly string[] TextKinds = ["skills", "profile", "interests"];
    public static readonly (string Id, string Label)[] SkillLevels = [("basic", "了解"), ("familiar", "熟悉"), ("proficient", "熟练")];
    public static string[] Missing(JsonNode profile) => Common.Where(key => profile["personal"].Text(key).Length == 0).Concat(profile.Bool("has_id_number") ? [] : new[] { "id_number" }).ToArray();
    public static Row[] MoreRows(JsonNode profile)
    {
        var shown = Basic.Concat(Links).Concat(Identity).Select(x => x.Key).ToHashSet();
        return (profile["catalog"]?["fields"] as JsonObject ?? []).Select(x => x.Value).Where(x => x.Text("scope") == "personal" && x.Text("site").Length == 0 && !shown.Contains(x.Text("key")) && x.Text("key") != "summary").Select(x => new Row(x.Text("key"), x.Text("label"))).OrderBy(x => x.Key, StringComparer.Ordinal).ToArray();
    }
    public static string EntryKind(string kind) => kind is "education" or "work" or "project" ? kind : "other";
    public sealed record Item(int SectionIndex, JsonNode Entry, string Kind);
    public sealed record Group(string Key, string Label, List<Item> Items);
    public static List<Group> Groups(JsonNode? experience)
    {
        List<Group> groups = [new("education", "教育", []), new("internship", "实习", []), new("work", "工作", []), new("project", "项目", []), new("campus", "校园", []), new("other", "奖项与证书", [])];
        var sections = experience.Items("sections");
        for (var i = 0; i < sections.Count; i++) { var raw = sections[i].Text("kind"); if (TextKinds.Contains(raw)) continue; var kind = EntryKind(raw); foreach (var entry in sections[i].Items("entries")) { var key = kind == "work" ? entry.Bool("intern") ? "internship" : "work" : raw == "activity" ? "campus" : kind; groups.First(x => x.Key == key).Items.Add(new(i, entry, kind)); } }
        return groups.Where(x => x.Items.Count > 0).ToList();
    }
    public static string EntryTitle(JsonNode entry)
    {
        var fields = entry["fields"]; foreach (var key in new[] { "学校", "单位", "所属单位", "项目名称", "名称" }) if (fields.Text(key).Length > 0) return fields.Text(key);
        var first = (fields as JsonObject)?.OrderBy(x => x.Key, StringComparer.Ordinal).FirstOrDefault().Value?.GetValue<string>(); return string.IsNullOrEmpty(first) ? "未命名" : first;
    }
    public sealed record Skill(string Name, string? Level);
    public static List<Skill> Skills(JsonNode? experience)
    {
        var existing = experience.Items("skills"); if (existing.Count > 0) return existing.Select(x => new Skill(x.Text("name"), x.Text("level").Length == 0 ? null : x.Text("level"))).ToList();
        List<Skill> result = []; var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var section in experience.Items("sections").Where(x => x.Text("kind") == "skills")) {
            var lines = section.Items("lines").Select(x => x.GetValue<string>()).Concat(section.Items("entries").Select(entry => string.Join("、", (entry["fields"] as JsonObject ?? []).OrderBy(x => x.Key, StringComparer.Ordinal).Select(x => x.Value?.GetValue<string>() ?? ""))));
            foreach (var line in lines) foreach (var part in line.Split(['；', ';'])) foreach (var raw in Regex.Replace(part, @"^[^：:]{1,12}[：:]", "").Split(['、', ',', '，', '/', '|'])) { var name = Regex.Replace(raw, @"^[-•·\s]+", "").Trim(); if (name.Length is > 0 and <= 60 && seen.Add(name)) result.Add(new(name, null)); }
        }
        return result.Take(60).ToList();
    }
    public static string SalaryText(JsonNode intent)
    {
        var values = new[] { intent.Number("salary_min"), intent.Number("salary_max") }.OfType<double>().ToArray();
        return values.Length == 0 ? "" : string.Join("–", values.Select(x => Math.Round(x / 1000, MidpointRounding.AwayFromZero) + "K")) + " / " + (intent.Text("salary_period") == "year" ? "年" : "月");
    }
}
