using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.Text;

namespace DrawOffer.App.DesignSystem;

/// <summary>
/// Web `v3/v3.css` 的页面 Token 与基础排版工具，逐项对应 Mac `DesignSystem/V3.swift` 的 `enum V3`。
/// 界面全部用 C# 构建（不写 .xaml），名字、颜色和尺寸与 Swift 版一致，方便逐文件对照。
/// </summary>
public static class V3
{
    public static readonly Color Txt = Hex(0x1D1D1B);
    public static readonly Color Sub = Hex(0x55554F);
    public static readonly Color Fnt = Hex(0x6C6C65);
    public static readonly Color Fnt2 = Hex(0xC4C4BE);
    public static readonly Color Line = Hex(0xECECEA);
    public static readonly Color Cl = Hex(0xE4E4E0);
    public static readonly Color Field = Hex(0xF4F4F2);
    public static readonly Color Hl = Hex(0xE6E6E2);
    public static readonly Color Stage = Hex(0xF4F4F1);
    public static readonly Color Column = Hex(0xF7F7F5);
    public static readonly Color Sk2 = Hex(0xDCDCD8);
    public static readonly Color Blue = Hex(0x3F6FD8);
    public static readonly Color Link = Hex(0x2E53AA);
    public static readonly Color BlueSoft = Hex(0xEAF0FB);
    public static readonly Color Orange = Hex(0xD9822B);
    public static readonly Color OrangeSoft = Hex(0xFBF1E6);
    public static readonly Color Green = Hex(0x3B9A5B);
    public static readonly Color GreenSoft = Hex(0xEEF6F0);
    public static readonly Color Red = Hex(0xD64545);
    public static readonly Color RedSoft = Hex(0xFBF2F2);
    public static readonly Color Purple = Hex(0x8A5CC7);
    public static readonly Color PurpleSoft = Hex(0xF3EEFA);
    public static readonly Color White = Colors.White;
    public static readonly Color Clear = Colors.Transparent;

    /// <summary>字体文件内登记的家族名是旧品牌名 `LinkResume Library …`，必须按文件里的名字引用才能加载。</summary>
    public static readonly FontFamily SansFamily = new("ms-appx:///Assets/Library/LibrarySans-Regular.otf#LinkResume Library Sans");
    public static readonly FontFamily SerifFamily = new("ms-appx:///Assets/Library/LibrarySerif-SemiBold.ttf#LinkResume Library Serif");
    public static readonly FontFamily IconFamily = new("Segoe Fluent Icons,Segoe MDL2 Assets");

    public static Color Hex(uint hex) => Color.FromArgb(255, (byte)(hex >> 16), (byte)(hex >> 8), (byte)hex);
    public static Color Alpha(Color color, double opacity) => Color.FromArgb((byte)Math.Round(opacity * 255), color.R, color.G, color.B);
    public static SolidColorBrush Brush(Color color) => new(color);
    public static SolidColorBrush Brush(uint hex) => new(Hex(hex));

    /// <summary>CSS `color-mix(in srgb, a (1 - t), b t)`，对应 Swift `Color.mix(with:by:)`。</summary>
    public static Color Mix(Color a, Color b, double t)
    {
        t = Math.Clamp(t, 0, 1);
        byte M(byte x, byte y) => (byte)Math.Round(x * (1 - t) + y * t);
        return Color.FromArgb(255, M(a.R, b.R), M(a.G, b.G), M(a.B, b.B));
    }

    public static FontWeight Weight(ushort value) => new() { Weight = value };
    public static readonly FontWeight Regular = Weight(400), Medium = Weight(500), Semibold = Weight(600), Bold = Weight(700);

    /// <summary>`V3.sans`。</summary>
    public static TextBlock Sans(string text, double size, Color? color = null, FontWeight? weight = null) => new()
    {
        Text = text, FontSize = size, FontFamily = SansFamily, FontWeight = weight ?? Regular,
        Foreground = Brush(color ?? Txt), TextTrimming = TextTrimming.CharacterEllipsis,
    };

    /// <summary>`V3.serif`：字体文件只有 SemiBold 一个字重。</summary>
    public static TextBlock Serif(string text, double size, Color? color = null) => new()
    {
        Text = text, FontSize = size, FontFamily = SerifFamily, Foreground = Brush(color ?? Txt), TextTrimming = TextTrimming.CharacterEllipsis,
    };

    /// <summary>系统字体文字（Swift `.font(.system(size:weight:))`）。</summary>
    public static TextBlock Label(string text, double size, Color? color = null, FontWeight? weight = null) => new()
    {
        Text = text, FontSize = size, FontWeight = weight ?? Regular, Foreground = Brush(color ?? Txt), TextTrimming = TextTrimming.CharacterEllipsis,
    };

    /// <summary>`V3.number`：系统字体等宽数字。</summary>
    public static TextBlock Number(string text, double size, Color? color = null, FontWeight? weight = null)
    {
        var block = Label(text, size, color, weight ?? Semibold);
        Microsoft.UI.Xaml.Documents.Typography.SetNumeralAlignment(block, FontNumeralAlignment.Tabular);
        return block;
    }

    /// <summary>CSS `line-height`，对应 Swift `.lineHeight(size, height)`：每行固定为 height。</summary>
    public static TextBlock LineHeight(this TextBlock block, double height)
    {
        block.LineHeight = height;
        block.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        return block;
    }

    /// <summary>多行换行（Swift `.fixedSize(horizontal: false, vertical: true)`）。</summary>
    public static TextBlock Wrap(this TextBlock block, int maxLines = 0)
    {
        block.TextWrapping = TextWrapping.Wrap;
        block.MaxLines = maxLines;
        block.TextTrimming = maxLines > 0 ? TextTrimming.CharacterEllipsis : TextTrimming.None;
        return block;
    }

    public static T Pad<T>(this T element, double left, double top, double right, double bottom) where T : FrameworkElement
    {
        element.Margin = new Thickness(left, top, right, bottom);
        return element;
    }

    public static T Top<T>(this T element, double top) where T : FrameworkElement
    {
        element.Margin = new Thickness(element.Margin.Left, top, element.Margin.Right, element.Margin.Bottom);
        return element;
    }

    public static T Frame<T>(this T element, double? width = null, double? height = null) where T : FrameworkElement
    {
        if (width is { } w) element.Width = w;
        if (height is { } h) element.Height = h;
        return element;
    }

    public static T Align<T>(this T element, HorizontalAlignment h = HorizontalAlignment.Stretch, VerticalAlignment v = VerticalAlignment.Stretch) where T : FrameworkElement
    {
        element.HorizontalAlignment = h;
        element.VerticalAlignment = v;
        return element;
    }

    public static T Tip<T>(this T element, string label) where T : FrameworkElement
    {
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(element, label);
        ToolTipService.SetToolTip(element, label);
        return element;
    }

    public static StackPanel VStack(double spacing, params UIElement?[] children) => Stack(Orientation.Vertical, spacing, children);

    /// <summary>横排；子元素默认垂直居中（SwiftUI `HStack` 的默认对齐）。</summary>
    public static StackPanel HStack(double spacing, params UIElement?[] children)
    {
        var stack = Stack(Orientation.Horizontal, spacing, children);
        foreach (var child in stack.Children.OfType<FrameworkElement>())
            if (child.VerticalAlignment == VerticalAlignment.Stretch) child.VerticalAlignment = VerticalAlignment.Center;
        return stack;
    }

    static StackPanel Stack(Orientation orientation, double spacing, UIElement?[] children)
    {
        var stack = new StackPanel { Orientation = orientation, Spacing = spacing };
        foreach (var child in children) if (child is not null) stack.Children.Add(child);
        return stack;
    }

    /// <summary>两端排布（SwiftUI `HStack { left; Spacer(); right }`）。</summary>
    public static Grid Spread(UIElement left, UIElement right, double spacing = 24, VerticalAlignment align = VerticalAlignment.Center)
    {
        var grid = new Grid { ColumnSpacing = spacing };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (left is FrameworkElement l) l.VerticalAlignment = align;
        if (right is FrameworkElement r) { r.VerticalAlignment = align; Grid.SetColumn(r, 1); }
        grid.Children.Add(left);
        grid.Children.Add(right);
        return grid;
    }

    /// <summary>固定列宽的网格（Swift `HStack` 里按宽度排的若干列）。</summary>
    public static Grid Columns(double spacing, params (GridLength width, UIElement child)[] columns)
    {
        var grid = new Grid { ColumnSpacing = spacing };
        for (var i = 0; i < columns.Length; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = columns[i].width });
            if (columns[i].child is FrameworkElement element) Grid.SetColumn(element, i);
            grid.Children.Add(columns[i].child);
        }
        return grid;
    }

    public static GridLength Star(double value = 1) => new(value, GridUnitType.Star);
    public static GridLength Px(double value) => new(value);
    public static readonly GridLength Auto = GridLength.Auto;

    /// <summary>叠放（SwiftUI `ZStack`）。</summary>
    public static Grid Layer(params UIElement?[] children)
    {
        var grid = new Grid();
        foreach (var child in children) if (child is not null) grid.Children.Add(child);
        return grid;
    }

    /// <summary>1px 分隔线。</summary>
    public static Border Divider(Color? color = null, bool vertical = false) => vertical
        ? new Border { Width = 1, Background = Brush(color ?? Line), VerticalAlignment = VerticalAlignment.Stretch }
        : new Border { Height = 1, Background = Brush(color ?? Line), HorizontalAlignment = HorizontalAlignment.Stretch };

    /// <summary>带 1px 边框与圆角的白底卡片。</summary>
    public static Border Card(UIElement? child, double radius = 12, Thickness? padding = null, Color? background = null, Color? border = null) => new()
    {
        Child = child, CornerRadius = new CornerRadius(radius), Padding = padding ?? new Thickness(0),
        Background = Brush(background ?? White), BorderBrush = Brush(border ?? Cl), BorderThickness = new Thickness(border == Clear ? 0 : 1),
    };

    /// <summary>纯色圆角块（`RoundedRectangle().fill`）。</summary>
    public static Border Fill(Color color, double radius = 0, double? width = null, double? height = null, UIElement? child = null) => new Border
    {
        Background = Brush(color), CornerRadius = new CornerRadius(radius), Child = child,
    }.Frame(width, height);

    /// <summary>胶囊：圆角为高度一半。</summary>
    public static CornerRadius Capsule(double height) => new(height / 2);

    /// <summary>Segoe Fluent Icons 图标，替代 Mac 的 SF Symbols（对照表见 <see cref="Icons"/>）。</summary>
    public static FontIcon Icon(string symbol, double size, Color? color = null) => new()
    {
        Glyph = Icons.Glyph(symbol), FontSize = size, FontFamily = IconFamily, Foreground = Brush(color ?? Txt),
    };

    /// <summary>`Shadow`：WinUI 只有 ThemeShadow（基于 Z 轴），用 Translation.Z 近似 CSS 的柔和投影。</summary>
    public static T Elevate<T>(this T element, float z = 8) where T : UIElement
    {
        element.Shadow = new ThemeShadow();
        element.Translation = new System.Numerics.Vector3(0, 0, z);
        return element;
    }
}

/// <summary>Mac 版用到的 SF Symbols → Segoe Fluent Icons 字形。按 SF 名查；没收录时抛错，避免静默显示方块。</summary>
public static class Icons
{
    static readonly Dictionary<string, string> Map = new()
    {
        ["xmark"] = "\uE711", ["checkmark"] = "\uE73E", ["plus"] = "\uE710", ["minus"] = "\uE738",
        ["chevron.down"] = "\uE70D", ["chevron.up"] = "\uE70E", ["chevron.right"] = "\uE76C", ["chevron.left"] = "\uE76B",
        ["arrow.left"] = "\uE72B", ["arrow.right"] = "\uE72A", ["arrow.up"] = "\uE74A", ["arrow.clockwise"] = "\uE72C",
        ["arrow.uturn.backward"] = "\uE7A7", ["arrow.uturn.forward"] = "\uE7A6", ["arrow.up.right.square"] = "\uE8A7",
        ["ellipsis"] = "\uE712", ["magnifyingglass"] = "\uE721", ["xmark.circle.fill"] = "\uEA39",
        ["exclamationmark.triangle"] = "\uE7BA", ["exclamationmark.circle"] = "\uE783", ["exclamationmark.arrow.triangle.2.circlepath"] = "\uE895",
        ["info.circle"] = "\uE946", ["square.and.arrow.up"] = "\uE72D", ["square.and.pencil"] = "\uE70F", ["pencil"] = "\uE70F",
        ["ticket"] = "\uE8C7", ["sparkle"] = "\uE945", ["lock"] = "\uE72E", ["line.3.horizontal"] = "\uE700",
        ["line.3.horizontal.decrease"] = "\uE71C", ["envelope"] = "\uE715", ["doc.text"] = "\uE8A5", ["bell"] = "\uEA8F",
        ["trash"] = "\uE74D", ["textformat"] = "\uE8D2", ["textformat.size.smaller"] = "\uE8E7", ["textformat.size.larger"] = "\uE8E8",
        ["star.square"] = "\uE734", ["slider.horizontal.3"] = "\uE9E9", ["sidebar.right"] = "\uE89F", ["rectangle.split.1x2"] = "\uF57E",
        ["puzzlepiece.extension"] = "\uEA86", ["puzzlepiece.extension.fill"] = "\uEA86", ["mic"] = "\uE720", ["link"] = "\uE71B",
        ["icloud.slash"] = "\uE8F7", ["house"] = "\uE80F", ["folder"] = "\uE8B7", ["eraser"] = "\uE75C", ["clock"] = "\uE823",
        ["checkmark.circle.fill"] = "\uEC61", ["checkmark.circle"] = "\uE930", ["bubble.left.and.bubble.right"] = "\uE8F2",
        ["briefcase"] = "\uE821", ["brain"] = "\uE9D9",
        ["photo"] = "\uE91B", ["doc.on.doc"] = "\uE8C8", ["tray.and.arrow.down"] = "\uE896", ["bubble.left"] = "\uE8BD",
        ["square"] = "\uE739", ["checkmark.square.fill"] = "\uE73D", ["circle"] = "\uEA3A", ["largecircle.fill.circle"] = "\uECCB",
        ["clock.arrow.circlepath"] = "\uE81C", ["gauge.with.dots.needle.33percent"] = "\uEC4A", ["arrow.down.left.and.arrow.up.right"] = "\uE73F",
        ["arrow.up.left.and.arrow.down.right"] = "\uE740", ["doc"] = "\uE8A5",
        ["pin"] = "\uE718", ["character.cursor.ibeam"] = "\uE8AC", ["arrow.down.doc"] = "\uE896", ["square.grid.2x2"] = "\uF0E2",
        // 简历编辑器（工具轨、排版、检查、富文本工具条、行内图标）
        ["list.bullet.indent"] = "\uE8FD", ["rectangle.on.rectangle"] = "\uE81E", ["rectangle.split.2x1"] = "\uE89A", ["sparkles"] = "\uE945",
        ["scope"] = "\uE707", ["exclamationmark"] = "\uE171", ["character"] = "\uE8D2", ["highlighter"] = "\uE7E6",
        ["bold"] = "\uE8DD", ["italic"] = "\uE8DB", ["underline"] = "\uE8DC", ["strikethrough"] = "\uEDE0",
        ["chevron.left.forwardslash.chevron.right"] = "\uE943", ["phone"] = "\uE717", ["mappin.and.ellipse"] = "\uE707", ["globe"] = "\uE774",
        ["person.crop.square"] = "\uE77B", ["graduationcap"] = "\uE7BE", ["rosette"] = "\uE735", ["star"] = "\uE734", ["calendar"] = "\uE787",
        ["curlybraces"] = "\uE943", ["questionmark.square"] = "\uE897",
        // 求职看板
        ["eye"] = "\uE7B3", ["nosign"] = "\uF140", ["list.bullet"] = "\uEA37", ["paperclip"] = "\uE723",
        // 求职阶段详情、资料与复盘报告
        ["play.fill"] = "\uE768", ["pause.fill"] = "\uE769", ["wand.and.stars"] = "\uE945", ["text.alignleft"] = "\uE8E4",
    };

    public static string Glyph(string symbol) => Map.TryGetValue(symbol, out var glyph) ? glyph : throw new KeyNotFoundException($"未收录的图标：{symbol}");
    public static IReadOnlyCollection<string> Known => Map.Keys;
}
