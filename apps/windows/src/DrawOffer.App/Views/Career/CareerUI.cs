using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>04.C01 palette，对应 Mac `CareerUI.swift` 的 `CareerPalette`：取自 Web `--v3-*` Token 与 ap-/sd-/rp- 页面变量。</summary>
public static class CareerPalette
{
    public static readonly Color Text = Hex(0x1D1D1B);
    public static readonly Color Sub = Hex(0x55554F);
    public static readonly Color Faint = Hex(0x96968F);
    public static readonly Color Hint = Hex(0x8C8C85);
    public static readonly Color Line = Hex(0xECECEA);
    public static readonly Color Border = Hex(0xE6E6E2);
    public static readonly Color Control = Hex(0xE4E4E0);
    public static readonly Color Field = Hex(0xF4F4F2);
    public static readonly Color Soft = Hex(0xFAFAF9);
    public static readonly Color PipelineLine = Hex(0xEDEDE9);
    public static readonly Color Dashed = Hex(0xB3B3AD);
    public static readonly Color Rail = Hex(0xE3E3DE);
    public static readonly Color ChipGray = Hex(0xF0F0EC);
    public static readonly Color Blue = Hex(0x3F6FD8);
    public static readonly Color BlueSoft = Hex(0xEBF0FB);
    public static readonly Color Green = Hex(0x359564);
    public static readonly Color GreenSoft = Hex(0xEAF5EF);
    public static readonly Color Orange = Hex(0xA96B27);
    public static readonly Color OrangeSoft = Hex(0xFBF2E6);
    public static readonly Color Red = Hex(0xD64545);
    public static readonly Color RedSoft = Hex(0xFBECEC);

    public static Color Foreground(CareerTone tone) => tone switch
    {
        CareerTone.Blue => Blue, CareerTone.Green => Green, CareerTone.Orange => Orange, CareerTone.Red => Red,
        CareerTone.Gray => Sub, _ => V3.White,
    };

    public static Color Background(CareerTone tone) => tone switch
    {
        CareerTone.Blue => BlueSoft, CareerTone.Green => GreenSoft, CareerTone.Orange => OrangeSoft, CareerTone.Red => RedSoft,
        CareerTone.Gray => ChipGray, _ => Text,
    };

    /// <summary>圆点、强调色与进度条用的实色。</summary>
    public static Color Solid(CareerTone tone) => tone switch
    {
        CareerTone.Blue => Blue, CareerTone.Green => Green, CareerTone.Orange => Orange, CareerTone.Red => Red,
        CareerTone.Gray => Faint, _ => Text,
    };
}

/// <summary>Mac `CareerChipView`：11px 中粗、左右 8、22 高、圆角 6 的色块标签。</summary>
public static class CareerChipView
{
    public static Border Make(CareerChip chip) => new()
    {
        Child = Sans(chip.Label, 11, CareerPalette.Foreground(chip.Tone), Medium).Align(v: VerticalAlignment.Center),
        Padding = new Thickness(8, 0, 8, 0), Height = 22, CornerRadius = new CornerRadius(6),
        Background = Brush(CareerPalette.Background(chip.Tone)), HorizontalAlignment = HorizontalAlignment.Left,
    };

    public static Border Make(string label, CareerTone tone) => Make(new CareerChip(label, tone));
}

/// <summary>
/// `.ap-outline-button` / `.ap-primary-button` / `.ap-text-button` / 链接按钮，对应 Mac `CareerActionStyle`。
/// 字号 12（large 13），muted 为常规字重其余中粗；outline / primary 左右 10（large 14）、30 高（large 34）、圆角 8；
/// text / danger 左右 10、30 高；禁用时不透明度 0.6（primary 改灰底 #9E9E99）。
/// </summary>
public sealed class CareerAction : BorderControl
{
    public enum Kind { Outline, Primary, Text, Danger, Link, Muted }

    readonly Kind _kind;
    readonly bool _large;
    readonly StackPanel _row = new() { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
    readonly TextBlock _label;
    bool _pressed, _enabled = true;

    public CareerAction(string title, Action action, Kind kind = Kind.Outline, bool large = false, string? icon = null)
    {
        _kind = kind;
        _large = large;
        var size = large ? 13 : 12;
        if (icon is not null) _row.Children.Add(Icon(icon, size - 1));
        _label = Sans(title, size, CareerPalette.Text, kind == Kind.Muted ? Regular : Medium);
        _row.Children.Add(_label);
        Child = _row;
        HorizontalAlignment = HorizontalAlignment.Left;
        VerticalAlignment = VerticalAlignment.Center;
        if (kind is Kind.Outline or Kind.Primary) { Padding = new Thickness(large ? 14 : 10, 0, large ? 14 : 10, 0); Height = large ? 34 : 30; CornerRadius = new CornerRadius(8); }
        else if (kind is Kind.Text or Kind.Danger) { Padding = new Thickness(10, 0, 10, 0); Height = 30; CornerRadius = new CornerRadius(8); }
        BorderThickness = new Thickness(kind == Kind.Outline ? 1 : 0);
        BorderBrush = Brush(CareerPalette.Border);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, title);
        PointerPressed += (_, e) => { if (_enabled) { _pressed = true; Paint(); e.Handled = true; } };
        PointerReleased += (_, e) => { if (_pressed && _enabled) { _pressed = false; Paint(); e.Handled = true; action(); } };
        PointerExited += (_, _) => { _pressed = false; Paint(); };
        PointerCanceled += (_, _) => { _pressed = false; Paint(); };
        IsTabStop = true;
        KeyDown += (_, e) => { if (_enabled && e.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space) { e.Handled = true; action(); } };
        Paint();
    }

    public bool Enabled { get => _enabled; set { _enabled = value; Paint(); } }
    public string Title { get => _label.Text; set => _label.Text = value; }

    void Paint()
    {
        var ink = _kind switch
        {
            Kind.Primary => V3.White,
            Kind.Danger => CareerPalette.Red,
            Kind.Text => CareerPalette.Sub,
            Kind.Link => CareerPalette.Blue,
            Kind.Muted => _pressed ? CareerPalette.Text : CareerPalette.Faint,
            _ => CareerPalette.Text,
        };
        foreach (var child in _row.Children)
        {
            if (child is TextBlock text) text.Foreground = Brush(ink);
            if (child is FontIcon glyph) glyph.Foreground = Brush(ink);
        }
        Background = Brush(_kind switch
        {
            Kind.Outline => _pressed ? CareerPalette.Field : V3.White,
            Kind.Primary => _enabled ? (_pressed ? Microsoft.UI.Colors.Black : CareerPalette.Text) : Hex(0x9E9E99),
            Kind.Text or Kind.Danger => _pressed ? CareerPalette.Field : Clear,
            _ => Clear,
        });
        Opacity = _enabled || _kind == Kind.Primary ? 1 : 0.6;
        ProtectedCursor = Microsoft.UI.Input.InputSystemCursor.Create(_enabled ? Microsoft.UI.Input.InputSystemCursorShape.Hand : Microsoft.UI.Input.InputSystemCursorShape.Arrow);
    }
}

public static class CareerCardExtensions
{
    /// <summary>`.ap-side-card` / `.sd-card`（Mac `careerCard`）：白底细边卡片，默认内边距 18、圆角 14、#E6E6E2 边。</summary>
    public static Border CareerCard(this UIElement content, double padding = 18, double radius = 14, Color? border = null, double lineWidth = 1) => new()
    {
        Child = content, Padding = new Thickness(padding), CornerRadius = new CornerRadius(radius), Background = Brush(V3.White),
        BorderBrush = Brush(border ?? CareerPalette.Border), BorderThickness = new Thickness(lineWidth), HorizontalAlignment = HorizontalAlignment.Stretch,
    };
}

/// <summary>`.ap-file-badge`（Mac `CareerFileBadge`）：关联文件的扩展名标签，默认 30×30、圆角 7 描边、8px 中粗。</summary>
public static class CareerFileBadge
{
    public static string Badge(string name)
    {
        var parts = name.Split('.', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length > 1 ? new string(parts[^1].Take(4).ToArray()).ToUpperInvariant() : "DOC";
    }

    public static Border Make(string name, double size = 30) => new()
    {
        Width = size, Height = size, CornerRadius = new CornerRadius(7), BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1),
        Child = Sans(Badge(name), 8, CareerPalette.Sub, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
    };
}

/// <summary>进度、阶段详情与复盘报告页的面包屑（Mac `CareerBreadcrumb`）：12px，返回项为 muted 按钮，“/” 与当前项为 #96968F。</summary>
public static class CareerBreadcrumb
{
    public static StackPanel Make(string back, string current, Action action)
    {
        var button = new CareerAction(back, action, CareerAction.Kind.Muted);
        return HStack(8, button, Sans("/", 12, CareerPalette.Faint), Sans(current, 12, CareerPalette.Faint));
    }
}

/// <summary>侧栏卡片里的名称 / 值行（`.ap-side-card dl`，Mac `CareerInfoRows`）：行距 8、列距 12、12px。</summary>
public static class CareerInfoRows
{
    public static StackPanel Make(IEnumerable<CareerInfoRow> rows)
    {
        var stack = new StackPanel { Spacing = 8 };
        foreach (var row in rows)
            stack.Children.Add(Spread(Sans(row.Label, 12, CareerPalette.Faint).Also(t => t.TextTrimming = TextTrimming.None),
                Sans(row.Value, 12, row.Tone is { } tone ? CareerPalette.Solid(tone) : CareerPalette.Text), 12, VerticalAlignment.Top));
        return stack;
    }
}

/// <summary>
/// 阶段弹窗共用外壳（`.sd-dialog`，Mac `CareerSheet`）：20px 衬线标题、12.5px 副标题（间距 4，上 28、左右 32、下 16），
/// 可滚动正文（间距 16、左右 32、下 8），顶线分隔的页脚（上 8 处分隔线，按钮右对齐间距 10，左右 32、上下 18）。
/// </summary>
public static class CareerSheet
{
    public static Border Make(string title, double width, IEnumerable<UIElement> content, IEnumerable<UIElement> footer, string subtitle = "")
    {
        var head = VStack(4, Serif(title, 20), subtitle.Length == 0 ? null : Sans(subtitle, 12.5, CareerPalette.Sub));
        head.Padding = new Thickness(32, 28, 32, 16);
        var body = new StackPanel { Spacing = 16, Padding = new Thickness(32, 0, 32, 8) };
        foreach (var child in content) body.Children.Add(child);
        var foot = HStack(10, footer.ToArray());
        foot.HorizontalAlignment = HorizontalAlignment.Right;
        foot.Margin = new Thickness(32, 18, 32, 18);
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
        grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
        grid.Children.Add(head);
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroll, 1); grid.Children.Add(scroll);
        var line = Divider(CareerPalette.Line).Top(8);
        Grid.SetRow(line, 2); grid.Children.Add(line);
        Grid.SetRow(foot, 3); grid.Children.Add(foot);
        return V3Dialog.Frame(grid, width);
    }
}

/// <summary>`.sd-field` 多行输入（Mac `CareerTextArea`）：12px 标题（间距 8），白底圆角 8、#E4E4E0 边，13px 正文，默认最小高 96。</summary>
public sealed class CareerTextArea : StackPanel
{
    public TextBox Box { get; }

    public CareerTextArea(string title, string text = "", string placeholder = "", double minHeight = 96)
    {
        Spacing = 8;
        if (title.Length > 0) Children.Add(Sans(title, 12, CareerPalette.Sub));
        Box = new TextBox
        {
            Text = text, PlaceholderText = placeholder, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontSize = 13, FontFamily = SansFamily,
            MinHeight = minHeight, Padding = new Thickness(12, 10, 12, 10), CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1),
            BorderBrush = Brush(CareerPalette.Control), Background = Brush(V3.White), Foreground = Brush(CareerPalette.Text), PlaceholderForeground = Brush(CareerPalette.Faint),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(Box, title.Length == 0 ? placeholder : title);
        Children.Add(Box);
    }

    public string Text { get => Box.Text; set => Box.Text = value; }
}

/// <summary>Mac `CareerErrors.message`：把接口错误换成求职页面统一的中文提示。</summary>
public static class CareerErrors
{
    public static string Message(Exception error)
    {
        if (error is OperationCanceledException) return "操作已取消。";
        if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) return "登录已失效，请重新登录。";
        if (error is ApiException api)
        {
            if (CareerTranscript.ImportError(api.Code) is { } text) return text;
            if (api.Code == "LLM_MODEL_NOT_CONFIGURED") return "请先配置模拟面试的 AI 模型，再生成复盘。";
            var status = (int)api.Status;
            if (status == 409) return "内容已在其他地方更新，请刷新后重试。";
            if (status == 403) return "当前服务尚未开放桌面端的这项操作，请更新服务端后重试。";
            if (status == 404) return "记录不存在或已被删除。";
            return $"操作失败（{api.Code}），请稍后重试。";
        }
        return "连接失败，请检查网络后重试。";
    }
}
