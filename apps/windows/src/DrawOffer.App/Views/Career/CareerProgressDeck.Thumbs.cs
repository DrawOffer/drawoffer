using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI.Text;
using static DrawOffer.App.DesignSystem.V3;
using Shapes = Microsoft.UI.Xaml.Shapes;

namespace DrawOffer.App.Views.Career;

/// <summary>叠起来的日历页（`.pd-cal`，Mac `CareerCalendarPage`）：蓝色页头写月份，中间日期，下面星期。</summary>
public static class CareerCalendarPage
{
    public static FrameworkElement Make(DateTimeOffset date, string? tone = null)
    {
        var head = tone == "red" ? PD.Red : tone == "gray" ? PD.Mute : PD.Blue;
        var local = PD.Local(date);
        // 后面两张斜放的纸：阴影 rgb(0x1A3373) 5% 半径 5、下移 3
        Border Sheet(double angle, double x, double y) => new Border
        {
            Width = 144, Height = 156, CornerRadius = new CornerRadius(24), Background = Brush(V3.White),
            BorderBrush = Brush(Hex(0xE5EAF3)), BorderThickness = new Thickness(1),
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = new CompositeTransform { Rotation = angle, TranslateX = x, TranslateY = y },
        }.Elevate(3);
        var ring = tone is null ? Hex(0xD6E2F8) : PD.Edge;
        var rings = Spread(Fill(ring, 3, 6, 14), Fill(ring, 3, 6, 14), 0, VerticalAlignment.Top);
        rings.Margin = new Thickness(34, -3, 34, 0);
        rings.VerticalAlignment = VerticalAlignment.Top;
        var header = Layer(new Border { Background = Brush(head), Height = 42, Child = Sans($"{local.Month} 月", 18, V3.White, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center) }, rings);
        header.Height = 42;
        var day = Label($"{local.Day}", 54, PD.Ink, Semibold).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        day.CharacterSpacing = -30; // kerning(-1.6)：-1.6 / 54 ≈ -0.03em
        var body = VStack(0, header,
            new Border { Height = 60, Margin = new Thickness(0, 10, 0, 0), Child = day },
            new Border { Height = 22, Margin = new Thickness(0, 4, 0, 0), Child = Sans(CareerDeckFormat.Weekday(date), 17, PD.Mute).Align(HorizontalAlignment.Center, VerticalAlignment.Center) });
        var front = new Border
        {
            Width = 144, Height = 156, CornerRadius = new CornerRadius(24), Background = Brush(V3.White), Child = body,
            BorderBrush = Brush(Hex(0xE5EAF3)), BorderThickness = new Thickness(1),
        }.Elevate(10);
        var stack = Layer(Sheet(-7, -6, 6), Sheet(5, 6, 4), front);
        stack.Width = 144;
        stack.Height = 156;
        stack.Margin = new Thickness(6, 8, 0, 0);
        stack.HorizontalAlignment = HorizontalAlignment.Left;
        stack.VerticalAlignment = VerticalAlignment.Top;
        AutomationProperties.SetAccessibilityView(stack, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return stack;
    }
}

/// <summary>缩略图（`.pd-thumb`，Mac `CareerThumb`）：预览纸片、名字、说明行。</summary>
public sealed record CareerThumb(string Id, string Name, string? Meta, CareerThumb.Preview Content, Action? Open = null)
{
    public abstract record Preview
    {
        public sealed record Info(IReadOnlyList<(string Label, string? Value)> Rows) : Preview;
        public sealed record Doc(string Title, IReadOnlyList<double> Widths) : Preview;
        public sealed record List(string? Kicker, IReadOnlyList<string> Items) : Preview;
        public sealed record Text(string? Kicker, string Body, bool Strong) : Preview;
        public sealed record Files(IReadOnlyList<string> Names, int More) : Preview;
        public sealed record Qa(IReadOnlyList<string> Questions) : Preview;
        public sealed record Checks(IReadOnlyList<(string Title, bool Done, Action Toggle)> Items) : Preview;
        public sealed record Written(IReadOnlyList<(string No, string Question, string Correctness)> Rows) : Preview;
        public sealed record Empty(string Icon, string Message, IReadOnlyList<(string Label, Action Run)> Actions) : Preview;
    }

    public bool IsEmpty => Content is Preview.Empty;
}

/// <summary>Mac `CareerThumbShelf`：一排缩略图，标题行右侧「全部资料 ›」。</summary>
public static class CareerThumbShelf
{
    public static FrameworkElement Make(string title, IReadOnlyList<CareerThumb> items, Action all)
    {
        var allButton = Sans("全部资料 ›", 14, PD.Body).OnTap(all, "全部资料 ›");
        var head = Spread(Sans(title, 13, PD.Mute).Frame(height: 18), allButton, 0, VerticalAlignment.Bottom);
        head.Height = 22;
        head.Margin = new Thickness(0, 0, 0, 14);
        var row = new Grid { ColumnSpacing = 20 };
        for (var i = 0; i < items.Count; i++)
        {
            var item = items[i];
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            FrameworkElement name = item.Open is { } open && !item.IsEmpty
                ? Sans(item.Name, 14, PD.Ink).OnTap(open, item.Name)
                : Sans(item.Name, 14, PD.Ink, Medium);
            name.Height = 20;
            name.Margin = new Thickness(0, 14, 0, 0);
            var meta = Sans(item.Meta ?? " ", 13, PD.Mute).Frame(height: 18).Top(2);
            var column = VStack(0, Sheet(item), name, meta);
            Grid.SetColumn(column, i);
            row.Children.Add(column);
        }
        var shelf = VStack(0, head, row);
        shelf.Margin = new Thickness(0, 64, 0, 0);
        AutomationProperties.SetName(shelf, title);
        return shelf;
    }

    static FrameworkElement Sheet(CareerThumb item)
    {
        var content = Preview(item.Content);
        content.HorizontalAlignment = item.IsEmpty ? HorizontalAlignment.Center : HorizontalAlignment.Stretch;
        content.VerticalAlignment = item.IsEmpty ? VerticalAlignment.Center : VerticalAlignment.Top;
        var host = new Grid { Padding = new Thickness(18, 16, 18, 16), MinHeight = 136 };
        host.Children.Add(content);
        var shape = new Shapes.Rectangle
        {
            RadiusX = 14, RadiusY = 14, Fill = Brush(item.IsEmpty ? Hex(0xFAFAF8) : V3.White),
            Stroke = Brush(item.IsEmpty ? Hex(0xD6D6D0) : PD.Edge), StrokeThickness = 1,
        };
        if (item.IsEmpty) shape.StrokeDashArray = [4, 3];
        var sheet = Layer(shape, host);
        sheet.MinHeight = 136;
        if (!item.IsEmpty)
        {
            // 阴影：黑 6%、半径 9、下移 6
            shape.Elevate(6);
            if (item.Open is { } open) sheet.OnTap(open);
        }
        return sheet;
    }

    static FrameworkElement Bars(IEnumerable<double> widths)
    {
        var grid = new Grid { RowSpacing = 9 };
        var index = 0;
        foreach (var width in widths)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = Px(6) });
            var bar = new Grid();
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = Star(width) });
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = Star(Math.Max(0.0001, 100 - width)) });
            bar.Children.Add(new Border { Height = 6, CornerRadius = Capsule(6), Background = Brush(Hex(0xEEEEEA)) });
            Grid.SetRow(bar, index++);
            grid.Children.Add(bar);
        }
        grid.Height = index * 15;
        return grid;
    }

    static TextBlock Kicker(string text) => Sans(text, 11.5, PD.Mute, Medium).Frame(height: 16).Pad(0, 0, 0, 4);

    static FrameworkElement Preview(CareerThumb.Preview preview)
    {
        switch (preview)
        {
            case CareerThumb.Preview.Info info:
            {
                var stack = new StackPanel();
                for (var i = 0; i < info.Rows.Count; i++)
                {
                    var (label, value) = info.Rows[i];
                    var line = Spread(Sans(label, 12.5, PD.Mute).Also(t => t.TextTrimming = TextTrimming.None),
                        Sans(value ?? "没填", 12.5, value is null ? PD.Mute : PD.Ink, value is null ? Regular : Medium), 12);
                    var cell = new Border { Child = line, Height = 18 + 7 * 2, Padding = new Thickness(0, 7, 0, 7) };
                    if (i < info.Rows.Count - 1) { cell.BorderBrush = Brush(Hex(0xF1F0EC)); cell.BorderThickness = new Thickness(0, 0, 0, 1); }
                    stack.Children.Add(cell);
                }
                return stack;
            }
            case CareerThumb.Preview.Doc doc:
                return VStack(9, Sans(doc.Title, 13, PD.Ink, Medium), Bars(doc.Widths));
            case CareerThumb.Preview.List list:
            {
                var stack = new StackPanel();
                if (list.Kicker is { } kicker) stack.Children.Add(Kicker(kicker));
                foreach (var item in list.Items)
                    stack.Children.Add(HStack(8, new Shapes.Ellipse { Width = 4, Height = 4, Fill = Brush(Hex(0xB9B9B2)) }, Sans(item, 12.5, PD.Body)).Frame(height: 25));
                return stack;
            }
            case CareerThumb.Preview.Text text:
            {
                var stack = new StackPanel();
                if (text.Kicker is { } kicker) stack.Children.Add(Kicker(kicker));
                // lineSpacing(4)：12.5px 字的默认行高约 17，再加 4
                stack.Children.Add(Sans(text.Body, 12.5, text.Strong ? PD.Ink : PD.Body, text.Strong ? Medium : Regular).Wrap(2).LineHeight(21));
                if (text.Strong) stack.Children.Add(Bars([82, 60, 70]).Top(8));
                return stack;
            }
            case CareerThumb.Preview.Files files:
            {
                var stack = new StackPanel();
                foreach (var name in files.Names)
                {
                    var badge = new Border
                    {
                        Width = 30, Height = 34, CornerRadius = new CornerRadius(6), Background = Brush(V3.Field),
                        Child = Label(CareerFileBadge.Badge(name), 9, PD.Mute, Semibold).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
                    };
                    stack.Children.Add(HStack(10, badge, Sans(name, 12.5, PD.Body)).Frame(height: 46));
                }
                if (files.More > 0) stack.Children.Add(Sans($"还有 {files.More} 份", 12, PD.Mute));
                return stack;
            }
            case CareerThumb.Preview.Qa qa:
            {
                var stack = new StackPanel();
                foreach (var (question, index) in qa.Questions.Take(2).Select((q, i) => (q, i)))
                {
                    stack.Children.Add(HStack(10, Sans("问", 11, index == 0 ? PD.Ink : PD.Mute, Medium).Frame(width: 14), Sans(question, 12.5, PD.Body)).Frame(height: 25));
                    var bar = new Grid { VerticalAlignment = VerticalAlignment.Center };
                    var share = index == 0 ? 78 : 56;
                    bar.ColumnDefinitions.Add(new ColumnDefinition { Width = Star(share) });
                    bar.ColumnDefinitions.Add(new ColumnDefinition { Width = Star(100 - share) });
                    bar.Children.Add(new Border { Height = 6, CornerRadius = Capsule(6), Background = Brush(Hex(0xEEEEEA)) });
                    stack.Children.Add(Columns(10, (Px(14), Sans("答", 11, PD.Mute, Medium).Align(v: VerticalAlignment.Center)), (Star(), bar)).Frame(height: 25));
                }
                return stack;
            }
            case CareerThumb.Preview.Checks checks:
            {
                var stack = new StackPanel();
                foreach (var (title, done, toggle) in checks.Items)
                {
                    var box = new Border
                    {
                        Width = 15, Height = 15, CornerRadius = new CornerRadius(4), BorderThickness = new Thickness(1.4),
                        BorderBrush = Brush(done ? PD.Blue : Hex(0xC9C9C3)), Background = Brush(done ? PD.Blue : V3.White),
                        Child = done ? Icon("checkmark", 8, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center) : null,
                    }.OnTap(toggle, title);
                    if (done) AutomationProperties.SetItemStatus(box, "已选中");
                    var label = Sans(title, 12.5, done ? PD.Mute : PD.Body);
                    if (done) label.TextDecorations = TextDecorations.Strikethrough;
                    stack.Children.Add(HStack(10, box, label).Frame(height: 30));
                }
                return stack;
            }
            case CareerThumb.Preview.Written written:
            {
                var stack = new StackPanel();
                foreach (var (no, question, correctness) in written.Rows)
                    stack.Children.Add(Columns(8,
                        (Px(14), Label(no, 12, PD.Mute, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center)),
                        (Star(), Sans(question, 12.5, PD.Body).Align(v: VerticalAlignment.Center)),
                        (Px(14), Sans(correctness == "correct" ? "✓" : correctness == "wrong" ? "✕" : "", 12.5, correctness == "wrong" ? PD.Red : PD.Ink).Align(HorizontalAlignment.Center, VerticalAlignment.Center))).Frame(height: 30));
                return stack;
            }
            case CareerThumb.Preview.Empty empty:
            {
                var stack = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
                stack.Children.Add(Icon(empty.Icon, 15, Hex(0xA3A39C)).Frame(18, 18).Align(HorizontalAlignment.Center));
                stack.Children.Add(Sans(empty.Message, 12.5, PD.Body).Wrap().Also(t => { t.TextAlignment = TextAlignment.Center; t.MinHeight = 18; t.HorizontalAlignment = HorizontalAlignment.Center; }));
                if (empty.Actions.Count > 0)
                {
                    var actions = HStack(8, empty.Actions.Select(a => (UIElement)new PDMiniButton(a.Label, a.Run)).ToArray());
                    actions.HorizontalAlignment = HorizontalAlignment.Center;
                    actions.Margin = new Thickness(0, 4, 0, 0);
                    stack.Children.Add(actions);
                }
                return stack;
            }
            default:
                return new Border();
        }
    }
}
