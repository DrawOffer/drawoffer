using System.Text.Json;
using System.Text.Json.Nodes;
using S = DrawOffer.Core.Models.SwiftCompat;

namespace DrawOffer.Core.Models;

/// <summary>
/// 原生结构化编辑 canonical-resume.v1（`contracts/resume/canonical-resume.schema.json`）的辅助函数。
/// 文本以 runs 编辑（加粗/斜体/下划线/删除线/代码、链接、颜色、高亮、字号）；图标与行内图片原样保留。
/// 分栏行、图片块与头像可编辑。保存前按 Web `canonicalV1SourceDispositions` 重算来源处置，删除的节点不留悬空引用。
/// Swift 的 JSONValue 是值类型；这里所有写入都返回深拷贝后的新节点，不改动传入的节点。
/// </summary>
public static class ResumeDocument
{
    public static readonly IReadOnlyList<(string Key, string Label)> EntryFields =
    [
        ("name", "名称"), ("organization", "单位"), ("role", "角色/职位"), ("degree", "学位"), ("college", "学院"), ("major", "专业"),
        ("location", "地点"), ("start_date", "开始时间"), ("end_date", "结束时间"), ("url", "链接"),
    ];
    public static readonly IReadOnlyList<(string Key, string Label)> SectionKinds =
    [
        ("profile", "个人简介"), ("work", "工作经历"), ("education", "教育经历"), ("project", "项目经历"), ("skills", "专业技能"),
        ("activity", "校园/社会活动"), ("interests", "兴趣爱好"), ("certificates", "证书"), ("awards", "荣誉奖项"), ("languages", "语言能力"), ("custom", "自定义"),
    ];
    public static readonly IReadOnlyList<(string Key, string Label)> ContactKinds =
    [
        ("phone", "电话"), ("email", "邮箱"), ("website", "网站"), ("location", "所在地"), ("github", "GitHub"), ("linkedin", "LinkedIn"), ("other", "其他"),
    ];

    public static string NewNodeID() => "node_" + Guid.NewGuid().ToString("N")[..24];

    // MARK: Text values

    static JsonObject PlainStyle() => new() { ["color"] = null, ["font_size_pt"] = null, ["highlight_color"] = null };

    static bool IsNull(JsonNode? node) => node is null;

    /// <summary>文本 run 是否为无格式纯文本。</summary>
    internal static bool IsPlainRun(JsonNode? run)
    {
        if (run.Text("inline_type") != "text") return false;
        var marks = S.Arr(run.Get("marks"));
        var href = run.Get("href");
        var style = run.Get("style");
        var styleEmpty = IsNull(style) || new[] { "color", "font_size_pt", "highlight_color" }.All(key => IsNull(style.Get(key)));
        return marks.Count == 0 && IsNull(href) && styleEmpty;
    }

    /// <summary>textValue 可编辑：没有 runs，或 runs 全是纯文本。</summary>
    public static bool Editable(JsonNode? textValue)
    {
        if (textValue is null) return true;
        if (textValue.Get("runs") is not { } runs) return true;
        return S.Arr(runs).All(IsPlainRun);
    }

    public static string Value(JsonNode? textValue) => textValue.Get("value").String() ?? "";

    /// <summary>textValue 的 runs；没有 runs 时由 value 生成一段纯文本。</summary>
    public static List<JsonNode?> TextRuns(JsonNode? textValue)
    {
        if (textValue.Get("runs") is { } runs) return S.Arr(runs);
        return S.Arr(PlainRuns(Value(textValue)));
    }

    /// <summary>以 runs 写入 textValue（只接受文字 run）；value 与 runs 拼接一致，全是纯文本时去掉 runs。空时返回 null。</summary>
    public static JsonNode? SetTextRuns(JsonNode? textValue, IEnumerable<JsonNode?> runs, int limit = 20_000)
    {
        var textOnly = NormalizeRuns(runs.Where(x => x.Text("inline_type") == "text"));
        var text = string.Concat(textOnly.Select(x => x.Text("text")));
        if (text.Length == 0) return null;
        if (S.Count(text) > limit) return S.Clone(textValue);
        var fields = textValue is JsonObject existing ? (JsonObject)existing.DeepClone()
            : new JsonObject { ["node_id"] = NewNodeID(), ["source_refs"] = new JsonArray() };
        fields["value"] = text;
        if (textOnly.All(IsPlainRun)) fields.Remove("runs"); else fields["runs"] = S.Array(textOnly);
        return fields;
    }

    /// <summary>合并相邻同格式文字 run、去掉空 run（schema 要求 text 至少 1 个字符）。</summary>
    public static List<JsonNode?> NormalizeRuns(IEnumerable<JsonNode?> runs)
    {
        var result = new List<JsonNode?>();
        foreach (var run in runs)
        {
            if (run.Text("inline_type") == "text")
            {
                if (run.Text("text").Length == 0) continue;
                if (result.Count > 0 && result[^1] is JsonObject last && last.Text("inline_type") == "text" && SameFormat(last, run))
                {
                    var merged = (JsonObject)last.DeepClone();
                    merged["text"] = last.Text("text") + run.Text("text");
                    result[^1] = merged;
                    continue;
                }
            }
            result.Add(S.Clone(run));
        }
        return result;
    }

    static bool SameFormat(JsonNode? left, JsonNode? right) =>
        S.Strings(left.Get("marks")).ToHashSet().SetEquals(S.Strings(right.Get("marks")))
        && S.Same(left.Get("href"), right.Get("href"))
        && S.Same(S.HasKey(left, "style") ? left.Get("style") : PlainStyle(), S.HasKey(right, "style") ? right.Get("style") : PlainStyle());

    /// <summary>构造一个文字 run。</summary>
    public static JsonObject TextRun(string text, IEnumerable<string>? marks = null, string? href = null, string? color = null, string? highlight = null, double? size = null)
    {
        var chosen = (marks ?? []).ToHashSet();
        string[] order = ["bold", "italic", "underline", "strike", "code"];
        return new JsonObject
        {
            ["inline_type"] = "text", ["text"] = text,
            ["marks"] = S.StringArray(order.Where(chosen.Contains)),
            ["href"] = href is null ? null : JsonValue.Create(href),
            ["style"] = new JsonObject
            {
                ["color"] = color is null ? null : JsonValue.Create(color),
                ["font_size_pt"] = size is { } pt ? S.Num(pt) : null,
                ["highlight_color"] = highlight is null ? null : JsonValue.Create(highlight),
            },
        };
    }

    public static readonly IReadOnlyList<string> IconNames = ["Mail", "Phone", "MapPin", "Globe", "Github", "Linkedin", "GraduationCap", "Briefcase", "Award", "Star", "Calendar", "Code2"];

    /// <summary>写入 textValue；空串时返回 null（由调用方决定置空或删除字段）。保留 node_id、source_refs、prefix_runs 与 align。</summary>
    public static JsonNode? SetValue(JsonNode? textValue, string text)
    {
        if (text.Length == 0) return null;
        var fields = textValue is JsonObject existing ? (JsonObject)existing.DeepClone()
            : new JsonObject { ["node_id"] = NewNodeID(), ["source_refs"] = new JsonArray() };
        fields["value"] = S.Prefix(text, 20_000);
        fields.Remove("runs");
        return fields;
    }

    // MARK: Paragraph & list item runs

    public static bool RunsEditable(JsonNode? runs) => S.Arr(runs).All(IsPlainRun);

    public static string RunsText(JsonNode? runs) => string.Concat(S.Arr(runs).Select(run => run.Text("inline_type") switch
    {
        "text" => run.Text("text"),
        "icon" => $"[{run.Text("name")}]",
        _ => "[图片]",
    }));

    public static JsonArray PlainRuns(string text) => text.Length == 0
        ? new JsonArray()
        : new JsonArray(new JsonObject
        {
            ["inline_type"] = "text", ["text"] = S.Prefix(text, 20_000), ["marks"] = new JsonArray(), ["href"] = null, ["style"] = PlainStyle(),
        });

    public static JsonObject NewParagraph(string text = "") =>
        new() { ["node_id"] = NewNodeID(), ["block_type"] = "paragraph", ["runs"] = PlainRuns(text), ["source_refs"] = new JsonArray() };

    public static JsonObject NewList(bool ordered) =>
        new() { ["node_id"] = NewNodeID(), ["block_type"] = ordered ? "ordered_list" : "bullet_list", ["start"] = ordered ? S.Num(1) : null, ["items"] = new JsonArray(NewListItem()) };

    public static JsonObject NewListItem(string text = "") =>
        new() { ["node_id"] = NewNodeID(), ["runs"] = PlainRuns(text), ["source_refs"] = new JsonArray() };

    public static JsonObject NewEntry() =>
        new() { ["node_id"] = NewNodeID(), ["fields"] = new JsonObject(), ["blocks"] = new JsonArray(), ["source_refs"] = new JsonArray() };

    public static JsonObject NewSection(string kind, string title) => new()
    {
        ["node_id"] = NewNodeID(), ["semantic_kind"] = kind, ["title"] = SetValue(null, title),
        ["entries"] = new JsonArray(), ["blocks"] = new JsonArray(), ["source_refs"] = new JsonArray(),
    };

    public static JsonObject NewContact(string kind, string value) =>
        new() { ["node_id"] = NewNodeID(), ["contact_kind"] = kind, ["value"] = value, ["source_refs"] = new JsonArray() };

    /// <summary>段落或列表项写入 runs（文字、图标与行内图片）。</summary>
    public static JsonNode? SetBlockRuns(JsonNode? node, IEnumerable<JsonNode?> runs)
    {
        if (node is not JsonObject obj) return S.Clone(node);
        var fields = (JsonObject)obj.DeepClone();
        fields["runs"] = S.Array(NormalizeRuns(runs).Take(2000));
        return fields;
    }

    public static JsonNode? SetAlign(JsonNode? node, string? align)
    {
        if (node is not JsonObject obj) return S.Clone(node);
        var fields = (JsonObject)obj.DeepClone();
        fields["align"] = align is null ? null : JsonValue.Create(align);
        return fields;
    }

    /// <summary>分栏行：pair 两栏（左栏 30–80%），trio 三栏，meta 四栏。</summary>
    public static JsonObject NewRow(string kind)
    {
        var count = kind switch { "pair" => 2, "trio" => 3, "meta" => 4, _ => 2 };
        var cells = new JsonArray();
        for (var i = 0; i < count; i++)
            cells.Add(new JsonObject { ["node_id"] = NewNodeID(), ["source_refs"] = new JsonArray(), ["blocks"] = new JsonArray(NewParagraph()) });
        return new JsonObject
        {
            ["node_id"] = NewNodeID(), ["source_refs"] = new JsonArray(), ["block_type"] = "row", ["row_kind"] = kind,
            ["cells"] = cells, ["left_width_percent"] = kind == "pair" ? S.Num(50) : null, ["column_widths_percent"] = null,
        };
    }

    public static JsonObject NewImage(string src, string? alt) => new()
    {
        ["node_id"] = NewNodeID(), ["source_refs"] = new JsonArray(), ["block_type"] = "media", ["media_kind"] = "resume_image",
        ["src"] = src, ["alt"] = alt is null ? null : JsonValue.Create(alt), ["width"] = S.Num(100), ["width_unit"] = "%",
        ["height_px"] = null, ["align"] = "center", ["system_fallback"] = false,
    };

    public static readonly (double Min, double Max) AvatarSizeRange = (56.0, 220.0);

    /// <summary>头像：保留原 node_id 与来源引用，只替换图片地址。</summary>
    public static JsonObject Avatar(JsonNode? previous, string src, double width = 96)
    {
        var fields = previous is JsonObject existing ? (JsonObject)existing.DeepClone()
            : new JsonObject { ["node_id"] = NewNodeID(), ["source_refs"] = new JsonArray() };
        fields["media_kind"] = "avatar"; fields["src"] = src;
        if (!fields.ContainsKey("alt")) fields["alt"] = null;
        if (fields["width"] is null) fields["width"] = S.Num(width);
        fields["width_unit"] = "px";
        fields["height_px"] = null; fields["align"] = null; fields["system_fallback"] = false;
        return fields;
    }

    /// <summary>简历图片地址只接受 http(s) 或站内 `/api/assets`、`/api/resumes`、`/templates` 路径（schema `src` pattern）。</summary>
    public static bool ValidImageSource(string src) =>
        S.Matches(@"^(?:https?://[^\s]{1,2040}|/(?:api/assets|api/resumes|templates)/[^\s]{1,2020})" + S.End, src);

    /// <summary>段落或列表项写入纯文本（只在 RunsEditable 时调用）。</summary>
    public static JsonNode? SetRuns(JsonNode? node, string text)
    {
        if (node is not JsonObject obj) return S.Clone(node);
        var fields = (JsonObject)obj.DeepClone();
        fields["runs"] = PlainRuns(text);
        return fields;
    }

    // MARK: Validation & dispositions

    /// <summary>提交前清理：空的列表项与列表移除；联系方式值不能为空；重算来源处置。</summary>
    public static JsonNode? PrepareForSave(JsonNode? document, JsonNode? previous)
    {
        if (document is not JsonObject obj) return S.Clone(document);
        var fields = (JsonObject)obj.DeepClone();
        if (fields["identity"] is JsonObject identity)
            identity["contacts"] = S.Array(S.Arr(identity["contacts"]).Where(x => S.TrimWs(x.Text("value")).Length > 0));
        fields["sections"] = S.Array(S.Arr(fields["sections"]).Select(CleanSection));
        var next = fields.DeepClone();
        fields["source_dispositions"] = S.Array(SourceDispositions(previous, next));
        return fields;
    }

    static JsonArray CleanBlocks(JsonNode? blocks)
    {
        var result = new JsonArray();
        foreach (var block in S.Arr(blocks))
        {
            var type = block.Text("block_type");
            if (type is not ("bullet_list" or "ordered_list") || block is not JsonObject list) { result.Add(S.Clone(block)); continue; }
            var items = S.Arr(list["items"]).Where(x => S.TrimWs(RunsText(x.Get("runs"))).Length > 0 || !RunsEditable(x.Get("runs"))).ToList();
            if (items.Count == 0) continue;
            var copy = (JsonObject)list.DeepClone();
            copy["items"] = S.Array(items);
            result.Add(copy);
        }
        return result;
    }

    static JsonNode? CleanSection(JsonNode? section)
    {
        if (section is not JsonObject obj) return S.Clone(section);
        var fields = (JsonObject)obj.DeepClone();
        fields["blocks"] = CleanBlocks(fields["blocks"]);
        fields["entries"] = S.Array(S.Arr(fields["entries"]).Select(entry =>
        {
            if (entry is not JsonObject entryObj) return S.Clone(entry);
            var entryFields = (JsonObject)entryObj.DeepClone();
            entryFields["blocks"] = CleanBlocks(entryFields["blocks"]);
            return entryFields;
        }));
        return fields;
    }

    /// <summary>
    /// Web `canonicalV1SourceDispositions`：按新文档里仍引用来源的节点重写目标；不再被引用的非 dropped 来源改为 `user_removed`。
    /// target_node_ids 的顺序按遍历顺序；Swift 遍历字典的顺序不固定，这里按 JSON 里的键序（同一来源被多个节点引用时，顺序可能与 Mac 不同）。
    /// </summary>
    public static List<JsonNode?> SourceDispositions(JsonNode? previous, JsonNode? next)
    {
        var targets = new Dictionary<string, List<string>>();
        void Visit(JsonNode? value)
        {
            switch (value)
            {
                case JsonArray items: foreach (var item in items) Visit(item); break;
                case JsonObject obj:
                    if (obj["node_id"].String() is { } id && S.HasPrefix(id, "node_") && obj.ContainsKey("source_refs"))
                        foreach (var source in S.Strings(obj["source_refs"]))
                        {
                            if (!targets.TryGetValue(source, out var list)) targets[source] = list = [];
                            if (!list.Contains(id)) list.Add(id);
                        }
                    foreach (var (key, child) in obj) if (key != "source_dispositions") Visit(child);
                    break;
            }
        }
        Visit(next);
        return S.Arr(previous.Get("source_dispositions")).Select(disposition =>
        {
            if (disposition is not JsonObject obj) return S.Clone(disposition);
            var fields = (JsonObject)obj.DeepClone();
            var outcome = disposition.Text("outcome");
            if (targets.TryGetValue(disposition.Text("source_id"), out var found) && found.Count > 0)
            {
                fields["outcome"] = outcome == "transformed" ? "transformed" : "mapped";
                fields["target_node_ids"] = S.StringArray(found);
                fields["reason_code"] = outcome == "transformed" ? S.Clone(obj["reason_code"]) : null;
                return fields;
            }
            if (outcome == "dropped") return fields;
            fields["outcome"] = "dropped"; fields["target_node_ids"] = new JsonArray(); fields["reason_code"] = "user_removed";
            return (JsonNode?)fields;
        }).ToList();
    }

    static readonly Dictionary<string, string> SaveMessages = new()
    {
        ["RESUME_EDIT_CONFLICT"] = "简历已在其他地方更新。请重新载入后再修改，当前未保存的内容会丢失。",
        ["RESUME_SCHEMA_INVALID"] = "简历内容不符合格式要求，请检查后重试。",
        ["TEMPLATE_COMPOSITION_INVALID"] = "当前模板无法容纳这些内容，请换一个模板或调整模块。",
        ["TEMPLATE_INACTIVE"] = "这个模板已下线，请换一个模板。",
        ["INVALID_RESUME_STYLE"] = "版式设置超出范围，请调整后重试。",
        ["RESUME_WRITE_PENDING"] = "简历正在被 AI 修改，请稍后再试。",
        ["INVALID_RESUME_TITLE"] = "名称无效，请输入 1–255 个字符且不含换行。",
        ["RESUME_TITLE_CONFLICT"] = "已有同名简历，请换一个名称。",
        ["DESKTOP_ROUTE_FORBIDDEN"] = "当前服务尚未开放桌面端编辑，请更新服务端后重试。",
    };

    public static string SaveError(Exception error)
    {
        if (S.IsUnauthorized(error)) return "登录已失效，请重新登录。修改尚未保存。";
        if (!S.IsServer(error, out var status, out var code)) return "网络中断，修改可能尚未保存。请重试保存。";
        return SaveMessages.TryGetValue(code, out var message) ? message : status == 422 ? "内容有字段超出限制，请检查长度后重试。" : $"保存失败（{code}），请稍后重试。";
    }
}

/// <summary>JSON 路径：对象键或数组下标。</summary>
public abstract record JsonPathPart
{
    public sealed record Key(string Name) : JsonPathPart;
    public sealed record Index(int Position) : JsonPathPart;
}

/// <summary>Mac `ResumeDocument.swift` 里 `extension JSONValue` 的路径读写；都返回新节点，不改动原节点。</summary>
public static class JsonPathExtensions
{
    /// <summary>`json[path:]`：任何一步缺失返回 null；数组下标越界返回 null。</summary>
    public static JsonNode? At(this JsonNode? node, IReadOnlyList<JsonPathPart> path)
    {
        var current = node;
        foreach (var part in path)
        {
            switch (part)
            {
                case JsonPathPart.Key key: current = current.Get(key.Name); break;
                case JsonPathPart.Index index:
                    if (current is not JsonArray items || index.Position < 0 || index.Position >= items.Count) return null;
                    current = items[index.Position];
                    break;
            }
        }
        return current;
    }

    /// <summary>
    /// 返回在 path 处写入（null 表示删除对象键或数组元素）后的新值；中间缺失的对象会被创建。
    /// 与 Swift 不同的唯一一点：Swift 能区分“写入 JSON null”和“删除”，这里两者都用 null 表示删除——要写 JSON null 请传 <paramref name="writeNull"/>。
    /// </summary>
    public static JsonNode? Setting(this JsonNode? node, IReadOnlyList<JsonPathPart> path, JsonNode? value, bool writeNull = false)
    {
        if (path.Count == 0) return S.Clone(value);
        var rest = path.Skip(1).ToList();
        switch (path[0])
        {
            case JsonPathPart.Key key:
                var obj = node is JsonObject existing ? (JsonObject)existing.DeepClone() : new JsonObject();
                if (rest.Count == 0)
                {
                    if (value is not null || writeNull) obj[key.Name] = S.Clone(value); else obj.Remove(key.Name);
                }
                else
                {
                    var child = obj.ContainsKey(key.Name) ? obj[key.Name] : new JsonObject();
                    obj[key.Name] = child.Setting(rest, value, writeNull);
                }
                return obj;
            case JsonPathPart.Index index:
                if (node is not JsonArray array || index.Position < 0 || index.Position >= array.Count) return S.Clone(node);
                var items = S.Arr(array).Select(S.Clone).ToList();
                if (rest.Count == 0)
                {
                    if (value is not null || writeNull) items[index.Position] = S.Clone(value); else items.RemoveAt(index.Position);
                }
                else items[index.Position] = items[index.Position].Setting(rest, value, writeNull);
                return S.Array(items);
            default: return S.Clone(node);
        }
    }

    /// <summary>在数组 path 末尾追加；path 指向的不是数组时新建数组。</summary>
    public static JsonNode? Appending(this JsonNode? node, IReadOnlyList<JsonPathPart> path, JsonNode? value)
    {
        var items = S.Arr(node.At(path));
        items.Add(value);
        return node.Setting(path, S.Array(items));
    }

    /// <summary>交换数组 path 中两个元素；下标越界时原样返回。</summary>
    public static JsonNode? Moving(this JsonNode? node, IReadOnlyList<JsonPathPart> path, int from, int to)
    {
        var items = S.Arr(node.At(path));
        if (from < 0 || from >= items.Count || to < 0 || to >= items.Count) return S.Clone(node);
        (items[from], items[to]) = (items[to], items[from]);
        return node.Setting(path, S.Array(items));
    }
}
