using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.DesignSystem;

/// <summary>
/// `.v3-btn`：胶囊按钮，对应 Swift `V3ButtonStyle`。WinUI 的 Button 自带 Fluent 模板，
/// 这里用 Border + 指针事件自绘，按下/悬停/禁用的颜色与 Web 一致。
/// </summary>
public sealed class V3Button : BorderControl
{
    public enum Kind { Dark, Ghost, Text, Danger }

    readonly Kind _kind;
    readonly StackPanel _row = new() { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly Action _action;
    readonly TextBlock _label;
    bool _hover, _pressed, _enabled = true;

    public V3Button(string title, Action action, Kind kind = Kind.Ghost, double height = 32, double? width = null, bool small = false, bool fill = false, string? icon = null)
    {
        _kind = kind;
        _action = action;
        var size = kind == Kind.Text ? 13 : small ? 12 : 14;
        if (icon is not null) _row.Children.Add(Icon(icon, size - 1, Ink));
        _label = Sans(title, size, Ink, Medium);
        _row.Children.Add(_label);
        Child = _row;
        Height = kind == Kind.Text ? double.NaN : height;
        if (width is { } w) Width = w;
        HorizontalAlignment = fill ? HorizontalAlignment.Stretch : HorizontalAlignment.Left;
        Padding = new Thickness(kind == Kind.Text ? 0 : height >= 36 ? 18 : 14, 0, kind == Kind.Text ? 0 : height >= 36 ? 18 : 14, 0);
        CornerRadius = Capsule(height);
        BorderThickness = new Thickness(kind == Kind.Ghost ? 1 : 0);
        BorderBrush = Brush(Cl);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, title);
        PointerEntered += (_, _) => { _hover = true; Paint(); };
        PointerExited += (_, _) => { _hover = false; _pressed = false; Paint(); };
        PointerPressed += (_, e) => { if (_enabled) { _pressed = true; Paint(); e.Handled = true; } };
        PointerReleased += (_, e) => { if (_pressed && _enabled) { _pressed = false; Paint(); e.Handled = true; _action(); } };
        PointerCanceled += (_, _) => { _pressed = false; Paint(); };
        IsTabStop = true;
        KeyDown += (_, e) => { if (_enabled && e.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space) { e.Handled = true; _action(); } };
        Paint();
    }

    public bool Enabled { get => _enabled; set { _enabled = value; Paint(); } }

    /// <summary>按钮文字（如“正在删除…”）。</summary>
    public string Title { get => _label.Text; set => _label.Text = value; }
    public double TextSize { get => _label.FontSize; set => _label.FontSize = value; }

    Color Ink => _kind is Kind.Dark or Kind.Danger ? V3.White : _kind == Kind.Text ? (_pressed || _hover ? Txt : Sub) : Txt;

    void Paint()
    {
        Background = Brush(_kind switch
        {
            Kind.Dark => _pressed ? Hex(0x0E0E0D) : _hover ? Hex(0x2F2F2C) : Txt,
            Kind.Danger => _pressed || _hover ? Hex(0xC33B3B) : Red,
            Kind.Ghost => _pressed || _hover ? Field : V3.White,
            _ => Clear,
        });
        foreach (var child in _row.Children)
        {
            if (child is TextBlock text) text.Foreground = Brush(Ink);
            if (child is FontIcon icon) icon.Foreground = Brush(Ink);
        }
        Opacity = _enabled ? 1 : 0.38;
        ProtectedCursor = InputSystemCursor.Create(_enabled ? InputSystemCursorShape.Hand : InputSystemCursorShape.Arrow);
    }
}

/// <summary>Full-width 44pt dark submit (`.mi-new-submit`)，对应 Swift `V3PrimaryBlockStyle`。</summary>
public static class V3PrimaryBlock
{
    public static V3Button Make(string title, Action action)
    {
        var button = new V3Button(title, action, V3Button.Kind.Dark, height: 44, fill: true);
        button.TextSize = 13.5;
        return button;
    }
}

/// <summary>`.v3-search`，对应 Swift `V3SearchField`：灰底 32 高、圆角 8、聚焦变白加边。</summary>
public sealed class V3SearchField : Grid
{
    public TextBox Box { get; }
    public event Action<string>? Changed;

    public V3SearchField(string placeholder, string text = "", double? width = 180, double height = 32)
    {
        if (width is { } w) Width = w;
        Height = height;
        Box = new TextBox
        {
            Text = text, PlaceholderText = placeholder, FontSize = 14, FontFamily = SansFamily, Height = height, MinHeight = 0,
            Padding = new Thickness(30, (height - 20) / 2, 28, 0), CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1), BorderBrush = Brush(Clear), Background = Brush(Field), Foreground = Brush(Txt),
            PlaceholderForeground = Brush(Fnt), VerticalContentAlignment = VerticalAlignment.Center,
        };
        var glass = Icon("magnifyingglass", 12, Fnt).Align(HorizontalAlignment.Left, VerticalAlignment.Center).Pad(10, 0, 0, 0);
        glass.IsHitTestVisible = false;
        var clear = Icon("xmark.circle.fill", 11, Fnt2).Align(HorizontalAlignment.Right, VerticalAlignment.Center).Pad(0, 0, 10, 0).Tip("清除搜索");
        clear.Visibility = text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        clear.PointerReleased += (_, _) => Box.Text = "";
        Box.TextChanged += (_, _) => { clear.Visibility = Box.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed; Changed?.Invoke(Box.Text); };
        Box.GotFocus += (_, _) => { Box.Background = Brush(V3.White); Box.BorderBrush = Brush(Sk2); };
        Box.LostFocus += (_, _) => { Box.Background = Brush(Field); Box.BorderBrush = Brush(Clear); };
        Children.Add(Box);
        Children.Add(glass);
        Children.Add(clear);
    }
}

/// <summary>`.v3-seg`：灰色轨道里白色选中段，对应 Swift `V3Segmented`。</summary>
public sealed class V3Segmented<T> : BorderControl where T : notnull
{
    readonly List<(T value, string label, Border cell, TextBlock text)> _cells = [];
    T _selection;
    public event Action<T>? Changed;

    public V3Segmented(IEnumerable<(T value, string label)> options, T selection, double? segmentWidth = null, double height = 30, double fontSize = 14)
    {
        _selection = selection;
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (value, label) in options)
        {
            var text = Sans(label, fontSize, Sub, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            var cell = new Border { Child = text, Height = height - 6, CornerRadius = new CornerRadius(6), Padding = new Thickness(segmentWidth is null ? 12 : 0, 0, segmentWidth is null ? 12 : 0, 0) };
            if (segmentWidth is { } w) cell.Width = w;
            var entry = value;
            cell.PointerReleased += (_, _) => Select(entry);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(cell, label);
            _cells.Add((value, label, cell, text));
            row.Children.Add(cell);
        }
        Child = row;
        Padding = new Thickness(3);
        Height = height;
        CornerRadius = new CornerRadius(8);
        Background = Brush(Field);
        HorizontalAlignment = HorizontalAlignment.Left;
        Paint();
    }

    public T Selection => _selection;

    public void Select(T value)
    {
        if (EqualityComparer<T>.Default.Equals(value, _selection)) return;
        _selection = value;
        Paint();
        Changed?.Invoke(value);
    }

    void Paint()
    {
        foreach (var (value, _, cell, text) in _cells)
        {
            var chosen = EqualityComparer<T>.Default.Equals(value, _selection);
            cell.Background = Brush(chosen ? V3.White : Clear);
            text.Foreground = Brush(chosen ? Txt : Sub);
            if (chosen) cell.Elevate(2); else { cell.Shadow = null; cell.Translation = default; }
        }
    }
}

/// <summary>`.v3-chip`，对应 Swift `V3Chip`。</summary>
public static class V3Chip
{
    public static Border Make(string label, Color? foreground = null, Color? background = null, double height = 22, double size = 12) => new()
    {
        Child = Sans(label, size, foreground ?? Sub, Medium).Align(v: VerticalAlignment.Center),
        Padding = new Thickness(7, 0, 7, 0), Height = height, CornerRadius = new CornerRadius(5),
        Background = Brush(background ?? Field), HorizontalAlignment = HorizontalAlignment.Left,
    };
}

/// <summary>
/// `.v3-stage.has-dots`：点阵底的插图舞台，对应 Swift `V3DotStage`。点距 14、首点偏移 5、半径 0.9、颜色 #D6D6D1。
/// 点阵用 <see cref="Canvas"/> 里的椭圆在尺寸变化时重画。
/// </summary>
public sealed class V3DotStage : Grid
{
    readonly Canvas _dots = new() { IsHitTestVisible = false };

    public V3DotStage(UIElement? content = null, double? height = 200)
    {
        Background = Brush(Stage);
        CornerRadius = new CornerRadius(11);
        if (height is { } h) Height = h;
        Children.Add(_dots);
        if (content is not null) Children.Add(content);
        SizeChanged += (_, e) => Draw(e.NewSize.Width, e.NewSize.Height);
    }

    void Draw(double width, double height)
    {
        _dots.Children.Clear();
        var brush = Brush(0xD6D6D1);
        for (var x = 5.0; x <= width; x += 14)
            for (var y = 5.0; y <= height; y += 14)
            {
                var dot = new Ellipse { Width = 1.8, Height = 1.8, Fill = brush };
                Canvas.SetLeft(dot, x - 0.9);
                Canvas.SetTop(dot, y - 0.9);
                _dots.Children.Add(dot);
            }
    }
}

/// <summary>`.v3-empty`：520 宽、插图 + 衬线标题 + 说明 + 按钮的空状态卡，对应 Swift `V3EmptyCard`。</summary>
public static class V3EmptyCard
{
    public static Border Make(string title, string message, UIElement? art, IEnumerable<UIElement> actions,
        double stageHeight = 200, double width = 520, double inset = 8, double messageTop = 10, double actionsTop = 26)
    {
        var body = VStack(0,
            new V3DotStage(art, stageHeight),
            Serif(title, 18).Frame(height: 26).Pad(24, 22, 24, 0),
            Sans(message, 13, Sub).LineHeight(22).Wrap().Pad(24, messageTop, 24, 0),
            HStack(20, actions.ToArray()).Pad(24, actionsTop, 24, 0));
        return new Border
        {
            Child = body, Padding = new Thickness(inset, inset, inset, 30), MaxWidth = width, CornerRadius = new CornerRadius(16),
            Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        }.Elevate(4);
    }
}

/// <summary>`.v3-menu` 一类浮层里的菜单行，对应 Swift `V3MenuRow`：34 高、12.5px、悬停灰底（危险项红底）。</summary>
public sealed class V3MenuRow : BorderControl
{
    public V3MenuRow(string label, Action action, string? icon = null, bool isChecked = false, bool danger = false)
    {
        var color = danger ? Red : Txt;
        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = icon is null ? new GridLength(0) : new GridLength(15) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (icon is not null) row.Children.Add(Icon(icon, 13, color));
        var text = Label(label, 12.5, color).Align(v: VerticalAlignment.Center);
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        if (isChecked) { var mark = Icon("checkmark", 11, color); Grid.SetColumn(mark, 2); row.Children.Add(mark); }
        Child = row;
        Height = 34;
        Padding = new Thickness(10, 0, 10, 0);
        CornerRadius = new CornerRadius(6);
        Background = Brush(Clear);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, label);
        PointerEntered += (_, _) => Background = Brush(danger ? RedSoft : Field);
        PointerExited += (_, _) => Background = Brush(Clear);
        PointerReleased += (_, _) => action();
    }
}

/// <summary>
/// `.v3-page`：内容卡里的页面容器，对应 Swift `V3Page`。最大宽度随卡宽分档（&lt;1180 为 860、≥1180 为 1100、≥1800 为 1400），
/// 左右留白取 max(24, 3% 卡宽) 与居中余量中较大者，上 52、下 60。
/// </summary>
public sealed class V3Page : UserControl
{
    readonly Border _host = new();

    public static double MaxWidthFor(double card) => card >= 1800 ? 1400 : card >= 1180 ? 1100 : 860;
    public static double Gutter(double card) => Math.Max(Math.Max(24, card * 0.03), (card - MaxWidthFor(card)) / 2);

    public ScrollViewer Scroller { get; } = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };

    public V3Page(UIElement content, double top = 52, double bottom = 60)
    {
        _host.Child = content;
        Scroller.Content = _host;
        Content = Scroller;
        SizeChanged += (_, e) =>
        {
            var gutter = Gutter(e.NewSize.Width);
            _host.Padding = new Thickness(gutter, top, gutter, bottom);
        };
    }
}

/// <summary>Web `components/ui/pagination.tsx`，对应 Swift `V3Pagination`。</summary>
public static class V3Pagination
{
    /// <summary>超过 7 页时保留首尾与当前前后一页，中间用 null 表示省略。</summary>
    public static List<int?> Numbers(int current, int total) => Core.Ui.Pagination.Numbers(current, total);

    public static Grid Make(int page, int total, Action<int> change, int pageSize = 20, bool loading = false)
    {
        var count = Math.Max(1, (total + pageSize - 1) / pageSize);
        var cells = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        cells.Children.Add(Cell("上一页", false, page > 1 && !loading, () => change(page - 1)));
        foreach (var value in Numbers(page, count))
            cells.Children.Add(value is { } n ? Cell($"{n}", n == page, !loading, () => change(n)).Tip($"第 {n} 页") : Label("…", 12, Sub));
        cells.Children.Add(Cell("下一页", false, page < count && !loading, () => change(page + 1)));
        return Spread(Label($"共 {total} 条 · 每页 {pageSize} 条", 12, Sub), cells, 12).Pad(0, 20, 0, 20);
    }

    static Border Cell(string title, bool current, bool enabled, Action action)
    {
        var cell = new Border
        {
            Child = Label(title, 12, current ? V3.White : Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            Padding = new Thickness(10, 0, 10, 0), MinWidth = 32, MinHeight = 32, CornerRadius = new CornerRadius(8),
            Background = Brush(current ? Blue : Clear), BorderBrush = Brush(current ? Blue : Cl), BorderThickness = new Thickness(1),
            Opacity = enabled ? 1 : 0.45,
        };
        if (enabled) cell.PointerReleased += (_, _) => action();
        return cell;
    }
}

/// <summary>`.v3-dialog-title` / `.v3-dialog-sub`，对应 Swift `V3DialogHead`：20px 半粗标题（行高 28），14px 说明（行高 22，距标题 8）。</summary>
public static class V3DialogHead
{
    public static StackPanel Make(string title, string? sub = null, double subTop = 8, double subLine = 22) => VStack(0,
        Label(title, 20, Txt, Semibold).Frame(height: 28).Pad(0, 0, 28, 0),
        sub is null ? null : Sans(sub, 14, Sub).LineHeight(subLine).Wrap().Top(subTop));
}

/// <summary>
/// `.v3-field` + `.v3-input`，对应 Swift `V3TextInput`：14px 中粗标签（行高 20）、间距 8、40 高圆角 8 内边距 14 的输入框，出错时红框与提示。
/// </summary>
public sealed class V3TextInput : StackPanel
{
    public TextBox Box { get; }
    readonly TextBlock _error;

    public V3TextInput(string label, string placeholder, string text = "", int maxLength = 255, Action? submit = null)
    {
        Spacing = 8;
        Box = new TextBox
        {
            Text = text, PlaceholderText = placeholder, MaxLength = maxLength, FontSize = 14, FontFamily = SansFamily, Height = 40, MinHeight = 0,
            Padding = new Thickness(14, 10, 14, 0), CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), BorderBrush = Brush(Cl),
            Background = Brush(V3.White), Foreground = Brush(Txt), PlaceholderForeground = Brush(Fnt2),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(Box, label);
        Box.GotFocus += (_, _) => Paint(true);
        Box.LostFocus += (_, _) => Paint(false);
        Box.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) submit?.Invoke(); };
        Box.Loaded += (_, _) => Box.Focus(FocusState.Programmatic);
        _error = Sans("", 14, Red).LineHeight(22).Wrap();
        _error.Visibility = Visibility.Collapsed;
        Children.Add(Sans(label, 14, Sub, Medium).Frame(height: 20));
        Children.Add(Box);
        Children.Add(_error);
    }

    public string Text { get => Box.Text; set => Box.Text = value; }

    public string? Error
    {
        get => _error.Visibility == Visibility.Visible ? _error.Text : null;
        set { _error.Text = value ?? ""; _error.Visibility = value is null ? Visibility.Collapsed : Visibility.Visible; Paint(Box.FocusState != FocusState.Unfocused); }
    }

    void Paint(bool focused) => Box.BorderBrush = Brush(Error is not null ? Red : focused ? Txt : Cl);
}

/// <summary>
/// `.career-v3-head`，对应 Swift `V3PageHead`：眉题 12/500 #6C6C65（18 高）、28px 衬线标题（36 高，距眉题 8）、
/// 14px 副标题（距标题 6，可指定行高 20）、右侧按钮距顶 31、间距 10。
/// `compact` 是「我的简历」的 `.hv3-head`：标题距眉题 9、说明 13px / 16 高距标题 6、按钮距顶 32、间距 8。
/// </summary>
public static class V3PageHead
{
    public static Grid Make(IEnumerable<string> eyebrow, string title, string? subtitle = null, bool compact = false, double? subtitleHeight = null, params UIElement[] actions)
    {
        var labels = VStack(0,
            Sans(string.Join(" · ", eyebrow), 12, Fnt, Medium).Frame(height: 18),
            Serif(title, 28).Frame(height: 36).Top(compact ? 9 : 8),
            subtitle is null ? null : Sans(subtitle, compact ? 13 : 14, Sub).Frame(height: compact ? 16 : subtitleHeight).Top(6));
        var buttons = HStack(compact ? 8 : 10, actions);
        buttons.Margin = new Thickness(0, compact ? 32 : 31, 0, 0);
        return Spread(labels, buttons, 24, VerticalAlignment.Top);
    }
}
