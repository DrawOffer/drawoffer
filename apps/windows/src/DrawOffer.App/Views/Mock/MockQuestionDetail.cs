using DrawOffer.App.DesignSystem;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

/// <summary>
/// 单题详情（Windows 稿 09 · 10.05 没答好、10.06 答到位；Mac `MockQuestionDetail`、Web `interviews/report/ReviewQuestion.tsx`）：
/// 左边完整问答（原话里出问题的地方划线），右边面试官想听到什么、可以这样说 / 亮点、这道题的几次；可以回放录音、修改识别稿、判得不对。
/// </summary>
internal sealed class MockQuestionDetail : UserControl
{
    readonly MockRV.Question _q;
    readonly int _total;
    readonly MockRV.Question? _prev, _next;
    readonly Action<string> _open;
    readonly Action<MockRV.Question> _practice, _record;
    readonly Action<MockRV.Question>? _judge, _edit, _play;
    readonly bool _playing;
    readonly FrameworkElement _crumb;
    readonly StackPanel _page = new();
    double _width;

    public MockQuestionDetail(MockRV.Question question, int total, MockRV.Question? prev, MockRV.Question? next, Action<string> open,
        Action<MockRV.Question> practice, Action<MockRV.Question> record, Action<MockRV.Question>? judge, Action<MockRV.Question>? edit,
        Action<MockRV.Question>? play, bool playing, FrameworkElement crumb)
    {
        (_q, _total, _prev, _next, _open, _practice, _record, _judge, _edit, _play, _playing, _crumb) =
            (question, total, prev, next, open, practice, record, judge, edit, play, playing, crumb);
        Background = Brush(V3.White);
        Content = new V3Page(_page, 46);
        _page.SizeChanged += (_, e) => { var wide = e.NewSize.Width >= 820; if (wide != _width >= 820 || _width == 0) { _width = e.NewSize.Width; Render(); } else _width = e.NewSize.Width; };
        Render();
    }

    void Render()
    {
        _page.Children.Clear();
        if (_crumb.Parent is Panel old) old.Children.Remove(_crumb);
        var level = _q.Level ?? 0;
        var tag = _q.Recovered ? "上次没过，这次答到了" : MockRV.RepeatTag(_q);
        var meta = string.Join(" · ", new[] { $"第 {_q.No} 题", MockRV.OutcomeText(_q), _q.Score is { } s ? $"{s} 分" : null, tag }.Where(x => x is not null));
        var pager = HStack(12,
            MP.Link("‹ 上一题", () => { if (_prev is not null) _open(_prev.Id); }, enabled: () => _prev is not null),
            Sans($"{_q.No} / {_total}", 13, RRC.Sub),
            MP.Link("下一题 ›", () => { if (_next is not null) _open(_next.Id); }, enabled: () => _next is not null));
        pager.VerticalAlignment = VerticalAlignment.Center;
        var right = HStack(24, pager);
        if (_q.Weak) right.Children.Add(MP.Dark("练这一处", () => _practice(_q), 40));
        _page.Children.Add(Columns(24, (Star(), _crumb.Top(6)), (Auto, right.Frame(height: 40))));
        _page.Children.Add(Serif(_q.Title, 28, RRC.Ink).LineHeight(36).Wrap().Top(6));
        _page.Children.Add(Sans(meta, 14, RRC.Text).Frame(height: 22).Top(4));
        _page.Children.Add(Label(MockRV.DepthSentence(_q), 13, RRC.Ink, Medium).Frame(height: 20).Top(22));
        _page.Children.Add(Depth(level));
        var talk = Talk();
        var side = Side(_q.History ?? []);
        _page.Children.Add((_width == 0 || _width >= 820
            ? (FrameworkElement)Columns(40, (new GridLength(620, GridUnitType.Star), talk), (new GridLength(395, GridUnitType.Star), side))
            : VStack(32, talk, side)).Top(20));
    }

    /// <summary>五层深度：答到的几层深色，当前层加粗，目标层一根竖线。</summary>
    FrameworkElement Depth(int level)
    {
        var grid = new Grid { ColumnSpacing = 8, Height = 30 };
        for (var i = 0; i < 5; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            var current = i + 1 == level;
            var cell = VStack(7,
                new Rectangle { Height = 5, RadiusX = 2.5, RadiusY = 2.5, Fill = Brush(i < level ? RRC.Text : RRC.Thin) },
                Sans(MockRV.Levels[i], 12, current ? RRC.Ink : RRC.Faint, current ? Medium : null));
            Grid.SetColumn(cell, i);
            grid.Children.Add(cell);
        }
        // 目标层：那一格右边一根竖线
        var target = Math.Clamp(_q.Expected, 1, 5);
        var mark = new Rectangle { Width = 2, Height = 13, Fill = Brush(RRC.Ink), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, -4, -5, 0) };
        Grid.SetColumn(mark, target - 1);
        grid.Children.Add(mark);
        return new Border { Child = grid, Padding = new Thickness(0, 10, 0, 16), BorderBrush = Brush(RRC.Thin), BorderThickness = new Thickness(0, 0, 0, 1) };
    }

    FrameworkElement Talk()
    {
        var stack = VStack(0, Sans("完整问答", 12, RRC.Sub).Frame(height: 18).Pad(0, 0, 0, 10));
        foreach (var turn in _q.Turns)
        {
            var marks = MockRV.Marks(_q, turn.Answer);
            stack.Children.Add(Say("面试官", Label(turn.Ask, 14, RRC.Ink, Medium).LineHeight(24).Wrap()));
            stack.Children.Add(Say("你", turn.Answer is { } answer ? RRC.Marked(answer, marks, RRC.Text) : Sans(turn.Missing, 14, RRC.Faint).LineHeight(24)));
            foreach (var mark in marks)
                stack.Children.Add(Sans("问题在这：" + MockRV.MarkText(mark), 12, RRC.Orange).LineHeight(18).Wrap().Pad(64, -8, 0, 14));
        }
        var links = HStack(24);
        if (_play is not null) links.Children.Add(MP.Link(_playing ? "暂停播放" : "播放这段录音", () => _play(_q), blue: true));
        if (_edit is not null) links.Children.Add(MP.Link("修改识别稿", () => _edit(_q), blue: true));
        links.Children.Add(MP.Link("在面试记录里打开", () => _record(_q), blue: true));
        stack.Children.Add(links.Pad(64, 6, 0, 0));
        return stack;
    }

    static FrameworkElement Say(string who, FrameworkElement content) =>
        Columns(0, (new GridLength(64), Sans(who, 13, RRC.Sub).Frame(height: 22).Align(v: VerticalAlignment.Top)), (Star(), content)).Pad(0, 0, 0, 14);

    FrameworkElement Side(List<MockRV.History> history)
    {
        var stack = VStack(24);
        if (_q.Signals.Count > 0)
        {
            var rows = VStack(0);
            foreach (var signal in _q.Signals)
            {
                var miss = signal.State == "miss";
                var state = signal.State switch { "hit" => "说到了", "partial" => "说了一半", "miss" => "没说到", _ => "" };
                rows.Children.Add(Columns(16, (Star(), Sans(signal.Label, 13, miss ? RRC.Ink : RRC.Text).Wrap()), (Auto, Sans(state, 12, miss ? RRC.Orange : RRC.Sub, miss ? Medium : null))).Pad(0, 0, 0, 10));
            }
            stack.Children.Add(Section("面试官想听到什么", rows));
        }
        if (_q.Weak && _q.Better is { } better) stack.Children.Add(Section("可以这样说", Sans(better, 13, RRC.Text).LineHeight(22).Wrap()));
        else if (!_q.Weak && _q.Highlight is { } highlight) stack.Children.Add(Section("亮点", Sans(highlight, 13, RRC.Text).LineHeight(22).Wrap()));
        if (history.Count > 1)
        {
            var rows = VStack(8);
            foreach (var item in history)
            {
                var color = item.Current ? RRC.Ink : RRC.Sub;
                rows.Children.Add(Columns(8,
                    (new GridLength(60), Sans(item.Date, 13, color, item.Current ? Medium : null)),
                    (Star(), Sans(item.Title, 13, color).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis)),
                    (Auto, Sans(item.Result, 13, color))).Frame(height: 22));
            }
            stack.Children.Add(Section($"这道题的 {history.Count} 次", rows));
        }
        if (_judge is not null) stack.Children.Add(MP.Link("判得不对？", () => _judge(_q), blue: true).Also(t => t.HorizontalAlignment = HorizontalAlignment.Left));
        return stack;
    }

    static FrameworkElement Section(string title, FrameworkElement content) =>
        VStack(0, Sans(title, 12, RRC.Sub).Frame(height: 18).Pad(0, 0, 0, 10), content);
}

/// <summary>判得不对（Windows 稿 09 · 10.07）：选你觉得答到的那一层；选回 AI 判的那一层就是撤销。</summary>
internal static class MockJudgeDialog
{
    public static void Show(XamlRoot root, MockRV.Question q, Action<int?> save)
    {
        var options = q.Layered
            ? MockRV.Levels.Select((name, i) => (i + 1, name)).ToList()
            : new List<(int, string)> { (Math.Max(0, q.Expected - 2), "没说清"), (Math.Max(1, q.Expected - 1), "说了一半"), (q.Expected, "说清了") };
        var current = q.Level ?? q.AiLevel ?? options[0].Item1;
        var picked = options.Any(o => o.Item1 == current) ? current : options[0].Item1;
        var ai = q.AiLevel;
        var aiText = ai is { } a ? a <= 0 ? "没到「了解」" : q.Layered ? $"「{MockRV.LevelLabel(a)}」" : null : null;
        var seg = new V3Segmented<int>(options, picked, height: 32, fontSize: 13);
        seg.Changed += value => picked = value;
        var extra = VStack(10, seg);
        if (aiText is not null) extra.Children.Add(Sans($"AI 判的是{aiText}", 12, MP.Fnt));
        MP.Confirm(root, "这题判得不对？", "选你觉得答到的那一层，这题会按你的判断显示。", "按这个算", () => save(picked == ai ? null : picked), extra: extra.Top(16));
    }
}

/// <summary>修改识别稿（Windows 稿 09 · 10.08）：一轮回答一个输入框；还有重新评分次数时保存后这题重新评分。</summary>
internal static class MockEditDialog
{
    public static void Show(XamlRoot root, MockRV.Question q, int remaining, Action<Dictionary<string, string>> save)
    {
        var turns = q.Turns.Where(t => t.Editable).ToList();
        var boxes = new Dictionary<string, TextBox>();
        var stack = VStack(12);
        foreach (var turn in turns)
        {
            var box = new TextBox
            {
                Text = turn.Answer ?? "", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontFamily = SansFamily, FontSize = 14, MinHeight = 148,
                Background = Brush(MP.Chip), BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 10, 12, 10),
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, "修改识别稿");
            boxes[turn.Id] = box;
            var item = VStack(6);
            if (turns.Count > 1) item.Children.Add(Sans(turn.Ask, 12, MP.Fnt).Wrap());
            item.Children.Add(box);
            stack.Children.Add(item);
        }
        var scroll = new ScrollViewer { Content = stack, MaxHeight = 360, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 16, 0, 0) };
        MP.Confirm(root, "修改识别稿", remaining > 0 ? "只改听错的字，保存后这题会重新评分。" : "只改听错的字。这题的重新评分次数已用完，保存后只更新文字。",
            remaining > 0 ? "保存并重新评分" : "保存", () => save(boxes.ToDictionary(p => p.Key, p => p.Value.Text)), extra: scroll);
    }
}
