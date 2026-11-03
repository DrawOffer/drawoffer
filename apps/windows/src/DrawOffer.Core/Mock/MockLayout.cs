namespace DrawOffer.Core.Models;

/// <summary>Mac MockLayout：一题一槽与题名、扇区候选位置防撞。</summary>
public static class MockLayout
{
    public readonly record struct Box(double L, double T, double R, double B);
    public enum Align { Left, Right, Center }
    public sealed record Label(double X, double Y, Align Align, Box Box, int Lines, double Width, bool Far);
    public sealed record SectorLabel(double X, double Y, Box Box);
    public const string JobSector = "岗位要求", MaterialSector = "资料";
    const string OtherSector = "其他";
    static string Clean(string text) => MockText.Lower(string.Concat(SwiftText.Elements(text).Where(c => !"「」…".Contains(c, StringComparison.Ordinal) && !SwiftText.IsWhitespace(c))));
    static bool Similar(string a, string b) { var x = Clean(a); var y = Clean(b); return x.Length > 0 && y.Length > 0 && (MockText.Contains(x, y) || MockText.Contains(y, x)); }
    static string Short(string text, int limit) => MockMap.ShortLabel(text, limit);
    public static string Group(MockMap.Round round, IReadOnlyList<MockMap.Point> memory, Func<string?, string?>? experienceOf)
    {
        var main = round.Main;
        if (main.Text("anchor_kind") == "resume")
        {
            var content = main.Text("content"); string? quoted = null;
            var open = content.IndexOf('「'); var close = open < 0 ? -1 : content.IndexOf('」', open + 1);
            if (close >= 0 && SwiftText.Count(content[(open + 1)..close]) >= 4) quoted = content[(open + 1)..close];
            return experienceOf?.Invoke(main.Text("anchor")) ?? experienceOf?.Invoke(quoted) ?? experienceOf?.Invoke(main.Text("topic")) ?? MockMap.ProjectSector;
        }
        if (main.Text("anchor_kind") == "intro") return MockMap.ExpressSector;
        var known = memory.FirstOrDefault(p => Similar(p.Name, round.Topic));
        if (known is not null && !known.Sector.StartsWith("__empty_", StringComparison.Ordinal) && known.Sector != MockMap.ProjectSector) return known.Sector;
        return main.Text("anchor_kind") switch { "job" => JobSector, "material" => MaterialSector, _ => OtherSector };
    }
    public sealed record Slots(List<MockMap.Point> Points, List<MockMap.Sector> Sectors, List<MockMap.PathStep> Path, List<double> Bounds, List<MockMap.Round> Rounds);
    public static Slots? SlotsOf(System.Text.Json.Nodes.JsonNode? detail, IReadOnlyList<MockMap.Point> memory, Func<string?, string?>? experienceOf = null)
    {
        var rounds = MockMap.Rounds(detail).Where(r => !r.Intro).ToList(); if (rounds.Count == 0) return null;
        var groups = new List<string>(); var by = new Dictionary<string, string>();
        foreach (var round in rounds) { var name = Short(Group(round, memory, experienceOf), 8); by[round.Main.Display("id")] = name; if (!groups.Contains(name)) groups.Add(name); }
        var ordered = groups.SelectMany(name => rounds.Where(r => by[r.Main.Display("id")] == name)).ToList();
        var step = 360.0 / ordered.Count; var angles = new Dictionary<string, double>();
        for (var i = 0; i < ordered.Count; i++) angles[ordered[i].Main.Display("id")] = -150 + i * step;
        var limit = rounds.Count >= 8 ? 8 : rounds.Count >= 6 ? 10 : 12;
        var points = rounds.Select(r => { var id = r.Main.Display("id"); return new MockMap.Point("q:" + id, Short(r.Topic, limit), by[id], angles[id], Math.Max(1, r.To), 2); }).ToList();
        var sectors = groups.Select(name => { var own = ordered.Where(r => by[r.Main.Display("id")] == name).Select(r => angles[r.Main.Display("id")]).ToList(); return new MockMap.Sector(name, (own.Min() + own.Max()) / 2); }).ToList();
        var bounds = groups.Count > 1 ? groups.Select(name => angles[ordered.First(r => by[r.Main.Display("id")] == name).Main.Display("id")] - step / 2).ToList() : [];
        return new(points, sectors, rounds.Select(r => new MockMap.PathStep("q:" + r.Main.Display("id"), r.From, r.To, r.Ok)).ToList(), bounds, rounds);
    }
    public const double SectorRadius = 284, LabelSize = 11.5, NowSize = 12.5, NoteLine = 15, SectorSize = 11, SubSize = 10.5;
    const double LabelH = 17, PointR = 12, NowR = 26, StrongR = 20;
    public static double TextWidth(string text, double size) => SwiftText.Elements(text).Sum(c => (c.Length == 1 && c[0] is >= ' ' and <= '~' ? .56 : 1) * size);
    sealed record Shape(Box? Box = null, double X = 0, double Y = 0, double R = 0);
    static double Overlap(Box box, Shape shape)
    {
        if (shape.Box is { } other) return Math.Max(0, Math.Min(box.R, other.R) - Math.Max(box.L, other.L)) * Math.Max(0, Math.Min(box.B, other.B) - Math.Max(box.T, other.T));
        var dx = Math.Max(Math.Max(box.L - shape.X, 0), shape.X - box.R); var dy = Math.Max(Math.Max(box.T - shape.Y, 0), shape.Y - box.B);
        var distance = Math.Sqrt(dx * dx + dy * dy); return distance < shape.R ? (shape.R - distance) * shape.R * 2 : 0;
    }
    public sealed class Input(MockMap.Geo g, List<MockMap.Placed> points, List<MockMap.PathStep> path, List<MockMap.Sector> sectors, Box frame)
    {
        public MockMap.Geo G { get; set; } = g;
        public List<MockMap.Placed> Points { get; set; } = points;
        public List<MockMap.PathStep> Path { get; set; } = path;
        public List<MockMap.Sector> Sectors { get; set; } = sectors;
        public Box Frame { get; set; } = frame;
        public string? Now { get; set; }
        public int NowLines { get; set; }
        public double NowLineWidth { get; set; }
        public Box? SectorFrame { get; set; }
        public List<Box> Obstacles { get; set; } = [];
        public List<string>? LabelIds { get; set; }
        public bool BandLabels { get; set; } = true;
        public Dictionary<string, string> Subs { get; set; } = [];
        public List<string> Strong { get; set; } = [];
        public double? GapTo { get; set; }
    }
    static List<Shape> MarkShapes(Input input)
    {
        var g = input.G; var shapes = new List<Shape>(); var by = input.Points.GroupBy(p => p.Point.Id).ToDictionary(p => p.Key, p => p.First());
        foreach (var placed in input.Points) shapes.Add(new(X: placed.X, Y: placed.Y, R: placed.Point.Id == input.Now ? NowR : input.Strong.Contains(placed.Point.Id) ? StrongR : PointR));
        if (input.GapTo is { } gap) foreach (var placed in input.Points.Where(p => p.Point.Level > 0 && p.Point.Level < gap && !p.Point.Pending))
            for (var radius = g.RingOf(gap); radius < Math.Sqrt(Math.Pow(placed.X - g.Cx, 2) + Math.Pow(placed.Y - g.Cy, 2)); radius += 6) { var p = g.P(placed.Point.Angle, radius); shapes.Add(new(X: p.X, Y: p.Y, R: 3)); }
        (double X, double Y)? previous = null;
        foreach (var step in input.Path)
        {
            if (!by.TryGetValue(step.Id, out var placed)) continue;
            var from = g.ROf(Math.Max(1, step.From)); var to = g.ROf(Math.Max(1, step.To)); var badge = g.P(placed.Point.Angle, from + 17 * g.K);
            shapes.Add(new(X: badge.X, Y: badge.Y, R: 10));
            for (var radius = Math.Min(from, to); radius <= Math.Max(from, to); radius += 6) { var p = g.P(placed.Point.Angle, radius); shapes.Add(new(X: p.X, Y: p.Y, R: 3)); }
            var start = g.P(placed.Point.Angle, from);
            if (previous is { } prev)
            {
                var qx = g.Cx + (prev.X + start.X - 2 * g.Cx) * .15; var qy = g.Cy + (prev.Y + start.Y - 2 * g.Cy) * .15;
                var steps = Math.Max(1, (int)Math.Ceiling(Math.Sqrt(Math.Pow(start.X - prev.X, 2) + Math.Pow(start.Y - prev.Y, 2)) / 7));
                for (var i = 1; i < steps; i++) { var t = (double)i / steps; shapes.Add(new(X: Math.Pow(1 - t, 2) * prev.X + 2 * (1 - t) * t * qx + t * t * start.X, Y: Math.Pow(1 - t, 2) * prev.Y + 2 * (1 - t) * t * qy + t * t * start.Y, R: 3)); }
            }
            previous = g.P(placed.Point.Angle, to);
        }
        if (input.BandLabels) for (var level = 1; level <= 4; level++) { var r = g.ROf(level); shapes.Add(new(new(g.Cx - 32, g.Cy - r - 7, g.Cx - 4, g.Cy - r + 8))); }
        shapes.Add(new(new(g.Cx - 26 * g.K - 16, g.Cy - 26 * g.K, g.Cx + 26 * g.K + 16, g.Cy + 26 * g.K + 22))); return shapes;
    }
    static double Cost(Box box, Box frame, List<Shape> taken) => (Math.Max(0, frame.L - box.L) + Math.Max(0, box.R - frame.R) + Math.Max(0, frame.T - box.T) + Math.Max(0, box.B - frame.B)) * 50 + taken.Sum(s => Overlap(box, s));
    static Dictionary<string, SectorLabel> PlaceSectors(Input input, List<Shape> taken)
    {
        var result = new Dictionary<string, SectorLabel>(); var g = input.G;
        foreach (var sector in input.Sectors)
        {
            var own = input.Points.Where(p => p.Point.Sector == sector.Name).Select(p => p.Point.Angle).ToList();
            var reach = Math.Max(10, own.Count > 1 ? (own.Max() - own.Min()) / 2 + 10 : 14); var width = TextWidth(sector.Name, SectorSize) * 1.18 + 4;
            SectorLabel? best = null; var bestCost = double.PositiveInfinity;
            foreach (var radius in new[] { SectorRadius, SectorRadius + 12, SectorRadius - 14, SectorRadius + 24 })
            {
                foreach (var shift in new[] { 0, .35, -.35, .7, -.7, 1, -1, 1.5, -1.5 })
                {
                    var p = g.P(sector.Angle + shift * reach, radius * g.K); var box = new Box(p.X - width / 2, p.Y - 8, p.X + width / 2, p.Y + 9); var cost = Cost(box, input.SectorFrame ?? input.Frame, taken);
                    if (best is null || cost < bestCost) { best = new(p.X, p.Y, box); bestCost = cost; } if (cost == 0) break;
                }
                if (bestCost == 0) break;
            }
            if (best is not null) { result[sector.Name] = best; taken.Add(new(best.Box)); }
        }
        return result;
    }
    sealed record Candidate(double X, double Y, Align Align, int Vertical, bool Far, double Order);
    static IEnumerable<Candidate> Candidates(MockMap.Geo g, MockMap.Placed placed, double gap)
    {
        var outward = Math.Atan2(placed.Y - g.Cy, placed.X - g.Cx); var list = new List<Candidate>(); double[] extras = [0, 12, 26, 44, 66, 92, 122, 156];
        for (var ring = 0; ring < extras.Length; ring++) for (var i = 0; i < (ring < 3 ? 8 : 16); i++)
        {
            var angle = i * 2 * Math.PI / (ring < 3 ? 8 : 16); var c = Math.Cos(angle); var s = Math.Sin(angle); var align = c > .3 ? Align.Left : c < -.3 ? Align.Right : Align.Center;
            list.Add(new(placed.X + c * (gap + extras[ring]), placed.Y + s * (gap + extras[ring]), align, s < -.3 ? -1 : s > .3 ? 1 : 0, extras[ring] >= 26, ring * 10 - Math.Cos(angle - outward) * 6 + (align == Align.Center ? .5 : 0)));
        }
        return list.OrderBy(c => c.Order);
    }
    static Box CandidateBox(Candidate option, double width, double height) { var l = option.Align == Align.Right ? option.X - width : option.Align == Align.Center ? option.X - width / 2 : option.X; var t = option.Vertical < 0 ? option.Y - height : option.Vertical > 0 ? option.Y : option.Y - LabelH / 2; return new(l, t, l + width, t + height); }
    public sealed record Layout(Dictionary<string, Label> Labels, Dictionary<string, SectorLabel> Sectors);
    public static Layout LayoutOf(Input input)
    {
        var taken = MarkShapes(input); taken.AddRange(input.Obstacles.Select(b => new Shape(b))); var sectors = PlaceSectors(input, taken); var labels = new Dictionary<string, Label>();
        var order = input.Points.OrderByDescending(p => p.Point.Id == input.Now).ThenBy(p => input.Path.FindIndex(s => s.Id == p.Point.Id));
        foreach (var placed in order)
        {
            var point = placed.Point; if (input.LabelIds is { } ids && !ids.Contains(point.Id)) continue;
            var now = point.Id == input.Now; var strong = now || input.Strong.Contains(point.Id); var size = strong ? NowSize : LabelSize; var sub = input.Subs.GetValueOrDefault(point.Id);
            var lines = now ? input.NowLines : sub is not null ? 1 : 0; var lineWidth = now ? input.NowLineWidth : sub is null ? 0 : TextWidth(sub, SubSize) + 4;
            var chars = SwiftText.Elements(point.Name); var shapes = new[] { (Rows: 1, Width: TextWidth(point.Name, size) + 4), (Rows: 2, Width: TextWidth(string.Concat(chars.Take((int)Math.Ceiling(chars.Length / 2.0))), size) + 6) };
            Label? best = null; var bestCost = double.PositiveInfinity;
            foreach (var shape in shapes)
            {
                var width = Math.Max(shape.Width, lines > 0 ? lineWidth : 0); var height = LabelH * shape.Rows + lines * NoteLine;
                foreach (var option in Candidates(input.G, placed, now ? NowR + 4 : strong ? StrongR + 2 : PointR + 3))
                {
                    var box = CandidateBox(option, width, height); var cost = Cost(box, input.Frame, taken);
                    if (best is null || cost < bestCost) { best = new(option.X, option.Y, option.Align, box, shape.Rows, shape.Width, option.Far); bestCost = cost; } if (cost == 0) break;
                }
                if (bestCost == 0) break;
            }
            if (best is not null) { labels[point.Id] = best; taken.Add(new(best.Box)); }
        }
        return new(labels, sectors);
    }
    public static List<MockMap.Placed> PlaceOnMap(MockMap.Geo g, IEnumerable<MockMap.Point> points) => points.Select(point => { var p = g.P(point.Angle, point.Level == 0 ? 248 * g.K : g.ROf(point.Level)); return new MockMap.Placed(point, p.X, p.Y); }).ToList();
    public sealed record Stage(MockMap.Geo At, Box Frame, Box SectorFrame, List<Box> Obstacles);
    public static readonly Stage Overview = new(new(790, 300, .95), new(470, 72, 1140, 640), new(470, 8, 1145, 650), [new(860, 0, 1151, 72)]);
    public static readonly Stage Home = new(new(770, 316, 1), new(450, 64, 1140, 650), new(450, 8, 1145, 660), [new(680, 20, 1151, 60)]);
    public static readonly Stage Session = new(new(1040, 318, .86), new(752, 84, 1356, 584), new(742, 72, 1362, 586), []);
    static Input On(Stage stage, IEnumerable<MockMap.Point> points, IEnumerable<MockMap.Sector> sectors, List<MockMap.PathStep> path, double rotation, double targetLevel, string targetLabel)
    {
        var g = stage.At; var placed = PlaceOnMap(g, points.Select(p => p with { Angle = p.Angle - rotation })); var rotated = sectors.Select(s => s with { Angle = s.Angle - rotation }).ToList(); var t = g.P(28, g.RingOf(targetLevel));
        return new(g, placed, path, rotated, stage.Frame) { SectorFrame = stage.SectorFrame, Obstacles = [..stage.Obstacles, new(t.X + 8, t.Y - 22, t.X + 8 + TextWidth(targetLabel, 10.5) + 18, t.Y)] };
    }
    public static Layout HomeSession(Slots slots, double targetLevel, string targetLabel) => LayoutOf(On(Home, slots.Points, slots.Sectors, slots.Path, 0, targetLevel, targetLabel));
    public static Layout HomeMap(List<MockMap.Placed> points, List<MockMap.Sector> sectors, double targetLevel, string targetLabel, Dictionary<string, string> subs, List<string> strong, bool gaps)
    {
        int Rank(MockMap.Point p) => (strong.Contains(p.Id) ? 2 : 0) + (subs.ContainsKey(p.Id) ? 1 : 0);
        var input = On(Home, [], sectors.Where(s => !s.Name.StartsWith("__empty_", StringComparison.Ordinal)), [], 0, targetLevel, targetLabel);
        input.Points = points.OrderByDescending(p => Rank(p.Point)).ThenByDescending(p => p.Point.Ask).ToList(); input.Subs = subs; input.Strong = strong; input.GapTo = gaps ? targetLevel : null; return LayoutOf(input);
    }
    public static Layout OverviewLayout(List<MockMap.Point> points, List<MockMap.Sector> sectors, List<MockMap.PathStep> path, double rotation, double targetLevel, string targetLabel) => LayoutOf(On(Overview, points, sectors, path, rotation, targetLevel, targetLabel));
}
