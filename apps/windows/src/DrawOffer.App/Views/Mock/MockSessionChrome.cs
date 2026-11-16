using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

/// <summary>
/// 面试中全屏画面的共用部件（Windows 稿 09 · 03 开始前 / 05 面试中 / 06 文字面试 / 07 结束；Mac `MockSessionChrome`、Web `v2/SessionChrome.tsx`）：
/// 画面固定 1368 × 828，整体等比缩放；顶行、大字题目、底部一行（这场要练的、这段回答）。
/// </summary>
internal static class MockFull
{
    public const double Width = 1368, Height = 828;

    /// <summary>新的一张画布（白底）。</summary>
    public static Canvas Canvas() => new() { Width = Width, Height = Height, Background = Brush(V3.White) };

    /// <summary>
    /// 外框：没有侧栏，白底铺满，按设计尺寸等比缩放。顶上留 32 高的标题栏条（可拖动窗口，系统按钮在它右边），画面从它下面开始，
    /// 右上角的「结束并评估」不会被最小化 / 关闭按钮盖住。
    /// </summary>
    public static FrameworkElement Stage(Canvas canvas)
    {
        var grid = new Grid { Background = Brush(V3.White) };
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(32) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var strip = new Border { Background = Brush(V3.White) };
        var box = new Viewbox { Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform, Child = canvas };
        Grid.SetRow(box, 1);
        grid.Children.Add(strip);
        grid.Children.Add(box);
        grid.Loaded += (_, _) => Shell.WorkspaceShell.Current?.SetDragRegion(strip);
        return grid;
    }

    public static T Put<T>(Canvas canvas, T element, double x, double y) where T : UIElement
    {
        Microsoft.UI.Xaml.Controls.Canvas.SetLeft(element, x);
        Microsoft.UI.Xaml.Controls.Canvas.SetTop(element, y);
        canvas.Children.Add(element);
        return element;
    }

    /// <summary>`.mi3-center`：1120 宽、居中排的一行（左边 124）。</summary>
    public static TextBlock Center(Canvas canvas, string text, double top, double size = 13, double line = 20, Color? color = null, bool serif = false)
    {
        var block = (serif ? Serif(text, size, color ?? MP.Ink) : Sans(text, size, color ?? MP.Fnt)).LineHeight(line).Wrap();
        block.Width = 1120;
        block.TextAlignment = TextAlignment.Center;
        return Put(canvas, block, 124, top);
    }

    /// <summary>
    /// 顶行（`SessionHead`）：没开始或已结束时左边是返回（「← 面试设置 / 公司 · 轮次」）；进行中左边是这场是谁，中间计时，右边跳过 / 放弃 / 结束。
    /// </summary>
    public static TextBlock? Head(Canvas canvas, JsonNode? detail, bool timer = false, (string Label, bool Disabled, Action Action)? back = null, params UIElement[] right)
    {
        if (back is { } b)
        {
            var crumb = HStack(12,
                HStack(6, Icon("arrow.left", 13, MP.Fnt), Sans(b.Label, 16, MP.Fnt)).OnTap(b.Action, "返回" + b.Label, () => !b.Disabled),
                Sans("/", 16, MP.Fnt),
                Sans(MockSessionText.Who(detail), 16, MP.Ink).Also(t => { t.TextTrimming = TextTrimming.CharacterEllipsis; t.MaxWidth = 360; }));
            crumb.Opacity = b.Disabled ? 0.5 : 1;
            Put(canvas, crumb.Frame(height: 22), 48, 24);
        }
        else
        {
            var who = HStack(12,
                Label(MockSessionText.Who(detail), 14, MP.Ink, Medium).Also(t => { t.TextTrimming = TextTrimming.CharacterEllipsis; t.MaxWidth = 300; }),
                Sans(detail.Text("job_title").NonEmpty() ?? detail.Text("target_role"), 13, MP.Fnt).Also(t => { t.TextTrimming = TextTrimming.CharacterEllipsis; t.MaxWidth = 168; t.VerticalAlignment = VerticalAlignment.Bottom; }));
            Put(canvas, who.Frame(height: 20), 48, 25);
        }
        TextBlock? clock = null;
        if (timer)
        {
            clock = Serif(MockSessionText.Elapsed(detail), 22, MP.Ink);
            clock.Width = Width; clock.TextAlignment = TextAlignment.Center;
            AutomationProperties.SetName(clock, "用时");
            Put(canvas, clock, 0, 19);
        }
        if (right.Length > 0)
        {
            var row = HStack(24, right);
            row.Height = 40; row.HorizontalAlignment = HorizontalAlignment.Right;
            foreach (var item in right) if (item is FrameworkElement element) element.VerticalAlignment = VerticalAlignment.Center;
            Put(canvas, new Grid { Width = Width - 96, Children = { row } }, 48, 16);
        }
        return clock;
    }

    /// <summary>`.mi3-question`：题目固定在两行大字的位置（左 124、顶 203、1120 × 160），长了收小字号；还没「打」出来的字浅灰。</summary>
    public static TextBlock BigQuestion(Canvas canvas, string text, int shown = int.MaxValue)
    {
        var block = new TextBlock { FontFamily = SansFamily, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Width = 1120, MaxHeight = 160 };
        SetQuestion(block, text, shown);
        AutomationProperties.SetName(block, text);
        return Put(canvas, block, 124, 203);
    }

    public static void SetQuestion(TextBlock block, string text, int shown)
    {
        var count = text.Length;
        var (size, line) = count <= 48 ? (46.0, 64.0) : count <= 93 ? (36.0, 50.0) : count <= 160 ? (28.0, 40.0) : (22.0, 32.0);
        block.FontSize = size;
        block.LineHeight = line;
        block.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        block.Inlines.Clear();
        var cut = Math.Clamp(shown, 0, count);
        block.Inlines.Add(new Run { Text = text[..cut], Foreground = Brush(MP.Ink) });
        if (cut < count) block.Inlines.Add(new Run { Text = text[cut..], Foreground = Brush(MP.Faint) });
    }

    /// <summary>底部一行（`SessionFoot`）：顶上一根细线，左边「这场要练的 …」或一句提示，右边操作。</summary>
    public static void Foot(Canvas canvas, string? goal, UIElement? left, params UIElement[] right)
    {
        var grid = new Grid { Width = Width - 96, Height = 76 };
        grid.Children.Add(new Rectangle { Height = 1, Fill = Brush(MP.Line), VerticalAlignment = VerticalAlignment.Top });
        UIElement? lead = left;
        if (lead is null && goal is { Length: > 0 } g)
            lead = HStack(12, Sans("这场要练的", 13, MP.Fnt), Label(g, 13, MP.Ink, Medium).Also(t => { t.TextTrimming = TextTrimming.CharacterEllipsis; t.MaxWidth = 700; }));
        if (lead is FrameworkElement l) { l.VerticalAlignment = VerticalAlignment.Top; l.HorizontalAlignment = HorizontalAlignment.Left; l.Margin = new Thickness(0, 25, 0, 0); grid.Children.Add(l); }
        if (right.Length > 0)
        {
            var row = HStack(20, right);
            foreach (var item in right) if (item is FrameworkElement element) element.VerticalAlignment = VerticalAlignment.Center;
            row.Height = 38; row.HorizontalAlignment = HorizontalAlignment.Right; row.VerticalAlignment = VerticalAlignment.Top; row.Margin = new Thickness(0, 16, 0, 0);
            grid.Children.Add(row);
        }
        Put(canvas, grid, 48, 740);
    }

    /// <summary>这段回答（`AnswerFeedback`）：语速、长停顿、口头禅、面试官记下几处；都没有时返回 null。</summary>
    public static FrameworkElement? AnswerFeedback(JsonNode? feedback, int notes)
    {
        var voice = feedback is JsonObject ? feedback : null;
        if (voice is null && notes <= 0) return null;
        var row = HStack(22, Sans("这段回答", 13, MP.Fnt));
        static FrameworkElement Item(long value, string unit, string label, Color? tone = null) =>
            HStack(0, Serif(value.ToString(), 20, tone ?? MP.Ink), Sans($" {unit}  {label}", 13, tone ?? MP.Fnt).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 3));
        if (voice is not null)
        {
            var pace = voice.Text("pace");
            row.Children.Add(Item(voice.Integer("chars_per_minute"), "字/分", pace switch { "slow" => "语速偏慢", "ok" => "语速合适", "fast" => "语速偏快", _ => "" }, pace == "ok" ? null : MP.Orange));
            row.Children.Add(Item(voice.Integer("long_pauses"), "次", "长停顿"));
            if (voice.Text("filler").NonEmpty() is { } filler && (voice.Integer("filler_count")) > 0)
                row.Children.Add(Item(voice.Integer("filler_count"), "次", $"“{filler}”偏多", MP.Orange));
        }
        if (notes > 0) row.Children.Add(Item(notes, "处", "面试官记下", MP.Blue));
        return row;
    }

    /// <summary>`FinishStats`：结束确认里的三个数（题、次追问、用时）。</summary>
    public static FrameworkElement FinishStats(JsonNode? detail)
    {
        var rounds = MockMap.Rounds(detail).Where(r => !r.Intro).ToList();
        var answered = rounds.Count(r => r.Main.Text("answer_status") != "pending");
        var follows = detail.Items("questions").Count(q => q.Text("kind") == "follow_up");
        static FrameworkElement Stat(string value, string label) => VStack(0, Serif(value, 24, MP.Ink).Frame(height: 32), Sans(label, 13, MP.Fnt).Frame(height: 20));
        return HStack(72, Stat($"{answered} / {detail.Integer("question_count")}", "题"), Stat(follows.ToString(), "次追问"), Stat(MockSessionText.Elapsed(detail), "用时")).Top(16);
    }

    /// <summary>思考中的三个点：依次闪一下蓝。</summary>
    public static void ThinkDots(Canvas canvas)
    {
        var dots = Enumerable.Range(0, 3).Select(_ => new Ellipse { Width = 8, Height = 8, Fill = Brush(MP.Faint) }).ToArray();
        var row = HStack(8, dots);
        row.Width = Width; row.HorizontalAlignment = HorizontalAlignment.Center;
        var host = new Grid { Width = Width, Children = { row.Align(HorizontalAlignment.Center) } };
        AutomationProperties.SetAccessibilityView(host, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        var start = DateTime.UtcNow;
        timer.Tick += (_, _) =>
        {
            var t = (DateTime.UtcNow - start).TotalSeconds;
            for (var i = 0; i < 3; i++)
            {
                var phase = (((t - i * 0.2) % 1.2) + 1.2) % 1.2 / 1.2;
                dots[i].Fill = Brush(phase is > 0.1 and < 0.3 ? MP.Blue : MP.Faint);
            }
        };
        host.Loaded += (_, _) => timer.Start();
        host.Unloaded += (_, _) => timer.Stop();
        Put(canvas, host, 0, 366);
    }

    /// <summary>一个绑在页面生命周期上的定时器（页面卸下就停）。</summary>
    public static DispatcherTimer Every(FrameworkElement owner, TimeSpan interval, Action tick)
    {
        var timer = new DispatcherTimer { Interval = interval };
        timer.Tick += (_, _) => tick();
        owner.Loaded += (_, _) => timer.Start();
        owner.Unloaded += (_, _) => timer.Stop();
        if (owner.IsLoaded) timer.Start();
        return timer;
    }
}

internal static class MockSessionText
{
    static readonly Dictionary<string, string> Source = new() { ["resume"] = "来自你的简历", ["job"] = "来自岗位要求", ["material"] = "来自你的资料" };

    public static string Who(JsonNode? detail) =>
        string.Join(" · ", new[] { detail.Text("company_name"), detail.Text("stage_label") }.Where(s => s.Length > 0)).NonEmpty() ?? detail.Text("resume_title");

    public static bool IsIntro(JsonNode? detail, JsonNode question) => question.Text("anchor_kind") == "intro" || MockMap.IsIntro(detail, question);

    /// <summary>大字题目上面那一行（`questionEyebrow`）。</summary>
    public static string Eyebrow(JsonNode? detail, JsonNode? question)
    {
        if (question is null) return "";
        if (MockMap.IsIntro(detail, question)) return "开场 · 自我介绍";
        var rounds = MockMap.Rounds(detail).Where(r => !r.Intro).ToList();
        var round = MockSession.RoundOf(detail, question);
        var index = round is null ? -1 : rounds.FindIndex(r => r.Main.Display("id") == round.Main.Display("id"));
        if (index < 0) index = rounds.Count - 1;
        if (question.Text("kind") == "follow_up")
        {
            var at = round?.Turns.FindIndex(t => t.Display("id") == question.Display("id")) ?? 1;
            return $"第 {index + 1} 题 · 追问 {Math.Max(1, at)}";
        }
        return string.Join(" · ", new[] { $"第 {index + 1} 题", $"共 {detail.Integer("question_count")} 题", Source.GetValueOrDefault(question.Text("anchor_kind")) }.Where(s => !string.IsNullOrEmpty(s)));
    }

    /// <summary>思考界面的眉题：哪一题，加这一题的结果，不再说题目来源。</summary>
    public static string ThinkingEyebrow(JsonNode? detail, JsonNode? question, bool skipped)
    {
        var done = skipped ? "已跳过" : "你答完了";
        var asked = Eyebrow(detail, question);
        if (question is not null && question.Text("kind") == "main" && Source.ContainsKey(question.Text("anchor_kind")) && !MockMap.IsIntro(detail, question))
            return string.Join(" · ", asked.Split(" · ").Take(2)) + " · " + done;
        return asked.Length == 0 ? done : $"{asked} · {done}";
    }

    /// <summary>把回答切成普通段和被面试官记下的原话段；找不到的原话跳过，重叠的只留先出现的。</summary>
    public static List<(string Text, bool Marked)> QuoteSegments(string text, IEnumerable<string> quotes)
    {
        var ranges = quotes.Where(q => q.Length > 0).Select(q => (Start: text.IndexOf(q, StringComparison.Ordinal), q.Length)).Where(r => r.Start >= 0).OrderBy(r => r.Start).ToList();
        var segments = new List<(string, bool)>();
        var at = 0;
        foreach (var (start, length) in ranges)
        {
            if (start < at) continue;
            if (start > at) segments.Add((text[at..start], false));
            segments.Add((text.Substring(start, length), true));
            at = start + length;
        }
        if (at < text.Length) segments.Add((text[at..], false));
        return segments;
    }

    public static string Elapsed(JsonNode? detail) =>
        Json.Date(detail.Text("started_at")) is { } started ? MockSession.Mmss((DateTimeOffset.UtcNow - started).TotalSeconds) : "00:00";
}

/// <summary>回合 SSE（整段返回）：笔记、面试官的话（delta 拼起来）、语音片段、最后的 turn。</summary>
internal sealed class MockTurn
{
    public readonly List<(string Question, JsonNode Notes)> Notes = [];
    public readonly List<JsonNode?> Events;
    public string Spoken = "";
    public bool AudioFailed, RecordingDropped, HasAudio;
    public JsonNode? Feedback;
    public JsonNode? End;

    public MockTurn(JsonNode result)
    {
        Events = result.Items("events").Cast<JsonNode?>().ToList();
        foreach (var e in Events)
        {
            var data = e.Get("data");
            switch (e.Text("event"))
            {
                case "interviewer.notes": Notes.Add((data.Display("question_id"), data.Get("notes")?.DeepClone() ?? new JsonArray())); break;
                case "interviewer.delta": Spoken += data.Text("content"); break;
                case "interviewer.audio": HasAudio = true; break;
                case "interviewer.audio_failed": AudioFailed = true; break;
                case "answer.accepted":
                    if (data.Bool("recording_dropped")) RecordingDropped = true;
                    Feedback = data.Get("feedback")?.DeepClone();
                    break;
                case "interviewer.turn": End = data?.DeepClone(); break;
            }
        }
    }

    public bool Finished => End.Text("action") == "finish" || End.Get("question") is not JsonObject;
}

/// <summary>场次 JSON 的本地改动：记下笔记、标记已答、接上下一题。</summary>
internal static class MockDetailEdit
{
    public static JsonNode Questions(JsonNode detail, Func<JsonNode, JsonNode?> map)
    {
        var copy = detail.DeepClone();
        if (copy["questions"] is JsonArray list)
            for (var i = 0; i < list.Count; i++)
                if (list[i] is { } q && map(q) is { } next && !ReferenceEquals(next, q)) list[i] = next;
        return copy;
    }

    public static JsonNode WithNotes(JsonNode detail, string question, JsonNode notes) =>
        Questions(detail, q => { if (q.Display("id") != question) return null; var c = q.DeepClone(); c["notes"] = notes.DeepClone(); return c; });

    public static JsonNode Answered(JsonNode detail, string question, string text) =>
        Questions(detail, q => { if (q.Display("id") != question) return null; var c = q.DeepClone(); c["answer_status"] = "answered"; c["answer_text"] = text; return c; });

    public static JsonNode AppendTurn(JsonNode detail, JsonNode end)
    {
        if (end.Get("question") is not JsonObject next) return detail;
        var copy = detail.DeepClone();
        if (copy["questions"] is not JsonArray list) copy["questions"] = list = [];
        if (!list.Any(q => q.Display("id") == next.Display("id"))) list.Add(next.DeepClone());
        copy["current_question_id"] = next["id"]?.DeepClone();
        copy["needs_reply"] = false;
        return copy;
    }

    public static string Key() => Guid.NewGuid().ToString().ToLowerInvariant();
}

/// <summary>面试中的三个确认（跳过此题、结束并评估、放弃）：文字和语音面试共用。</summary>
internal static class MockSessionDialogs
{
    public static void Skip(XamlRoot root, Action skip) =>
        MP.Confirm(root, "跳过这道题？", "跳过的部分记为没答，面试官会换下一个考点；前面已经答的照常评分。", "跳过此题", skip, "继续作答");

    public static void Finish(XamlRoot root, JsonNode? detail, Action finish)
    {
        if (MockSession.HasAnswered(detail))
            MP.Confirm(root, "结束并生成评估？", "已作答的题目会进入评估，后面没问到的题不扣分。", "结束并评估", finish, "继续面试", MockFull.FinishStats(detail));
        else
            MP.Confirm(root, "结束这场面试？", "你还没有回答任何考点，结束后这场记为已放弃，不生成报告。", "结束这场", finish, "继续面试");
    }

    public static void Abandon(XamlRoot root, bool voice, Action abandon) =>
        MP.Confirm(root, "放弃这场面试？", voice ? "已作答的内容不会生成评估报告，录音会删除。放弃后可以重新开始一场。" : "已作答的内容不会生成评估报告。放弃后可以重新开始一场。", "放弃面试", abandon, "继续面试");
}
