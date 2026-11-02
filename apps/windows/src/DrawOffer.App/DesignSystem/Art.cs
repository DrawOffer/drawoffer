using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.DesignSystem;

/// <summary>
/// 插图积木（Web `v3/art.tsx`），对应 Mac `DesignSystem/Art.swift`：坐标照设计稿，放在 <see cref="V3DotStage"/> 里。
/// SwiftUI 的 `.offset(x:y:)` 以舞台中心为原点；这里用居中对齐 + TranslateTransform 得到同样的位置。
/// </summary>
public static class Art
{
    static T Place<T>(T element, double x, double y) where T : FrameworkElement
    {
        element.HorizontalAlignment = HorizontalAlignment.Center;
        element.VerticalAlignment = VerticalAlignment.Center;
        element.RenderTransform = new TranslateTransform { X = x, Y = y };
        return element;
    }

    /// <summary>`ArtBox`：把内容放在 w×h 的框里偏移 (x, y)。</summary>
    public static FrameworkElement Box(double x, double y, double w, double h, UIElement content) =>
        Place(new Border { Width = w, Height = h, Child = content }, x, y);

    /// <summary>`ArtBar`：圆角色条，默认 `V3.line`、圆角 1。</summary>
    public static FrameworkElement Bar(double x, double y, double w, double h, double r = 1, Color? color = null) =>
        Place(new Border { Width = w, Height = h, CornerRadius = new CornerRadius(r), Background = Brush(color ?? Line) }, x, y);

    /// <summary>`ArtPaper`：白纸，1px `V3.cl` 边、圆角 8、阴影 (0, 6, 8, 6%)；子元素以左上角为原点。</summary>
    public static FrameworkElement Paper(double x, double y, double w, double h, IEnumerable<UIElement>? children = null, double r = 8, bool shadow = true, Color? fill = null)
    {
        var canvas = new Grid();
        foreach (var child in children ?? []) canvas.Children.Add(child);
        var paper = new Border
        {
            Width = w, Height = h, CornerRadius = new CornerRadius(r), Background = Brush(fill ?? V3.White),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), Child = canvas,
        };
        if (shadow) paper.Elevate(6);
        return Place(paper, x, y);
    }

    /// <summary>纸面内的元素：以纸的左上角为原点放在 (x, y)，对应纸里的 `ArtBar` / `ArtBox`（ZStack topLeading）。</summary>
    public static FrameworkElement At(FrameworkElement element, double x, double y)
    {
        element.HorizontalAlignment = HorizontalAlignment.Left;
        element.VerticalAlignment = VerticalAlignment.Top;
        element.Margin = new Thickness(x, y, 0, 0);
        element.RenderTransform = null;
        return element;
    }

    /// <summary>`ArtBadge`：圆形徽章，图标为直径的 0.42、半粗，阴影 (0, 2, 3, 10%)。</summary>
    public static FrameworkElement Badge(double x, double y, double size = 22, string symbol = "xmark", Color? fill = null, Color? color = null, Color? border = null)
    {
        var badge = new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(size / 2), Background = Brush(fill ?? Txt),
            BorderBrush = Brush(border ?? Clear), BorderThickness = new Thickness(border is null ? 0 : 1),
            Child = Icon(symbol, size * 0.42, color ?? V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        }.Elevate(3);
        return Place(badge, x, y);
    }

    /// <summary>叠放若干插图积木（舞台内容）。</summary>
    public static Grid Group(params FrameworkElement[] parts) => Layer(parts);
}
