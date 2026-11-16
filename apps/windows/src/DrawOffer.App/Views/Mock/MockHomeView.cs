using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Views.Resumes;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

/// <summary>
/// 模拟面试首页（Windows 稿 09 · 01：01.01 没有简历 / 01.02 有简历没面试 / 01.03–01.05 一到多条记录；Mac `MockHomeV2`、Web `v2/MockHome.tsx`）。
/// 五个状态共用一个骨架：页头写结论、操作放右上，中间固定三行录音时间线，分隔线下是四列摘要。
/// </summary>
public sealed class MockHomeView : UserControl
{
    static readonly string[] CountWord = ["", "一", "两", "三", "四", "五", "六", "七", "八", "九"];
    static readonly string[] StopLabel = ["", "停在这里", "两次都停在这里", "每次都停在这里"];
    static readonly double[] RowOpacity = [1, 0.75, 0.5], GhostFade = [0.5, 0.25, 0.12], EmptyFade = [0.6, 0.32, 0.14];
    const double QuoteW = 263, MetaW = 154;

    readonly Action<string> _open;
    readonly Action _records, _resumes, _config;
    readonly MockViewLifetime _life;
    JsonNode? _overview;
    List<JsonNode> _list = [], _resumeList = [];
    bool _loaded, _failed;
    string? _waitingId;
    readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromSeconds(5) };
    readonly Border _host = new();
    double _width = 900, _height = 900;

    public MockHomeView(Action<string> open, Action records, Action resumes, Action config)
    {
        (_open, _records, _resumes, _config) = (open, records, resumes, config);
        _life = new MockViewLifetime(this, () => { _overview = null; _list = []; Render(); });
        var scroll = new ScrollViewer { Content = _host, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        scroll.SizeChanged += (_, e) =>
        {
            if (Math.Abs(e.NewSize.Width - _width) < 1 && Math.Abs(e.NewSize.Height - _height) < 1) return;
            (_width, _height) = (e.NewSize.Width, e.NewSize.Height);
            Render();
        };
        Content = scroll;
        Background = Brush(V3.White);
        _poll.Tick += async (_, _) => await LoadAsync();
        Unloaded += (_, _) => _poll.Stop();
        Loaded += async (_, _) => await LoadAsync();
        Render();
    }

    JsonNode? Active => _list.FirstOrDefault(x => x.Text("status") is "in_progress" or "preparing");
    JsonNode? Recent => _list.OrderByDescending(x => x.Text("created_at"), StringComparer.Ordinal).FirstOrDefault();
    JsonNode? Evaluating => Recent is { } recent && recent.Text("status") is "evaluating" or "evaluation_failed" ? recent : null;
    JsonNode? Blocking => Active ?? Evaluating;

    string StartLabel(string idle) => Active is not null ? "继续这一场" : Evaluating is not null ? "看上一场" : idle;

    void Start()
    {
        if (Blocking is { } blocking) _open(blocking.Text("id")); else _config();
    }

    void Render()
    {
        var gutter = V3Page.Gutter(_width);
        var width = Math.Max(0, _width - gutter * 2);
        // 行高跟着内容高度走：900 高是设计稿的 114，高屏把多出来的高度分给时间线
        var runH = Math.Min(200, Math.Max(120, (_height - 528) / 2));
        var page = new StackPanel { Width = width, HorizontalAlignment = HorizontalAlignment.Left };
        _host.Padding = new Thickness(gutter, 52, gutter, 60);
        _host.Child = page;

        if (_overview is { } overview && _loaded)
        {
            var finished = overview.Get("counts").Integer("mock") + overview.Get("counts").Integer("real");
            var reviewing = overview.Items("records").Any(x => x.Text("status") == "reviewing");
            if (_resumeList.Count == 0)
            {
                page.Children.Add(Head(overview, "先放一份简历，面试官按它出题。", "面试里的问题，都从你写的经历来。\n没有现成的，现在写一份也可以。", "支持 PDF、Word、Markdown", width,
                    MP.Ghost("写第一份简历", _resumes, 40), MP.Dark("导入简历", ImportResume, 40)));
                page.Children.Add(GhostRuns(runH));
                page.Children.Add(MockTally.Section("有了简历，练完这里会记下", EmptyTallies, width).Top(0));
            }
            else if (finished == 0)
            {
                page.Children.Add(Head(overview, "先有一场面试，才知道该练什么。", "练一场，或者导入面过的一场。\n之后每一场，都从你卡住的地方接着问。",
                    reviewing ? "导入的面试正在生成复盘，好了会出现在这里。" : "录音或文字稿都可以导入。", width,
                    MP.Ghost("导入面试记录", Import, 40), MP.Dark(StartLabel("开始第一场模拟面试"), Start, 40)));
                page.Children.Add(GhostRuns(runH));
                page.Children.Add(MockTally.Section("练完第一场，这里会记下", EmptyTallies, width));
            }
            else
            {
                var stuck = overview.Get("stuck") is JsonObject s ? s : null;
                page.Children.Add(Head(overview, stuck is null ? "这几场没有卡住的地方。" : StuckTitle(stuck),
                    stuck is not null ? "这场从这里接着问，答过去就不用再练了。" : "下一场换个方向，继续往深处问。", null, width,
                    MP.Ghost("导入面试记录", Import, 40), MP.Dark(StartLabel("开始这一场"), Start, 40)));
                page.Children.Add(StuckRuns(stuck, runH));
                page.Children.Add(MockTally.Section($"这 {finished} 场记下的", Tallies(overview), width, _records));
            }
        }
        else if (_failed)
        {
            page.Children.Add(Head(null, "模拟面试", null, null, width));
            page.Children.Add(VStack(12, Label("模拟面试没有加载出来", 28, MP.Ink, Semibold), Sans("请检查网络后重试。", 13, MP.Fnt),
                MP.Ghost("重新加载", () => _ = LoadAsync()).Also(b => b.HorizontalAlignment = HorizontalAlignment.Left)).Top(12));
        }
        else page.Children.Add(new V3Loading("正在加载模拟面试…") { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 160, 0, 0) });
    }

    /// <summary>`.mi3-home-head`：左边眉题、标题、说明，右边操作（下面一行小字）；窄于 640 时操作换到下面。</summary>
    static FrameworkElement Head(JsonNode? overview, string title, string? desc, string? note, double width, params UIElement[] actions)
    {
        var counts = overview is null ? "" : CountLine(overview);
        var copy = VStack(0,
            Sans(string.Join(" · ", new[] { "MOCK INTERVIEWS", counts }.Where(x => x.Length > 0)), 12, MP.Fnt, Medium).Frame(height: 18),
            Label(title, 28, MP.Ink, Semibold).LineHeight(36).Wrap().Top(8));
        if (desc is not null) copy.Children.Add(Sans(desc, 14, MP.Sub).LineHeight(22).Wrap().Top(6));
        var narrow = width < 640;
        var side = VStack(9, HStack(10, actions).Also(r => r.HorizontalAlignment = narrow ? HorizontalAlignment.Left : HorizontalAlignment.Right));
        if (note is not null) side.Children.Add(Sans(note, 13, MP.Fnt).Frame(height: 20).Also(t => t.HorizontalAlignment = narrow ? HorizontalAlignment.Left : HorizontalAlignment.Right));
        FrameworkElement head = narrow
            ? VStack(16, copy, side)
            : Columns(24, (Star(), copy), (Auto, side.Top(30)));
        head.MinHeight = 112;
        return head;
    }

    // 时间线

    static FrameworkElement GhostRuns(double runH)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 40, 0, 0) };
        for (var i = 0; i < 3; i++) stack.Children.Add(GhostRow(EmptyFade[i], i, i == 2 ? 126 : runH));
        return stack;
    }

    static FrameworkElement GhostRow(double opacity, int shift, double height)
    {
        var meta = VStack(8,
            new Border { Width = 42, Height = 6, CornerRadius = new CornerRadius(3), Background = Brush(MP.Cl), HorizontalAlignment = HorizontalAlignment.Left },
            new Border { Width = 66, Height = 5, CornerRadius = new CornerRadius(2.5), Background = Brush(MP.Line), HorizontalAlignment = HorizontalAlignment.Left }).Top(11);
        var wave = MockWave.Ghost(shift);
        wave.Margin = new Thickness(0, -11, 25, 0);
        wave.VerticalAlignment = VerticalAlignment.Top;
        var row = Columns(0, (Px(MetaW), meta), (Star(), wave), (Px(QuoteW), new Border()));
        row.Height = height;
        row.Opacity = opacity;
        return row;
    }

    static FrameworkElement StuckRuns(JsonNode? stuck, double runH)
    {
        var records = stuck.Items("records").TakeLast(3).Reverse().ToList();
        var rows = records.Count;
        var stack = new StackPanel { Margin = new Thickness(0, 28, 0, 0) };
        for (var i = 0; i < rows; i++)
        {
            var record = records[i];
            var meta = VStack(0, Label(Mmdd(record.Text("date")), 14, MP.Ink, Medium).Frame(height: 22),
                Sans(record.Text("title").NonEmpty() ?? (record.Text("kind") == "real" ? "真实面试" : "模拟练习"), 13, MP.Fnt).Also(t => { t.TextTrimming = TextTrimming.CharacterEllipsis; t.MaxWidth = 146; }).Frame(height: 20));
            var wave = MockWave.Row($"{record.Text("date")}:{i}", RowOpacity[i]);
            wave.Margin = new Thickness(0, -9, 15, 0);
            wave.VerticalAlignment = VerticalAlignment.Top;
            FrameworkElement quote = record.Text("quote").NonEmpty() is { } q
                ? Sans($"“{q}……”", 13, i == 0 ? MP.Ink : MP.Fnt).LineHeight(20).Wrap().Top(11)
                : new Border();
            var row = Columns(0, (Px(MetaW), meta), (Star(), wave), (Px(QuoteW), quote));
            row.Height = rows == 3 && i == 2 ? 126 : runH;
            stack.Children.Add(row);
        }
        for (var i = 0; i < 3 - rows; i++) stack.Children.Add(GhostRow(GhostFade[i], i, rows + i == 2 ? 126 : runH));
        var layer = new Grid { Margin = new Thickness(0, 12, 0, 0) };
        layer.Children.Add(stack);
        if (rows > 0)
        {
            // 「停在这里」那条竖线：落在声纹右端与原话之间
            layer.Children.Add(new Rectangle
            {
                Width = 1, Height = runH * (rows - 1) + 63, Fill = Brush(MP.Cl), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 24, QuoteW + 7.5, 0),
            });
            var label = Label(StopLabel[rows], 12.5, MP.Sub, Medium);
            label.HorizontalAlignment = HorizontalAlignment.Right;
            label.VerticalAlignment = VerticalAlignment.Top;
            label.TextAlignment = TextAlignment.Center;
            label.RenderTransform = new Microsoft.UI.Xaml.Media.TranslateTransform();
            label.Margin = new Thickness(0, 0, QuoteW + 8, 0);
            label.SizeChanged += (_, e) => ((Microsoft.UI.Xaml.Media.TranslateTransform)label.RenderTransform).X = e.NewSize.Width / 2;
            layer.Children.Add(label);
        }
        return layer;
    }

    // 摘要

    static readonly MockTally[] EmptyTallies =
    [
        new("–", null, "不用再练", "答好的地方，之后就不再问。"),
        new("–", null, "还要补", "卡住的地方，下一场接着问。"),
        new("–", null, "回答习惯", "看你是先说结论，还是被追问才讲做法。"),
        new("–", null, "分数变化", "每一场的分数都记在这里。"),
    ];

    static List<MockTally> Tallies(JsonNode overview)
    {
        var counts = overview.Get("counts");
        var t = overview.Get("tallies");
        var first = counts.Integer("mock") + counts.Integer("real") <= 1;
        var cleared = t.Get("cleared");
        var open = t.Get("open");
        var late = t.Get("late");
        static string Examples(JsonNode? value) => string.Join("、", value.Items("examples").Select(x => x is JsonValue v && v.TryGetValue<string>(out var s) ? s : "").Where(x => x.Length > 0));
        var items = new List<MockTally>
        {
            cleared.Integer("count") > 0
                ? new($"{cleared.Integer("count")}", "处", first ? "答好了" : "不用再练", Examples(cleared), Dot: MP.Blue)
                : new("0", "处", first ? "答好了" : "不用再练", "答好的地方，之后就不再问。"),
            open.Integer("count") > 0
                ? new($"{open.Integer("count")}", "处", "还要补", Examples(open), Dot: MP.Orange)
                : new("0", "处", "还要补", "这几场没有留下要补的地方。"),
        };
        var lateCount = late.Integer("count");
        if (first || late.Integer("total") == 0) items.Add(new("1", "场后", "看出回答习惯", "再练一场，就能看出来。"));
        else items.Add(new($"{lateCount}", "场", "被追问才讲做法", lateCount == 0 ? "每场都先说了结论，保持这个习惯。" : "这场试试先说结论。"));
        if (t.Get("score") is JsonObject score)
        {
            int latest = score.Integer("latest"), start = score.Integer("first"), count = score.Integer("count");
            var diff = latest - start;
            items.Add(count <= 1
                ? new($"{latest}", "分", "第一场", "下一场开始，看得到进步。")
                : new($"{latest}", "分", diff >= 0 ? $"+{diff}" : $"{diff}", $"从 {start} 分{(count > 2 ? "练" : "")}到 {latest} 分，一共 {count} 场。", Tone: diff >= 0 ? MP.Blue : MP.Orange));
        }
        return items;
    }

    static string StuckTitle(JsonNode stuck)
    {
        var topic = stuck.Text("topic");
        var times = stuck.Get("times") is null ? 1 : stuck.Integer("times");
        if (times >= 2) return $"{topic}，你{(times < CountWord.Length ? CountWord[times] : $"{times}")}次都停在同一处。";
        if (stuck.Text("detail").NonEmpty() is not { } detail) return $"{topic}，你上次停在了这里。";
        var spaced = char.IsAscii(detail[0]) && char.IsLetterOrDigit(detail[0]);
        return $"{topic}，你停在了{(spaced ? " " : "")}{detail}这一步。";
    }

    static string CountLine(JsonNode overview)
    {
        int real = overview.Get("counts").Integer("real"), mock = overview.Get("counts").Integer("mock");
        return string.Join(" · ", new[] { real > 0 ? $"面了 {real} 场" : null, mock > 0 ? $"练了 {mock} 场" : null }.OfType<string>());
    }

    static string Mmdd(string value) => CareerApplication.Date(value) is { } date ? date.ToBeijing().ToString("MM-dd") : "";

    // 命令

    void Import() => MockImportDialog.Show(XamlRoot, () =>
    {
        MP.Notice("已开始生成复盘", "好了会出现在这里，也会记进长期记忆");
        _ = LoadAsync();
    });

    void ImportResume() => ResumeImportSheet.Show(XamlRoot, title =>
    {
        MP.Notice("已开始导入", $"「{title}」解析完成后这里会更新");
        _ = LoadAsync();
    });

    async Task LoadAsync()
    {
        if (App.Session.User is null) return;
        try
        {
            var overview = _life.Request("/api/mock-interviews/overview");
            var list = _life.Request("/api/mock-interviews", query: new() { ["limit"] = "100" });
            var resumes = _life.Request("/api/resumes");
            await Task.WhenAll(overview, list, resumes);
            _overview = overview.Result;
            _list = list.Result.Items("items");
            _resumeList = resumes.Result.Items("resumes");
            _loaded = true;
            _failed = false;
        }
        catch (OperationCanceledException) { return; }
        catch (Exception) { if (!_loaded) _failed = true; }
        // 评估中：5 秒刷新一次，好了提示一下
        if (Evaluating is { } evaluating && evaluating.Text("status") == "evaluating") { _waitingId = evaluating.Text("id"); _poll.Start(); }
        else
        {
            _poll.Stop();
            if (_waitingId is { } id && _list.Any(x => x.Text("id") == id && x.Text("status") == "completed"))
            {
                _waitingId = null;
                MP.Notice("评估报告好了", "这场的分数和卡住的地方已经更新");
            }
        }
        Render();
    }
}
