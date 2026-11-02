using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

public sealed partial class CareerApplicationDetailView
{
    UIElement ProgressPage()
    {
        var deck = Deck;
        var current = deck.Current ?? deck.Stations[^1];
        var shown = (_viewKey is { } key ? deck.Stations.FirstOrDefault(x => x.Id == key) : null) ?? current;
        var viewing = shown.Id != current.Id;
        var shownIndex = Math.Max(0, deck.Stations.ToList().FindIndex(x => x.Id == shown.Id));

        var column = new StackPanel();
        column.Children.Add(DeckHeader(deck));
        if (_error is { } error)
        {
            var row = HStack(8, Sans(error, 12, PD.Red), new CareerAction("重试", Refresh));
            row.Margin = new Thickness(0, 12, 0, 0);
            column.Children.Add(row);
        }
        if (_notice is { } notice) column.Children.Add(Sans(notice, 12, PD.Body).Wrap().Top(12));
        var rail = new CareerStationRail(deck, Raw, viewing ? shownIndex : -1, _now,
            key => { _viewKey = key == current.Id ? null : key; Render(); },
            toApply => Handle(toApply ? CareerDetailAction.RecordApplied : CareerDetailAction.Advance));
        var card = new CareerStationCard(Raw, deck, shown, shownIndex > 0 ? deck.Stations[shownIndex - 1] : null, _details, viewing, _now,
            _busy || _loading, _prepBusy == shown.Session?.Text("id"), MaterialsCount, action => DeckAction(action, shown));
        if (_lastShown is not null && _lastShown != shown.Id) PD.FadeIn(card);
        _lastShown = shown.Id;
        // 页头到主体 48；左栏 320、与右侧之间 64（窄屏按比例收）
        var body = new Grid { Margin = new Thickness(0, 48, 0, 0) };
        var railColumn = new ColumnDefinition { Width = Px(320) };
        var gapColumn = new ColumnDefinition { Width = Px(64) };
        body.ColumnDefinitions.Add(railColumn);
        body.ColumnDefinitions.Add(gapColumn);
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        rail.VerticalAlignment = VerticalAlignment.Top;
        card.VerticalAlignment = VerticalAlignment.Top;
        body.Children.Add(rail);
        Grid.SetColumn(card, 2);
        body.Children.Add(card);
        column.Children.Add(body);

        var host = new Border { Child = column, Padding = new Thickness(24, 52, 24, 72) };
        var scroll = new ScrollViewer { Content = host, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, IsTabStop = true };
        void Fit(double width)
        {
            var gutter = V3Page.Gutter(width);
            var inner = Math.Max(0, width - gutter * 2);
            host.Padding = new Thickness(gutter, 52, gutter, 72);
            railColumn.Width = Px(Math.Min(320, Math.Max(232, inner * 0.29)));
            gapColumn.Width = Px(Math.Min(64, Math.Max(28, inner * 0.058)));
        }
        scroll.SizeChanged += (_, e) => Fit(e.NewSize.Width);
        if (ActualWidth > 0) Fit(ActualWidth);
        return scroll;
    }

    string? _lastShown;

    /// <summary>页头（`.pd-head`）：返回、岗位详情与更多；公司、职位、标签；右侧三个数字。</summary>
    UIElement DeckHeader(CareerDeck deck)
    {
        var snapshot = Raw.Get("job_snapshot");
        var employment = snapshot.Text("employment_type") switch { "full_time" => "正式", "campus" => "校招", "internship" => "实习", _ => null };
        var city = new[] { snapshot.Text("work_city"), snapshot.Text("city"), snapshot.Text("location") }.FirstOrDefault(x => x.Length > 0);
        var salary = new[] { snapshot.Text("salary_text"), snapshot.Text("salary") }.FirstOrDefault(x => x.Length > 0);
        var summary = string.Join(" · ", new[] { city, salary }.OfType<string>());
        var company = string.Join(" · ", new[] { Item.Company, snapshot.Text("department").NonEmpty() ?? snapshot.Text("department_name") }.Where(x => x.Length > 0));
        var ended = deck.Ended is not null || Raw.Text("archived_at").Length > 0;

        var back = HStack(6, Icon("arrow.left", 13, Fnt), Sans("投递看板", 14, Fnt)).Frame(height: 20);
        back.Background = Brush(Clear);
        back.OnTap(_back, "返回投递看板");
        var job = new Border
        {
            Child = HStack(6, Icon("briefcase", 12, PD.Body), Sans("岗位详情", 14, PD.Body)),
            Padding = new Thickness(10, 0, 10, 0), Height = 28, CornerRadius = Capsule(28), Background = Brush(Clear),
        }.OnTap(OpenJob, "岗位详情");
        var more = new Border { Width = 28, Height = 28, Background = Brush(Clear), Child = Icon("ellipsis", 13, Fnt).Align(HorizontalAlignment.Center, VerticalAlignment.Center) };
        more.OnTap(() => MoreMenu(ended).ShowAt(more, new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight }), "这条投递的操作");
        var tools = HStack(4, job, more);
        tools.RenderTransform = new Microsoft.UI.Xaml.Media.TranslateTransform { Y = -4 };
        var top = Spread(back, tools, 24, VerticalAlignment.Top);

        var title = Serif(Item.Title, 30, PD.Ink).Wrap(2);
        title.MinHeight = 40;
        AutomationProperties.SetName(title, Item.Company + "，" + Item.Title);
        var tags = HStack(8,
            employment is null ? null : new Border { Child = Sans(employment, 12, PD.Body, Medium).Align(v: VerticalAlignment.Center), Padding = new Thickness(8, 0, 8, 0), Height = 22, CornerRadius = new CornerRadius(6), Background = Brush(Hex(0xF5F5F2)) },
            summary.Length == 0 ? null : Sans(summary, 13, PD.Body));
        tags.MinHeight = 22;
        tags.Margin = new Thickness(0, 6, 0, 0);
        var left = VStack(0, Sans(company, 13, PD.Body, Medium).Frame(height: 20), title, tags);
        var latestReview = deck.Stations.Reverse().Select(x => x.Session).OfType<JsonNode>().FirstOrDefault(x => CareerDeck.HasReview(x));
        var stats = HStack(28,
            Stat(deck.DaysLabel, $"{deck.Days}", "天", null),
            Stat("复盘", $"{deck.Reviews}", "篇", () => HandleDeck(new CareerDeckAction.Review(latestReview))),
            Stat("资料", $"{MaterialsCount}", "份", () => Go(new Route.Materials(null))));
        stats.Margin = new Thickness(0, 0, 0, 16);
        var bottom = Spread(left, stats, 24, VerticalAlignment.Bottom);
        bottom.Margin = new Thickness(0, 8, 0, 0);
        return VStack(0, top, bottom);
    }

    MenuFlyout MoreMenu(bool ended)
    {
        var menu = new MenuFlyout();
        MenuFlyoutItem Item(string text, Action run, bool enabled = true)
        {
            var entry = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
            entry.Click += (_, _) => run();
            return entry;
        }
        menu.Items.Add(Item(Raw.Bool("is_favorite") ? "取消收藏" : "收藏", () => _ = ToggleFavorite()));
        var colors = new MenuFlyoutSubItem { Text = "日历颜色" };
        foreach (var (value, label) in new[] { ("blue", "蓝"), ("purple", "紫"), ("green", "绿"), ("orange", "橙"), ("yellow", "黄"), ("red", "红"), ("gray", "灰") })
            colors.Items.Add(Item(label + (Raw.Text("calendar_color") == value ? " ✓" : ""), () => _ = Update(new JsonObject { ["calendar_color"] = value })));
        menu.Items.Add(colors);
        var archived = Raw.Text("archived_at").Length > 0;
        menu.Items.Add(Item(archived ? "取消归档" : "归档", () => _perform(archived ? "restore" : "archive", this.Item)));
        menu.Items.Add(new MenuFlyoutSeparator());
        var delete = Item("删除这条记录", () => _perform("delete", this.Item), ended);
        delete.Foreground = Brush(Red);
        menu.Items.Add(delete);
        return menu;
    }

    static UIElement Stat(string label, string value, string unit, Action? action)
    {
        var number = HStack(3, Label(value, 24, PD.Ink, Medium).Frame(height: 30), Sans(unit, 12.5, PD.Mute).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 5));
        var content = VStack(0, number, Sans(label, 11.5, PD.Mute).Frame(height: 16));
        content.Background = Brush(Clear);
        if (action is not null) content.OnTap(action, label);
        return content;
    }

    int MaterialsCount => _details.Values.Sum(x => x.Items("assets").Count) + (Raw.Text("resume_id").Length == 0 ? 0 : 1);

    void DeckAction(CareerDeckAction action, CareerStation shown)
    {
        if (action is CareerDeckAction.Reschedule) { if (shown.Session is { } session) OpenReschedule(session); }
        else HandleDeck(action);
    }

    void HandleDeck(CareerDeckAction action)
    {
        switch (action)
        {
            case CareerDeckAction.RecordApplied: _perform("apply", Item); break;
            case CareerDeckAction.Advance: _perform("stage", Item); break;
            case CareerDeckAction.Schedule: _perform("schedule-current", Item); break;
            case CareerDeckAction.Reschedule: if (Model.CurrentSession is { } current) OpenReschedule(current); break;
            case CareerDeckAction.RecordOffer or CareerDeckAction.EditOffer or CareerDeckAction.UploadOffer: _perform("offer", Item); break;
            case CareerDeckAction.HandleOffer: _perform("accept", Item); break;
            case CareerDeckAction.EditJob: OpenJob(); break;
            case CareerDeckAction.EditDelivery: _perform("apply", Item); break;
            case CareerDeckAction.Reopen: _ = Reopen(); break;
            case CareerDeckAction.Reject: _ = ConfirmReject(); break;
            case CareerDeckAction.Materials(var id):
            {
                // 面试记录：有记录时直接看，否则到资料页
                var markdown = _details.TryGetValue(id, out var detail) ? detail.Get("session").Text("questions_markdown") : "";
                Go(InterviewRecord.Parse(markdown).Count == 0 ? new Route.Materials(id) : new Route.Record(id, false, null));
                break;
            }
            case CareerDeckAction.AllMaterials: Go(new Route.Materials(null)); break;
            case CareerDeckAction.Review(var session):
                if (session?.Text("id") is { Length: > 0 } reviewId) Go(new Route.Stage(reviewId));
                else { _notice = "这次求职还没有可查看的复盘记录。"; Render(); }
                break;
            case CareerDeckAction.GenerateReview(var session): Go(new Route.Stage(session.Text("id"))); break;
            case CareerDeckAction.PrepOpen(var session): _prepFor = session.Text("id"); ShowPrep(); break;
            case CareerDeckAction.PrepToggle(var session, var index):
            {
                var items = new JsonArray();
                var position = 0;
                foreach (var item in session.Items("prep_items"))
                {
                    var copy = item.DeepClone();
                    if (position++ == index && copy is JsonObject fields) fields["done"] = !item.Bool("done");
                    items.Add(copy);
                }
                _ = SavePrep(session, items);
                break;
            }
            case CareerDeckAction.PrepGenerate(var session): _ = GeneratePrep(session); break;
            case CareerDeckAction.Copy(var text):
            {
                var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
                package.SetText(text);
                Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
                _notice = "已复制";
                Render();
                break;
            }
        }
    }

    /// <summary>有岗位记录时进入完整岗位详情（匹配度、字段编辑）；原岗位已删除时退回只读描述。</summary>
    void OpenJob()
    {
        var id = Raw.Text("job_description_id");
        if (id.Length == 0) ShowJob(); else Go(new Route.Job(id));
    }

    // MARK: 弹窗

    void ShowJob()
    {
        V3Overlay.Show(XamlRoot, close =>
        {
            var text = Sans(_jobDescription ?? "原岗位资料已不可用。", 13, CareerPalette.Sub).Wrap();
            text.IsTextSelectionEnabled = true;
            var sheet = CareerSheet.Make("岗位详情", 720, [text], [new CareerAction("关闭", close, CareerAction.Kind.Primary, large: true)], Item.Company + " · " + Item.Title);
            sheet.Height = 600;
            return sheet;
        });
    }

    void OpenReschedule(JsonNode session)
    {
        V3Overlay? overlay = null;
        overlay = V3Overlay.Show(XamlRoot, close => new CareerRescheduleSheet(session, close, () => { overlay?.Close(); Refresh(); }), dismissible: true);
    }

    bool _reopeningPrep;

    /// <summary>准备清单弹窗（Mac `.sheet(item: prepFor)`）：内容随 prepBusy 与刷新后的场次变化，状态变了就重建。</summary>
    void ShowPrep()
    {
        if (_prepFor is not { } id || _sessions.FirstOrDefault(x => x.Text("id") == id) is not { } entry) return;
        if (_prepOverlay is { IsOpen: true } open) { _reopeningPrep = true; open.Close(); _reopeningPrep = false; }
        var session = CareerSessions.WithEffectiveStatus(_details.TryGetValue(id, out var detail) && detail.Get("session") is { } fresh ? fresh : entry, _now);
        _prepOverlay = V3Overlay.Show(XamlRoot, close => new CareerPrepSheet(session, _prepBusy == id,
            items => _ = SavePrep(session, new JsonArray(items.Select(x => x.DeepClone()).ToArray())),
            () => _ = GeneratePrep(session), close),
            dismissed: () => { if (!_reopeningPrep) { _prepFor = null; _prepOverlay = null; } });
    }

    /// <summary>SwiftUI 的弹窗随状态自动刷新；这里在 prepBusy 或数据变化后重建已打开的准备清单。</summary>
    void RefreshPrep() { if (_prepOverlay is { IsOpen: true }) ShowPrep(); }

    async Task ConfirmReject()
    {
        var deck = Deck;
        var current = deck.Current ?? deck.Stations[^1];
        var shown = (_viewKey is { } key ? deck.Stations.FirstOrDefault(x => x.Id == key) : null) ?? current;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = $"{shown.Short}没通过？", Content = "这条投递会结束，记录会一直保留，复盘可以在之后的投递里继续参考。",
            PrimaryButtonText = "记为没通过", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await Terminate("company_rejected");
    }
}
