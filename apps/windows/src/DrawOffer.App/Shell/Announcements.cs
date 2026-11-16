using DrawOffer.App.DesignSystem;
using DrawOffer.App.Views;
using DrawOffer.Core.Models;
using DrawOffer.Core.Session;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Shell;

/// <summary>
/// 公告铃（Mac `AnnouncementBell`，Web `AnnouncementCenter.tsx`）：28×28，14 号铃铛 #55554F，未读时右上 6px 橙色圆点（Windows 稿侧栏：未读点统一橙色）。
/// 点开时强制刷新并把列表全部标为已读。
/// </summary>
public sealed class AnnouncementBell : Grid
{
    readonly WorkspaceShell _shell;
    readonly Border _dot = new() { Width = 6, Height = 6, CornerRadius = new CornerRadius(3), Background = Brush(Orange), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 5, 5, 0) };
    Flyout? _open;

    public AnnouncementBell(WorkspaceShell shell)
    {
        _shell = shell;
        Width = 28;
        Height = 28;
        Background = Brush(Clear);
        Children.Add(Icon("bell", 14, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center));
        Children.Add(_dot);
        shell.Announcements.Changed += () => DispatcherQueue.TryEnqueue(Paint);
        PointerReleased += async (_, _) =>
        {
            if (_open is not null) { _open.Hide(); return; }
            var list = new AnnouncementListView(shell, (ids, index) => { _open?.Hide(); shell.Announcements.Detail = (ids, index); AnnouncementDetail.Show(shell); });
            _open = V3Popover.Show(this, list, FlyoutPlacementMode.RightEdgeAlignedTop, 0);
            _open.Closed += (_, _) => _open = null;
            await shell.Announcements.RefreshAsync(App.Session.Api, force: true);
            shell.Announcements.ViewList(App.Session.Api);
        };
        Paint();
    }

    void Paint()
    {
        _dot.Visibility = _shell.Announcements.UnreadCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        this.Tip(_shell.Announcements.UnreadCount > 0 ? "公告，有未读" : "公告");
    }
}

/// <summary>
/// 公告列表浮层（Web `.ann-popover`）：360 宽；头部 18/24/4、17px 衬线标题；空态 24/24/36；
/// 列表左右 12、行间 1px 线，每条 12 内边距，悬停 #F4F4F2 圆角 10（第二条起上方两角不圆）。
/// </summary>
public sealed class AnnouncementListView : StackPanel
{
    readonly WorkspaceShell _shell;
    readonly Action<List<string>, int> _pick;

    public AnnouncementListView(WorkspaceShell shell, Action<List<string>, int> pick)
    {
        _shell = shell;
        _pick = pick;
        Width = 360;
        shell.Announcements.Changed += () => DispatcherQueue.TryEnqueue(Render);
        Render();
    }

    void Render()
    {
        Children.Clear();
        var center = _shell.Announcements;
        var head = HStack(8, Label("公告", 16, Txt, Semibold));
        if (center.Items.Count > 0)
        {
            var fresh = center.Items.Count(x => center.FreshIds.Contains(x.Id));
            head.Children.Add(Label(fresh > 0 ? $"{fresh} 条新公告" : $"共 {center.Items.Count} 条", 11.5, Hex(0x96968F)));
        }
        head.Margin = new Thickness(24, 18, 24, 4);
        Children.Add(head);
        if (center.Items.Count == 0)
        {
            var empty = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(24, 24, 24, 36) };
            TextBlock Line(string text, double size, Windows.UI.Color color) { var t = Label(text, size, color); t.TextAlignment = TextAlignment.Center; t.HorizontalAlignment = HorizontalAlignment.Center; return t; }
            switch (center.Status)
            {
                case AnnouncementCenter.LoadStatus.Error:
                    empty.Children.Add(Line("公告暂时无法读取", 13, Sub));
                    empty.Children.Add(Line("稍后再打开试试", 12, Hex(0x96968F)));
                    break;
                case AnnouncementCenter.LoadStatus.Ready:
                    empty.Children.Add(Icon("bell", 18, Hex(0xB3B3AD)).Align(HorizontalAlignment.Center).Frame(22, 22));
                    empty.Children.Add(Line("暂时没有公告", 13, Sub));
                    empty.Children.Add(Line("有新功能或服务通知时会出现在这里", 12, Hex(0x96968F)));
                    break;
                default:
                    empty.Children.Add(Line("正在读取公告…", 13, Sub));
                    break;
            }
            Children.Add(empty);
            return;
        }
        var rows = new StackPanel { Margin = new Thickness(12, 0, 12, 8) };
        var ids = center.Items.Select(x => x.Id).ToList();
        for (var index = 0; index < center.Items.Count; index++)
        {
            var item = center.Items[index];
            if (index > 0) rows.Children.Add(Divider());
            var titleLine = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            if (center.FreshIds.Contains(item.Id)) titleLine.Children.Add(new Border { Width = 6, Height = 6, CornerRadius = new CornerRadius(3), Background = Brush(Blue), VerticalAlignment = VerticalAlignment.Center }.Tip("新"));
            if (item.Important) titleLine.Children.Add(ImportantChip());
            titleLine.Children.Add(Label(item.Title, 14, Txt, Medium).Frame(height: 21));
            var top = Spread(titleLine, Label($"{item.CategoryLabel} · {item.DateText}", 11, Hex(0x96968F)), 4);
            var body = VStack(4, top, Label(item.Summary, 13, Sub).Frame(height: 20));
            var first = index == 0;
            var row = new Border { Child = body, Padding = new Thickness(12), Background = Brush(Clear), CornerRadius = new CornerRadius(first ? 10 : 0, first ? 10 : 0, 10, 10) };
            var position = index;
            row.PointerEntered += (_, _) => row.Background = Brush(Field);
            row.PointerExited += (_, _) => row.Background = Brush(Clear);
            row.PointerReleased += (_, _) => _pick(ids, position);
            rows.Children.Add(row);
        }
        var height = Math.Min(480, (XamlRoot?.Size.Height ?? 900) - 120);
        Children.Add(new ScrollViewer { Content = rows, MaxHeight = height, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
    }

    /// <summary>“重要”标签：11/500 #A13A28，#FAEDEA 底，18 高、圆角 5。</summary>
    public static Border ImportantChip() => V3Chip.Make("重要", Hex(0xA13A28), Hex(0xFAEDEA), 18, 11).Also(x => x.Padding = new Thickness(6, 0, 6, 0));
}

/// <summary>
/// 公告详情弹窗（Mac `AnnouncementDetailSheet`）：520 宽；顶部 #EEF3FC 分类带（40×40 白底 70% 图标、分类与日期；不放 ×，Esc 关闭），
/// 标题 20/600 衬线、Markdown 正文（最高 320）；多条时左下分页点（7px，当前 #17191C），右侧“下一条 →”或“知道了”。
/// </summary>
public static class AnnouncementDetail
{
    static V3Overlay? _open;

    public static void Show(WorkspaceShell shell)
    {
        if (_open is { IsOpen: true }) return;
        var center = shell.Announcements;
        var host = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        _open = V3Overlay.Show(shell.XamlRoot, close =>
        {
            void Render()
            {
                var byId = center.Items.ToDictionary(x => x.Id);
                if (center.Detail is not { } detail) { close(); return; }
                var ids = detail.Ids.Where(byId.ContainsKey).ToList();
                var currentId = detail.Index >= 0 && detail.Index < detail.Ids.Count ? detail.Ids[detail.Index] : null;
                if (currentId is null || !byId.TryGetValue(currentId, out var item)) { center.Detail = null; close(); return; }
                var index = ids.IndexOf(currentId);
                void GoTo(int position)
                {
                    if (center.Detail is not { } d || position < 0 || position >= ids.Count) return;
                    var target = d.Ids.IndexOf(ids[position]);
                    if (target < 0) return;
                    center.Detail = (d.Ids, target);
                    Render();
                }

                var categoryRow = HStack(6, Label(item.CategoryLabel, 13, Txt, Medium), item.Important ? AnnouncementListView.ImportantChip() : null);
                var meta = VStack(2, categoryRow, item.DateText.Length > 0 ? Label($"{item.DateText}发布", 11.5, Hex(0x6F6F69)) : null);
                var icon = new Border { Width = 40, Height = 40, CornerRadius = new CornerRadius(10), Background = Brush(Alpha(V3.White, 0.7)),
                    Child = new FontIcon { Glyph = item.CategoryGlyph, FontSize = 18, FontFamily = IconFamily, Foreground = Brush(Txt) } };
                var band = new Border { Background = Brush(0xEEF3FC), Padding = new Thickness(24, 20, 24, 20), Child = Columns(12, (Auto, icon), (Star(), meta.Align(v: VerticalAlignment.Center))) };
                var body = VStack(12, Label(item.Title, 20, Txt, Bold).Wrap(),
                    new ScrollViewer { Content = NativeMarkdownView.Render(item.Body), MaxHeight = 320 }).Pad(24, 20, 24, 24);
                var dots = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                if (ids.Count > 1)
                    for (var position = 0; position < ids.Count; position++)
                    {
                        var p = position;
                        var dot = new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(3.5), Background = Brush(p == index ? 0x17191Cu : 0xD4D4CFu) }.Tip($"第 {p + 1} 条，共 {ids.Count} 条");
                        dot.PointerReleased += (_, _) => GoTo(p);
                        dots.Children.Add(dot);
                    }
                var action = index < ids.Count - 1
                    ? new V3Button("下一条", () => GoTo(index + 1), V3Button.Kind.Dark, icon: "arrow.right")
                    : new V3Button("知道了", () => { center.Detail = null; close(); }, V3Button.Kind.Dark);
                // CommandSpace：#F4F4F1 底、上边细线；Windows 稿弹窗不放 ×，Esc 关闭
                var foot = new Border { Background = Brush(Stage), BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(24), Child = Spread(dots, action) };
                host.Content = VStack(0, band, body, foot);
            }
            Render();
            return V3Dialog.Frame(host, 520);
        }, dismissed: () => center.Detail = null);
    }
}
