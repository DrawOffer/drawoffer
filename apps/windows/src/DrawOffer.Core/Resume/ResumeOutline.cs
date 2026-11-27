using System.Text.Json.Nodes;
using S = DrawOffer.Core.Models.SwiftCompat;

namespace DrawOffer.Core.Models;

/// <summary>大纲 V2 模块正文判空（Web `outlineSectionSummary` 的 empty 判断）。</summary>
public static class ResumeOutline
{
    /// <summary>模块正文是否为空（Web `empty` 摘要：行尾“空”标签）。</summary>
    public static bool IsEmpty(JsonNode? section) => Text(section).Length == 0;

    /// <summary>模块标题以外的全部可见文字。条目字段按键名（Unicode 标量序）排序后读取。</summary>
    internal static string Text(JsonNode? section)
    {
        var parts = new List<string>();
        void Blocks(IEnumerable<JsonNode?> list)
        {
            foreach (var block in list)
            {
                parts.Add(ResumeDocument.RunsText(block.Get("runs")));
                foreach (var item in S.Arr(block.Get("items"))) parts.Add(ResumeDocument.RunsText(item.Get("runs")));
                foreach (var cell in S.Arr(block.Get("cells"))) Blocks(S.Arr(cell.Get("blocks")));
            }
        }
        Blocks(S.Arr(section.Get("blocks")));
        foreach (var entry in S.Arr(section.Get("entries")))
        {
            if (entry.Get("fields") is JsonObject fields)
                foreach (var key in fields.Select(x => x.Key).OrderBy(x => x, S.StringOrder)) parts.Add(ResumeDocument.Value(fields[key]));
            Blocks(S.Arr(entry.Get("blocks")));
        }
        return S.Trimmed(string.Join("\n", parts));
    }
}
