using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.DesignSystem;

/// <summary>
/// `.v3-dialog`，对应 Swift `V3Dialog`：正文 28/32/24 内边距，右上 28×28 关闭（距边 26），底部 88 高、顶线分隔的按钮区（左侧可放说明）。
/// 宽度 ≤500 时按 `@container dialog (max-width: 500px)`：正文 24/20、关闭 20/16、页脚上下 16 左右 20、按钮在说明下方靠左。
/// </summary>
public static class V3Dialog
{
    public static Border Make(UIElement content, IEnumerable<UIElement> foot, Action close, double width = 440, bool closable = true,
        IEnumerable<UIElement>? left = null, bool padded = true)
    {
        var narrow = width <= 500;
        var leftItems = left?.ToArray() ?? [];
        var body = new Border
        {
            Child = content,
            Padding = padded ? new Thickness(narrow ? 20 : 32, narrow ? 24 : 28, narrow ? 20 : 32, 24) : new Thickness(0),
        };
        UIElement footer;
        if (narrow)
        {
            footer = VStack(10, leftItems.Length > 0 ? HStack(20, leftItems) : null, HStack(10, foot.ToArray()))
                .Pad(20, 16, 20, 16);
            ((FrameworkElement)footer).MinHeight = 40;
        }
        else
        {
            var row = Spread(HStack(20, leftItems), HStack(10, foot.ToArray()), 10);
            row.Padding = new Thickness(32, 0, 32, 0);
            row.MinHeight = 88;
            footer = row;
        }
        var footBorder = new Border { Child = footer, BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 1, 0, 0) };
        var stack = new Grid();
        stack.RowDefinitions.Add(new RowDefinition { Height = Star() });
        stack.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        stack.Children.Add(new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Grid.SetRow(footBorder, 1);
        stack.Children.Add(footBorder);
        if (closable)
        {
            var x = CloseButton(close).Align(HorizontalAlignment.Right, VerticalAlignment.Top).Pad(0, narrow ? 20 : 26, narrow ? 16 : 26, 0);
            Grid.SetRowSpan(x, 2);
            stack.Children.Add(x);
        }
        return Frame(stack, width);
    }

    /// <summary>不带页脚的弹窗外框：1px 边、16 圆角、白底、`--v3-shadow-dialog`。</summary>
    public static Border Frame(UIElement child, double width) => new Border
    {
        Child = child, Width = width, CornerRadius = new CornerRadius(16), Background = Brush(V3.White),
        BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
    }.Elevate(32);

    /// <summary>`.v3-dialog-close`：28×28、圆角 7，悬停灰底。</summary>
    public static Border CloseButton(Action close)
    {
        var button = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(7), Child = Icon("xmark", 12, Fnt).Align(HorizontalAlignment.Center, VerticalAlignment.Center) }.Tip("关闭");
        button.Background = Brush(Clear);
        button.PointerEntered += (_, _) => button.Background = Brush(Field);
        button.PointerExited += (_, _) => button.Background = Brush(Clear);
        button.PointerReleased += (_, _) => close();
        return button;
    }
}

/// <summary>
/// 模态层（`.v3-overlay`）：盖住整个窗口的 rgb(29 29 27 / 32%) 遮罩，弹窗居中，四周留 clamp(12, 3vw, 24) 边距；Esc 关闭。
/// 对应 SwiftUI 的 `.sheet`。WinUI 的 ContentDialog 有固定的系统外观，所以用 Popup 自建。
/// </summary>
public sealed class V3Overlay
{
    readonly Popup _popup;
    readonly Action? _dismiss;

    V3Overlay(XamlRoot root, Func<Action, FrameworkElement> build, bool dismissible, Action? dismissed)
    {
        _dismiss = dismissed;
        var scrim = new Grid { Background = Brush(Alpha(Txt, 0.32)) };
        var dialog = build(Close);
        dialog.HorizontalAlignment = HorizontalAlignment.Center;
        dialog.VerticalAlignment = VerticalAlignment.Center;
        scrim.Children.Add(dialog);
        void Fit()
        {
            var size = root.Size;
            var gutter = Math.Clamp(size.Width * 0.03, 12, 24);
            scrim.Width = size.Width;
            scrim.Height = size.Height;
            scrim.Padding = new Thickness(gutter);
            dialog.MaxHeight = Math.Max(0, size.Height - gutter * 2);
            dialog.MaxWidth = Math.Max(0, size.Width - gutter * 2);
        }
        Fit();
        root.Changed += (_, _) => Fit();
        scrim.PointerReleased += (_, e) => { if (dismissible && ReferenceEquals(e.OriginalSource, scrim)) Close(); };
        scrim.KeyDown += (_, e) => { if (dismissible && e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; Close(); } };
        _popup = new Popup { XamlRoot = root, Child = scrim, IsLightDismissEnabled = false };
    }

    /// <summary>打开一个弹窗；<paramref name="build"/> 收到关闭回调。</summary>
    public static V3Overlay Show(XamlRoot root, Func<Action, FrameworkElement> build, bool dismissible = true, Action? dismissed = null)
    {
        var overlay = new V3Overlay(root, build, dismissible, dismissed);
        overlay._popup.IsOpen = true;
        ((FrameworkElement)overlay._popup.Child).Loaded += (_, _) => ((Control?)FindFocusable(overlay._popup.Child))?.Focus(FocusState.Programmatic);
        return overlay;
    }

    public bool IsOpen => _popup.IsOpen;

    public void Close()
    {
        if (!_popup.IsOpen) return;
        _popup.IsOpen = false;
        _dismiss?.Invoke();
    }

    static DependencyObject? FindFocusable(DependencyObject node)
    {
        if (node is Control { IsTabStop: true } control) return control;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
            if (FindFocusable(VisualTreeHelper.GetChild(node, i)) is { } found) return found;
        return null;
    }
}

/// <summary>锚定在某个元素上的浮层（SwiftUI `.popover`）：白底 12 圆角、1px 边、阴影，点外面关闭。</summary>
public static class V3Popover
{
    public static Flyout Show(FrameworkElement anchor, UIElement content, FlyoutPlacementMode placement = FlyoutPlacementMode.Bottom, double padding = 6)
    {
        var flyout = new Flyout
        {
            Content = content, Placement = placement,
            FlyoutPresenterStyle = PresenterStyle(padding),
        };
        flyout.ShowAt(anchor);
        return flyout;
    }

    static Style PresenterStyle(double padding)
    {
        var style = new Style(typeof(FlyoutPresenter));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(padding)));
        style.Setters.Add(new Setter(Control.BackgroundProperty, Brush(V3.White)));
        style.Setters.Add(new Setter(Control.BorderBrushProperty, Brush(Cl)));
        style.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(1)));
        style.Setters.Add(new Setter(Control.CornerRadiusProperty, new CornerRadius(12)));
        style.Setters.Add(new Setter(FrameworkElement.MinWidthProperty, 0d));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 0d));
        style.Setters.Add(new Setter(FrameworkElement.MaxWidthProperty, 640d));
        return style;
    }
}
