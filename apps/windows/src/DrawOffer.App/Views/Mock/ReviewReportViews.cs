using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace DrawOffer.App.Views.Mock;

/// <summary>面试复盘的配色（Windows 稿 09 · 10；Mac `RRC`、Web `interviews/report`）。</summary>
internal static class RRC
{
    public static readonly Color Blue = Hex(0x3F6FD8), Orange = Hex(0xC9651B), Ink = Hex(0x1D1D1B), Text = Hex(0x55554F), Sub = Hex(0x6C6C65),
        Faint = Hex(0xA9A9A3), Line = Hex(0xE4E4E0), Thin = Hex(0xECECEA), TargetLine = Hex(0xCFDCF5), Gray = Hex(0x96968F);

    /// <summary>白底、圆角 12、细边的盒子。</summary>
    public static Border Box(UIElement child, Thickness? padding = null) => new()
    {
        Child = child, Padding = padding ?? new Thickness(0), CornerRadius = new CornerRadius(12),
        Background = Brush(V3.White), BorderBrush = Brush(Line), BorderThickness = new Thickness(1),
    };

    /// <summary>`返回` 面包屑：← 标签。</summary>
    public static FrameworkElement Crumb(string label, Action action) =>
        HStack(6, Icon("arrow.left", 13, MP.Fnt), Sans(label, 16, MP.Fnt).Also(t => { t.MaxWidth = 520; t.TextTrimming = TextTrimming.CharacterEllipsis; }))
            .OnTap(action, "返回" + label).Also(c => c.HorizontalAlignment = HorizontalAlignment.Left);

    /// <summary>原话里出问题的部分划橙色下划线。</summary>
    public static TextBlock Marked(string text, IReadOnlyList<MockRV.Mark> marks, Color baseColor, double size = 14, double line = 24)
    {
        var block = new TextBlock { FontFamily = SansFamily, FontSize = size, LineHeight = line, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        var cursor = 0;
        foreach (var mark in marks.OrderBy(m => text.IndexOf(m.Quote, StringComparison.Ordinal) is var i and >= 0 ? i : int.MaxValue))
        {
            var at = text.IndexOf(mark.Quote, cursor, StringComparison.Ordinal);
            if (at < 0) continue;
            block.Inlines.Add(new Run { Text = text[cursor..at], Foreground = Brush(baseColor) });
            var underline = new Underline { Foreground = Brush(Orange) };
            underline.Inlines.Add(new Run { Text = mark.Quote });
            block.Inlines.Add(underline);
            cursor = at + mark.Quote.Length;
        }
        block.Inlines.Add(new Run { Text = text[cursor..], Foreground = Brush(baseColor) });
        return block;
    }
}

/// <summary>设计稿坐标里的一张图：按宽度等比缩放；画布左上角是 (x, y)。</summary>
internal sealed class RRChart
{
    public readonly Canvas Canvas;
    readonly double _x, _y;
    public RRChart(double x, double y, double width, double height) { (_x, _y) = (x, y); Canvas = new Canvas { Width = width, Height = height }; }
    public FrameworkElement View(string name)
    {
        var box = new Viewbox { Stretch = Stretch.Uniform, Child = Canvas, StretchDirection = StretchDirection.Both };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, name);
        return box;
    }
    Point P(Point p) => new(p.X - _x, p.Y - _y);

    public void Stroke(Geometry geometry, Color color, double width = 1, DoubleCollection? dash = null, Color? fill = null) =>
        Canvas.Children.Add(new Path { Data = geometry, Stroke = Brush(color), StrokeThickness = width, StrokeDashArray = dash, Fill = fill is { } f ? Brush(f) : null });
    public void Line(Point a, Point b, Color color, double width = 1, DoubleCollection? dash = null) =>
        Stroke(new LineGeometry { StartPoint = P(a), EndPoint = P(b) }, color, width, dash);
    public void Circle(Point c, double r, Color? stroke, Color? fill = null, double width = 1, DoubleCollection? dash = null) =>
        Canvas.Children.Add(new Path { Data = new EllipseGeometry { Center = P(c), RadiusX = r, RadiusY = r }, Stroke = stroke is { } s ? Brush(s) : null, StrokeThickness = width, StrokeDashArray = dash, Fill = fill is { } f ? Brush(f) : null });
    public void Rect(double x, double y, double w, double h, double radius, Color fill)
    {
        var rect = new Rectangle { Width = Math.Max(0, w), Height = Math.Max(0, h), RadiusX = radius, RadiusY = radius, Fill = Brush(fill) };
        Microsoft.UI.Xaml.Controls.Canvas.SetLeft(rect, x - _x); Microsoft.UI.Xaml.Controls.Canvas.SetTop(rect, y - _y);
        Canvas.Children.Add(rect);
    }
    public PathGeometry Poly(IEnumerable<Point> points, bool closed)
    {
        var list = points.Select(P).ToList();
        var figure = new PathFigure { StartPoint = list.FirstOrDefault(), IsClosed = closed };
        foreach (var p in list.Skip(1)) figure.Segments.Add(new LineSegment { Point = p });
        return new PathGeometry { Figures = { figure } };
    }
    public PathGeometry Curve(IReadOnlyList<Point> points)
    {
        Point At(int i) => P(points[(i + points.Count) % points.Count]);
        var figure = new PathFigure { StartPoint = At(0), IsClosed = false };
        for (var i = 0; i < points.Count; i++)
        {
            Point p0 = At(i - 1), p1 = At(i), p2 = At(i + 1), p3 = At(i + 2);
            figure.Segments.Add(new BezierSegment
            {
                Point1 = new Point(p1.X + (p2.X - p0.X) / 6, p1.Y + (p2.Y - p0.Y) / 6),
                Point2 = new Point(p2.X - (p3.X - p1.X) / 6, p2.Y - (p3.Y - p1.Y) / 6), Point3 = p2,
            });
        }
        return new PathGeometry { Figures = { figure } };
    }

    /// <summary>y 是基线；anchor -1 左对齐、0 居中、1 右对齐。</summary>
    public void Label(string text, double x, double y, double size, Color color, int anchor = 0, bool medium = false, bool serif = false)
    {
        var block = serif ? Serif(text, size, color) : Sans(text, size, color, medium ? Medium : null);
        block.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var w = block.DesiredSize.Width;
        Microsoft.UI.Xaml.Controls.Canvas.SetLeft(block, x - _x - (anchor == 0 ? w / 2 : anchor > 0 ? w : 0));
        Microsoft.UI.Xaml.Controls.Canvas.SetTop(block, y - _y - size * 1.05);
        Canvas.Children.Add(block);
    }
}

internal static class RRCharts
{
    static readonly double[] Bands = [164, 144.5, 125, 105, 85.5], Stops = [154, 134.6, 115, 95, 76];
    const double Cx = 260, Cy = 272;

    /// <summary>环形图：每层一圈（了解在最外），每道题一根线落在它答到的那一层，没到目标打叉；中间总分。</summary>
    public static FrameworkElement ScoreRing(IReadOnlyList<MockRV.Question> questions, int target, int? score)
    {
        var c = new RRChart(0, 88, 520, 420);
        var total = questions.Count;
        var step = total > 0 ? 360.0 / total : 0;
        var targetR = Bands[Math.Clamp(target - 1, 0, 4)];
        static Point Polar(double r, double degree) { var a = degree * Math.PI / 180; return new(Cx + r * Math.Sin(a), Cy - r * Math.Cos(a)); }
        foreach (var r in Bands) c.Circle(new(Cx, Cy), r, r <= targetR ? RRC.TargetLine : RRC.Thin);
        c.Circle(new(Cx, Cy), targetR, RRC.Blue, Alpha(Hex(0xEAF0FB), 0.55), 1.25, [4, 3.2]);
        foreach (var r in Bands.Where(r => r < targetR)) c.Circle(new(Cx, Cy), r, RRC.TargetLine);
        for (var i = 0; i < MockRV.Levels.Length; i++)
            c.Label(MockRV.Levels[i], Cx, Cy - Stops[i] + 3.5, 10, Bands[i] <= targetR ? Hex(0x8EA6DC) : RRC.Faint);
        var placed = questions.Select((q, i) =>
        {
            var degree = step / 2 + i * step;
            var r = (q.Level ?? 0) <= 0 ? Bands[0] : Stops[Math.Min(5, q.Level ?? 1) - 1];
            return (Q: q, Degree: degree, Stop: Polar(r, degree));
        }).ToList();
        if (placed.Count >= 3) c.Stroke(c.Curve(placed.Select(p => p.Stop).ToList()), Hex(0xC9C9C3));
        foreach (var (q, degree, stop) in placed)
        {
            var color = q.Outcome == MockRV.Outcome.Unrecorded ? RRC.Faint : q.Weak ? RRC.Orange : RRC.Blue;
            Point start = Polar(168, degree), badge = Polar(179, degree);
            c.Line(start, stop, color, 2);
            if (q.Weak)
            {
                c.Line(new(stop.X - 4, stop.Y - 4), new(stop.X + 4, stop.Y + 4), color, 2);
                c.Line(new(stop.X + 4, stop.Y - 4), new(stop.X - 4, stop.Y + 4), color, 2);
            }
            else c.Circle(stop, 4.5, null, color);
            c.Circle(badge, 9.5, color, V3.White);
            c.Label(q.No.ToString(), badge.X, badge.Y + 4, 11, color, medium: true);
            var right = degree <= 180;
            var title = q.Title.Length > 8 ? q.Title[..7] + "…" : q.Title;
            c.Label(title, badge.X + (right ? 14 : -14), badge.Y + 4, 11, q.Weak ? RRC.Ink : RRC.Sub, right ? -1 : 1);
        }
        c.Circle(new(Cx, Cy), 66, Hex(0xE4E4E0), V3.White);
        c.Label("总分", Cx, Cy - 34, 11, RRC.Sub);
        c.Label(score?.ToString() ?? "—", Cx, Cy + 18, 50, RRC.Ink, serif: true);
        c.Label("/ 100", Cx, Cy + 47, 11, RRC.Faint);
        c.Line(new(96, 485), new(118, 485), RRC.Blue, 2);
        c.Label("答到位", 124, 489, 12, RRC.Sub, -1);
        c.Line(new(186, 485), new(208, 485), RRC.Orange, 2);
        c.Label("没到目标", 214, 489, 12, RRC.Sub, -1);
        c.Line(new(288, 485), new(310, 485), RRC.Blue, 1.25, [4, 3.2]);
        c.Label($"目标：答到「{MockRV.LevelLabel(target)}」", 316, 489, 12, RRC.Sub, -1);
        return c.View($"每道题答到哪一层，总分 {score?.ToString() ?? "—"}");
    }

    /// <summary>每道题得分：底线 y=200，100 分高 136。</summary>
    public static FrameworkElement ScoreBars(IReadOnlyList<MockRV.Question> questions)
    {
        var c = new RRChart(0, 48, 523, 184);
        const double Base = 200, Scale = 1.36, Left = 44, Width = 459;
        foreach (var value in new[] { 0, 50, 100 })
        {
            var y = Base - value * Scale;
            c.Line(new(Left, y), new(Left + Width, y), RRC.Thin);
            c.Label(value.ToString(), 36, y + 4, 11, RRC.Faint, 1);
        }
        var slot = Width / Math.Max(1, questions.Count);
        var bar = Math.Min(26, slot * 0.6);
        for (var i = 0; i < questions.Count; i++)
        {
            var q = questions[i];
            var center = Left + slot * (i + 0.5);
            if (q.Score is { } s)
            {
                var h = s * Scale;
                c.Rect(center - bar / 2, Base - h, bar, h, 3, q.Weak ? RRC.Orange : RRC.Blue);
                c.Label(s.ToString(), center, Base - h - 6, 12, q.Weak ? RRC.Ink : RRC.Text, medium: q.Weak);
            }
            c.Label(q.No.ToString(), center, Base + 20, 12, RRC.Sub);
        }
        return c.View("每道题得分");
    }

    /// <summary>通用能力雷达：圆心 (168,142)，半径 66；以往是灰色虚线，最弱一项标橙。</summary>
    public static FrameworkElement Radar(IReadOnlyList<MockRV.Ability> abilities, string? weakest)
    {
        var count = abilities.Count;
        Point Vertex(int index, double ratio) { var a = (double)index / count * 2 * Math.PI; return new(168 + 66 * ratio * Math.Sin(a), 142 - 66 * ratio * Math.Cos(a)); }
        static int Side(double x) => Math.Abs(x - 168) < 8 ? 0 : x > 168 ? 1 : -1;
        static string Text(MockRV.Ability a) => $"{a.Label} {a.Score}";
        static double W(string s) => s.Sum(ch => ch > 255 ? 12 : 7);
        double left = 0, right = 340;
        for (var i = 0; i < count; i++)
        {
            var x = Vertex(i, 1).X; var s = Side(x); var w = W(Text(abilities[i]));
            var from = s == 0 ? x - w / 2 : s > 0 ? x + 9 : x - 9 - w;
            left = Math.Min(left, from - 8); right = Math.Max(right, from + w + 8);
        }
        static double Ratio(double score) => Math.Clamp(score / 100, 0.08, 1);
        var c = new RRChart(left, 44, right - left, 200);
        PathGeometry Shape(IEnumerable<double> ratios) => c.Poly(ratios.Select((r, i) => Vertex(i, r)), true);
        foreach (var r in new[] { 1, 0.66, 0.33 }) c.Stroke(Shape(Enumerable.Repeat(r, count)), RRC.Thin);
        for (var i = 0; i < count; i++) c.Line(new(168, 142), Vertex(i, 1), RRC.Thin);
        if (abilities.Any(a => a.Past is not null)) c.Stroke(Shape(abilities.Select(a => Ratio(a.Past ?? a.Score))), RRC.Faint, 1.25, [3.2, 2.4]);
        c.Stroke(Shape(abilities.Select(a => Ratio(a.Score))), RRC.Blue, 1.75, null, Alpha(RRC.Blue, 0.1));
        for (var i = 0; i < count; i++)
        {
            var item = abilities[i];
            var dot = Vertex(i, Ratio(item.Score)); var at = Vertex(i, 1); var s = Side(at.X); var low = item.Key == weakest;
            c.Circle(dot, 3, null, low ? RRC.Orange : RRC.Blue);
            c.Label(Text(item), at.X + s * 9, s != 0 ? at.Y + 4 : at.Y + (at.Y < 142 ? -9 : 19), 12, low ? RRC.Ink : RRC.Sub, s == 0 ? 0 : s > 0 ? -1 : 1, low);
        }
        return c.View(string.Join("，", abilities.Select(Text)));
    }

    /// <summary>五格深度条：答到的几格深色，目标位置一根竖线。</summary>
    public static FrameworkElement Depth(MockRV.Question q)
    {
        var level = Math.Max(0, q.Level ?? 0);
        var canvas = new Canvas { Width = 122, Height = 10 };
        for (var step = 1; step <= 5; step++)
        {
            var cell = new Rectangle { Width = 22, Height = 4, RadiusX = 2, RadiusY = 2, Fill = Brush(step <= level ? RRC.Text : RRC.Thin) };
            Microsoft.UI.Xaml.Controls.Canvas.SetLeft(cell, (step - 1) * 25); Microsoft.UI.Xaml.Controls.Canvas.SetTop(cell, 3);
            canvas.Children.Add(cell);
        }
        var mark = new Rectangle { Width = 2, Height = 10, Fill = Brush(RRC.Ink) };
        Microsoft.UI.Xaml.Controls.Canvas.SetLeft(mark, Math.Clamp(q.Expected, 1, 5) * 25 - 3);
        canvas.Children.Add(mark);
        return canvas;
    }
}

/// <summary>
/// 面试复盘总览（Windows 稿 09 · 10.01 总览、10.02 只看没答好、10.03 建议先补；Mac `MockReviewOverview`、Web `interviews/report/ReviewReport.tsx`）：
/// 第一屏是总分和三张图，下面是记忆变化、一题一张同高的卡，再下面是建议先补的几处。
/// </summary>
internal sealed class MockReviewOverview : UserControl
{
    readonly MockRV.View _view;
    readonly (string Label, string Date, int Days)? _next;
    readonly Action<string> _open;
    readonly Action<List<MockRV.Question>> _practice;
    readonly FrameworkElement _crumb, _memory;
    readonly UIElement[] _actions;
    readonly FrameworkElement? _footnote;
    readonly StackPanel _page = new();
    bool _onlyWeak;
    double _width = 1000;

    public MockReviewOverview(MockRV.View view, (string, string, int)? next, Action<string> open, Action<List<MockRV.Question>> practice,
        FrameworkElement crumb, UIElement[] actions, FrameworkElement memory, FrameworkElement? footnote)
    {
        (_view, _next, _open, _practice, _crumb, _actions, _memory, _footnote) = (view, next, open, practice, crumb, actions, memory, footnote);
        Background = Brush(V3.White);
        Content = new V3Page(_page, 46);
        _page.SizeChanged += (_, e) => { if (Math.Abs(e.NewSize.Width - _width) > 1) { _width = e.NewSize.Width; Render(); } };
        Render();
    }

    static void Detach(FrameworkElement element)
    {
        if (element.Parent is Panel panel) panel.Children.Remove(element);
        else if (element.Parent is Border border) border.Child = null;
    }

    void Render()
    {
        _page.Children.Clear();
        var weak = _view.Questions.Where(q => q.Weak).ToList();
        var reached = _view.Questions.Count(q => q.Outcome == MockRV.Outcome.Reached);
        var suggestions = MockRV.Suggestions(_view.Questions);
        Detach(_crumb); Detach(_memory);
        foreach (var a in _actions) if (a is FrameworkElement f) Detach(f);
        if (_footnote is not null) Detach(_footnote);

        _page.Children.Add(Columns(24, (Star(), _crumb.Top(6)), (Auto, HStack(10, _actions))));
        _page.Children.Add(Serif(_view.Title, 28, RRC.Ink).LineHeight(36).Wrap().Top(6));
        _page.Children.Add(Sans(_view.Meta, 14, RRC.Text).Frame(height: 22).Top(4));
        _page.Children.Add(Top(_width > 800, reached, weak.Count).Top(18));
        _page.Children.Add(_memory);

        var head = Columns(12, (Star(), Serif("每道题", 22, RRC.Ink)), (Auto, weak.Count == 0 ? new Border() : Filter(weak.Count)));
        _page.Children.Add(head.Top(44));
        var list = new StackPanel { Spacing = 8, Margin = new Thickness(0, 12, 0, 0) };
        foreach (var q in _onlyWeak ? weak : _view.Questions) list.Children.Add(QuestionRow(q));
        _page.Children.Add(list);

        if (suggestions.Count > 0)
        {
            _page.Children.Add(Serif($"建议先补这 {suggestions.Count} 处知识", 22, RRC.Ink).Top(44));
            var basis = _view.Questions.Any(q => q.History is { Count: > 0 }) ? "按这场答得差、以往也停过的排。" : "按这场答得差的排。";
            var when = _next is { } n ? n.Days <= 0 ? $"{n.Label} {n.Date}，就是今天。" : $"{n.Label} {n.Date}，还有 {n.Days} 天。" : "";
            _page.Children.Add(Sans(basis + when, 13, RRC.Sub).Frame(height: 20).Top(4));
            var cards = new Grid { ColumnSpacing = 11, Margin = new Thickness(0, 14, 0, 0) };
            for (var i = 0; i < suggestions.Count; i++)
            {
                cards.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
                var card = SuggestCard(suggestions[i]);
                Grid.SetColumn(card, i);
                cards.Children.Add(card);
            }
            _page.Children.Add(cards);
        }
        var foot = HStack(4, Sans($"总分来自这 {_view.Questions.Count} 道题，通用能力不计入总分。" + (_view.PastCount > 0 ? $"“以往”来自你之前的 {_view.PastCount} 场面试。" : ""), 12, RRC.Sub).Wrap());
        if (_footnote is not null) foot.Children.Add(_footnote);
        _page.Children.Add(foot.Top(20));
    }

    FrameworkElement Filter(int weak)
    {
        var seg = new V3Segmented<bool>([(false, $"全部 {_view.Questions.Count}"), (true, $"没答好 {weak}")], _onlyWeak, height: 30, fontSize: 13);
        seg.Changed += value => { _onlyWeak = value; Render(); };
        return seg;
    }

    /// <summary>两栏时左边环形卡占两行（高度跟宽度等比），单栏时三张卡竖排。</summary>
    FrameworkElement Top(bool wide, int reached, int weak)
    {
        var ring = RRC.Box(VStack(0,
            Serif(_view.Conclusion, 22, RRC.Ink).LineHeight(30).Wrap().Pad(24, 0, 24, 0),
            Sans(_view.Compare, 13, RRC.Sub).Frame(height: 20).Pad(24, 2, 24, 0),
            RRCharts.ScoreRing(_view.Questions, _view.Target, _view.Score).Top(16)), new Thickness(0, 20, 0, 0));
        var legend = HStack(0, Legend(RRC.Blue, $"{reached} 道答到位"));
        if (weak > 0) legend.Children.Add(Legend(RRC.Orange, $"{weak} 道没答好"));
        var bars = RRC.Box(VStack(4, ChartHead("每道题得分", null, legend), RRCharts.ScoreBars(_view.Questions).Pad(-20, 0, -20, 0)), new Thickness(20, 15, 20, 12));
        var ability = AbilityBox();
        if (!wide)
        {
            bars.Height = 248; ability.Height = 248;
            return VStack(12, ring, bars, ability);
        }
        var right = new Grid { RowSpacing = 12 };
        right.RowDefinitions.Add(new RowDefinition { Height = Star() });
        right.RowDefinitions.Add(new RowDefinition { Height = Star() });
        Grid.SetRow(ability, 1);
        right.Children.Add(bars); right.Children.Add(ability);
        right.MinHeight = 248 * 2 + 12;
        return Columns(12, (new GridLength(520, GridUnitType.Star), ring), (new GridLength(523, GridUnitType.Star), right));
    }

    Border AbilityBox()
    {
        var abilities = MockRV.GeneralAbilities(_view.Abilities);
        var ordered = abilities.OrderByDescending(a => a.Score).ToList();
        var best = ordered.FirstOrDefault(); var worst = ordered.LastOrDefault();
        var weakest = worst is not null && best is not null && best.Score > worst.Score ? worst.Key : null;
        var lines = _view.Voice is { } v
            ? new[] { ("语速", v.Speed), ("长停顿", v.Pauses), ("口头禅占比", v.Fillers) }
            : [("最稳", best is null ? "—" : $"{best.Label} {best.Score}"), ("先补", worst is null ? "—" : $"{worst.Label} {worst.Score}")];
        var legend = HStack(0);
        if (abilities.Count >= 3)
        {
            legend.Children.Add(Legend(RRC.Blue, "这场"));
            if (abilities.Any(a => a.Past is not null)) legend.Children.Add(Legend(RRC.Faint, "以往"));
        }
        FrameworkElement body;
        if (abilities.Count >= 3)
        {
            var side = VStack(6, lines.Select(l => (UIElement)VStack(0, Sans(l.Item1, 12, RRC.Sub).Frame(height: 18), Label(l.Item2, 13, RRC.Ink, Medium).LineHeight(20).Wrap())).ToArray());
            body = Columns(16, (new GridLength(340, GridUnitType.Star), RRCharts.Radar(abilities, weakest).Pad(-20, 0, 0, 0)), (new GridLength(143), side.Align(v: VerticalAlignment.Center)));
        }
        else body = Sans("这场能判断的能力太少，先不画这张图。", 13, RRC.Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center).Frame(height: 160);
        return RRC.Box(VStack(0, ChartHead("通用能力", "不看题目，看你怎么说", legend), body), new Thickness(20, 15, 20, 12));
    }

    static FrameworkElement ChartHead(string title, string? small, FrameworkElement legend)
    {
        var name = HStack(8, Label(title, 15, RRC.Ink, Medium));
        if (small is not null) name.Children.Add(Sans(small, 12, RRC.Sub).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 2));
        return Columns(12, (Star(), name), (Auto, legend)).Frame(height: 24);
    }

    static FrameworkElement Legend(Color color, string text) =>
        HStack(5, new Ellipse { Width = 8, Height = 8, Fill = Brush(color), VerticalAlignment = VerticalAlignment.Center }, Sans(text, 12, RRC.Sub)).Pad(12, 0, 0, 0);

    /// <summary>`.rr-q`：76 高的一题，列宽 68 / 30 / 自适应 / 182 / 145 / 20；悬停只加深描边。</summary>
    FrameworkElement QuestionRow(MockRV.Question q)
    {
        var tag = MockRV.RepeatTag(q);
        var titleRow = HStack(12, Label(q.Title, 15, RRC.Ink, Medium).Also(t => { t.TextTrimming = TextTrimming.CharacterEllipsis; t.MaxWidth = 420; }));
        if (tag is not null) titleRow.Children.Add(Sans(tag, 12, RRC.Sub).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 2));
        var info = VStack(2, titleRow);
        if (q.Line is { } line) info.Children.Add(Sans(line, 13, q.Weak ? RRC.Ink : RRC.Sub).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis));
        info.VerticalAlignment = VerticalAlignment.Center; info.Margin = new Thickness(0, 0, 22, 0);
        var no = new Grid { Width = 20, Height = 20, Children = { new Ellipse { Stroke = Brush(RRC.Faint), StrokeThickness = 1 }, Label(q.No.ToString(), 11, RRC.Sub, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center) } };
        no.VerticalAlignment = VerticalAlignment.Top; no.HorizontalAlignment = HorizontalAlignment.Left; no.Margin = new Thickness(0, 16, 0, 0);
        var depth = VStack(8, RRCharts.Depth(q), Sans(MockRV.DepthLine(q), 12, RRC.Sub).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis));
        depth.VerticalAlignment = VerticalAlignment.Center;
        var row = new Grid { MinHeight = 76 };
        foreach (var w in new[] { new GridLength(68), new GridLength(30), Star(), new GridLength(182), new GridLength(145), new GridLength(20) })
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = w });
        FrameworkElement[] cells =
        [
            Serif(q.Score?.ToString() ?? "—", 30, RRC.Ink).Align(v: VerticalAlignment.Center), no, info, depth,
            Sans(MockRV.OutcomeText(q), 13, q.Weak ? RRC.Orange : RRC.Sub, q.Weak ? Medium : null).Align(v: VerticalAlignment.Center),
            Sans("›", 15, RRC.Faint).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        ];
        for (var i = 0; i < cells.Length; i++) { Grid.SetColumn(cells[i], i); row.Children.Add(cells[i]); }
        var box = RRC.Box(row, new Thickness(24, 0, 24, 0));
        box.OnHover(h => box.BorderBrush = Brush(h ? Hex(0xC9C9C3) : RRC.Line));
        return box.OnTap(() => _open(q.Id), $"{q.Title} · {MockRV.OutcomeText(q)}");
    }

    /// <summary>建议先补的一张卡：题名、要补的点、一句建议、来自第几题、练这一处。</summary>
    FrameworkElement SuggestCard(MockRV.Question q)
    {
        var head = Columns(12, (Star(), Label(q.Title, 15, RRC.Ink, Medium).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis)),
            (Auto, MockRV.StopTag(q) is { } tag ? Sans(tag, 12, RRC.Sub) : new Border()));
        var chips = new VariableSizedFlow(6);
        foreach (var gap in MockRV.Gaps(q).Take(3))
            chips.Add(new Border { Child = Sans(gap, 12, RRC.Text).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis), Padding = new Thickness(10, 3, 10, 3), CornerRadius = new CornerRadius(6), Background = Brush(MP.Chip) });
        var foot = Columns(8, (Star(), Sans($"来自第 {q.No} 题", 12, RRC.Sub)), (Auto, MP.Link("练这一处 ›", () => _practice([q]), blue: true)));
        foot.VerticalAlignment = VerticalAlignment.Bottom;
        var grid = new Grid { MinHeight = 186 - 34 };
        grid.Children.Add(VStack(0, head, chips.Panel.Top(12), Sans(MockRV.Advice(q), 13, RRC.Text).LineHeight(21).Wrap().Top(12)).Also(s => s.Margin = new Thickness(0, 0, 0, 34)));
        grid.Children.Add(foot);
        return RRC.Box(grid, new Thickness(20, 18, 20, 16));
    }
}

/// <summary>翻看面试记录（Windows 稿 09 · 10.04；Mac `MockReviewRecord`、Web `ReviewRecord.tsx`）：逐题问答，没答好的题标橙、问题处加批注；右边题目索引可跳转。</summary>
internal sealed class MockReviewRecord : UserControl
{
    public MockReviewRecord(MockRV.View view, string? initial, string? playing, Action<MockRV.Question>? play, FrameworkElement crumb)
    {
        Background = Brush(V3.White);
        var blocks = new StackPanel { Spacing = 36 };
        var anchors = new Dictionary<string, FrameworkElement>();
        foreach (var q in view.Questions) { var block = Block(q, playing, play); anchors[q.Id] = block; blocks.Children.Add(block); }
        var index = new StackPanel { Spacing = 10, Width = 220 };
        var page = new V3Page(new Border(), 46);
        var items = new List<TextBlock>();
        for (var i = 0; i < view.Questions.Count; i++)
        {
            var q = view.Questions[i];
            var text = Sans($"{q.No:00}  {q.Title}", 13, i == 0 ? RRC.Ink : RRC.Sub, i == 0 ? Medium : null).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis);
            items.Add(text);
            var at = i;
            index.Children.Add(HStack(8, new Ellipse { Width = 6, Height = 6, Fill = Brush(q.Weak ? RRC.Orange : Clear), VerticalAlignment = VerticalAlignment.Center }, text)
                .OnTap(() => { Scroll(page, anchors[q.Id]); Mark(items, at); }, q.Title));
        }
        var body = VStack(0, crumb.Top(6), Serif(view.RecordTitle, 28, RRC.Ink).LineHeight(36).Wrap().Top(18),
            Columns(40, (Star(), blocks), (new GridLength(220), index)).Top(28));
        page = new V3Page(body, 46);
        Content = page;
        if (initial is not null && anchors.TryGetValue(initial, out var target))
            Loaded += (_, _) => DispatcherQueue.TryEnqueue(() => Scroll(page, target));
    }

    static void Mark(List<TextBlock> items, int active)
    {
        for (var i = 0; i < items.Count; i++)
        {
            items[i].Foreground = Brush(i == active ? RRC.Ink : RRC.Sub);
            items[i].FontWeight = i == active ? Medium : FontWeights.Normal;
        }
    }

    static void Scroll(V3Page page, FrameworkElement target)
    {
        var point = target.TransformToVisual(page.Scroller.Content as UIElement).TransformPoint(new Point(0, 0));
        page.Scroller.ChangeView(null, Math.Max(0, point.Y + 46 - 24), null);
    }

    static FrameworkElement Block(MockRV.Question q, string? playing, Action<MockRV.Question>? play)
    {
        var head = HStack(12, Serif($"{q.No:00}", 20, RRC.Ink));
        if (q.Weak) head.Children.Add(Label(MockRV.OutcomeText(q), 12, RRC.Orange, Medium).Align(v: VerticalAlignment.Center));
        if (play is not null && q.Turns.Any(t => t.HasRecording))
            head.Children.Add(MP.Link(playing == q.Id ? "❚❚ 暂停" : "▶ 播放这段", () => play(q), blue: true).Align(v: VerticalAlignment.Center));
        var stack = VStack(12, head);
        foreach (var turn in q.Turns)
        {
            var marks = MockRV.Marks(q, turn.Answer);
            var part = VStack(8, turn.Follow
                ? Label("追问  " + turn.Ask, 14, RRC.Ink, Medium).LineHeight(24).Wrap()
                : Label(turn.Ask, 17, RRC.Ink, Medium).LineHeight(28).Wrap());
            part.Children.Add(turn.Answer is { } answer ? RRC.Marked(answer, marks, RRC.Text) : Sans(turn.Missing, 14, RRC.Faint));
            foreach (var mark in marks)
            {
                var note = new TextBlock { FontFamily = SansFamily, FontSize = 12, Foreground = Brush(RRC.Orange), TextWrapping = TextWrapping.Wrap };
                note.Inlines.Add(new Run { Text = "问题在这  ", FontWeight = Medium });
                note.Inlines.Add(new Run { Text = MockRV.MarkText(mark) });
                part.Children.Add(note);
            }
            stack.Children.Add(turn.Follow
                ? new Border { Child = part, Padding = new Thickness(16, 0, 0, 0), BorderBrush = Brush(RRC.Line), BorderThickness = new Thickness(1, 0, 0, 0) }
                : part);
        }
        return stack;
    }
}

/// <summary>「这场之后，记忆里变了什么」（Windows 稿 09 · 11 记忆变化状态 11.01–11.04；Mac `RRMemorySection`、Web `ReviewMemory.tsx`）。</summary>
internal sealed class RRMemorySection : UserControl
{
    static readonly Dictionary<string, string> Word = new() { ["up"] = "升了", ["down"] = "降了", ["same"] = "没变", ["new"] = "第一次记下", ["unsettled"] = "还说不准" };
    static readonly Dictionary<string, int> Order = new() { ["up"] = 0, ["down"] = 1, ["new"] = 2, ["unsettled"] = 3, ["same"] = 4 };
    readonly string _mockId;
    readonly int _pastCount;
    readonly Action<JsonNode> _practice;
    List<JsonNode> _points = [], _levels = [];
    JsonNode? _pending;
    bool _alive = true;

    public RRMemorySection(string mockId, int pastCount, Action<JsonNode> practice)
    {
        (_mockId, _pastCount, _practice) = (mockId, pastCount, practice);
        Loaded += (_, _) => { _alive = true; _ = Load(); };
        Unloaded += (_, _) => _alive = false;
    }

    async Task Load()
    {
        for (var tries = 0; _alive; tries++)
        {
            var found = new List<JsonNode>();
            JsonNode? waiting = null;
            foreach (var kind in new[] { "progress", "insight" })
            {
                try
                {
                    var result = await App.Session.Api.CareerRequestAsync("/api/memory/feedback", "GET", new() { ["mock_interview_id"] = _mockId, ["kinds"] = kind }, null);
                    if (!result.Bool("enabled") || result.Get("card") is not JsonObject card) continue;
                    if (card.Text("status") == "pending") waiting = card;
                    else found.AddRange(card.Items("points").Where(p => p.Text("kind") is "progress" or "insight"));
                }
                catch { }
            }
            if (!_alive) return;
            _pending = waiting; _points = waiting is null ? found : [];
            if (waiting is null)
            {
                try
                {
                    var comparison = await App.Session.Api.CareerRequestAsync("/api/memory/review-comparison", "GET", new() { ["mock_interview_id"] = _mockId }, null);
                    var items = comparison.Bool("enabled") && (comparison.Get("diarized") is null || comparison.Bool("diarized")) ? comparison.Items("items") : [];
                    _levels = items.Select((item, i) => (item, i))
                        .Where(x => x.item.Text("kind") is "skill" or "point" or "type" && !(x.item.Text("before") == "证据不足" && x.item.Text("after") == "证据不足"))
                        .OrderBy(x => Order.GetValueOrDefault(x.item.Text("change"), 9)).ThenBy(x => x.i).Select(x => x.item).Take(8).ToList();
                }
                catch { _levels = []; }
                if (_alive) Render();
                return;
            }
            Render();
            if (tries >= 7) return;
            var wait = Json.Date(waiting.Text("expected_at")) is { } at ? (at - DateTimeOffset.UtcNow).TotalSeconds : 15;
            await Task.Delay(TimeSpan.FromSeconds(Math.Clamp(wait, 15, 120)));
        }
    }

    void Render()
    {
        if (_pending is null && _points.Count == 0 && _levels.Count == 0) { Content = null; return; }
        var first = _pastCount == 0;
        var many = _levels.Count > 0 && _pending is null;
        var sub = first && !many ? (_pending is not null ? "" : "以后改简历、出题和面试前提醒，都会按这里的结论来。")
            : (many ? "对照这场之前的记忆。" : _pastCount > 0 ? $"对照你之前的 {_pastCount} 场面试。" : "") + (_pending is not null ? "" : "以后出题和面试前提醒会按这里的结论来。");
        var rows = new StackPanel();
        if (_pending is null && _levels.Count > 0) rows.Children.Add(LevelRow());
        if (_pending is { } pending) rows.Children.Add(PendingRow(pending));
        else
            for (var i = 0; i < _points.Count; i++)
            {
                if (i > 0 || _levels.Count > 0) rows.Children.Add(new Rectangle { Height = 1, Fill = Brush(RRC.Line) });
                rows.Children.Add(PointRow(_points[i]));
            }
        var stack = VStack(0, Serif(first && !many ? "第一场之后，记忆里记下了什么" : "这场之后，记忆里变了什么", 22, RRC.Ink).LineHeight(30));
        if (sub.Length > 0) stack.Children.Add(Sans(sub, 13, RRC.Sub).Frame(height: 20).Top(4));
        stack.Children.Add(RRC.Box(rows).Top(14));
        Content = stack.Top(44);
    }

    static FrameworkElement Badge(string text, Color color, bool hollow = false) =>
        HStack(8, new Ellipse { Width = 8, Height = 8, Fill = hollow ? null : Brush(color), Stroke = hollow ? Brush(color) : null, StrokeThickness = 1.5, VerticalAlignment = VerticalAlignment.Center },
            Sans(text, 13, color, hollow ? null : Medium)).Frame(width: 96, height: 22);

    static FrameworkElement Row(FrameworkElement tag, FrameworkElement body) =>
        Columns(24, (Auto, tag.Align(v: VerticalAlignment.Top)), (Star(), body)).Pad(24, 20, 24, 20);

    FrameworkElement LevelRow()
    {
        var flow = new VariableSizedFlow(40);
        foreach (var item in _levels)
        {
            var change = item.Text("change");
            Color? tone = change == "up" ? RRC.Blue : change == "down" ? RRC.Orange : null;
            var line = new TextBlock { FontFamily = SansFamily, FontSize = 13 };
            line.Inlines.Add(new Run { Text = item.Text("before") + " → ", Foreground = Brush(RRC.Gray) });
            line.Inlines.Add(new Run { Text = item.Text("after"), Foreground = Brush(tone ?? RRC.Text), FontWeight = tone is null ? FontWeights.Normal : Medium });
            line.Inlines.Add(new Run { Text = " " + Word.GetValueOrDefault(change, ""), FontSize = 12, Foreground = Brush(tone ?? RRC.Gray) });
            flow.Add(VStack(2, Label(item.Text("name"), 15, RRC.Ink, Medium), line).Pad(0, 0, 0, 14));
        }
        return Row(Badge("等级变化", RRC.Ink), flow.Panel);
    }

    static FrameworkElement PendingRow(JsonNode card)
    {
        var left = Json.Date(card.Text("expected_at")) is { } at ? Math.Max(1, (int)Math.Ceiling((at - DateTimeOffset.UtcNow).TotalMinutes)) : 1;
        return Row(Badge("正在记入", RRC.Gray, true), VStack(4,
            Label($"正在把这场记入长期记忆，大约还要 {left} 分钟", 16, RRC.Ink, Medium).Wrap(),
            Sans("评分已经出来了，可以先看下面每道题。记好后，这里会出现这场带来的变化。", 13, RRC.Sub).LineHeight(22).Wrap()));
    }

    FrameworkElement PointRow(JsonNode point)
    {
        var progress = point.Text("kind") == "progress";
        var name = progress ? "练稳了" : point.Text("insight_kind") == "habit" ? "说话习惯" : "值得留意";
        var observed = VStack(4, Label(point.Get("observed").Text("text"), 16, RRC.Ink, Medium).Wrap());
        if (point.Get("observed").Text("quote").NonEmpty() is { } quote) observed.Children.Add(Sans($"你说：「{quote}」", 13, RRC.Sub).LineHeight(22).Wrap());
        var next = VStack(4, Sans(point.Get("next").Text("text"), 13, RRC.Text).LineHeight(22).Wrap(), Sans(point.Get("review").Text("text"), 12, RRC.Gray).LineHeight(20).Wrap());
        next.MaxWidth = 300;
        var body = Columns(24, (Star(), observed), (Auto, next));
        if (point.Get("target") is JsonObject target)
            body = Columns(24, (Star(), observed), (Auto, next), (Auto, MP.Link(progress ? "再答一次 ›" : "练这一点 ›", () => _practice(target), blue: true)));
        return Row(Badge(name, progress ? RRC.Blue : RRC.Orange), body);
    }
}
