using System.Globalization;
using System.Text.Json.Nodes;
using DrawOffer.Core.Models;

namespace DrawOffer.Core.Models
{
    /// <summary>首页与模拟面试共用的练习焦点（Mac `PracticeFocus`）。</summary>
    public sealed record PracticeFocus(string Kind, string Ref, string Label)
    {
        /// <summary>只接受对象且 ref 非空；否则为 null。</summary>
        public static PracticeFocus? From(JsonNode? json) =>
            json is JsonObject && json.Text("ref").Length > 0 ? new PracticeFocus(json.Text("kind"), json.Text("ref"), json.Text("label")) : null;
    }
}

namespace DrawOffer.Core.Home
{
    /// <summary>
    /// 工作区首页（Mac `HomeGraph.swift`，Web `assistant/home/HomeMemory.tsx`）：读 `GET /api/memory/home/graph`，
    /// 按“有没有简历、练过几场、有没有结论”选 01 新用户 / 03 练第一场 / 07 有记忆三种首页。
    /// </summary>
    public sealed class HomeGraph
    {
        public enum Status { Top, Good, Ok, Weak, None }
        public enum Kind { Experience, Highlight, Technology, Point, Session }
        public enum Tone { Plain, Hot, New }

        public sealed record Node(string Id, Kind Kind, string Name, Status Status, bool Overstated, bool ChangedUp, double Size)
        {
            /// <summary>图上的分类（Web `stageNodeOf`）：橙色只给还不牢或写高了的，蓝色给刚练稳的；场次一律墨色。</summary>
            public Tone Tone => Kind == Kind.Session ? Tone.Plain : Status == Status.Weak || Overstated ? Tone.Hot : ChangedUp ? Tone.New : Tone.Plain;

            string Base => Name.Split('（')[0];
            public string Label => Kind == Kind.Highlight ? $"“{Base}”" : Base;

            /// <summary>首页右栏只画经历、技术和问到过的知识点；展开后全画。</summary>
            public bool OnHome => Kind is Kind.Experience or Kind.Technology || (Kind == Kind.Point && Status != Status.None);

            /// <summary>图上的短名：汉字算 2、字母数字算 1，经历放宽到 20，其余 16；经历放不下就只留公司。</summary>
            public string Short => Kind switch
            {
                Kind.Highlight => $"“{Clip(Base, 16)}”",
                Kind.Experience => Width(Base) <= 20 ? Base : Clip(Base.Split(" · ")[0], 16),
                Kind.Session => Clip(Base, 20),
                _ => Clip(Base, 16),
            };

            static IEnumerable<string> Elements(string s)
            {
                var e = StringInfo.GetTextElementEnumerator(s);
                while (e.MoveNext()) yield return e.GetTextElement();
            }
            static int Units(string c) => c.EnumerateRunes().All(r => r.Value < 0x250) ? 1 : 2;
            static int Width(string s) => Elements(s).Sum(Units);
            static string Clip(string s, int limit)
            {
                var used = 0;
                var output = new System.Text.StringBuilder();
                foreach (var c in Elements(s))
                {
                    used += Units(c);
                    if (used > limit) return output.ToString().Trim() + "…";
                    output.Append(c);
                }
                return s;
            }
        }

        public sealed record Edge(string Src, string Dst, string Kind);
        public sealed record Pick(string Key, string Name, int Experiences);

        public enum Source { Mock, Real, Resume }
        public enum ProgressTone { Up, Weak, Info }

        /// <summary>最近进展的一条（Web `HomeGraphProgress`）。</summary>
        public sealed record Progress(Source Kind, string Date, string Source, string SourceId, ProgressTone Tone, string? Name, string? Before, string? After,
            int Asked, int Missed, string? PracticeLabel, string? PracticeRef, string? PracticeKind);

        public sealed class Entries
        {
            public int InterviewCount, MockCount, ApplicationsOpen, ApplicationsAwaiting, JobsSaved, Datasets;
            public string? InterviewCompany, InterviewStage, InterviewStart;
            public double? MockLastScore;
        }

        public string? ResumeId { get; }
        public string ResumeTitle { get; }
        public IReadOnlyList<string> Topics { get; }
        public IReadOnlyList<Node> Nodes { get; }
        public IReadOnlyList<Edge> Edges { get; }
        public bool HasConclusions { get; }
        public int Points { get; }
        public int WeakPoints { get; }
        public Pick? Weakest { get; }
        public IReadOnlyList<Progress> Timeline { get; }
        public string Today { get; }
        public Entries? Entry { get; }
        public (int Resumes, int Mocks, int Interviews) Sources { get; }

        static int Int(JsonNode? value) => (int)(value.Number() ?? 0);
        static string? Opt(JsonNode? value) => value.String() is { Length: > 0 } text ? text : null;
        static T? Parse<T>(string raw) where T : struct, Enum =>
            raw.Length > 0 && Enum.TryParse<T>(raw, true, out var value) && Enum.IsDefined(value) ? value : null;

        public HomeGraph(JsonNode? json)
        {
            var resume = json?["resume"];
            ResumeId = Opt(resume?["id"]);
            ResumeTitle = resume.Text("title");
            // 练之前的面试纸先按经历出两道题：项目、工作、实习、校园依次取
            string[] order = ["project", "work", "internship", "campus"];
            Topics = json.Items("groups").Where(x => order.Contains(x.Text("kind")))
                .OrderBy(x => Array.IndexOf(order, x.Text("kind")))
                .SelectMany(x => x.Items("items")).Select(x => x.Text("title")).Where(x => x.Length > 0).ToList();
            Nodes = json?["graph"].Items("nodes").Select(item =>
                Parse<Kind>(item.Text("kind")) is { } kind && item.Text("key").Length > 0
                    ? new Node(item.Text("key"), kind, item.Text("name"), Parse<Status>(item.Text("status")) ?? Status.None,
                        item.Text("flag") == "overstated", item.Text("changed") == "up", item.Number("size") ?? 1)
                    : null).OfType<Node>().ToList() ?? [];
            Edges = json?["graph"].Items("edges").Select(x => new Edge(x.Text("src"), x.Text("dst"), x.Text("kind"))).ToList() ?? [];
            HasConclusions = json.Bool("has_conclusions");
            Points = Int(json?["points"]);
            WeakPoints = Int(json?["weak_points"]);
            Weakest = json?["weakest"] is JsonObject weakest && weakest.Text("key").Length > 0 ? new Pick(weakest.Text("key"), weakest.Text("name"), Int(weakest["experiences"])) : null;
            Timeline = json.Items("timeline").Select(item =>
            {
                if (Parse<Source>(item.Text("kind")) is not { } kind) return null;
                var practice = item["practice"];
                return new Progress(kind, item.Text("date"), item.Text("source"), item.Text("source_id"), Parse<ProgressTone>(item.Text("tone")) ?? ProgressTone.Info,
                    Opt(item["name"]), Opt(item["before"]), Opt(item["after"]), Int(item["asked"]), Int(item["missed"]),
                    Opt(practice?["label"]), Opt(practice?["ref"]), Opt(practice?["kind"]));
            }).OfType<Progress>().ToList();
            Today = json.Text("today");
            if (json?["entries"] is JsonObject value)
                Entry = new Entries
                {
                    InterviewCount = Int(value["interview"]?["count"]), InterviewCompany = Opt(value["interview"]?["company"]),
                    InterviewStage = Opt(value["interview"]?["stage"]), InterviewStart = Opt(value["interview"]?["start_at"]),
                    MockCount = Int(value["mock"]?["count"]), MockLastScore = value["mock"]?["last_score"].Number(),
                    ApplicationsOpen = Int(value["applications"]?["open"]), ApplicationsAwaiting = Int(value["applications"]?["awaiting_result"]),
                    JobsSaved = Int(value["jobs"]?["saved"]), Datasets = Int(value["datasets"]?["count"]),
                };
            Sources = (Int(json?["sources"]?["resumes"]), Int(json?["sources"]?["mocks"]), Int(json?["sources"]?["interviews"]));
        }
    }

    /// <summary>已经完成或正在出报告的模拟面试（Web `readMockProgress`）：不含放弃和准备失败的场次，最近的在前。</summary>
    public sealed class HomeMockProgress
    {
        public int Count { get; }
        public string? FirstId { get; }
        public string? FirstStatus { get; }
        public DateTimeOffset? FirstFinishedAt { get; }
        public bool None => Count == 0;

        public HomeMockProgress(JsonNode? json)
        {
            string[] counted = ["in_progress", "evaluating", "evaluation_failed", "completed"];
            var items = json.Items("items").Where(x => counted.Contains(x.Text("status"))).ToList();
            Count = items.Count;
            var first = items.Count == 1 ? items[0] : null;
            FirstId = first?.Text("id");
            FirstStatus = first?.Text("status");
            FirstFinishedAt = first is null ? null : HomeStage.ParseDate(first.Text("finished_at"));
        }
    }

    /// <summary>首页选哪一屏（Web `HomeMemory` + `pickFirstSteps`）。</summary>
    public static class HomeStage
    {
        public enum Screen { NewUser, FirstSteps, Feedback, ResumeOnly }
        public enum FirstSteps { Start, Ongoing, Evaluating, Failed, Report }

        /// <summary>只给这套首页上线之后才练完第一场的人看“第一份报告好了”。</summary>
        static readonly DateTimeOffset FirstReportSince = DateTimeOffset.Parse("2026-11-14T00:00:00+08:00", CultureInfo.InvariantCulture);

        public static (Screen Screen, FirstSteps Steps) Pick(HomeGraph graph, HomeMockProgress? mocks, bool reportSeen)
        {
            if (graph.ResumeId is null) return (Screen.NewUser, FirstSteps.Start);
            if (mocks is not null && Steps(mocks, graph.HasConclusions, reportSeen) is { } steps) return (Screen.FirstSteps, steps);
            if (graph.HasConclusions && graph.Nodes.Count > 0 && graph.Timeline.Count > 0) return (Screen.Feedback, FirstSteps.Start);
            return (Screen.ResumeOnly, FirstSteps.Start);
        }

        public static FirstSteps? Steps(HomeMockProgress mocks, bool hasConclusions, bool reportSeen)
        {
            if (mocks.None) return hasConclusions ? null : FirstSteps.Start;
            if (mocks.Count != 1) return null;
            FirstSteps? mode = mocks.FirstStatus switch
            {
                "in_progress" => FirstSteps.Ongoing,
                "evaluating" => FirstSteps.Evaluating,
                "evaluation_failed" => FirstSteps.Failed,
                "completed" => FirstSteps.Report,
                _ => null,
            };
            if (mode != FirstSteps.Report) return mode;
            if (mocks.FirstFinishedAt is not { } finished) return null;
            return reportSeen || finished < FirstReportSince ? null : FirstSteps.Report;
        }

        public static DateTimeOffset? ParseDate(string text) =>
            text.Length > 0 && DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date) ? date : null;
    }

    /// <summary>最近进展的文字（Web `progressText` / `whenOf`）。</summary>
    public static class HomeProgressText
    {
        /// <param name="Lines">两行标题，每行是（前、重点词、后）；重点词上色。</param>
        public sealed record Text(IReadOnlyList<(string Before, string Mark, string After)> Lines, bool Weak, string Short, string Desc);

        public static Text Of(HomeGraph.Progress item, int weakPoints)
        {
            var left = weakPoints > 0 ? $"还有 {weakPoints} 个不牢。" : "图上没有还不牢的了。";
            if (item.Kind == HomeGraph.Source.Resume)
                return new([("简历有更新", "", ""), ("", "图谱跟着重读了", "")], false, $"更新了《{item.Name ?? ""}》", "简历里写的技术和经历都已经记进图谱。" + left);
            if (item.Tone == HomeGraph.ProgressTone.Up && item.Name is { } name && item.After is { } after)
                return new([(name, "", ""), (item.Before is { } before ? $"从{before}练到了" : "这次答到了", after, "")], false,
                    item.Before is { } b ? $"{name}从{b}练到了{after}" : $"{name}答到了{after}", $"这一场问到 {item.Asked} 处。" + left);
            if (item.Tone == HomeGraph.ProgressTone.Weak && item.Name is { } weak)
                return new([(weak, "没答好", ""), ("已排进下一次练习", "", "")], true, $"{weak}没答好，已排进下一次练习", $"这一场问到 {item.Asked} 处，{item.Missed} 处没答好。");
            return new([($"这一场问到 {item.Asked} 处", "", ""), ("", "都记进了图谱", "")], false, $"问到 {item.Asked} 处，都记进了图谱", left);
        }

        /// <summary>相对今天：今天、昨天、几天前，一周以上写月-日。</summary>
        public static string When(string date, string today)
        {
            var head = date.Length >= 10 ? date[..10] : date;
            var monthDay = head.Length > 5 ? head[5..] : head;
            if (!DateOnly.TryParseExact(head, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var day)) return monthDay;
            var now = today.Length >= 10 && DateOnly.TryParseExact(today[..10], "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var t) ? t : Beijing.TodayDate;
            var days = now.DayNumber - day.DayNumber;
            if (days < 0) return monthDay;
            return days switch { 0 => "今天", 1 => "昨天", <= 7 => $"{days} 天前", _ => monthDay };
        }
    }

    /// <summary>
    /// 知识图谱的摆放：确定性的力导向（同一份数据每次摆得一样），坐标归一到 0…1，界面按区域大小换算。
    /// 桌面端首页只要静态摆好、点开放大，不做逐帧漂浮。
    /// </summary>
    public static class HomeGraphLayout
    {
        public static Dictionary<string, (double X, double Y)> Layout(IReadOnlyList<HomeGraph.Node> nodes, IReadOnlyList<HomeGraph.Edge> edges, int iterations = 320)
        {
            var result = new Dictionary<string, (double X, double Y)>();
            if (nodes.Count == 0) return result;
            var index = new Dictionary<string, int>();
            for (var i = 0; i < nodes.Count; i++) index.TryAdd(nodes[i].Id, i);
            var links = edges.Where(e => e.Kind != "EE" && index.ContainsKey(e.Src) && index.ContainsKey(e.Dst) && index[e.Src] != index[e.Dst])
                .Select(e => (A: index[e.Src], B: index[e.Dst])).ToList();
            var count = nodes.Count;
            // 起点：按序号放在螺旋上，确定且不重叠
            var x = new double[count];
            var y = new double[count];
            for (var i = 0; i < count; i++)
            {
                var angle = i * 2.399963;
                var radius = 0.08 + 0.42 * Math.Sqrt((i + 1.0) / (count + 1.0));
                x[i] = 0.5 + radius * Math.Cos(angle);
                y[i] = 0.5 + radius * Math.Sin(angle);
            }
            var k = 0.9 * Math.Sqrt(1.0 / count);
            var temperature = 0.1;
            for (var step = 0; step < iterations; step++)
            {
                var mx = new double[count];
                var my = new double[count];
                for (var i = 0; i < count; i++)
                    for (var j = i + 1; j < count; j++)
                    {
                        double dx = x[i] - x[j], dy = y[i] - y[j];
                        var distance = Math.Sqrt(dx * dx + dy * dy);
                        if (distance < 1e-4) { dx = 0.001 * (i - j); dy = 0.001; distance = 0.0015; }
                        var force = k * k / distance;
                        mx[i] += dx / distance * force; my[i] += dy / distance * force;
                        mx[j] -= dx / distance * force; my[j] -= dy / distance * force;
                    }
                foreach (var (a, b) in links)
                {
                    double dx = x[a] - x[b], dy = y[a] - y[b];
                    var distance = Math.Max(Math.Sqrt(dx * dx + dy * dy), 1e-4);
                    var force = distance * distance / k;
                    mx[a] -= dx / distance * force; my[a] -= dy / distance * force;
                    mx[b] += dx / distance * force; my[b] += dy / distance * force;
                }
                for (var i = 0; i < count; i++)
                {
                    // 轻微拉向中心，孤立节点不飞出去
                    mx[i] += (0.5 - x[i]) * 0.02; my[i] += (0.5 - y[i]) * 0.02;
                    var length = Math.Max(Math.Sqrt(mx[i] * mx[i] + my[i] * my[i]), 1e-9);
                    x[i] += mx[i] / length * Math.Min(length, temperature);
                    y[i] += my[i] / length * Math.Min(length, temperature);
                }
                temperature = Math.Max(0.002, temperature * 0.985);
            }
            // 归一到 0…1，留 6% 边距
            double minX = x.Min(), maxX = x.Max(), minY = y.Min(), maxY = y.Max();
            double spanX = Math.Max(maxX - minX, 1e-6), spanY = Math.Max(maxY - minY, 1e-6);
            for (var i = 0; i < count; i++)
                result[nodes[i].Id] = (0.06 + 0.88 * (x[i] - minX) / spanX, 0.06 + 0.88 * (y[i] - minY) / spanY);
            return result;
        }
    }
}
