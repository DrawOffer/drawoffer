using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace DrawOffer.App.Views;

/// <summary>
/// 临时：旧模拟面试页与旧资料库页（W6、W7 重写前）借用的文字与按钮样式，原先挂在已删除的旧日程页 `InterviewSchedulePage` 上。
/// 两页按 Mac 重写后删除本文件。
/// </summary>
static class LegacyControls
{
    static SolidColorBrush Brush(int color) => new(Windows.UI.Color.FromArgb(255, (byte)(color >> 16), (byte)(color >> 8), (byte)color));

    internal static TextBlock Text(string value, double size = 13, bool muted = false) =>
        new() { Text = value, FontSize = size, TextWrapping = TextWrapping.Wrap, Foreground = Brush(muted ? 0x96968F : 0x17191C) };

    internal static Button Button(string title, Action action, bool dark = false)
    {
        var value = new Button { Content = title, Padding = new Thickness(12, 7, 12, 7), CornerRadius = new CornerRadius(8), Background = Brush(dark ? 0x17191C : 0xFFFFFF), Foreground = Brush(dark ? 0xFFFFFF : 0x17191C) };
        value.Click += (_, _) => action();
        return value;
    }
}
