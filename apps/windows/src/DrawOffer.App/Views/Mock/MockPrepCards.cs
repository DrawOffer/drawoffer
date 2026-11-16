using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

/// <summary>
/// 准备题目中间的卡片（Windows 稿 09 · 04 选题动效；Mac `MockPrepCards`、Web `v2/PrepCards.tsx`）：中间那叠是「本场题目」，两侧各两张候选考点。
/// 读简历：两张资料卡轮流被扫描线扫过，扫完一张就抽出一张小卡飞向中间；选题：每轮挑一张抬起、上方给理由，再滑进中间那叠，
/// 同侧外面的卡向里补位、桌边递补一张；挑完后两侧留下的是这场不考的点，淡着停在桌上。生成第一问：那叠最上面一张写「第一题」并轻轻浮着。
/// 整块铺满 1368 × 828 画布；准备页每次刷新都复用同一个实例，动画不重头开始。
/// </summary>
internal sealed class MockPrepCards : Canvas
{
    const double Cx = 684, Cy = 444, PileW = 204, PileH = 136, CardW = 156, CardH = 104;
    static readonly double[] SlotX = [-372, -204, 204, 372], SlotRot = [4, 2, -2, -4], SlotDY = [10, 2, 2, 10];
    static readonly (double X, double Y, double R)[] Under = [(6, 8, 3), (-5, 6, -2.5), (3, 3, 1.5)];
    static readonly (double X, double Y, double R)[] Land = [(2, -3, -1.5), (-2, -6, 1.2), (1, -4, -0.8), (-1, -5, 1.6)];
    public static readonly Dictionary<string, (string Label, Color Tone)> Tags = new()
    {
        ["retest"] = ("复测", MP.Orange), ["probe"] = ("补问", MP.Blue), ["focus"] = ("你选的", MP.Blue),
        ["practice"] = ("练习", MP.Mute), ["job"] = ("岗位要求", MP.Mute), ["basics"] = ("常考", MP.Mute),
        ["resume"] = ("你的经历", MP.Mute), ["competency"] = ("综合素质", MP.Mute),
    };

    enum Phase { Deal, Scan, Pick, Reason, Land }
    internal sealed record Pick(string Topic, string Tag, string Note);
    internal sealed record Card(string Key, string Name, int? PickIndex, int Slot);
    internal sealed record Round(List<Card> Cards, string Chosen, int PickIndex);

    JsonNode? _prep;
    bool _frozen, _hasJob;
    string? _firstSeen;
    int _landed;
    Phase _phase = Phase.Deal;
    List<Pick> _picks = [];
    (List<Round> Rounds, List<Card> Final) _deck = ([], []);
    string _deckKey = "";
    bool _playing;
    readonly Dictionary<string, Border> _cards = [];
    readonly Canvas _pileLayer = new(), _tableLayer = new(), _docLayer = new(), _top = new();
    readonly TextBlock _reason = Sans("", 13, MP.Ink, Medium);
    readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromMilliseconds(40) };
    readonly DateTime _born = DateTime.UtcNow;
    Border? _floating;
    Rectangle? _emptyPile;

    public MockPrepCards()
    {
        Width = MockFull.Width; Height = MockFull.Height; IsHitTestVisible = false;
        AutomationProperties.SetAccessibilityView(this, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        Children.Add(_docLayer); Children.Add(_pileLayer); Children.Add(_tableLayer); Children.Add(_top);
        _reason.Opacity = 0;
        _top.Children.Add(_reason);
        var caption = Sans("本场题目", 13, MP.Mute);
        caption.Width = 1120; caption.TextAlignment = TextAlignment.Center;
        SetLeft(caption, 124); SetTop(caption, 538);
        _top.Children.Add(caption);
        _clock.Tick += (_, _) => Tick();
        Loaded += (_, _) => _clock.Start();
        Unloaded += (_, _) => { _clock.Stop(); _playing = false; };
    }

    /// <summary>准备页刷新时传入最新的 prep。</summary>
    public void Update(JsonNode? prep, bool frozen, bool hasJob)
    {
        _prep = prep is JsonObject ? prep : null;
        _frozen = frozen; _hasJob = hasJob;
        if (_firstSeen is null && _prep is not null) _firstSeen = _prep.Text("stage");
        _picks = _prep.Items("picks").Select(p => new Pick(p.Text("topic"), p.Text("tag"), p.Text("note"))).ToList();
        var candidates = _prep.Items("candidates").Select(c => c is JsonValue v && v.TryGetValue<string>(out var s) ? s : "").Where(s => s.Length > 0).ToList();
        var key = string.Join("|", _picks.Select(p => p.Topic)) + "#" + string.Join("|", candidates);
        if (key != _deckKey) { _deckKey = key; _deck = Schedule(_picks, candidates); }
        if (_prep is null)
        {
            _pileLayer.Children.Clear(); _tableLayer.Children.Clear(); _cards.Clear(); _floating = null;
            DrawDocs();
            _emptyPile = EmptyPile();
            _pileLayer.Children.Add(_emptyPile);
            return;
        }
        _docLayer.Children.Clear();
        if (Still || _landed >= _deck.Rounds.Count) { Layout(animate: false); return; }
        Layout(animate: false);
        if (!_playing) _ = Play();
    }

    bool Still => _frozen || _firstSeen == "opening";
    bool Playing => _prep is not null && !Still && _landed < _deck.Rounds.Count;

    /// <summary>每一轮：发牌 → 扫一眼 → 抬起 → 给理由 → 滑进那叠，然后下一轮。</summary>
    async Task Play()
    {
        _playing = true;
        while (_playing && Playing)
        {
            var extra = _landed == 0 ? 0.6 : 0;
            foreach (var (at, next) in new[] { (0.38, Phase.Scan), (0.70, Phase.Pick), (0.85, Phase.Reason), (1.75, Phase.Land) })
            {
                await Task.Delay(TimeSpan.FromSeconds(at + extra));
                if (!_playing || !IsLoaded) { _playing = false; return; }
                _phase = next;
                Layout(animate: true);
            }
            await Task.Delay(TimeSpan.FromSeconds(0.45));
            if (!_playing || !IsLoaded) { _playing = false; return; }
            _phase = Phase.Deal; _landed++;
            Layout(animate: true);
        }
        _playing = false;
    }

    void Layout(bool animate)
    {
        var playing = Playing;
        var round = playing ? _deck.Rounds[_landed] : null;
        var shown = playing ? _landed : _picks.Count;
        var opening = _prep.Text("stage") == "opening";
        var order = _deck.Rounds.Select(r => r.PickIndex).ToList();
        Pick? last = null;
        if (shown > 0)
        {
            var at = shown - 1 < order.Count ? order[shown - 1] : shown - 1;
            if (at >= 0 && at < _picks.Count) last = _picks[at];
        }
        (string, string, Color)? top = opening && !playing
            ? ((_prep.Text("first").NonEmpty() ?? _picks.FirstOrDefault()?.Topic ?? ""), "第一题", MP.Ink)
            : last is null ? null : (last.Topic, Tags.GetValueOrDefault(last.Tag).Label ?? "", Tags.TryGetValue(last.Tag, out var t) ? t.Tone : MP.Mute);
        DrawPile(shown, top, opening && !playing);

        var cards = round?.Cards ?? _deck.Final;
        var keys = cards.Select(c => c.Key).ToHashSet();
        foreach (var gone in _cards.Keys.Where(k => !keys.Contains(k)).ToList())
        {
            var element = _cards[gone];
            _cards.Remove(gone);
            if (animate) Animate(element, null, null, null, null, 0, () => _tableLayer.Children.Remove(element));
            else _tableLayer.Children.Remove(element);
        }
        foreach (var card in cards) Place(card, round, animate);

        if (round is not null && round.PickIndex < _picks.Count && Tags.TryGetValue(_picks[round.PickIndex].Tag, out var tag))
        {
            var pick = _picks[round.PickIndex];
            var slot = round.Cards.FirstOrDefault(c => c.Key == round.Chosen)?.Slot ?? 0;
            _reason.Text = pick.Note.Length == 0 ? tag.Label : $"{tag.Label} · {pick.Note}";
            _reason.Foreground = Brush(tag.Tone);
            _reason.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
            SetLeft(_reason, Cx + SlotX[slot] - _reason.DesiredSize.Width / 2);
            SetTop(_reason, Cy + SlotDY[slot] - 18 - 52 - 12 - 10 - 10);
            _reason.Opacity = _phase == Phase.Reason ? 1 : 0;
        }
        else _reason.Opacity = 0;
    }

    void Place(Card card, Round? round, bool animate)
    {
        var chosen = round is not null && card.Key == round.Chosen;
        var lifted = chosen && _phase is Phase.Pick or Phase.Reason;
        var moving = chosen && _phase == Phase.Land;
        var landAt = Land[_landed % Land.Length];
        var x = moving ? landAt.X : SlotX[card.Slot];
        var y = moving ? landAt.Y : lifted ? SlotDY[card.Slot] - 18 : SlotDY[card.Slot];
        var rot = moving ? landAt.R : lifted ? 0 : SlotRot[card.Slot];
        var dim = round is null || (!chosen && _phase != Phase.Deal && _phase != Phase.Scan);
        var fresh = !_cards.TryGetValue(card.Key, out var element);
        if (fresh)
        {
            var name = Sans(card.Name, 15, MP.Ink, Medium).Wrap(2);
            name.TextAlignment = TextAlignment.Center; name.VerticalAlignment = VerticalAlignment.Center; name.Margin = new Thickness(12, 0, 12, 0);
            var tagText = Sans("", 10, MP.Mute, Medium);
            tagText.Margin = new Thickness(12, 9, 0, 0); tagText.Opacity = 0;
            element = new Border
            {
                Width = CardW, Height = CardH, CornerRadius = new CornerRadius(12), Background = Brush(V3.White),
                BorderBrush = Brush(MP.Edge), BorderThickness = new Thickness(1), RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5),
                RenderTransform = new CompositeTransform { TranslateX = x + (card.Slot < 2 ? -140 : 140), TranslateY = y, Rotation = rot },
                Child = new Grid { Children = { name, tagText } }, Opacity = 0,
            }.Elevate(6);
            SetLeft(element, Cx - CardW / 2); SetTop(element, Cy - CardH / 2);
            _cards[card.Key] = element;
            _tableLayer.Children.Add(element);
        }
        var grid = (Grid)element!.Child;
        ((TextBlock)grid.Children[0]).Opacity = dim ? 0.35 : 1;
        var tagBlock = (TextBlock)grid.Children[1];
        if (chosen && round is not null && round.PickIndex < _picks.Count && Tags.TryGetValue(_picks[round.PickIndex].Tag, out var tag))
        { tagBlock.Text = tag.Label; tagBlock.Foreground = Brush(tag.Tone); }
        tagBlock.Opacity = moving ? 1 : 0;
        Canvas.SetZIndex(element, lifted || moving ? 3 : 1);
        var scale = moving ? PileW / CardW : 1;
        if (animate || fresh) Animate(element, x, y, rot, scale, 1, null);
        else
        {
            var tr = (CompositeTransform)element.RenderTransform;
            tr.TranslateX = x; tr.TranslateY = y; tr.Rotation = rot; tr.ScaleX = tr.ScaleY = scale;
            element.Opacity = 1;
        }
    }

    static void Animate(UIElement element, double? x, double? y, double? rot, double? scale, double opacity, Action? done)
    {
        var board = new Storyboard();
        var tr = (CompositeTransform)element.RenderTransform;
        void Add(DependencyObject target, string property, double to)
        {
            var animation = new DoubleAnimation { To = to, Duration = TimeSpan.FromSeconds(0.45), EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut } };
            Storyboard.SetTarget(animation, target);
            Storyboard.SetTargetProperty(animation, property);
            board.Children.Add(animation);
        }
        if (x is { } vx) Add(tr, "TranslateX", vx);
        if (y is { } vy) Add(tr, "TranslateY", vy);
        if (rot is { } vr) Add(tr, "Rotation", vr);
        if (scale is { } vs) { Add(tr, "ScaleX", vs); Add(tr, "ScaleY", vs); }
        Add(element, "Opacity", opacity);
        if (done is not null) board.Completed += (_, _) => done();
        board.Begin();
    }

    Rectangle EmptyPile() => new Rectangle
    {
        Width = PileW, Height = PileH, RadiusX = 16, RadiusY = 16, Stroke = Brush(MP.Edge), StrokeThickness = 1, StrokeDashArray = [4, 3],
    }.Also(r => { SetLeft(r, Cx - PileW / 2); SetTop(r, Cy - PileH / 2); });

    static Border PileCard() => new Border
    {
        Width = PileW, Height = PileH, CornerRadius = new CornerRadius(16), Background = Brush(V3.White), BorderBrush = Brush(MP.Edge), BorderThickness = new Thickness(1),
        RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5),
    }.Elevate(8);

    void DrawPile(int count, (string Topic, string Label, Color Tone)? top, bool lifted)
    {
        _pileLayer.Children.Clear();
        _floating = null; _emptyPile = null;
        if (count == 0 || top is not { } head) { _emptyPile = EmptyPile(); _pileLayer.Children.Add(_emptyPile); return; }
        for (var i = 0; i < Math.Min(count - 1, Under.Length); i++)
        {
            var card = PileCard();
            card.RenderTransform = new CompositeTransform { TranslateX = Under[i].X, TranslateY = Under[i].Y, Rotation = Under[i].R };
            SetLeft(card, Cx - PileW / 2); SetTop(card, Cy - PileH / 2);
            _pileLayer.Children.Add(card);
        }
        var at = lifted ? (X: 0.0, Y: -10.0, R: 0.0) : Land[(count - 1) % Land.Length];
        var face = PileCard();
        var topic = Sans(head.Topic, 19, MP.Ink, Medium).Wrap(2);
        topic.TextAlignment = TextAlignment.Center; topic.VerticalAlignment = VerticalAlignment.Center; topic.Margin = new Thickness(18, 0, 18, 0);
        var label = Sans(head.Label, 12, head.Tone, Medium);
        label.Margin = new Thickness(16, 13, 0, 0);
        face.Child = new Grid { Children = { topic, label } };
        face.RenderTransform = new CompositeTransform { TranslateX = at.X, TranslateY = at.Y, Rotation = at.R };
        SetLeft(face, Cx - PileW / 2); SetTop(face, Cy - PileH / 2);
        _pileLayer.Children.Add(face);
        if (lifted) _floating = face;
    }

    /// <summary>读简历：两张资料卡 + 扫描线 + 飞向中间的小卡。</summary>
    void DrawDocs()
    {
        if (_docLayer.Children.Count > 0) return;
        _docLayer.Children.Add(Doc(_hasJob ? "岗位要求" : "方向常考点", 290, -3));
        _docLayer.Children.Add(Doc("你的简历", -290, 3));
        _docLayer.Children.Add(Ghost());
        _docLayer.Children.Add(Ghost());
    }

    static Border Doc(string title, double x, double rot)
    {
        var lines = VStack(14, Sans(title, 12, MP.Mute).Frame(height: 18).Pad(0, 0, 0, 2));
        foreach (var w in new[] { 0.86, 0.62, 0.74 })
            lines.Children.Add(new Rectangle { Width = 172 * w, Height = 8, RadiusX = 4, RadiusY = 4, Fill = Brush(Hex(0xEDEDEA)), HorizontalAlignment = HorizontalAlignment.Left });
        lines.Margin = new Thickness(18, 16, 18, 0);
        var scan = new Rectangle
        {
            Height = 2, VerticalAlignment = VerticalAlignment.Top, Opacity = 0,
            Fill = new LinearGradientBrush
            {
                StartPoint = new Windows.Foundation.Point(0, 0), EndPoint = new Windows.Foundation.Point(1, 0),
                GradientStops = { new GradientStop { Color = Alpha(MP.Blue, 0), Offset = 0 }, new GradientStop { Color = Alpha(MP.Blue, 0.75), Offset = 0.3 }, new GradientStop { Color = Alpha(MP.Blue, 0.75), Offset = 0.7 }, new GradientStop { Color = Alpha(MP.Blue, 0), Offset = 1 } },
            },
            RenderTransform = new TranslateTransform(),
        };
        var card = new Border
        {
            Width = 208, Height = 136, CornerRadius = new CornerRadius(14), Background = Brush(V3.White), BorderBrush = Brush(MP.Edge), BorderThickness = new Thickness(1),
            Child = new Grid { Children = { lines, scan } }, RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5),
            RenderTransform = new RotateTransform { Angle = rot }, Tag = x,
        }.Elevate(6);
        SetLeft(card, Cx + x - 104); SetTop(card, Cy - 68);
        return card;
    }

    static Border Ghost()
    {
        var ghost = new Border
        {
            Width = 70, Height = 46, CornerRadius = new CornerRadius(8), Background = Brush(V3.White), BorderBrush = Brush(MP.Edge), BorderThickness = new Thickness(1), Opacity = 0,
            Child = VStack(6, new Rectangle { Width = 50, Height = 6, RadiusX = 3, RadiusY = 3, Fill = Brush(Hex(0xEDEDEA)), HorizontalAlignment = HorizontalAlignment.Left },
                new Rectangle { Width = 34, Height = 6, RadiusX = 3, RadiusY = 3, Fill = Brush(Hex(0xEDEDEA)), HorizontalAlignment = HorizontalAlignment.Left }).Pad(10, 10, 10, 10),
        };
        return ghost;
    }

    void Tick()
    {
        var t = (DateTime.UtcNow - _born).TotalSeconds;
        if (_floating?.RenderTransform is CompositeTransform f) f.TranslateY = -10 + Math.Sin(t / 3.2 * 2 * Math.PI) * 4;
        if (_emptyPile is not null) _emptyPile.Stroke = Brush(_prep is null && !Still && (t % 1.2) / 1.2 < 0.3 ? Alpha(MP.Blue, 0.5) : MP.Edge);
        if (_prep is not null || _docLayer.Children.Count < 4) return;
        var reading = !Still;
        for (var i = 0; i < 2; i++)
        {
            var doc = (Border)_docLayer.Children[i];
            var lag = i == 0 ? 1 : 0;
            var p = reading ? (((t - lag * 1.2) % 2.4) + 2.4) % 2.4 / 2.4 : 1;
            var focused = reading && p < 0.4;
            doc.BorderBrush = Brush(focused ? Hex(0xC4D2F0) : MP.Edge);
            var scan = (Rectangle)((Grid)doc.Child).Children[1];
            scan.Opacity = focused ? 1 : 0;
            if (scan.RenderTransform is TranslateTransform move) move.Y = 136 * p / 0.4;

            var ghost = (Border)_docLayer.Children[2 + i];
            var from = (double)doc.Tag;
            var g = (((t - lag * 1.2 - 0.96) % 2.4) + 2.4) % 2.4 / 2.4;
            var travel = Math.Min(1, g / 0.35);
            ghost.Opacity = reading && g < 0.35 ? Math.Sin(travel * Math.PI) : 0;
            SetLeft(ghost, Cx + from * (1 - travel) - 35);
            SetTop(ghost, Cy - 20 * Math.Sin(travel * Math.PI) - 23);
        }
    }

    /// <summary>
    /// 先排好每一轮开始时桌上的卡和挑哪张（与 Web `schedule` 相同）：挑的那张尽量和上一轮不在同一侧、先挑里侧的；
    /// 挑走后同侧外面的卡向里补位，空出的外侧由桌边递补一张。挑的先后只影响动画，题目顺序仍按 picks。
    /// </summary>
    internal static (List<Round> Rounds, List<Card> Final) Schedule(List<Pick> picks, List<string> candidates)
    {
        int dealt = 0, serial = 0, cursor = 0;
        string? NextCandidate(List<Card> table)
        {
            var on = table.Select(c => c.Name).ToHashSet();
            for (var k = 0; k < candidates.Count; k++)
            {
                var name = candidates[(cursor + k) % candidates.Count];
                if (!on.Contains(name) && !picks.Any(p => p.Topic == name)) { cursor = (cursor + k + 1) % candidates.Count; return name; }
            }
            return null;
        }
        void Deal(List<Card> table, int slot, bool candidate = false)
        {
            if (!candidate && dealt < picks.Count && table.Count(c => c.PickIndex is not null) < 3)
            { table.Add(new Card($"p{dealt}", picks[dealt].Topic, dealt, slot)); dealt++; return; }
            if (NextCandidate(table) is { } name) { table.Add(new Card($"c{serial}", name, null, slot)); serial++; }
            else if (dealt < picks.Count) { table.Add(new Card($"p{dealt}", picks[dealt].Topic, dealt, slot)); dealt++; }
        }
        var table = new List<Card>();
        foreach (var slot in new[] { 2, 1, 3, 0 }) Deal(table, slot, slot == 0 && picks.Count > 1);
        var rounds = new List<Round>();
        var lastSide = 0;
        static int SideOf(int slot) => slot < 2 ? 0 : 1;
        for (var n = 0; n < picks.Count; n++)
        {
            var on = table.Where(c => c.PickIndex is not null).ToList();
            if (on.Count == 0) break;
            int Rank(Card c) => (SideOf(c.Slot) != lastSide ? 0 : 2) + (c.Slot is 1 or 2 ? 0 : 1);
            var chosen = on.OrderBy(Rank).First();
            rounds.Add(new Round([.. table], chosen.Key, chosen.PickIndex!.Value));
            lastSide = SideOf(chosen.Slot);
            var next = table.Where(c => c.Key != chosen.Key).ToList();
            var inner = new[] { 1, 2 }[lastSide];
            var outer = new[] { 0, 3 }[lastSide];
            if (!next.Any(c => c.Slot == inner) && next.FindIndex(c => c.Slot == outer) is var moving and >= 0) next[moving] = next[moving] with { Slot = inner };
            foreach (var slot in new[] { outer, inner }) if (!next.Any(c => c.Slot == slot)) Deal(next, slot);
            table = next;
        }
        if (table.Count < 4)
        {
            int[][] spread = [[], [2], [1, 2], [1, 2, 3]];
            table = table.OrderBy(c => c.Slot).Select((c, i) => c with { Slot = spread[table.Count][i] }).ToList();
        }
        return (rounds, table);
    }
}
