using System.Text.Json.Nodes;
using S = DrawOffer.Core.Models.SwiftCompat;

namespace DrawOffer.Core.Models;

/// <summary>
/// 编辑中的实时纸面：后端 `domain/resume/layout.py` 的 `compile_layout_plan` 在 Swift 的移植（Mac `ResumeLayout.swift`）。
/// 只为未保存内容生成本地预览用的版式计划；保存后仍以后端返回的 layout_plan 为准。
/// 规则相同：identity 在前，各模块按存储顺序；每个节点选唯一的显式槽位，否则落到通用兜底槽位。
/// </summary>
public static class ResumeLayout
{
    /// <summary>按 (order, id) 排序；Swift 的元组比较里字符串按 Unicode 标量序。Swift `sorted` 不保证稳定，这里稳定。</summary>
    static List<JsonNode?> Ordered(IEnumerable<JsonNode?> items, string idKey) =>
        items.OrderBy(x => Number(x.Get("order"))).ThenBy(x => x.Text(idKey), S.StringOrder).ToList();

    public static JsonNode? Compile(JsonNode? data, JsonNode? style, string contentHash)
    {
        var template = style.Get("template_snapshot");
        var regions = S.Arr(template.Get("regions"));
        var slots = Ordered(S.Arr(template.Get("slots")), "slot_id");
        var identity = data.Get("identity") is { } identityNode ? identityNode.Text("node_id") : "";
        if (regions.Count == 0 || slots.Count == 0 || identity.Length == 0) return null;
        var top = new List<(string Id, string Kind)> { (identity, "identity") };
        top.AddRange(S.Arr(data.Get("sections")).Select(x => (x.Text("node_id"), x.Text("semantic_kind"))));
        var assigned = new Dictionary<string, JsonArray>();
        foreach (var node in top)
        {
            if (Select(node.Kind, slots) is not { } slot) return null;
            var region = slot.Text("region_id");
            if (!assigned.TryGetValue(region, out var list)) assigned[region] = list = new JsonArray();
            list.Add(new JsonObject { ["node_id"] = node.Id, ["semantic_kind"] = node.Kind, ["slot_id"] = slot.Text("slot_id") });
        }
        var ordered = Ordered(regions, "region_id");
        var outRegions = new JsonArray();
        foreach (var region in ordered)
        {
            var id = region.Text("region_id");
            outRegions.Add(new JsonObject
            {
                ["region_id"] = id,
                // Swift `region["order"] ?? .number(0)`：键存在（即使是 null）就原样保留。
                ["order"] = S.HasKey(region, "order") ? S.Clone(region.Get("order")) : S.Num(0),
                ["nodes"] = assigned.TryGetValue(id, out var nodes) ? nodes.DeepClone() : new JsonArray(),
            });
        }
        return new JsonObject
        {
            ["schema_version"] = "layout-plan.v1",
            ["content_sha256"] = contentHash,
            ["template_key"] = template.Text("template_key"),
            ["regions"] = outRegions,
        };
    }

    static JsonNode? Select(string kind, List<JsonNode?> slots)
    {
        bool Accepts(JsonNode? slot) => S.Arr(slot.Get("accepts")).Any(x => x.String() is { } value && S.Eq(value, kind));
        bool Universal(JsonNode? slot) => slot.Get("universal_fallback") is JsonValue flag && flag.GetValueKind() == System.Text.Json.JsonValueKind.True;
        var explicitSlots = slots.Where(x => !Universal(x) && Accepts(x)).ToList();
        if (explicitSlots.Count == 1) return explicitSlots[0];
        if (explicitSlots.Count > 0) return null;
        var fallback = slots.Where(Universal).ToList();
        return fallback.Count == 1 && Accepts(fallback[0]) ? fallback[0] : null;
    }

    /// <summary>双栏模板中每个模块所在的栏（侧栏/主栏），用于排序面板分组；单栏模板返回空。</summary>
    public static Dictionary<string, string> Columns(JsonNode? data, JsonNode? style)
    {
        var template = style.Get("template_snapshot");
        var regions = S.Arr(template.Get("regions"));
        if (!regions.Any(x => x.Text("region_kind") == "sidebar") || Compile(data, style, "") is not { } plan) return [];
        var kinds = new Dictionary<string, string>();
        foreach (var region in regions) kinds[region.Text("region_id")] = region.Text("region_kind");
        var result = new Dictionary<string, string>();
        foreach (var region in S.Arr(plan.Get("regions")))
            foreach (var node in S.Arr(region.Get("nodes")))
                result[node.Text("node_id")] = kinds.TryGetValue(region.Text("region_id"), out var kind) ? kind : "main";
        return result;
    }

    static double Number(JsonNode? value) => value.Number() ?? 0;
}

/// <summary>Web `styleToEditorSettings` / `editorSettingsToStyle`（canonical 分支）的移植：字体、字号、行距、边距与智能一页。</summary>
public sealed record ResumeTypeSettings(string FontFamily, double FontSize, double LineHeight, double PageMargin, double VerticalPageMargin, bool SmartOnePage)
{
    public const string SerifStack = "\"Source Han Serif SC\", \"Songti SC\", STSong, SimSun, serif";
    public static readonly IReadOnlyList<(string Label, string Value)> Fonts =
    [
        ("思源宋体", SerifStack),
        ("霞鹜文楷", "\"LXGW WenKai\", KaiTi, STKaiti, \"Songti SC\", serif"),
        ("系统黑体", "\"DrawOffer Noto Sans SC\", \"PingFang SC\", \"Microsoft YaHei\", sans-serif"),
    ];
    public static readonly (double Min, double Max, double Step) FontSizeRange = (8.0, 16.0, 0.5);
    public static readonly (double Min, double Max, double Step) LineHeightRange = (1.1, 1.8, 0.05);
    public static readonly (double Min, double Max, double Step) VerticalMarginRange = (6.0, 30.0, 2.0);
    public static readonly (double Min, double Max, double Step) HorizontalMarginRange = (10.0, 30.0, 2.0);

    public string FontFamily { get; set; } = FontFamily;
    public double FontSize { get; set; } = FontSize;
    public double LineHeight { get; set; } = LineHeight;
    public double PageMargin { get; set; } = PageMargin;
    public double VerticalPageMargin { get; set; } = VerticalPageMargin;
    public bool SmartOnePage { get; set; } = SmartOnePage;

    public static ResumeTypeSettings? Read(JsonNode? style)
    {
        if (style.Text("schema_version") != "resume-presentation.v1" || style.Get("template_snapshot") is not { } snapshot || !S.HasKey(snapshot, "tokens")) return null;
        var tokens = snapshot.Get("tokens");
        var key = snapshot.Text("template_key");
        var scoped = style.Get("template_scoped").Get(key);
        var portable = style.Get("portable");
        // A zero carried in portable is a previous template's full-bleed decoration,
        // not a text inset the user chose. The active template's own zero still wins.
        double? Carried(string field) { var value = portable.Number(field); return value is > 0 ? value : null; }
        double? Pick(string field) => scoped.Number(field) ?? Carried(field);
        var fontBase = tokens.Number("font_size_pt") ?? 10;
        var scale = Pick("font_scale") ?? 1;
        var margin = tokens.Number("page_margin_mm") ?? 16;
        var horizontal = Pick("page_margin_mm") ?? margin;
        var vertical = Pick("vertical_page_margin_mm") ?? tokens.Number("vertical_page_margin_mm") ?? margin;
        var persisted = scoped.Get("font_family").String() ?? portable.Get("font_family").String() ?? tokens.Text("font_family");
        var font = persisted == "source-han-serif" ? SerifStack : persisted;
        if (S.Matches("PingFang SC|Microsoft YaHei|system-ui", font)) font = Fonts[2].Value;
        return new ResumeTypeSettings(
            font,
            S.Round(fontBase * scale * 1e10) / 1e10,
            Pick("line_height") ?? tokens.Number("line_height") ?? 1.5,
            Pick("page_margin_left_mm") ?? tokens.Number("page_margin_left_mm") ?? horizontal,
            Pick("page_margin_top_mm") ?? tokens.Number("page_margin_top_mm") ?? vertical,
            portable.Get("smart_one_page").Bool());
    }

    /// <summary>写回 presentation；与 Web 相同，只在边距真正改变时写四边覆盖值。返回新节点。</summary>
    public JsonNode? Apply(JsonNode? style)
    {
        if (Read(style) is not { } previous || style is not JsonObject original) return S.Clone(style);
        var root = (JsonObject)original.DeepClone();
        var key = style.Get("template_snapshot").Text("template_key");
        var fontBase = style.Get("template_snapshot").Get("tokens").Number("font_size_pt") ?? 0;
        var portable = S.ObjectCopy(style.Get("portable"));
        portable["smart_one_page"] = SmartOnePage;
        portable["line_height"] = S.Num(LineHeight);
        portable["page_margin_mm"] = S.Num(PageMargin);
        portable["vertical_page_margin_mm"] = S.Num(VerticalPageMargin);
        var allScoped = S.ObjectCopy(style.Get("template_scoped"));
        var scoped = S.ObjectCopy(allScoped[key]);
        if (PageMargin != previous.PageMargin) { scoped["page_margin_left_mm"] = S.Num(PageMargin); scoped["page_margin_right_mm"] = S.Num(PageMargin); }
        if (VerticalPageMargin != previous.VerticalPageMargin) { scoped["page_margin_top_mm"] = S.Num(VerticalPageMargin); scoped["page_margin_bottom_mm"] = S.Num(VerticalPageMargin); }
        scoped["font_family"] = S.Has(FontFamily, "Source Han Serif") ? "source-han-serif" : FontFamily;
        var scale = fontBase > 0 ? FontSize / fontBase : (scoped["font_scale"].Number() ?? 1);
        scoped["font_scale"] = S.Num(S.Min(1.5, S.Max(0.75, double.IsFinite(scale) ? scale : 1)));
        scoped["line_height"] = S.Num(LineHeight);
        scoped["page_margin_mm"] = S.Num(PageMargin);
        scoped["vertical_page_margin_mm"] = S.Num(VerticalPageMargin);
        allScoped[key] = scoped;
        root["portable"] = portable;
        root["template_scoped"] = allScoped;
        return root;
    }

    /// <summary>步进并吸附到步长（Web `steppedSettingValue`）。</summary>
    public static double Step(double value, double direction, double min, double max, double step)
    {
        var next = S.Round((value + direction * step) / step) * step;
        return S.Min(max, S.Max(min, S.Round(next * 100) / 100));
    }
}

/// <summary>
/// 板块顺序（Web `resumeSectionOrder.ts`）：个人信息固定在最前，其余按 canonical 顺序可拖动；
/// “恢复默认”按后端的语义顺序稳定排序。
/// </summary>
public static class ResumeSectionOrder
{
    public static readonly IReadOnlyList<string> Canonical = ["profile", "work", "project", "education", "skills", "activity", "interests", "certificates", "awards", "languages", "custom"];

    public static List<JsonNode?> RestoreDefault(IEnumerable<JsonNode?> sections) =>
        sections.Select((section, offset) => (section, offset))
            .OrderBy(x => Canonical.IndexOf(x.section.Text("semantic_kind")) is var i && i >= 0 ? i : Canonical.Count)
            .ThenBy(x => x.offset).Select(x => x.section).ToList();

    static int IndexOf(this IReadOnlyList<string> list, string value)
    {
        for (var i = 0; i < list.Count; i++) if (list[i] == value) return i;
        return -1;
    }
}
