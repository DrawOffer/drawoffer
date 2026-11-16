using System.Text.Json.Nodes;
using DrawOffer.Core.Api;
using S = DrawOffer.Core.Models.SwiftCompat;

namespace DrawOffer.Core.Models;

/// <summary>
/// 检查简历（Web `workbench/ResumeCheck.tsx`，Mac `ResumeCheck.swift`，Windows 稿 03 页分区 12.7–12.11）：把整份简历拆成段，
/// `POST /api/resumes/{id}/review:check` 一次读完，服务端给出最多 6 处；这里负责组请求、解析结果，
/// 以及把“换上 / 删掉 / 换标题”写回 canonical 正文。判定、排序、上限和总结论都在服务端。
/// </summary>
public static class ResumeCheck
{
    public const int MaxUnits = 16;
    public const int MaxLines = 20;
    public const int LineChars = 500;
    public const int UnitChars = 4_000;

    /// <summary>不检查的模块（简介、证书、荣誉、兴趣……）；其中技能类按技能检查。与 Web `LIST_SECTION` / `SKILL_SECTION` 相同。</summary>
    static readonly string[] SkillWords = ["技能", "技术栈", "专长", "能力"];
    static readonly string[] ListWords = [.. SkillWords, "评价", "简介", "总结", "兴趣", "爱好", "语言", "证书", "荣誉", "奖项", "获奖", "自我"];
    static readonly HashSet<string> OtherKinds = ["profile", "interests", "certificates", "awards", "languages"];
    /// <summary>条目标题优先取名称，没有时取单位；其余字段（角色、时间、地点）只给模型看。</summary>
    static readonly string[] HeadingFields = ["name", "organization"];

    public enum Kind { Experience, Skills, Other }

    public sealed record Unit(string Id, string SectionLabel, string Heading, string? HeadingField, IReadOnlyList<string> Meta, Kind Kind, bool IsEntry,
        IReadOnlyList<SectionFocus.Line> Lines)
    {
        public string Where => string.Join(" · ", new[] { SectionLabel, IsEntry ? Heading : "" }.Where(x => x.Length > 0));

        internal JsonObject CheckPayload => new()
        {
            ["entry_id"] = Id,
            ["section"] = S.Prefix(SectionLabel, 60),
            ["heading"] = S.Prefix(Heading, 200),
            ["meta"] = S.Array(Meta.Take(6).Select(x => (JsonNode?)JsonValue.Create(S.Prefix(x, 200)))),
            ["kind"] = Kind == Kind.Skills ? "skills" : "experience",
            ["lines"] = S.Array(Lines.Select(x => (JsonNode?)new JsonObject { ["id"] = x.Id, ["text"] = x.Text })),
        };

        /// <summary>`section-review:rewrite` 的 section（Web `sectionPayload`）。</summary>
        public JsonObject SectionPayload => new()
        {
            ["entry_id"] = Id,
            ["heading"] = S.Prefix(string.Join(" · ", new[] { Heading }.Concat(Meta).Where(x => x.Length > 0)), 200),
            ["kind"] = Kind switch { Kind.Skills => "skills", Kind.Other => "other", _ => "experience" },
            ["lines"] = S.Array(Lines.Select(x => (JsonNode?)new JsonObject { ["id"] = x.Id, ["text"] = x.Text })),
        };

        internal string ContextText => string.Join("\n", new[] { Heading }.Concat(Meta).Concat(Lines.Select(x => x.Text)).Where(x => x.Length > 0));
    }

    public enum Status { Open, Applied, Skipped }

    /// <param name="Fix">rewrite / complete / delete / merge / entry</param>
    /// <param name="Before">纸面上这一行原来的文字（整段时是标题），写回前核对。</param>
    public sealed record Finding(string Id, string Type, string TypeLabel, string EntryId, string? LineId, string Quote, string Title, string Detail,
        string Fix, string? Suggestion, IReadOnlyList<string> Risky, string? MergeInto, string Caption, string Ask, string Example,
        string Before, string MergeBefore, string Label, string Where)
    {
        public Status Status { get; set; } = Status.Open;
        public string? Suggestion { get; set; } = Suggestion;
        public IReadOnlyList<string> Risky { get; set; } = Risky;
        public string Caption { get; set; } = Caption;
        public string Detail { get; set; } = Detail;
    }

    public sealed record Result(string Summary, string Basis, IReadOnlyList<Finding> Findings);

    // MARK: Units

    public static Kind KindOf(string semantic, string label)
    {
        if (semantic == "skills" || SkillWords.Any(label.Contains)) return Kind.Skills;
        if (OtherKinds.Contains(semantic) || ListWords.Any(label.Contains)) return Kind.Other;
        return Kind.Experience;
    }

    /// <summary>可改写的行：只取前 20 行里没被截断的（截断的行写回前核对不过），整段不超过 4000 字。</summary>
    static List<SectionFocus.Line> Lines(JsonNode? blocks)
    {
        var budget = UnitChars;
        var result = new List<SectionFocus.Line>();
        foreach (var line in SectionFocus.Lines(blocks).Where(x => S.TrimWs(x.Text).Length > 0))
        {
            var count = S.Count(line.Text);
            if (result.Count >= MaxLines || count > LineChars || count > budget) continue;
            budget -= count;
            result.Add(line);
        }
        return result;
    }

    /// <summary>整份简历拆成段：有条目的模块每个条目一段，没有条目的模块整个一段；不检查的模块和空段不发。</summary>
    public static List<Unit> Units(JsonNode? document, Func<JsonNode, string> label)
    {
        var units = new List<Unit>();
        foreach (var section in document.Items("sections"))
        {
            var sectionLabel = label(section);
            var kind = KindOf(section.Text("semantic_kind"), sectionLabel);
            if (kind == Kind.Other) continue;
            var own = Lines(section.Get("blocks"));
            if (own.Count > 0) units.Add(new Unit(section.Text("node_id"), sectionLabel, sectionLabel, null, [], kind, false, own));
            foreach (var entry in section.Items("entries"))
            {
                var found = Lines(entry.Get("blocks"));
                if (found.Count == 0) continue;
                var fields = entry.Get("fields");
                var headingField = HeadingFields.FirstOrDefault(key => ResumeDocument.Value(fields.Get(key)).Length > 0);
                var heading = headingField is null ? "" : ResumeDocument.Value(fields.Get(headingField));
                var meta = ResumeDocument.EntryFields.Select(x => x.Key).Where(key => key != headingField && key != "url")
                    .Select(key => ResumeDocument.Value(fields.Get(key))).Where(x => x.Length > 0).ToList();
                units.Add(new Unit(entry.Text("node_id"), sectionLabel, heading, headingField, meta, kind, true, found));
            }
        }
        return units.Take(MaxUnits).ToList();
    }

    public static JsonObject CheckBody(IEnumerable<Unit> units, int pageCount, (string EntryId, string Answer)? focus = null)
    {
        var body = new JsonObject
        {
            ["units"] = S.Array(units.Select(x => (JsonNode?)x.CheckPayload)),
            ["page_count"] = Math.Min(10, Math.Max(1, pageCount)),
        };
        if (focus is { } f) body["focus"] = new JsonObject { ["entry_id"] = f.EntryId, ["answer"] = S.Prefix(f.Answer, 300) };
        return body;
    }

    /// <summary>改写一句时带上的其他段（Web `defaultContextIds` + `contextPayload`）：最多 6 段、每段 1500 字、合计 6000 字。</summary>
    public static JsonArray Context(IEnumerable<Unit> units, string excluding)
    {
        var budget = 6_000;
        var items = new JsonArray();
        foreach (var unit in units.Where(x => x.Id != excluding))
        {
            if (items.Count >= 6 || budget <= 0) break;
            var text = S.Prefix(unit.ContextText, Math.Min(1_500, budget));
            budget -= S.Count(text);
            var label = unit.IsEntry && unit.SectionLabel.Length > 0 ? $"{unit.SectionLabel} · {unit.Heading}" : unit.Heading;
            items.Add(new JsonObject { ["id"] = unit.Id, ["label"] = S.Prefix(label, 120), ["text"] = text });
        }
        return items;
    }

    // MARK: Findings

    static string ListLabel(string type, string quote, string fix, string title)
    {
        quote = S.Trimmed(quote);
        if (quote.Length > 0 && type is "empty" or "overclaim" or "vague")
        {
            var shortQuote = S.Count(quote) > 14 ? S.Prefix(quote, 14) + "…" : quote;
            return type switch
            {
                "empty" => $"“{shortQuote}”是空话",
                "overclaim" => $"“{shortQuote}”说过头了",
                _ => $"“{shortQuote}”结果含糊",
            };
        }
        if (type == "deletable") return fix == "merge" ? "有两条说的是同一件事" : "有一条可以删";
        return title;
    }

    static Finding? FindingOf(JsonNode item, IReadOnlyList<Unit> units)
    {
        if (units.FirstOrDefault(x => x.Id == item.Text("entry_id")) is not { } unit) return null;
        var lineId = item.Text("line_id") is { Length: > 0 } l ? l : null;
        var line = lineId is null ? null : unit.Lines.FirstOrDefault(x => x.Id == lineId);
        if (lineId is not null && line is null) return null;
        var fix = item.Text("fix");
        // 整段换标题只对有名称 / 单位字段的条目可写
        if (fix == "entry" && unit.HeadingField is null) return null;
        var mergeInto = item.Text("merge_into") is { Length: > 0 } m ? m : null;
        var type = item.Text("type");
        return new Finding(
            item.Text("id"), type, item.Text("type_label"), unit.Id, lineId,
            item.Text("quote"), item.Text("title"), item.Text("detail"), fix,
            item.Text("suggestion") is { Length: > 0 } suggestion ? suggestion : null,
            item.Items("risky").Select(x => x.String()).OfType<string>().ToList(), mergeInto,
            item.Text("caption"), item.Text("ask"), item.Text("example"),
            line?.Text ?? unit.Heading,
            mergeInto is null ? "" : unit.Lines.FirstOrDefault(x => x.Id == mergeInto)?.Text ?? "",
            ListLabel(type, item.Text("quote"), fix, item.Text("title")),
            unit.Where);
    }

    public static Result ResultOf(JsonNode? response, IReadOnlyList<Unit> units) =>
        new(response.Text("summary"), response.Text("basis"), response.Items("findings").Select(x => FindingOf(x, units)).OfType<Finding>().ToList());

    // MARK: Writing back

    public enum WriteError { None, Conflict, Missing }

    /// <summary>某一行（段落或列表项）当前的文字；找不到时为 null。</summary>
    public static string? LineText(JsonNode? document, string lineId)
    {
        switch (document)
        {
            case JsonObject obj:
                if (obj["node_id"].String() == lineId && obj.ContainsKey("runs")) return ResumeDocument.RunsText(obj["runs"]);
                foreach (var (_, value) in obj) if (LineText(value, lineId) is { } found) return found;
                return null;
            case JsonArray items:
                foreach (var item in items) if (LineText(item, lineId) is { } found) return found;
                return null;
            default: return null;
        }
    }

    static bool Same(string left, string right) => S.Trimmed(left) == S.Trimmed(right);

    /// <summary>换上一句：这一行还是检查时的文字才换，被改过就不动。</summary>
    public static (JsonNode? Document, WriteError Error) ReplaceLine(JsonNode? document, string lineId, string before, string text)
    {
        if (LineText(document, lineId) is not { } current) return (null, WriteError.Missing);
        if (!Same(current, before)) return (null, WriteError.Conflict);
        return SectionFocus.Replacing(document, lineId, text) is { } next ? (next, WriteError.None) : (null, WriteError.Missing);
    }

    /// <summary>删掉一行：段落块或列表项；列表删空时整个列表一起删。</summary>
    public static (JsonNode? Document, WriteError Error) DeleteLine(JsonNode? document, string lineId, string before)
    {
        if (LineText(document, lineId) is not { } current) return (null, WriteError.Missing);
        if (!Same(current, before)) return (null, WriteError.Conflict);
        var found = false;
        JsonNode? Visit(JsonNode? node)
        {
            switch (node)
            {
                case JsonObject obj:
                    var fields = new JsonObject();
                    foreach (var (key, value) in obj) fields[key] = Visit(value);
                    return fields;
                case JsonArray items:
                    var kept = new JsonArray();
                    foreach (var item in items)
                    {
                        if (item.Text("node_id") == lineId && item is JsonObject o && o.ContainsKey("runs")) { found = true; continue; }
                        var next = Visit(item);
                        var list = next.Text("block_type") is "bullet_list" or "ordered_list";
                        if (list && item.Items("items").Count > 0 && next.Items("items").Count == 0) continue;
                        kept.Add(next);
                    }
                    return kept;
                default: return node?.DeepClone();
            }
        }
        var result = Visit(document);
        return found ? (result, WriteError.None) : (null, WriteError.Missing);
    }

    /// <summary>换标题（整段）：把条目的名称 / 单位字段换成建议的标题。</summary>
    public static (JsonNode? Document, WriteError Error) ReplaceHeading(JsonNode? document, string entryId, string field, string before, string text)
    {
        var error = WriteError.Missing;
        JsonNode? Visit(JsonNode? node)
        {
            switch (node)
            {
                case JsonObject obj:
                    if (obj["node_id"].String() == entryId && obj["fields"] is JsonObject entryFields)
                    {
                        if (!Same(ResumeDocument.Value(entryFields[field]), before)) { error = WriteError.Conflict; return obj.DeepClone(); }
                        if (ResumeDocument.SetTextRuns(entryFields[field], ResumeDocument.PlainRuns(S.Prefix(text, 200)).Select(x => x)) is not { } value) return obj.DeepClone();
                        var copy = (JsonObject)obj.DeepClone();
                        ((JsonObject)copy["fields"]!)[field] = value;
                        error = WriteError.None;
                        return copy;
                    }
                    var fields = new JsonObject();
                    foreach (var (key, value) in obj) fields[key] = Visit(value);
                    return fields;
                case JsonArray items: return S.Array(items.Select(Visit));
                default: return node?.DeepClone();
            }
        }
        var next = Visit(document);
        return error == WriteError.None ? (next, error) : (null, error);
    }

    public static (bool Credit, string Message) ErrorMessage(Exception error)
    {
        if (error is ApiException { Code: "CREDIT_INSUFFICIENT" or "PAID_CREDIT_REQUIRED" }) return (true, "积分不够了，充值后再试。");
        return (false, "没连上，稍后再试。");
    }
}
