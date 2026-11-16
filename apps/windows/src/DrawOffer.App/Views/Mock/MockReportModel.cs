using System.Globalization;
using System.Text.Json.Nodes;
using DrawOffer.Core.Models;

namespace DrawOffer.App.Views.Mock;

/// <summary>
/// 面试复盘的统一结构（Windows 稿 09 · 10 复盘；Mac `MockRV`、Web `interviews/report/reviewView.ts`、`fromMock.ts`）：
/// 一题是一道主问题连同它的追问；只有语音面试才有的录音、语音指标按数据有无显示。
/// </summary>
internal static class MockRV
{
    public enum Outcome { Reached, OneShort, Missed, Unrecorded }

    public sealed record Turn(string Id, string Ask, string? Answer, string Missing, bool Follow, double? DurationMs, bool HasRecording, bool Editable);
    public sealed record Signal(string Label, string State, string? Quote);
    public sealed record History(string Date, string Title, string Result, bool Current = false);

    public sealed record Question(string Id, int No, string Ref, string Title, Outcome Outcome, int? Level, int? AiLevel, int Expected, int? Score, int Follows,
        string? Line, List<Turn> Turns, List<Signal> Signals, string? Better, string? Highlight, string? Advice, int ReEvaluated)
    {
        public bool Layered { get; init; } = true;
        public List<History>? History { get; init; }
        public int Stops { get; init; }
        public bool Recovered { get; init; }
        public bool Weak => Outcome is Outcome.Missed or Outcome.OneShort;
    }

    public sealed record Ability(string Key, string Label, int Score, double? Past);
    public sealed record Voice(string Speed, string Pauses, string Fillers);
    public sealed record View(string Title, string Meta, string RecordTitle, int? Score, string Conclusion, string Compare, List<Question> Questions, int Target, List<Ability> Abilities, Voice? Voice, int PastCount);

    public static readonly string[] Levels = ["了解", "熟悉", "掌握", "精通", "专家"];
    public static string LevelLabel(int level) => Levels[Math.Clamp(level - 1, 0, 4)];

    public static readonly Dictionary<string, string> VerdictName = new()
    {
        ["likely_pass"] = "达到目标", ["promising"] = "接近目标", ["at_risk"] = "还差一些", ["likely_fail"] = "差距较大", ["insufficient"] = "证据不足",
        ["meets"] = "达标", ["borderline"] = "接近达标", ["below"] = "未达标",
    };

    public static string OutcomeText(Question q) => q.Layered
        ? q.Outcome switch { Outcome.Reached => "答到位", Outcome.OneShort => "差一点", Outcome.Missed => "没答上", _ => "没记下" }
        : q.Outcome switch { Outcome.Reached => "说清了", Outcome.OneShort => "说了一半", Outcome.Missed => "没说清", _ => "没记下" };

    public static Outcome OutcomeAt(int level, int expected) => (expected - level) switch { <= 0 => Outcome.Reached, 1 => Outcome.OneShort, _ => Outcome.Missed };

    static Outcome Parse(string value) => value switch { "reached" => Outcome.Reached, "one_short" => Outcome.OneShort, "missed" => Outcome.Missed, _ => Outcome.Unrecorded };
    public static string Raw(Outcome value) => value switch { Outcome.Reached => "reached", Outcome.OneShort => "one_short", Outcome.Missed => "missed", _ => "unrecorded" };

    /// <summary>卡片深度下面的一行：答到「熟悉」· 要到「掌握」</summary>
    public static string DepthLine(Question q, bool asReached = false)
    {
        if (q.Level is not { } level) return "没记下回答";
        var at = level <= 0 ? "没到「了解」" : $"答到「{LevelLabel(level)}」";
        return q.Outcome == Outcome.Reached || asReached ? at : $"{at} · 要到「{LevelLabel(q.Expected)}」";
    }

    /// <summary>单题详情深度上面的一句。</summary>
    public static string DepthSentence(Question q)
    {
        var wanted = LevelLabel(q.Expected);
        if (q.Level is not { } level) return $"没记下回答，面试官想听到「{wanted}」";
        return level <= 0 ? $"没到「了解」，面试官想听到「{wanted}」" : $"答到「{LevelLabel(level)}」，面试官想听到「{wanted}」";
    }

    public static string? RepeatTag(Question q)
    {
        if (!q.Weak || q.History is not { } history) return null;
        if (q.Stops >= 2) return $"第 {q.Stops} 次停在这";
        return history.Count == 0 ? "第一次问到" : null;
    }

    public static string? StopTag(Question q)
    {
        if (q.History is not { } history) return null;
        if (q.Stops >= 2) return $"停过 {q.Stops} 次";
        return history.Count == 0 ? "第一次问到" : null;
    }

    public static List<string> Gaps(Question q) => q.Signals.Where(s => s.State != "hit").Select(s => s.Label).ToList();

    public static List<Question> Suggestions(IEnumerable<Question> questions, int limit = 3) =>
        questions.Where(q => q.Weak).OrderByDescending(q => q.Stops).ThenBy(q => q.Score ?? 0).ThenBy(q => q.No).Take(limit).ToList();

    public static string Advice(Question q) => q.Advice ?? (q.Stops >= 2 ? $"这里已经停过 {q.Stops} 次，先把这一段补上。" : q.Line ?? "先把这一段补上，再练一次。");

    public static string MonthDay(string value) => Json.Date(value)?.ToBeijing().ToString("MM-dd", CultureInfo.InvariantCulture) ?? "";

    const string Clean = " \n\t，。！？、,.!?：:“”\"'（）()";

    /// <summary>原话在回答里的位置：评分引的原话可能和回答差几个标点。</summary>
    public static string? QuoteIn(string answer, string? quote)
    {
        var text = quote?.Trim();
        if (string.IsNullOrEmpty(text)) return null;
        if (answer.Contains(text, StringComparison.Ordinal)) return text;
        var wanted = new string(text.Where(c => !Clean.Contains(c)).ToArray());
        if (wanted.Length < 4) return null;
        var kept = Enumerable.Range(0, answer.Length).Where(i => !Clean.Contains(answer[i])).ToList();
        var joined = new string(kept.Select(i => answer[i]).ToArray());
        var start = joined.IndexOf(wanted, StringComparison.Ordinal);
        if (start < 0) return null;
        return answer[kept[start]..(kept[start + wanted.Length - 1] + 1)];
    }

    public sealed record Mark(string Quote, string Label, string State);

    public static List<Mark> Marks(Question q, string? answer)
    {
        if (answer is null) return [];
        return q.Signals.Where(s => s.State != "hit").Select(s => QuoteIn(answer, s.Quote) is { } quote ? new Mark(quote, s.Label, s.State) : null).OfType<Mark>().ToList();
    }

    public static string MarkText(Mark mark) => mark.State == "miss" ? $"没说到{mark.Label}" : $"只说了一半：{mark.Label}";

    // MARK: 模拟面试评估报告 → 统一结构

    public static View? ViewOf(JsonNode? detail, JsonNode? context)
    {
        if (detail.Get("report") is not JsonObject report) return null;
        var target = (int)MockMap.DiffLevel.GetValueOrDefault(detail.Text("difficulty"), 3);
        var rounds = MockMap.Rounds(detail).Where(r => !r.Intro).ToList();
        var fromReport = report.Items("questions");
        var date = detail.Text("finished_at").NonEmpty() ?? detail.Text("created_at");
        var questions = rounds.Select((round, index) =>
        {
            var sequence = round.Main.Number("sequence_no");
            JsonNode? evaluation = fromReport.FirstOrDefault(q => q.Number("sequence_no") == sequence)?.DeepClone();
            if (evaluation is JsonObject merged && round.Main.Get("evaluation") is JsonObject latest)
                foreach (var (key, value) in latest)
                    if (key is not ("topic" or "sequence_no")) merged[key] = value?.DeepClone();
            return WithContext(QuestionOf(round, evaluation, index + 1, target, report), date, context);
        }).ToList();
        var type = MockMap.TypeName(detail);
        var stage = detail.Text("stage_label").NonEmpty() ?? type;
        var stats = MockMap.StatsOf(detail);
        var follows = detail.Items("questions").Count(q => q.Text("kind") == "follow_up");
        var role = detail.Text("job_title").NonEmpty() ?? detail.Text("target_role").NonEmpty();
        var meta = string.Join(" · ", new[] { role, "模拟", type, follows > 0 ? $"追问 {follows} 次" : null, MonthDay(date) }.Where(s => !string.IsNullOrEmpty(s)));
        int? score = report.Number("total_score") is { } total ? (int)Math.Round(total) : null;
        var verdict = report.Get("verdict").Text("level").NonEmpty();
        var metrics = report.Get("voice_metrics") as JsonObject;
        int? previous = context.Get("previous").Number("score") is { } p ? (int)Math.Round(p) : null;
        return new View(
            $"{detail.Text("company_name").NonEmpty() ?? "通用练习"} {stage}", meta,
            $"{stage}问了 {rounds.Count} 道题。" + (stats.Minutes is { } m ? $" {m} 分钟" : ""),
            score,
            (verdict is not null ? VerdictName.GetValueOrDefault(verdict) : null) ?? report.Text("headline"),
            CompareLine(score, previous, questions),
            questions, target, Abilities(report, context),
            detail.Text("answer_mode") == "voice" && metrics is not null
                ? new Voice($"{(int)Math.Round(metrics.Number("chars_per_minute") ?? 0)} 字/分", $"{metrics.Integer("long_pauses")} 次", ((metrics.Number("filler_ratio") ?? 0) * 100).ToString("0.0", CultureInfo.InvariantCulture) + "%")
                : null,
            context.Integer("past_count"));
    }

    static Question QuestionOf(MockMap.Round round, JsonNode? evaluation, int no, int target, JsonNode report)
    {
        var expected = evaluation.Integer("target_depth") is var t and > 0 ? t : target;
        var skipped = evaluation.Bool("skipped");
        int? aiLevel = evaluation is null ? null : skipped ? 0 : Math.Clamp(evaluation.Integer("achieved_depth"), 0, 5);
        int? userDepth = round.Main.Get("evaluation").Number("user_depth") is { } u ? (int)u : null;
        Outcome outcome;
        if (userDepth is { } ud) outcome = OutcomeAt(ud, expected);
        else if (evaluation is null) outcome = Outcome.Unrecorded;
        else if (evaluation.Text("outcome").NonEmpty() is { } given) outcome = given == "not_judged" ? Outcome.Unrecorded : Parse(given);
        else if (skipped) outcome = Outcome.Missed;
        else
        {
            var gap = target - Math.Clamp(evaluation.Integer("achieved_depth"), 0, 5);
            outcome = gap <= 0 ? Outcome.Reached : evaluation.Text("depth_status") == "not_probed" || gap == 1 ? Outcome.OneShort : Outcome.Missed;
        }
        static string? First(JsonNode? node, string key) => node.Items(key).Select(i => i is JsonValue v && v.TryGetValue<string>(out var s) ? s : null).FirstOrDefault();
        var weakness = First(evaluation, "weaknesses");
        var highlight = First(evaluation, "highlights");
        var weak = outcome is Outcome.Missed or Outcome.OneShort;
        var sequence = round.Main.Integer("sequence_no");
        var turns = round.Turns.Select((turn, position) => new Turn(
            turn.Display("id"), turn.Text("content"),
            turn.Text("answer_status") == "answered" ? turn.Text("answer_text") : null,
            turn.Text("answer_status") == "skipped" ? "跳过了这道题" : "这道题没有作答",
            position > 0, turn.Number("audio_duration_ms"), turn.Bool("has_recording"),
            turn.Text("answer_source") == "voice" && turn.Text("answer_status") == "answered")).ToList();
        var signals = evaluation.Items("signals").Where(i => i.Text("verdict") != "not_probed")
            .Select(i => new Signal(i.Text("signal"), i.Text("verdict"), i.Text("evidence").NonEmpty())).ToList();
        var advice = report.Items("actions").FirstOrDefault(a => a.Text("kind") == "practice" && a.Items("question_refs").Any(r => (int)(r.Number() ?? -1) == sequence))?.Text("detail").NonEmpty();
        return new Question(round.Main.Display("id"), no, sequence.ToString(CultureInfo.InvariantCulture), round.Topic, outcome, userDepth ?? aiLevel, aiLevel, expected,
            evaluation.Number("score") is { } s ? (int)Math.Round(s) : null, Math.Max(0, round.Turns.Count - 1),
            weak ? weakness ?? highlight : highlight ?? weakness, turns, signals,
            evaluation.Text("reference_answer").NonEmpty() ?? weakness, highlight, advice,
            round.Main.Get("re_evaluate_count") is null ? 3 : round.Main.Integer("re_evaluate_count"))
        { Stops = weak ? 1 : 0 };
    }

    static string LevelResult(int? level, string outcome, bool layered)
    {
        if (layered && level is { } l) return l <= 0 ? "没到「了解」" : LevelLabel(l);
        return OutcomeText(new Question("", 0, "", "", Parse(outcome), null, null, 0, null, 0, null, [], [], null, null, null, 0) { Layered = layered });
    }

    /// <summary>把「和以往比」接到一道题上：history 第一行是这一场。</summary>
    static Question WithContext(Question q, string date, JsonNode? context)
    {
        if (context is not JsonObject) return q;
        var found = context.Items("questions").FirstOrDefault(i => i.Display("ref") == q.Ref);
        var here = new History(MonthDay(date), "这场", LevelResult(q.Level, Raw(q.Outcome), q.Layered), true);
        var past = found.Items("history").Select(h => new History(MonthDay(h.Text("at")), h.Text("title"),
            LevelResult(h.Number("level") is { } lv ? (int)lv : null, h.Text("outcome"), q.Layered))).ToList();
        var recovered = found.Bool("recovered");
        return q with
        {
            History = past.Count == 0 ? [] : [here, .. past],
            Stops = found.Get("stops") is null ? (q.Weak ? 1 : 0) : found.Integer("stops"),
            Recovered = recovered,
            Line = recovered ? "上次没过，这次答到了。" : q.Line,
        };
    }

    static string CompareLine(int? score, int? previous, List<Question> questions)
    {
        var judged = questions.Where(q => q.Outcome != Outcome.Unrecorded).ToList();
        var tally = $"{judged.Count} 题答到位 {judged.Count(q => q.Outcome == Outcome.Reached)} 题";
        if (score is not { } s || previous is not { } p) return tally;
        var gap = s - p;
        return (gap > 0 ? $"比上一场高 {gap} 分" : gap < 0 ? $"比上一场低 {-gap} 分" : "和上一场同分") + "，" + tally;
    }

    static readonly HashSet<string> Outside = ["knowledge", "job_fit", "professional_depth", "resume_consistency"];

    static List<Ability> Abilities(JsonNode report, JsonNode? context)
    {
        var competencies = report.Items("competencies");
        var items = competencies.Count == 0
            ? report.Items("dimensions").Select(d => (d.Text("key"), (d.Number("score") ?? 0) * 20)).ToList()
            : competencies.Where(c => c.Bool("assessed") && c.Number("score") is not null).Select(c => (c.Text("key"), c.Number("score") ?? 0)).ToList();
        return items.Select(i => new Ability(i.Item1, MockReview.DimensionLabels.GetValueOrDefault(i.Item1, i.Item1), (int)Math.Round(i.Item2),
            context.Get("competencies").Get(i.Item1).Number("average"))).ToList();
    }

    /// <summary>通用能力只看怎么说，不含知识和岗位匹配；能评的太少时才把它们放回来。最多 6 项。</summary>
    public static List<Ability> GeneralAbilities(List<Ability> abilities)
    {
        var general = abilities.Where(a => !Outside.Contains(a.Key)).ToList();
        var shown = general.Count >= 3 ? general : abilities;
        return shown.Take(6).Select(a => a.Key == "communication" ? a with { Label = "表达水平" } : a).ToList();
    }

    /// <summary>复盘里「练这几题」「练这一处」带到配置页的内容（Web `practicePlan.ts`）。</summary>
    public static MockPracticeItem PracticeItem(Question q)
    {
        var gaps = Gaps(q);
        static string Cut(string s, int n) => s.Length > n ? s[..n] : s;
        return new MockPracticeItem(
            Cut(q.Title, 120), Cut(q.Turns.LastOrDefault()?.Ask ?? q.Title, 500),
            gaps.Take(5).Select(g => Cut(g, 300)).ToList(), q.Line, RepeatTag(q),
            string.Join("，", new[] { DepthLine(q, true), q.Line }.Where(s => s is not null)),
            string.Join("，", new[] { $"答到「{LevelLabel(q.Expected)}」", gaps.Count == 0 ? null : $"把{string.Join("和", gaps.Take(2))}讲清楚" }.Where(s => s is not null)));
    }
}
