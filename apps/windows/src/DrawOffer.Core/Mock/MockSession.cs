using System.Text.Json.Nodes;
using System.Globalization;

namespace DrawOffer.Core.Models;

public static class MockSession
{
    public static string Heading(JsonNode? detail)
    {
        var mode = detail.Text("answer_mode") == "voice" ? "语音面试" : "文字面试";
        var who = string.Join(" ", new[] { detail.Text("company_name").NonEmpty(), detail.Text("stage_label").NonEmpty() is { } stage ? stage + "准备" : null }.OfType<string>());
        return $"{(who.Length == 0 ? detail.Text("resume_title") : who)} · {mode}";
    }
    public static string Subtitle(JsonNode? detail) => string.Join(" · ", new[] { MockMap.TypeName(detail), MockMap.DiffName.GetValueOrDefault(detail.Text("difficulty")), $"{detail.Integer("question_count")} 题", detail.Get("practice_focus").Text("label").NonEmpty() is { } focus ? "先问 " + focus : null }.OfType<string>().Where(s => s.Length > 0));
    public static JsonNode? Current(JsonNode? detail) { var id = detail.Display("current_question_id"); return id.Length == 0 ? null : detail.Items("questions").FirstOrDefault(q => q.Display("id") == id); }
    public static JsonNode? LastAsked(JsonNode? detail) => detail.Items("questions").OrderByDescending(q => q.Number("sequence_no") ?? 0).FirstOrDefault();
    public static MockMap.Round? RoundOf(JsonNode? detail, JsonNode? question) { if (question is null) return null; var root = question.Display("parent_id").NonEmpty() ?? question.Display("id"); return MockMap.Rounds(detail).FirstOrDefault(r => r.Main.Display("id") == root); }
    public static string Progress(JsonNode? detail, JsonNode? question)
    {
        var count = detail.Integer("question_count"); if (question is null) return $"{count} / {count} 题"; if (MockMap.IsIntro(detail, question)) return "开场 · 自我介绍";
        var rounds = MockMap.Rounds(detail).Where(r => !r.Intro).ToList(); var round = RoundOf(detail, question); var index = round is null ? rounds.Count - 1 : rounds.FindIndex(r => r.Main.Display("id") == round.Main.Display("id")); var follows = round is null ? 0 : round.Turns.Count - 1;
        return $"第 {index + 1} / {count} 题" + (follows > 0 ? $" · 追问 {follows} 次" : "");
    }
    public sealed record Note(string Kind, string Text, double Level);
    public static List<Note> Notes(MockMap.Round? round) => round?.Turns.SelectMany(turn => turn.Items("notes").Select(n => new Note(n.Text("kind"), n.Text("text"), Math.Max(1, turn.Number("depth_level") ?? 1)))).ToList() ?? [];
    public static string ShortNote(string text, double limit = 12)
    {
        var chars = SwiftText.Elements(text); var head = Array.FindIndex(chars, c => "：:，,。；;".Contains(c, StringComparison.Ordinal)); var clean = string.Concat(head < 0 ? chars : chars.Take(head)).Trim(); chars = SwiftText.Elements(clean);
        static bool Ascii(string c) => c.Length == 1 && c[0] is >= ' ' and <= '~';
        static bool Alnum(string c) => c.Length == 1 && (c[0] is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9');
        var width = 0.0; var end = 0; while (end < chars.Length) { var next = width + (Ascii(chars[end]) ? .55 : 1); if (next > limit) break; width = next; end++; }
        if (end >= chars.Length) return clean; var cut = end; while (cut > 0 && Alnum(chars[cut - 1]) && Alnum(chars[cut])) cut--; if (cut < end / 2.0) cut = end;
        return string.Concat(chars.Take(cut).Reverse().SkipWhile(c => c == "、" || SwiftText.IsWhitespace(c)).Reverse()) + "…";
    }
    public enum Phase { Asking, Answering, Thinking, Done }
    public enum NoteTone { Blue, Orange }
    public sealed record Annotation(double Level, string Text, NoteTone Tone);
    public sealed record Map(List<MockMap.Point> Points, List<MockMap.Sector> Sectors, List<MockMap.PathStep> Path, string? Now, List<string> Hot, double Rotation, List<Annotation> Annotations, List<MockMap.Round> Rounds, List<double>? Bounds);
    public static Map MapOf(JsonNode? detail, List<MockMap.Point> memory, List<MockMap.Sector> memorySectors, Func<string?, string?>? experienceOf, JsonNode? current, Phase phase)
    {
        var slots = MockLayout.SlotsOf(detail, memory, experienceOf); var path = slots?.Path ?? []; var rounds = slots?.Rounds ?? []; var points = slots?.Points ?? memory; var sectors = slots?.Sectors ?? memorySectors;
        var round = RoundOf(detail, current); var index = round is null ? -1 : rounds.FindIndex(r => r.Main.Display("id") == round.Main.Display("id")); var step = index >= 0 && index < path.Count ? path[index] : null; var point = step is null ? null : points.FirstOrDefault(p => p.Id == step.Id); var rotation = point is null ? 0 : 180 - point.Angle;
        var deepest = 1.0; foreach (var turn in round?.Turns ?? []) { var depth = turn.Number("depth_level") ?? 0; deepest = Math.Max(deepest, depth == 0 ? 1 : depth); }
        var steps = path.Select((item, i) => i == index && round is not null ? item with { To = deepest, Ok = phase == Phase.Done ? item.Ok : null } : item).ToList(); var annotations = new List<Annotation>();
        if (round is not null && point is not null && phase != Phase.Done)
        {
            var notes = Notes(round);
            for (var level = Math.Max(1, round.From); level <= deepest; level++)
            {
                var here = notes.Where(n => n.Level == level).ToList(); var question = here.FirstOrDefault(n => n.Kind == "question"); var hit = here.FirstOrDefault(n => n.Kind == "hit");
                if (question is not null && level == deepest && phase == Phase.Thinking) annotations.Add(new(level, $"? {MockMap.LevelName(level)} · {ShortNote(question.Text, 10)}", NoteTone.Orange));
                else if (hit is not null) annotations.Add(new(level, $"✓ {MockMap.LevelName(level)} · {ShortNote(hit.Text, 10)}", NoteTone.Blue));
                else if (level == round.From && round.Turns.Count == 1) annotations.Add(new(level, MockMap.LevelName(level), NoteTone.Blue));
                else if (level > round.From) annotations.Add(new(level, "追问 · " + MockMap.LevelName(level), NoteTone.Blue));
            }
        }
        return new(points.Select(p => p with { Angle = p.Angle + rotation }).ToList(), sectors.Select(s => s with { Angle = s.Angle + rotation }).ToList(), steps, phase == Phase.Done ? null : point?.Id, path.Select(p => p.Id).ToList(), rotation, annotations, rounds, slots?.Bounds.Select(b => b + rotation).ToList());
    }
    public static MockLayout.Layout? LayoutOf(Map map, double targetLevel, bool labelAll)
    {
        if (map.Bounds is null) return null; var stage = MockLayout.Session; var placed = MockMap.Place(stage.At, map.Points); var notes = map.Annotations.TakeLast(1).ToList(); var now = placed.FirstOrDefault(p => p.Point.Id == map.Now);
        return MockLayout.LayoutOf(new(stage.At, placed, map.Path, map.Sectors, stage.Frame) { SectorFrame = stage.SectorFrame, Now = map.Now, NowLines = now is null ? 0 : notes.Count, NowLineWidth = notes.Select(n => MockLayout.TextWidth(n.Text, 10)).DefaultIfEmpty(0).Max(), LabelIds = labelAll ? null : map.Now is null ? [] : [map.Now] });
    }
    public enum BeadState { Done, Now, Todo, Skip }
    public sealed record Bead(string Id, string Title, BeadState State, int FollowUps, bool Miss);
    public static List<Bead> Beads(JsonNode? detail, JsonNode? current)
    {
        var now = RoundOf(detail, current); var beads = MockMap.Rounds(detail).Where(r => !r.Intro).Select(r => new Bead(r.Main.Display("id"), r.Topic, now?.Main.Display("id") == r.Main.Display("id") && detail.Text("status") == "in_progress" ? BeadState.Now : r.Skipped ? BeadState.Skip : BeadState.Done, r.Turns.Count - 1, r.Ok == false)).ToList();
        while (beads.Count < detail.Integer("question_count")) beads.Add(new("todo-" + beads.Count.ToString(CultureInfo.InvariantCulture), "…", BeadState.Todo, 0, false)); return beads;
    }
    public static bool IntroNow(JsonNode? detail, JsonNode? current) => current is not null && MockMap.IsIntro(detail, current);
    public static List<double> BeadXs(int count) => Enumerable.Range(0, count).Select(i => 300 + 790 * (i + .5) / Math.Max(1, count)).ToList();
    public static (string Label, string Quote)? SourceChip(JsonNode? question)
    {
        if (question is null || question.Text("kind") != "main" || question.Text("anchor").NonEmpty() is not { } anchor || question.Text("anchor_kind") == "intro") return null;
        return (question.Text("anchor_kind") switch { "job" => "从岗位要求里来", "material" => "从资料里来", _ => "从简历里来" }, anchor);
    }
    public static string Mmss(double seconds) { var total = Math.Max(0, (int)seconds); return (total / 60).ToString("00", CultureInfo.InvariantCulture) + ":" + (total % 60).ToString("00", CultureInfo.InvariantCulture); }
    public static (string Before, string Quote, string After)? SplitQuoted(string text, string? quote)
    {
        if (string.IsNullOrEmpty(quote) || MockText.Range(text, quote) is not { } range) return null;
        return (text[..range.Start], quote, text[range.End..]);
    }
    public static bool HasAnswered(JsonNode? detail) => detail.Items("questions").Any(q => q.Text("answer_status") == "answered" && !MockMap.IsIntro(detail, q));
}
