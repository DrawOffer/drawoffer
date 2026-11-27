using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace DrawOffer.Core.Models;

/// <summary>Mac AccountCrop.swift：圆窗的 cover、拖动约束与原图裁剪坐标。</summary>
public static class AvatarCrop
{
    public const double Output = 512, Window = 264, MinZoom = 1, MaxZoom = 3;
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

/// <summary>Mac CareerProfileRules：账号求职资料的必填项、经历类型与技能投影。</summary>
public static class CareerProfileRules
{
    public static readonly string[] Common = ["name", "gender", "birth_date", "phone", "email", "ethnicity", "political_status", "native_place"];
    public static readonly string[] TextKinds = ["skills", "profile", "interests"];
    public static readonly (string Id, string Label)[] SkillLevels = [("basic", "了解"), ("familiar", "熟悉"), ("proficient", "熟练")];
    public static string[] Missing(JsonNode profile) => Common.Where(key => profile["personal"].Text(key).Length == 0).Concat(profile.Bool("has_id_number") ? [] : new[] { "id_number" }).ToArray();
    public static string EntryKind(string kind) => kind is "education" or "work" or "project" ? kind : "other";
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
}
