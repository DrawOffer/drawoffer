using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace DrawOffer.App.DesignSystem;

/// <summary>
/// WinUI 的 Border / ScrollViewer 是密封类，不能继承。自定义部件继承这个 UserControl，
/// 内部放一个 Border，并把 Border 的外观属性转发过去，用法与 Border 相同（对应 SwiftUI 里的自定义 View）。
/// </summary>
public class BorderControl : UserControl
{
    protected readonly Border Frame = new();

    public BorderControl() => base.Content = Frame;

    public UIElement? Child { get => Frame.Child; set => Frame.Child = value; }
    public new Brush? Background { get => Frame.Background; set => Frame.Background = value; }
    public new CornerRadius CornerRadius { get => Frame.CornerRadius; set => Frame.CornerRadius = value; }
    public new Thickness Padding { get => Frame.Padding; set => Frame.Padding = value; }
    public new Brush? BorderBrush { get => Frame.BorderBrush; set => Frame.BorderBrush = value; }
    public new Thickness BorderThickness { get => Frame.BorderThickness; set => Frame.BorderThickness = value; }
}
