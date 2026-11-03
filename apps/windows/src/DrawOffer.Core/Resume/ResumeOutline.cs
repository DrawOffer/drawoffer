using System.Text.Json.Nodes;
using S = DrawOffer.Core.Models.SwiftCompat;

namespace DrawOffer.Core.Models;

/// <summary>
/// 大纲 V2 每行的一行摘要（Web `outlineSectionSummary` + `outlineSummaryText`）：
/// 个人信息列出已填的联系方式；经历按条目数（段）与要点数；教育没有要点时列学历；只有列表时按条数；否则按字数。
/// </summary>
public static class ResumeOutline
{
    static readonly string[] Degrees = ["博士", "硕士", "本科", "大专", "专科"];
    static readonly Dictionary<string, string> ContactLabels = new()
    {
        ["avatar"] = "头像", ["phone"] = "电话", ["email"] = "邮箱", ["github"] = "GitHub", ["linkedin"] = "LinkedIn", ["website"] = "主页", ["location"] = "城市",
    };

    /// <summary>`identity` 为 null 表示键不存在（Swift 的 nil）；JSON null 节点同样按“没有联系方式”处理。</summary>
    public static string IdentitySummary(JsonNode? identity)
    {
        if (identity is null) return "还没有联系方式";
        var contacts = S.Arr(identity.Get("contacts"));
        var kinds = contacts.Where(x => S.TrimWs(x.Text("value")).Length > 0).Select(x => x.Text("kind")).ToHashSet();
        var content = string.Join("\n", contacts.Select(x => x.Text("value"))) + "\n" + ResumeDocument.Value(identity.Get("headline"));
        if (S.Matches(@"1\d{2}[\s-]?\d{4}[\s-]?\d{4}|\d{3,4}-\d{7,8}", content)) kinds.Add("phone");
        if (S.Matches(@"[\w.+-]+@[\w-]+\.[\w.]+", content)) kinds.Add("email");
        if (content.Contains("github.com", StringComparison.OrdinalIgnoreCase)) kinds.Add("github");
        if (content.Contains("linkedin.com", StringComparison.OrdinalIgnoreCase)) kinds.Add("linkedin");
        var avatar = identity.Get("avatar") is not null;
        var ordered = (avatar ? new[] { "avatar" } : []).Concat(new[] { "phone", "email", "github", "linkedin", "website", "location" }.Where(kinds.Contains)).ToList();
        return ordered.Count == 0 ? "还没有联系方式" : string.Join(" · ", ordered.Select(x => ContactLabels.GetValueOrDefault(x) ?? x));
    }

    /// <summary>模块正文是否为空（Web `empty` 摘要：行尾“空”标签）。</summary>
    public static bool IsEmpty(JsonNode? section) => Text(section).Length == 0;

    public static string Summary(JsonNode? section)
    {
        var body = Text(section);
        if (body.Length == 0) return "还没有内容";
        var entries = S.Arr(section.Get("entries")).Count;
        var bullets = 0;
        void Visit(IEnumerable<JsonNode?> blocks)
        {
            foreach (var block in blocks)
            {
                var type = block.Text("block_type");
                if (type is "bullet_list" or "ordered_list") bullets += S.Arr(block.Get("items")).Count;
                if (type == "row") foreach (var cell in S.Arr(block.Get("cells"))) Visit(S.Arr(cell.Get("blocks")));
            }
        }
        Visit(S.Arr(section.Get("blocks")));
        foreach (var entry in S.Arr(section.Get("entries"))) Visit(S.Arr(entry.Get("blocks")));
        if (entries > 0)
        {
            var found = section.Text("semantic_kind") == "education" && bullets == 0 ? Degrees.Where(x => S.Has(body, x)).ToList() : [];
            return string.Join(" · ", new[] { $"{entries} 段", bullets > 0 ? $"{bullets} 条要点" : null, found.Count == 0 ? null : string.Join(" / ", found) }.OfType<string>());
        }
        if (bullets > 0) return $"{bullets} 条";
        return $"{S.CountNonWhitespace(body)} 字";
    }

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

    /// <summary>Web `OUTLINE_MODULE_OPTIONS`：添加模块弹层的候选，已有的类型不再列出。</summary>
    public static readonly IReadOnlyList<(string Kind, string Title, string Hint)> ModuleOptions =
    [
        ("profile", "个人总结", "用 2–3 句话概括定位与优势"),
        ("work", "工作经历", "公司、职位与主要成果"),
        ("project", "项目经历", "项目背景、职责与结果"),
        ("education", "教育经历", "学校、专业与学历"),
        ("skills", "专业技能", "技术栈与熟练程度"),
        ("activity", "校园经历", "社团、学生工作、竞赛"),
        ("certificates", "证书资质", "语言、职业或技术认证"),
        ("awards", "获奖荣誉", "奖项名称、级别与时间"),
        ("languages", "语言能力", "语种与熟练程度"),
        ("interests", "兴趣爱好", "与岗位相关的个人特长"),
    ];
}
