using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Home;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Home;

/// <summary>首页配色（Mac `HomeColors`）。</summary>
public static class HomeColors
{
    public static readonly Color Ink = Hex(0x1D1D1B);
    public static readonly Color Blue = Hex(0x3F6FD8);
    public static readonly Color Orange = Hex(0xD9822B);
    public static readonly Color Soft = Hex(0xA8A49A);
    public static Color Tone(HomeTone tone) => tone switch { HomeTone.Ink => Ink, HomeTone.Blue => Blue, HomeTone.Orange => Orange, _ => Soft };
}

/// <summary>星图符号（Mac `HomeSymbols`）：半径表与逐种符号的画法。</summary>
public static class HomeSymbols
{
    public static readonly double[] Levels = [2.6, 3.6, 4.8, 6.2, 7.8];
    public static readonly double DefaultTail = Math.Atan2(-0.6, -1);

    public static double Radius(HomeSym sym, int level = 3)
    {
        var lv = Levels[Math.Clamp(level, 1, 5) - 1];
        return sym switch
        {
            HomeSym.Mastered or HomeSym.Due => lv + 3,
            HomeSym.Weak => lv + 9,
            HomeSym.Anchor => 19,
            HomeSym.Planet => 17,
            HomeSym.Topic => 5,
            HomeSym.Pending => 7,
            _ => 10,
        };
    }

    static Microsoft.UI.Xaml.Media.Geometry Rays(Point c, double a, double b) =>
        global::DrawOffer.App.DesignSystem.Draw.Segments(new (double dx, double dy)[] { (0, -1), (0, 1), (-1, 0), (1, 0) }
            .Select(d => (new Point(c.X + d.dx * a, c.Y + d.dy * a), new Point(c.X + d.dx * b, c.Y + d.dy * b))));

    public static void Paint(HomeSym sym, Point center, int level, global::DrawOffer.App.DesignSystem.Draw context, double scale = 1, double? tail = null)
    {
        var r = Levels[Math.Clamp(level == 0 ? 3 : level, 1, 5) - 1] * scale;
        Microsoft.UI.Xaml.Media.Geometry Circle(double radius) => global::DrawOffer.App.DesignSystem.Draw.Circle(center, radius);
        switch (sym)
        {
            case HomeSym.Mastered: context.Fill(Circle(r), HomeColors.Blue); break;
            case HomeSym.Weak:
                context.Fill(Circle(r), HomeColors.Orange);
                context.Stroke(Rays(center, r + 3, r + 8), HomeColors.Orange, 1.2, round: true);
                break;
            case HomeSym.Pending:
                context.Fill(Circle(4.6), V3.White);
                context.Stroke(Circle(4.6), HomeColors.Soft, 1.4);
                break;
            case HomeSym.Untested: context.Stroke(Rays(center, 3.5, 9), HomeColors.Soft, 1.2, round: true); break;
            case HomeSym.Topic: context.Fill(Circle(2.6), HomeColors.Ink); break;
            case HomeSym.Due:
            {
                var angle = tail ?? DefaultTail;
                double ux = Math.Cos(angle), uy = Math.Sin(angle);
                var tip = new Point(center.X + ux * 28, center.Y + uy * 28);
                var path = global::DrawOffer.App.DesignSystem.Draw.Lines([new Point(center.X - uy * r, center.Y + ux * r), tip, new Point(center.X + uy * r, center.Y - ux * r)], closed: true);
                context.Fill(path, global::DrawOffer.App.DesignSystem.Draw.Gradient(center, tip, (Alpha(HomeColors.Blue, 0.38), 0), (Alpha(HomeColors.Blue, 0), 1)));
                context.Fill(Circle(r), HomeColors.Blue);
                break;
            }
            case HomeSym.Anchor:
            {
                context.Stroke(Rays(center, 7, 17), HomeColors.Ink, 1.2, round: true);
                const double k = 0.7071;
                var diagonal = global::DrawOffer.App.DesignSystem.Draw.Segments(new (double dx, double dy)[] { (k, k), (k, -k), (-k, k), (-k, -k) }
                    .Select(d => (new Point(center.X + d.dx * 5.5, center.Y + d.dy * 5.5), new Point(center.X + d.dx * 9, center.Y + d.dy * 9))));
                context.Stroke(diagonal, HomeColors.Ink, 1, round: true);
                context.Fill(Circle(4.6), HomeColors.Ink);
                break;
            }
            case HomeSym.Planet:
            {
                var ring = global::DrawOffer.App.DesignSystem.Draw.Rotated(global::DrawOffer.App.DesignSystem.Draw.Ellipse(new Rect(center.X - 15 * scale, center.Y - 4.5 * scale, 30 * scale, 9 * scale)), -20, center);
                context.Stroke(ring, HomeColors.Ink, 1.1);
                context.Fill(Circle(7 * scale), V3.White);
                context.Stroke(Circle(7 * scale), HomeColors.Ink, 1.3);
                break;
            }
        }
    }

    /// <summary>独立的小符号画布（列表行、图例、引导里的 `Canvas { … }.frame(width:height:)`），符号画在中心。</summary>
    public static FrameworkElement Glyph(HomeSym sym, double width, double height, int level, double scale = 1)
    {
        var context = new global::DrawOffer.App.DesignSystem.Draw(width, height);
        Paint(sym, new Point(width / 2, height / 2), level, context, scale);
        return context.Surface;
    }
}

/// <summary>背景同心弧与经线（Mac `HomeBackdrop`）。</summary>
public static class HomeBackdrop
{
    public static Canvas Make()
    {
        var context = new global::DrawOffer.App.DesignSystem.Draw(HomeCanvas.Width, HomeCanvas.Height);
        var origin = new Point(575, 1500);
        Point At(double angle, double radius) => new(origin.X + radius * Math.Cos(angle * Math.PI / 180), origin.Y + radius * Math.Sin(angle * Math.PI / 180));
        foreach (var radius in new double[] { 880, 940, 1000, 1060, 1110, 1145, 1180, 1215, 1250, 1285, 1320, 1360 })
        {
            var dashed = radius > 1100 && radius < 1330;
            context.Stroke(global::DrawOffer.App.DesignSystem.Draw.Circle(origin, radius), Alpha(HomeColors.Ink, (int)radius % 2 == 1 ? 0.05 : 0.07), 1, dash: dashed ? [1, 5] : null);
        }
        var meridians = new List<(Point, Point)>();
        for (var angle = -140.0; angle <= -40; angle += 6) meridians.Add((At(angle, 880), At(angle, 1400)));
        context.Stroke(global::DrawOffer.App.DesignSystem.Draw.Segments(meridians), Alpha(HomeColors.Ink, 0.035), 1);
        return context.Surface;
    }
}

/// <summary>地平线（Mac `HorizonView`）：弧下填色、六道渐淡的弧、主弧与刻度。</summary>
public static class HomeHorizon
{
    static Microsoft.UI.Xaml.Media.Geometry Arc(double top, bool close = false)
    {
        var points = new List<Point> { new(0, HomeCanvas.HorizonY(0, top)) };
        for (var x = 0.0; x <= HomeCanvas.Width; x += 8) points.Add(new Point(x, HomeCanvas.HorizonY(x, top)));
        if (close) { points.Add(new Point(HomeCanvas.Width, HomeCanvas.Height)); points.Add(new Point(0, HomeCanvas.Height)); }
        return global::DrawOffer.App.DesignSystem.Draw.Lines(points, close);
    }

    public static Canvas Make()
    {
        var context = new global::DrawOffer.App.DesignSystem.Draw(HomeCanvas.Width, HomeCanvas.Height);
        var top = HomeCanvas.HorizonTop;
        context.Fill(Arc(top, close: true), Hex(0xF2F0EA));
        var offsets = new double[] { 4, 9, 16, 26, 40, 58 };
        for (var i = 0; i < offsets.Length; i++) context.Stroke(Arc(top + offsets[i]), Alpha(Hex(0xCFCABD), 0.9 - i * 0.12), 0.8);
        context.Stroke(Arc(top), HomeColors.Ink, 1.3);
        var ticks = new List<(Point, Point)>();
        var index = 0;
        for (var x = 4.0; x < HomeCanvas.Width; x += 10.4)
        {
            var y = HomeCanvas.HorizonY(x);
            var h = index % 20 == 15 ? 8.0 : index % 4 == 3 ? 5 : index % 2 == 1 ? 3 : 2;
            ticks.Add((new Point(x, y + 1), new Point(x, y + 1 + h)));
            index++;
        }
        context.Stroke(global::DrawOffer.App.DesignSystem.Draw.Segments(ticks), Hex(0xA9A59A), 0.7);
        return context.Surface;
    }
}

/// <summary>地平线上的时间轴（Mac `TimelineView`）：今天的竖刻度、过去的实心点与之后的空心点及标签。</summary>
public static class HomeTimeline
{
    public static Canvas Make(IReadOnlyList<HomeMark> marks, DateTimeOffset now)
    {
        var placed = HomeLayouts.PlaceMarks(marks, now);
        var context = new global::DrawOffer.App.DesignSystem.Draw(HomeCanvas.Width, HomeCanvas.Height);
        var x0 = HomeLayouts.TodayX;
        var y0 = HomeCanvas.HorizonY(x0);
        context.Stroke(global::DrawOffer.App.DesignSystem.Draw.Lines([new Point(x0, y0 - 9), new Point(x0, y0 + 9)]), HomeColors.Ink, 1.6);
        foreach (var (mark, x) in placed)
        {
            var y = HomeCanvas.HorizonY(x);
            var color = HomeColors.Tone(mark.Tone);
            if (mark.Future)
            {
                context.Fill(global::DrawOffer.App.DesignSystem.Draw.Circle(new Point(x, y), 5.5), V3.White);
                context.Stroke(global::DrawOffer.App.DesignSystem.Draw.Circle(new Point(x, y), 5.5), color, 1.2);
                context.Fill(global::DrawOffer.App.DesignSystem.Draw.Circle(new Point(x, y), 2.4), color);
            }
            else context.Fill(global::DrawOffer.App.DesignSystem.Draw.Circle(new Point(x, y), 3), color);
        }
        context.Text(Label("今天", 10, HomeColors.Ink, Medium), new Point(x0, y0 - 21));
        foreach (var (mark, x) in placed)
        {
            var color = HomeColors.Tone(mark.Tone);
            var stack = new StackPanel { Spacing = 1 };
            stack.Children.Add(Label(mark.Label, 10, color, Medium).Align(HorizontalAlignment.Center));
            if (mark.Sub is { } sub) stack.Children.Add(Label(sub, 9.5, color).Align(HorizontalAlignment.Center));
            context.Text(stack, new Point(x, HomeCanvas.HorizonY(x) - (mark.Sub is not null ? 26 : 17)));
        }
        return context.Surface;
    }
}

/// <summary>右上角的图例（Mac `HomeLegend`），右缘对齐 x = 画布宽 − 41、顶 26。</summary>
public static class HomeLegend
{
    public static FrameworkElement Make(IReadOnlyList<(HomeSym sym, string label)> items)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, IsHitTestVisible = false };
        foreach (var (sym, label) in items)
        {
            var item = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            item.Children.Add(HomeSymbols.Glyph(sym, sym == HomeSym.Planet ? 26 : 22, 22, 2, sym is HomeSym.Planet or HomeSym.Anchor ? 0.62 : 1));
            item.Children.Add(Label(label, 10.5, Hex(0x6B6963)).Align(v: VerticalAlignment.Center));
            row.Children.Add(item);
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, "图里的符号");
        var host = new Grid { Width = HomeCanvas.Width - 41 };
        row.HorizontalAlignment = HorizontalAlignment.Right;
        host.Children.Add(row);
        return host.At(0, 26);
    }
}

/// <summary>
/// 星图（Mac `StarMapView`）：区域椭圆、连线、符号与标签。悬停一个点时它与相邻的点保持原样，其余降到 0.25 透明度。
/// 状态（拖动偏移、悬停、选中）变化时整张重画，点数只有几十个。
/// </summary>
public static class HomeStarMap
{
    public static Canvas Make(HomeScene scene, HomeLayout layout, IReadOnlyDictionary<string, Point> offsets, string? picked, string? hover)
    {
        var at = Positions(layout, offsets);
        var lit = hover is null ? null : LitSet(scene, hover);
        var context = new global::DrawOffer.App.DesignSystem.Draw(HomeCanvas.Width, HomeCanvas.Height);
        var region = RegionNow(scene, layout, at, offsets.Count == 0);
        if (region is { } box)
        {
            var dim = lit is not null && !(scene.Region?.Members.Any(lit.Contains) ?? false);
            var layer = context.Layer(dim ? 0.25 : 1);
            var ellipse = global::DrawOffer.App.DesignSystem.Draw.Ellipse(new Rect(box.Cx - box.Rx, box.Cy - box.Ry, box.Rx * 2, box.Ry * 2));
            layer.Fill(ellipse, Alpha(HomeColors.Orange, 0.035));
            layer.Stroke(global::DrawOffer.App.DesignSystem.Draw.Ellipse(new Rect(box.Cx - box.Rx, box.Cy - box.Ry, box.Rx * 2, box.Ry * 2)), Alpha(HomeColors.Orange, 0.75), 1, dash: [4, 4]);
        }
        Edges(scene, at, lit, hover, context);
        foreach (var node in scene.Nodes)
        {
            if (!at.TryGetValue(node.Id, out var point)) continue;
            var layer = context.Layer(lit is not null && !lit.Contains(node.Id) ? 0.25 : 1);
            HomeSymbols.Paint(node.Sym, point, node.Level ?? 3, layer, tail: TailFor(node, at));
            if (picked == node.Id)
            {
                var ring = HomeSymbols.Radius(node.Sym, node.Level ?? 3) + 4;
                layer.Stroke(global::DrawOffer.App.DesignSystem.Draw.Circle(point, ring), Alpha(HomeColors.Blue, 0.6), 1);
            }
        }
        foreach (var planet in scene.Planets)
        {
            if (!at.TryGetValue(planet.Id, out var point)) continue;
            HomeSymbols.Paint(HomeSym.Planet, point, 3, context.Layer(lit is not null && !lit.Contains(planet.Id) ? 0.25 : 1));
        }
        foreach (var node in scene.Nodes)
            if (at.TryGetValue(node.Id, out var point) && node.Label.Length > 0)
                NodeLabel(context, node.Label, node.Sub, node.SubTone, node.Badge, node.Sym, node.Level ?? 3, point, Side(layout, node.Id), lit is null || lit.Contains(node.Id));
        foreach (var planet in scene.Planets)
            if (at.TryGetValue(planet.Id, out var point))
                NodeLabel(context, planet.Label, planet.Sub, planet.SubTone, null, HomeSym.Planet, 3, point, Side(layout, planet.Id), lit is null || lit.Contains(planet.Id));
        if (region is { } titled && scene.Region?.Title is { Length: > 0 } title)
        {
            var text = Label(title, 10.5, HomeColors.Orange, Medium);
            text.CharacterSpacing = Spacing(2, 10.5);
            context.Text(text, new Point(titled.Cx, titled.TitleY - 4));
        }
        context.Surface.IsHitTestVisible = false;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(context.Surface, scene.Title.Length == 0 ? scene.MapTitle : scene.Title);
        return context.Surface;
    }

    /// <summary>SwiftUI `.tracking(pt)` 换算成 WinUI 的 CharacterSpacing（千分之一 em）。</summary>
    public static int Spacing(double tracking, double size) => (int)Math.Round(tracking / size * 1000);

    static HomeSide Side(HomeLayout layout, string id) => layout.At.TryGetValue(id, out var placed) ? placed.Side : HomeSide.R;

    public static Dictionary<string, Point> Positions(HomeLayout layout, IReadOnlyDictionary<string, Point> offsets)
    {
        var output = new Dictionary<string, Point>();
        foreach (var (id, placed) in layout.At)
        {
            var offset = offsets.TryGetValue(id, out var value) ? value : default;
            output[id] = new Point(placed.X + offset.X, placed.Y + offset.Y);
        }
        return output;
    }

    static HashSet<string> LitSet(HomeScene scene, string id)
    {
        var output = new HashSet<string> { id };
        foreach (var edge in scene.Edges) { if (edge.From == id) output.Add(edge.To); if (edge.To == id) output.Add(edge.From); }
        foreach (var planet in scene.Planets)
        {
            if (planet.Id == id) output.UnionWith(planet.Links);
            if (planet.Links.Contains(id)) output.Add(planet.Id);
        }
        return output;
    }

    static HomeRegionBox? RegionNow(HomeScene scene, HomeLayout layout, Dictionary<string, Point> at, bool untouched)
    {
        if (untouched) return layout.Region;
        var placed = new Dictionary<string, HomePlaced>();
        foreach (var (id, point) in at) placed[id] = new HomePlaced(point.X, point.Y, Side(layout, id));
        return HomeLayouts.Region(scene, placed);
    }

    static (Point start, Point end, double ux, double uy) Trimmed(Point a, Point b, double ra, double rb)
    {
        double dx = b.X - a.X, dy = b.Y - a.Y, length = Math.Max(Math.Sqrt(dx * dx + dy * dy), 1);
        double ux = dx / length, uy = dy / length;
        return (new Point(a.X + ux * ra, a.Y + uy * ra), new Point(b.X - ux * rb, b.Y - uy * rb), ux, uy);
    }

    static void Edges(HomeScene scene, Dictionary<string, Point> at, HashSet<string>? lit, string? hover, global::DrawOffer.App.DesignSystem.Draw context)
    {
        var byId = new Dictionary<string, HomeMapNode>();
        foreach (var node in scene.Nodes) byId.TryAdd(node.Id, node);
        double Radius(string id) => byId.TryGetValue(id, out var node) ? HomeSymbols.Radius(node.Sym, node.Level ?? 3) : HomeSymbols.Radius(HomeSym.Planet);
        foreach (var edge in scene.Edges)
        {
            if (!at.TryGetValue(edge.From, out var a) || !at.TryGetValue(edge.To, out var b)) continue;
            var (start, end, ux, uy) = Trimmed(a, b, Radius(edge.From) + 2, Radius(edge.To) + 2);
            var on = lit is not null && lit.Contains(edge.From) && lit.Contains(edge.To) && (edge.From == hover || edge.To == hover);
            var layer = context.Layer(lit is not null && !on ? 0.25 : 1);
            if (edge.Prereq)
            {
                layer.Stroke(global::DrawOffer.App.DesignSystem.Draw.Lines([start, new Point(end.X - ux * 6, end.Y - uy * 6)]), HomeColors.Orange, 1.2);
                double px = -uy, py = ux;
                layer.Fill(global::DrawOffer.App.DesignSystem.Draw.Lines([end, new Point(end.X - ux * 7 + px * 3.2, end.Y - uy * 7 + py * 3.2), new Point(end.X - ux * 7 - px * 3.2, end.Y - uy * 7 - py * 3.2)], closed: true), HomeColors.Orange);
                layer.Text(Label("前置", 10.5, HomeColors.Orange), new Point((start.X + end.X) / 2 + px * 12, (start.Y + end.Y) / 2 + py * 12));
                continue;
            }
            var line = global::DrawOffer.App.DesignSystem.Draw.Lines([start, end]);
            if (on) layer.Stroke(line, Alpha(HomeColors.Blue, 0.85), 1.1, round: true);
            else layer.Stroke(line, global::DrawOffer.App.DesignSystem.Draw.Gradient(start, end,
                (Alpha(HomeColors.Soft, 0.9), 0), (Alpha(HomeColors.Soft, 0.5), 0.55), (Alpha(HomeColors.Soft, 0.18), 1)), 0.8, round: true);
        }
        foreach (var planet in scene.Planets)
        {
            if (!at.TryGetValue(planet.Id, out var a)) continue;
            foreach (var target in planet.Links)
            {
                if (!at.TryGetValue(target, out var b)) continue;
                var (start, end, _, _) = Trimmed(a, b, HomeSymbols.Radius(HomeSym.Planet) + 2, Radius(target) + 2);
                var on = lit is not null && lit.Contains(planet.Id) && lit.Contains(target);
                var layer = context.Layer(lit is not null && !on ? 0.25 : 1);
                layer.Stroke(global::DrawOffer.App.DesignSystem.Draw.Lines([start, end]), on ? Alpha(HomeColors.Blue, 0.85) : Alpha(HomeColors.Soft, 0.7),
                    on ? 1 : 0.8, round: true, dash: on ? [3, 3] : [1, 4]);
            }
        }
    }

    /// <summary>彗尾朝向：四个斜向里第一个与父节点方向相差超过 0.9 弧度的。</summary>
    static double TailFor(HomeMapNode node, Dictionary<string, Point> at)
    {
        if (!at.TryGetValue(node.Id, out var me)) return HomeSymbols.DefaultTail;
        double? avoid = node.Parent is { } parent && at.TryGetValue(parent, out var p) ? Math.Atan2(p.Y - me.Y, p.X - me.X) : null;
        double[] options = [Math.Atan2(-0.6, -1), Math.Atan2(-0.6, 1), Math.Atan2(0.6, 1), Math.Atan2(0.6, -1)];
        static double Diff(double a, double b) { var d = Math.Abs(a - b) % (2 * Math.PI); return d > Math.PI ? 2 * Math.PI - d : d; }
        foreach (var option in options) if (avoid is null || Diff(option, avoid.Value) > 0.9) return option;
        return options[0];
    }

    /// <summary>节点标签（Mac `NodeLabel`）：按朝向把文字的对应锚点放到符号外 gap 处，名字行竖直居中于符号。</summary>
    static void NodeLabel(global::DrawOffer.App.DesignSystem.Draw context, string label, string? sub, HomeTone? subTone, int? badge, HomeSym sym, int level, Point point, HomeSide side, bool on)
    {
        var big = sym == HomeSym.Anchor;
        var gap = HomeSymbols.Radius(sym, level) + (big ? 4 : 5);
        var align = side == HomeSide.R ? HorizontalAlignment.Left : side == HomeSide.L ? HorizontalAlignment.Right : HorizontalAlignment.Center;
        var stack = new StackPanel { Spacing = 1, Opacity = on ? 1 : 0.25 };
        var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, HorizontalAlignment = align };
        if (badge is { } count)
            name.Children.Add(new Border { Width = 15, Height = 15, CornerRadius = new CornerRadius(7.5), Background = Brush(HomeColors.Orange),
                Child = Label($"{count}", 10, V3.White, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center) });
        name.Children.Add(big ? Serif(label, 20, HomeColors.Ink) : Label(label, 12, HomeColors.Ink, Medium));
        stack.Children.Add(name);
        if (sub is not null) stack.Children.Add(Label(sub, big ? 11 : 10.5, HomeColors.Tone(subTone ?? HomeTone.Soft)).Align(align));
        var nameHeight = (big ? 20.0 : 12) * 1.35;
        switch (side)
        {
            case HomeSide.R: context.Text(stack, new Point(point.X + gap, point.Y - nameHeight / 2), 0, 0); break;
            case HomeSide.L: context.Text(stack, new Point(point.X - gap, point.Y - nameHeight / 2), 1, 0); break;
            case HomeSide.T: context.Text(stack, new Point(point.X, point.Y - gap), 0.5, 1); break;
            default: context.Text(stack, new Point(point.X, point.Y + gap), 0.5, 0); break;
        }
    }
}
