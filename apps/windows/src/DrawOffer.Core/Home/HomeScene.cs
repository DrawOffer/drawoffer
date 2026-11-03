using System.Globalization;
using System.Text.Json.Nodes;
using DrawOffer.Core.Models;

namespace DrawOffer.Core.Models
{
    /// <summary>首页与模拟面试共用的练习焦点（Mac `HomeScene.swift` 的 `PracticeFocus`）。</summary>
    public sealed record PracticeFocus(string Kind, string Ref, string Label)
    {
        /// <summary>只接受对象且 ref 非空；否则为 null。</summary>
        public static PracticeFocus? From(JsonNode? json) =>
            json is JsonObject && json.Text("ref").Length > 0 ? new PracticeFocus(json.Text("kind"), json.Text("ref"), json.Text("label")) : null;
    }
}

namespace DrawOffer.Core.Home
{
    // 首页 · 哪里要提升：移植 Web `features/assistant/homeImprove/scene.ts`。
    // 按用户此刻的状态挑一种画面（起步、有资料没简历、经历、有简历没练过、备战/没打牢、回流、结论形成中），
    // 同样的输入得到同样的结论、清单、星图节点与时间轴。

    /// <summary>`GET /api/memory/home` 的记忆首页数据。</summary>
    public sealed class MemoryHome
    {
        public sealed record Ask(string Date, string Kind, string SourceID, string? Company, string? Stage);
        public sealed record Node(string Key, string Name, string? Grade, string? GradeLabel, int? Level, int? BestLevel, string? LastDate, IReadOnlyList<Ask> Asks);
        public sealed record Issue(string Key, string Kind, string Statement, string? Node, string Name, string? Experience, string? Element, string? Facet,
            string? Cause, string? Held, string? Date, PracticeFocus? Practice);
        public sealed record Link(string Key, string Name, string? Parent);
        public sealed record Edge(string Src, string Dst);
        public sealed record Tech(string Key, string Name, IReadOnlyList<string> Topics);
        public sealed record Gap(string? Facet, string? Element, string Issue);
        public sealed record Experience(string Key, string Title, bool Told, IReadOnlyList<Gap> Gaps, PracticeFocus? Practice);
        public sealed record Competency(string Key, string Name, string? Grade, string? GradeLabel, double Coverage);
        public sealed record Origin(string Kind, string? Company, string Title);

        public bool Enabled { get; }
        public bool? TargetComputing { get; }
        public IReadOnlyList<Node> Nodes { get; }
        public IReadOnlyList<Issue> Issues { get; }
        public IReadOnlyList<Link> Links { get; }
        public IReadOnlyList<Edge> Edges { get; }
        public IReadOnlyDictionary<string, IReadOnlyList<string>> Neighbors { get; }
        public IReadOnlyList<Tech> ResumeTechnologies { get; }
        public IReadOnlyList<Experience> Experiences { get; }
        public IReadOnlyList<Competency> Competencies { get; }
        public IReadOnlyList<string> Unasked { get; }
        public Origin? UnaskedFrom { get; }

        static string? Opt(JsonNode? value, string key) => value.Text(key).NonEmpty();
        /// <summary>Swift `Int(Double)` 向零取整。</summary>
        static int? Int(JsonNode? value, string key) => value.Number(key) is { } number ? (int)Math.Truncate(number) : null;
        static List<JsonNode?> Items(JsonNode? value, string key) => SwiftCompat.Arr(value.Get(key));

        public MemoryHome(JsonNode? json)
        {
            Enabled = json.Bool("enabled");
            TargetComputing = json.Get("target") is JsonObject target ? target.Bool("computing") : null;
            Nodes = Items(json, "nodes").Select(node => new Node(node.Text("key"), node.Text("name"), Opt(node, "grade"), Opt(node, "grade_label"),
                Int(node, "level"), Int(node, "best_level"), Opt(node, "last_date"),
                Items(node, "asks").Select(ask => new Ask(ask.Text("date"), ask.Text("kind"), ask.Text("source_id"), Opt(ask, "company"), Opt(ask, "stage"))).ToList())).ToList();
            Issues = Items(json, "issues").Select(issue => new Issue(issue.Text("key"), issue.Text("kind"), issue.Text("statement"), Opt(issue, "node"),
                issue.Text("name"), Opt(issue, "experience"), Opt(issue, "element"), Opt(issue, "facet"), Opt(issue, "cause"), Opt(issue, "held"), Opt(issue, "date"),
                PracticeFocus.From(issue.Get("practice")))).ToList();
            Links = Items(json, "links").Select(x => new Link(x.Text("key"), x.Text("name"), Opt(x, "parent"))).ToList();
            Edges = Items(json, "edges").Select(x => new Edge(x.Text("src"), x.Text("dst"))).ToList();
            var neighbors = new Dictionary<string, IReadOnlyList<string>>();
            if (json.Get("neighbors") is JsonObject map) foreach (var (key, value) in map) neighbors[key] = SwiftCompat.Strings(value);
            Neighbors = neighbors;
            ResumeTechnologies = Items(json, "resume_technologies").Select(x => new Tech(x.Text("key"), x.Text("name"), SwiftCompat.Strings(x.Get("topics")))).ToList();
            Experiences = Items(json, "experiences").Select(item => new Experience(item.Text("key"), item.Text("title"), item.Bool("told"),
                Items(item, "gaps").Select(x => new Gap(Opt(x, "facet"), Opt(x, "element"), x.Text("issue"))).ToList(), PracticeFocus.From(item.Get("practice")))).ToList();
            Competencies = Items(json, "competencies").Select(x => new Competency(x.Text("key"), x.Text("name"), Opt(x, "grade"), Opt(x, "grade_label"), x.Number("coverage") ?? 0)).ToList();
            Unasked = SwiftCompat.Strings(json.Get("unasked"));
            UnaskedFrom = json.Get("unasked_from") is JsonObject from ? new Origin(from.Text("kind"), Opt(from, "company"), from.Text("title")) : null;
        }
    }

    /// <summary>资料库里的一份文件（首页只认解析成功的文档）。</summary>
    public sealed class HomeDataset
    {
        public string Id { get; }
        public string FileName { get; }
        public DateTimeOffset CreatedAt { get; }
        public bool Document { get; }

        public HomeDataset(JsonNode? json)
        {
            Id = json.Display("id"); FileName = json.Text("file_name");
            CreatedAt = ResumeSummary.ParseTimestamp(json.Text("created_at")) ?? SwiftCompat.DistantPast;
            var kind = json.Text("asset_kind").Length == 0 ? "document" : json.Text("asset_kind");
            Document = kind == "document" && json.Text("upload_status") == "succeeded" && json.Text("parse_status") == "succeeded";
        }
    }

    /// <summary>面试日程里的一场。</summary>
    public sealed record HomeSession(string Id, string Status, DateTimeOffset StartAt, string Company, string StageLabel)
    {
        /// <summary>start_at 读不出时为 null；不带时区的时间按 `zone`（默认本机时区）读，与 Mac `CareerApplication.date` 一致。</summary>
        public static HomeSession? FromJson(JsonNode? json, TimeZoneInfo? zone = null) =>
            SwiftCompat.CareerDate(json.Text("start_at"), zone ?? TimeZoneInfo.Local) is { } start
                ? new HomeSession(json.Display("id"), json.Text("status"), start, json.Text("company_name"), json.Text("stage_label"))
                : null;
    }

    public sealed record HomeResume(string Id, string Title, string UpdatedAt);

    public enum HomeSym { Mastered, Weak, Pending, Untested, Due, Anchor, Topic, Planet }
    public enum HomeTone { Ink, Blue, Orange, Soft }

    /// <summary>星图节点。与 Swift 结构体相同，各字段可改。</summary>
    public sealed record HomeMapNode
    {
        public required string Id { get; init; }
        public HomeSym Sym { get; set; }
        public string Label { get; set; } = "";
        public string? Sub { get; set; }
        public HomeTone? SubTone { get; set; }
        public int? Level { get; set; }
        public int? Badge { get; set; }
        public string Group { get; set; } = "";
        public string? Parent { get; set; }
        public PracticeFocus? Focus { get; set; }
        public string? Ask { get; set; }
    }

    public sealed record HomeMapEdge(string From, string To, bool Prereq);
    public sealed record HomeRegion(IReadOnlyList<string> Members, string Title);
    public sealed record HomeListItem(string Id, HomeSym Sym, string Title, string? Right, string Sub, int? Badge, int? Level, PracticeFocus? Focus);

    /// <summary>首页按钮的动作：开一场模拟面试、发一句话、填进输入框、开写作引导。</summary>
    public abstract record HomeAction
    {
        public sealed record Mock(PracticeFocus? Focus) : HomeAction;
        public sealed record Chat(string Prompt) : HomeAction;
        public sealed record Suggest(string Text) : HomeAction;
        public sealed record Guide(IReadOnlyList<string> Ids) : HomeAction;
    }

    /// <summary>时间轴上的一个点；`At` 为 DateTimeOffset。</summary>
    public sealed record HomeMark(string Id, DateTimeOffset At, string Label, string? Sub, HomeTone Tone, bool Future);
    public sealed record HomePlanet(string Id, string Label, string Sub, HomeTone? SubTone, IReadOnlyList<string> Links, bool Near);
    /// <summary>Swift `action: (label, run, verb, hint)`。</summary>
    public sealed record HomeSceneAction(string Label, HomeAction Run, string? Verb, string? Hint);
    /// <summary>Swift `secondary: (label, run)`。</summary>
    public sealed record HomeSecondary(string Label, HomeAction Run);

    public sealed class HomeScene
    {
        public string Key { get; set; } = "";
        public string Eyebrow { get; set; } = "";
        public HomeTone EyebrowTone { get; set; } = HomeTone.Blue;
        public string Title { get; set; } = "";
        public string Sub { get; set; } = "";
        public string ListTitle { get; set; } = "";
        public List<HomeListItem> List { get; set; } = [];
        public HomeSceneAction? Action { get; set; }
        public HomeSecondary? Secondary { get; set; }
        public string MapTitle { get; set; } = "";
        public string MapNote { get; set; } = "";
        public List<HomeMapNode> Nodes { get; set; } = [];
        public List<HomeMapEdge> Edges { get; set; } = [];
        public List<HomePlanet> Planets { get; set; } = [];
        public HomeRegion? Region { get; set; }
        public List<(HomeSym Sym, string Label)> Legend { get; set; } = [];
        public List<HomeMark> Marks { get; set; } = [];
        public string Suggestion { get; set; } = "";
        public List<string> Disclose { get; set; } = [];
    }

    /// <summary>
    /// 画面输入。Swift 用 `Calendar.current` 换日、取星期；这里由 <see cref="Zone"/> 指定（默认本机时区）。
    /// </summary>
    public sealed class HomeInput(DateTimeOffset now, MemoryHome? home, IReadOnlyList<HomeResume> resumes, IReadOnlyList<HomeDataset> datasets,
        IReadOnlyList<HomeSession> sessions, IReadOnlyList<string> directions, string? targetRole)
    {
        public DateTimeOffset Now { get; set; } = now;
        public MemoryHome? Home { get; set; } = home;
        public IReadOnlyList<HomeResume> Resumes { get; set; } = resumes;
        public IReadOnlyList<HomeDataset> Datasets { get; set; } = datasets;
        public IReadOnlyList<HomeSession> Sessions { get; set; } = sessions;
        public IReadOnlyList<string> Directions { get; set; } = directions;
        public string? TargetRole { get; set; } = targetRole;
        public TimeZoneInfo Zone { get; set; } = TimeZoneInfo.Local;
    }

    public static class HomeScenes
    {
        public static readonly string[] LevelNames = ["了解", "熟悉", "掌握", "精通", "专家"];
        const double Day = 86_400;
        static readonly string[] Weekday = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
        static readonly Dictionary<string, string> CauseShort = new()
        {
            ["single"] = "相关的几点都答得不错，只差这一点", ["theme"] = "相关的几点也要一起补",
            ["prerequisite"] = "它依赖的基础还不稳，先补基础", ["shallow"] = "再往深追问时容易卡住", ["misconception"] = "有一处说法反复出现偏差",
        };
        static readonly (string Key, string Label)[] Facets = [("background", "背景"), ("task", "任务"), ("action", "行动"), ("result", "结果")];
        static readonly TimeZoneInfo China = TimeZoneInfo.FindSystemTimeZoneById("Asia/Shanghai");

        /// <summary>“10 · 31”（`zone` 默认本机时区，对应 Swift `Calendar.current`）。</summary>
        public static string Mmdd(DateTimeOffset date, TimeZoneInfo? zone = null)
        {
            var local = SwiftCompat.Local(date, zone ?? TimeZoneInfo.Local);
            return $"{local.Month} · {local.Day}";
        }

        /// <summary>Web `dateOf`：日期取当天中午（东八区），避免跨时区换日。</summary>
        internal static DateTimeOffset DateOf(string text)
        {
            var parts = SwiftCompat.SplitCharacters(SwiftCompat.Prefix(text, 10), "-").Select(SwiftCompat.Int).OfType<long>().ToList();
            if (parts.Count != 3) return SwiftCompat.DistantPast;
            return SwiftCompat.FromComponents(parts[0], parts[1], parts[2], 12, China) ?? SwiftCompat.DistantPast;
        }

        internal static int? LevelOf(string? held)
        {
            if (held is null) return null;
            var chars = SwiftCompat.Graphemes(held).ToList();
            if (chars.Count != 2 || chars[0] != "L" || SwiftCompat.Int(chars[1]) is not { } value || value is < 1 or > 5) return null;
            return (int)value;
        }

        internal static string LevelName(int? level) => level is { } value && value > 0 ? LevelNames[Math.Min(5, Math.Max(1, value)) - 1] : "";
        internal static int GoalOf(int? level) => Math.Min(5, Math.Max(3, (level ?? 2) + 1));
        internal static string NextName(int? level) => LevelNames[GoalOf(level) - 1];
        internal static string CountZh(int count) => count is >= 0 and <= 3 ? new[] { "", "一", "两", "三" }[count] : count.ToString(CultureInfo.InvariantCulture);
        static DateTimeOffset StartOfDay(DateTimeOffset date, HomeInput input) => SwiftCompat.StartOfDay(date, input.Zone);
        static int RoundDays(double seconds) => (int)SwiftCompat.Round(seconds / Day);

        internal static string WeekdayLabel(DateTimeOffset at, DateTimeOffset now, TimeZoneInfo zone)
        {
            var days = (int)SwiftCompat.Round(SwiftCompat.Since(SwiftCompat.StartOfDay(at, zone), SwiftCompat.StartOfDay(now, zone)) / Day);
            return days == 0 ? "今天" : days == 1 ? "明天" : days == 2 ? "后天" : Weekday[(int)SwiftCompat.Local(at, zone).DayOfWeek];
        }

        sealed class Tree
        {
            public readonly Dictionary<string, MemoryHome.Link> Links = new();
            readonly MemoryHome _home;
            public Tree(MemoryHome home)
            {
                _home = home;
                foreach (var link in home.Links) Links.TryAdd(link.Key, link);
            }
            public string Top(string key)
            {
                var at = key;
                for (var i = 0; i < 8; i++)
                {
                    if (!Links.TryGetValue(at, out var link) || link.Parent is not { } parent || !Links.ContainsKey(parent)) return at;
                    at = parent;
                }
                return at;
            }
            public string? Mid(string key)
            {
                string at = key, below = key;
                for (var i = 0; i < 8; i++)
                {
                    if (!Links.TryGetValue(at, out var link) || link.Parent is not { } parent || !Links.ContainsKey(parent)) return below == key ? null : below;
                    below = at; at = parent;
                }
                return null;
            }
            public string Name(string key) => Links.TryGetValue(key, out var link) ? link.Name : _home.Nodes.FirstOrDefault(x => x.Key == key)?.Name ?? key;
        }

        static (HomeSym, int) SymOf(MemoryHome.Node? node, IReadOnlyList<MemoryHome.Issue> issues)
        {
            var issue = node is null ? null : issues.FirstOrDefault(x => x.Node == node.Key && x.Kind != "unclear_telling");
            var level = node?.BestLevel ?? node?.Level ?? 0;
            if (issue?.Kind == "knowledge_gap") return (HomeSym.Weak, LevelOf(issue.Held) ?? node?.Level ?? 2);
            if (issue?.Kind == "review_due") return (HomeSym.Due, Math.Max(3, level));
            if (node is null) return (HomeSym.Untested, 0);
            return node.Grade is not null ? (HomeSym.Mastered, Math.Max(1, level == 0 ? 3 : level)) : (HomeSym.Pending, level);
        }

        static (string, HomeTone) SubOf(HomeSym sym, MemoryHome.Node? node, MemoryHome.Issue? issue)
        {
            switch (sym)
            {
                case HomeSym.Weak:
                    var held = LevelOf(issue?.Held) ?? node?.Level;
                    if (held is { } value && GoalOf(value) > value) return ($"{LevelName(value)} · 差 {GoalOf(value) - value} 级", HomeTone.Orange);
                    return ("还不稳定", HomeTone.Orange);
                case HomeSym.Due:
                    var name = LevelName(node?.BestLevel ?? node?.Level);
                    return ($"该复测 · 上次{(name.Length == 0 ? "答到了" : name)}", HomeTone.Blue);
                case HomeSym.Mastered:
                    var mastered = LevelName(node?.BestLevel ?? node?.Level);
                    return (mastered.Length == 0 ? node?.GradeLabel ?? "有结论" : mastered, HomeTone.Blue);
                case HomeSym.Pending: return ("答过一次 · 还说不准", HomeTone.Soft);
                default: return ("还没问过", HomeTone.Soft);
            }
        }

        /// <summary>
        /// 时间轴：近 45 天答过的场次（每个来源一个点，最多 4 个）与 21 天内的 2 场日程。
        /// Swift 从字典取值再按时间排序，同一时刻的先后在 Swift 里不确定；这里按第一次出现的顺序。
        /// </summary>
        static List<HomeMark> Marks(HomeInput input, ISet<string> weakKeys)
        {
            var seen = new Dictionary<string, HomeMark>();
            foreach (var node in input.Home?.Nodes ?? [])
            {
                foreach (var ask in node.Asks)
                {
                    var at = DateOf(ask.Date);
                    if (SwiftCompat.Since(input.Now, at) > 45 * Day) continue;
                    var tone = weakKeys.Contains(node.Key) ? HomeTone.Orange : seen.TryGetValue(ask.SourceID, out var previous) ? previous.Tone : HomeTone.Soft;
                    seen[ask.SourceID] = new HomeMark(ask.SourceID, at, Mmdd(at, input.Zone),
                        ask.Kind == "real" ? $"{ask.Company ?? ""}{ask.Stage ?? "面试"}" : "模拟面试", tone, false);
                }
            }
            var past = seen.Values.OrderByDescending(x => x.At).Take(4);
            var future = input.Sessions
                .Where(x => x.Status == "scheduled" && x.StartAt > input.Now && SwiftCompat.Since(x.StartAt, input.Now) < 21 * Day)
                .OrderBy(x => x.StartAt).Take(2)
                .Select(session =>
                {
                    var days = Math.Max(0, RoundDays(SwiftCompat.Since(StartOfDay(session.StartAt, input), StartOfDay(input.Now, input))));
                    return new HomeMark(session.Id, session.StartAt, $"{WeekdayLabel(session.StartAt, input.Now, input.Zone)} {session.Company}{session.StageLabel}",
                        days > 0 ? $"还有 {days} 天" : "就在今天", HomeTone.Blue, true);
                });
            return past.Concat(future).ToList();
        }

        static List<HomeMark> Uploads(HomeInput input, IReadOnlyList<HomeDataset> docs)
        {
            var days = new Dictionary<DateTimeOffset, int>();
            foreach (var doc in docs)
            {
                var at = StartOfDay(doc.CreatedAt, input);
                if (SwiftCompat.Since(input.Now, at) <= 45 * Day) days[at] = days.GetValueOrDefault(at) + 1;
            }
            return days.OrderByDescending(x => x.Key).Take(3).Select(x =>
                new HomeMark($"up:{SwiftCompat.DoubleText(SwiftCompat.Epoch(x.Key))}", x.Key, Mmdd(x.Key, input.Zone), $"上传 {x.Value} 份", HomeTone.Soft, false)).ToList();
        }

        static HomeSession? Upcoming(HomeInput input, double days) =>
            SwiftCompat.MinBy(input.Sessions.Where(x => x.Status == "scheduled" && x.StartAt > input.Now && SwiftCompat.Since(x.StartAt, input.Now) < days * Day),
                (a, b) => a.StartAt < b.StartAt);

        static DateTimeOffset LastPractice(MemoryHome home)
        {
            var dates = home.Nodes.SelectMany(x => x.Asks).Select(x => DateOf(x.Date)).ToList();
            return dates.Count == 0 ? DateTimeOffset.UnixEpoch : dates.Max();
        }

        static List<HomePlanet> ResumePlanet(HomeInput input, IReadOnlyList<string> links, string sub = "你的简历", HomeTone? tone = null)
        {
            if (SwiftCompat.MaxBy(input.Resumes, (a, b) => SwiftCompat.Cmp(a.UpdatedAt, b.UpdatedAt) < 0) is not { } resume) return [];
            return [new HomePlanet($"resume:{resume.Id}", resume.Title.Length == 0 ? "你的简历" : resume.Title, sub, tone, links, false)];
        }

        public static bool NonComputing(HomeInput input)
        {
            if (input.Home?.TargetComputing is { } computing) return !computing;
            return input.Directions.Count > 0 && input.Directions[0] != "rd";
        }

        public static HomeScene Pick(HomeInput input)
        {
            var scene = Choose(input);
            scene.MapNote = UnaskedNote(input.Home, scene.Nodes);
            return scene;
        }

        static string UnaskedNote(MemoryHome? home, IReadOnlyList<HomeMapNode> nodes)
        {
            if (home?.UnaskedFrom is not { } from || !nodes.Any(x => home.Unasked.Contains(x.Id))) return "";
            if (from.Kind == "direction") return $"还没问过的点：「{from.Title}」方向常问的要求";
            var title = SwiftCompat.Count(from.Title) > 18 ? SwiftCompat.Prefix(from.Title, 18) + "…" : from.Title;
            return $"还没问过的点来自{(from.Kind == "application" ? "投递" : "岗位")}：{(from.Company is { } company ? company + " · " : "")}{title}";
        }

        static HomeScene Choose(HomeInput input)
        {
            var docs = input.Datasets.Where(x => x.Document).ToList();
            if (input.Resumes.Count == 0) return docs.Count == 0 ? Start(input) : Materials(input, docs);
            if (input.Home is not { Enabled: true } home) return Experience(input);
            var weak = home.Issues.Where(x => x.Kind == "knowledge_gap" && x.Node is not null).ToList();
            var due = home.Issues.Where(x => x.Kind == "review_due" && x.Node is not null).ToList();
            if (home.Nodes.Count == 0 && weak.Count == 0)
                return !NonComputing(input) && home.ResumeTechnologies.Count > 0 ? ResumeScene(input) : Experience(input);
            var interview = Upcoming(input, 7);
            if (weak.Count > 0) return WeakScene(input, weak, interview);
            if (due.Count > 0 && SwiftCompat.Since(input.Now, LastPractice(home)) >= 14 * Day) return ReturnScene(input, due);
            var telling = home.Issues.Any(x => x.Kind == "unclear_telling");
            if (NonComputing(input) && telling && !home.Nodes.Any(x => x.Grade is not null)) return Experience(input);
            return Forming(input);
        }

        static readonly Dictionary<string, (string Role, string[] Points)> CategoryPoints = new()
        {
            ["rd"] = ("研发 / 技术", ["数据结构与算法", "数据库", "项目里的技术难点"]),
            ["product"] = ("产品", ["需求分析", "竞品分析", "数据指标"]),
            ["design"] = ("设计", ["作品集讲解", "设计思路", "用户研究"]),
            ["operations"] = ("运营", ["内容策划", "数据复盘", "用户增长"]),
            ["marketing"] = ("市场 / 销售", ["市场分析", "客户沟通", "目标拆解"]),
            ["functions"] = ("职能", ["专业基础", "流程与制度", "细节把控"]),
            ["finance"] = ("财务 / 审计", ["会计准则", "财务分析", "税务与内控"]),
            ["hr"] = ("人力资源", ["招聘与面试", "薪酬绩效", "劳动法规"]),
            ["admin"] = ("行政 / 文秘", ["公文写作", "会务与接待", "流程与制度"]),
            ["legal"] = ("法务", ["合同审查", "公司法务", "合规风控"]),
            ["manufacturing"] = ("生产 / 制造", ["工艺流程", "设备与安全", "问题排查"]),
            ["quality"] = ("质量", ["质量体系", "问题分析", "改进方法"]),
            ["supply_chain"] = ("供应链", ["采购与谈判", "库存与物流", "成本控制"]),
            ["banking"] = ("金融 / 银行证券", ["金融市场", "估值与财报", "风险管理"]),
            ["consulting"] = ("咨询", ["案例分析", "市场估算", "商业框架"]),
            ["healthcare"] = ("医药 / 医疗", ["医学基础", "药品与法规", "临床流程"]),
            ["media"] = ("新闻 / 编辑", ["选题策划", "写作与编辑", "新闻伦理"]),
            ["construction"] = ("建筑 / 土木", ["结构与材料", "施工管理", "造价与规范"]),
            ["electronics"] = ("电子 / 硬件", ["电路基础", "器件选型", "调试与测试"]),
            ["civil_service"] = ("公务员 / 事业单位", ["综合分析", "组织协调", "应急应变"]),
            ["teacher"] = ("教师招聘", ["试讲", "教学设计", "班级管理"]),
            ["postgraduate"] = ("考研复试", ["专业课", "科研经历", "英语口语"]),
        };

        static HomeMapNode NewNode(string id, HomeSym sym, string label, string group, string? parent = null, string? sub = null) =>
            new() { Id = id, Sym = sym, Label = label, Sub = sub, Group = group, Parent = parent };

        static List<HomeMapEdge> TreeEdges(IEnumerable<HomeMapNode> nodes) =>
            nodes.Where(x => x.Parent is not null).Select(x => new HomeMapEdge(x.Parent!, x.Id, false)).ToList();

        static void CategoryMap(HomeInput input, List<HomePlanet> planets, HomeScene scene)
        {
            var category = input.Directions.Count > 0 ? input.Directions[0] : null;
            string[]? points = category is not null && CategoryPoints.TryGetValue(category, out var found) ? found.Points : null;
            var role = input.TargetRole is { Length: > 0 } target ? target : category is not null && CategoryPoints.TryGetValue(category, out var known) ? known.Role : null;
            var nodes = new List<HomeMapNode> { NewNode("g:exp", HomeSym.Anchor, "你的经历", "g:exp", sub: "每段经历都会被追问") };
            nodes.AddRange(Facets.Select(x => NewNode($"g:exp:{x.Key}", HomeSym.Untested, x.Label, "g:exp", "g:exp")));
            nodes.Add(NewNode("g:cmp", HomeSym.Anchor, "通用能力", "g:cmp", sub: "各行业都会问"));
            nodes.AddRange(new[] { "沟通协作", "抗压", "学习能力", "主动性" }.Select((x, i) => NewNode($"g:cmp:{i}", HomeSym.Untested, x, "g:cmp", "g:cmp")));
            nodes.Add(NewNode("g:job", HomeSym.Anchor, "岗位相关", "g:job", sub: points is not null ? "这个方向常问" : "选好方向后出现"));
            nodes.AddRange((points ?? ["", "", ""]).Select((x, i) => NewNode($"g:job:{i}", HomeSym.Untested, x, "g:job", "g:job")));
            scene.Nodes = nodes;
            scene.Edges = TreeEdges(nodes);
            scene.Planets = planets;
            scene.Legend = [(HomeSym.Anchor, "类别"), (HomeSym.Untested, "还没问过"), (HomeSym.Mastered, "练后 · 答好了"), (HomeSym.Weak, "练后 · 没打牢")];
            scene.MapTitle = role is not null ? $"{role} · 面试常问的三类问题" : "面试常问的三类问题";
        }

        static HomeScene Start(HomeInput input)
        {
            var scene = new HomeScene { Key = "start" };
            CategoryMap(input, [new HomePlanet("next:resume", "你的简历", "第 2 步后出现", null, ["g:exp"], true)], scene);
            scene.Marks =
            [
                new HomeMark("next:resume", SwiftCompat.Adding(input.Now, 4 * Day), "第一份简历", "第 2 步", HomeTone.Blue, true),
                new HomeMark("next:mock", SwiftCompat.Adding(input.Now, 9 * Day), "第一场模拟面试", "第 3 步", HomeTone.Blue, true),
            ];
            return scene;
        }

        /// <summary>去掉最后一个“.”及其后的扩展名；“.”在开头时原样返回。</summary>
        internal static string Stem(string name)
        {
            int? dot = null;
            var e = StringInfo.GetTextElementEnumerator(name);
            while (e.MoveNext()) if ((string)e.Current == ".") dot = e.ElementIndex;
            return dot is { } index && index != 0 ? name[..index] : name;
        }

        static HomeScene Materials(HomeInput input, List<HomeDataset> docs)
        {
            var shown = docs.OrderByDescending(x => x.CreatedAt).Take(4).ToList();
            var scene = new HomeScene
            {
                Key = "materials",
                Eyebrow = "资料已整理",
                Title = $"{docs.Count} 份资料，够写出第一份简历",
                Sub = "我先读完它们，把能用的写进简历，缺的再一项项问你；之后练一场，就能看出哪里要补",
                ListTitle = "会用到的资料",
            };
            scene.List = shown.Select(x => new HomeListItem(x.Id, HomeSym.Planet, x.FileName, null, $"{Mmdd(x.CreatedAt, input.Zone)} 上传", null, null, null)).ToList();
            scene.Action = new HomeSceneAction("写第一份简历", new HomeAction.Guide(shown.Select(x => x.Id).ToList()), "开始", "读完资料先写上纸，缺的再问你");
            scene.Secondary = new HomeSecondary("或者先补一段经历", new HomeAction.Suggest("我想先补一段经历："));
            CategoryMap(input, shown.Select(x => new HomePlanet($"doc:{x.Id}", Stem(x.FileName), $"{Mmdd(x.CreatedAt, input.Zone)} 上传", null, [], false)).ToList(), scene);
            scene.Marks = Uploads(input, docs);
            scene.Marks.Add(new HomeMark("next:resume", SwiftCompat.Adding(input.Now, 2 * Day), "第一份简历", "跟着引导写", HomeTone.Blue, true));
            scene.Suggestion = shown.Count > 0 ? $"帮我把《{Stem(shown[0].FileName)}》写成一段经历" : "";
            return scene;
        }

        internal static string ShortName(string label, string top)
        {
            if (!SwiftCompat.HasPrefix(label, top)) return label;
            var trimmed = SwiftCompat.TrimWs(SwiftCompat.DropFirst(label, SwiftCompat.Count(top)));
            return trimmed.Length == 0 ? label : trimmed;
        }

        static HomeScene ResumeScene(HomeInput input)
        {
            var home = input.Home!;
            var tree = new Tree(home);
            var techs = home.ResumeTechnologies.Take(6).ToList();
            var nodes = new List<HomeMapNode>();
            for (var index = 0; index < techs.Count; index++)
            {
                var tech = techs[index];
                nodes.Add(NewNode(tech.Key, HomeSym.Anchor, tech.Name, tech.Key, sub: "简历写到"));
                var topics = tech.Topics.Take(index < 3 ? 2 : 1).ToList();
                for (var at = 0; at < topics.Count; at++)
                {
                    var topic = topics[at];
                    var likelyTopic = at == 0 && index < 3;
                    var item = NewNode(topic, HomeSym.Untested, ShortName(tree.Name(topic), tech.Name), tech.Key, tech.Key, likelyTopic ? "最可能被追问" : "还没问过");
                    item.SubTone = likelyTopic ? HomeTone.Ink : HomeTone.Soft;
                    item.Focus = new PracticeFocus("topic", topic, tree.Name(topic));
                    item.Ask = $"{tree.Name(topic)}面试官一般会怎么追问？";
                    nodes.Add(item);
                }
            }
            var likely = techs.Take(3).Where(x => x.Topics.Count > 0).Select(x => (Tech: x, Topic: x.Topics[0])).ToList();
            var scene = new HomeScene
            {
                Key = "resume",
                Eyebrow = "记忆还是空的",
                Title = $"简历上的 {techs.Count} 项技术，还没被检验",
                Sub = $"答过一次它们才会亮起来；先从最可能被追问的 {likely.Count} 处开始",
                ListTitle = "最可能被追问",
            };
            scene.List = likely.Select(x => new HomeListItem(x.Topic, HomeSym.Untested, tree.Name(x.Topic), null, $"简历写到 {x.Tech.Name}", null, null,
                new PracticeFocus("topic", x.Topic, tree.Name(x.Topic)))).ToList();
            scene.Action = new HomeSceneAction("来一场模拟面试，点亮第一批",
                new HomeAction.Mock(likely.Count > 0 ? new PracticeFocus("topic", likely[0].Topic, tree.Name(likely[0].Topic)) : null), null, null);
            scene.Nodes = nodes; scene.Edges = TreeEdges(nodes);
            scene.Planets = ResumePlanet(input, techs.Select(x => x.Key).ToList());
            scene.Legend = [(HomeSym.Planet, "你的简历"), (HomeSym.Anchor, "简历写的技术"), (HomeSym.Untested, "还没问过")];
            scene.Marks = Marks(input, new HashSet<string>());
            scene.Suggestion = likely.Count > 0 ? $"{tree.Name(likely[0].Topic)}面试官一般会怎么追问？" : "";
            return scene;
        }

        const string CompetencyGroup = "g:cmp";
        static bool IsCompetency(string key) => key.StartsWith("cmp:", StringComparison.Ordinal);

        static HomeMapNode CompetencyNode(MemoryHome home, string key, IReadOnlyList<MemoryHome.Issue> issues, IReadOnlyDictionary<string, int> badges)
        {
            var found = home.Competencies.FirstOrDefault(x => x.Key == key);
            var label = found?.Name ?? issues.FirstOrDefault(x => x.Node == key)?.Name ?? key;
            var issue = issues.FirstOrDefault(x => x.Node == key && x.Kind == "knowledge_gap");
            var sym = issue is not null ? HomeSym.Weak : found?.Grade is not null ? HomeSym.Mastered : (found?.Coverage ?? 0) > 0 ? HomeSym.Pending : HomeSym.Untested;
            var sub = issue is not null ? "还不够稳" : found?.GradeLabel ?? ((found?.Coverage ?? 0) > 0 ? "有过表现 · 还说不准" : "还没看出来");
            return new HomeMapNode
            {
                Id = key, Sym = sym, Label = label, Sub = sub,
                SubTone = issue is not null ? HomeTone.Orange : found?.Grade is not null ? HomeTone.Blue : HomeTone.Soft,
                Level = 3, Badge = badges.TryGetValue(key, out var badge) ? badge : null, Group = CompetencyGroup, Parent = CompetencyGroup,
                Focus = issue?.Practice, Ask = $"面试里怎么体现「{label}」？",
            };
        }

        static List<string> ExtraKeys(MemoryHome home, List<string> keys)
        {
            var competencies = home.Competencies.Where(item => item.Coverage > 0 || home.Issues.Any(x => x.Node == item.Key))
                .Select(x => x.Key).Where(x => !keys.Contains(x)).Take(3);
            var unasked = home.Unasked.Where(x => !keys.Contains(x)).Take(3);
            return keys.Concat(unasked).Concat(competencies).ToList();
        }

        static (List<HomeMapNode>, List<HomeMapEdge>) KnowledgeMap(MemoryHome home, List<string> keys, IReadOnlyList<MemoryHome.Issue> issues, IReadOnlyDictionary<string, int>? badges = null)
        {
            badges ??= new Dictionary<string, int>();
            var tree = new Tree(home);
            var nodeBy = new Dictionary<string, MemoryHome.Node>();
            foreach (var node in home.Nodes) nodeBy.TryAdd(node.Key, node);
            var nodes = new List<HomeMapNode>();
            var edges = new List<HomeMapEdge>();
            var has = new HashSet<string>();
            var selfSub = new Dictionary<string, (string, HomeTone)>();
            void Add(HomeMapNode item) { if (has.Add(item.Id)) nodes.Add(item); }
            foreach (var key in keys)
            {
                if (IsCompetency(key))
                {
                    Add(NewNode(CompetencyGroup, HomeSym.Anchor, "通用能力", CompetencyGroup));
                    Add(CompetencyNode(home, key, issues, badges));
                    edges.Add(new HomeMapEdge(CompetencyGroup, key, false));
                    continue;
                }
                var root = tree.Top(key);
                var atlas = nodeBy.GetValueOrDefault(key);
                var rootName = tree.Name(root);
                Add(NewNode(root, HomeSym.Anchor, rootName, root));
                if (root == key)
                {
                    var own = SymOf(atlas, issues);
                    selfSub[root] = SubOf(own.Item1, atlas, issues.FirstOrDefault(x => x.Node == key));
                    continue;
                }
                var parent = root;
                if (tree.Mid(key) is { } between && between != key)
                {
                    Add(NewNode(between, HomeSym.Topic, ShortName(tree.Name(between), rootName), root, root));
                    if (!edges.Any(x => x.To == between)) edges.Add(new HomeMapEdge(root, between, false));
                    parent = between;
                }
                var issue = issues.FirstOrDefault(x => x.Node == key);
                var (sym, level) = SymOf(atlas, issues);
                var (sub, tone) = SubOf(sym, atlas, issue);
                Add(new HomeMapNode
                {
                    Id = key, Sym = sym, Label = ShortName(tree.Name(key), rootName), Sub = sub, SubTone = tone, Level = level,
                    Badge = badges.TryGetValue(key, out var badge) ? badge : null, Group = root, Parent = parent,
                    Focus = new PracticeFocus("topic", key, tree.Name(key)), Ask = $"「{tree.Name(key)}」我上次答到哪了，怎么补？",
                });
                edges.Add(new HomeMapEdge(parent, key, false));
            }
            foreach (var edge in home.Edges)
                if (has.Contains(edge.Src) && has.Contains(edge.Dst)) edges.Add(new HomeMapEdge(edge.Src, edge.Dst, true));
            for (var index = 0; index < nodes.Count; index++)
            {
                if (nodes[index].Sym != HomeSym.Anchor) continue;
                var id = nodes[index].Id;
                var members = nodes.Where(x => x.Group == id && x.Sym != HomeSym.Anchor && x.Sym != HomeSym.Topic).ToList();
                var weak = members.Count(x => x.Sym == HomeSym.Weak);
                var pending = members.Count(x => x.Sym == HomeSym.Pending);
                var graded = members.Count(x => x.Sym is HomeSym.Mastered or HomeSym.Due);
                var untested = members.Count(x => x.Sym == HomeSym.Untested);
                if (members.Count == 0 && selfSub.TryGetValue(id, out var own)) { nodes[index].Sub = own.Item1; nodes[index].SubTone = own.Item2; continue; }
                nodes[index].Sub = weak > 0 ? $"{members.Count} 个点 · {weak} 处没打牢"
                    : pending > 0 ? $"{graded} 个有结论 · {pending} 个待定"
                    : untested == members.Count && members.Count > 0 ? $"{members.Count} 个点 · 还没问过"
                    : untested > 0 ? $"{graded} 个达到要求 · {untested} 个还没问过"
                    : members.Count > 0 ? $"{members.Count} 个点 · 都达到要求" : null;
                nodes[index].SubTone = weak > 0 ? HomeTone.Orange : HomeTone.Soft;
            }
            return (nodes, edges);
        }

        static List<string> PickKeys(MemoryHome home, List<string> first, int limit = 14)
        {
            var tree = new Tree(home);
            var keys = first.ToList();
            var roots = first.Select(tree.Top).ToHashSet();
            foreach (var node in home.Nodes)
            {
                if (keys.Count >= limit) break;
                var root = tree.Top(node.Key);
                if (keys.Contains(node.Key) || (!roots.Contains(root) && roots.Count >= 4)) continue;
                roots.Add(root); keys.Add(node.Key);
            }
            return keys;
        }

        static HomeScene WeakScene(HomeInput input, List<MemoryHome.Issue> weak, HomeSession? interview)
        {
            var home = input.Home!;
            var tree = new Tree(home);
            var shown = weak.Take(3).ToList();
            var firstNode = shown[0].Node!;
            var area = tree.Mid(firstNode) ?? tree.Top(firstNode);
            var neighbors = (home.Neighbors.GetValueOrDefault(firstNode) ?? []).Where(key => !shown.Any(x => x.Node == key)).ToList();
            var badges = new Dictionary<string, int>();
            for (var i = 0; i < shown.Count; i++) badges.TryAdd(shown[i].Node!, i + 1);
            var keys = ExtraKeys(home, PickKeys(home, shown.Select(x => x.Node!).Concat(neighbors).ToList()));
            var (nodes, edges) = KnowledgeMap(home, keys, home.Issues, badges);
            var regionMembers = nodes.Where(x => x.Id == area || (tree.Mid(x.Id) == area && x.Sym != HomeSym.Anchor)).Select(x => x.Id).ToList();
            var held = LevelOf(shown[0].Held);
            var scene = new HomeScene { Key = interview is not null ? "prep" : "weak" };
            scene.Eyebrow = interview is not null
                ? $"{WeekdayLabel(interview.StartAt, input.Now, input.Zone)}{interview.Company}{(interview.StageLabel.Length == 0 ? "面试" : interview.StageLabel)}前"
                : "先补这几处";
            scene.EyebrowTone = HomeTone.Orange;
            scene.Title = IsCompetency(firstNode) ? $"「{shown[0].Name}」还不够稳" : $"{tree.Name(area)}没打牢";
            scene.Sub = held is { } level ? $"最近几次都停在「{LevelName(level)}」，再往下追问就讲不出" : shown[0].Statement;
            scene.ListTitle = $"先补这{CountZh(shown.Count)}处";
            scene.List = shown.Select((item, index) =>
            {
                var itemLevel = LevelOf(item.Held) ?? home.Nodes.FirstOrDefault(x => x.Key == item.Node)?.Level;
                var sub = item.Cause is { } cause && CauseShort.TryGetValue(cause, out var shortCause) ? shortCause
                    : itemLevel is { } value ? $"追问到「{NextName(value)}」时讲不出" : "最近的练习里还不稳定";
                return new HomeListItem(item.Key, HomeSym.Weak, item.Name, itemLevel is { } l ? $"{LevelName(l)} → {NextName(l)}" : null, sub, index + 1, null, item.Practice);
            }).ToList();
            scene.Action = new HomeSceneAction("从 ① 开始练", new HomeAction.Mock(shown[0].Practice), null, null);
            scene.Nodes = nodes; scene.Edges = edges;
            scene.Region = regionMembers.Count > 1 ? new HomeRegion(regionMembers, $"没打牢 · {ShortName(tree.Name(area), tree.Name(tree.Top(area)))}") : null;
            scene.Planets = ResumePlanet(input, [firstNode]);
            scene.Legend = [(HomeSym.Mastered, "掌握"), (HomeSym.Weak, "没打牢"), (HomeSym.Untested, "没问过"), (HomeSym.Planet, "你的简历")];
            scene.Marks = Marks(input, weak.Select(x => x.Node).OfType<string>().ToHashSet());
            scene.Suggestion = neighbors.Count > 0 ? $"{shown[0].Name}和{tree.Name(neighbors[0])}有什么关系？" : $"{shown[0].Name}面试一般会怎么追问？";
            scene.Disclose = shown.Select(x => x.Key).ToList();
            return scene;
        }

        static HomeScene ReturnScene(HomeInput input, List<MemoryHome.Issue> due)
        {
            var home = input.Home!;
            var shown = due.Take(3).ToList();
            var (nodes, edges) = KnowledgeMap(home, ExtraKeys(home, PickKeys(home, shown.Select(x => x.Node!).ToList())), home.Issues);
            var days = RoundDays(SwiftCompat.Since(input.Now, LastPractice(home)));
            var recent = home.Nodes.Count(node => node.Grade is not null && node.LastDate is { } last && SwiftCompat.Since(input.Now, DateOf(last)) < 30 * Day);
            var scene = new HomeScene
            {
                Key = "return",
                Eyebrow = days >= 28 ? "一个月没练了" : "两周没练了",
                Title = $"{shown.Count} 个点该复测了",
                Sub = $"上次都答到了，隔久了容易忘{(recent > 0 ? $"；这个月一共亮起 {recent} 个点" : "")}",
                ListTitle = "该复测",
            };
            scene.List = shown.Select(item =>
            {
                var node = home.Nodes.FirstOrDefault(x => x.Key == item.Node);
                var name = LevelName(node?.BestLevel ?? node?.Level);
                return new HomeListItem(item.Key, HomeSym.Due, item.Name, null,
                    $"上次 {(item.Date is { } date ? Mmdd(DateOf(date), input.Zone) : "较早")} 答到「{(name.Length == 0 ? "掌握" : name)}」", null, null, item.Practice);
            }).ToList();
            scene.Action = new HomeSceneAction($"复测这 {shown.Count} 个点", new HomeAction.Mock(shown[0].Practice), null, null);
            scene.Nodes = nodes; scene.Edges = edges;
            scene.Planets = ResumePlanet(input, shown.Select(x => x.Node).OfType<string>().Take(2).ToList());
            scene.Legend = [(HomeSym.Mastered, "掌握（越大越深）"), (HomeSym.Due, "该复测"), (HomeSym.Planet, "你的简历")];
            scene.Marks = WithNext(input, Marks(input, new HashSet<string>()));
            scene.Suggestion = $"帮我出 3 道{shown[0].Name}的复测题";
            scene.Disclose = shown.Select(x => x.Key).ToList();
            return scene;
        }

        static List<HomeMark> WithNext(HomeInput input, List<HomeMark> found)
        {
            if (found.Any(x => x.Future)) return found;
            return [.. found, new HomeMark("next:none", SwiftCompat.Adding(input.Now, 8 * Day), "还没有下一场", "去面试日程加一场", HomeTone.Soft, true)];
        }

        static bool IsUnder(MemoryHome home, string key, string tech)
        {
            var links = new Tree(home).Links;
            string? at = key;
            for (var i = 0; i < 8; i++)
            {
                if (at is null) return false;
                if (at == tech) return true;
                at = links.TryGetValue(at, out var link) ? link.Parent : null;
            }
            return false;
        }

        static (List<HomeMapNode>, List<HomeMapEdge>, List<string>) WithResumeTechs(MemoryHome home, (List<HomeMapNode>, List<HomeMapEdge>) map)
        {
            var tree = new Tree(home);
            var nodes = map.Item1.ToList();
            var edges = map.Item2.ToList();
            var known = nodes.Select(x => x.Id).ToHashSet();
            var asked = home.Nodes.Select(x => x.Key).ToHashSet();
            var added = new List<string>();
            foreach (var tech in home.ResumeTechnologies)
            {
                var onMap = known.Contains(tech.Key);
                if (!onMap && home.Nodes.Any(x => IsUnder(home, x.Key, tech.Key))) continue;
                if (!onMap && added.Count >= 2) continue;
                var topics = tech.Topics.Where(x => !asked.Contains(x) && !known.Contains(x)).Take(onMap ? 2 : 1).ToList();
                if (!onMap)
                {
                    nodes.Add(NewNode(tech.Key, HomeSym.Anchor, tech.Name, tech.Key, sub: "简历写到"));
                    known.Add(tech.Key); added.Add(tech.Key);
                }
                foreach (var topic in topics)
                {
                    var item = NewNode(topic, HomeSym.Untested, ShortName(tree.Name(topic), tech.Name), tech.Key, tech.Key, "还没问过");
                    item.SubTone = HomeTone.Soft;
                    item.Focus = new PracticeFocus("topic", topic, tree.Name(topic));
                    item.Ask = $"{tree.Name(topic)}面试官一般会怎么追问？";
                    nodes.Add(item); known.Add(topic);
                    edges.Add(new HomeMapEdge(tech.Key, topic, false));
                }
            }
            return (nodes, edges, added);
        }

        static string Coverage(MemoryHome home)
        {
            var parts = new List<string>();
            var techs = home.ResumeTechnologies;
            if (techs.Count > 0) parts.Add($"简历技术问到 {techs.Count(tech => home.Nodes.Any(x => IsUnder(home, x.Key, tech.Key)))}/{techs.Count}");
            if (home.Experiences.Count > 0) parts.Add($"经历讲过 {home.Experiences.Count(x => x.Told)}/{home.Experiences.Count}");
            return string.Join(" · ", parts);
        }

        static HomeScene Forming(HomeInput input)
        {
            var home = input.Home!;
            var graded = home.Nodes.Where(x => x.Grade is not null).ToList();
            var pending = home.Nodes.Where(x => x.Grade is null).ToList();
            var due = home.Issues.Where(x => x.Kind == "review_due" && x.Node is not null).ToList();
            var answered = KnowledgeMap(home, ExtraKeys(home, PickKeys(home, pending.Take(4).Select(x => x.Key).ToList())), home.Issues);
            var (nodes, edges, techs) = WithResumeTechs(home, answered);
            var done = pending.Count == 0;
            var scene = new HomeScene
            {
                Key = "forming",
                Eyebrow = done ? "记忆已经成形" : "记忆正在形成",
                Title = done ? $"答过的 {home.Nodes.Count} 个知识点都有了结论" : $"答过 {home.Nodes.Count} 个知识点，{graded.Count} 个有了结论",
                Sub = done ? (due.Count > 0 ? $"{due.Count} 个点之后该复测；想更稳可以挑一处再往深练" : "都达到要求了；想更稳可以挑一处再往深练")
                    : $"另外 {pending.Count} 个只答过一次，还说不准；下一场会先把它们问清",
                ListTitle = done ? (due.Count > 0 ? "之后该复测" : "") : "下一场先问清",
            };
            scene.List = done
                ? due.Take(3).Select(x => new HomeListItem(x.Key, HomeSym.Due, x.Name, null, $"上次 {(x.Date is { } date ? Mmdd(DateOf(date), input.Zone) : "较早")} 问到", null, null, x.Practice)).ToList()
                : pending.Take(4).Select(node => new HomeListItem(node.Key, HomeSym.Pending, node.Name, null,
                    node.Level is { } level ? $"答到「{LevelName(level)}」，只答过一次" : "只答过一次", null, null,
                    new PracticeFocus("topic", node.Key, node.Name))).ToList();
            var focus = pending.Count > 0 ? new PracticeFocus("topic", pending[0].Key, pending[0].Name) : due.FirstOrDefault()?.Practice;
            scene.Action = new HomeSceneAction(done ? "再练一场，往深里问" : "再练一场，把它们问清", new HomeAction.Mock(focus), null, null);
            scene.Nodes = nodes; scene.Edges = edges;
            scene.MapTitle = Coverage(home);
            scene.Planets = ResumePlanet(input, pending.Take(1).Select(x => x.Key).Concat(techs).ToList());
            scene.Legend = [(HomeSym.Mastered, "有结论（越大越深）"), (HomeSym.Pending, "答过、还说不准"), (HomeSym.Untested, "没问过"), (HomeSym.Anchor, "技术"), (HomeSym.Planet, "你的简历")];
            scene.Marks = Marks(input, new HashSet<string>());
            scene.Suggestion = pending.Count > 0 ? $"我上次{pending[0].Name}答到哪了？" : graded.Count > 0 ? $"{graded[0].Name}还能往哪里深挖？" : "";
            scene.Disclose = done ? due.Take(3).Select(x => x.Key).ToList() : [];
            return scene;
        }

        static HomeScene Experience(HomeInput input)
        {
            var home = input.Home;
            var experiences = (home?.Experiences ?? []).Take(3).ToList();
            var scene = new HomeScene { Key = "experience" };
            if (experiences.Count == 0)
            {
                scene.Eyebrow = "记忆还是空的";
                scene.Title = "简历已经有了，还没在面试里讲过";
                scene.Sub = "练一场模拟面试，就能看出哪段经历讲得清、哪里要补";
                scene.Action = new HomeSceneAction("来一场模拟面试", new HomeAction.Mock(null), null, null);
                CategoryMap(input, ResumePlanet(input, ["g:exp"]), scene);
                scene.Marks = Marks(input, new HashSet<string>());
                scene.Suggestion = "我的简历里哪段经历最容易被追问？";
                return scene;
            }
            var telling = (home?.Issues ?? []).Where(x => x.Kind == "unclear_telling").ToList();
            var badges = new Dictionary<string, int>();
            var topTelling = telling.Take(3).ToList();
            for (var i = 0; i < topTelling.Count; i++) badges.TryAdd(topTelling[i].Key, i + 1);
            var nodes = new List<HomeMapNode>();
            foreach (var item in experiences)
            {
                var gaps = item.Gaps;
                var anchor = NewNode(item.Key, HomeSym.Anchor, item.Title, item.Key,
                    sub: gaps.Count > 0 ? $"{Facets.Length} 个要素 · 缺 {gaps.Count} 个" : item.Told ? "讲清楚了" : "还没练过");
                anchor.SubTone = gaps.Count == 0 ? HomeTone.Soft : HomeTone.Orange;
                anchor.Focus = item.Practice;
                nodes.Add(anchor);
                var list = Facets.ToArray();
                foreach (var gap in gaps)
                    if (gap.Facet is { } facet && !list.Any(x => x.Key == facet)) list[1] = (facet, gap.Element ?? facet);
                foreach (var (facet, label) in list)
                {
                    var gap = gaps.FirstOrDefault(x => x.Facet == facet);
                    nodes.Add(new HomeMapNode
                    {
                        Id = $"{item.Key}:{facet}", Sym = gap is not null ? HomeSym.Weak : item.Told ? HomeSym.Mastered : HomeSym.Untested,
                        Label = gap?.Element ?? label, Sub = gap is not null ? "还没讲清楚" : item.Told ? "讲清楚了" : "还没讲过",
                        SubTone = gap is not null ? HomeTone.Orange : item.Told ? HomeTone.Blue : HomeTone.Soft, Level = 3,
                        Badge = gap is not null && badges.TryGetValue(gap.Issue, out var badge) ? badge : null,
                        Group = item.Key, Parent = item.Key, Focus = item.Practice, Ask = $"{item.Title}的{gap?.Element ?? label}该怎么讲？",
                    });
                }
            }
            var first = telling.FirstOrDefault();
            var firstExp = experiences.FirstOrDefault(x => first is not null && x.Key == first.Experience);
            var untold = experiences.Where(x => !x.Told).ToList();
            var listed = topTelling.Select(x => new HomeListItem(x.Key, HomeSym.Weak, $"{x.Name} · {x.Element ?? ""}", null, x.Statement, null, null, x.Practice))
                .Concat(untold.Select(x => new HomeListItem(x.Key, HomeSym.Untested, x.Title, null, "还没练过怎么讲", null, null, x.Practice))).Take(3).ToList();
            if (first is not null) listed = listed.Select((x, i) => new HomeListItem(x.Id, x.Sym, x.Title, null, x.Sub, i + 1, null, x.Focus)).ToList();
            scene.Eyebrow = "你的经历记忆";
            scene.EyebrowTone = first is not null ? HomeTone.Orange : HomeTone.Blue;
            scene.Title = first is not null ? $"「{first.Name}」这段还讲不完整" : untold.Count > 0 ? $"{untold.Count} 段经历，还没在面试里讲过" : $"{experiences.Count} 段经历都讲清楚了";
            scene.Sub = first is not null ? $"面试官问到{first.Element ?? "细节"}时，还没讲清楚" : untold.Count > 0 ? "讲过一次就知道哪里要补" : "想更稳可以换个角度再讲一遍";
            scene.ListTitle = first is not null ? $"先补这{CountZh(listed.Count)}处" : untold.Count > 0 ? "还没讲过" : "";
            scene.List = listed;
            scene.Action = new HomeSceneAction(first is not null ? $"练讲「{first.Name}」" : "来一场模拟面试", new HomeAction.Mock(first?.Practice ?? untold.FirstOrDefault()?.Practice), null, null);
            scene.Nodes = nodes; scene.Edges = TreeEdges(nodes);
            scene.Region = firstExp is not null ? new HomeRegion(nodes.Where(x => x.Group == firstExp.Key).Select(x => x.Id).ToList(), $"讲不完整 · {firstExp.Title}") : null;
            scene.Planets = ResumePlanet(input, experiences.Select(x => x.Key).ToList());
            scene.Legend = [(HomeSym.Mastered, "讲清楚了"), (HomeSym.Weak, "缺了 / 偏弱"), (HomeSym.Untested, "没讲过"), (HomeSym.Planet, "你的简历")];
            scene.Marks = Marks(input, new HashSet<string>());
            scene.Suggestion = first is not null ? $"{first.Name}的{first.Element ?? "这段"}该怎么讲才有说服力？" : $"{experiences[0].Title}面试官会怎么追问？";
            scene.Disclose = topTelling.Select(x => x.Key).ToList();
            return scene;
        }
    }
}
