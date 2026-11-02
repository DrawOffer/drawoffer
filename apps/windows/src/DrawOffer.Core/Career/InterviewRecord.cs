using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
namespace DrawOffer.Core.Models;

/// <summary>追问及其回答。</summary>
public sealed record RecordFollowUp(string Question, string Answer);

/// <summary>
/// 一场面试的记录（`questions_markdown`）中的一道题，对应 Web `progress/interviewRecord.ts`。
/// 一段一轮：`面试官：` 问题、`我：` 回答、`面试官（追问）：` 追问、`面试官（回答）：` 反问时面试官的回答。
/// 旧记录（编号列表、自由文本、“说话人 1/2”）也能读。
/// </summary>
public sealed class RecordQuestion : IEquatable<RecordQuestion>
{
    public string Question { get; set; }
    public string Answer { get; set; }
    public string? Reply { get; set; }
    public List<RecordFollowUp> FollowUps { get; set; }

    public RecordQuestion(string question, string answer = "", string? reply = null, List<RecordFollowUp>? followUps = null)
    {
        Question = question; Answer = answer; Reply = reply; FollowUps = followUps ?? [];
    }

    public bool Equals(RecordQuestion? other) => other is not null && Question == other.Question && Answer == other.Answer && Reply == other.Reply && FollowUps.SequenceEqual(other.FollowUps);
    public override bool Equals(object? obj) => Equals(obj as RecordQuestion);
    public override int GetHashCode() => HashCode.Combine(Question, Answer, Reply, FollowUps.Count);
}

public static class InterviewRecord
{
    internal const string Interviewer = "面试官", FollowUp = "面试官（追问）", Reply = "面试官（回答）", Candidate = "我";

    /// <summary>段落以「标签：」开头时返回 (标签, 内容)：标签不超过 12 个非空白字符，或为「说话人 N」。</summary>
    internal static (string Label, string Text)? Turn(string paragraph)
    {
        var trimmed = SwiftText.Elements(paragraph).SkipWhile(SwiftText.IsWhitespace).ToArray();
        var colon = Array.FindIndex(trimmed, c => c is "：" or ":");
        if (colon < 0) return null;
        var labelChars = trimmed[..colon];
        var label = string.Concat(labelChars);
        var speaker = SwiftText.HasPrefix(label, "说话人")
            && SwiftText.Elements(SwiftText.TrimWhitespaces(SwiftText.DropFirst(label, 3))).All(SwiftText.IsNumber)
            && labelChars.Length > 3;
        if (!(speaker || labelChars.Length > 0 && labelChars.Length <= 12 && !labelChars.Any(SwiftText.IsWhitespace))) return null;
        return (label, string.Concat(trimmed[(colon + 1)..]));
    }

    public static List<RecordQuestion> Parse(string? markdown)
    {
        var source = SwiftText.TrimAll(markdown ?? "");
        if (source.Length == 0) return [];
        var groups = new List<List<string>> { new() };
        foreach (var line in source.Replace("\r\n", "\n").Split('\n'))
        {
            if (SwiftText.TrimWhitespaces(line).Length == 0) { if (groups[^1].Count > 0) groups.Add([]); }
            else groups[^1].Add(line);
        }
        var paragraphs = groups.Select(g => SwiftText.TrimAll(string.Join('\n', g))).Where(x => x.Length > 0).ToList();
        var labelled = paragraphs.Count(x => Turn(x) is not null);
        if (labelled >= Math.Max(1, paragraphs.Count / 2.0)) return ParseTurns(paragraphs);
        return ParseList(source);
    }

    static string Join(string current, string text) => current.Length == 0 ? text : current + "\n" + text;

    internal static List<RecordQuestion> ParseTurns(List<string> paragraphs)
    {
        var questions = new List<RecordQuestion>();
        string? speaker = null;
        var lastWasFollowUp = false;
        foreach (var paragraph in paragraphs)
        {
            var match = Turn(paragraph);
            var label = match?.Label;
            var text = SwiftText.TrimAll(match?.Text ?? paragraph);
            if (text.Length == 0) continue;
            // 没写名字时，先开口的当作面试官
            if (label is not null && SwiftText.HasPrefix(label, "说话人") && speaker is null) speaker = label;
            var asks = label == Interviewer || label == FollowUp || label is not null && label == speaker;
            if (label == Reply && questions.Count > 0)
            {
                questions[^1].Reply = Join(questions[^1].Reply ?? "", text); lastWasFollowUp = false;
            }
            else if (asks && label == FollowUp && questions.Count > 0)
            {
                questions[^1].FollowUps.Add(new(text, "")); lastWasFollowUp = true;
            }
            else if (asks || questions.Count == 0)
            {
                questions.Add(new RecordQuestion(text)); lastWasFollowUp = false;
            }
            else if (lastWasFollowUp && questions[^1].FollowUps.Count > 0)
            {
                var follow = questions[^1].FollowUps;
                follow[^1] = follow[^1] with { Answer = Join(follow[^1].Answer, text) };
            }
            else questions[^1].Answer = Join(questions[^1].Answer, text);
        }
        return questions;
    }

    // NSRegularExpression：`^` 只在开头，`.` 不匹配行终止符，`$` 允许末尾一个行终止符；`\d` `\s` 都是 Unicode 语义。
    static readonly Regex Numbered = new(@"^\s*(?:\d+[.)、]|[-*])\s+([^\n\r\u0085\u2028\u2029\v\f]*)(?:\r\n|[\n\r\u0085\u2028\u2029\v\f])?\z", RegexOptions.CultureInvariant);

    internal static List<RecordQuestion> ParseList(string source)
    {
        var questions = new List<RecordQuestion>();
        foreach (var line in source.Split('\n'))
        {
            var match = Numbered.Match(line);
            if (match.Success) { questions.Add(new RecordQuestion(SwiftText.TrimWhitespaces(match.Groups[1].Value))); continue; }
            var text = SwiftText.TrimWhitespaces(line);
            if (text.Length == 0) continue;
            if (questions.Count == 0) questions.Add(new RecordQuestion(text));
            else questions[^1].Answer = questions[^1].Answer.Length == 0 ? text : questions[^1].Answer + "\n" + text;
        }
        return questions;
    }

    internal static string OneLine(string text) => string.Join(' ', SwiftText.Split(text, SwiftText.IsWhitespace));

    public static string Serialize(IEnumerable<RecordQuestion> questions)
    {
        var blocks = new List<string>();
        foreach (var item in questions)
        {
            var question = OneLine(item.Question);
            if (question.Length == 0) continue;
            blocks.Add($"{Interviewer}：{question}");
            if (OneLine(item.Answer).Length > 0) blocks.Add($"{Candidate}：{OneLine(item.Answer)}");
            if (OneLine(item.Reply ?? "").Length > 0) blocks.Add($"{Reply}：{OneLine(item.Reply ?? "")}");
            foreach (var follow in item.FollowUps.Where(x => OneLine(x.Question).Length > 0))
            {
                blocks.Add($"{FollowUp}：{OneLine(follow.Question)}");
                if (OneLine(follow.Answer).Length > 0) blocks.Add($"{Candidate}：{OneLine(follow.Answer)}");
            }
        }
        return string.Join("\n\n", blocks);
    }

    /// <summary>`record:structure` 的返回（`InterviewRecordDraft`）转成题目。</summary>
    public static List<RecordQuestion> Draft(JsonNode value) =>
        value.Items("questions").Select(item => new RecordQuestion(item.Text("question"), item.Text("answer"), item.Text("reply").Length == 0 ? null : item.Text("reply"),
            item.Items("follow_ups").Select(x => new RecordFollowUp(x.Text("question"), x.Text("answer"))).ToList())).ToList();

    public static int Answered(IEnumerable<RecordQuestion> questions) => questions.Count(x => SwiftText.TrimAll(x.Answer).Length > 0);
}
