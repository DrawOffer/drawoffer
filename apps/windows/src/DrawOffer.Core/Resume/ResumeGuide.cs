using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using S = DrawOffer.Core.Models.SwiftCompat;

namespace DrawOffer.Core.Models;

/// <summary>
/// 新建简历的写作引导（Web `workbench/guide/guideModel.ts` 的移植）：步骤文案、各步表单的预填、
/// 结构化写入（`guide/writes`）、条目写法推断，以及收尾写回求职画像与求职资料的清单。
/// 文档都是后端 canonical 简历 JSON（identity / sections / entries / blocks）。
/// </summary>
public static class ResumeGuideModel
{
    public static readonly IReadOnlyList<string> Steps = ["materials", "job_profile", "basics", "education", "skills", "experience", "wrap_up"];
    public static readonly IReadOnlyDictionary<string, string> Labels = new Dictionary<string, string>
    {
        ["materials"] = "资料", ["job_profile"] = "求职意向", ["basics"] = "基本信息", ["education"] = "教育",
        ["skills"] = "技能", ["experience"] = "经历", ["wrap_up"] = "完成",
    };
    /// <summary>Pi 用同一句话识别“面板打开了这一步、请先开口”。</summary>
    public const string Kickoff = "（引导面板打开了这一步）";
    /// <summary>引导里上传的资料统一放进这个资料夹，没有就建一个。</summary>
    public const string FolderName = "简历资料";

    static string Label(string step) => Labels.TryGetValue(step, out var label) ? label : step;
    static string StepStatus(JsonNode? guide, string step) => guide.Get("steps") is { } steps && S.HasKey(steps, step) ? steps.Get(step).Text("status") : "pending";

    /// <summary>只往下走的主按钮写明去哪：“下一步：求职意向”。</summary>
    public static string NextLabel(string step)
    {
        var index = Steps.ToList().IndexOf(step);
        if (index < 0 || index + 1 >= Steps.Count) return "下一步";
        return $"下一步：{(Labels.TryGetValue(Steps[index + 1], out var label) ? label : "")}";
    }

    public static string StepState(JsonNode? guide, string step)
    {
        if (guide.Text("status") == "completed") return "done";
        if (guide.Text("current_step") == step) return "current";
        return StepStatus(guide, step) == "pending" ? "pending" : "done";
    }

    public static List<string> RemainingSteps(JsonNode? guide) => Steps.Where(x => x != "wrap_up" && StepStatus(guide, x) == "pending").ToList();

    /// <summary>“欢迎回来，还差 n 步”的已写好与还差两组。</summary>
    public static (List<string> Done, List<string> Left) Welcome(JsonNode? guide)
    {
        var remaining = RemainingSteps(guide);
        var current = guide.Text("current_step");
        if (!remaining.Contains(current) && current != "wrap_up") remaining.Insert(0, current);
        var left = remaining.Select(Label).Append("完成").ToList();
        var done = Steps.Where(x => x != "wrap_up" && !remaining.Contains(x) && StepStatus(guide, x) != "pending").ToList();
        return (done.Select(Label).ToList(), left);
    }

    public static HashSet<string> SampleIDs(JsonNode? guide) => S.Arr(guide.Get("samples")).Select(x => x.Text("node_id")).ToHashSet();

    public static string FailureKind(string code)
    {
        if (code is "CREDIT_INSUFFICIENT" or "PAID_CREDIT_REQUIRED") return "credit";
        return code is "SKILLS_COMPOSE_INVALID" or "EXPERIENCE_COMPOSE_INVALID" ? "invalid" : "failed";
    }

    // MARK: 文字

    /// <summary>一个 textValue / 块 / 列表项上的纯文字。</summary>
    public static string TextOf(JsonNode? value)
    {
        if (value is null) return "";
        if (value.Get("value").String() is { } text) return text;
        if (S.HasKey(value, "runs")) return ResumeDocument.RunsText(value.Get("runs"));
        return "";
    }

    static string FieldText(JsonNode? entry, string key) => S.Trimmed(TextOf(entry.Get("fields").Get(key)));

    /// <summary>一个节点下所有带 node_id 的节点及其文字。</summary>
    static void NodeTexts(JsonNode? value, Dictionary<string, string> result)
    {
        switch (value)
        {
            case JsonArray items: foreach (var item in items) NodeTexts(item, result); break;
            case JsonObject fields:
                if (fields["node_id"].String() is { } id) result[id] = TextOf(value);
                foreach (var (key, child) in fields) if (key is not ("runs" or "prefix_runs" or "source_refs")) NodeTexts(child, result);
                break;
        }
    }

    static List<string> EntryBullets(JsonNode? entry) => S.Arr(entry.Get("blocks")).SelectMany(block => block.Text("block_type") switch
    {
        "bullet_list" or "ordered_list" => S.Arr(block.Get("items")).Select(TextOf),
        "paragraph" => new[] { TextOf(block) },
        _ => [],
    }).Select(S.Trimmed).Where(x => x.Length > 0).ToList();

    static List<JsonNode?> Sections(JsonNode? document) => S.Arr(document.Get("sections"));
    public static List<string> SectionKinds(JsonNode? document) => Sections(document).Select(x => x.Text("semantic_kind")).ToList();

    /// <summary>纸面上用户自己的条目（模板示例不算）。</summary>
    static List<(string Kind, JsonNode? Entry)> OwnEntries(JsonNode? document, IReadOnlyCollection<string> kinds, ISet<string> samples) =>
        Sections(document).Where(x => kinds.Contains(x.Text("semantic_kind")) && !samples.Contains(x.Text("node_id")))
            .SelectMany(section => S.Arr(section.Get("entries")).Select(entry => (Kind: section.Text("semantic_kind"), Entry: entry)))
            .Where(x => !samples.Contains(x.Entry.Text("node_id"))).ToList();

    // MARK: 条目写法：新写的条目照同类条目的写法来

    static readonly Regex DateRange = S.Re(@"(\d{4}(?:[.\-/年]\d{1,2}月?)?)(\s*[—–\-~～至到]+\s*)(\d{4}(?:[.\-/年]\d{1,2}月?)?|至今|现在|今)");
    static readonly Regex DegreeWord = S.Re("专科|大专|本科|学士|硕士|研究生|博士");
    static readonly Regex SegmentDelimiter = S.Re(@"\s*[｜|]\s*");
    static readonly string[] EntrySections = ["education", "work", "project", "activity"];

    public sealed record DateStyle(string Sep, bool Pad)
    {
        public string Sep { get; set; } = Sep;
        public bool Pad { get; set; } = Pad;
    }

    /// <summary>条目写法：标题与说明行各放哪些槽位、用什么分隔、日期样式与学历顺序。按值比较。</summary>
    public sealed class EntryFormat : IEquatable<EntryFormat>
    {
        public List<(List<string> Slots, string Delimiter)> Lines { get; set; } = [];
        public string Dash { get; set; } = "—";
        public DateStyle Date { get; set; } = new(".", true);
        public string Joiner { get; set; } = " · ";
        public bool DegreeFirst { get; set; }
        public bool InlineExtra { get; set; }

        public EntryFormat Copy() => new()
        {
            Lines = Lines.Select(x => (x.Slots.ToList(), x.Delimiter)).ToList(), Dash = Dash, Date = Date with { }, Joiner = Joiner,
            DegreeFirst = DegreeFirst, InlineExtra = InlineExtra,
        };

        public bool Equals(EntryFormat? other) =>
            other is not null && Lines.Count == other.Lines.Count
            && Lines.Zip(other.Lines).All(x => x.First.Slots.SequenceEqual(x.Second.Slots) && x.First.Delimiter == x.Second.Delimiter)
            && Dash == other.Dash && Date == other.Date && Joiner == other.Joiner && DegreeFirst == other.DegreeFirst && InlineExtra == other.InlineExtra;
        public override bool Equals(object? obj) => Equals(obj as EntryFormat);
        public override int GetHashCode() => HashCode.Combine(Lines.Count, Dash, Date, Joiner, DegreeFirst, InlineExtra);
    }

    /// <summary>默认写法；每次返回新的副本（Swift 是值类型）。</summary>
    public static EntryFormat DefaultFormat => new()
    {
        Lines = [(["name"], "｜"), (["date", "detail"], "｜")], Dash = "—", Date = new DateStyle(".", true), Joiner = " · ", DegreeFirst = false, InlineExtra = false,
    };

    static string[]? Groups(Regex regex, string text) => S.Groups(regex, text);
    static bool Matches(string pattern, string text) => S.Matches(pattern, text);

    static DateStyle? DateStyleOf(string text)
    {
        if (Groups(S.Re(@"\d{4}\s*([.\-/年])\s*(\d{1,2})"), text) is not { } match) return null;
        return new DateStyle(match[1], S.Count(match[2]) == 2);
    }

    /// <summary>随手填的年月（2024.3、2024-03、2024年3月、202403）按模板写法统一；认不出的原样留着。</summary>
    public static string NormalizeDate(string value, DateStyle style)
    {
        var text = S.Trimmed(value);
        if (text is "至今" or "现在" or "今") return "至今";
        if (Groups(S.Re(@"^((?:19|20)\d{2})\s*(?:[.\-/年]\s*(\d{1,2})\s*月?|(\d{2}))?" + S.End), text) is not { } match) return text;
        var month = (int)(S.Int(match[2].Length == 0 ? match[3] : match[2]) ?? 0);
        if (month == 0) return match[1];
        if (month > 12) return text;
        var mm = style.Pad && month < 10 ? $"0{month}" : $"{month}";
        return style.Sep == "年" ? $"{match[1]}年{month}月" : $"{match[1]}{style.Sep}{mm}";
    }

    sealed class EntryParts
    {
        public string Name = "", Start = "", End = "", Detail = "";
        public int Consumed;
        public EntryFormat? Format;
    }

    static List<string> LeadingParagraphs(JsonNode? entry)
    {
        var lines = new List<string>();
        foreach (var block in S.Arr(entry.Get("blocks")))
        {
            if (block.Text("block_type") != "paragraph") break;
            lines.Add(S.Trimmed(TextOf(block)));
        }
        return lines;
    }

    static bool SlotsEqual(List<string>? slots, params string[] expected) => slots is not null && slots.SequenceEqual(expected);

    /// <summary>拆开一个条目的标题和标题下的说明段落：名称、起止、说明各在哪一行、用什么分隔。</summary>
    static EntryParts ReadEntry(JsonNode? entry)
    {
        var heading = S.NilIfBlank(FieldText(entry, "name")) ?? FieldText(entry, "organization");
        var texts = new[] { heading }.Concat(LeadingParagraphs(entry).Take(2)).ToList();
        var parts = new EntryParts();
        var lines = new List<(List<string> Slots, string Delimiter)>();
        var defaults = DefaultFormat;
        string dash = defaults.Dash;
        var date = defaults.Date;
        var dated = false;
        for (var index = 0; index < texts.Count; index++)
        {
            var text = texts[index];
            if (index > 0)
            {
                var previous = lines.Count >= index ? lines[index - 1] : ((List<string>, string)?)null;
                var dateOnly = SlotsEqual(previous?.Item1, "date");
                var hasRange = Groups(DateRange, text) is not null;
                if (text.Length == 0 || !((!dated && hasRange) || (dateOnly && parts.Detail.Length == 0))) break;
            }
            var delimiter = Groups(SegmentDelimiter, text)?[0] ?? defaults.Lines[1].Delimiter;
            var slots = new List<string>();
            foreach (var segment in S.SplitRegex(text, SegmentDelimiter).Select(S.TrimWs).Where(x => x.Length > 0))
            {
                if (!dated && Groups(DateRange, segment) is { } match)
                {
                    dated = true;
                    parts.Start = match[1]; dash = match[2];
                    date = DateStyleOf(match[1]) ?? DateStyleOf(match[3]) ?? date;
                    parts.End = match[3];
                    slots.Add("date");
                }
                else if (index == 0 && parts.Name.Length == 0) { parts.Name = segment; slots.Add("name"); }
                else if (parts.Detail.Length == 0) { parts.Detail = segment; slots.Add("detail"); }
                else parts.Detail += delimiter + segment;
            }
            lines.Add((slots, delimiter));
            if (index > 0) parts.Consumed = index;
        }
        if (!(lines.Count > 0 && lines[0].Slots.Contains("name")))
        {
            var first = lines.Count > 0 ? lines[0] : (Slots: new List<string>(), Delimiter: "｜");
            lines = new[] { (new[] { "name" }.Concat(first.Slots).ToList(), lines.Count > 0 ? first.Delimiter : "｜") }.Concat(lines.Skip(1)).ToList();
        }
        if (dated)
        {
            var detail = parts.Detail;
            parts.Format = new EntryFormat
            {
                Lines = lines, Dash = dash, Date = date,
                Joiner = S.Has(detail, " · ") ? " · " : S.Has(detail, "·") ? "·" : S.Has(detail, " / ") ? " / " : " · ",
                DegreeFirst = Matches("^(专科|大专|本科|学士|硕士|研究生|博士)", S.Trimmed(detail)),
                InlineExtra = S.Has(detail, "；"),
            };
        }
        if (parts.Name.Length == 0) parts.Name = heading;
        if (S.NilIfBlank(FieldText(entry, "start_date")) is { } start) parts.Start = start;
        if (S.NilIfBlank(FieldText(entry, "end_date")) is { } end) parts.End = end;
        return parts;
    }

    public static string EntryName(JsonNode? entry) => entry is null ? "" : ReadEntry(entry).Name;

    /// <summary>新条目照哪种写法：纸面上同一栏 → 模板示例同一栏 → 纸面其他经历栏 → 模板示例其他经历栏 → 默认。</summary>
    public static EntryFormat EntryFormatOf(IReadOnlyList<JsonNode?> documents, IReadOnlyCollection<string> kinds)
    {
        EntryFormat? Pick(JsonNode? document, bool same)
        {
            foreach (var section in Sections(document))
            {
                var kind = section.Text("semantic_kind");
                if (same ? !kinds.Contains(kind) : kinds.Contains(kind) || !EntrySections.Contains(kind)) continue;
                foreach (var entry in S.Arr(section.Get("entries")))
                {
                    if (ReadEntry(entry).Format is { } format)
                    {
                        if (!same) format.InlineExtra = false;
                        return format;
                    }
                }
            }
            return null;
        }
        var first = documents.Count > 0 ? documents[0] : null;
        var second = documents.Count > 1 ? documents[1] : null;
        return Pick(first, true) ?? Pick(second, true) ?? Pick(first, false) ?? Pick(second, false) ?? DefaultFormat;
    }

    /// <summary>模板示例里这一类栏目的标题（如“教育背景”），新建这一栏时沿用。</summary>
    public static string? SectionTitle(IEnumerable<JsonNode?> documents, string kind)
    {
        foreach (var document in documents)
        {
            var section = Sections(document).FirstOrDefault(x => x.Text("semantic_kind") == kind);
            if (section is null) continue;
            var title = S.TrimWs(ResumeDocument.Value(section.Get("title")));
            if (title.Length > 0) return title;
        }
        return null;
    }

    /// <summary>按写法排出条目：标题（名称字段）和标题下的段落。模板没给说明留位置时，说明接在日期那一行。</summary>
    public static (string Name, List<string> Paragraphs) EntryLines(EntryFormat format, string name, string start, string end, string detail)
    {
        var s = NormalizeDate(start, format.Date);
        var e = NormalizeDate(end, format.Date);
        var values = new Dictionary<string, string>
        {
            ["name"] = S.TrimWs(name),
            ["date"] = s.Length > 0 && e.Length > 0 ? s + format.Dash + e : s.Length == 0 ? e : s,
            ["detail"] = S.TrimWs(detail),
        };
        var slots = format.Lines.Select(x => x.Slots.ToList()).ToList();
        if (!slots.Any(x => x.Contains("detail")))
        {
            var at = slots.FindIndex(x => x.Contains("date"));
            slots[Math.Max(0, at < 0 ? 0 : at)].Add("detail");
        }
        var texts = format.Lines.Select((line, index) =>
            string.Join(line.Delimiter, slots[index].Select(x => values.TryGetValue(x, out var v) && v.Length > 0 ? v : null).OfType<string>())).ToList();
        return (texts.Count > 0 && texts[0].Length > 0 ? texts[0] : values["name"], texts.Skip(1).Where(x => x.Length > 0).ToList());
    }

    static JsonObject EntrySpec((string Name, List<string> Paragraphs) lines, IReadOnlyList<string>? bullets = null)
    {
        var spec = new JsonObject { ["name"] = lines.Name };
        if (lines.Paragraphs.Count > 0) spec["paragraphs"] = S.StringArray(lines.Paragraphs);
        if (bullets is { Count: > 0 }) spec["bullets"] = S.StringArray(bullets);
        return spec;
    }

    // MARK: 资料：读到的只用来预填

    /// <summary>资料一步最近一次读出来的整份简历（AI 的资料提案，不确认写入）。并列时取最先出现的。</summary>
    public static JsonNode? MaterialsDocument(IEnumerable<JsonNode?> proposals) =>
        S.MaxBy(proposals.Where(x => x.Text("proposal_mode") == "guided_fill" && x.Get("preview").Text("step") == "materials" && x.Get("data") is not null).OfType<JsonNode>(),
            (a, b) => S.Cmp(a.Text("created_at"), b.Text("created_at")) < 0)?.Get("data");

    static readonly Dictionary<string, string> FoundLabels = new()
    {
        ["set_identity"] = "基本信息", ["education"] = "教育", ["skills"] = "技能", ["work"] = "实习", ["project"] = "项目",
        ["activity"] = "校园", ["awards"] = "获奖", ["certificates"] = "证书", ["languages"] = "语言", ["profile"] = "总结",
    };

    /// <summary>资料读完后的清单行（“读到了 n 项”）。</summary>
    public static List<(string Label, string Text)> FoundRows(JsonNode? proposal) =>
        S.Arr(proposal.Get("preview").Get("changes")).Select(change =>
        {
            var identity = change.Text("op") == "set_identity";
            var kind = identity ? "set_identity" : change.Text("section");
            var lines = S.SplitCharacters(change.Text("after"), "\n").Select(x => S.TrimWs(S.Replace(x, @"^·\s*", ""))).Where(x => x.Length > 0).ToList();
            var text = S.Prefix(identity ? string.Join(" · ", lines) : lines.FirstOrDefault() ?? "", 80);
            return text.Length == 0 ? ((string, string)?)null
                : (FoundLabels.TryGetValue(kind, out var label) ? label : S.NilIfBlank(change.Text("label")) ?? kind, text);
        }).OfType<(string, string)>().ToList();

    /// <summary>引导对话里属于这一步的最后一条 AI 回复（没读出内容时的说明）。开场消息只用来让 AI 先开口。</summary>
    public static string? StepQuestion(IEnumerable<JsonNode?> messages, string step)
    {
        var list = messages.ToList();
        var runSteps = new Dictionary<string, (string Step, bool Kickoff)>();
        foreach (var message in list)
        {
            if (message.Text("role") != "user") continue;
            if (S.HasKey(message, "guide") && message.Get("guide").Text("step").Length > 0 && message.Text("run_id").Length > 0)
                runSteps[message.Text("run_id")] = (message.Get("guide").Text("step"), message.Get("guide").Get("kickoff").Bool());
        }
        string? question = null;
        foreach (var message in list.OrderBy(x => x.Get("sequence_no").Number() ?? 0))
        {
            if (message.Text("message_type") == "compaction" || !runSteps.TryGetValue(message.Text("run_id"), out var run) || run.Step != step) continue;
            if (message.Text("role") == "assistant")
            {
                var text = S.Trimmed(message.Text("content"));
                if (text.Length > 0) question = text;
            }
            else if (!run.Kickoff) question = null;
        }
        return question;
    }

    // MARK: 求职意向

    public sealed class JobIntent : IEquatable<JobIntent>
    {
        public string Role { get; set; } = "";
        public List<string> Cities { get; set; } = [];
        public string Type { get; set; } = "campus";
        public string GraduationYear { get; set; } = "";
        public bool YearFromResume { get; set; }
        public bool Equals(JobIntent? other) => other is not null && Role == other.Role && Cities.SequenceEqual(other.Cities) && Type == other.Type
            && GraduationYear == other.GraduationYear && YearFromResume == other.YearFromResume;
        public override bool Equals(object? obj) => Equals(obj as JobIntent);
        public override int GetHashCode() => HashCode.Combine(Role, Type, GraduationYear, YearFromResume);
    }

    /// <summary>Swift `String(Int(double))`：向零取整。</summary>
    static string YearText(JsonNode? value) => value.Number() is { } number ? ((long)Math.Truncate(number)).ToString(System.Globalization.CultureInfo.InvariantCulture) : "";

    public static JobIntent JobIntentOf(JsonNode? profile, JsonNode? document)
    {
        var intent = new JobIntent();
        var types = S.Strings(profile.Get("employment_types"));
        intent.Type = types.Contains("internship") && types.Contains("full_time") ? "any" : types.Contains("internship") ? "internship" : "campus";
        var fromProfile = YearText(profile.Get("graduation_year"));
        var fromResume = fromProfile.Length == 0 ? GraduationYearOnPaper(document) : "";
        intent.Role = profile.Text("target_role");
        intent.Cities = S.Strings(profile.Get("candidate_cities"));
        intent.GraduationYear = fromProfile.Length == 0 ? fromResume : fromProfile;
        intent.YearFromResume = fromResume.Length > 0;
        return intent;
    }

    public static string GraduationYearOnPaper(JsonNode? document)
    {
        var education = Sections(document).FirstOrDefault(x => x.Text("semantic_kind") == "education");
        var years = S.Arr(education.Get("entries")).SelectMany(entry =>
            S.Re("(19|20)\\d{2}").Matches(ReadEntry(entry).End).Select(x => S.Int(x.Value)).OfType<long>()).ToList();
        return years.Count == 0 ? "" : years.Max().ToString(System.Globalization.CultureInfo.InvariantCulture);
    }

    public static string JobIntentHeadline(JobIntent intent)
    {
        var year = S.TrimWs(intent.GraduationYear);
        return string.Join(" · ", new[]
        {
            S.TrimWs(intent.Role),
            S.Count(year) == 4 && S.Int(year) is not null ? $"{year} 届" : "",
            string.Join(" / ", intent.Cities.Select(S.TrimWs).Where(x => x.Length > 0)),
        }.Where(x => x.Length > 0));
    }

    public static List<string> EmploymentTypes(string type) => type == "internship" ? ["internship"] : type == "any" ? ["full_time", "internship"] : ["full_time"];

    /// <summary>毕业年份连带的画像字段：只有应届生能填，且工作年限为 0。</summary>
    public static Dictionary<string, JsonNode?> GraduationChanges(JsonNode? profile, long? year)
    {
        if (year is not { } value || profile.Text("candidate_status") == "experienced" || (profile.Number("years_experience") ?? 0) != 0) return [];
        return new Dictionary<string, JsonNode?> { ["graduation_year"] = S.Num(value), ["candidate_status"] = "fresh_graduate", ["years_experience"] = S.Num(0) };
    }

    /// <summary>画像整体保存：在最新画像上覆盖改动，带版本号（Web `profileUpdate`）。返回新节点。</summary>
    public static JsonNode? ProfileUpdate(JsonNode? profile, IReadOnlyDictionary<string, JsonNode?> changes)
    {
        if (profile is not JsonObject obj) return S.Clone(profile);
        var fields = (JsonObject)obj.DeepClone();
        foreach (var key in new[] { "lock_version", "created_at", "updated_at", "id", "user_id" }) fields.Remove(key);
        foreach (var (key, value) in changes) fields[key] = S.Clone(value);
        fields["base_lock_version"] = obj.ContainsKey("lock_version") ? S.Clone(obj["lock_version"]) : S.Num(1);
        return fields;
    }

    public static Dictionary<string, JsonNode?> JobIntentChanges(JobIntent intent, JsonNode? latest)
    {
        var seen = new HashSet<string>();
        var cities = intent.Cities.Select(S.TrimWs).Where(x => x.Length > 0 && seen.Add(x)).ToList();
        var changes = new Dictionary<string, JsonNode?>
        {
            ["target_role"] = S.TrimWs(intent.Role),
            ["candidate_cities"] = S.StringArray(cities),
            ["employment_types"] = S.StringArray(EmploymentTypes(intent.Type)),
        };
        var year = S.Int(intent.GraduationYear);
        foreach (var (key, value) in GraduationChanges(latest, year is { } y && y > 1900 ? y : null)) changes[key] = value;
        return changes;
    }

    // MARK: 基本信息

    public sealed record BasicInfo
    {
        public string Name { get; set; } = "";
        public string Phone { get; set; } = "";
        public string Email { get; set; } = "";
        public string Link { get; set; } = "";
    }

    public static BasicInfo BasicInfoOf(JsonNode? document, IReadOnlyDictionary<string, string> personal, ISet<string> samples)
    {
        var identity = document.Get("identity");
        string Own(JsonNode? node)
        {
            if (node is null || samples.Contains(node.Text("node_id"))) return "";
            return S.TrimWs(node.Get("value").String() ?? "");
        }
        string Contact(params string[] kinds) => Own(S.Arr(identity.Get("contacts")).FirstOrDefault(x => kinds.Contains(x.Text("contact_kind"))));
        string? P(string key) => personal.TryGetValue(key, out var value) ? value : null;
        return new BasicInfo
        {
            Name = S.NilIfBlank(Own(identity.Get("name"))) ?? P("name") ?? "",
            Phone = S.NilIfBlank(Contact("phone")) ?? P("phone") ?? "",
            Email = S.NilIfBlank(Contact("email")) ?? P("email") ?? "",
            Link = S.NilIfBlank(Contact("github", "website")) ?? P("github") ?? P("website") ?? "",
        };
    }

    /// <summary>姓名必填，手机和邮箱至少一项。</summary>
    public static bool BasicInfoReady(BasicInfo info) =>
        S.Trimmed(info.Name).Length > 0 && (S.Trimmed(info.Phone).Length > 0 || S.Trimmed(info.Email).Length > 0);

    static List<(string Kind, string Value)> BasicContacts(BasicInfo info)
    {
        var link = S.Trimmed(info.Link);
        return new[] { ("phone", S.Trimmed(info.Phone)), ("email", S.Trimmed(info.Email)), (S.Matches(@"github\.com", link, ignoreCase: true) ? "github" : "website", link) }
            .Where(x => x.Item2.Length > 0).ToList();
    }

    public static List<JsonNode?> BasicInfoOperations(BasicInfo info)
    {
        var op = new JsonObject { ["op"] = "set_identity" };
        if (S.Trimmed(info.Name).Length > 0) op["name"] = S.Trimmed(info.Name);
        var contacts = BasicContacts(info);
        if (contacts.Count > 0) op["contacts"] = S.Array(contacts.Select(x => (JsonNode?)new JsonObject { ["kind"] = x.Kind, ["value"] = x.Value }));
        return [op];
    }

    public static Dictionary<string, string> BasicInfoCareerChanges(BasicInfo info)
    {
        var changes = new Dictionary<string, string>();
        if (S.Trimmed(info.Name).Length > 0) changes["name"] = S.Prefix(S.Trimmed(info.Name), 60);
        foreach (var contact in BasicContacts(info)) changes[contact.Kind] = S.Prefix(contact.Value, 300);
        return changes;
    }

    // MARK: 教育

    public static readonly IReadOnlyList<string> Degrees = ["专科", "本科", "硕士", "博士"];
    static readonly Dictionary<string, string> LevelDegree = new() { ["junior_college"] = "专科", ["bachelor"] = "本科", ["master"] = "硕士", ["doctor"] = "博士" };
    static readonly (string Pattern, string Level)[] DegreeLevels = [("博士", "doctor"), ("硕士|研究生", "master"), ("本科|学士", "bachelor"), ("专科|大专", "junior_college")];

    public sealed record EducationForm
    {
        public string? EntryID { get; set; }
        public string School { get; set; } = "";
        public string Major { get; set; } = "";
        public string Degree { get; set; } = "";
        public string Start { get; set; } = "";
        public string End { get; set; } = "";
        public string Gpa { get; set; } = "";
        public string Courses { get; set; } = "";
    }

    public static EducationForm Education(JsonNode? document, JsonNode? materials, JsonNode? profile, ISet<string> samples)
    {
        var own = OwnEntries(document, ["education"], samples).Select(x => x.Entry).FirstOrDefault();
        var hasOwn = OwnEntries(document, ["education"], samples).Count > 0;
        var readList = OwnEntries(materials, ["education"], new HashSet<string>());
        var entry = hasOwn ? own : readList.Count > 0 ? readList[0].Entry : null;
        var hasEntry = hasOwn || readList.Count > 0;
        var joined = string.Join("；", EntryBullets(entry));
        var form = new EducationForm { EntryID = hasOwn ? own.Text("node_id") : null };
        if (Groups(S.Re("GPA[^；;，,]*", ignoreCase: true), joined) is { } gpa)
            form.Gpa = S.Trimmed(S.Replace(gpa[0], @"^GPA\s*[：:]?\s*", "", ignoreCase: true));
        form.Courses = Groups(S.Re(@"主修(?:课程)?[：:]?\s*([^；;]+)"), joined) is { } courses ? S.Trimmed(courses[1]) : "";
        var meta = hasEntry ? ReadEntry(entry) : null;
        var head = meta is null ? "" : S.SplitCharacters(meta.Detail, "；;").FirstOrDefault() ?? "";
        var headDegree = Groups(DegreeWord, head)?[0] ?? "";
        var headMajor = S.SplitCharacters(S.Replace(head, "专科|大专|本科|学士|硕士|研究生|博士", ""), "·｜|/，,").Select(S.Trimmed).FirstOrDefault(x => x.Length > 0) ?? "";
        var year = YearText(profile.Get("graduation_year"));
        form.School = (meta is not null ? S.NilIfBlank(meta.Name) : null) ?? profile.Text("school");
        form.Major = S.NilIfBlank(FieldText(entry, "major")) ?? S.NilIfBlank(headMajor) ?? profile.Text("major");
        var degreeField = FieldText(entry, "degree");
        form.Degree = Degrees.FirstOrDefault(x => S.Has(degreeField, x))
            ?? Degrees.FirstOrDefault(x => headDegree.Length > 0 && (S.Has(headDegree, x) || (x == "专科" && headDegree == "大专") || (x == "硕士" && headDegree == "研究生")))
            ?? (LevelDegree.TryGetValue(profile.Text("education_level"), out var level) ? level : "");
        form.Start = meta?.Start ?? "";
        form.End = (meta is not null ? S.NilIfBlank(meta.End) : null) ?? (year.Length == 0 ? "" : $"{year}.06");
        return form;
    }

    public static bool EducationReady(EducationForm form) => S.Trimmed(form.School).Length > 0 && S.Trimmed(form.Major).Length > 0 && form.Degree.Length > 0;

    public static List<JsonNode?> EducationOperations(EducationForm form, EntryFormat? format = null, string? title = null)
    {
        format ??= DefaultFormat;
        var extra = string.Join("；", new[] { S.Trimmed(form.Gpa).Length == 0 ? "" : $"GPA {S.Trimmed(form.Gpa)}", S.Trimmed(form.Courses).Length == 0 ? "" : $"主修课程：{S.Trimmed(form.Courses)}" }.Where(x => x.Length > 0));
        var parts = format.DegreeFirst ? new[] { form.Degree, S.Trimmed(form.Major) } : [S.Trimmed(form.Major), form.Degree];
        var head = string.Join(format.Joiner, parts.Where(x => x.Length > 0));
        var inline = format.InlineExtra && extra.Length > 0;
        var detail = inline ? string.Join("；", new[] { head, extra }.Where(x => x.Length > 0)) : head;
        var entry = EntrySpec(EntryLines(format, form.School, form.Start, form.End, detail), extra.Length > 0 && !inline ? [extra] : []);
        if (form.EntryID is { } id) return [new JsonObject { ["op"] = "fill_entry", ["entry_id"] = id, ["entry"] = entry }];
        var op = new JsonObject { ["op"] = "write_section", ["semantic_kind"] = "education", ["entries"] = new JsonArray(entry) };
        if (title is not null) op["title"] = title;
        return [op];
    }

    public static Dictionary<string, JsonNode?> EducationProfileChanges(JsonNode? profile, EducationForm form)
    {
        var changes = new Dictionary<string, JsonNode?>();
        if (S.Trimmed(form.School).Length > 0) changes["school"] = S.Trimmed(form.School);
        if (S.Trimmed(form.Major).Length > 0) changes["major"] = S.Trimmed(form.Major);
        var level = DegreeLevels.FirstOrDefault(x => Matches(x.Pattern, form.Degree)).Level;
        if (level is not null) changes["education_level"] = level;
        var year = Groups(S.Re("(19|20)\\d{2}"), form.End) is { } found ? S.Int(found[0]) : null;
        foreach (var (key, value) in GraduationChanges(profile, year)) changes[key] = value;
        return changes;
    }

    // MARK: 技能

    public static readonly IReadOnlyList<(string Key, string Label)> SkillLevels = [("basic", "了解"), ("familiar", "熟悉"), ("proficient", "熟练")];
    static readonly Dictionary<string, string> LevelWords = new() { ["了解"] = "basic", ["熟悉"] = "familiar", ["熟练"] = "proficient", ["精通"] = "proficient", ["掌握"] = "familiar" };

    public static List<string> SplitSkillNames(string text) =>
        S.SplitCharacters(text, "、,，;；/|\n").Select(x => S.Trimmed(S.Replace(x, @"^[·•\-\s]+", ""))).Where(x => x.Length > 0 && S.Count(x) <= 40).ToList();

    /// <summary>
    /// 纸面技能栏里已有的技能；写过熟练度的（“熟练：Java、MySQL”）带上原来的等级。
    /// 节点文字按键名（Unicode 标量序）深度优先读取。
    /// </summary>
    public static List<(string Name, string? Level)> SkillsOnPaper(JsonNode? document)
    {
        var section = Sections(document).FirstOrDefault(x => x.Text("semantic_kind") == "skills");
        if (section is null) return [];
        var ordered = new List<string>();
        void Visit(JsonNode? value)
        {
            switch (value)
            {
                case JsonArray items: foreach (var item in items) Visit(item); break;
                case JsonObject fields:
                    if (fields.ContainsKey("node_id")) { var text = TextOf(value); if (text.Length > 0) ordered.Add(text); }
                    foreach (var key in fields.Select(x => x.Key).OrderBy(x => x, S.StringOrder))
                        if (key is not ("runs" or "prefix_runs" or "source_refs")) Visit(fields[key]);
                    break;
            }
        }
        Visit(section.Get("entries")); Visit(section.Get("blocks"));
        var found = new List<(string Name, string? Level)>();
        void Add(string name, string? level) { if (!found.Any(x => S.Eq(x.Name, name))) found.Add((name, level)); }
        (string Pattern, string Level)[] verbs = [("^(熟练掌握|熟练|精通|掌握)", "proficient"), ("^熟悉", "familiar"), ("^了解", "basic")];
        foreach (var line in ordered)
        {
            var numbered = S.Replace(line, @"^\s*\d+\s*[.、)）]\s*", "");
            if (Groups(S.Re(@"^\s*([^：:]{1,24})[：:]\s*(" + S.Dot + "*)" + S.End), numbered) is { } expanded
                && verbs.FirstOrDefault(x => Matches(x.Pattern, expanded[2])).Level is { } verb)
            {
                Add(S.Trimmed(expanded[1]), verb); continue;
            }
            foreach (var part in S.SplitCharacters(numbered, "；;"))
            {
                var labelled = Groups(S.Re(@"^\s*([^：:]{1,24})[：:](" + S.Dot + "*)" + S.End), part);
                var label = labelled is null ? "" : S.Trimmed(labelled[1]);
                string? level = LevelWords.TryGetValue(label, out var known) ? known : null;
                var text = labelled is null ? part : (level is not null || !Matches("[A-Za-z]", label)) ? labelled[2] : label;
                foreach (var name in SplitSkillNames(text).Select(x => S.Replace(x, "[。.]+" + S.End, "")))
                    if (name.Length > 0 && S.Count(name) <= 30 && !S.Has(name, "。")) Add(name, level);
            }
        }
        return found;
    }

    /// <summary>系统补充的知识点（知识目录或模型给的），面试里没答好的排在最前。</summary>
    public static List<(int Line, string Text, bool Weak)> AddedPoints(IReadOnlyList<JsonNode?> lines)
    {
        var points = new List<(int Line, string Text, bool Weak)>();
        for (var index = 0; index < lines.Count; index++)
            foreach (var layer in S.Arr(lines[index].Get("layers")))
                foreach (var point in S.Arr(layer.Get("points")))
                    if (point.Text("source") != "user") points.Add((index, point.Text("text"), point.Get("weak").Bool()));
        return points.Where(x => x.Weak).Concat(points.Where(x => !x.Weak)).ToList();
    }

    static readonly Dictionary<string, string> LevelWord = new() { ["basic"] = "了解", ["familiar"] = "熟悉", ["proficient"] = "熟练掌握" };

    /// <summary>一条专业技能排成一行：“方向：熟悉 A、B，熟练掌握 C”，与后端 skills.line_text 一致。</summary>
    public static string SkillLineText(JsonNode? line)
    {
        var layers = S.Arr(line.Get("layers")).Where(x => S.Arr(x.Get("points")).Count > 0)
            .Select(layer => (LevelWord.TryGetValue(layer.Text("level"), out var word) ? word : "") + string.Join("、", S.Arr(layer.Get("points")).Select(x => S.Trimmed(x.Text("text")))));
        return $"{S.Trimmed(line.Text("direction"))}：{string.Join("，", layers)}";
    }

    /// <summary>去掉某条里的一个补充点：层空了去掉这一层，条里不剩点了去掉这一条。返回新列表。</summary>
    public static List<JsonNode?> WithoutPoint(IReadOnlyList<JsonNode?> lines, int target, string text)
    {
        var result = new List<JsonNode?>();
        for (var index = 0; index < lines.Count; index++)
        {
            var line = lines[index];
            if (index != target || line is not JsonObject obj) { result.Add(S.Clone(line)); continue; }
            var fields = (JsonObject)obj.DeepClone();
            var layers = new List<JsonNode?>();
            foreach (var layer in S.Arr(line.Get("layers")))
            {
                if (layer is not JsonObject layerObj) continue;
                var points = S.Arr(layer.Get("points")).Where(x => !S.Eq(x.Text("text"), text)).ToList();
                if (points.Count == 0) continue;
                var layerFields = (JsonObject)layerObj.DeepClone();
                layerFields["points"] = S.Array(points);
                layers.Add(layerFields);
            }
            if (layers.Count == 0) continue;
            fields["layers"] = S.Array(layers);
            fields["text"] = SkillLineText(fields);
            result.Add(fields);
        }
        return result;
    }

    // MARK: 经历

    public static readonly IReadOnlyList<(string Key, string Label, string Section)> ExperienceKinds =
        [("intern", "实习", "work"), ("project", "项目", "project"), ("campus", "校园", "activity"), ("work", "工作", "work")];

    public sealed record ExperienceForm
    {
        public string? EntryID { get; set; }
        public string Kind { get; set; } = "intern";
        public string Name { get; set; } = "";
        public string Role { get; set; } = "";
        public string Start { get; set; } = "";
        public string End { get; set; } = "";
        public string Did { get; set; } = "";
        public string Result { get; set; } = "";
        public bool Ready => S.Trimmed(Name).Length > 0 && S.Trimmed(Did).Length > 0;
        public string Section => ExperienceKinds.FirstOrDefault(x => x.Key == Kind).Section ?? "work";
        public string KindLabel => ExperienceKinds.FirstOrDefault(x => x.Key == Kind).Label ?? "经历";
        public string Summary => string.Join(" · ", new[] { S.Trimmed(Name), S.Trimmed(Role), string.Join(" – ", new[] { S.Trimmed(Start), S.Trimmed(End) }.Where(x => x.Length > 0)) }.Where(x => x.Length > 0));
        public string Meta => string.Join(" · ", new[] { KindLabel, S.Trimmed(Role), string.Join(" – ", new[] { S.Trimmed(Start), S.Trimmed(End) }.Where(x => x.Length > 0)) }.Where(x => x.Length > 0));
    }

    static ExperienceForm ExperienceFormOf(string kind, JsonNode? entry, string? entryID)
    {
        var meta = ReadEntry(entry);
        var form = new ExperienceForm
        {
            EntryID = entryID,
            Kind = kind == "project" ? "project" : kind == "activity" ? "campus" : "intern",
            Name = meta.Name,
            Role = S.NilIfBlank(FieldText(entry, "role")) ?? meta.Detail,
            Start = meta.Start, End = meta.End,
        };
        var rest = entry;
        if (entry is JsonObject obj)
        {
            var fields = (JsonObject)obj.DeepClone();
            fields["blocks"] = S.Array(S.Arr(entry.Get("blocks")).Skip(meta.Consumed));
            rest = fields;
        }
        form.Did = string.Join("；", EntryBullets(rest));
        return form;
    }

    public sealed record ExperienceItem(string Id, string Status, ExperienceForm Form);

    /// <summary>经历清单：纸面上写好的、资料里待写的、选了这份简历不用的。</summary>
    public static List<ExperienceItem> ExperienceList(JsonNode? document, JsonNode? materials, ISet<string> samples, ISet<string> unused)
    {
        string[] kinds = ["work", "project", "activity"];
        var written = OwnEntries(document, kinds, samples)
            .Select(x => new ExperienceItem(x.Entry.Text("node_id"), "written", ExperienceFormOf(x.Kind, x.Entry, x.Entry.Text("node_id")))).ToList();
        bool OnPaper(ExperienceForm form) => written.Any(x => S.Eq(NameCore(x.Form.Name), NameCore(form.Name)) && Overlaps(x.Form, form));
        var read = OwnEntries(materials, kinds, new HashSet<string>())
            .Select(x => ExperienceFormOf(x.Kind, x.Entry, null))
            .Where(x => x.Name.Length > 0 && !OnPaper(x))
            .Select(x => new ExperienceItem($"read:{x.Name}:{x.Start}", unused.Contains(x.Name) ? "unused" : "pending", x));
        return written.Concat(read).ToList();
    }

    public static ExperienceForm NextExperience(JsonNode? document, JsonNode? materials, ISet<string> unused) =>
        ExperienceList(document, materials, new HashSet<string>(), unused).FirstOrDefault(x => x.Status == "pending")?.Form ?? new ExperienceForm();

    public static string NameCore(string name)
    {
        var core = S.Lower(S.Replace(name, @"[\s()（）·・]", ""));
        var previous = "";
        while (previous != core && S.Count(core) > 2)
        {
            previous = core;
            core = S.Replace(core, "(股份有限公司|有限责任公司|有限公司|集团|股份|科技|信息技术|网络技术|网络|技术|公司)" + S.End, "");
        }
        return core;
    }

    static double? Month(string value, bool open)
    {
        if (Matches("至今|现在|今", value)) return double.PositiveInfinity;
        if (Groups(S.Re(@"(\d{4})(?:[.\-/年](\d{1,2}))?"), value) is not { } match || S.DoubleDigits(match[1]) is not { } year) return null;
        return year * 12 + (S.DoubleDigits(match[2]) ?? (open ? 12 : 1));
    }

    static bool Overlaps(ExperienceForm left, ExperienceForm right) => Overlaps(left.Start, left.End, right.Start, right.End);

    static bool Overlaps(string s1, string e1, string s2, string e2)
    {
        if (Month(s1, false) is not { } a1 || Month(s2, false) is not { } b1) return true;
        var a2 = Month(e1, true);
        var b2 = Month(e2, true);
        return a1 <= (b2 ?? b1) && b1 <= (a2 ?? a1);
    }

    /// <summary>简历上和表单是同一段的条目：名称核心相同，且时间有重叠。</summary>
    public static string? MatchingEntry(JsonNode? document, ExperienceForm form, ISet<string> samples)
    {
        var core = NameCore(form.Name);
        if (S.Count(core) < 2) return null;
        foreach (var item in OwnEntries(document, ["work", "project", "activity"], samples))
        {
            var parts = ReadEntry(item.Entry);
            if (S.Eq(NameCore(parts.Name), core) && Overlaps(form.Start, form.End, parts.Start, parts.End)) return item.Entry.Text("node_id");
        }
        return null;
    }

    // MARK: 收尾：证书与获奖

    public sealed record HonorsForm
    {
        public string Certificates { get; set; } = "";
        public string Awards { get; set; } = "";
    }

    static List<string> SectionLines(JsonNode? document, string kind, ISet<string>? samples = null)
    {
        samples ??= new HashSet<string>();
        return Sections(document).Where(x => x.Text("semantic_kind") == kind && !samples.Contains(x.Text("node_id"))).SelectMany(section =>
        {
            var entries = S.Arr(section.Get("entries")).Where(x => !samples.Contains(x.Text("node_id")))
                .Select(x => string.Join(" ", new[] { EntryName(x) }.Concat(EntryBullets(x))));
            var blocks = S.Arr(section.Get("blocks")).Where(x => !samples.Contains(x.Text("node_id")))
                .SelectMany(x => EntryBullets(new JsonObject { ["blocks"] = new JsonArray(S.Clone(x)) }));
            return entries.Concat(blocks);
        }).Select(S.Trimmed).Where(x => x.Length > 0).ToList();
    }

    public static HonorsForm HonorsFormOf(JsonNode? document, JsonNode? materials, JsonNode? profile, ISet<string> samples)
    {
        string Pick(string[] kinds, List<string> remembered)
        {
            var onPaper = kinds.SelectMany(x => SectionLines(document, x, samples)).ToList();
            var lines = onPaper.Count == 0 ? kinds.SelectMany(x => SectionLines(materials, x)).Concat(remembered).ToList() : onPaper;
            var seen = new HashSet<string>();
            return string.Join("\n", lines.Select(S.Trimmed).Where(x => x.Length > 0 && seen.Add(x)).Take(12));
        }
        return new HonorsForm
        {
            Certificates = Pick(["certificates", "languages"], S.Strings(profile.Get("certifications"))),
            Awards = Pick(["awards"], S.Strings(profile.Get("honors"))),
        };
    }

    static List<string> HonorLines(string text)
    {
        var seen = new HashSet<string>();
        return S.SplitCharacters(text, "\n").Select(x => S.Trimmed(S.Replace(x, @"^[\s•·\-–—*]+", ""))).Where(x => x.Length > 0 && seen.Add(x)).Take(12).ToList();
    }

    /// <summary>模板只有其中一栏时两样都写进那一栏；都没有或都有时各写一栏。</summary>
    public static List<JsonNode?> HonorsOperations(HonorsForm form, ISet<string> templateKinds)
    {
        var certificates = HonorLines(form.Certificates);
        var awards = HonorLines(form.Awards);
        var hasCertificates = templateKinds.Contains("certificates");
        var hasAwards = templateKinds.Contains("awards");
        static JsonNode Op(string kind, List<string> lines) => new JsonObject { ["op"] = "replace_section", ["semantic_kind"] = kind, ["bullets"] = S.StringArray(lines) };
        if (hasCertificates != hasAwards)
        {
            var lines = hasAwards ? awards.Concat(certificates).ToList() : certificates.Concat(awards).ToList();
            return lines.Count == 0 ? [] : [Op(hasAwards ? "awards" : "certificates", lines)];
        }
        var result = new List<JsonNode?>();
        if (awards.Count > 0) result.Add(Op("awards", awards));
        if (certificates.Count > 0) result.Add(Op("certificates", certificates));
        return result;
    }

    // MARK: 收尾：记进求职画像与求职资料

    /// <summary>
    /// 简历里出现、画像里还没有的事实；列表字段只追加，单值字段只填空位。返回合并后的整份画像更新。
    /// 奖项块文字按节点 id 去重后追加；Swift 字典取值顺序不固定，这里按遍历时第一次出现的顺序（多个奖项块时顺序可能与 Mac 不同）。
    /// </summary>
    public static JsonNode? ProfileWrite(JsonNode? document, JsonNode? profile)
    {
        var changes = new Dictionary<string, JsonNode?>();
        List<string> List(string key) => S.Strings(profile.Get(key));
        bool Empty(string key) => (profile.Get(key).String() ?? "").Length == 0 && profile.Get(key).Number() is null;
        List<JsonNode?> Entries(string kind) => Sections(document).Where(x => x.Text("semantic_kind") == kind).SelectMany(x => S.Arr(x.Get("entries"))).ToList();
        var schools = Entries("education");
        if (schools.Count > 0)
        {
            var school = schools[0];
            string name = EntryName(school), major = FieldText(school, "major"), degree = FieldText(school, "degree");
            if (name.Length > 0 && Empty("school")) changes["school"] = name;
            if (major.Length > 0 && Empty("major")) changes["major"] = major;
            if (DegreeLevels.FirstOrDefault(x => Matches(x.Pattern, degree)).Level is { } level && Empty("education_level")) changes["education_level"] = level;
            if (S.Int(GraduationYearOnPaper(document)) is { } year && profile.Get("graduation_year").Number() is null)
                foreach (var (key, value) in GraduationChanges(profile, year)) changes[key] = value;
        }
        void Append(string key, IEnumerable<string> values)
        {
            var current = List(key);
            var added = values.Where(x => x.Length > 0 && !current.Contains(x)).ToList();
            if (added.Count == 0) return;
            var seen = new HashSet<string>();
            changes[key] = S.StringArray(current.Concat(added).Where(seen.Add).Take(50));
        }
        Append("skills", SkillsOnPaper(document).Select(x => x.Name));
        Append("certifications", SectionLines(document, "certificates"));
        var awardTexts = new Dictionary<string, string>();
        var awardSections = Sections(document).Where(x => x.Text("semantic_kind") == "awards").ToList();
        NodeTexts(S.Array(awardSections.Select(x => S.HasKey(x, "blocks") ? x.Get("blocks") : new JsonArray())), awardTexts);
        Append("honors", Entries("awards").Select(x => FieldText(x, "name")).Concat(awardTexts.Values.Select(S.Trimmed)));
        Append("campus_experiences", Entries("activity").Select(entry =>
            string.Join(" · ", new[] { EntryName(entry), S.NilIfBlank(FieldText(entry, "role")) ?? ReadEntry(entry).Detail }.Where(x => x.Length > 0))));
        return changes.Count == 0 ? null : ProfileUpdate(profile, changes);
    }

    /// <summary>简历抬头里有、求职资料还空着的联系方式；只填空位。</summary>
    public static Dictionary<string, string> CareerContactChanges(JsonNode? document, IReadOnlyDictionary<string, string> personal)
    {
        var changes = new Dictionary<string, string>();
        string Personal(string key) => personal.TryGetValue(key, out var value) ? value : "";
        var name = S.Trimmed(ResumeDocument.Value(document.Get("identity").Get("name")));
        if (name.Length > 0 && Personal("name").Length == 0) changes["name"] = S.Prefix(name, 60);
        string[] keys = ["phone", "email", "github", "website"];
        foreach (var contact in S.Arr(document.Get("identity").Get("contacts")))
        {
            var key = contact.Text("contact_kind");
            if (!keys.Contains(key)) continue;
            var value = S.Trimmed(contact.Text("value"));
            if (value.Length == 0 || Personal(key).Length > 0 || changes.ContainsKey(key)) continue;
            if (key == "website" && !Matches(@"^https?://\S+" + S.End, value)) continue;
            changes[key] = S.Prefix(value, 300);
        }
        return changes;
    }

    public static bool CareerHasExperience(JsonNode? career) => S.Arr(career.Get("experience").Get("sections")).Any(x => S.Arr(x.Get("entries")).Count > 0);

    public static Dictionary<string, string> Personal(JsonNode? career)
    {
        if (career.Get("personal") is not JsonObject fields) return [];
        var result = new Dictionary<string, string>();
        foreach (var (key, value) in fields) if (value.String() is { } text) result[key] = text;
        return result;
    }

    /// <summary>纸面上已经有用户自己的个人简介（不是模板示例）。</summary>
    public static bool ProfileWritten(JsonNode? document, ISet<string> samples) =>
        Sections(document).Any(section => section.Text("semantic_kind") == "profile" && !samples.Contains(section.Text("node_id"))
            && S.Arr(section.Get("blocks")).Any(x => !samples.Contains(x.Text("node_id"))));
}
