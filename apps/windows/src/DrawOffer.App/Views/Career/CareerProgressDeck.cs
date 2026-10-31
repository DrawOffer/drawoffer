using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;
using Shapes = Microsoft.UI.Xaml.Shapes;

namespace DrawOffer.App.Views.Career;

/// <summary>Web `features/interviews/progress/progressDeck.css` 的颜色（Mac `CareerProgressDeck.swift` 的 `PD`）。</summary>
public static class PD
{
    public static readonly Color Ink = Hex(0x1D1D1B);
    public static readonly Color Body = Hex(0x55554F);
    public static readonly Color Mute = Hex(0x96968F);
    public static readonly Color Blue = Hex(0x3F6FD8);
    public static readonly Color BlueText = Hex(0x145ED6);
    public static readonly Color Tint = Hex(0xE9F1FD);
    public static readonly Color Red = Hex(0xC2412D);
    public static readonly Color RedTint = Hex(0xFDEEEA);
    public static readonly Color Act = Hex(0xC9D6EE);
    public static readonly Color Done = Hex(0x96ACD6);
    public static readonly Color Dash = Hex(0xC4C4BE);
    public static readonly Color Edge = Hex(0xECEBE6);
    public static readonly Color Field = Hex(0xDED7CC);
    public const double Axis = 68;

    /// <summary>把日期换到本机时区取年月日（Swift `Calendar.current.component`）。</summary>
    internal static DateTime Local(DateTimeOffset date) => TimeZoneInfo.ConvertTime(date, TimeZoneInfo.Local).DateTime;

    /// <summary>在 Canvas 上以中心对齐放一个元素（Swift `.position(x:y:)`）。</summary>
    internal static Canvas At(FrameworkElement child, double x, double y)
    {
        var canvas = new Canvas { IsHitTestVisible = false };
        canvas.Children.Add(child);
        Draw.Place(child, new Point(x, y), 0.5, 0.5);
        return canvas;
    }

    /// <summary>`withAnimation(.easeOut(duration: 0.24))` + `.transition(.opacity)`：新内容淡入。</summary>
    internal static void FadeIn(UIElement element, double seconds = 0.24)
    {
        var animation = new Microsoft.UI.Xaml.Media.Animation.DoubleAnimation
        {
            From = 0, To = 1, Duration = TimeSpan.FromSeconds(seconds),
            EasingFunction = new Microsoft.UI.Xaml.Media.Animation.CubicEase { EasingMode = Microsoft.UI.Xaml.Media.Animation.EasingMode.EaseOut },
        };
        var story = new Microsoft.UI.Xaml.Media.Animation.Storyboard();
        Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTarget(animation, element);
        Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTargetProperty(animation, "Opacity");
        story.Children.Add(animation);
        story.Begin();
    }
}

/// <summary>`.pd-btn`（Mac `PDButtonStyle`）：36 高胶囊；一页只有一个黑色实心主按钮，没通过是红字。</summary>
public sealed class PDButton : BorderControl
{
    public enum Kind { Normal, Primary, Reject }

    readonly Kind _kind;
    bool _pressed, _enabled = true;

    public PDButton(string title, Action action, Kind kind = Kind.Normal, bool enabled = true, string? icon = null)
    {
        _kind = kind;
        _enabled = enabled;
        // Web `.pd-page button { font: inherit }` 盖过按钮类的字号：页面里的按钮都是 14px 常规
        var ink = kind == Kind.Primary ? V3.White : kind == Kind.Reject ? PD.Red : PD.Ink;
        var text = Sans(title, 14, ink);
        Child = (icon is null ? (FrameworkElement)text : HStack(6, Icon(icon, 12, ink), text)).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        Padding = new Thickness(16, 0, 16, 0);
        Height = 36;
        CornerRadius = Capsule(36);
        Background = Brush(kind == Kind.Primary ? PD.Ink : V3.White);
        BorderBrush = Brush(kind == Kind.Primary ? PD.Ink : kind == Kind.Reject ? Hex(0xEFD2CC) : Cl);
        BorderThickness = new Thickness(1);
        VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(this, title);
        IsTabStop = enabled;
        PointerPressed += (_, e) => { if (_enabled) { _pressed = true; Paint(); e.Handled = true; } };
        PointerReleased += (_, e) => { if (_pressed && _enabled) { _pressed = false; Paint(); e.Handled = true; action(); } };
        PointerExited += (_, _) => { _pressed = false; Paint(); };
        PointerCanceled += (_, _) => { _pressed = false; Paint(); };
        KeyDown += (_, e) => { if (_enabled && e.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space) { e.Handled = true; action(); } };
        Paint();
    }

    public bool Enabled { get => _enabled; set { _enabled = value; IsTabStop = value; Paint(); } }

    void Paint()
    {
        Opacity = !_enabled ? 0.55 : _pressed ? 0.8 : 1;
        ProtectedCursor = Microsoft.UI.Input.InputSystemCursor.Create(_enabled ? Microsoft.UI.Input.InputSystemCursorShape.Hand : Microsoft.UI.Input.InputSystemCursorShape.Arrow);
    }
}

/// <summary>`.pd-mini-btn`（Mac `PDMiniButtonStyle`）：缩略图虚线框里的小按钮。</summary>
public sealed class PDMiniButton : BorderControl
{
    public PDMiniButton(string title, Action action)
    {
        Child = Sans(title, 14, PD.Ink).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        Padding = new Thickness(12, 0, 12, 0);
        MinHeight = 32;
        CornerRadius = Capsule(32);
        Background = Brush(V3.White);
        BorderBrush = Brush(Cl);
        BorderThickness = new Thickness(1);
        AutomationProperties.SetName(this, title);
        PointerPressed += (_, e) => { Background = Brush(V3.Field); e.Handled = true; };
        PointerReleased += (_, e) => { Background = Brush(V3.White); e.Handled = true; action(); };
        PointerExited += (_, _) => Background = Brush(V3.White);
        ProtectedCursor = Microsoft.UI.Input.InputSystemCursor.Create(Microsoft.UI.Input.InputSystemCursorShape.Hand);
    }
}

/// <summary>左栏站点线（`.pd-rail`，Mac `CareerStationRail`）：日期 | 节点 | 内容三列，点哪一站右边就换成哪一站。</summary>
public sealed class CareerStationRail : UserControl
{
    readonly CareerDeck _deck;
    readonly JsonNode _application;
    readonly int _picked;
    readonly DateTimeOffset _now;
    readonly Action<string> _pick;
    readonly Action<bool> _next;

    public CareerStationRail(CareerDeck deck, JsonNode application, int picked, DateTimeOffset now, Action<string> pick, Action<bool> next)
    {
        _deck = deck;
        _application = application;
        _picked = picked;
        _now = now;
        _pick = pick;
        _next = next;
        Content = Build();
    }

    StackPanel Build()
    {
        var line = _deck.Line(_now);
        var ended = _deck.Ended;
        var stack = new StackPanel();
        for (var index = 0; index < line.Stations.Count; index++)
        {
            var (station, rows) = line.Stations[index];
            for (var position = 0; position < rows.Count; position++)
                stack.Children.Add(RowView(rows[position], station, index, index == 0 && position == 0));
        }
        if (line.Next is { } label)
        {
            var toApply = _deck.Pending && _deck.Ended is null;
            var offer = _deck.Stations.Count > 0 && _deck.Stations[^1].Kind == CareerStationKind.Offer;
            var texts = VStack(2, Sans(label, 15, PD.Mute, Medium).Frame(height: 22),
                offer ? null : Sans(toApply ? "点这里记录投递" : "有结果后点这里添加", 13, PD.Mute).Frame(height: 18));
            texts.Margin = new Thickness(PD.Axis + 24, 0, 0, 0);
            // 虚线从上一站接下来，再画一个虚线空心圆
            var mark = new Canvas { IsHitTestVisible = false, Width = PD.Axis * 2, Height = 22, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
            mark.Children.Add(new Shapes.Line { X1 = PD.Axis, X2 = PD.Axis, Y1 = -14, Y2 = 10, Stroke = Brush(PD.Dash), StrokeThickness = 1, StrokeDashArray = [3, 3] });
            var circle = new Shapes.Ellipse { Width = 12, Height = 12, Fill = Brush(V3.White), Stroke = Brush(Hex(0xBDBDB7)), StrokeThickness = 1.5, StrokeDashArray = [2 / 1.5, 2 / 1.5] };
            Canvas.SetLeft(circle, PD.Axis - 6); Canvas.SetTop(circle, 11 - 6);
            mark.Children.Add(circle);
            var button = new Grid { Background = Brush(Clear), Margin = new Thickness(0, 14, 0, 0) };
            button.Children.Add(texts);
            button.Children.Add(mark);
            button.OnTap(() => { if (!offer) _next(toApply); }, label + (offer ? "" : toApply ? " 点这里记录投递" : " 有结果后点这里添加"), () => !offer);
            stack.Children.Add(button);
        }
        string? endedText = ended is null ? null : ended.Kind switch
        {
            CareerDeckEndedKind.Rejected => "没通过", CareerDeckEndedKind.Accepted => "接受了 Offer", CareerDeckEndedKind.Withdrew => "我不继续了", _ => "已结束",
        };
        var foot = Label(ended is { } end ? $"{endedText ?? ""} · {CareerDeckFormat.MonthDay(end.At)} · 共 {_deck.Days} 天" : $"共 {_deck.Days} 天 · {_deck.Stations.Count} 站",
            12, ended?.Kind == CareerDeckEndedKind.Rejected ? PD.Red : PD.Mute);
        foot.Margin = new Thickness(PD.Axis + 24, 16, 0, 0);
        stack.Children.Add(foot);
        AutomationProperties.SetName(stack, "投递进度");
        return stack;
    }

    /// <summary>每一行在节点列自己画那一段线：实线已走过，灰虚线往后。</summary>
    static Canvas LineSegment(CareerLineTone tone, double top = 0, double? height = null)
    {
        var canvas = new Canvas { IsHitTestVisible = false };
        if (tone == CareerLineTone.None) return canvas;
        var next = tone == CareerLineTone.Next;
        var path = new Shapes.Line { X1 = PD.Axis, X2 = PD.Axis, Y1 = top, Stroke = Brush(next ? PD.Dash : PD.Act), StrokeThickness = next ? 1 : 2 };
        if (next) path.StrokeDashArray = [3, 3];
        canvas.Children.Add(path);
        void Fit() => path.Y2 = height is { } h ? top + h : Math.Max(top, canvas.ActualHeight);
        Fit();
        canvas.SizeChanged += (_, _) => Fit();
        return canvas;
    }

    static Grid Row(CareerLineTone tone, FrameworkElement content, double minHeight)
    {
        var grid = new Grid { MinHeight = minHeight };
        grid.Children.Add(LineSegment(tone));
        content.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(content);
        return grid;
    }

    UIElement RowView(CareerLineRow row, CareerStation station, int index, bool first)
    {
        switch (row)
        {
            case CareerLineRow.Stop stop:
                return Stop(station, stop.Kind, stop.Tone, index, first);
            case CareerLineRow.Span span:
            {
                var grid = new Grid { Height = 40 };
                grid.Children.Add(LineSegment(span.Tone));
                if (span.Days > 0)
                {
                    var chip = new Border
                    {
                        Child = Label($"{span.Days} 天", 11, PD.Mute, Medium).Align(v: VerticalAlignment.Center),
                        Padding = new Thickness(7, 0, 7, 0), Height = 18, CornerRadius = Capsule(18),
                        Background = Brush(V3.White), BorderBrush = Brush(PD.Edge), BorderThickness = new Thickness(1),
                    };
                    grid.Children.Add(PD.At(chip, PD.Axis, 20));
                }
                AutomationProperties.SetAccessibilityView(grid, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
                return grid;
            }
            case CareerLineRow.Event item:
            {
                var text = HStack(8, Sans(item.Text, 13, item.Upcoming ? PD.BlueText : PD.Ink, Medium).Also(t => t.TextTrimming = TextTrimming.None),
                    item.Detail is { } detail ? Sans(detail, 12.5, PD.Mute) : null);
                text.Margin = new Thickness(PD.Axis + 24, 0, 0, 0);
                var grid = Row(item.Tone, text, 30);
                grid.Children.Add(new Shapes.Ellipse
                {
                    Width = 8, Height = 8, Fill = Brush(V3.White), Stroke = Brush(PD.Blue), StrokeThickness = 1.5,
                    HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(PD.Axis - 4, 0, 0, 0),
                });
                return grid;
            }
            case CareerLineRow.Wait wait:
            {
                var chip = new Border
                {
                    Child = Sans(wait.Label, 12, PD.BlueText, Medium).Align(v: VerticalAlignment.Center),
                    Padding = new Thickness(10, 0, 10, 0), Height = 22, CornerRadius = Capsule(22), Background = Brush(PD.Tint),
                    HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(PD.Axis + 24, 0, 0, 0),
                };
                return Row(wait.Tone, chip, 32);
            }
            case CareerLineRow.Today today:
            {
                var text = HStack(0, Sans("今天", 13, PD.Ink, Medium).Also(t => t.TextAlignment = TextAlignment.Right).Frame(width: PD.Axis - 22),
                    new Border { Width = 46 }, Label(today.Label, 13, PD.Body));
                var grid = Row(today.Tone, text, 36);
                grid.Children.Add(new Border
                {
                    Width = 20, Height = 2, CornerRadius = new CornerRadius(1), Background = Brush(PD.Ink),
                    HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(PD.Axis - 10, 0, 0, 0),
                });
                return grid;
            }
            default:
                return new Border();
        }
    }

    UIElement Stop(CareerStation station, CareerLineStop state, CareerLineTone tone, int index, bool first)
    {
        var isPicked = index == _picked;
        var current = state == CareerLineStop.Current;
        var failed = state == CareerLineStop.Failed;
        var detail = StopDetail(station, current);
        var color = failed ? PD.Red : current ? PD.BlueText : PD.Ink;
        var name = _deck.Pending && _deck.Ended is null && station.Kind == CareerStationKind.Apply ? "待投递" : station.Short;
        var date = Label(CareerDeckFormat.MonthDay(station.Start), 13, failed ? PD.Red : current ? PD.BlueText : PD.Body, current ? Semibold : Medium);
        date.TextAlignment = TextAlignment.Right;
        date.Width = PD.Axis - 22;
        date.VerticalAlignment = VerticalAlignment.Top;
        date.Margin = new Thickness(0, 13, 0, 0);
        var texts = VStack(2, Sans(name, 16, color, isPicked ? Semibold : Medium).Frame(height: 22),
            detail is null ? null : Sans(detail, 13, failed ? PD.Red : PD.Mute).Frame(height: 18));
        var block = new Border { Child = texts, Padding = new Thickness(12, 9, 12, 9), CornerRadius = new CornerRadius(12), Background = Brush(Clear) };
        // StopHover：悬停时浅灰底
        block.OnHover(hover => block.Background = Brush(hover ? Hex(0xF6F6F3) : Clear));
        var content = Columns(0, (Px(PD.Axis - 22), date), (Px(34), new Border()), (Star(), block));
        content.Margin = new Thickness(0, 4, 0, 4);
        var grid = new Grid { Background = Brush(Clear) };
        // 首站从圆点开始画；已结束的最后一站只补上一段到圆点
        grid.Children.Add(LineSegment(tone == CareerLineTone.None && !first ? CareerLineTone.Done : tone, first ? 26 : 0, tone == CareerLineTone.None ? (first ? 0 : 26) : null));
        grid.Children.Add(content);
        grid.Children.Add(PD.At(Dot(state, isPicked), PD.Axis, 26));
        grid.OnTap(() => _pick(station.Id), "查看" + station.Short);
        return grid;
    }

    static FrameworkElement Dot(CareerLineStop state, bool picked)
    {
        if (state == CareerLineStop.Current && !picked)
            return Layer(new Shapes.Ellipse { Width = 18, Height = 18, Fill = Brush(V3.White), Stroke = Brush(PD.Blue), StrokeThickness = 2 },
                new Shapes.Ellipse { Width = 7, Height = 7, Fill = Brush(PD.Blue) }).Frame(18, 18);
        if (state == CareerLineStop.Offer)
            return Layer(new Shapes.Ellipse { Width = 18, Height = 18, Fill = Brush(PD.Blue) },
                Icon("checkmark", 8, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center)).Frame(18, 18);
        var failed = state == CareerLineStop.Failed;
        var size = picked ? 16 : 12;
        var halo = new Shapes.Ellipse { Width = 26, Height = 26, Fill = Brush(failed ? PD.RedTint : PD.Tint), Opacity = picked ? 1 : 0 };
        var dot = new Shapes.Ellipse { Width = size, Height = size, Fill = Brush(picked ? (failed ? PD.Red : PD.Blue) : failed ? PD.Red : PD.Done) };
        var mark = Icon(failed ? "xmark" : "checkmark", picked ? 8 : 6.5, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        return Layer(halo, dot, mark).Frame(26, 26);
    }

    string? StopDetail(CareerStation station, bool current)
    {
        if (current && station.Kind is CareerStationKind.Written or CareerStationKind.Interview) return $"{CareerDeckFormat.MonthDay(station.Start)} 收到通知";
        if (current && station.Kind == CareerStationKind.Screening) return null;
        var text = CareerDeckCopy.EdgeDetail(station, _application);
        return text.Length == 0 ? null : text;
    }
}

/// <summary>Mac `CareerDeckCopy`：站点线与站点卡共用的文案。</summary>
public static class CareerDeckCopy
{
    public static string Mode(JsonNode session, bool @short = false) => session.Text("mode") switch
    {
        "video" => @short ? "视频" : "视频面试",
        "onsite" => @short ? "现场" : "现场面试",
        "phone" => "电话",
        _ => "其他方式",
    };

    public static string EdgeDetail(CareerStation station, JsonNode application)
    {
        switch (station.Kind)
        {
            case CareerStationKind.Apply: return string.Join(" · ", new[] { CareerDeck.Source(application), application.Text("resume_title_snapshot").NonEmpty() }.OfType<string>());
            case CareerStationKind.Oc: return string.Join(" · ", new[] { application.Text("oc_salary_text").NonEmpty(), "口头意向" }.OfType<string>());
            case CareerStationKind.Offer: return "正式 Offer";
        }
        if (station.Session is not { } session)
            return station.End is { } end ? $"{CareerDeckFormat.DayCount(station.Start, end)} 天出结果" : "";
        var start = CareerApplication.Date(session.Text("start_at")) ?? station.Start;
        var finish = CareerApplication.Date(session.Text("end_at")) ?? start;
        if (station.Kind == CareerStationKind.Written)
        {
            if (session.Text("schedule_kind") == "open_window" && CareerApplication.Date(session.Text("answer_plan_start_at")) is { } s && CareerApplication.Date(session.Text("answer_plan_end_at")) is { } e)
                return $"{CareerDeckFormat.MonthDay(s)} {CareerDeckFormat.Clock(s)} – {CareerDeckFormat.Clock(e)} 完成";
            return $"{CareerDeckFormat.MonthDay(start)} {CareerDeckFormat.Clock(start)} – {CareerDeckFormat.Clock(finish)} 完成";
        }
        return $"{CareerDeckFormat.MonthDay(start)} {CareerDeckFormat.Clock(start)} – {CareerDeckFormat.Clock(finish)} · {Mode(session)}";
    }
}
