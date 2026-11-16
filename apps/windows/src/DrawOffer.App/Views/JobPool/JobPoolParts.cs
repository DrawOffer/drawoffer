using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using Windows.UI.Text;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.JobPool;

/// <summary>岗位广场共用部件（Windows 稿 06）：数字分组、Logo、面包屑、统计、筛选胶囊、下拉、标签、骨架、提示条与空状态。</summary>
static class PoolUI
{
    /// <summary>`grouped`：zh_CN 千分位。</summary>
    public static string Grouped(int value) => value.ToString("N0", System.Globalization.CultureInfo.GetCultureInfo("zh-CN"));

    public static string Trim(string value) => value.Trim(' ', '\t');

    /// <summary>`title + " - " + department`。</summary>
    public static string Title(JsonNode job) => job.Text("title") + (job.Text("department").NonEmpty() is { } department ? " - " + department : "");

    /// <summary>外部链接只打开 http / https。</summary>
    public static Uri? Web(string value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" ? uri : null;

    public static void Launch(Uri uri) => _ = Windows.System.Launcher.LaunchUriAsync(uri);

    /// <summary>外链文字，末尾带「↗」（Windows 稿 06）。</summary>
    public static TextBlock Link(string title, Uri uri, double size, Color color, FontWeight? weight = null) =>
        TextLink(title + " ↗", () => Launch(uri), size, color, weight ?? Regular);

    /// <summary>
    /// 公司图标：公开 Logo，缺图或加载失败时回退首字。目录紧凑卡片（filled）为 #F4F4F2 底、无描边；其余白底细描边。
    /// </summary>
    public static Border Logo(string name, string url, double size = 24, bool filled = false)
    {
        var radius = size switch { 20 => 5, 24 => 6, 32 => 8, 40 => 9, 48 => 10, 56 => 12, 64 => 12, _ => 6 };
        var font = size switch { 20 => 10, 24 => 12, 32 => 14, 40 => 16, 48 => 19, 56 => 22, 64 => 24, _ => 12 };
        var trimmed = name.Trim(' ', '\t');
        var initial = trimmed.Length == 0 ? "企" : System.Globalization.StringInfo.GetNextTextElement(trimmed);
        var fallback = Sans(initial, font, Hex(0x454842), Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        var logo = new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(radius), Background = Brush(filled ? Field : V3.White),
            BorderBrush = Brush(filled ? Clear : Cl), BorderThickness = new Thickness(filled ? 0 : 1), Child = fallback,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(logo, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        if (url.StartsWith("/api/company-logos/") && (App.Session.Api as HttpApiClient)?.Coordinator.Origin is { } origin)
        {
            var bitmap = new BitmapImage(new Uri(origin, url));
            bitmap.ImageOpened += (_, _) => logo.Child = new Image { Source = bitmap, Stretch = Stretch.Uniform };
        }
        return logo;
    }

    /// <summary>面包屑「岗位广场 / 公司 / 当前页」：12 号，前几级灰色可点、斜杠更浅、当前页墨黑；高 18。</summary>
    public static FrameworkElement Crumbs(Action back, IEnumerable<(string Title, Action Action)>? trail = null, string? current = null)
    {
        var row = HStack(6, TextLink("岗位广场", back, 12, Fnt, Regular).Tip("返回岗位广场"));
        foreach (var item in trail ?? [])
        {
            row.Children.Add(Sans("/", 12, Fnt2));
            row.Children.Add(TextLink(item.Title, item.Action, 12, Fnt, Regular));
        }
        if (current is { Length: > 0 })
        {
            row.Children.Add(Sans("/", 12, Fnt2));
            row.Children.Add(Sans(current, 12, Txt).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis));
        }
        row.Height = 18;
        return row;
    }

    /// <summary>页头右侧：在招总数（24 号数字 + 「个在招岗位」），下一行蓝点「今日新增 N」· 补充说明。</summary>
    public static FrameworkElement Stats(int count, int today, string? extra = null)
    {
        var top = HStack(8, Number(Grouped(count), 24, Txt), Sans("个在招岗位", 12, Fnt).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 3));
        top.HorizontalAlignment = HorizontalAlignment.Right;
        var tint = today > 0 ? Blue : Fnt;
        var bottom = HStack(6, new Ellipse { Width = 6, Height = 6, Fill = Brush(today > 0 ? Blue : Fnt2), VerticalAlignment = VerticalAlignment.Center },
            Sans($"今日新增 {Grouped(today)}", 12, tint));
        if (extra is not null) { bottom.Children.Add(Sans("·", 12, Fnt2)); bottom.Children.Add(Sans(extra, 12, Fnt)); }
        bottom.Height = 18;
        bottom.HorizontalAlignment = HorizontalAlignment.Right;
        return VStack(4, top, bottom).Align(HorizontalAlignment.Right, VerticalAlignment.Top);
    }

    /// <summary>筛选胶囊：一排 Windows 稿 FilterChip（28 高，选中白底细边、未选灰底），数量并进文字，间距 4。</summary>
    public static FrameworkElement Chips(IEnumerable<(string Value, string Label, int? Count)> items, string selection, string label, Action<string> change)
    {
        var flow = new VariableSizedFlow(4);
        foreach (var item in items)
        {
            var value = item.Value;
            flow.Add(new V3FilterChip(item.Count is { } count ? $"{item.Label} {Grouped(count)}" : item.Label, value == selection, () => change(value)));
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(flow.Panel, label);
        return flow.Panel;
    }

    /// <summary>Windows 稿 ComboBox：32 高白底 #DCDCD8 细边、圆角 4，13 号字，右侧下箭头；点开为 V3 菜单（选中项打勾）。</summary>
    public static FrameworkElement Select(string label, string value, IReadOnlyList<(string Value, string Label)> options, Action<string> change, string? placeholder = null, double width = 120)
    {
        var current = options.FirstOrDefault(o => o.Value == value).Label;
        var text = Sans(current ?? placeholder ?? label, 13, current is null ? Sub : Txt).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis);
        var row = Columns(8, (Star(), text.Align(v: VerticalAlignment.Center)), (Auto, Icon("chevron.down", 10, Sub).Align(v: VerticalAlignment.Center)));
        var box = new Border
        {
            Child = row, Height = 32, Width = width, Padding = new Thickness(11, 0, 11, 0), CornerRadius = new CornerRadius(4),
            Background = Brush(V3.White), BorderBrush = Brush(Sk2), BorderThickness = new Thickness(1),
        };
        box.OnHover(h => box.Background = Brush(h ? Hex(0xFAFAF8) : V3.White));
        box.OnTap(() =>
        {
            Flyout? flyout = null;
            var menu = new StackPanel { MinWidth = Math.Max(140, width) };
            foreach (var option in options)
            {
                var picked = option.Value;
                menu.Children.Add(new V3MenuRow(option.Label, () => { flyout?.Hide(); change(picked); }, isChecked: option.Value == value));
            }
            flyout = V3Popover.Show(box, menu);
        }, label);
        return box;
    }

    /// <summary>灰底小标签（Tag · Neutral）：22 高、12 号 #55554F、圆角 4。</summary>
    public static Border MetaTag(string text, double height = 22) => new()
    {
        Child = Sans(text, 12, Sub).Align(v: VerticalAlignment.Center), Height = height, Padding = new Thickness(8, 0, 8, 0),
        CornerRadius = new CornerRadius(4), Background = Brush(Field), VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>今日新增 / 本轮未发现 小标签：22 高、12 号、圆角 4（Windows 稿 Tag · Accent）。</summary>
    public static Border Badge(string text, bool warn = false) => new()
    {
        Child = Sans(text, 12, warn ? Hex(0x8A4D12) : Blue, Medium).Align(v: VerticalAlignment.Center), Height = 22, Padding = new Thickness(8, 0, 8, 0),
        CornerRadius = new CornerRadius(4), Background = Brush(warn ? OrangeSoft : BlueSoft), VerticalAlignment = VerticalAlignment.Center,
    };

    public static Border Skeleton(double? width, double height, double radius = 4) => new()
    {
        Width = width ?? double.NaN, Height = height, CornerRadius = new CornerRadius(radius), Background = Brush(V3.Line),
        HorizontalAlignment = width is null ? HorizontalAlignment.Stretch : HorizontalAlignment.Left,
    };

    /// <summary>按父容器宽度比例的骨架条（`GeometryReader { box.size.width * ratio }`）。</summary>
    public static FrameworkElement Ratio(double ratio, double height, double radius = 4)
    {
        var bar = Skeleton(0, height, radius);
        var host = new Grid { Height = height };
        host.Children.Add(bar);
        host.SizeChanged += (_, e) => bar.Width = e.NewSize.Width * ratio;
        return host;
    }

    /// <summary>`.pool-note`：浅色提示条，警告时为橙色。</summary>
    public static Border Note(string text, bool warn = true, bool icon = false, UIElement? trailing = null)
    {
        var color = warn ? Hex(0x8A4D12) : Sub;
        var row = HStack(8, icon ? Icon("exclamationmark.triangle", 13, Orange) : null, Sans(text, 12.5, color).Wrap().Also(t => t.MinHeight = 22), trailing);
        return new Border
        {
            Child = row, Padding = new Thickness(12, 10, 12, 10), CornerRadius = new CornerRadius(8), Background = Brush(warn ? OrangeSoft : Field),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
    }

    /// <summary>`.pool-state` 里的空状态、失败与不存在卡片：居中，上 52、下 40。</summary>
    public static FrameworkElement State(string title, string message, UIElement art, IEnumerable<UIElement> actions, double width = 400, double stage = 156)
    {
        var card = V3EmptyCard.Make(title, message, art, actions, stageHeight: stage, width: width, actionsTop: 22);
        card.Width = width;
        card.HorizontalAlignment = HorizontalAlignment.Center;
        card.Margin = new Thickness(0, 52, 0, 40);
        return card;
    }

    public static FrameworkElement Error(string title, string message, Action retry)
    {
        var card = V3EmptyCard.Make(title, message, Icon("icloud.slash", 30, Hex(0x96968F)).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            [new V3Button("重新加载", retry, V3Button.Kind.Ghost, height: 36, icon: "arrow.clockwise")], stageHeight: 128, width: 440);
        card.Width = 440;
        card.HorizontalAlignment = HorizontalAlignment.Center;
        card.Margin = new Thickness(0, 52, 0, 40);
        return card;
    }

    /// <summary>`Button(...).buttonStyle(.plain)` 的文字链接。</summary>
    public static TextBlock TextLink(string title, Action action, double size, Color color, FontWeight? weight = null)
    {
        var text = Sans(title, size, color, weight ?? Medium);
        text.OnTap(action, title);
        return text;
    }
}

/// <summary>插图（坐标照 Web `PoolArt.tsx`，原点在左上角）。</summary>
static class PoolArt
{
    static T Put<T>(Canvas canvas, T element, double x, double y) where T : UIElement
    {
        Canvas.SetLeft(element, x);
        Canvas.SetTop(element, y);
        canvas.Children.Add(element);
        return element;
    }

    static Border Bar(double w, double h, double r, Color? color = null) =>
        new() { Width = w, Height = h, CornerRadius = new CornerRadius(r), Background = Brush(color ?? V3.Line) };

    static Rectangle Dashed(double w, double h, double r) =>
        new() { Width = w, Height = h, RadiusX = r, RadiusY = r, Stroke = Brush(Sk2), StrokeThickness = 1, StrokeDashArray = [3, 2] };

    /// <summary>`ArtPaper`：白纸 + 1px `V3.cl` 边，子元素以左上角为原点。</summary>
    static (Border Paper, Canvas Inner) Paper(double w, double h, bool shadow = true, Color? fill = null)
    {
        var inner = new Canvas { Width = w, Height = h };
        var paper = new Border
        {
            Width = w, Height = h, CornerRadius = new CornerRadius(8), Background = Brush(fill ?? V3.White),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), Child = inner,
        };
        if (shadow) paper.Elevate(6);
        return (paper, inner);
    }

    /// <summary>`ArtBadge`：图标为直径的 0.42。</summary>
    static Border Badge(double size, string symbol, Color fill, Color color, Color? border) => new Border
    {
        Width = size, Height = size, CornerRadius = new CornerRadius(size / 2), Background = Brush(fill),
        BorderBrush = Brush(border ?? Clear), BorderThickness = new Thickness(border is null ? 0 : 1),
        Child = Icon(symbol, size * 0.42, color).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
    }.Elevate(3);

    static FrameworkElement Host(Canvas canvas, double top = 0)
    {
        canvas.IsHitTestVisible = false;
        canvas.HorizontalAlignment = HorizontalAlignment.Center;
        canvas.VerticalAlignment = VerticalAlignment.Top;
        canvas.Margin = new Thickness(0, top, 0, 0);
        return canvas;
    }

    /// <summary>`PoolEmptyArt`：带当前条件的搜索框 + 清除角标，下面三行虚线空位（240×150）。</summary>
    public static FrameworkElement Empty(string summary)
    {
        var canvas = new Canvas { Width = 240, Height = 150 };
        var search = new Border
        {
            Width = 180, Height = 28, CornerRadius = Capsule(28), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            Padding = new Thickness(12, 0, 12, 0),
            Child = HStack(6, Icon("magnifyingglass", 9, Sub), Sans(summary, 9.5, Sub)).Align(v: VerticalAlignment.Center),
        }.Elevate(3);
        Put(canvas, search, 30, 24);
        Put(canvas, Badge(22, "xmark", Txt, V3.White, null), 196, 14);
        foreach (var top in new double[] { 64, 92, 120 })
        {
            var row = new Grid { Width = 180, Height = 22 };
            row.Children.Add(new Border { CornerRadius = new CornerRadius(6), Background = Brush(Alpha(V3.White, 0.6)) });
            row.Children.Add(Dashed(180, 22, 6));
            var inner = new Canvas();
            Put(inner, Bar(10, 4, 2), 8, 9);
            Put(inner, Bar(top == 92 ? 64 : 84, 4, 2), 24, 9);
            row.Children.Add(inner);
            Put(canvas, row, 30, top);
        }
        return Host(canvas);
    }

    /// <summary>`PoolUnavailableArt`：卡片 + 状态标签 + 禁止角标（220×96，上距 16）。</summary>
    public static FrameworkElement Unavailable(string tag)
    {
        var canvas = new Canvas { Width = 220, Height = 96 };
        var (paper, inner) = Paper(150, 66);
        Put(inner, Bar(20, 20, 5, Hex(0x8D8D87)), 14, 14);
        Put(inner, Bar(70, 6, 3), 44, 16);
        Put(inner, Bar(44, 4, 2), 44, 28);
        Put(inner, Bar(100, 4, 2), 14, 48);
        Put(canvas, paper, 30, 12);
        var label = new Border
        {
            Height = 20, Padding = new Thickness(8, 0, 8, 0), CornerRadius = Capsule(20), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            Child = HStack(5, new Ellipse { Width = 6, Height = 6, Fill = Brush(Hex(0x8D8D87)) }, Sans(tag, 9.5, Sub, Medium)).Align(v: VerticalAlignment.Center),
        }.Elevate(3);
        Put(canvas, label, 120, 0);
        Put(canvas, Badge(26, "nosign", V3.White, Sub, Cl), 166, 60);
        return Host(canvas, 16);
    }

    /// <summary>`PoolJoinFailedArt`：岗位卡片 → 求职进程空位，红色失败角标（330×128）。</summary>
    public static FrameworkElement JoinFailed()
    {
        var canvas = new Canvas { Width = 330, Height = 128 };
        var (card, inner) = Paper(128, 70);
        Put(inner, Bar(26, 26, 6, Txt), 12, 14);
        Put(inner, Bar(50, 6, 3), 48, 16);
        Put(inner, Bar(32, 4, 2), 48, 29);
        Put(inner, Bar(28, 10, 3), 12, 48);
        Put(canvas, card, 40, 28);
        var gray = Brush(Hex(0xB9B9B3));
        Put(canvas, new Line { X1 = 2, Y1 = 7, X2 = 34, Y2 = 7, Stroke = gray, StrokeThickness = 1.4, StrokeDashArray = [3 / 1.4, 3 / 1.4] }, 184, 56);
        Put(canvas, new Polyline
        {
            Points = { new(34, 3), new(39, 7), new(34, 11) }, Stroke = gray, StrokeThickness = 1.4,
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
        }, 184, 56);
        var (slot, slotInner) = Paper(92, 88, shadow: false, fill: Hex(0xFAFAF8));
        Put(slotInner, Bar(6, 6, 3, Hex(0x8D8D87)), 10, 12);
        Put(slotInner, Bar(40, 4, 2), 22, 13);
        foreach (var top in new double[] { 30, 56 }) Put(slotInner, Dashed(74, 20, 5), 8, top);
        Put(canvas, slot, 246, 20);
        Put(canvas, Badge(26, "xmark", RedSoft, Red, Red), 314, 88);
        return Host(canvas);
    }
}

/// <summary>
/// 加入求职进程（Web `usePoolJoin`，Mac `PoolJoin` + `PoolJoinFeedback`）：成功时顶部就地提示 3 秒；失败或岗位已下线时弹窗。
/// 已加入的岗位直接打开求职进程。
/// </summary>
sealed class PoolJoin(Func<XamlRoot?> root, Grid host, Action<string> open, Action changed)
{
    public string? JoiningId { get; private set; }
    Border? _toast;
    V3Overlay? _failure;
    int _notice;

    public async Task JoinAsync(JsonNode job, Action<string, string> joined, Action<string> closed)
    {
        if (job.Text("joined_application_id").NonEmpty() is { } existing) { open(existing); return; }
        if (JoiningId is not null || job.Text("availability_status") == "closed") return;
        var id = job.Text("id");
        JoiningId = id;
        changed();
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/job-pool/{id}/join", "POST", [], null);
            var application = result.Text("application_id");
            joined(id, application);
            _failure?.Close();
            Notice(application, result.Get("created") is JsonValue created ? created.Bool() : true);
        }
        catch (ApiException error) when (error.Code == "JOB_POOL_CLOSED")
        {
            closed(id);
            Fail(job, "这个岗位已从企业官网下线，无法再加入；已有求职记录不受影响。", closed: true, joined, closed);
        }
        catch (ApiException error) { Fail(job, Core.Models.JobPool.Error(error.Code) + "岗位信息和已有记录均已保留。", false, joined, closed); }
        catch (Exception) { Fail(job, Core.Models.JobPool.Error("") + "岗位信息和已有记录均已保留。", false, joined, closed); }
        finally { JoiningId = null; changed(); }
    }

    void Notice(string application, bool created)
    {
        if (_toast is not null) host.Children.Remove(_toast);
        var token = ++_notice;
        var link = new V3Button(created ? "查看" : "查看已有记录", () => open(application), V3Button.Kind.Text);
        var row = Columns(10,
            (Auto, Icon("checkmark", 13, Green).Align(v: VerticalAlignment.Top).Pad(0, 2, 0, 0)),
            (Star(), VStack(4, Sans(created ? "已加入求职进程" : "这个岗位已经加入", 14, Txt, Medium), Sans(created ? "可以在求职进程里继续管理投递和面试。" : "你已有这个岗位的求职记录。", 12, Sub))),
            (Auto, link.Align(v: VerticalAlignment.Center)));
        _toast = new Border
        {
            Child = row, Padding = new Thickness(16, 14, 16, 14), MinWidth = 320, CornerRadius = new CornerRadius(12), Background = Brush(V3.White),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 28, 0, 0),
        }.Elevate(12);
        Grid.SetRowSpan(_toast, 8);
        host.Children.Add(_toast);
        var toast = _toast;
        _ = Task.Delay(3000).ContinueWith(_ => host.DispatcherQueue.TryEnqueue(() =>
        {
            if (token == _notice) { host.Children.Remove(toast); _toast = null; }
        }));
    }

    void Fail(JsonNode job, string message, bool closed, Action<string, string> joined, Action<string> markClosed)
    {
        if (root() is not { } xaml) return;
        // 先放下旧弹窗的引用再关闭，避免关闭回调把新弹窗清掉
        var previous = _failure;
        _failure = null;
        previous?.Close();
        _failure = V3Overlay.Show(xaml, close =>
        {
            var body = VStack(0,
                new V3DotStage(closed ? PoolArt.Unavailable("官网已下线") : PoolArt.JoinFailed(), 128).Pad(0, 0, 0, 20),
                Label(closed ? "岗位已下线" : "加入失败", 18, Txt, Semibold).Align(HorizontalAlignment.Center),
                Sans(message, 14, Sub).LineHeight(22).Wrap().Also(t => t.TextAlignment = TextAlignment.Center).Pad(0, 6, 0, 0));
            body.Padding = new Thickness(24, 24, 24, 0);
            UIElement buttons;
            if (closed) buttons = new V3Button("知道了", close, V3Button.Kind.Dark, height: 36, fill: true);
            else
            {
                // 与 Mac 一致：重试时弹窗留着、按钮显示「正在加入…」；成功后关闭，再失败时换成新的失败内容
                V3Button? retry = null;
                retry = new V3Button(JoiningId is not null ? "正在加入…" : "重新加入", async () =>
                {
                    retry!.Title = "正在加入…"; retry.Enabled = false;
                    await JoinAsync(job, joined, markClosed);
                    retry.Title = "重新加入"; retry.Enabled = JoiningId is null;
                }, V3Button.Kind.Dark, height: 36, fill: true) { Enabled = JoiningId is null };
                buttons = Columns(12, (Star(), new V3Button("取消", close, V3Button.Kind.Ghost, height: 36, fill: true)), (Star(), retry));
            }
            var foot = new Border { Child = buttons, Padding = new Thickness(24, 20, 24, 24) };
            return V3Dialog.Frame(VStack(0, body, foot), 420);
        });
    }
}
