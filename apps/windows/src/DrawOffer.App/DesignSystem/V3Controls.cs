using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.DesignSystem;

/// <summary>
/// Windows 稿 00 页 Button（跟 Web `.v3-btn`）：胶囊 999 圆角，高 32（13px、左右 14）/ 28（12px、左右 12）。
/// Primary 墨黑（一页只放一个）、Secondary 白底 #E4E4E0 细边、Text 灰字无底、Danger 红底；悬停加深、按下缩到 .98、禁用 .38。
/// WinUI Button 的 Fluent 模板改色麻烦，这里用 Border + 指针事件自绘。
/// </summary>
public sealed class V3Button : BorderControl
{
    public enum Kind { Dark, Ghost, Text, Danger }

    readonly Kind _kind;
    readonly StackPanel _row = new() { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly Action _action;
    readonly TextBlock _label;
    bool _hover, _pressed, _enabled = true;

    /// <param name="height">稿里只有 32 和 28 两档：小于 30 的按 28 画，其余按 32（旧调用里的 36/40/44 都收成 32）。</param>
    public V3Button(string title, Action action, Kind kind = Kind.Ghost, double height = 32, double? width = null, bool small = false, bool fill = false, string? icon = null)
    {
        _kind = kind;
        _action = action;
        var compact = small || height < 30;
        var h = compact ? 28 : 32;
        var size = compact ? 12 : 13;
        if (icon is not null) _row.Children.Add(Icon(icon, size, Ink));
        _label = Sans(title, size, Ink, Medium);
        _row.Children.Add(_label);
        Child = _row;
        Height = h;
        if (width is { } w) Width = w;
        HorizontalAlignment = fill ? HorizontalAlignment.Stretch : HorizontalAlignment.Left;
        var pad = kind == Kind.Text ? 4 : compact ? 12 : 14;
        Padding = new Thickness(pad, 0, pad, 0);
        CornerRadius = new CornerRadius(999);
        BorderThickness = new Thickness(kind == Kind.Ghost ? 1 : 0);
        BorderBrush = Brush(Cl);
        RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
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

    /// <summary>程序触发（快捷键）。</summary>
    public void Invoke() { if (_enabled) _action(); }

    /// <summary>文字按钮的着色（如红色“移除头像”）；不设时按种类取色。</summary>
    public Color? Tint { get => _tint; set { _tint = value; Paint(); } }
    Color? _tint;

    Color Ink => _kind is Kind.Dark or Kind.Danger ? V3.White : _tint ?? (_kind == Kind.Text ? (_pressed || _hover ? Txt : Sub) : Txt);

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
        RenderTransform = _pressed ? new ScaleTransform { ScaleX = 0.98, ScaleY = 0.98 } : null;
        Opacity = _enabled ? 1 : 0.38;
        ProtectedCursor = InputSystemCursor.Create(_enabled ? InputSystemCursorShape.Hand : InputSystemCursorShape.Arrow);
    }
}

/// <summary>整行宽的墨黑提交按钮（32 高胶囊）。</summary>
public static class V3PrimaryBlock
{
    public static V3Button Make(string title, Action action) => new(title, action, V3Button.Kind.Dark, fill: true);
}

/// <summary>
/// Windows 稿 IconButton（SubtleButtonStyle）：28×28、圆角 4，静止透明、悬停 #F4F4F2；不可用时图标 #C4C4BE。
/// </summary>
public sealed class V3IconButton : BorderControl
{
    readonly FontIcon _icon;
    readonly Action _action;
    readonly Color _color;
    bool _enabled = true;

    public V3IconButton(string symbol, string label, Action action, double size = 28, double glyph = 14, Color? color = null)
    {
        _action = action;
        _color = color ?? Sub;
        _icon = Icon(symbol, glyph, _color);
        Child = _icon.Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        Width = size;
        Height = size;
        CornerRadius = new CornerRadius(4);
        Background = Brush(Clear);
        IsTabStop = true;
        this.Tip(label);
        PointerEntered += (_, _) => { if (_enabled) Background = Brush(Field); };
        PointerExited += (_, _) => Background = Brush(Clear);
        PointerReleased += (_, e) => { if (_enabled) { e.Handled = true; _action(); } };
        KeyDown += (_, e) => { if (_enabled && e.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space) { e.Handled = true; _action(); } };
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.Hand);
    }

    public bool Enabled
    {
        get => _enabled;
        set { _enabled = value; _icon.Foreground = Brush(value ? _color : Fnt2); if (!value) Background = Brush(Clear); }
    }

    public string Glyph { set => _icon.Glyph = Icons.Glyph(value); }
}

/// <summary>
/// Windows 稿 AutoSuggestBox（跟 Web `.v3-search`）：32 高、圆角 4、#F4F4F2 灰底无边框，放大镜在左，占位 #C4C4BE；
/// 聚焦变白底 #DCDCD8 细边。列表页放在分组标题行右侧，与标题垂直居中、右缘对齐页头主按钮。
/// </summary>
public sealed class V3SearchField : Grid
{
    public TextBox Box { get; }
    public event Action<string>? Changed;

    public V3SearchField(string placeholder, string text = "", double? width = 240, double height = 32)
    {
        if (width is { } w) Width = w;
        Height = height;
        Box = new TextBox
        {
            Text = text, PlaceholderText = placeholder, FontSize = 13, FontFamily = SansFamily, Height = height, MinHeight = 0,
            Padding = new Thickness(34, (height - 20) / 2, 28, 0), CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(1), BorderBrush = Brush(Clear), Background = Brush(Field), Foreground = Brush(Txt),
            PlaceholderForeground = Brush(Fnt2), VerticalContentAlignment = VerticalAlignment.Center,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(Box, placeholder.TrimEnd('…'));
        var glass = Icon("magnifyingglass", 13, Sub).Align(HorizontalAlignment.Left, VerticalAlignment.Center).Pad(11, 0, 0, 0);
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

    public string Text { get => Box.Text; set => Box.Text = value; }
}

/// <summary>Windows 稿 Segmented：#F4F4F2 灰槽、圆角 6，选中项白底 #E4E4E0 细边、墨色 500 字（不用黑色，黑色只给主按钮）。</summary>
public sealed class V3Segmented<T> : BorderControl where T : notnull
{
    readonly List<(T value, string label, Border cell, TextBlock text)> _cells = [];
    T _selection;
    public event Action<T>? Changed;

    public V3Segmented(IEnumerable<(T value, string label)> options, T selection, double? segmentWidth = null, double height = 32, double fontSize = 13)
    {
        _selection = selection;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        foreach (var (value, label) in options)
        {
            var text = Sans(label, Math.Min(fontSize, 13), Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            var cell = new Border
            {
                Child = text, Height = height - 6, CornerRadius = new CornerRadius(4), BorderThickness = new Thickness(1),
                Padding = new Thickness(segmentWidth is null ? 12 : 0, 0, segmentWidth is null ? 12 : 0, 0),
            };
            if (segmentWidth is { } w) cell.Width = w;
            var entry = value;
            cell.OnTap(() => Select(entry), label);
            _cells.Add((value, label, cell, text));
            row.Children.Add(cell);
        }
        Child = row;
        Padding = new Thickness(3);
        Height = height;
        CornerRadius = new CornerRadius(6);
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
            cell.BorderBrush = Brush(chosen ? Cl : Clear);
            text.Foreground = Brush(chosen ? Txt : Sub);
            text.FontWeight = chosen ? Medium : Regular;
        }
    }
}

/// <summary>Windows 稿 FilterChip（ToggleButton，替代 macOS ScopeButton）：28 高胶囊、12/500；选中白底 #DCDCD8 细边，未选 #F4F4F2 灰底。</summary>
public sealed class V3FilterChip : BorderControl
{
    readonly TextBlock _text;
    bool _on;

    public V3FilterChip(string label, bool on, Action action)
    {
        _text = Sans(label, 12, Sub, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        Child = _text;
        Height = 28;
        Padding = new Thickness(12, 0, 12, 0);
        CornerRadius = new CornerRadius(999);
        BorderThickness = new Thickness(1);
        HorizontalAlignment = HorizontalAlignment.Left;
        this.OnTap(action, label);
        On = on;
    }

    public bool On
    {
        get => _on;
        set
        {
            _on = value;
            Background = Brush(value ? V3.White : Field);
            BorderBrush = Brush(value ? Sk2 : Field);
            _text.Foreground = Brush(value ? Txt : Sub);
        }
    }
}

/// <summary>状态标签（Web `.v3-pill` / 稿 Tag）：22 高、圆角 11，浅色底 + 同色字。<see cref="Make"/> 保留旧的 `.v3-chip` 写法。</summary>
public static class V3Chip
{
    public static Border Make(string label, Color? foreground = null, Color? background = null, double height = 22, double size = 12) => new()
    {
        Child = Sans(label, size, foreground ?? Sub, Medium).Align(v: VerticalAlignment.Center),
        Padding = new Thickness(8, 0, 8, 0), Height = height, CornerRadius = new CornerRadius(height / 2),
        Background = Brush(background ?? Field), HorizontalAlignment = HorizontalAlignment.Left,
    };
}

/// <summary>
/// `.v3-stage.has-dots`：点阵底的插图舞台，点距 14、首点偏移 5、半径 0.9、颜色 #D6D6D1。
/// </summary>
public sealed class V3DotStage : Grid
{
    readonly Canvas _dots = new() { IsHitTestVisible = false };

    public V3DotStage(UIElement? content = null, double? height = 200)
    {
        Background = Brush(Stage);
        CornerRadius = new CornerRadius(8);
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

/// <summary>空状态卡：插图舞台 + 18/600 标题 + 13px 说明 + 按钮行；圆角 8、细边。</summary>
public static class V3EmptyCard
{
    public static Border Make(string title, string message, UIElement? art, IEnumerable<UIElement> actions,
        double stageHeight = 200, double width = 520, double inset = 8, double messageTop = 10, double actionsTop = 24)
    {
        var body = VStack(0,
            new V3DotStage(art, stageHeight),
            Label(title, 18, Txt, Semibold).Frame(height: 26).Pad(24, 22, 24, 0),
            Sans(message, 13, Sub).LineHeight(22).Wrap().Pad(24, messageTop, 24, 0),
            HStack(12, actions.ToArray()).Pad(24, actionsTop, 24, 0));
        return new Border
        {
            Child = body, Padding = new Thickness(inset, inset, inset, 28), MaxWidth = width, CornerRadius = new CornerRadius(8),
            Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        };
    }
}

/// <summary>Windows 稿 MenuFlyoutItem：32 高、圆角 4、内边距 10、13px；图标 16 灰、快捷键 12 灰靠右；悬停 #F4F4F2，危险项红字。</summary>
public sealed class V3MenuRow : BorderControl
{
    public V3MenuRow(string label, Action action, string? icon = null, bool isChecked = false, bool danger = false, string? shortcut = null)
    {
        var color = danger ? Red : Txt;
        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = icon is null ? new GridLength(0) : new GridLength(16) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (icon is not null) row.Children.Add(Icon(icon, 14, danger ? Red : Sub));
        var text = Label(label, 13, color).Align(v: VerticalAlignment.Center);
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        UIElement? trailing = isChecked ? Icon("checkmark", 12, color) : shortcut is null ? null : Label(shortcut, 12, Fnt);
        if (trailing is FrameworkElement t) { t.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(t, 2); row.Children.Add(t); }
        Child = row;
        Height = 32;
        Padding = new Thickness(10, 0, 10, 0);
        CornerRadius = new CornerRadius(4);
        Background = Brush(Clear);
        PointerEntered += (_, _) => Background = Brush(Field);
        PointerExited += (_, _) => Background = Brush(Clear);
        this.OnTap(action, label);
    }

    /// <summary>菜单分隔线（上下各 4）。</summary>
    public static Border Separator() => Divider().Pad(0, 4, 0, 4);
}

/// <summary>
/// 内容区页面容器（Web `.v3-page`）：最大宽度随内容区宽度分档（&lt;1180 为 860、≥1180 为 1100、≥1800 为 1400），
/// 左右留白取 max(24, 3% 宽) 与居中余量中较大者，上 40、下 60。滚动条是 WinUI 自动隐藏的悬浮细条。
/// </summary>
public sealed class V3Page : UserControl
{
    readonly Border _host = new();

    public static double MaxWidthFor(double card) => card >= 1800 ? 1400 : card >= 1180 ? 1100 : 860;
    public static double Gutter(double card) => Math.Max(Math.Max(24, card * 0.03), (card - MaxWidthFor(card)) / 2);

    public ScrollViewer Scroller { get; } = V3.Scroll();

    public V3Page(UIElement content, double top = 40, double bottom = 60)
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

/// <summary>Windows 稿 Pagination：左侧「共 N 条 · 每页 M 条」，右侧 28×28 Subtle 按钮（‹ 页码 ›），当前页 #E6E6E2 底 500 字。</summary>
public static class V3Pagination
{
    /// <summary>超过 7 页时保留首尾与当前前后一页，中间用 null 表示省略。</summary>
    public static List<int?> Numbers(int current, int total) => Core.Ui.Pagination.Numbers(current, total);

    public static Grid Make(int page, int total, Action<int> change, int pageSize = 20, bool loading = false)
    {
        var count = Math.Max(1, (total + pageSize - 1) / pageSize);
        var cells = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        cells.Children.Add(Cell(null, "chevron.left", false, page > 1 && !loading, () => change(page - 1)).Tip("上一页"));
        foreach (var value in Numbers(page, count))
            cells.Children.Add(value is { } n ? Cell($"{n}", null, n == page, !loading, () => change(n)).Tip($"第 {n} 页") : Label("…", 13, Sub).Frame(28).Align(v: VerticalAlignment.Center));
        cells.Children.Add(Cell(null, "chevron.right", false, page < count && !loading, () => change(page + 1)).Tip("下一页"));
        return Spread(Label($"共 {total} 条 · 每页 {pageSize} 条", 12, Sub), cells, 12).Pad(0, 20, 0, 20);
    }

    static Border Cell(string? title, string? icon, bool current, bool enabled, Action action)
    {
        UIElement content = icon is not null ? Icon(icon, 12, Sub) : Label(title!, 13, current ? Txt : Sub, current ? Medium : Regular);
        var cell = new Border
        {
            Child = ((FrameworkElement)content).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            MinWidth = 28, Height = 28, Padding = new Thickness(4, 0, 4, 0), CornerRadius = new CornerRadius(4),
            Background = Brush(current ? Hl : Clear), Opacity = enabled ? 1 : 0.38,
        };
        if (enabled)
        {
            cell.OnTap(action);
            if (!current) cell.OnHover(h => cell.Background = Brush(h ? Field : Clear));
        }
        return cell;
    }
}

/// <summary>Windows 稿 ContentDialog 正文：标题 20/700（行高 28），说明 14 #55554F（行高 22，距标题 12）。</summary>
public static class V3DialogHead
{
    public static StackPanel Make(string title, string? sub = null, double subTop = 12, double subLine = 22) => VStack(0,
        Label(title, 20, Txt, Bold).Wrap().LineHeight(28),
        sub is null ? null : Sans(sub, 14, Sub).LineHeight(subLine).Wrap().Top(subTop));
}

/// <summary>
/// Windows 稿 TextBox：标签 13/500 #55554F（距输入框 8）；输入框 32 高、圆角 4、#E4E4E0 细边、底部 1px #C4C4BE 强调线，
/// 聚焦时底线 2px 墨黑（不用系统蓝），出错时红框红底线与 12px 红字提示。
/// </summary>
public sealed class V3TextInput : StackPanel
{
    public TextBox Box { get; }
    readonly TextBlock _error;
    readonly Border _accent;

    public V3TextInput(string label, string placeholder, string text = "", int maxLength = 255, Action? submit = null, bool autofocus = true, bool multiline = false)
    {
        Spacing = 8;
        Box = V3.Input(placeholder, text, maxLength, multiline);
        _accent = new Border { Height = 1, Background = Brush(Fnt2), VerticalAlignment = VerticalAlignment.Bottom, CornerRadius = new CornerRadius(0, 0, 4, 4), IsHitTestVisible = false };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(Box, label);
        Box.GotFocus += (_, _) => Paint(true);
        Box.LostFocus += (_, _) => Paint(false);
        if (!multiline) Box.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) submit?.Invoke(); };
        if (autofocus) Box.Loaded += (_, _) => Box.Focus(FocusState.Programmatic);
        _error = Sans("", 12, Red).LineHeight(18).Wrap();
        _error.Visibility = Visibility.Collapsed;
        Children.Add(Sans(label, 13, Sub, Medium).Frame(height: 18));
        Children.Add(Layer(Box, _accent));
        Children.Add(_error);
    }

    public string Text { get => Box.Text; set => Box.Text = value; }

    public string? Error
    {
        get => _error.Visibility == Visibility.Visible ? _error.Text : null;
        set { _error.Text = value ?? ""; _error.Visibility = value is null ? Visibility.Collapsed : Visibility.Visible; Paint(Box.FocusState != FocusState.Unfocused); }
    }

    void Paint(bool focused)
    {
        var error = Error is not null;
        Box.BorderBrush = Brush(error ? Red : Cl);
        _accent.Background = Brush(error ? Red : focused ? Txt : Fnt2);
        _accent.Height = focused && !error ? 2 : 1;
    }
}

/// <summary>
/// 页头：眉题 12/500 #6C6C65（18 高）、标题 24/600（32 高，距眉题 6）、13px 副标题（距标题 4）、右侧按钮与标题底对齐、间距 8。
/// </summary>
public static class V3PageHead
{
    public static Grid Make(IEnumerable<string> eyebrow, string title, string? subtitle = null, bool compact = false, double? subtitleHeight = null, params UIElement[] actions)
    {
        var words = eyebrow.ToArray();
        var labels = VStack(0,
            words.Length == 0 ? null : Sans(string.Join(" · ", words), 12, Fnt, Medium).Frame(height: 18),
            Label(title, 24, Txt, Semibold).Frame(height: 32).Top(words.Length == 0 ? 0 : 6),
            subtitle is null ? null : Sans(subtitle, 13, Sub).Frame(height: subtitleHeight ?? 20).Top(4));
        var buttons = HStack(8, actions);
        buttons.VerticalAlignment = VerticalAlignment.Bottom;
        return Spread(labels, buttons, 24, VerticalAlignment.Bottom);
    }
}

/// <summary>
/// Windows 稿 InfoBar（替代 Mac 第 16 页顶部提示栏）：圆角 4，四种 Severity 用 v3 浅色底 + 同色 1px 边与图标；
/// 标题 13/500 与说明 13 #55554F 同一行；可关闭时右侧 32×32 ×，常驻错误不可关闭；可带一个文字操作。
/// </summary>
public static class V3InfoBar
{
    public enum Severity { Info, Success, Warning, Error }

    public static Border Make(Severity severity, string title, string? message = null, Action? close = null, (string label, Action action)? action = null)
    {
        var (fg, bg, icon) = severity switch
        {
            Severity.Success => (Green, GreenSoft, "checkmark.circle"),
            Severity.Warning => (Orange, OrangeSoft, "exclamationmark.triangle"),
            Severity.Error => (Red, RedSoft, "exclamationmark.circle"),
            _ => (Blue, BlueSoft, "info.circle"),
        };
        var text = new TextBlock { FontFamily = SansFamily, FontSize = 13, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        text.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = title, FontWeight = Medium, Foreground = Brush(Txt) });
        if (!string.IsNullOrEmpty(message)) text.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = "  " + message, Foreground = Brush(Sub) });
        var grid = new Grid { ColumnSpacing = 12, MinHeight = 46 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(Icon(icon, 16, fg).Align(v: VerticalAlignment.Center));
        Grid.SetColumn(text, 1);
        grid.Children.Add(text.Pad(0, 12, 0, 12));
        if (action is { } a)
        {
            var link = new V3Button(a.label, a.action, V3Button.Kind.Text, height: 28);
            link.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(link, 2);
            grid.Children.Add(link);
        }
        if (close is not null)
        {
            var x = new V3IconButton("xmark", "关闭提示", close, 32, 12);
            x.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(x, 3);
            grid.Children.Add(x);
        }
        return new Border
        {
            Child = grid, Padding = new Thickness(16, 0, close is null ? 16 : 8, 0), CornerRadius = new CornerRadius(4),
            Background = Brush(bg), BorderBrush = Brush(fg), BorderThickness = new Thickness(1),
        };
    }
}

/// <summary>
/// 品牌山茶花五片花瓣依次绽放、停留后收拢，3 秒一轮（Web `ThinkingMark` 同一动画）；系统关闭动画时静止显示完整花朵。
/// </summary>
public sealed class V3ThinkingMark : Grid
{
    readonly List<(Image image, CompositeTransform transform)> _petals = [];
    DispatcherTimerLike? _timer;

    public V3ThinkingMark(double size = 40)
    {
        Width = size;
        Height = size;
        IsHitTestVisible = false;
        for (var i = 1; i <= 5; i++)
        {
            var transform = new CompositeTransform { CenterX = size * 0.5, CenterY = size * 0.547 };
            var image = new Image { Source = new BitmapImage(new Uri($"ms-appx:///Assets/Library/loading-petal-{i}.png")), Width = size, Height = size, RenderTransform = transform };
            _petals.Add((image, transform));
            Children.Add(image);
        }
        Loaded += (_, _) =>
        {
            if (!new Windows.UI.ViewManagement.UISettings().AnimationsEnabled) return;
            var start = DateTime.UtcNow;
            _timer = new DispatcherTimerLike(DispatcherQueue, TimeSpan.FromMilliseconds(33), () =>
            {
                var time = (DateTime.UtcNow - start).TotalSeconds;
                for (var i = 0; i < _petals.Count; i++)
                {
                    var (scale, angle) = Pose(time - i * 0.15);
                    _petals[i].transform.ScaleX = scale;
                    _petals[i].transform.ScaleY = scale;
                    _petals[i].transform.Rotation = angle;
                }
            });
        };
        Unloaded += (_, _) => { _timer?.Stop(); _timer = null; };
    }

    /// <summary>Web `assistant-thinking-petal` 关键帧：0% 缩 0 转 -30° → 20% 放大 1.05 转 3° → 28%–72% 停住 → 94% 收回。</summary>
    static (double scale, double angle) Pose(double time)
    {
        var p = ((time % 3) + 3) % 3 / 3;
        static double Ease(double x) { var t = Math.Clamp(x, 0, 1); return t * t * (3 - 2 * t); }
        if (p < 0.2) { var t = Ease(p / 0.2); return (1.05 * t, -30 + 33 * t); }
        if (p < 0.28) { var t = Ease((p - 0.2) / 0.08); return (1.05 - 0.05 * t, 3 - 3 * t); }
        if (p < 0.72) return (1, 0);
        if (p < 0.94) { var t = Ease((p - 0.72) / 0.22); return (1 - t, -30 * t); }
        return (0, -30);
    }
}

/// <summary>DispatcherQueueTimer 的薄包装：构造即开始，Stop 后释放。</summary>
public sealed class DispatcherTimerLike
{
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _timer;

    public DispatcherTimerLike(Microsoft.UI.Dispatching.DispatcherQueue queue, TimeSpan interval, Action tick, bool repeat = true)
    {
        _timer = queue.CreateTimer();
        _timer.Interval = interval;
        _timer.IsRepeating = repeat;
        _timer.Tick += (_, _) => tick();
        _timer.Start();
    }

    public void Stop() => _timer.Stop();
}

/// <summary>
/// 统一加载（稿 15 页 · 04「二级页面统一加载」）：内容区正中一朵山茶花 + 一行 12.5 灰字；180ms 内返回不出现；
/// 超过 8 秒补一行「比平时慢一些，还在加载。」，有重试动作时附蓝色「重新加载」。
/// </summary>
public sealed class V3Loading : StackPanel
{
    public V3Loading(string label, Action? retry = null)
    {
        Spacing = 8;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Center;
        Opacity = 0;
        Children.Add(new V3ThinkingMark(40).Align(HorizontalAlignment.Center));
        Children.Add(Sans(label, 12.5, Faint).Align(HorizontalAlignment.Center));
        var slow = HStack(6, Sans("比平时慢一些，还在加载。", 12.5, Fnt), retry is null ? null : TextLink("重新加载", retry, 12.5));
        slow.HorizontalAlignment = HorizontalAlignment.Center;
        slow.Visibility = Visibility.Collapsed;
        Children.Add(slow.Top(4));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, label);
        DispatcherTimerLike? show = null, late = null;
        Loaded += (_, _) =>
        {
            show = new DispatcherTimerLike(DispatcherQueue, TimeSpan.FromMilliseconds(180), () => { Opacity = 1; show?.Stop(); }, false);
            late = new DispatcherTimerLike(DispatcherQueue, TimeSpan.FromSeconds(8), () => { slow.Visibility = Visibility.Visible; late?.Stop(); }, false);
        };
        Unloaded += (_, _) => { show?.Stop(); late?.Stop(); };
    }

    /// <summary>蓝色文字链（「重新加载」等），悬停手形光标。</summary>
    public static TextBlock TextLink(string label, Action action, double size = 13) =>
        Sans(label, size, Blue, Medium).OnTap(action, label);
}

/// <summary>加载失败（稿 15 页 01 · D）：一行灰字 + 蓝色「重新加载」，不弹窗、不放插图。</summary>
public static class V3LoadFailed
{
    public static StackPanel Make(Action retry, string message = "没有加载出来。") =>
        HStack(6, Sans(message, 13, Fnt), V3Loading.TextLink("重新加载", retry)).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
}

/// <summary>骨架占位块（Web `.v3-sk`）：#ECECEA 底、圆角 4；150ms 后淡入，快的请求不闪骨架。</summary>
public static class V3Skeleton
{
    public static Border Make(double? width = null, double height = 12, double radius = 4, Color? color = null)
    {
        var block = new Border { Height = height, CornerRadius = new CornerRadius(radius), Background = Brush(color ?? Line), Opacity = 0, IsHitTestVisible = false };
        if (width is { } w) block.Width = w;
        DispatcherTimerLike? timer = null;
        block.Loaded += (_, _) => timer = new DispatcherTimerLike(block.DispatcherQueue, TimeSpan.FromMilliseconds(150), () => { block.Opacity = 1; timer?.Stop(); }, false);
        block.Unloaded += (_, _) => timer?.Stop();
        return block;
    }
}

/// <summary>Windows 稿 ToggleSwitch：40×20 胶囊，开为墨黑底、关为 #C9C9C3 底，12 白圆钮；禁用 .38。</summary>
public sealed class V3Switch : Border
{
    readonly Border _knob = new() { Width = 12, Height = 12, CornerRadius = new CornerRadius(6), Background = Brush(V3.White), VerticalAlignment = VerticalAlignment.Center };
    bool _on;
    public event Action<bool>? Toggled;

    public V3Switch(bool on, string label)
    {
        Width = 40; Height = 20; CornerRadius = new CornerRadius(10);
        Child = _knob;
        _on = on;
        Paint();
        this.OnTap(() => { if (!Enabled) return; _on = !_on; Paint(); Toggled?.Invoke(_on); }, label);
    }

    public bool IsOn { get => _on; set { _on = value; Paint(); } }

    bool _enabled = true;
    public bool Enabled { get => _enabled; set { _enabled = value; Opacity = value ? 1 : 0.38; } }

    void Paint()
    {
        Background = Brush(_on ? Txt : Hex(0xC9C9C3));
        _knob.HorizontalAlignment = _on ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        _knob.Margin = new Thickness(4, 0, 4, 0);
    }
}
