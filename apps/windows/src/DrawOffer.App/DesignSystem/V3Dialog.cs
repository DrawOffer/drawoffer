using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.DesignSystem;

/// <summary>
/// Windows 稿 ContentDialog：宽 440（大表单 560/680），圆角 8、1px #E4E4E0 边；正文内边距 24；
/// 底部 CommandSpace #F4F4F1、内边距 24、按钮间距 8，按钮等宽、主按钮在右；不放右上角 ×，Esc 关闭。
/// 左侧说明（<paramref name="left"/>）存在时按钮不再等宽，说明在左、按钮靠右。
/// </summary>
public static class V3Dialog
{
    public static Border Make(UIElement content, IEnumerable<UIElement> foot, Action close, double width = 440, bool closable = true,
        IEnumerable<UIElement>? left = null, bool padded = true)
    {
        var leftItems = left?.ToArray() ?? [];
        var buttons = foot.ToArray();
        var body = new Border { Child = content, Padding = padded ? new Thickness(24) : new Thickness(0) };
        UIElement commands;
        if (leftItems.Length > 0)
        {
            commands = Spread(HStack(16, leftItems), HStack(8, buttons), 12);
        }
        else
        {
            var grid = new Grid { ColumnSpacing = 8 };
            for (var i = 0; i < buttons.Length; i++)
            {
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
                if (buttons[i] is FrameworkElement element) { element.HorizontalAlignment = HorizontalAlignment.Stretch; element.Width = double.NaN; Grid.SetColumn(element, i); }
                grid.Children.Add(buttons[i]);
            }
            commands = grid;
        }
        var commandSpace = new Border
        {
            Child = commands, Padding = new Thickness(24), Background = Brush(Stage),
            BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 1, 0, 0),
            Visibility = buttons.Length == 0 && leftItems.Length == 0 ? Visibility.Collapsed : Visibility.Visible,
        };
        var stack = new Grid();
        stack.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        stack.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        stack.Children.Add(Scroll(body));
        Grid.SetRow(commandSpace, 1);
        stack.Children.Add(commandSpace);
        return Frame(stack, width);
    }

    /// <summary>不带 CommandSpace 的弹窗外框：1px #E4E4E0 边、圆角 8、白底、Pop 阴影。</summary>
    public static Border Frame(UIElement child, double width) => new Border
    {
        Child = child, Width = width, CornerRadius = new CornerRadius(8), Background = Brush(V3.White),
        BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
    }.Elevate(32);

    /// <summary>一句话确认（稿：一句话确认也用 ContentDialog，440 宽）。返回是否点了主按钮。</summary>
    public static Task<bool> ConfirmAsync(XamlRoot root, string title, string? message, string confirm, bool danger = false, string cancel = "取消")
    {
        var result = new TaskCompletionSource<bool>();
        V3Overlay.Show(root, close =>
        {
            var primary = new V3Button(confirm, () => { result.TrySetResult(true); close(); }, danger ? V3Button.Kind.Danger : V3Button.Kind.Dark);
            return Make(V3DialogHead.Make(title, message), [new V3Button(cancel, close), primary], close);
        }, dismissed: () => result.TrySetResult(false));
        return result.Task;
    }

    /// <summary>只有一个「知道了」的提示。</summary>
    public static Task AlertAsync(XamlRoot root, string title, string? message = null, string button = "知道了")
    {
        var done = new TaskCompletionSource();
        V3Overlay.Show(root, close => Make(V3DialogHead.Make(title, message), [new V3Button(button, close, V3Button.Kind.Dark)], close),
            dismissed: () => done.TrySetResult());
        return done.Task;
    }
}

/// <summary>
/// 模态层（ContentDialog / Smoke）：#000 30% 遮罩盖住整个窗口（含侧栏与标题栏区域，系统最小化/最大化/关闭仍在最上面），
/// 弹窗在窗口正中，四周至少留 24；Esc 关闭。用 Popup 自建而不是系统 ContentDialog，以便放任意内容并统一外观。
/// </summary>
public sealed class V3Overlay
{
    readonly Popup _popup;
    readonly Action? _dismiss;
    static readonly List<V3Overlay> Open = [];

    V3Overlay(XamlRoot root, Func<Action, FrameworkElement> build, bool dismissible, Action? dismissed)
    {
        _dismiss = dismissed;
        var scrim = new Grid { Background = Brush(Alpha(Microsoft.UI.Colors.Black, 0.3)) };
        var dialog = build(Close);
        dialog.HorizontalAlignment = HorizontalAlignment.Center;
        dialog.VerticalAlignment = VerticalAlignment.Center;
        scrim.Children.Add(dialog);
        void Fit()
        {
            var size = root.Size;
            scrim.Width = size.Width;
            scrim.Height = size.Height;
            scrim.Padding = new Thickness(24);
            dialog.MaxHeight = Math.Max(0, size.Height - 48);
            dialog.MaxWidth = Math.Max(0, size.Width - 48);
        }
        Fit();
        root.Changed += (_, _) => Fit();
        scrim.KeyDown += (_, e) => { if (dismissible && e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; Close(); } };
        _popup = new Popup { XamlRoot = root, Child = scrim, IsLightDismissEnabled = false };
    }

    /// <summary>打开一个弹窗；<paramref name="build"/> 收到关闭回调。</summary>
    public static V3Overlay Show(XamlRoot root, Func<Action, FrameworkElement> build, bool dismissible = true, Action? dismissed = null)
    {
        var overlay = new V3Overlay(root, build, dismissible, dismissed);
        overlay._popup.IsOpen = true;
        Open.Add(overlay);
        ((FrameworkElement)overlay._popup.Child).Loaded += (_, _) => ((Control?)FindFocusable(overlay._popup.Child))?.Focus(FocusState.Programmatic);
        return overlay;
    }

    public bool IsOpen => _popup.IsOpen;

    public void Close()
    {
        if (!_popup.IsOpen) return;
        _popup.IsOpen = false;
        Open.Remove(this);
        _dismiss?.Invoke();
    }

    /// <summary>退出登录、换账号时关掉所有弹窗。</summary>
    public static void CloseAll()
    {
        foreach (var overlay in Open.ToArray()) overlay.Close();
    }

    static DependencyObject? FindFocusable(DependencyObject node)
    {
        if (node is Control { IsTabStop: true } control) return control;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
            if (FindFocusable(VisualTreeHelper.GetChild(node, i)) is { } found) return found;
        return null;
    }
}

/// <summary>
/// Windows 稿 Flyout（替代 macOS Popover）：无箭头，贴着触发控件 4px 弹出；白底、圆角 8、#E4E4E0 细边、Pop 阴影，默认内边距 16。
/// 菜单类内容传 padding 4（MenuFlyout 观感）。
/// </summary>
public static class V3Popover
{
    public static Flyout Show(FrameworkElement anchor, UIElement content, FlyoutPlacementMode placement = FlyoutPlacementMode.Bottom, double padding = 16)
    {
        var flyout = Make(content, placement, padding);
        flyout.ShowAt(anchor);
        return flyout;
    }

    public static Flyout Make(UIElement content, FlyoutPlacementMode placement = FlyoutPlacementMode.Bottom, double padding = 16) => new()
    {
        Content = content, Placement = placement, FlyoutPresenterStyle = PresenterStyle(padding), AreOpenCloseAnimationsEnabled = true,
    };

    /// <summary>菜单浮层（MenuFlyout 观感）：传入若干 <see cref="V3MenuRow"/>，点任一行后自动关闭。</summary>
    public static Flyout Menu(FrameworkElement anchor, double width, params UIElement[] rows)
    {
        var stack = new StackPanel { Width = width };
        Flyout? flyout = null;
        foreach (var row in rows)
        {
            if (row is V3MenuRow menuRow) menuRow.PointerReleased += (_, _) => flyout?.Hide();
            stack.Children.Add(row);
        }
        flyout = Show(anchor, stack, FlyoutPlacementMode.BottomEdgeAlignedLeft, 4);
        return flyout;
    }

    static Style PresenterStyle(double padding)
    {
        var style = new Style(typeof(FlyoutPresenter));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(padding)));
        style.Setters.Add(new Setter(Control.BackgroundProperty, Brush(V3.White)));
        style.Setters.Add(new Setter(Control.BorderBrushProperty, Brush(Cl)));
        style.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(1)));
        style.Setters.Add(new Setter(Control.CornerRadiusProperty, new CornerRadius(8)));
        style.Setters.Add(new Setter(FrameworkElement.MinWidthProperty, 0d));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 0d));
        style.Setters.Add(new Setter(FrameworkElement.MaxWidthProperty, 720d));
        style.Setters.Add(new Setter(ScrollViewer.VerticalScrollBarVisibilityProperty, ScrollBarVisibility.Auto));
        return style;
    }
}
