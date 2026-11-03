using System.Text;

namespace DrawOffer.Core.Home;

// 首页星图摆放：移植 Web `homeImprove/layout.ts`（1151×828 设计稿坐标）。
// 主星落在右侧几处错开的位置，下面的点朝外散开；简历连到所有主星时放在中间当枢纽；最后推开太近的点并挑标签朝向。

public enum HomeSide { R, L, T, B }

/// <summary>一个点的位置与标签朝向（Swift 结构体，字段可改）。</summary>
public sealed record HomePlaced
{
    public double X { get; set; }
    public double Y { get; set; }
    public HomeSide Side { get; set; }
    public HomePlaced(double x, double y, HomeSide side) { X = x; Y = y; Side = side; }
}

/// <summary>区域椭圆：Swift `region: (cx, cy, rx, ry, titleY)?`。</summary>
public sealed record HomeRegionBox(double Cx, double Cy, double Rx, double Ry, double TitleY);

public sealed class HomeLayout(Dictionary<string, HomePlaced> at, HomeRegionBox? region)
{
    public Dictionary<string, HomePlaced> At { get; set; } = at;
    public HomeRegionBox? Region { get; set; } = region;
}

public static class HomeCanvas
{
    public const double Width = 1151.0;
    public const double Height = 828.0;
    public const double HorizonTop = 668.0;
    const double HorizonR = 2397.0;

    public static double HorizonY(double x, double top = HorizonTop)
    {
        var d = x - Width / 2;
        return top + HorizonR - Math.Sqrt(HorizonR * HorizonR - d * d);
    }
}

public static class HomeLayouts
{
    static readonly (double L, double R, double T, double B) Area = (490.0, 1085.0, 112.0, 600.0);
    static readonly (double L, double LowL, double LowT, double R, double T) Text = (470.0, 385.0, 150.0, 1138.0, 70.0);
    static readonly (double X, double Y) Center = (800.0, 345.0);
    static readonly Dictionary<int, (double, double)[]> Slots = new()
    {
        [1] = [(760, 300)], [2] = [(650, 235), (930, 430)], [3] = [(640, 220), (965, 235), (815, 470)],
        [4] = [(610, 200), (925, 165), (665, 455), (995, 420)],
        [5] = [(600, 190), (880, 150), (1020, 330), (650, 450), (880, 505)],
        [6] = [(590, 180), (840, 140), (1030, 255), (640, 420), (870, 380), (1000, 520)],
    };

    /// <summary>FNV-1a（按 UTF-16 码元），取 0–0.999。</summary>
    internal static double Hash(string text)
    {
        uint value = 2166136261;
        foreach (var unit in text) value = unchecked((value ^ unit) * 16777619);
        return (value % 1000) / 1000.0;
    }

    static double Jitter(string key, double span) => (Hash(key) - 0.5) * 2 * span;

    static double Hypot(double x, double y) => double.Hypot(x, y);

    static void Clamp(ref double x, ref double y, double top)
    {
        x = Math.Min(Area.R, Math.Max(Area.L, x));
        y = Math.Min(Math.Min(Area.B, HomeCanvas.HorizonY(x) - 72), Math.Max(top, y));
    }

    static void Clamp(HomePlaced point, double top)
    {
        double x = point.X, y = point.Y;
        Clamp(ref x, ref y, top);
        point.X = x; point.Y = y;
    }

    internal readonly record struct Box(double L, double R, double T, double B);

    static double Overlap(Box a, Box b) =>
        Math.Max(0, Math.Min(a.R, b.R) - Math.Max(a.L, b.L) + 6) * Math.Max(0, Math.Min(a.B, b.B) - Math.Max(a.T, b.T) + 6);

    /// <summary>估算文字宽度：CJK 区（U+2E80–U+FFEF）按一个字号，其余按 0.6 个字号；按 Unicode 标量计。</summary>
    public static double TextWidth(string text, double size)
    {
        double width = 0;
        foreach (var rune in text.EnumerateRunes()) width += rune.Value is >= 0x2E80 and <= 0xFFEF ? size : size * 0.6;
        return width;
    }

    static Box LabelBox(string label, string? sub, HomeSym sym, int? badge, (double X, double Y) at, HomeSide side)
    {
        var big = sym == HomeSym.Anchor;
        var gap = big ? 23.0 : sym == HomeSym.Planet ? 21 : 13;
        var width = Math.Max(TextWidth(label, big ? 20 : 12), sub is not null ? TextWidth(sub, big ? 11 : 10.5) : 0) + (badge is not null ? 20 : 0);
        var height = (big ? 27.0 : 16) + (sub is not null ? 15 : 0);
        return side switch
        {
            HomeSide.R => new Box(at.X + gap, at.X + gap + width, at.Y - 10, at.Y - 10 + height),
            HomeSide.L => new Box(at.X - gap - width, at.X - gap, at.Y - 10, at.Y - 10 + height),
            HomeSide.T => new Box(at.X - width / 2, at.X + width / 2, at.Y - gap - height, at.Y - gap),
            _ => new Box(at.X - width / 2, at.X + width / 2, at.Y + gap, at.Y + gap + height),
        };
    }

    static bool Fits(Box box) =>
        box.L >= (box.T >= Text.LowT ? Text.LowL : Text.L) && box.R <= Text.R && box.T >= Text.T && box.B <= HomeCanvas.HorizonY((box.L + box.R) / 2) - 40;

    static double SideAngle(HomeSide side) => side switch { HomeSide.R => 0, HomeSide.B => Math.PI / 2, HomeSide.L => Math.PI, _ => -Math.PI / 2 };

    static double AngleGap(double a, double b)
    {
        var d = Math.Abs(a - b) % (2 * Math.PI);
        return d > Math.PI ? 2 * Math.PI - d : d;
    }

    static HomeSide SideOf(double dx, double dy)
    {
        var length = Math.Max(Hypot(dx, dy), 1);
        if (dx / length > 0.38) return HomeSide.R;
        if (dx / length < -0.38) return HomeSide.L;
        return dy < 0 ? HomeSide.T : HomeSide.B;
    }

    public static HomeLayout Layout(HomeScene scene)
    {
        var at = new Dictionary<string, HomePlaced>();
        var top = scene.MapTitle.Length > 0 || scene.MapNote.Length > 0 ? 165.0 : Area.T;
        (double, double) Place(double x, double y) { Clamp(ref x, ref y, top); return (x, y); }
        var anchors = scene.Nodes.Where(x => x.Sym == HomeSym.Anchor).ToList();
        var hub = scene.Planets.Count == 1 && anchors.Count >= 2 && anchors.All(x => scene.Planets[0].Links.Contains(x.Id));
        var count = Math.Min(6, Math.Max(1, anchors.Count));
        for (var index = 0; index < Math.Min(6, anchors.Count); index++)
        {
            var anchor = anchors[index];
            double x, y;
            if (hub)
            {
                var angle = -Math.PI * 0.82 + index * 2 * Math.PI / anchors.Count + Jitter(anchor.Id, 0.18);
                x = Center.X + Math.Cos(angle) * 235; y = Center.Y + Math.Sin(angle) * 185;
            }
            else
            {
                (x, y) = Slots[count][index];
                x += Jitter(anchor.Id, 16); y += Jitter($"{anchor.Id}y", 14);
            }
            var point = Place(x, y);
            at[anchor.Id] = new HomePlaced(point.Item1, point.Item2, y < 175 ? HomeSide.R : HomeSide.T);
        }
        if (hub) at[scene.Planets[0].Id] = new HomePlaced(Center.X, Center.Y, HomeSide.B);

        void Fan(HomeMapNode parent, (double X, double Y) origin, (double X, double Y) from, double radius)
        {
            var kids = scene.Nodes.Where(x => x.Parent == parent.Id && x.Sym != HomeSym.Anchor).ToList();
            if (kids.Count == 0) return;
            var baseAngle = Math.Atan2(origin.Y - from.Y, origin.X - from.X);
            var step = kids.Count > 4 ? 0.72 : 0.92;
            for (var index = 0; index < kids.Count; index++)
            {
                var kid = kids[index];
                var angle = baseAngle + (index - (kids.Count - 1) / 2.0) * step + Jitter(kid.Id, 0.16);
                var r = radius + Jitter($"{kid.Id}r", 14) + (kid.Sym == HomeSym.Topic ? -18 : 0);
                var point = Place(origin.X + Math.Cos(angle) * r, origin.Y + Math.Sin(angle) * r);
                at[kid.Id] = new HomePlaced(point.Item1, point.Item2, SideOf(point.Item1 - origin.X, point.Item2 - origin.Y));
                if (kid.Sym == HomeSym.Topic) Fan(kid, point, origin, 92);
            }
        }
        foreach (var anchor in anchors)
        {
            if (!at.TryGetValue(anchor.Id, out var origin)) continue;
            if (hub) { Fan(anchor, (origin.X, origin.Y), (Center.X, Center.Y), 108); continue; }
            var dx = origin.X > Center.X ? 1.0 : -1.0;
            var dir = origin.Y < Center.Y ? (dx * 0.7, 1.0) : (dx * 0.6, 0.8);
            Fan(anchor, (origin.X, origin.Y), (origin.X - dir.Item1 * 50, origin.Y - dir.Item2 * 50), 108);
        }
        var corner = 0.0;
        foreach (var planet in scene.Planets)
        {
            if (at.ContainsKey(planet.Id)) continue;
            if (planet.Near && planet.Links.Count > 0 && at.TryGetValue(planet.Links[0], out var target))
            {
                var near = Place(target.X - 115, target.Y - 22);
                at[planet.Id] = new HomePlaced(near.Item1, near.Item2, HomeSide.B);
                continue;
            }
            var point = Place(985 + Jitter(planet.Id, 10), 560 - corner * 56);
            at[planet.Id] = new HomePlaced(point.Item1, point.Item2, HomeSide.R);
            corner += 1;
        }
        Relax(scene, at, top);
        ClearRegion(scene, at, top);
        ChooseSides(scene, at);
        return new HomeLayout(at, Region(scene, at));
    }

    static void Relax(HomeScene scene, Dictionary<string, HomePlaced> at, double top)
    {
        var ids = scene.Nodes.Select(x => x.Id).Concat(scene.Planets.Select(x => x.Id)).Where(at.ContainsKey).ToList();
        var anchors = scene.Nodes.Where(x => x.Sym == HomeSym.Anchor).Select(x => x.Id).ToHashSet();
        for (var round = 0; round < 60; round++)
        {
            var moved = false;
            for (var i = 0; i < ids.Count; i++)
            {
                for (var j = i + 1; j < ids.Count; j++)
                {
                    // Swift 里 a、b 是值拷贝；这里先取坐标，写回时再更新字典里的点。
                    var a = at[ids[i]] with { };
                    var b = at[ids[j]] with { };
                    var need = anchors.Contains(ids[i]) && anchors.Contains(ids[j]) ? 190.0 : anchors.Contains(ids[i]) || anchors.Contains(ids[j]) ? 70 : 58;
                    double dx = b.X - a.X, dy = (b.Y - a.Y) * 1.6;
                    var distance = Math.Max(Hypot(dx, dy), 0.01);
                    if (distance >= need) continue;
                    double push = (need - distance) / 2, ux = dx / distance, uy = dy / distance / 1.6;
                    var fixedA = anchors.Contains(ids[i]) && !anchors.Contains(ids[j]);
                    var fixedB = anchors.Contains(ids[j]) && !anchors.Contains(ids[i]);
                    if (!fixedA) { a.X -= ux * push * (fixedB ? 2 : 1); a.Y -= uy * push * (fixedB ? 2 : 1); Clamp(a, top); at[ids[i]] = a; }
                    if (!fixedB) { b.X += ux * push * (fixedA ? 2 : 1); b.Y += uy * push * (fixedA ? 2 : 1); Clamp(b, top); at[ids[j]] = b; }
                    moved = true;
                }
            }
            if (!moved) break;
        }
    }

    static void ClearRegion(HomeScene scene, Dictionary<string, HomePlaced> at, double top)
    {
        var members = (scene.Region?.Members ?? []).ToHashSet();
        var points = members.Where(at.ContainsKey).Select(x => at[x]).ToList();
        if (points.Count < 2) return;
        double l = points.Min(x => x.X) - 70, r = points.Max(x => x.X) + 120;
        double t = points.Min(x => x.Y) - 50, b = points.Max(x => x.Y) + 50;
        double cx = (l + r) / 2, cy = (t + b) / 2, rx = (r - l) / 2, ry = (b - t) / 2;
        bool Inside(double x, double y) => Math.Pow((x - cx) / (rx + 40), 2) + Math.Pow((y - cy) / (ry + 40), 2) < 1;
        foreach (var anchor in scene.Nodes)
        {
            if (anchor.Sym != HomeSym.Anchor || members.Contains(anchor.Id)) continue;
            var group = scene.Nodes.Where(x => x.Group == anchor.Id && !members.Contains(x.Id)).ToList();
            if (!at.TryGetValue(anchor.Id, out var origin) || scene.Nodes.Any(x => x.Group == anchor.Id && members.Contains(x.Id))) continue;
            double dx = origin.X - cx == 0 ? 1 : origin.X - cx, dy = origin.Y - cy == 0 ? 1 : origin.Y - cy;
            var length = Hypot(dx, dy);
            var step = 0;
            while (step < 12 && at.TryGetValue(anchor.Id, out var now) && (Inside(now.X, now.Y) || Inside(now.X, now.Y - 40)))
            {
                foreach (var item in group)
                {
                    if (!at.TryGetValue(item.Id, out var current)) continue;
                    var point = current with { };
                    point.X += dx / length * 18; point.Y += dy / length * 18;
                    Clamp(point, top); at[item.Id] = point;
                }
                step += 1;
            }
        }
    }

    static void ChooseSides(HomeScene scene, Dictionary<string, HomePlaced> at)
    {
        var taken = scene.Nodes.Where(x => at.ContainsKey(x.Id)).Select(x => at[x.Id]).Select(p => new Box(p.X - 7, p.X + 7, p.Y - 7, p.Y + 7))
            .Concat(scene.Planets.Where(x => at.ContainsKey(x.Id)).Select(x => at[x.Id]).Select(p => new Box(p.X - 16, p.X + 16, p.Y - 8, p.Y + 8))).ToList();
        foreach (var edge in scene.Edges)
        {
            if (!edge.Prereq || !at.TryGetValue(edge.From, out var a) || !at.TryGetValue(edge.To, out var b)) continue;
            var length = Math.Max(Hypot(b.X - a.X, b.Y - a.Y), 1);
            double x = (a.X + b.X) / 2 - (b.Y - a.Y) / length * 12, y = (a.Y + b.Y) / 2 + (b.X - a.X) / length * 12;
            taken.Add(new Box(x - 14, x + 14, y - 10, y + 4));
        }
        void Choose(string id, string label, string? sub, HomeSym sym, int? badge, IReadOnlyList<HomeSide> order)
        {
            if (!at.TryGetValue(id, out var current)) return;
            var me = current with { };
            var own = new Box(me.X - 17, me.X + 17, me.Y - 9, me.Y + 9);
            (HomeSide Side, Box Box, double Cost)? best = null;
            var seen = new List<HomeSide>();
            foreach (var side in order)
            {
                if (seen.Contains(side)) continue;
                seen.Add(side);
                var box = LabelBox(label, sub, sym, badge, (me.X, me.Y), side);
                var cost = (Fits(box) ? 0 : 1e6) + taken.Aggregate(0.0, (sum, other) => sum + (Overlap(other, own) > 0 ? 0 : Overlap(box, other)));
                if (best is null || cost < best.Value.Cost) best = (side, box, cost);
                if (cost == 0) break;
            }
            me.Side = best!.Value.Side; at[id] = me; taken.Add(best.Value.Box);
        }
        var ordered = scene.Nodes.Where(x => x.Sym == HomeSym.Anchor).Concat(scene.Nodes.Where(x => x.Sym != HomeSym.Anchor)).ToList();
        foreach (var node in ordered)
        {
            if (!at.TryGetValue(node.Id, out var me)) continue;
            var lineIDs = scene.Nodes.Where(x => x.Parent == node.Id).Select(x => x.Id)
                .Concat(node.Parent is { } p ? [p] : [])
                .Concat(scene.Planets.Where(x => x.Links.Contains(node.Id)).Select(x => x.Id));
            var lines = lineIDs.Where(at.ContainsKey).Select(x => at[x]).Select(x => Math.Atan2(x.Y - me.Y, x.X - me.X)).ToList();
            HomePlaced? parent = node.Parent is { } parentID && at.TryGetValue(parentID, out var found) ? found : null;
            double Clearance(HomeSide side) =>
                (lines.Count == 0 ? Math.PI : lines.Select(x => AngleGap(x, SideAngle(side))).Min()) + (side == HomeSide.T ? 0.05 : 0);
            // Swift 的 sorted 是稳定排序；OrderByDescending 同样稳定。
            IReadOnlyList<HomeSide> order = node.Sym == HomeSym.Anchor
                ? new[] { HomeSide.T, HomeSide.B, HomeSide.R, HomeSide.L }.OrderByDescending(Clearance).ToList()
                : [parent is not null ? SideOf(me.X - parent.X, me.Y - parent.Y) : me.Side, HomeSide.R, HomeSide.L, HomeSide.B, HomeSide.T];
            Choose(node.Id, node.Label, node.Sub, node.Sym, node.Badge, order);
        }
        foreach (var planet in scene.Planets)
        {
            if (!at.TryGetValue(planet.Id, out var me)) continue;
            Choose(planet.Id, planet.Label, planet.Sub, HomeSym.Planet, null, [me.Side, HomeSide.R, HomeSide.L, HomeSide.B, HomeSide.T]);
        }
    }

    public static HomeRegionBox? Region(HomeScene scene, IReadOnlyDictionary<string, HomePlaced> at)
    {
        if (scene.Region?.Members is not { } members) return null;
        var byId = new Dictionary<string, HomeMapNode>();
        foreach (var node in scene.Nodes) byId.TryAdd(node.Id, node);
        var boxes = new List<Box>();
        foreach (var id in members)
        {
            if (!at.TryGetValue(id, out var point)) continue;
            var box = byId.TryGetValue(id, out var node)
                ? LabelBox(node.Label, node.Sub, node.Sym, node.Badge, (point.X, point.Y), point.Side)
                : new Box(point.X, point.X, point.Y, point.Y);
            boxes.Add(new Box(Math.Min(box.L, point.X - 10), Math.Max(box.R, point.X + 10), Math.Min(box.T, point.Y - 10), Math.Max(box.B, point.Y + 10)));
        }
        if (boxes.Count < 2) return null;
        double l = boxes.Min(x => x.L), r = boxes.Max(x => x.R), t = boxes.Min(x => x.T), b = boxes.Max(x => x.B);
        double cy = (t + b) / 2, ry = Math.Max(70, (b - t) / 2 * 1.22 + 8);
        return new HomeRegionBox((l + r) / 2, cy, Math.Max(90, (r - l) / 2 * 1.22 + 8), ry, cy - ry - 9);
    }

    /// <summary>时间轴：今天固定在 730，过去往左、之后往右（Web `placeMarks`）。</summary>
    public const double TodayX = 730.0;

    public static List<(HomeMark mark, double x)> PlaceMarks(IEnumerable<HomeMark> marks, DateTimeOffset now)
    {
        var list = marks.ToList();
        var past = list.Where(x => !x.Future).OrderByDescending(x => x.At).ToList();
        var future = list.Where(x => x.Future).OrderBy(x => x.At).ToList();
        var placed = new List<(HomeMark mark, double x)>();
        var edge = TodayX - 40;
        foreach (var mark in past)
        {
            var days = (now - mark.At).TotalSeconds / 86_400;
            var x = Math.Max(260, Math.Min(edge, TodayX - 30 - days * 12));
            placed.Add((mark, x)); edge = x - 82;
        }
        edge = TodayX + 60;
        foreach (var mark in future)
        {
            var days = (mark.At - now).TotalSeconds / 86_400;
            var x = Math.Min(1060, Math.Max(edge, TodayX + 50 + days * 26));
            placed.Add((mark, x)); edge = x + 110;
        }
        return placed.Where(x => x.x >= 250).ToList();
    }
}
