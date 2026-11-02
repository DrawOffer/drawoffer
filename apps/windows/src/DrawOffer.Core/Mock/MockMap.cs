using System.Globalization;
using System.Text.Json.Nodes;

namespace DrawOffer.Core.Models;

/// <summary>
/// 模拟面试 V2 的掌握程度图与地平线（Web `mock-interview/v2/geom.ts`、`pathModel.ts`、`experienceModel.ts`、
/// `homeModel.ts`、`sessionLayout.ts`）：画布按设计稿坐标排版（首页 1151 × 828，面试中 1368 × 828），再整体缩放。
/// </summary>
public static class MockMap
{
    public static readonly string[] Levels = ["了解", "熟悉", "掌握", "精通", "专家"];
    public static readonly double[] SectorAngles = [-120, -60, 0, 60, 120, 180];
    public const double HorizonRadius = 3000.0;

    public static string LevelName(double? level)
    {
        if (level is not { } value || !(value >= 1)) return "";
        return Levels[Math.Min(5, Math.Max(1, (int)Math.Round(value, MidpointRounding.AwayFromZero))) - 1];
    }

    // MARK: 几何

    public readonly record struct Geo(double Cx, double Cy, double K)
    {
        /// <summary>第 L 层圆环的中线（点画在这里）。</summary>
        public double ROf(double level) => K * (225 - 45 * (level - 1) - 22.5);
        /// <summary>第 L 层圆环的内沿（目标线画在这里）。</summary>
        public double RingOf(double level) => K * (225 - 45 * (level - 1) - 45);
        public (double X, double Y) P(double angle, double radius) =>
            (Cx + radius * Math.Cos(angle * Math.PI / 180), Cy + radius * Math.Sin(angle * Math.PI / 180));
    }

    /// <summary>地平线：半径 3000 的大圆弧，顶点在画布正中。</summary>
    public static Func<double, double> ArcY(double width, double top) =>
        x => top + HorizonRadius - Math.Sqrt(HorizonRadius * HorizonRadius - Math.Pow(x - width / 2, 2));

    // MARK: 图上的点

    public sealed record Point(string Id, string Name, string Sector, double Angle, double Level, int Ask,
        bool Job = false, double? Prev = null, bool Pending = false, double Offset = 0)
    {
        public string Id { get; set; } = Id;
        public string Name { get; set; } = Name;
        public string Sector { get; set; } = Sector;
        public double Angle { get; set; } = Angle;
        /// <summary>答到第几层；0 表示还没被问过（画在外圈虚线上）。</summary>
        public double Level { get; set; } = Level;
        /// <summary>被问概率 1 低 · 2 中 · 3 高。</summary>
        public int Ask { get; set; } = Ask;
        public bool Job { get; set; } = Job;
        public double? Prev { get; set; } = Prev;
        public bool Pending { get; set; } = Pending;
        public double Offset { get; set; } = Offset;
    }

    public sealed record Sector(string Name, double Angle);
    /// <summary>一场练习的提问路线：每道主问题从起问层走到追问停下的那层；Ok=false 是在那层没答上，null 是正在问。</summary>
    public sealed record PathStep(string Id, double From, double To, bool? Ok);
    public sealed record Placed(Point Point, double X, double Y);

    public static List<Placed> Place(Geo g, IEnumerable<Point> points) => points.Select(point =>
    {
        var radius = (point.Level == 0 ? 248 * g.K : g.ROf(point.Level)) + point.Offset * g.K;
        var p = g.P(point.Angle, radius);
        return new Placed(point, p.X, p.Y);
    }).ToList();

    // MARK: 提问路线（pathModel）

    public sealed record Round(JsonNode Main, List<JsonNode> Turns, string Topic, double From, double To, bool? Ok, bool Skipped, bool Intro);

    internal static double Depth(JsonNode question) => question.Number("depth_level") ?? 0;

    public static bool IsIntro(JsonNode? detail, JsonNode question) =>
        detail.Get("has_intro").Bool() && question.Text("kind") == "main" && (question.Number("plan_index") ?? -1) == 0;

    public static List<Round> Rounds(JsonNode? detail)
    {
        var questions = detail.Items("questions");
        static double Sequence(JsonNode q) => q.Number("sequence_no") ?? 0;
        var mains = questions.Where(x => x.Text("kind") == "main").OrderBy(Sequence).ToList();
        return mains.Select(main =>
        {
            var id = main.Display("id");
            var turns = new List<JsonNode> { main };
            turns.AddRange(questions.Where(x => x.Display("parent_id") == id && id.Length > 0).OrderBy(Sequence));
            var from = Math.Max(1, Depth(main) == 0 ? 1 : Depth(main));
            var deepest = turns.Select(x => Depth(x) == 0 ? from : Depth(x)).DefaultIfEmpty(from).Max();
            var evaluation = main.Get("evaluation");
            var hasEvaluation = evaluation is not null;
            var skipped = main.Text("answer_status") == "skipped";
            var pending = turns.Any(x => x.Text("answer_status") == "pending");
            var achieved = evaluation.Number("achieved_depth") ?? 0;
            var reached = hasEvaluation ? Math.Max(1, achieved == 0 ? 1 : achieved) : deepest;
            var probed = evaluation.Number("probed_depth") ?? deepest;
            bool? ok;
            if (pending && !hasEvaluation && detail.Text("status") == "in_progress") ok = null;
            else if (skipped) ok = false;
            else if (hasEvaluation) ok = evaluation.Text("depth_status") == "met" || reached >= probed;
            else ok = turns[^1].Text("answer_status") == "answered";
            var topic = main.Text("topic").Length == 0 ? MockText.Prefix(main.Text("content"), 8) : main.Text("topic");
            var to = Math.Max(from, hasEvaluation ? Math.Max(reached, ok == true ? reached : probed) : deepest);
            return new Round(main, turns, topic, from, to, ok, skipped, IsIntro(detail, main));
        }).ToList();
    }

    public sealed record Stats(List<Round> Rounds, int Follows, int Answered, int? Minutes);

    public static Stats StatsOf(JsonNode? detail)
    {
        var rounds = Rounds(detail).Where(x => !x.Intro).ToList();
        var follows = detail.Items("questions").Count(x => x.Text("kind") == "follow_up");
        var answered = rounds.Count(x => x.Main.Text("answer_status") == "answered");
        int? minutes = null;
        if (Json.Date(detail.Text("started_at")) is { } start && Json.Date(detail.Text("finished_at")) is { } end)
            minutes = Math.Max(1, (int)Math.Round((end - start).TotalSeconds / 60, MidpointRounding.AwayFromZero));
        return new Stats(rounds, follows, answered, minutes);
    }

    // MARK: 简历经历（experienceModel）

    private static readonly HashSet<string> SkipKinds = ["profile", "skills", "interests", "languages", "certificates"];
    private static readonly HashSet<string> NormDrop = MockText.Graphemes("「」“”\"'‘’，。,.、：:；;（）()·-—…~～").ToHashSet();

    internal static string Norm(string text) =>
        MockText.Lower(string.Concat(MockText.Graphemes(text).Where(c => !MockText.IsWhitespace(c) && !NormDrop.Contains(c))));

    internal static void Strings(JsonNode? value, List<string> output)
    {
        switch (value)
        {
            case JsonArray items:
                foreach (var item in items) Strings(item, output);
                break;
            case JsonObject obj:
                // 与 Web Object.entries 一致按插入顺序遍历做不到，这里按键名排序；只影响「第一条正文」的兜底名字。
                foreach (var key in obj.Select(x => x.Key).OrderBy(x => x, MockText.Order))
                {
                    var item = obj[key];
                    if (key == "value" && item.String() is { } text) output.Add(text);
                    else if (item is JsonObject) Strings(item, output);
                    else if (item is JsonArray) Strings(item, output);
                }
                break;
        }
    }

    internal static string ShortLabel(string text, int limit = 8)
    {
        var clean = MockText.CollapseWhitespace(text);
        return MockText.Count(clean) > limit ? MockText.Prefix(clean, limit) + "…" : clean;
    }

    internal static int Overlap(string anchor, string body)
    {
        if (anchor.Length == 0 || body.Length == 0) return 0;
        if (MockText.Contains(body, anchor)) return 1000;
        var size = anchor.Length < 16 ? 4 : 6;
        var hits = 0;
        for (var index = 0; index + size <= anchor.Length; index += 2)
            if (MockText.Contains(body, MockText.FromUtf16(anchor.AsSpan(index, size)))) hits++;
        return hits;
    }

    /// <summary>简历题出自哪段经历：在简历里找包含这句话（或重合最多）的那条经历，用公司 / 项目 / 论文名作扇区名。</summary>
    public static Func<string?, string?> ExperienceIndex(JsonNode? resume)
    {
        var items = new List<(string Label, string Body)>();
        foreach (var section in resume.Items("sections"))
        {
            if (SkipKinds.Contains(section.Text("semantic_kind"))) continue;
            foreach (var entry in section.Items("entries"))
            {
                var fields = entry.Get("fields");
                var field = fields.Get("organization").Text("value").NonEmpty() ?? fields.Get("name").Text("value").NonEmpty();
                string? label;
                if (field is not null && MockText.TrimSpaces(field).Length > 0) label = ShortLabel(field);
                else
                {
                    var first = new List<string>();
                    if (entry.Get("blocks") is { } blocks) Strings(blocks, first);
                    var title = section.Get("title") is { } t ? t.Text("value") : "";
                    var head = first.Count > 0 ? MockText.TrimSpaces(first[0]) : null;
                    label = head is { Length: > 0 } ? ShortLabel(head) : MockText.TrimSpaces(title).Length == 0 ? null : ShortLabel(title);
                }
                var texts = new List<string>();
                Strings(entry, texts);
                if (label is not null) items.Add((label, Norm(string.Concat(texts))));
            }
        }
        return anchor =>
        {
            var text = Norm(anchor ?? "");
            if (text.Length == 0 || items.Count == 0) return null;
            (string Label, int Score)? best = null;
            foreach (var item in items)
            {
                var score = Overlap(text, item.Body);
                if (score > (best?.Score ?? 0)) best = (item.Label, score);
            }
            return best?.Label;
        };
    }

    // MARK: 首页模型（homeModel）

    public static readonly Dictionary<string, double> DiffLevel = new() { ["junior"] = 2, ["intermediate"] = 3, ["senior"] = 4 };
    public static readonly Dictionary<string, string> DiffName = new() { ["junior"] = "初级", ["intermediate"] = "中级", ["senior"] = "高级" };
    public static readonly Dictionary<string, string> TypeNames = new() { ["technical"] = "专业面", ["project_deep_dive"] = "项目深挖", ["comprehensive"] = "综合面", ["hr"] = "HR 面" };
    public static string TypeName(JsonNode? item) => item.Text("type_label").NonEmpty() ?? TypeNames.GetValueOrDefault(item.Text("interview_type")) ?? "综合面";
    public static readonly Dictionary<string, string> VerdictName = new()
    {
        ["likely_pass"] = "达到目标", ["promising"] = "接近目标", ["at_risk"] = "还差一些", ["likely_fail"] = "差距较大", ["insufficient"] = "证据不足",
        ["meets"] = "达标", ["borderline"] = "接近达标", ["below"] = "未达标",
    };
    public enum Tone { Blue, Orange, Ink, Gray }
    public static Tone VerdictTone(string? level) => level switch
    {
        "likely_pass" or "meets" => Tone.Blue,
        "promising" or "borderline" => Tone.Orange,
        "insufficient" or null or "" => Tone.Gray,
        _ => Tone.Ink,
    };

    public const string ProjectSector = "项目经历";
    public const string ExpressSector = "表达";
    private static readonly HashSet<string> ExpressKinds = ["type_point", "competency"];
    private const int MaxPoints = 14;

    public sealed record Focus(string Kind, string Ref, string Label)
    {
        /// <summary>`Focus(json)`：没有 label 时为 null。</summary>
        public static Focus? From(JsonNode? json) =>
            json is null || json.Text("label").Length == 0 ? null : new Focus(json.Text("kind"), json.Text("ref"), json.Text("label"));
        public JsonNode Json => new JsonObject { ["kind"] = Kind, ["ref"] = Ref, ["label"] = Label };
    }

    public sealed class HomePoint
    {
        public required Point Point { get; set; }
        /// <summary>出处：知识点、简历说法或岗位要求。</summary>
        public required string Source { get; set; }
        public JsonNode? Node { get; set; }
        public JsonNode? Hook { get; set; }
        public Focus? Focus { get; set; }
        public List<string> FollowUps { get; set; } = [];
        internal HomePoint Copy() => new() { Point = Point with { }, Source = Source, Node = Node, Hook = Hook, Focus = Focus, FollowUps = FollowUps };
    }

    internal static int Ask(JsonNode node)
    {
        int real = node.Integer("real_count"), mock = node.Integer("mock_count");
        if (real >= 2 || real + mock >= 3) return 3;
        if (real >= 1 || mock >= 2) return 2;
        return 1;
    }
    internal static readonly Dictionary<string, int> Asked = new() { ["高"] = 3, ["中"] = 2, ["低"] = 1 };

    internal static List<double> Spread(double center, int count, double width = 48) =>
        Enumerable.Range(0, count).Select(i => center - width / 2 + width * (i + 0.5) / count).ToList();

    internal static string ShortName(string text, int limit = 10)
    {
        var clean = MockText.CollapseWhitespace(text);
        // Web 用 String.length（UTF-16）截断。
        return clean.Length > limit ? MockText.FromUtf16(clean.AsSpan(0, limit)) + "…" : clean;
    }

    /// <summary>扇区：问得最多的四个技术领域 + 项目经历 + 表达；其余领域并进「其他」。</summary>
    public static (List<Sector> Sectors, Func<JsonNode, string> SectorOf) Sectors(IReadOnlyList<JsonNode> nodes)
    {
        var tech = nodes.Where(x => !ExpressKinds.Contains(x.Text("kind")));
        var counts = new List<(string Domain, int Count)>();
        foreach (var node in tech)
        {
            var domain = node.Text("domain").NonEmpty() ?? "其他";
            var add = node.Integer("real_count") * 2 + node.Integer("mock_count") + 1;
            var index = counts.FindIndex(x => x.Domain == domain);
            if (index >= 0) counts[index] = (domain, counts[index].Count + add); else counts.Add((domain, add));
        }
        // 稳定排序：同分按出现先后（与 JS Array.sort 一致）。
        var ranked = counts.Select((x, i) => (x, i)).OrderByDescending(x => x.x.Count).ThenBy(x => x.i).Select(x => x.x.Domain).ToList();
        var named = ranked.Count > 4 ? ranked.Take(3).Append("其他").ToList() : ranked;
        while (named.Count < 4) named.Add("__empty_" + named.Count.ToString(CultureInfo.InvariantCulture));
        var all = named.Take(4).Concat([ProjectSector, ExpressSector]).ToList();
        var sectors = all.Select((name, i) => new Sector(name, SectorAngles[i])).ToList();
        string SectorOf(JsonNode node)
        {
            if (ExpressKinds.Contains(node.Text("kind"))) return ExpressSector;
            var domain = node.Text("domain").NonEmpty() ?? "其他";
            return named.Contains(domain) ? domain : "其他";
        }
        return (sectors, SectorOf);
    }

    public static (List<HomePoint> Points, List<Sector> Sectors) HomePoints(JsonNode? atlas, JsonNode? outline, JsonNode? match, string type)
    {
        var nodes = atlas.Get("enabled").Bool() ? atlas.Items("nodes") : [];
        var (sectors, sectorOf) = Sectors(nodes);
        var grouped = new Dictionary<string, List<HomePoint>>();
        void Push(string sector, HomePoint point)
        {
            var item = point.Copy();
            item.Point.Sector = sector;
            if (!grouped.TryGetValue(sector, out var list)) grouped[sector] = list = [];
            list.Add(item);
        }
        var known = new HashSet<string>();
        foreach (var node in nodes)
        {
            var level = node.Number("level") ?? 0;
            known.Add(node.Text("name")); known.Add(node.Text("key"));
            var prev = node.Number("previous_level");
            Push(sectorOf(node), new HomePoint
            {
                Point = new Point("n:" + node.Text("key"), ShortName(node.Text("name"), 10), "", 0, level, Ask(node),
                    Prev: prev is { } p && p > 0 && p < level ? p : null),
                Source = "atlas", Node = node, Focus = new Focus("topic", node.Text("key"), node.Text("name")),
            });
        }
        var hooks = outline.Get("enabled").Bool() ? outline.Items("hooks") : [];
        static (bool Untested, double Level) Held(JsonNode hook) =>
            (hook.Get("held").Text("status") == "untested", hook.Get("held").Number("level") ?? 0);
        if (type == "project_deep_dive")
        {
            foreach (var hook in hooks.Take(6))
            {
                var state = Held(hook);
                Push(ProjectSector, new HomePoint
                {
                    Point = new Point("h:" + hook.Display("id"), "「" + ShortName(hook.Text("text"), 9) + "」", "", 0,
                        state.Untested ? 0 : state.Level, Asked.GetValueOrDefault(hook.Text("asked"), 1)),
                    Source = "hook", Hook = hook, Focus = Focus.From(hook.Get("practice")),
                    FollowUps = hook.Items("follow_ups").Select(x => x.Text("question")).ToList(),
                });
            }
        }
        else
        {
            var order = new List<string>();
            var byExperience = new Dictionary<string, List<JsonNode>>();
            foreach (var hook in hooks)
            {
                var key = hook.Text("experience").NonEmpty() ?? hook.Text("text");
                if (!byExperience.TryGetValue(key, out var list)) { order.Add(key); byExperience[key] = list = []; }
                list.Add(hook);
            }
            foreach (var experience in order.Take(3))
            {
                var list = byExperience[experience];
                var tested = list.Where(x => !Held(x).Untested && Held(x).Level > 0).ToList();
                var level = tested.Count == 0 ? 0 : tested.Select(x => Held(x).Level).Min();
                var ask = list.Select(x => Asked.GetValueOrDefault(x.Text("asked"), 1)).DefaultIfEmpty(1).Max();
                var first = list.FirstOrDefault(x => Focus.From(x.Get("practice")) is not null) ?? list[0];
                Push(ProjectSector, new HomePoint
                {
                    Point = new Point("e:" + experience, ShortName(experience, 8), "", 0, level, ask),
                    Source = "hook", Hook = first, Focus = Focus.From(first.Get("practice")),
                    FollowUps = list.SelectMany(x => x.Items("follow_ups").Select(f => f.Text("question"))).ToList(),
                });
            }
        }
        if (match.Get("enabled").Bool() && match.Text("match_status") == "ready")
        {
            foreach (var requirement in match.Items("requirements"))
            {
                if (requirement.Text("group") == "qualification" || requirement.Get("interview").Text("status") != "insufficient") continue;
                var node = requirement.Items("nodes").FirstOrDefault();
                var name = node.Text("name").NonEmpty() ?? requirement.Get("interview").Items("skills").FirstOrDefault().Text("name").NonEmpty()
                    ?? ShortName(requirement.Text("text"), 8);
                if (name.Length == 0 || known.Contains(name) || (node is not null && known.Contains(node.Text("key")))) continue;
                known.Add(name);
                var sector = sectors.Take(4).FirstOrDefault(x => MockText.Contains(requirement.Text("text"), x.Name))?.Name ?? sectors[3].Name;
                var importance = requirement.Text("importance");
                Push(sector, new HomePoint
                {
                    Point = new Point("j:" + (requirement.Display("id").NonEmpty() ?? name), name, "", 0, 0,
                        importance is "must" or "high" ? 3 : 2, Job: true),
                    Source = "job", Focus = node is null ? null : new Focus("topic", node.Text("key"), node.Text("name")),
                });
            }
        }
        var points = new List<HomePoint>();
        var perSector = Math.Max(2, (int)Math.Ceiling(MaxPoints / 6.0));
        foreach (var sector in sectors)
        {
            var list = grouped.GetValueOrDefault(sector.Name) ?? [];
            var sorted = list.Select((x, i) => (x, i)).ToList();
            sorted.Sort((a, b) =>
            {
                var x = a.x.Point; var y = b.x.Point;
                if (x.Job != y.Job) return x.Job ? -1 : 1;
                if (x.Ask != y.Ask) return x.Ask > y.Ask ? -1 : 1;
                if (x.Level != y.Level) return x.Level < y.Level ? -1 : 1;
                return a.i.CompareTo(b.i);
            });
            var deep = type == "project_deep_dive" && sector.Name == ProjectSector;
            var shown = sorted.Select(x => x.x).Take(deep ? 6 : perSector).ToList();
            var angles = Spread(deep ? sector.Angle - 6 : sector.Angle, shown.Count, deep ? 104 : 48);
            for (var index = 0; index < shown.Count; index++)
            {
                var item = shown[index].Copy();
                item.Point.Angle = angles[index];
                item.Point.Offset = deep && item.Point.Level == 0 && index % 2 == 1 ? -22 : 0;
                points.Add(item);
            }
        }
        return (points, sectors);
    }

    /// <summary>先问的那一处：被问概率高、离目标差得最多的点；都答到了就交给「让面试官决定」。</summary>
    public static HomePoint? SuggestFocus(IReadOnlyList<HomePoint> points, double targetLevel)
    {
        var scored = new List<(HomePoint Item, double Score, int Index)>();
        for (var index = 0; index < points.Count; index++)
        {
            var item = points[index];
            if (item.Focus is null) continue;
            var point = item.Point;
            var gap = point.Level == 0 ? (point.Job ? targetLevel - 0.5 : 0) : Math.Max(0, targetLevel - point.Level);
            if (gap > 0) scored.Add((item, gap * 2 + point.Ask, index));
        }
        return scored.OrderByDescending(x => x.Score).ThenBy(x => x.Index).Select(x => x.Item).FirstOrDefault();
    }

    public enum SubTone { Orange, Blue, Mute }

    public static Dictionary<string, (string Text, SubTone Tone)> PointSubs(IReadOnlyList<HomePoint> points, double targetLevel, string? focusId)
    {
        var subs = new Dictionary<string, (string, SubTone)>();
        if (points.FirstOrDefault(x => x.Point.Id == focusId) is { } focus && focus.Point.Level > 0 && focus.Point.Level < targetLevel)
        {
            var real = Enumerable.Reverse(focus.Node.Items("asks")).FirstOrDefault(x => x.Text("kind") == "real" && (x.Number("depth") ?? -1) == focus.Point.Level);
            var where = real is null ? "" : real.Text("company") + real.Text("stage");
            subs[focus.Point.Id] = ($"{where}只答到「{LevelName(focus.Point.Level)}」· 差 {MockText.Int(targetLevel - focus.Point.Level)} 层", SubTone.Orange);
        }
        if (points.FirstOrDefault(x => x.Point.Job && x.Point.Level == 0 && x.Point.Id != focusId) is { } job) subs[job.Point.Id] = ("岗位要求有 · 还没被问过", SubTone.Orange);
        if (points.FirstOrDefault(x => x.Point.Prev is not null && x.Point.Ask == 3 && !subs.ContainsKey(x.Point.Id)) is { } progress)
        {
            var diff = MockText.Int(progress.Point.Level - (progress.Point.Prev ?? 0));
            subs[progress.Point.Id] = ("高频 · 比上次多答" + (diff > 1 ? $" {diff} " : "一") + "层", SubTone.Blue);
        }
        return subs;
    }

    // MARK: 下一场

    public enum TargetKind { Interview, Application, General }
    public sealed record Target(TargetKind Kind, JsonNode? Application, JsonNode? Session);

    internal static int StageRank(JsonNode application)
    {
        string[] order = ["screening", "assessment", "written_test", "ai_interview", "interview", "hr", "offer"];
        var type = application.Get("current_stage").Text("stage_type").NonEmpty() ?? application.Text("current_stage_type");
        return Math.Max(0, Array.IndexOf(order, type)) * 10 + application.Integer("current_round_no");
    }

    private static bool IsNull(JsonNode? node) => node is null;

    public static Target PickTarget(IReadOnlyList<JsonNode> applications, IReadOnlyList<JsonNode> sessions, DateTimeOffset now, string? chosen)
    {
        if (chosen == "general") return new Target(TargetKind.General, null, null);
        DateTimeOffset Date(string value) => Json.Date(value) ?? DateTimeOffset.MinValue;
        var active = applications.Where(x => x.Text("status") == "active" && IsNull(x.Get("archived_at")) && x.Text("lifecycle_status") != "terminated").ToList();
        var upcoming = sessions.Where(x => x.Text("status") == "scheduled" && Date(x.Text("end_at")) >= now).OrderBy(x => Date(x.Text("start_at"))).ToList();
        if (chosen is not null && (active.FirstOrDefault(x => x.Display("id") == chosen) ?? applications.FirstOrDefault(x => x.Display("id") == chosen)) is { } application)
        {
            var session = upcoming.FirstOrDefault(x => x.Display("application_id") == application.Display("id"));
            return new Target(session is null ? TargetKind.Application : TargetKind.Interview, application, session);
        }
        if (upcoming.FirstOrDefault(item => active.Any(x => x.Display("id") == item.Display("application_id"))) is { } next)
            return new Target(TargetKind.Interview, active.FirstOrDefault(x => x.Display("id") == next.Display("application_id")), next);
        var ranked = active.Where(x => !IsNull(x.Get("job_description_id"))).Select((x, i) => (x, i)).ToList();
        ranked.Sort((a, b) =>
        {
            int x = StageRank(a.x), y = StageRank(b.x);
            if (x != y) return x > y ? -1 : 1;
            string u = a.x.Text("updated_at"), v = b.x.Text("updated_at");
            return u != v ? (MockText.Less(v, u) ? -1 : 1) : a.i.CompareTo(b.i);
        });
        if (ranked.Count > 0) return new Target(TargetKind.Application, ranked[0].x, null);
        return new Target(TargetKind.General, null, null);
    }

    internal static readonly string[] Weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

    /// <summary>两个时刻在 `zone` 里相差的自然日数（Swift 传 Calendar，这里传时区）。</summary>
    public static int DayDiff(DateTimeOffset from, DateTimeOffset to, TimeZoneInfo? zone = null)
    {
        zone ??= Beijing.Zone;
        var a = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(from, zone).DateTime);
        var b = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(to, zone).DateTime);
        return b.DayNumber - a.DayNumber;
    }

    public static string RelativeDay(DateTimeOffset date, DateTimeOffset now, TimeZoneInfo? zone = null)
    {
        zone ??= Beijing.Zone;
        var diff = DayDiff(now, date, zone);
        var local = TimeZoneInfo.ConvertTime(date, zone);
        if (diff == 0) return local.Hour >= 18 ? "今晚" : "今天";
        if (diff == 1) return "明天";
        if (diff > 1 && diff < 7) return Weekdays[(int)local.DayOfWeek];
        return local.Month.ToString(CultureInfo.InvariantCulture) + "·" + local.Day.ToString("00", CultureInfo.InvariantCulture);
    }

    public static string Hhmm(DateTimeOffset date, TimeZoneInfo? zone = null)
    {
        var local = TimeZoneInfo.ConvertTime(date, zone ?? Beijing.Zone);
        return local.Hour.ToString("00", CultureInfo.InvariantCulture) + ":" + local.Minute.ToString("00", CultureInfo.InvariantCulture);
    }

    public static string MmddDot(DateTimeOffset date, TimeZoneInfo? zone = null)
    {
        var local = TimeZoneInfo.ConvertTime(date, zone ?? Beijing.Zone);
        return local.Month.ToString("00", CultureInfo.InvariantCulture) + "·" + local.Day.ToString("00", CultureInfo.InvariantCulture);
    }
    public static string MmddDot(string value, TimeZoneInfo? zone = null) => Json.Date(value) is { } date ? MmddDot(date, zone) : "";

    public enum ChainTone { Done, Now, Todo }
    public sealed record ChainItem(string Label, ChainTone Tone, bool Check = false)
    {
        public string Label { get; set; } = Label;
        public ChainTone Tone { get; set; } = Tone;
    }

    /// <summary>投递 — 笔试 — 一面 — 二面 · 周五 — HR — Offer：走过的墨黑，当前一步蓝色，后面灰色。</summary>
    public static List<ChainItem> StageChain(JsonNode? application, JsonNode? session, DateTimeOffset now, TimeZoneInfo? zone = null)
    {
        if (application is null) return [];
        var stages = application.Items("stages").Where(x => x.Text("stage_status") != "cancelled").OrderBy(x => x.Number("sequence_no") ?? 0).ToList();
        var items = new List<ChainItem> { new("投递", ChainTone.Done) };
        var currentId = application.Get("current_stage") is { } current ? current.Display("id") : "";
        for (var index = 0; index < stages.Count; index++)
        {
            var stage = stages[index];
            if (stage.Text("stage_type") == "screening") continue;
            var isCurrent = !IsNull(stage.Get("current_marker")) || (currentId.Length > 0 && stage.Display("id") == currentId);
            items.Add(new ChainItem(stage.Text("stage_label"), isCurrent ? ChainTone.Now : ChainTone.Done,
                !isCurrent && stage.Text("stage_result") == "passed" && index == stages.Count - 1));
        }
        if (session is not null)
        {
            var label = session.Text("stage_label").NonEmpty() ?? application.Text("current_stage_label");
            var when = RelativeDay(Json.Date(session.Text("start_at")) ?? now, now, zone);
            if (items[^1].Label == label) { items[^1].Label = $"{label} · {when}"; items[^1].Tone = ChainTone.Now; }
            else
            {
                foreach (var item in items) if (item.Tone == ChainTone.Now) item.Tone = ChainTone.Done;
                items.Add(new ChainItem($"{label} · {when}", ChainTone.Now));
            }
        }
        else if (!items.Any(x => x.Tone == ChainTone.Now) && items.Count > 1) items[^1].Tone = ChainTone.Now;
        var reached = string.Join(" ", items.Select(x => x.Label));
        if (!reached.Contains("HR", StringComparison.OrdinalIgnoreCase)) items.Add(new ChainItem("HR", ChainTone.Todo));
        if (!reached.Contains("Offer", StringComparison.OrdinalIgnoreCase)) items.Add(new ChainItem("Offer", ChainTone.Todo));
        return items;
    }

    // MARK: 地平线

    public sealed record HorizonSession(string Id, double X, string Date, int? Score, string? Level, bool Mine, string Title, int? Delta, string Detail);
    public sealed record Interview(double X, string Title, string? Sub, bool SubGray, bool Dash);
    public sealed record Horizon(List<HorizonSession> Sessions, double Today, List<(double X, string Label)> Days, Interview? Interview, (string Title, string? Sub) Past);

    public const double TodayX = 520.0;
    public const double HomeHorizonTop = 668.0;

    private static string FinishedKey(JsonNode x) => x.Text("finished_at").NonEmpty() ?? x.Text("created_at");

    public static Horizon HorizonOf(IReadOnlyList<JsonNode> list, Target target, string difficulty, DateTimeOffset now, TimeZoneInfo? zone = null)
    {
        zone ??= Beijing.Zone;
        var all = list.Where(x => x.Text("status") is "completed" or "abandoned").OrderBy(FinishedKey, MockText.Order).ToList();
        var finished = all.Skip(Math.Max(0, all.Count - 7)).ToList();
        var lastScore = new Dictionary<string, int>();
        var sessions = finished.Select((item, index) =>
        {
            var app = item.Display("job_application_id");
            var mine = target.Kind == TargetKind.General ? app.Length == 0 && item.Text("difficulty") == difficulty
                : target.Application is { } application && app == application.Display("id") && item.Text("difficulty") == difficulty;
            int? score = item.Text("status") == "completed" && item.Number("total_score") is { } s ? (int)Math.Round(s, MidpointRounding.AwayFromZero) : null;
            var group = (app.Length == 0 ? "general" : app) + ":" + item.Text("difficulty");
            int? previous = lastScore.TryGetValue(group, out var last) ? last : null;
            if (score is { } value) lastScore[group] = value;
            var date = MmddDot(FinishedKey(item), zone);
            var count = item.Integer("question_count");
            return new HorizonSession(item.Text("id"), TodayX - 80 - (finished.Count - 1 - index) * 58.0, date, score,
                item.Text("verdict").NonEmpty(), mine,
                string.Join(" · ", date, item.Text("company_name").NonEmpty() ?? "通用练习", TypeName(item), DiffName.GetValueOrDefault(item.Text("difficulty")) ?? ""),
                score is not null && previous is not null ? score - previous : null,
                score is null ? $"{count} 题 · 中途放弃，没有报告" : $"{count} 题");
        }).ToList();
        var practiced = list.Count(x => x.Text("status") is "completed" or "abandoned");
        var latest = Enumerable.Reverse(sessions).FirstOrDefault(x => x.Score is not null);
        (string, string?) past = practiced == 0 ? ("还没练过", "练过的每一场会排在这条线上")
            : ($"练过 {practiced} 场", latest is null ? "还没有完成的场次"
                : $"最近 {latest.Score} 分" + (latest.Delta is { } delta ? $" · 比上一场同岗位 {(delta >= 0 ? "+" : "")}{delta}" : ""));
        var days = new List<(double, string)>();
        Interview? interview = null;
        if (target.Session is { } session && Json.Date(session.Text("start_at")) is { } start)
        {
            var diff = Math.Max(0, DayDiff(now, start, zone));
            var x = Math.Min(1040, 760 + Math.Max(0, diff - 1) * 150.0);
            var day = 1;
            while (day < diff && 760 + (day - 1) * 150.0 < x)
            {
                var date = AddDays(now, day, zone);
                days.Add((760 + (day - 1) * 150.0, Weekdays[(int)TimeZoneInfo.ConvertTime(date, zone).DayOfWeek]));
                day++;
            }
            var label = session.Text("stage_label").NonEmpty() ?? target.Application.Text("current_stage_label").NonEmpty() ?? "面试";
            interview = new Interview(diff == 0 ? 760 : x, $"{RelativeDay(start, now, zone)}  {label}", diff == 0 ? $"{Hhmm(start, zone)} 开始" : $"还有 {diff} 天", false, false);
        }
        else if (target.Kind == TargetKind.Application)
            interview = new Interview(910, "还没安排面试", "在面试日程里加上时间后会显示在这里", true, true);
        return new Horizon(sessions, TodayX, days, interview, past);
    }

    /// <summary>`Calendar.date(byAdding: .day)`：日历日加 N，保留当地钟点。</summary>
    private static DateTimeOffset AddDays(DateTimeOffset now, int days, TimeZoneInfo zone)
    {
        return SwiftCalendar.AddDays(now, days, zone);
    }

    public static List<JsonNode> TrackLine(IReadOnlyList<JsonNode> list, Target target, string difficulty) =>
        list.Where(item =>
        {
            if (item.Text("status") != "completed" || item.Number("total_score") is null || item.Text("difficulty") != difficulty) return false;
            var app = item.Display("job_application_id");
            return target.Kind == TargetKind.General ? app.Length == 0 : app == (target.Application?.Display("id") ?? "");
        }).OrderBy(FinishedKey, MockText.Order).ToList();

    public static string CompanyName(Target target) =>
        target.Application.Text("company_name_snapshot").NonEmpty() ?? (target.Session is { } session ? session.Text("company_name") : "");

    /// <summary>地平线上分数越高竖杆越高；低于 45 分的按 45 算。</summary>
    public static double HomeScoreY(Func<double, double> arcY, double x, int score) =>
        arcY(x) - 30 - (Math.Max(45, Math.Min(100, score)) - 50.0) * 2.1;
    public static List<double> SlotXs(int count) => Enumerable.Range(0, Math.Max(0, count)).Select(i => 590 + i * 28.0).ToList();

    /// <summary>积分说明（后端 billing.service.mock_question_price）。</summary>
    public static string? Credits(JsonNode? text, JsonNode? voice, int count)
    {
        static double? Unit(JsonNode? price) => price.Number("unitPoints") ?? (price.Get("unitPoints").String() is { } s ? MockText.SwiftDouble(s) : null);
        static string Mode(JsonNode? price) => price is null ? "" : price.Text("priceMode");
        static string Trim(double value)
        {
            var rounded = Math.Round(value * 100, MidpointRounding.AwayFromZero) / 100;
            return rounded == Math.Round(rounded, MidpointRounding.AwayFromZero) ? MockText.Int(rounded).ToString(CultureInfo.InvariantCulture) : MockText.SwiftString(rounded);
        }
        if (Mode(text) == "fixed" && Unit(text) is { } textUnit)
        {
            if (Mode(voice) == "free") return "本次免费";
            var each = Mode(voice) == "fixed" ? Unit(voice) ?? textUnit : textUnit;
            return $"{Trim(each * count)} 积分（每题 {Trim(each)}）";
        }
        if (Mode(text) == "free") return "本次免费";
        if (Mode(text) == "usage") return "按实际用量计积分";
        return null;
    }
}
