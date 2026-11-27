using System.Globalization;
using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Text;
using Windows.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>阶段详情、资料、面试记录与复盘报告共用的小工具（Mac 版散落在各 View 里的同名私有函数）。</summary>
internal static class CareerKit
{
    public static readonly FontFamily MonoFamily = new("Cascadia Mono,Consolas");

    /// <summary>`.font(.system(size:weight:design: .monospaced))`。</summary>
    public static TextBlock Mono(string text, double size, Color color, FontWeight? weight = null) => new()
    {
        Text = text, FontSize = size, FontFamily = MonoFamily, FontWeight = weight ?? Regular, Foreground = Brush(color),
        TextTrimming = TextTrimming.CharacterEllipsis,
    };

    /// <summary>SwiftUI `.lineSpacing(x)`：在自然行高上再加 x。</summary>
    public static TextBlock Spaced(this TextBlock text, double spacing) => text.LineHeight(Math.Round(text.FontSize * 1.25 + spacing, 1));

    public static TextBlock Selectable(this TextBlock text) { text.IsTextSelectionEnabled = true; return text; }

    /// <summary>401 时上报登录失效（Mac 由 APIClient 统一处理）。</summary>
    public static void Fail(Exception error)
    {
        if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
    }

    public static bool Unauthorized(Exception error) => error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized };

    /// <summary>Mac `APIError.server(status, code)`：非 401 的接口错误。</summary>
    public static bool Server(Exception error, out int status, out string code)
    {
        if (error is ApiException api && api.Status != System.Net.HttpStatusCode.Unauthorized) { status = (int)api.Status; code = api.Code; return true; }
        status = 0; code = "";
        return false;
    }

    /// <summary>`session["lock_version"] ?? .number(1)`。</summary>
    public static JsonNode Lock(JsonNode? session) => session.Get("lock_version")?.DeepClone() ?? JsonValue.Create(1);

    /// <summary>`ISO8601DateFormatter().string(from:)`：UTC、不带小数秒。</summary>
    public static string Iso(DateTimeOffset date) => date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    public static string Or(this string value, string fallback) => value.Length == 0 ? fallback : value;

    /// <summary>Swift `String.count`（按字素计）。</summary>
    public static int Count(string value) => new StringInfo(value).LengthInTextElements;

    /// <summary>Swift `String(value.prefix(n))`。</summary>
    public static string Prefix(string value, int count)
    {
        var info = new StringInfo(value);
        return info.LengthInTextElements <= count ? value : info.SubstringByTextElements(0, count);
    }

    public static string Two(int value) => value.ToString("00", CultureInfo.InvariantCulture);

    /// <summary>把持久保留的控件从旧父容器摘下，便于整体重绘时复用（保留输入焦点与内容）。</summary>
    public static T Detach<T>(T element) where T : FrameworkElement
    {
        switch (element.Parent)
        {
            case Panel panel: panel.Children.Remove(element); break;
            case Border border: border.Child = null; break;
            case ContentControl control: control.Content = null; break;
            case UserControl user: user.Content = null; break;
        }
        return element;
    }

    /// <summary>圆角块加虚线描边（`.background(fill, in: RoundedRectangle).overlay(stroke(style: dash))`）。</summary>
    public static Grid Dashed(UIElement content, double radius, Color stroke, Color? fill = null, double width = 1, double[]? dash = null)
    {
        var grid = new Grid();
        grid.Children.Add(new Border { CornerRadius = new CornerRadius(radius), Background = Brush(fill ?? Clear) });
        grid.Children.Add(content);
        var pattern = new DoubleCollection();
        foreach (var value in dash ?? [4, 3]) pattern.Add(value / width);
        grid.Children.Add(new Rectangle { RadiusX = radius, RadiusY = radius, Stroke = Brush(stroke), StrokeThickness = width, StrokeDashArray = pattern, IsHitTestVisible = false });
        return grid;
    }

    /// <summary>`ProgressView("…")`：小号转圈加说明。</summary>
    public static StackPanel Spinner(string text, double size = 12)
    {
        var row = HStack(8, new ProgressRing { Width = 16, Height = 16, IsActive = true }, Sans(text, size, CareerPalette.Sub));
        return row;
    }

    public static TextBlock ErrorText(string text) => Sans(text, 12, CareerPalette.Red).Wrap();

    /// <summary>`Text(...).underline()` 的纯文字按钮（状态条里的“重新转写”等）。</summary>
    public static Border LinkButton(string title, Action action, double size, Color color, bool enabled = true)
    {
        var label = Sans(title, size, color, Medium);
        label.TextDecorations = TextDecorations.Underline;
        var button = new Border { Child = label, Background = Brush(Clear), Opacity = enabled ? 1 : 0.5 };
        return button.OnTap(action, title, () => enabled);
    }

    /// <summary>可点按的透明容器（`Button { … }.buttonStyle(.plain)`）。</summary>
    public static Border Tappable(UIElement content, Action action, string? name = null, Func<bool>? enabled = null)
        => new Border { Child = content, Background = Brush(Clear) }.OnTap(action, name, enabled);

    public static void Hidden(UIElement element) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(element, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);

    public static T Named<T>(this T element, string name) where T : UIElement
    {
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(element, name);
        return element;
    }

    /// <summary>`Circle()`。</summary>
    public static Ellipse Dot(Color color, double size) => new() { Width = size, Height = size, Fill = Brush(color) };

    /// <summary>四角圆角不同的矩形路径（`UnevenRoundedRectangle`），用于虚线描边。</summary>
    public static Geometry Uneven(double w, double h, double tl, double tr, double br, double bl)
    {
        var figure = new PathFigure { StartPoint = new Point(tl, 0), IsClosed = true, IsFilled = false };
        void Line(double x, double y) => figure.Segments.Add(new LineSegment { Point = new Point(x, y) });
        void Arc(double x, double y, double r) => figure.Segments.Add(new ArcSegment { Point = new Point(x, y), Size = new Size(r, r), SweepDirection = SweepDirection.Clockwise });
        Line(w - tr, 0); Arc(w, tr, tr);
        Line(w, h - br); Arc(w - br, h, br);
        Line(bl, h); Arc(0, h - bl, bl);
        Line(0, tl); Arc(tl, 0, tl);
        return new PathGeometry { Figures = { figure } };
    }

    /// <summary>`DatePicker(label, selection:)`：标签 + 日期 + 时间（本地时区）。</summary>
    public static Grid DateTimeRow(string label, DateTimeOffset value, Action<DateTimeOffset> changed, bool enabled = true)
    {
        var date = new CalendarDatePicker { Date = value, IsEnabled = enabled, DateFormat = "{year.full}/{month.integer(2)}/{day.integer(2)}" }.Named(label);
        var time = new TimePicker { Time = value.LocalDateTime.TimeOfDay, ClockIdentifier = "24HourClock", IsEnabled = enabled, MinuteIncrement = 1 }.Named(label);
        void Update()
        {
            var day = (date.Date ?? value).LocalDateTime.Date;
            changed(Local(day + time.Time));
        }
        date.DateChanged += (_, _) => Update();
        time.TimeChanged += (_, _) => Update();
        return Columns(12, (Px(80), Sans(label, 13, CareerPalette.Text)), (Auto, date), (Auto, time));
    }

    /// <summary>本地墙上时间 → DateTimeOffset。</summary>
    public static DateTimeOffset Local(DateTime wall)
    {
        var unspecified = DateTime.SpecifyKind(wall, DateTimeKind.Unspecified);
        return new DateTimeOffset(unspecified, Beijing.Zone.GetUtcOffset(unspecified));
    }

    /// <summary>`String(format: "%02d:%02d", s / 60, s % 60)`。</summary>
    public static string Stamp(double seconds)
    {
        var value = (int)Math.Max(0, seconds);
        return $"{Two(value / 60)}:{Two(value % 60)}";
    }

    /// <summary>
    /// 整体重绘时保住输入焦点：重绘会把保留的 TextBox 摘下再挂回，WinUI 会因此丢焦点；记下焦点与选区，重绘后还原。
    /// </summary>
    public static void KeepFocus(XamlRoot? root, Action rebuild)
    {
        var box = root is null ? null : Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(root) as TextBox;
        var (start, length) = box is null ? (0, 0) : (box.SelectionStart, box.SelectionLength);
        rebuild();
        if (box is null) return;
        box.DispatcherQueue.TryEnqueue(() =>
        {
            if (box.XamlRoot is null) return;
            box.Focus(FocusState.Programmatic);
            box.Select(Math.Min(start, box.Text.Length), Math.Min(length, Math.Max(0, box.Text.Length - start)));
        });
    }

    /// <summary>Swift `Double.rounded()`：四舍五入远离零。</summary>
    public static double Round(double value) => Math.Round(value, MidpointRounding.AwayFromZero);
}
