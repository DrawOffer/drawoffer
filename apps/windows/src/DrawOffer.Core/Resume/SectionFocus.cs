using System.Text.Json.Nodes;
using S = DrawOffer.Core.Models.SwiftCompat;

namespace DrawOffer.Core.Models;

/// <summary>
/// “聚焦这段”（Web `sectionFocus/sectionModel.ts` 的简化移植）：把一段经历（条目）或没有条目的模块
/// 转成 `section-review:analyze` 需要的 `{entry_id, heading, lines}`，并能把采用的改写写回对应行。
/// </summary>
public static class SectionFocus
{
    public const int MaxLines = 20;
    public const int LineChars = 500;

    public sealed record Line(string Id, string Text);

    public sealed record Unit(string Id, string Heading, IReadOnlyList<Line> Lines)
    {
        public JsonObject Payload => new()
        {
            ["entry_id"] = Id,
            ["heading"] = S.Prefix(Heading, 200),
            ["lines"] = S.Array(Lines.Take(MaxLines).Select(x => (JsonNode?)new JsonObject { ["id"] = x.Id, ["text"] = S.Prefix(x.Text, LineChars) })),
        };

        /// <summary>按值比较行（Swift `Equatable`）。</summary>
        public bool Equals(Unit? other) => other is not null && Id == other.Id && Heading == other.Heading && Lines.SequenceEqual(other.Lines);
        public override int GetHashCode() => HashCode.Combine(Id, Heading, Lines.Count);
    }

    /// <summary>一个块里可改写的行：段落本身，或列表的每一项。</summary>
    internal static List<Line> Lines(JsonNode? blocks) => S.Arr(blocks).SelectMany(block =>
    {
        switch (block.Text("block_type"))
        {
            case "paragraph":
                var text = ResumeDocument.RunsText(block.Get("runs"));
                return text.Length == 0 ? [] : new[] { new Line(block.Text("node_id"), text) };
            case "bullet_list":
            case "ordered_list":
                return S.Arr(block.Get("items")).Select(item => (Item: item, Text: ResumeDocument.RunsText(item.Get("runs"))))
                    .Where(x => x.Text.Length > 0).Select(x => new Line(x.Item.Text("node_id"), x.Text));
            default: return [];
        }
    }).ToList();

    /// <summary>条目：标题取字段里的单位/职位/时间等短文本（键名按 Unicode 标量序）；行取条目下的段落与列表项。</summary>
    public static Unit? UnitOf(JsonNode? entry)
    {
        var heading = new List<string>();
        if (entry.Get("fields") is JsonObject fields)
            foreach (var key in fields.Select(x => x.Key).OrderBy(x => x, S.StringOrder))
            {
                var value = ResumeDocument.Value(fields[key]);
                if (value.Length > 0) heading.Add(value);
            }
        var found = Lines(entry.Get("blocks"));
        if (found.Count == 0) return null;
        return new Unit(entry.Text("node_id"), string.Join(" · ", heading), found);
    }

    /// <summary>没有条目的模块（如技能）：整个模块作为一段。</summary>
    public static Unit? UnitOfSection(JsonNode? section)
    {
        var found = Lines(section.Get("blocks"));
        if (found.Count == 0) return null;
        return new Unit(section.Text("node_id"), ResumeDocument.Value(section.Get("title")), found);
    }

    /// <summary>
    /// 把某一行（段落或列表项）的文字替换为采用的改写；找不到这一行时返回 null。
    /// 与 Swift 相同：所有 node_id 相同且带 runs 键的节点都会被替换，命中的节点不再往下遍历。返回新节点。
    /// </summary>
    public static JsonNode? Replacing(JsonNode? document, string lineID, string text)
    {
        var found = false;
        JsonNode? Visit(JsonNode? node)
        {
            switch (node)
            {
                case JsonObject obj:
                    var fields = new JsonObject();
                    if (obj["node_id"].String() == lineID && obj.ContainsKey("runs"))
                    {
                        found = true;
                        foreach (var (key, value) in obj) fields[key] = S.Clone(value);
                        fields["runs"] = ResumeDocument.PlainRuns(S.Prefix(text, LineChars));
                        return fields;
                    }
                    foreach (var (key, value) in obj) fields[key] = Visit(value);
                    return fields;
                case JsonArray items: return S.Array(items.Select(Visit));
                default: return S.Clone(node);
            }
        }
        var next = Visit(document);
        return found ? next : null;
    }

    /// <summary>注意：与 Mac 相同，401 也落到“请检查网络”分支（Mac 只匹配 server 错误）。</summary>
    public static string ErrorMessage(Exception error)
    {
        if (!S.IsServer(error, out var status, out var code)) return "分析没有完成，请检查网络后重试。";
        return code switch
        {
            "CREDIT_INSUFFICIENT" => "积分已用完，本次 AI 请求没有发出。",
            "PAID_CREDIT_REQUIRED" => "当前额度只能使用基础模型，暂不能使用这项功能。",
            "LLM_MODEL_NOT_CONFIGURED" => "AI 模型暂未配置，请稍后再试。",
            "RESUME_NOT_FOUND" => "这份简历已不存在。",
            "SECTION_REVIEW_ITEM_APPLIED" => "这条建议已经采用过了。",
            _ => status >= 500 ? "AI 服务暂时不可用，请稍后重试。" : "分析没有完成，请稍后重试。",
        };
    }
}
