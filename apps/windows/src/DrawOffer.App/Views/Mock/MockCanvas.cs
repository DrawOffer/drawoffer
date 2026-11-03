using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

/// <summary>Mac MockStage：设计坐标保持不变，窗口只整体缩放。</summary>
internal static class MockCanvas
{
    internal static FrameworkElement Stage(Canvas canvas) => new Viewbox { Stretch = Stretch.Uniform, Child = canvas, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    internal static void Put(Canvas canvas, FrameworkElement element, double x, double y) { Canvas.SetLeft(element, x); Canvas.SetTop(element, y); canvas.Children.Add(element); }
    internal static TextBlock Text(Canvas canvas, string text, double x, double y, double size = 12, Color? color = null, bool centered = false)
    {
        var block = Sans(text, size, color ?? Sub); block.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        Put(canvas, block, centered ? x - block.DesiredSize.Width / 2 : x, y); return block;
    }
    internal static void Line(Canvas canvas, double x1, double y1, double x2, double y2, Color color, double weight = 1, bool dashed = false)
    {
        var line = new Line { X1 = x1, Y1 = y1, X2 = x2, Y2 = y2, Stroke = Brush(color), StrokeThickness = weight, IsHitTestVisible = false };
        if (dashed) line.StrokeDashArray = new DoubleCollection { 4, 4 }; canvas.Children.Add(line);
    }
    internal static Ellipse Circle(Canvas canvas, double x, double y, double radius, Color color, Color? fill = null, bool dashed = false, double weight = 1)
    {
        var circle = new Ellipse { Width = radius * 2, Height = radius * 2, Stroke = Brush(color), StrokeThickness = weight, Fill = Brush(fill ?? Clear), IsHitTestVisible = false };
        if (dashed) circle.StrokeDashArray = new DoubleCollection { 4, 4 }; Put(canvas, circle, x - radius, y - radius); return circle;
    }
}

/// <summary>Mac MasteryMapView：同一圆环、目标线、知识点和提问路线。</summary>
public sealed class MockMasteryMap : Canvas
{
    readonly MockMap.Geo _geo;
    readonly IReadOnlyList<MockMap.Point> _points;
    readonly IReadOnlyList<MockMap.Sector> _sectors;
    readonly double _target;
    readonly string? _targetLabel;
    readonly Action<string>? _select;
    public string? Selected { get; set; }
    public new string? Focus { get; set; }
    public string? Now { get; set; }
    public IReadOnlyList<string>? Hot { get; set; }
    public IReadOnlyList<MockMap.PathStep>? PathSteps { get; set; }
    public bool Plain { get; set; }
    public string? Center { get; set; }
    public bool NoLinks { get; set; }
    public MockLayout.Layout? LabelLayout { get; set; }
    public IReadOnlyList<double>? Bounds { get; set; }
    public IReadOnlyList<string>? LabelOnly { get; set; }
    public IReadOnlyList<string> Dim { get; set; } = [];
    public IReadOnlyDictionary<string, (string Text, MockMap.SubTone Tone)> Subs { get; set; } = new Dictionary<string, (string, MockMap.SubTone)>();
    public Action<string>? DropFocus { get; set; }
    public (double X, double Y)? DropTarget { get; set; }
    public MockMasteryMap(double width, double height, MockMap.Geo geo, IReadOnlyList<MockMap.Point> points, IReadOnlyList<MockMap.Sector> sectors, double targetLevel, string? targetLabel = null, Action<string>? select = null)
    {
        Width = width; Height = height; _geo = geo; _points = points; _sectors = sectors; _target = targetLevel; _targetLabel = targetLabel; _select = select;
        Loaded += (_, _) => Render();
    }
    public void Render()
    {
        Children.Clear(); var g = _geo;
        MockCanvas.Circle(this, g.Cx, g.Cy, 258 * g.K, Alpha(Hex(0xA9A59A), .5), dashed: true);
        foreach (var radius in new[] { 225, 180, 135, 90, 45 }) MockCanvas.Circle(this, g.Cx, g.Cy, radius * g.K, Hex(0xC9C5BB), dashed: true, weight: .75);
        MockCanvas.Circle(this, g.Cx, g.Cy, g.RingOf(_target), Blue, Alpha(Blue, .05), true, 1.4);
        foreach (var angle in Bounds ?? new double[] { -150, -90, -30, 30, 90, 150 }) { var a = g.P(angle, 55 * g.K); var b = g.P(angle, 213 * g.K); MockCanvas.Line(this, a.X, a.Y, b.X, b.Y, Hex(0xD6D2C7), .75, true); }
        foreach (var sector in _sectors.Where(s => !s.Name.StartsWith("__empty_"))) { var at = g.P(sector.Angle, 284 * g.K); if (LabelLayout?.Sectors.GetValueOrDefault(sector.Name) is { } label) at = (label.X, label.Y); MockCanvas.Text(this, sector.Name, at.X, at.Y - 8, 11, Dim.Contains(sector.Name) ? Hex(0xCFCABD) : Hex(0x9B978C), true); }
        for (var level = 1; level <= 4; level++) MockCanvas.Text(this, MockMap.Levels[level - 1], g.Cx + 5, g.Cy - g.ROf(level) - 7, 10, Hex(0xA9A59A));
        if (_targetLabel is not null) { var at = g.P(28, g.RingOf(_target)); MockCanvas.Text(this, _targetLabel, at.X + 8, at.Y - 22, 10.5, Blue); }
        var placed = MockMap.Place(g, _points);
        foreach (var item in placed)
        {
            var p = item.Point; var c = p.Pending ? Hex(0xA9A59A) : p.Level == 0 ? p.Job ? Orange : Hex(0xA9A59A) : p.Level >= _target ? Blue : Orange;
            var radius = new[] { .72, .72, .86, 1.05 }[Math.Clamp(p.Ask, 0, 3)] * Math.Max(g.K, .8) * 6.4;
            if (Dim.Contains(p.Sector) || Hot is not null && !Hot.Contains(p.Id)) c = Alpha(c, .25);
            if (p.Level > 0 && p.Level < _target && PathSteps is null) { var at = g.P(p.Angle, g.RingOf(_target)); MockCanvas.Line(this, item.X, item.Y, at.X, at.Y, Alpha(Orange, .8), .9); }
            MockCanvas.Circle(this, item.X, item.Y, radius, Plain && p.Level > 0 ? White : c, p.Level == 0 || p.Pending ? White : Plain ? c : Alpha(c, .14), p.Level == 0 || p.Pending);
            if (p.Level > 0 && !p.Pending && !Plain)
            {
                MockCanvas.Circle(this, item.X, item.Y, radius * .4, c, c);
                Star(item.X, item.Y, (p.Id == Focus ? 9.75 : 7.3) * radius / 5.5, c);
            }
            if (p.Id == Focus || p.Id == Now) MockCanvas.Circle(this, item.X, item.Y, p.Id == Now ? 24 : 15, c, Alpha(c, .08), true);
            if (p.Id == Selected) MockCanvas.Circle(this, item.X, item.Y, 19, Txt);
            var left = Math.Cos(p.Angle * Math.PI / 180) < -.2;
            if (LabelOnly is null || LabelOnly.Contains(p.Id))
            {
                var label = Sans(p.Name, p.Id == Now ? 12.5 : 11.5, p.Id == Selected ? Txt : Sub); label.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
                var x = left ? item.X - 15 - label.DesiredSize.Width : item.X + 15; var y = item.Y - 9; var lines = 1;
                if (LabelLayout?.Labels.GetValueOrDefault(p.Id) is { } place)
                {
                    lines = place.Lines; label.Width = place.Width; if (lines == 2) label.Wrap(2).LineHeight(17);
                    label.TextAlignment = place.Align == MockLayout.Align.Right ? TextAlignment.Right : place.Align == MockLayout.Align.Center ? TextAlignment.Center : TextAlignment.Left;
                    x = place.Align == MockLayout.Align.Right ? place.X - place.Width : place.Align == MockLayout.Align.Center ? place.X - place.Width / 2 : place.X; y = place.Box.T;
                    if (place.Far) MockCanvas.Line(this, item.X, item.Y, Math.Clamp(item.X, place.Box.L, place.Box.R), Math.Clamp(item.Y, place.Box.T, place.Box.B), Hex(0xA9A59A), .7, true);
                }
                MockCanvas.Put(this, label, x, y);
                if (Subs.TryGetValue(p.Id, out var sub)) MockCanvas.Text(this, sub.Text, x, y + lines * 17, 10.5, sub.Tone == MockMap.SubTone.Blue ? Blue : sub.Tone == MockMap.SubTone.Orange ? Orange : Fnt);
            }
            if (_select is not null)
            {
                var button = new Button { Width = 30, Height = 30, Background = Brush(Clear), BorderThickness = new Thickness(0), Padding = new Thickness(0) }.Tip(p.Name);
                var dragged = false;
                button.Click += (_, _) => { if (!dragged) _select(p.Id); dragged = false; };
                if (DropFocus is not null)
                {
                    Windows.Foundation.Point? start = null; Border? ghost = null;
                    void ResetDrag() { start = null; button.ReleasePointerCaptures(); if (ghost is not null) Children.Remove(ghost); ghost = null; Canvas.SetLeft(button, item.X - 15); Canvas.SetTop(button, item.Y - 15); }
                    button.PointerPressed += (_, e) => { start = e.GetCurrentPoint(this).Position; dragged = false; button.CapturePointer(e.Pointer); };
                    button.PointerMoved += (_, e) =>
                    {
                        if (start is not { } from) return; var at = e.GetCurrentPoint(this).Position;
                        if (Math.Abs(at.X - from.X) + Math.Abs(at.Y - from.Y) <= 6 && !dragged) return;
                        dragged = true;
                        if (ghost is null) { ghost = Card(Sans(p.Name + " · 拖到第一颗题珠设为先问", 11, Orange), 8, new Thickness(10), White, Orange); ghost.IsHitTestVisible = false; MockCanvas.Put(this, ghost, at.X + 16, at.Y - 24); }
                        Canvas.SetLeft(ghost, at.X + 16); Canvas.SetTop(ghost, at.Y - 24);
                        Canvas.SetLeft(button, at.X - 15); Canvas.SetTop(button, at.Y - 15);
                    };
                    button.PointerReleased += (_, e) => { var at = e.GetCurrentPoint(this).Position; var accept = dragged && DropTarget is { } drop && Math.Pow(at.X - drop.X, 2) + Math.Pow(at.Y - drop.Y, 2) < 900; ResetDrag(); if (accept) DropFocus(p.Id); };
                    button.PointerCanceled += (_, _) => ResetDrag();
                }
                MockCanvas.Put(this, button, item.X - 15, item.Y - 15);
            }
        }
        (double X, double Y)? previous = null;
        foreach (var step in PathSteps ?? [])
        {
            var item = placed.FirstOrDefault(p => p.Point.Id == step.Id); if (item is null) continue;
            var a = g.P(item.Point.Angle, g.ROf(Math.Max(1, step.From))); var b = g.P(item.Point.Angle, g.ROf(Math.Max(1, step.To)));
            if (previous is { } prev && !NoLinks)
            {
                var figure = new PathFigure { StartPoint = new(prev.X, prev.Y) };
                figure.Segments.Add(new QuadraticBezierSegment { Point1 = new(g.Cx + (prev.X + a.X - 2 * g.Cx) * .15, g.Cy + (prev.Y + a.Y - 2 * g.Cy) * .15), Point2 = new(a.X, a.Y) });
                var geometry = new PathGeometry(); geometry.Figures.Add(figure);
                Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Stroke = Brush(Alpha(Txt, .4)), StrokeThickness = 1, IsHitTestVisible = false });
            }
            for (var level = Math.Max(1, step.From); level <= step.To; level++)
                if (level < step.To || step.Ok == true) { var at = g.P(item.Point.Angle, g.ROf(level)); MockCanvas.Circle(this, at.X, at.Y, 2.2, Blue, Blue); }
            MockCanvas.Line(this, a.X, a.Y, b.X, b.Y, step.Ok == false ? Orange : Blue, 2.2, step.Ok is null);
            if (step.Ok is null)
            {
                var next = g.P(item.Point.Angle, g.ROf(Math.Min(5, step.To + 1)));
                MockCanvas.Line(this, b.X, b.Y, next.X, next.Y, Alpha(Blue, .5), 1.2, true);
                MockCanvas.Circle(this, next.X, next.Y, 4, Blue, White, true);
            }
            else if (step.Ok == true) MockCanvas.Circle(this, b.X, b.Y, 4, Blue, Blue);
            else { MockCanvas.Line(this, b.X - 4, b.Y - 4, b.X + 4, b.Y + 4, Orange, 2); MockCanvas.Line(this, b.X + 4, b.Y - 4, b.X - 4, b.Y + 4, Orange, 2); }
            previous = b;
        }
        if (Plain) MockCanvas.Text(this, "专家", g.Cx, g.Cy - 7, 10, Txt, true);
        else { Star(g.Cx, g.Cy, 14 * g.K, Txt, .186); MockCanvas.Circle(this, g.Cx, g.Cy, 20 * g.K, Alpha(Txt, .25)); }
        if (Center is not null) MockCanvas.Text(this, Center, g.Cx, g.Cy + 26 * g.K, 13, Txt, true);
    }
    void Star(double x, double y, double tip, Color color, double middle = .044)
    {
        var w = tip * middle; var polygon = new Polygon { Fill = Brush(color), IsHitTestVisible = false };
        foreach (var p in new[] { (0d, -tip), (w, -w), (tip, 0d), (w, w), (0d, tip), (-w, w), (-tip, 0d), (-w, -w) }) polygon.Points.Add(new Windows.Foundation.Point(x + p.Item1, y + p.Item2));
        Children.Add(polygon);
    }
}
