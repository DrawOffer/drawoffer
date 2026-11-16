using DrawOffer.App.DesignSystem;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.System;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Resumes;

/// <summary>
/// 纸右边的对话（Figma 分区 12「修改对话与检查简历：对话版」，Mac `ResumeTalk.swift`）：400 宽一列、不加卡片；
/// 职绘头像 28 + 气泡（最新一轮白底细边，上一轮变淡），用户的话是右侧灰底小气泡，
/// 下面一排快捷回答（33 高胶囊）和一行输入框（47 高、右侧 30 圆形发送钮）。
/// </summary>
static class ResumeTalk
{
    public const double ColumnWidth = 400;
    /// <summary>头像左缘 2、气泡左缘 45（头像 28 + 间距 15）。</summary>
    public const double Indent = 45;
    public static readonly Color LineColor = Hex(0xD6D4CC), FieldLine = Hex(0xDCDAD2), Hint = Hex(0xA5A39B), Note = Hex(0x87867F),
        UserFill = Hex(0xEDECE7), OldFill = Hex(0xEFEFEC), Verify = Hex(0xC8721C);

    /// <summary>职绘头像：品牌花。</summary>
    public static Image Avatar(double size = 28)
    {
        var image = new Image { Width = size, Height = size, Source = new BitmapImage(new Uri("ms-appx:///Assets/Branding/mark.png")), Stretch = Stretch.Uniform };
        AutomationProperties.SetAccessibilityView(image, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return image;
    }

    /// <summary>对话列：竖排，间距 18，上 12 下 40，外面包滚动。</summary>
    public static ScrollViewer Column(params UIElement?[] children)
    {
        var stack = VStack(18, children);
        stack.Padding = new Thickness(0, 12, 0, 40);
        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollMode = ScrollMode.Disabled };
    }

    /// <summary>职绘说的一句：主句 14 号墨黑，补充 12.5 号灰；faded 是上一轮（灰底、变淡）。</summary>
    public static Grid Assistant(string text, string? note = null, bool faded = false, bool thinking = false, UIElement? extra = null)
    {
        var main = Sans(text, 14, faded ? Fnt : Txt).Wrap().LineHeight(22);
        main.IsTextSelectionEnabled = true;
        var head = thinking ? Columns(6, (Star(), main), (GridLength.Auto, new ProgressRing { IsActive = true, Width = 12, Height = 12, MinWidth = 0, MinHeight = 0, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 5, 0, 0) })) : (UIElement)main;
        var body = VStack(0, head);
        if (!string.IsNullOrEmpty(note)) body.Children.Add(Sans(note, 12.5, Note).Wrap().LineHeight(19).Top(10));
        if (extra is not null) body.Children.Add(extra);
        var bubble = new Border
        {
            Child = body, Padding = new Thickness(16, 12, 16, 12), CornerRadius = new CornerRadius(14),
            Background = Brush(faded ? OldFill : V3.White), BorderBrush = Brush(faded ? Clear : Cl), BorderThickness = new Thickness(1),
            Opacity = faded ? 0.75 : 1, HorizontalAlignment = HorizontalAlignment.Left,
        };
        var avatar = Avatar();
        avatar.Margin = new Thickness(2, 3, 0, 0);
        avatar.VerticalAlignment = VerticalAlignment.Top;
        var row = Columns(15, (GridLength.Auto, avatar), (Star(), bubble));
        row.Padding = new Thickness(0, 0, 40, 0);
        return row;
    }

    /// <summary>用户说的一句：右侧灰底小气泡。</summary>
    public static Border User(string text, bool faded = false) => new()
    {
        Child = Sans(text, 14, faded ? Fnt : Txt).Wrap().LineHeight(21), Padding = new Thickness(14, 8, 14, 8), CornerRadius = new CornerRadius(12),
        Background = Brush(UserFill), Opacity = faded ? 0.7 : 1, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(Indent + 40, 0, 0, 0),
    };

    /// <summary>快捷回答：33 高白底胶囊、#D6D4CC 细边、13 号字；悬停只加深边线，不加灰块。</summary>
    public static Border Chip(string title, Action action, bool disabled = false)
    {
        var chip = new Border
        {
            Child = Sans(title, 13, Txt).Align(v: VerticalAlignment.Center), Height = 33, Padding = new Thickness(14, 0, 14, 0), CornerRadius = Capsule(33),
            Background = Brush(V3.White), BorderBrush = Brush(LineColor), BorderThickness = new Thickness(1), Opacity = disabled ? 0.45 : 1,
        };
        chip.OnHover(h => chip.BorderBrush = Brush(h && !disabled ? Alpha(Sub, 0.6) : LineColor));
        chip.OnTap(action, title, () => !disabled);
        return chip;
    }

    /// <summary>一排快捷回答，放不下时换行（间距 9）。</summary>
    public static Panel Chips(IEnumerable<(string Title, Action Action)> items, bool disabled = false)
    {
        var flow = new VariableSizedFlow(9);
        foreach (var (title, action) in items) flow.Add(Chip(title, action, disabled));
        flow.Panel.Margin = new Thickness(Indent, 0, 0, 0);
        return flow.Panel;
    }

    /// <summary>错误提示：12.5 红字，与气泡左缘对齐。</summary>
    public static TextBlock? Notice(string? text) => text is null ? null : Sans(text, 12.5, Red).Wrap().Pad(Indent, 0, 0, 0);

    /// <summary>
    /// 输入框：随列宽撑满、最低 47 高、圆角 13.5、#DCDAD2 边；右侧 30 圆形发送钮，有字时变墨黑。
    /// Enter 发送，Shift+Enter 换行；最多 limit 字。
    /// </summary>
    public static Border Input(string placeholder, Action<string> send, bool disabled = false, int limit = 300, string text = "")
    {
        var box = new TextBox
        {
            Text = text, PlaceholderText = placeholder, MaxLength = limit, FontSize = 13.5, FontFamily = SansFamily, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
            MaxHeight = 96, MinHeight = 0, Padding = new Thickness(0, 6, 0, 6), BorderThickness = new Thickness(0), Background = Brush(Clear),
            Foreground = Brush(Txt), PlaceholderForeground = Brush(Hint), IsEnabled = !disabled, VerticalAlignment = VerticalAlignment.Center,
        };
        foreach (var key in new[] { "TextControlBackgroundFocused", "TextControlBackgroundPointerOver" }) box.Resources[key] = Brush(Clear);
        foreach (var key in new[] { "TextControlBorderBrushFocused", "TextControlBorderBrushPointerOver" }) box.Resources[key] = Brush(Clear);
        box.Resources["TextControlForegroundFocused"] = Brush(Txt);
        AutomationProperties.SetName(box, placeholder);
        var arrow = Icon("arrow.up", 12, V3.White);
        arrow.FontWeight = Semibold;
        arrow.HorizontalAlignment = HorizontalAlignment.Center;
        arrow.VerticalAlignment = VerticalAlignment.Center;
        var button = new Border { Width = 30, Height = 30, CornerRadius = new CornerRadius(15), Child = arrow, VerticalAlignment = VerticalAlignment.Center };
        bool Ready() => !disabled && box.Text.Trim().Length > 0;
        void Paint() => button.Background = Brush(Ready() ? Txt : LineColor);
        void Send() { if (!Ready()) return; var value = box.Text.Trim(); box.Text = ""; send(value); }
        button.OnTap(Send, "发送", Ready);
        box.TextChanged += (_, _) => Paint();
        box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Enter) return;
            var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (shift) return;
            e.Handled = true;
            Send();
        };
        Paint();
        var frame = new Border
        {
            Child = Columns(8, (Star(), box), (GridLength.Auto, button)), MinHeight = 47, Padding = new Thickness(16, 8, 8, 8), CornerRadius = new CornerRadius(13.5),
            Background = Brush(V3.White), BorderBrush = Brush(FieldLine), BorderThickness = new Thickness(1), Margin = new Thickness(Indent, 6, 0, 0),
        };
        box.GotFocus += (_, _) => frame.BorderBrush = Brush(Alpha(Sub, 0.5));
        box.LostFocus += (_, _) => frame.BorderBrush = Brush(FieldLine);
        return frame;
    }

    /// <summary>改好的那一句（整段换标题时纸上没有对应的行，写在对话里）：浅蓝底，要核实的说法标橙。</summary>
    public static Border Proposal(string text, IReadOnlyList<string> risky)
    {
        var block = new TextBlock { FontFamily = SansFamily, FontSize = 13, Foreground = Brush(Txt), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }.LineHeight(20);
        foreach (var (part, flagged) in Marked(text, risky)) block.Inlines.Add(new Run { Text = part, Foreground = Brush(flagged ? Verify : Txt) });
        return new Border { Child = block, Padding = new Thickness(10, 8, 10, 8), CornerRadius = new CornerRadius(6), Background = Brush(BlueSoft), Margin = new Thickness(0, 10, 0, 0) };
    }

    /// <summary>按要核实的说法把一句切成若干段。</summary>
    static IEnumerable<(string Text, bool Flagged)> Marked(string text, IReadOnlyList<string> risky)
    {
        var flags = new bool[text.Length];
        foreach (var term in risky.Where(t => t.Length > 0))
            for (var at = text.IndexOf(term, StringComparison.Ordinal); at >= 0; at = text.IndexOf(term, at + term.Length, StringComparison.Ordinal))
                for (var i = at; i < at + term.Length; i++) flags[i] = true;
        var start = 0;
        for (var i = 1; i <= text.Length; i++)
            if (i == text.Length || flags[i] != flags[start]) { yield return (text[start..i], flags[start]); start = i; }
    }

    /// <summary>Figma 12.1「改这一条」：126×33 白色胶囊、#D6D4CC 细边；职绘图标 14、「改这一条」13 墨黑、「Ctrl+K」灰字。悬停只加深边线。</summary>
    public static Border Trigger(Action action)
    {
        var pill = new Border
        {
            Child = HStack(6, Avatar(14), Sans("改这一条", 13, Txt).Align(v: VerticalAlignment.Center), Sans("Ctrl+K", 10.5, Hex(0xC4C3BD)).Align(v: VerticalAlignment.Center)),
            Height = 33, Padding = new Thickness(14.5, 0, 14, 0), CornerRadius = Capsule(33), Background = Brush(V3.White),
            BorderBrush = Brush(LineColor), BorderThickness = new Thickness(1),
        };
        pill.OnHover(h => pill.BorderBrush = Brush(h ? Alpha(Sub, 0.6) : LineColor));
        pill.OnTap(action, "改这一条");
        ToolTipService.SetToolTip(pill, "改这一条（Ctrl+K）");
        return pill;
    }
}
