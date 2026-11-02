using System.Text.Json.Nodes;

namespace DrawOffer.Core.Models;

/// <summary>按 Mac MockReview 转成统一复盘结构；本地仅解释报告，不重新评分。</summary>
public static class MockReview
{
    public enum Outcome { Reached, OneShort, Missed, Unrecorded }
    public sealed record Question(string Id, int No, string Title, Outcome Outcome, bool Layered, double? Level, double Expected, int? Score, int Follows, string Sector, string Ask, string? Answer, string? Better, string? Miss, string? Note, bool FollowUp, int? ParentNo);
    public sealed record Dimension(string Key, string Label, bool Assessed, int? Steps, int? Score, int Max, double? Average, int AverageCount, (string Text, string Tone)? Comparison, string? Comment, string? Evidence, int? EvidenceNo, string? OffReason)
    {
        // Mac 的自定义 Equatable 只比较这四项。
        public bool Equals(Dimension? other) => other is not null && Key == other.Key && Score == other.Score && Assessed == other.Assessed && Steps == other.Steps;
        public override int GetHashCode() => HashCode.Combine(Key, Score, Assessed, Steps);
    }
    public sealed record Action(string Title, string? Detail, bool Key, List<int> Refs, string Kind, bool Done);
    public sealed record Stat(string Value, string Label, bool Orange);
    public sealed record View(string Title, string Sub, int? Score, (string Text, MockMap.Tone Tone)? Verdict, string Headline, string Summary, List<Stat> Stats, List<Question> Questions, double Target, string TargetLabel, List<Dimension> Dimensions, int PastCount, List<Action> Actions);
    public sealed record Row(MockMap.Round Round, JsonNode? Evaluation, int No);
    public static readonly Dictionary<string, string> DimensionLabels = new(MockInterview.Dimensions)
    {
        ["structured_thinking"] = "结构化思考", ["analysis"] = "分析判断", ["planning"] = "计划组织协调", ["resilience"] = "应变与抗压", ["collaboration"] = "协作与影响", ["learning"] = "学习能力", ["professionalism"] = "职业素养"
    };
    public static string LevelLabel(double level) => MockMap.Levels[Math.Clamp((int)level - 1, 0, 4)];
    public static List<Row> Rows(JsonNode? detail, JsonNode? report) => MockMap.Rounds(detail).Where(r => !r.Intro).Select((round, index) =>
    {
        var sequence = round.Main.Number("sequence_no"); var found = report.Items("questions").FirstOrDefault(q => q.Number("sequence_no") == sequence); JsonNode? evaluation = found;
        if (found is JsonObject obj && round.Main.Get("evaluation") is JsonObject latest)
        {
            var merged = (JsonObject)obj.DeepClone(); foreach (var (key, value) in latest) if (key is not "topic" and not "sequence_no") merged[key] = value?.DeepClone(); evaluation = merged;
        }
        return new Row(round, evaluation, index + 1);
    }).ToList();
    static double Depth(JsonNode evaluation) => Math.Clamp(evaluation.Number("achieved_depth") ?? 0, 0, 5);
    static Outcome OutcomeOf(Row row, double target)
    {
        var evaluation = row.Evaluation; if (evaluation is null) return Outcome.Unrecorded;
        if (evaluation.Text("outcome").NonEmpty() is { } value) return value switch { "reached" => Outcome.Reached, "one_short" => Outcome.OneShort, "missed" => Outcome.Missed, _ => Outcome.Unrecorded };
        if (evaluation.Bool("skipped")) return Outcome.Missed; var gap = target - Depth(evaluation); if (gap <= 0) return Outcome.Reached; if (evaluation.Text("depth_status") == "not_probed") return Outcome.OneShort; return gap == 1 ? Outcome.OneShort : Outcome.Missed;
    }
    static readonly Dictionary<string, string> SectorNames = new() { ["resume"] = "讲项目", ["job"] = "岗位要求", ["material"] = "资料", ["intro"] = "自我介绍" };
    static int? Rounded(double? value) => value is { } number ? (int)SwiftText.Rounded(number) : null;
    public static View ViewOf(JsonNode? detail, JsonNode? report, List<Row> rows, string title, string sub)
    {
        var target = MockMap.DiffLevel.GetValueOrDefault(detail.Text("difficulty"), 3); var category = detail.Get("category"); var fallback = category is not null && category.Text("id") != "rd" ? "专业问答" : "技术问答";
        int? NoOf(double sequence) => rows.FirstOrDefault(r => r.Round.Main.Number("sequence_no") == sequence)?.No;
        var questions = rows.Select(row =>
        {
            var evaluation = row.Evaluation; var last = row.Round.Turns.LastOrDefault() ?? row.Round.Main; var miss = evaluation.Items("signals").FirstOrDefault(s => s.Text("verdict") is "miss" or "partial"); var skipped = evaluation.Bool("skipped");
            var expected = evaluation.Number("target_depth");
            return new Question(row.Round.Main.Display("id"), row.No, row.Round.Topic, OutcomeOf(row, target), true, evaluation is null ? null : skipped ? 0 : Depth(evaluation), expected is > 0 ? expected.Value : target, Rounded(evaluation.Number("score")), Math.Max(0, row.Round.Turns.Count - 1), SectorNames.GetValueOrDefault(row.Round.Main.Text("anchor_kind"), fallback), last.Text("content"), last.Text("answer_status") == "answered" ? last.Text("answer_text") : null, evaluation.Text("reference_answer").NonEmpty() ?? evaluation.Items("weaknesses").FirstOrDefault().String(), miss is null ? null : miss.Text("signal"), skipped ? "跳过了这道题" : null, false, null);
        }).ToList();
        var competencies = report.Items("competencies"); var source = competencies.Count == 0 ? report.Items("dimensions") : competencies;
        var dimensions = source.Select(item =>
        {
            var score = item.Number("score"); var assessed = competencies.Count == 0 || item.Bool("assessed") && score is not null; var refs = item.Items("question_refs").Select(r => r.Number()).OfType<double>();
            return new Dimension(item.Text("key"), DimensionLabels.GetValueOrDefault(item.Text("key"), item.Text("key")), assessed, assessed && score is { } s ? Math.Clamp((int)Math.Ceiling(s / 20), 1, 5) : null, assessed ? Rounded(score) : null, 100, null, 0, null, item.Text("comment").NonEmpty(), null, refs.Select(NoOf).FirstOrDefault(n => n is not null), assessed ? null : "这场没考到");
        }).ToList();
        var level = report.Get("verdict").Text("level").NonEmpty(); var missed = questions.Count(q => q.Outcome == Outcome.Missed); var follows = detail.Items("questions").Count(q => q.Text("kind") == "follow_up");
        // JSONValue.integer 对存在的非数值也返回 0。
        var done = detail.Items("done_actions").Select(v => (int)(v.Number() ?? 0)).ToHashSet();
        var actions = report.Items("actions").Take(3).Select((action, index) =>
        {
            var quote = action.Text("resume_quote"); return new Action(action.Text("title"), quote.Length == 0 ? action.Text("detail").NonEmpty() : $"{quote} → {action.Text("detail")}", action.Text("priority") == "high", action.Items("question_refs").Select(r => r.Number()).OfType<double>().Select(NoOf).OfType<int>().ToList(), action.Text("kind").NonEmpty() ?? "practice", done.Contains(index));
        }).ToList();
        return new(title, sub, Rounded(report.Number("total_score")), level is null ? null : (MockMap.VerdictName.GetValueOrDefault(level, level), MockMap.VerdictTone(level)), report.Text("headline"), report.Text("summary"), [new($"{questions.Count(q => q.Outcome == Outcome.Reached)} / {questions.Count} 道", "答到位", false), new($"{missed} 道", "没答上", missed > 0), new($"{follows} 次", "追问", false)], questions, target, $"{MockMap.DiffName.GetValueOrDefault(detail.Text("difficulty"), "中级")}目标线 · 要答进「{LevelLabel(target)}」", dimensions, 0, actions);
    }
    public static string OutcomeText(Question question) => question.Layered ? question.Outcome switch { Outcome.Reached => "答到位", Outcome.OneShort => "差一点", Outcome.Missed => "没答上", _ => "没记下" } : question.Outcome switch { Outcome.Reached => "说清了", Outcome.OneShort => "说了一半", Outcome.Missed => "没说清", _ => "没记下" };
    public static List<Question> Weak(View view) => view.Questions.Where(q => q.Outcome == Outcome.Missed).Concat(view.Questions.Where(q => q.Outcome == Outcome.OneShort)).ToList();
    public sealed record OverviewMap(List<MockMap.Point> Points, List<MockMap.Sector> Sectors, List<MockMap.PathStep> Path, List<double> Bounds, List<string> Hot);
    public static OverviewMap? OverviewMapOf(IReadOnlyList<Question> questions)
    {
        if (questions.Count == 0) return null; var groups = questions.Select(q => q.Sector).Distinct().ToList(); var ordered = groups.SelectMany(name => questions.Where(q => q.Sector == name)).ToList(); var step = 360.0 / ordered.Count; var angles = new Dictionary<string, double>();
        for (var i = 0; i < ordered.Count; i++) angles[ordered[i].Id] = -150 + i * step;
        var limit = questions.Count >= 8 ? 8 : questions.Count >= 6 ? 10 : 12;
        static double Stop(Question q) => q.Level is not { } level ? 0 : q.Outcome == Outcome.Reached ? Math.Max(1, level) : Math.Min(5, level + 1);
        var points = questions.Select(q => new MockMap.Point(q.Id, MockMap.ShortLabel(q.Title, limit), q.Sector, angles[q.Id], Stop(q), 2)).ToList();
        var sectors = groups.Select(name => { var own = ordered.Where(q => q.Sector == name).Select(q => angles[q.Id]).ToList(); return new MockMap.Sector(name, (own.Min() + own.Max()) / 2); }).ToList();
        var bounds = groups.Count > 1 ? groups.Select(name => angles[ordered.First(q => q.Sector == name).Id] - step / 2).ToList() : [];
        return new(points, sectors, questions.Where(q => q.Level is not null).Select(q => new MockMap.PathStep(q.Id, 1, Stop(q), q.Outcome == Outcome.Reached)).ToList(), bounds, points.Select(p => p.Id).ToList());
    }
    public sealed record RecordTurn(string Question, string Answer);
    public sealed record RecordEntry(string Question, string Answer, List<RecordTurn> FollowUps);
    public static List<RecordEntry> Record(JsonNode? detail)
    {
        static string Said(JsonNode turn) => turn.Text("answer_status") == "answered" ? turn.Text("answer_text") : "";
        return MockMap.Rounds(detail).Select(r => new RecordEntry(r.Main.Text("content"), Said(r.Main), r.Turns.Skip(1).Select(t => new RecordTurn(t.Text("content"), Said(t))).ToList())).ToList();
    }
    public static string ShortText(string text, int limit = 14) => SwiftText.Count(text) > limit ? SwiftText.Prefix(text, limit - 1) + "…" : text;
    public static double ChangeRatio(string original, string next)
    {
        var a = original.Trim(); var b = next.Trim(); if (a.Length == 0) return b.Length == 0 ? 0 : 1; var previous = Enumerable.Range(0, b.Length + 1).ToArray();
        for (var i = 1; i <= a.Length; i++) { var diagonal = previous[0]; previous[0] = i; for (var j = 1; j <= b.Length; j++) { var temp = previous[j]; previous[j] = Math.Min(Math.Min(previous[j] + 1, previous[j - 1] + 1), diagonal + (a[i - 1] == b[j - 1] ? 0 : 1)); diagonal = temp; } }
        return (double)previous[b.Length] / a.Length;
    }
}
