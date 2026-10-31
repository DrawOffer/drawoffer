using System.Text.Json.Nodes;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.DesignSystem;

/// <summary>
/// 模型选择，对应 Mac `ModelPicker.swift`（Web `assistant/ModelPicker.tsx`）：触发按钮（厂商图标 + 名称 + ⌄）与 248 宽的“选择模型”弹层，
/// 悬停一行在左侧显示介绍、能力 / 速度档位与平均每轮积分；额度不可用的模型仍能悬停查看但不能选。
/// </summary>
public sealed class ModelPicker : BorderControl
{
    readonly IReadOnlyList<JsonNode> _models;
    readonly string? _selectedId;
    readonly bool _disabled;
    readonly Action<string> _select;
    Flyout? _flyout;
    readonly Popup _hoverPopup = new() { IsHitTestVisible = false };

    /// <param name="inline">首页地平线提示行里的样式：10px、跟随提示行颜色、不显示 ⌄。</param>
    public ModelPicker(IReadOnlyList<JsonNode> models, string? selectedId, Action<string> select, bool loading = false, bool disabled = false, bool inline = false, bool compact = false)
    {
        _models = models;
        _selectedId = selectedId;
        _disabled = disabled;
        _select = select;
        var selected = models.FirstOrDefault(m => m.Text("id") == selectedId);
        var label = selected?.Text("name") is { Length: > 0 } name ? name : "选择模型";
        var size = inline ? 10 : compact ? 11 : 12.5;
        var color = inline ? Hex(0x9B978C) : compact ? Fnt : Hex(0x33332F);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = inline ? 4 : 5, VerticalAlignment = VerticalAlignment.Center };
        if (selected is not null)
        {
            var icon = ModelIcon.Make(selected.Text("name"), inline ? 10 : compact ? 13 : 15);
            // `.saturation(0).opacity(0.7)`：WinUI 没有去色滤镜，内联时用半透明近似
            if (inline) icon.Opacity = 0.7;
            row.Children.Add(icon);
        }
        var text = Label(loading ? "正在读取模型" : label, size, color, compact ? Medium : Regular);
        text.MaxWidth = 240;
        row.Children.Add(text.Align(v: VerticalAlignment.Center));
        if (!compact && !inline) row.Children.Add(Icon("chevron.down", 9, Sub).Align(v: VerticalAlignment.Center));
        Child = row;
        Background = Brush(Clear);
        if (selected?.Text("name") is { Length: > 0 } tip) ToolTipService.SetToolTip(this, tip);
        AutomationProperties.SetName(this, label);
        this.OnTap(Open, enabled: () => !loading);
    }

    void Open()
    {
        var panel = new StackPanel { Width = 248 - 14 };
        panel.Children.Add(Label("选择模型", 12, Hex(0x474D56)).Frame(height: 34 - 4).Align(v: VerticalAlignment.Bottom).Pad(10, 0, 10, 4));
        if (_models.Count == 0)
            panel.Children.Add(Label("当前没有可用模型", 12, Fnt).Pad(10, 8, 10, 8));
        else
        {
            var list = new StackPanel { Spacing = 4, Padding = new Thickness(0, 2, 0, 2) };
            foreach (var model in _models) list.Children.Add(Row(model));
            panel.Children.Add(new ScrollViewer { Content = list, MaxHeight = 200, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        }
        panel.PointerExited += (_, _) => _hoverPopup.IsOpen = false;
        AutomationProperties.SetName(panel, "选择模型");
        _flyout = V3Popover.Show(this, panel, Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Top, padding: 7);
        _flyout.Closed += (_, _) => _hoverPopup.IsOpen = false;
    }

    FrameworkElement Row(JsonNode model)
    {
        var id = model.Text("id");
        var active = id == _selectedId;
        var unavailable = model.Get("available") is JsonValue v && v.GetValueKind() == System.Text.Json.JsonValueKind.False;
        var grid = new Grid { ColumnSpacing = 8, Height = 36, Padding = new Thickness(10, 0, 8, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(ModelIcon.Make(model.Text("name"), 18).Align(v: VerticalAlignment.Center));
        var name = Label(model.Text("name"), 12, Hex(0x25292F)).Align(v: VerticalAlignment.Center);
        Grid.SetColumn(name, 1);
        grid.Children.Add(name);
        if (unavailable) { var note = Label("当前额度不可用", 11, Sub).Align(v: VerticalAlignment.Center); Grid.SetColumn(note, 2); grid.Children.Add(note); }
        if (active) { var mark = Icon("checkmark", 10, Txt).Align(v: VerticalAlignment.Center); Grid.SetColumn(mark, 3); grid.Children.Add(mark); }
        var row = new Border { Child = grid, CornerRadius = new CornerRadius(7), Background = Brush(active ? Hex(0xF4F5F7) : Clear), Opacity = unavailable ? 0.5 : 1 };
        row.OnHover(on =>
        {
            row.Background = Brush(active || on ? Hex(0xF4F5F7) : Clear);
            if (on) ShowHover(model, row);
        });
        row.OnTap(() =>
        {
            if (unavailable) return;
            _flyout?.Hide();
            _select(id);
        }, model.Text("name"), () => !_disabled);
        if (active) AutomationProperties.SetItemStatus(row, "已选择");
        return row;
    }

    /// <summary>悬停卡放在弹层左侧 15px（Mac `.offset(x: -248 - 15)`），与弹层顶边对齐。</summary>
    void ShowHover(JsonNode model, FrameworkElement row)
    {
        if (row.XamlRoot is null || _flyout is null) return;
        var card = ModelHoverCard.Make(model);
        _hoverPopup.XamlRoot = row.XamlRoot;
        _hoverPopup.Child = card;
        var menu = FindPresenter(row) ?? row;
        var origin = menu.TransformToVisual(null).TransformPoint(new Point(0, 0));
        _hoverPopup.HorizontalOffset = origin.X - 248 - 15;
        _hoverPopup.VerticalOffset = origin.Y;
        _hoverPopup.IsOpen = true;
    }

    static FrameworkElement? FindPresenter(DependencyObject node)
    {
        for (var current = VisualTreeHelper.GetParent(node); current is not null; current = VisualTreeHelper.GetParent(current))
            if (current is FlyoutPresenter presenter) return presenter;
        return null;
    }
}

/// <summary>悬停卡（Figma 25.1）：名称与状态、介绍、能力 / 速度细条、平均每轮积分。</summary>
public static class ModelHoverCard
{
    static readonly string[] Abilities = ["一般", "够用", "较强", "很强", "最强"];
    static readonly string[] Speeds = ["很慢", "较慢", "中等", "较快", "很快"];

    public static FrameworkElement Make(JsonNode model)
    {
        var turn = model.Get("turn") as JsonObject;
        var available = model.Get("available") is not JsonValue a || a.GetValueKind() != System.Text.Json.JsonValueKind.False;
        var status = model.Bool("isFreeTier") ? "free" : !available ? "locked" : "member";
        var stack = new StackPanel();
        var head = new Grid { ColumnSpacing = 8 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(ModelIcon.Make(model.Text("name"), 16).Align(v: VerticalAlignment.Center));
        var name = Label(model.Text("name"), 13, Hex(0x1F2329), Medium).Align(v: VerticalAlignment.Center);
        Grid.SetColumn(name, 1);
        head.Children.Add(name);
        // 对话不扣积分时人人都能用，不标会员
        if (turn.Text("basis") != "free")
        {
            var badge = Label(status switch { "free" => "免费可用", "member" => "会员", _ => "需开通会员" }, 11,
                status == "free" ? Hex(0x3F6FD8) : status == "locked" ? Hex(0xC2410C) : Hex(0xA0A6AE)).Align(v: VerticalAlignment.Center);
            Grid.SetColumn(badge, 2);
            head.Children.Add(badge);
        }
        stack.Children.Add(head);
        var intro = model.Text("chatIntro").Trim();
        if (intro.Length > 0) stack.Children.Add(Label(intro, 12, Hex(0x6B7280)).Wrap().LineHeight(12 + 2 + 4).Top(4));
        var ability = (int)(model.Number("abilityLevel") ?? 0);
        var speed = (int)(model.Number("speedLevel") ?? 0);
        if (ability > 0 || speed > 0)
        {
            var levels = new StackPanel { Spacing = 8 };
            if (ability > 0) levels.Children.Add(Level("能力", ability, Abilities));
            if (speed > 0) levels.Children.Add(Level("速度", speed, Speeds));
            stack.Children.Add(levels.Top(12));
        }
        if (turn is not null)
        {
            var line = new Grid { ColumnSpacing = 4 };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.Children.Add(Label("平均每轮", 12, Hex(0x6B7280)).Align(v: VerticalAlignment.Bottom));
            var points = TurnPoints(turn.Get("points").String());
            UIElement value = turn.Text("basis") == "free" ? Label("不扣积分", 13, Hex(0x1F2329), Medium)
                : points is not null ? Label(turn.Text("basis") == "fixed" ? points : $"约 {points}", 13, Hex(0x1F2329), Medium)
                : Label("按实际用量", 12, Hex(0x6B7280));
            Grid.SetColumn((FrameworkElement)value, 1);
            line.Children.Add(value);
            if (turn.Text("basis") != "free" && points is not null)
            {
                var unit = Label("积分", 11, Hex(0xA0A6AE)).Align(v: VerticalAlignment.Bottom);
                Grid.SetColumn(unit, 2);
                line.Children.Add(unit);
            }
            stack.Children.Add(line.Top(12));
        }
        return new Border
        {
            Child = stack, Width = 248, Padding = new Thickness(16, 14, 16, 14),
            Background = Brush(V3.White), CornerRadius = new CornerRadius(12),
            BorderBrush = Brush(Hex(0xE6E8EB)), BorderThickness = new Thickness(1),
        }.Elevate(10);
    }

    static Grid Level(string label, int value, string[] names)
    {
        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        row.Children.Add(Label(label, 12, Hex(0x6B7280)));
        // 渐变铺满整条轨道，档位只决定露出多少
        var gradient = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 0), MappingMode = BrushMappingMode.RelativeToBoundingBox };
        foreach (var (color, offset) in new (Color, double)[] { (Hex(0xB9C47A), 0), (Hex(0xE0B45A), 0.41667), (Hex(0xD9824A), 0.83333), (Hex(0xB8513F), 1) })
            gradient.GradientStops.Add(new GradientStop { Color = color, Offset = offset });
        var track = new Grid { Width = 120, Height = 4, CornerRadius = new CornerRadius(2), Background = Brush(Hex(0xEEF0F3)), VerticalAlignment = VerticalAlignment.Center };
        // 渐变按整条轨道铺，再用裁剪只露出前一段
        var fill = new Border { Width = 120, Height = 4, CornerRadius = new CornerRadius(2), Background = gradient, HorizontalAlignment = HorizontalAlignment.Left };
        fill.Clip = new RectangleGeometry { Rect = new Rect(0, 0, 120 * Math.Min(5, value) / 5.0, 4) };
        track.Children.Add(fill);
        Grid.SetColumn(track, 1);
        row.Children.Add(track);
        var name = Label(names[Math.Clamp(value, 1, 5) - 1], 11, Hex(0xA0A6AE)).Align(HorizontalAlignment.Right);
        Grid.SetColumn(name, 2);
        row.Children.Add(name);
        return row;
    }

    /// <summary>「约 1.4」：不到 10 保留一位小数，10 以上取整；没有价格时为 null。</summary>
    public static string? TurnPoints(string? raw)
    {
        if (raw is null || !double.TryParse(raw, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var value) || !double.IsFinite(value)) return null;
        if (value >= 10) return ((long)Math.Round(value, MidpointRounding.AwayFromZero)).ToString(System.Globalization.CultureInfo.InvariantCulture);
        var one = Math.Round(value * 10, MidpointRounding.AwayFromZero) / 10;
        return one == Math.Round(one) ? ((long)one).ToString(System.Globalization.CultureInfo.InvariantCulture) : one.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);
    }
}

/// <summary>厂商图标：按模型名认出厂商（与 Web `modelVendor` 同规则），认不出时用 spark。</summary>
public static class ModelIcon
{
    public static string? Vendor(string name)
    {
        var value = name.ToLowerInvariant();
        if (System.Text.RegularExpressions.Regex.IsMatch(value, "gpt|(^|[^a-z])o[1-9]|openai")) return "openai";
        foreach (var (key, words) in new (string, string[])[] { ("claude", ["claude"]), ("gemini", ["gemini"]), ("deepseek", ["deepseek"]), ("kimi", ["kimi", "moonshot"]), ("grok", ["grok"]) })
            if (words.Any(value.Contains)) return key;
        return null;
    }

    public static FrameworkElement Make(string name, double size = 18)
    {
        if (Vendor(name) is { } vendor)
            return new Image { Source = new SvgImageSource(new Uri($"ms-appx:///Assets/Models/{vendor}.svg")) { RasterizePixelWidth = size * 2, RasterizePixelHeight = size * 2 }, Width = size, Height = size };
        return Icon("sparkle", size * 0.8, Sub).Frame(size, size);
    }
}
