using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using S = DrawOffer.Core.Models.SwiftCompat;

namespace DrawOffer.Core.Models;

/// <summary>
/// 简历完整度（Web `features/workbench/resumeCompleteness.ts` 与 `resumeContract.ts` 的
/// `canonicalDocumentToMarkdown`）：把 canonical 正文投影为 Markdown，再按同一组 12 项检查与示例上限计分。
/// 规则只读正文，不经过 AI；Web 改动规则时需要同步这里。
/// </summary>
public sealed record ResumeCompleteness(int Score, IReadOnlyList<ResumeCompleteness.Check> Checks)
{
    public sealed record Check(string Id, string Label, int Earned, int Max)
    {
        /// <summary>未满分时的问题与建议（Web `issue` / `recommendation`）。</summary>
        public string? Issue { get; init; }
        public string? Recommendation { get; init; }
        public bool Passed => Earned == Max;

        /// <summary>Web `category`：basics / experience / education / skills / structure（由检查 id 决定）。</summary>
        public string Category
        {
            get
            {
                if (Id is "name" or "phone" or "email" or "positioning") return "basics";
                if (Id.StartsWith("experience", StringComparison.Ordinal)) return "experience";
                if (Id.StartsWith("education", StringComparison.Ordinal)) return "education";
                if (Id.StartsWith("skills", StringComparison.Ordinal)) return "skills";
                return "structure";
            }
        }

        /// <summary>Web `status`：passed / partial / failed。</summary>
        public string Status => Earned == Max ? "passed" : Earned > 0 ? "partial" : "failed";
    }

    public sealed record Cap(string Id, int MaxScore, string Reason);

    public IReadOnlyList<Cap> Caps { get; init; } = [];

    /// <summary>Web `scoreLevel`。</summary>
    public string Level => Score >= 90 ? "完整" : Score >= 70 ? "较完整" : Score >= 40 ? "基本完整" : "待补充";

    /// <summary>第一项未满分的检查，首页“待完善”使用。</summary>
    public string? Missing => Checks.FirstOrDefault(x => !x.Passed)?.Label;

    /// <summary>Web `pendingChecks`：未满分的检查数，工具卡片“检查”角标。</summary>
    public int PendingCount => Checks.Count(x => !x.Passed);

    /// <summary>Web `flaggedSectionKinds`：未通过的检查影响到的模块类型，大纲行尾显示“待完善”。</summary>
    public IReadOnlySet<string> FlaggedKinds
    {
        get
        {
            var map = new Dictionary<string, string[]> { ["basics"] = ["identity"], ["experience"] = ["work", "project"], ["education"] = ["education"], ["skills"] = ["skills"], ["structure"] = [] };
            return Checks.Where(x => !x.Passed).SelectMany(x => map.GetValueOrDefault(x.Category) ?? []).ToHashSet();
        }
    }

    // MARK: Markdown projection

    static string TextValue(JsonNode? node) => node.Text("value");

    public static string Markdown(JsonNode? document)
    {
        var lines = new List<string>();
        var identity = document.Get("identity");
        var name = TextValue(identity.Get("name"));
        if (name.Length > 0) lines.Add("# " + name);
        var headline = TextValue(identity.Get("headline"));
        if (headline.Length > 0) lines.AddRange(["", headline]);
        var contacts = S.Arr(identity.Get("contacts"));
        if (contacts.Count > 0)
            lines.AddRange(["", string.Join(" ｜ ", contacts.Select(x => (x.Text("label").Length == 0 ? "" : x.Text("label") + "：") + x.Text("value")))]);
        foreach (var section in S.Arr(document.Get("sections")))
        {
            var title = TextValue(section.Get("title"));
            if (title.Length > 0) lines.AddRange(["", "## " + title]);
            foreach (var entry in S.Arr(section.Get("entries")))
            {
                var fields = entry.Get("fields");
                var headingKey = new[] { "name", "organization", "role" }.FirstOrDefault(key => S.HasKey(fields, key));
                var headingValue = headingKey is null ? "" : TextValue(fields.Get(headingKey));
                if (headingValue.Length > 0) lines.AddRange(["", "### " + headingValue]);
                foreach (var key in new[] { "organization", "role", "location", "start_date", "end_date", "degree", "college", "major", "url" })
                {
                    var value = TextValue(fields.Get(key));
                    if (value.Length > 0 && !S.Eq(value, headingValue)) lines.Add(value);
                }
                foreach (var block in S.Arr(entry.Get("blocks"))) { var text = BlockMarkdown(block); if (text.Length > 0) lines.AddRange(["", text]); }
            }
            foreach (var block in S.Arr(section.Get("blocks"))) { var text = BlockMarkdown(block); if (text.Length > 0) lines.AddRange(["", text]); }
        }
        var joined = string.Join("\n", lines);
        // Swift 的 contains 按字素判断，replacingOccurrences 按码元替换；两者都照搬。
        while (S.Has(joined, "\n\n\n")) joined = joined.Replace("\n\n\n", "\n\n", StringComparison.Ordinal);
        return S.Trimmed(joined);
    }

    static string Runs(JsonNode? value) => string.Concat(S.Arr(value).Where(x => x.Text("inline_type") == "text").Select(x => x.Text("text")));

    static string BlockMarkdown(JsonNode? block)
    {
        switch (block.Text("block_type"))
        {
            case "paragraph": return Runs(block.Get("runs"));
            case "bullet_list": return string.Join("\n", S.Arr(block.Get("items")).Select(x => "- " + Runs(x.Get("runs"))));
            case "ordered_list":
                var start = block.Number("start") is { } number ? (long)Math.Truncate(number) : 1;
                return string.Join("\n", S.Arr(block.Get("items")).Select((x, i) => $"{start + i}. " + Runs(x.Get("runs"))));
            case "row":
                return string.Join(" ｜ ", S.Arr(block.Get("cells")).Select(x => Runs(S.ArrOpt(x, "blocks")?.FirstOrDefault().Get("runs"))));
            default: return "";
        }
    }

    // MARK: Scoring

    public static ResumeCompleteness? Evaluate(JsonNode? document) => S.HasKey(document, "identity") ? EvaluateMarkdown(Markdown(document)) : null;

    static Regex Rx(string pattern) => S.Re(pattern, ignoreCase: true);
    static bool Matches(Regex pattern, string text) => pattern.IsMatch(text);
    static List<string> All(Regex pattern, string text) => pattern.Matches(text).Select(x => x.Value).ToList();
    static string Replace(string text, string pattern, string with) => Rx(pattern).Replace(text, with);

    static readonly Regex Education = Rx("(?:教育|学历|院校|education|academic)");
    static readonly Regex Skills = Rx("(?:技能|技术栈|技术能力|专业能力|核心能力|能力与专长|专长|skills?|technolog|competenc|expertise)");
    static readonly Regex ExperienceTitle = Rx("(?:工作|实习|项目|开源|校园|研究|实践|任职|职业|experience|employment|work|projects?|intern|research)");
    static readonly Regex DateRx = Rx(@"(?:19|20)\d{2}(?:\s*[./年-]\s*(?:0?[1-9]|1[0-2])月?)?|至今|现在|present|current");
    static readonly Regex Email = Rx(@"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b");
    static readonly Regex Phone = Rx(@"(?:\+?\d[\d\s()-]{5,}\d)");
    static readonly Regex ListItem = Rx(@"^\s*(?:[-*+]\s+|\d+[.)、]\s*)\S");
    const string ListPrefix = @"^\s*(?:[-*+]\s+|\d+[.)、]\s*)";
    static readonly Regex SkillPlaceholder = Rx("^(?:无|暂无|没有|待补充|待完善|略|技能|专业技能|技术栈|技术能力|核心能力|熟练|精通|掌握|了解)[。.!！]?" + S.End);
    static readonly Regex GenericSkill = Rx("^(?:沟通|学习|执行|抗压|适应|团队协作|责任心|认真负责|吃苦耐劳)(?:能力)?(?:强|良好|优秀)?[。.!！]?" + S.End);
    static readonly Regex SkillApplication = Rx("(?:熟练|精通|掌握|了解|使用|应用|搭建|开发|设计|优化|测试|分析|运营|管理|写作|协作|项目|场景|经验|年|能够|可独立|负责|提升|降低|完成|支持)");
    static readonly Regex LatinSkill = Rx(@"\b[A-Z][A-Z0-9.+#/-]{1,}\b");
    static readonly Regex MultipleConcept = Rx(@"(?:与|及|和|、|/|\+|，|,|；|;)");

    /// <summary>去掉 Markdown 标记后的可见文字。`.` 按 ICU 语义不跨任何行终止符。</summary>
    static string Visible(string value)
    {
        var text = value;
        foreach (var (pattern, with) in new[]
        {
            ("<!--" + S.Dot + "*?-->", " "), (@"!\[[^\]]*\]\([^)]*\)", " "), (@"\[([^\]]+)\]\([^)]*\)", "$1"), ("<[^>]+>", " "),
            (@":\w+\[[^\]]*\]:", " "), (@":::[^\r\n]*", " "), ("[*_~`>#|]", " "), (@"\s+", " "),
        })
            text = Replace(text, pattern, with);
        return S.TrimWs(text);
    }

    static List<string> Phones(string text) =>
        All(Phone, text).Select(x => new string(x.Where(char.IsDigit).ToArray())).Where(x => S.Count(x) is >= 7 and <= 15).ToList();

    static bool MeaningfulIdentity(string body) => body.Split('\n').Any(line =>
    {
        var text = Visible(line);
        var stripped = Replace(text, @"(?:19|20)\d{2}(?:\s*[./年-]\s*(?:0?[1-9]|1[0-2])月?)?", " ");
        stripped = Replace(stripped, "至今|现在|present|current", " ");
        stripped = Replace(stripped, @"[\d\s./年月日|｜·—–~～-]", "");
        return S.Count(stripped) >= 2 && !Matches(ListItem, line) && !Matches(Email, text)
            && !Matches(Rx("^https?://"), text) && !Matches(Rx("^(?:电话|手机|邮箱|博客|主页|地址|技术架构|工作介绍|项目描述)[:：]?" + S.End), text);
    });

    static List<string> SkillEntries(string body)
    {
        var rawLines = body.Split('\n');
        var lines = rawLines.Select(x => Visible(Replace(x, ListPrefix, ""))).Where(x => x.Length > 0).ToList();
        var explicitList = rawLines.Any(x => Matches(ListItem, x));
        var candidates = explicitList ? lines : lines.SelectMany(x => x.Split(['、', '·', '，', ',', '；', ';', '|']).Select(S.TrimWs)).ToList();
        var seen = new HashSet<string>();
        var result = new List<string>();
        foreach (var entry in candidates)
        {
            if (S.Count(entry) is < 2 or > 120 || Matches(SkillPlaceholder, entry)) continue;
            if (seen.Add(S.Lower(entry))) result.Add(entry);
        }
        return result;
    }

    static bool Quality(string entry)
    {
        if (Matches(GenericSkill, entry)) return false;
        if (Matches(LatinSkill, entry)) return true;
        if (Matches(SkillApplication, entry) && S.Count(entry) >= 4) return true;
        return Matches(MultipleConcept, entry) && S.Count(entry) >= 6;
    }

    static Check Make(string id, string label, int earned, int max, string issue, string advice) =>
        new(id, label, earned, max) { Issue = earned == max ? null : issue, Recommendation = earned == max ? null : advice };

    /// <summary>按 Markdown 计分（Swift `evaluate(markdown:)`）。</summary>
    public static ResumeCompleteness EvaluateMarkdown(string source)
    {
        var markdown = source;
        var lines = markdown.Split('\n');
        var h1 = new List<string>();
        var h2 = new List<(int Index, string Title)>();
        var firstH1 = -1;
        for (var index = 0; index < lines.Length; index++)
        {
            var trimmed = S.TrimWs(lines[index]);
            if (S.HasPrefix(trimmed, "# ")) { h1.Add(Visible(S.DropFirst(trimmed, 2))); if (firstH1 < 0) firstH1 = index; }
            else if (S.HasPrefix(trimmed, "## ")) h2.Add((index, Visible(S.DropFirst(trimmed, 3))));
        }
        var sections = h2.Select((heading, offset) =>
            (Title: heading.Title, Body: string.Join("\n", lines[(heading.Index + 1)..(offset + 1 < h2.Count ? h2[offset + 1].Index : lines.Length)]))).ToList();
        var firstH2 = h2.Count > 0 ? h2[0].Index : lines.Length;
        var preambleStart = firstH1 >= 0 ? firstH1 + 1 : 0;
        var preamble = string.Join("\n", lines[preambleStart..Math.Max(preambleStart, firstH2)]);
        string Kind(string title) => Matches(Education, title) ? "education" : Matches(Skills, title) ? "skills" : Matches(ExperienceTitle, title) ? "experience" : "other";
        (int Count, string Text) Body(string type)
        {
            var found = sections.Where(x => Kind(x.Title) == type).ToList();
            return (found.Count, string.Join("\n", found.Select(x => x.Body)));
        }
        var name = h1.Count == 1 ? h1[0] : "";
        var sample = S.Eq(name, "张三");
        var mail = All(Email, markdown).FirstOrDefault() ?? "";
        var phoneNumbers = Phones(markdown);
        var work = Body("experience");
        var school = Body("education");
        var skill = Body("skills");
        var position = string.Concat(preamble.Split('\n').Where(line =>
        {
            var text = Visible(line);
            return text.Length > 0 && !Matches(Email, text) && Phones(text).Count == 0
                && !Matches(Rx(@"(?:https?://|www\.|\b[A-Z0-9.-]+\.(?:com|cn|net|org)\b)"), text)
                && !Matches(Rx(@"^(?:电话|手机|邮箱|博客|主页|地址|微信)\s*[:：]"), text);
        }).Select(Visible));
        var workIdentity = MeaningfulIdentity(work.Text);
        var workDate = Matches(DateRx, Visible(work.Text));
        var schoolIdentity = MeaningfulIdentity(school.Text);
        var schoolDate = Matches(DateRx, Visible(school.Text));
        var details = work.Text.Split('\n').Count(x => Matches(ListItem, x));
        var entries = SkillEntries(skill.Text);
        var qualityCount = entries.Count(Quality);
        static int Tier(int count) => count >= 3 ? 4 : count == 2 ? 3 : count == 1 ? 2 : 0;
        var positionCount = S.Count(position);
        var checks = new List<Check>
        {
            Make("name", "姓名", name.Length > 0 && !sample ? 8 : 0, 8, name.Length == 0 ? "缺少唯一的一级标题姓名。" : "姓名仍是系统示例内容。", "把第一行一级标题改为你的真实姓名。"),
            Make("phone", "联系电话", phoneNumbers.Any(x => x != "13800000000") ? 6 : 0, 6, "未识别到有效的非示例联系电话。", "补充常用联系电话，并检查区号和位数。"),
            Make("email", "联系邮箱", mail.Length > 0 && !Matches(Rx(@"@example\.(?:com|org|net)" + S.End), mail) ? 6 : 0, 6, "未识别到有效的非示例邮箱。", "补充用于求职联系的邮箱地址。"),
            Make("positioning", "职业定位", positionCount >= 10 ? 10 : position.Length == 0 ? 0 : 5, 10, position.Length == 0 ? "姓名和联系方式后缺少职业定位。" : "职业定位过短，目标方向还不够明确。", "用一句话写明目标岗位、经验方向或核心优势。"),
            Make("experience-section", "经历章节", work.Count > 0 && Visible(work.Text).Length > 0 ? 10 : 0, 10, "缺少工作、实习、项目或研究经历。", "至少补充一段与目标岗位相关的经历。"),
            Make("experience-basics", "经历基本信息", workIdentity && workDate ? 10 : workIdentity || workDate ? 5 : 0, 10, "经历中的单位、角色或起止时间不完整。", "为经历补齐单位或项目、角色以及起止时间。"),
            Make("experience-details", "经历成果描述", details >= 3 ? 15 : details == 2 ? 10 : details == 1 ? 5 : 0, 15, "可验证的经历成果条目不足。", "增加 3 条以上职责或成果，优先写行动、结果和数据。"),
            Make("education-section", "教育章节", school.Count > 0 && Visible(school.Text).Length > 0 ? 8 : 0, 8, "缺少教育经历章节。", "补充学校、专业或学习经历。"),
            Make("education-basics", "教育基本信息", schoolIdentity && schoolDate ? 7 : schoolIdentity || schoolDate ? 3 : 0, 7, "教育经历中的学校、专业或时间不完整。", "补齐学校或专业，以及起止时间。"),
            Make("skills-section", "技能内容", entries.Count >= 2 ? 7 : entries.Count == 1 ? 4 : 0, 7, skill.Count > 0 ? "技能章节缺少具体、有效的内容。" : "缺少技能章节及其具体内容。", "补充至少 2 项具体技能，可写明技术、工具、熟悉程度或应用场景。"),
            Make("skills-entries", "技能条目质量", Tier(entries.Count) + Tier(qualityCount), 8, entries.Count < 3 ? "具体技能条目不足 3 项。" : $"已有 {entries.Count} 项技能，但只有 {qualityCount} 项足够具体。", "列出至少 3 项岗位相关技能，并写明工具、熟悉程度或实际应用场景。"),
            Make("structure", "文档结构", (h1.Count == 1 && name.Length > 0 ? 2 : 0) + (h2.Count >= 3 ? 3 : 0), 5, "一级标题不唯一，或二级章节少于 3 个。", "保留一个姓名一级标题，并使用至少 3 个清晰的二级章节。"),
        };
        var caps = new List<Cap>();
        if (sample) caps.Add(new Cap("sample-identity", 20, "姓名仍是系统示例内容，完整度最高按 20 分计算。"));
        if (new[] { "示例大学", "星河云科技有限公司", "青舟数据服务有限公司", "TaskFlow Lite" }.Any(x => S.Has(markdown, x)))
            caps.Add(new Cap("sample-content", 60, "正文仍包含系统示例内容，完整度最高按 60 分计算。"));
        var score = new[] { 100, checks.Sum(x => x.Earned) }.Concat(caps.Select(x => x.MaxScore)).Min();
        return new ResumeCompleteness(score, checks) { Caps = caps };
    }
}
