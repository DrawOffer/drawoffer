using DrawOffer.App.DesignSystem;
using DrawOffer.App.Views.Mock;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views;

/// <summary>Mac SessionChrome 的 1368 × 828 设计坐标、全屏顶栏、题目地平线与对话抽屉。</summary>
internal static class MockSessionChrome
{
    internal const double Width = 1368, Height = 828;
    internal static readonly Color Ink = Hex(0x292822), Muted = Hex(0x8B877C), Rule = Hex(0xE8E5DE);
    internal static Canvas Frame() => new() { Width = Width, Height = Height, Background = Brush(White) };
    internal static void Put(Canvas canvas, FrameworkElement element, double x, double y) => MockCanvas.Put(canvas, element, x, y);
    internal static TextBlock Text(Canvas canvas, string text, double x, double y, double size = 12, Color? color = null) => MockCanvas.Text(canvas, text, x, y, size, color ?? Muted);
    internal static V3Button Button(string title, Action action, bool enabled = true, bool primary = false, double height = 30)
        => new(title, action, primary ? V3Button.Kind.Dark : V3Button.Kind.Ghost, height: height, small: height < 36) { Enabled = enabled };
    internal static void Top(Canvas canvas, JsonNodeContext model, string center, TextBlock timer, Action abandon, Action finish, Action exit, bool active, bool enabled)
    {
        Text(canvas, MockSession.Heading(model.Detail), 36, 22, 13.5, Ink);
        Text(canvas, MockSession.Subtitle(model.Detail), 36, 43, 11.5);
        var progress = Sans(center, 12, Sub); progress.Width = 420; progress.TextAlignment = TextAlignment.Center; Put(canvas, progress, 474, 30);
        var actions = active ? HStack(16, timer, Button("放弃", abandon, enabled), Button("结束并评估", finish, enabled)) : HStack(16, Button("退出", exit, enabled));
        actions.Measure(new Windows.Foundation.Size(double.PositiveInfinity, 32)); Put(canvas, actions, Width - 36 - actions.DesiredSize.Width, 22);
        MockCanvas.Line(canvas, 0, 71, Width, 71, Rule);
    }
    internal static void Map(Canvas canvas, MockSession.Map map, double target, bool caption, bool grey)
    {
        var view = new MockMasteryMap(Width, Height, MockLayout.Session.At, map.Points, map.Sectors, target)
        { Now = map.Now, Hot = map.Hot, PathSteps = map.Path, Plain = true, Center = "这一场", NoLinks = map.Bounds is null, LabelLayout = MockSession.LayoutOf(map, target, !caption), Bounds = map.Bounds, IsHitTestVisible = false, Opacity = grey ? .5 : 1 };
        canvas.Children.Add(view);
        if (caption) Text(canvas, "这一场的图：当前这题转到左边，往圆心走一圈就是追问深一层", 893, 590, 10.5);
        var placed = MockMap.Place(MockLayout.Session.At, map.Points).FirstOrDefault(p => p.Point.Id == map.Now);
        if (placed is not null)
            foreach (var (note, i) in map.Annotations.TakeLast(1).Select((n, i) => (n, i)))
                Text(canvas, note.Text, placed.X - 115, placed.Y + 24 + i * 16, 10, note.Tone == MockSession.NoteTone.Orange ? Orange : Blue);
    }
    internal static void Horizon(Canvas canvas, System.Text.Json.Nodes.JsonNode? detail, System.Text.Json.Nodes.JsonNode? current, bool ended)
    {
        var arc = MockMap.ArcY(Width, 646);
        double Y(double x) => arc(x);
        var geometry = new PathGeometry(); var figure = new PathFigure { StartPoint = new(0, Y(0)), IsClosed = false };
        for (var x = 12; x <= Width; x += 12) figure.Segments.Add(new LineSegment { Point = new(x, Y(x)) });
        geometry.Figures.Add(figure); canvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Stroke = Brush(Rule), StrokeThickness = 1 });
        MockCanvas.Circle(canvas, 200, Y(200), 5, Ink, MockSession.IntroNow(detail, current) ? Blue : Ink);
        Text(canvas, "开场", 188, Y(200) + 15, 10.5);
        MockCanvas.Circle(canvas, 1180, Y(1180), 5, ended ? Ink : Muted, ended ? Ink : White);
        Text(canvas, "结束", 1168, Y(1180) + 15, 10.5);
        var beads = MockSession.Beads(detail, current); var xs = MockSession.BeadXs(beads.Count);
        for (var i = 0; i < beads.Count; i++)
        {
            var bead = beads[i]; var x = xs[i]; var y = Y(x);
            var color = bead.State == MockSession.BeadState.Now ? Blue : bead.State == MockSession.BeadState.Done ? bead.Miss ? Orange : Ink : Muted;
            if (bead.State == MockSession.BeadState.Now) MockCanvas.Circle(canvas, x, y, 15, Clear, Alpha(Blue, .12));
            MockCanvas.Circle(canvas, x, y, bead.State == MockSession.BeadState.Now ? 8 : 6, color, bead.State is MockSession.BeadState.Todo or MockSession.BeadState.Skip ? White : color);
            for (var j = 0; j < bead.FollowUps; j++) MockCanvas.Circle(canvas, x, y - 18 - j * 11, 3, color, color);
            if (bead.State == MockSession.BeadState.Skip) MockCanvas.Line(canvas, x - 5, y + 5, x + 5, y - 5, Muted);
            var label = Sans(bead.Title, 10.5, color).Wrap(2); label.Width = 100; label.TextAlignment = TextAlignment.Center; Put(canvas, label, x - 50, y + 19);
        }
    }
    internal static ScrollViewer Scroll(UIElement child, double width, double height) => new() { Content = child, Width = width, Height = height, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    internal static FrameworkElement Notes(IEnumerable<MockSession.Note> notes)
    {
        var stack = VStack(8, Sans("面试官在记", 10.5, Muted));
        foreach (var note in notes.TakeLast(4)) stack.Children.Add(Sans((note.Kind == "hit" ? "✓ " : "? ") + note.Text, 12, note.Kind == "hit" ? Blue : Orange).Wrap());
        return stack;
    }
    internal sealed record JsonNodeContext(System.Text.Json.Nodes.JsonNode? Detail);
}
