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

/// <summary>投递详情按钮（Windows 稿 07）：32 高胶囊、13 号字；一页只有一个黑色实心主按钮，没通过是红字。</summary>
public sealed class PDButton : BorderControl
{
    public enum Kind { Normal, Primary, Reject }

    readonly Kind _kind;
    bool _pressed, _enabled = true;

    public PDButton(string title, Action action, Kind kind = Kind.Normal, bool enabled = true, string? icon = null)
    {
        _kind = kind;
        _enabled = enabled;
        var ink = kind == Kind.Primary ? V3.White : kind == Kind.Reject ? PD.Red : PD.Ink;
        var text = Sans(title, 13, ink, Medium);
        Child = (icon is null ? (FrameworkElement)text : HStack(6, Icon(icon, 12, ink), text)).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        Padding = new Thickness(16, 0, 16, 0);
        Height = 32;
        CornerRadius = Capsule(32);
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
