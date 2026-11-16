using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Shell;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>
/// 投递详情（Windows 稿 07 页 04–09 分区，Mac `progressPage`）：顶部返回 + 岗位详情 + ⋯；
/// 左边「这一步」（结论、说明、地点、资料、按钮），右边按阶段换内容，底部全程时间线，点过去的节点回看那一轮。
/// </summary>
public sealed partial class CareerApplicationDetailView
{
    UIElement ProgressPage()
    {
        var deck = Deck;
        var current = deck.Current ?? deck.Stations[^1];
        var shown = (_viewKey is { } key ? deck.Stations.FirstOrDefault(x => x.Id == key) : null) ?? current;
        var viewing = shown.Id != current.Id;
        var shownIndex = Math.Max(0, deck.Stations.ToList().FindIndex(x => x.Id == shown.Id));
        var previous = shownIndex > 0 ? deck.Stations[shownIndex - 1] : null;
        var session = shown.Session is { } s && s.Text("status") != "cancelled" ? s : null;
        var detail = session is null ? null : _details.GetValueOrDefault(session.Text("id"));
        var step = CareerJourney.Step(Raw, deck, shown, viewing, _now, detail, previous, _reviewCost);
        var timeline = CareerJourney.Build(Raw, deck, _now);
        var files = session is null ? new List<JsonNode>() : detail.Items("assets");
        // 右侧已经有黑按钮（上传录音、生成准备清单）时，左边只留白按钮
        var prepEmpty = session is not null && session.Items("prep_items").Count == 0 && session.Get("prep_generated_at") is null;
        var sideHasBlack = step.Side == CareerJourneySide.RecordEntry || (step.Side == CareerJourneySide.Prep && prepEmpty);

        var column = new StackPanel();
        column.Children.Add(TopBar(deck));
        if (_error is { } error)
            column.Children.Add(HStack(10, Sans(error, 12, PD.Red).Align(v: VerticalAlignment.Center), new PDButton("重试", Refresh)).Top(12));
        if (_notice is { } notice)
        {
            var close = Icon("xmark", 9, PD.Mute).Align(v: VerticalAlignment.Center).OnTap(() => { _notice = null; Render(); }, "关闭提示");
            column.Children.Add(HStack(10, Sans(notice, 12.5, PD.Body).Wrap().Align(v: VerticalAlignment.Center), close).Top(12));
        }

        var hero = CareerJourneyUI.Hero(Item.Company + " · " + Item.Title, step, files, sideHasBlack, _busy || _loading,
            action => JourneyAction(action, session), Copy, OpenAsset,
            () => { if (session is not null) PickFiles(session); },
            () => { if (session is not null) OpenAdd(session, CareerAddContentSheet.Mode.Library); });
        if (_lastShown is not null && _lastShown != shown.Id + viewing) PD.FadeIn(hero);
        _lastShown = shown.Id + viewing;
        var side = SideView(step.Side, deck, shown, session, detail);

        // 宽 ≥ 900：左 500、右 420 两栏居中对齐；窄时上下排
        var body = new Grid { Margin = new Thickness(0, 48, 0, 0) };
        void Arrange(double width)
        {
            body.Children.Clear();
            body.ColumnDefinitions.Clear();
            body.RowDefinitions.Clear();
            hero.HorizontalAlignment = HorizontalAlignment.Left;
            if (side is not null) side.HorizontalAlignment = HorizontalAlignment.Stretch;
            if (width >= 900)
            {
                body.ColumnSpacing = 48;
                body.ColumnDefinitions.Add(new ColumnDefinition { Width = Star(), MaxWidth = 500 });
                body.ColumnDefinitions.Add(new ColumnDefinition { Width = Star(0.0001) });
                body.ColumnDefinitions.Add(new ColumnDefinition { Width = Star(), MaxWidth = 420 });
                hero.VerticalAlignment = VerticalAlignment.Center;
                body.Children.Add(hero);
                if (side is not null)
                {
                    side.VerticalAlignment = VerticalAlignment.Center;
                    Grid.SetColumn(side, 2);
                    body.Children.Add(side);
                }
            }
            else
            {
                body.ColumnSpacing = 0;
                body.RowSpacing = 44;
                body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                body.Children.Add(hero);
                if (side is not null)
                {
                    side.MaxWidth = 560;
                    side.HorizontalAlignment = HorizontalAlignment.Left;
                    Grid.SetRow(side, 1);
                    Grid.SetColumn(side, 0);
                    body.Children.Add(side);
                }
            }
        }
        column.Children.Add(body);
        var line = new CareerJourneyTimeline(timeline, viewing ? shown.Id : null, picked => { _viewKey = picked == current.Id ? null : picked; Render(); });
        line.Margin = new Thickness(0, 64, 0, 0);
        column.Children.Add(line);

        var host = new Border { Child = column, Padding = new Thickness(40, 40, 40, 50) };
        var scroll = new ScrollViewer { Content = host, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, IsTabStop = true };
        double arranged = -1;
        void Fit(double width)
        {
            // 稿：内容区 1178 宽时左右各 63，主体 500 + 420 两栏；更宽时内容最多 1200
            var gutter = Math.Max(Math.Max(40, width * 0.0535), (width - 1200) / 2);
            var inner = Math.Max(0, width - gutter * 2);
            host.Padding = new Thickness(gutter, 40, gutter, 50);
            host.MinHeight = Math.Max(0, scroll.ActualHeight - 40);
            var wide = inner >= 900 ? 1 : 0;
            if (wide != arranged) { arranged = wide; Arrange(inner); }
        }
        scroll.SizeChanged += (_, e) => Fit(e.NewSize.Width);
        Fit(ActualWidth > 0 ? ActualWidth : 1180);
        return scroll;
    }

    string? _lastShown;
    string? _reviewCost, _prepCost;
    bool _pricesLoaded;

    /// <summary>顶部：左上统一返回，右上「岗位详情」文字按钮 + ⋯ 菜单（09.07 / 09.08）。</summary>
    UIElement TopBar(CareerDeck deck)
    {
        var back = CareerJourneyUI.TextButton("← 投递看板", _back, 13, JS.Sub);
        AutomationProperties.SetName(back, "返回投递看板");
        var more = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(14), Background = Brush(Clear), Child = Label("⋯", 16, PD.Body, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center) };
        more.OnTap(() =>
        {
            more.Background = Brush(Hex(0xEDEDEA));
            Flyout? flyout = null;
            var menu = new CareerDetailMenu(MenuItems(deck), Raw.Text("calendar_color"), color => { flyout?.Hide(); _ = Update(new JsonObject { ["calendar_color"] = color }); }, () => flyout?.Hide());
            flyout = V3Popover.Show(more, menu, FlyoutPlacementMode.BottomEdgeAlignedRight, 6);
            flyout.Closed += (_, _) => more.Background = Brush(Clear);
        }, "这条投递的操作");
        var tools = HStack(14, CareerJourneyUI.TextButton("岗位详情", OpenJob).Align(v: VerticalAlignment.Center), more);
        return Columns(16, (Star(), back.Align(v: VerticalAlignment.Center)), (Auto, tools)).Frame(height: 28);
    }

    /// <summary>09.07 / 09.08 ⋯ 里的编辑类操作；删除在结束或归档后才能点。</summary>
    List<CareerDetailMenu.Item> MenuItems(CareerDeck deck)
    {
        var archived = Raw.Text("archived_at").Length > 0;
        var ended = deck.Ended is not null || archived;
        var currentKind = deck.Current?.Kind;
        var offerMenu = currentKind is CareerStationKind.Offer or CareerStationKind.Oc || deck.Ended?.Kind is CareerDeckEndedKind.Accepted or CareerDeckEndedKind.Declined;
        var items = new List<CareerDetailMenu.Item> { new("编辑投递信息", () => _perform("apply", Item)) };
        if (offerMenu) items.Add(new("编辑 Offer 信息", () => _perform("offer", Item)));
        items.Add(new(Raw.Bool("is_favorite") ? "取消收藏" : "收藏", () => _ = ToggleFavorite()));
        items.Add(new("日历颜色", () => { }, Colors: true));
        items.Add(new(archived ? "取消归档" : "归档", () => _perform(archived ? "restore" : "archive", Item)));
        items.Add(new("删除这条投递", () => _ = ConfirmDelete(deck), Danger: true, Enabled: ended));
        return items;
    }

    FrameworkElement? SideView(CareerJourneySide side, CareerDeck deck, CareerStation shown, JsonNode? session, JsonNode? detail)
    {
        var id = session?.Text("id");
        return side switch
        {
            CareerJourneySide.Resume => new CareerJourneyResumeSide(Raw, deck.Pending, OpenResume, () => _perform("apply", Item)),
            CareerJourneySide.Prep => new CareerJourneyPrepSide(shown.Short, session is null ? null : detail.Get("session") ?? session, _prepBusy is not null && _prepBusy == id, _prepCost,
                items => { if (session is not null) _ = SavePrep(session, new JsonArray(items.ToArray())); },
                () => { if (session is not null) _ = GeneratePrep(session); }, Practice),
            CareerJourneySide.RecordEntry when session is not null => CareerJourneyUI.RecordEntrySide(CareerJourney.Record(session, detail), _busy,
                () => PickFiles(session), () => Go(new Route.Record(session.Text("id"), true, null)), dataset => _ = RetryTranscription(session, dataset)),
            CareerJourneySide.Questions when session is not null => new CareerJourneyQuestionsSide(session, detail, _ => Go(new Route.Record(session.Text("id"), false, null))),
            CareerJourneySide.Review when session is not null => CareerJourneyUI.ReviewSide(session, detail, () => OpenReview(session), Practice),
            // 笔试题页还没做成单独页面：先进阶段详情看题
            CareerJourneySide.Written when session is not null => CareerJourneyUI.WrittenSide(session, detail, () => Go(new Route.Stage(session.Text("id"))), () => Go(new Route.Stage(session.Text("id")))),
            CareerJourneySide.Offer => CareerJourneyUI.OfferSide(Raw, false, deck.Ended?.Kind == CareerDeckEndedKind.Accepted),
            CareerJourneySide.Oc => CareerJourneyUI.OfferSide(Raw, true, false),
            CareerJourneySide.Left => CareerJourneyUI.LeftSide(deck, _details, () => OpenReview(null), Practice),
            _ => null,
        };
    }

    void JourneyAction(CareerJourneyAction action, JsonNode? session)
    {
        switch (action)
        {
            case CareerJourneyAction.RecordApplied: _perform("apply", Item); break;
            case CareerJourneyAction.Advance: _perform("stage", Item); break;
            case CareerJourneyAction.Schedule: _perform("schedule-current", Item); break;
            case CareerJourneyAction.Reschedule: if ((session ?? Model.CurrentSession) is { } target) OpenReschedule(target); break;
            case CareerJourneyAction.RecordOffer: _perform("offer", Item); break;
            case CareerJourneyAction.EditOffer: _perform("offer", Item); break;
            case CareerJourneyAction.Decide: Decide(); break;
            case CareerJourneyAction.Reopen: _ = Reopen(); break;
            case CareerJourneyAction.BackToNow: _viewKey = null; Render(); break;
            case CareerJourneyAction.OpenSource: if (CareerJourney.SourceUrl(Raw) is { } source) _ = Windows.System.Launcher.LaunchUriAsync(source); break;
            case CareerJourneyAction.Enter:
                if (Uri.TryCreate(session?.Text("meeting_url") ?? "", UriKind.Absolute, out var meeting)) _ = Windows.System.Launcher.LaunchUriAsync(meeting);
                break;
            case CareerJourneyAction.Mock: WorkspaceShell.Current.Practice(null); break;
            case CareerJourneyAction.GenerateReview: if (session?.Text("id") is { Length: > 0 } reviewId) Go(new Route.Stage(reviewId)); break;
            case CareerJourneyAction.OpenReview: OpenReview(session); break;
            case CareerJourneyAction.OpenRecord: if (session?.Text("id") is { Length: > 0 } recordId) Go(new Route.Record(recordId, false, null)); break;
            case CareerJourneyAction.OpenWritten: if (session?.Text("id") is { Length: > 0 } writtenId) Go(new Route.Stage(writtenId)); break;
        }
    }

    /// <summary>打开复盘：优先看的这一轮，否则最近一份复盘。</summary>
    void OpenReview(JsonNode? session)
    {
        var target = (session is not null && CareerDeck.HasReview(session) ? session : null)
            ?? Deck.Stations.Reverse().Select(x => x.Session).OfType<JsonNode>().FirstOrDefault(CareerDeck.HasReview);
        if (target?.Text("id") is { Length: > 0 } id) Go(new Route.Report(id));
        else { _notice = "这次求职还没有可查看的复盘记录。"; Render(); }
    }

    /// <summary>「去练这一处」：带着这一处进模拟面试（kind topic、ref 与 label 都是这一处的标题）。</summary>
    static void Practice(string label)
    {
        var topic = label.Trim();
        WorkspaceShell.Current.Practice(topic.Length == 0 ? null : new PracticeFocus("topic", topic, topic));
    }

    void OpenResume()
    {
        if (Raw.Text("resume_id") is { Length: > 0 } id) WorkspaceShell.Current.EditResume(id);
    }

    void Copy(string text)
    {
        var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
        package.SetText(text);
        Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
        _notice = "已复制";
        Render();
    }

    /// <summary>打开这一轮的资料：下载到临时目录后用系统默认程序打开。</summary>
    async void OpenAsset(JsonNode asset)
    {
        try
        {
            var file = await App.Session.Api.DownloadDatasetAsync(asset.Text("id"), 512L * 1024 * 1024, default);
            var name = asset.Text("original_file_name").NonEmptyOr(Path.GetFileName(file.File));
            var named = Path.Combine(file.Directory, string.Concat(name.Split(Path.GetInvalidFileNameChars())));
            if (named != file.File && !File.Exists(named)) File.Move(file.File, named);
            var storage = await Windows.Storage.StorageFile.GetFileFromPathAsync(File.Exists(named) ? named : file.File);
            await Windows.System.Launcher.LaunchFileAsync(storage);
        }
        catch (Exception error) { Unauthorized(error); _notice = CareerErrors.Message(error); Render(); }
    }

    /// <summary>从电脑选资料（07.03「＋ 添加」、07.01「上传录音」）：Windows 走添加内容弹窗的上传页。</summary>
    void PickFiles(JsonNode session) => OpenAdd(session, CareerAddContentSheet.Mode.Upload);

    /// <summary>09.03 做决定：460 宽，只写这份 Offer、答复截止、接受后会怎样；无 ×，Esc 关闭。</summary>
    void Decide()
    {
        var due = CareerJourney.OfferDate(Raw.Text("offer_reply_due_on"));
        V3Overlay.Show(XamlRoot, close =>
        {
            var summary = string.Join(" · ", new[] { CareerJourney.OfferSalary(Raw) is { } salary ? "这份 Offer：" + salary : null, due is { } d ? "答复截止 " + CareerDeckFormat.MonthDay(d) : null }.OfType<string>());
            var stack = VStack(0, Label($"处理「{Item.Company}」的 Offer", 20, PD.Ink, Semibold).Wrap());
            if (summary.Length > 0) stack.Children.Add(Sans(summary, 13, PD.Body).Wrap().Top(10));
            stack.Children.Add(Sans("接受或婉拒后，这条投递会结束；各站记录、资料和复盘都会保留。", 13, PD.Body).LineHeight(21).Wrap().Top(6));
            var buttons = HStack(10,
                new PDButton("再想想", close, enabled: !_busy),
                new PDButton("婉拒", () => { close(); _ = DecideAsync("declined"); }, enabled: !_busy),
                new PDButton("接受 Offer", () => { close(); _ = DecideAsync("accepted"); }, PDButton.Kind.Primary, enabled: !_busy));
            buttons.HorizontalAlignment = HorizontalAlignment.Right;
            stack.Children.Add(buttons.Top(24));
            return new Border
            {
                Child = stack, Width = 460, Padding = new Thickness(24), CornerRadius = new CornerRadius(8),
                Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            };
        });
    }

    /// <summary>删除确认（Web `ImpactConfirmDialog`）：写清会删除什么、会保留什么。</summary>
    async Task ConfirmDelete(CareerDeck deck)
    {
        var reviews = _sessions.Count(CareerDeck.HasReview);
        var files = _details.Values.Sum(x => x.Items("assets").Count);
        var removed = string.Join("、", new[] { $"{deck.Stations.Count} 站记录", "面试记录", "笔试题", reviews > 0 ? $"{reviews} 篇复盘" : null }.OfType<string>());
        var kept = files > 0 ? $"资料库里的 {files} 份文件（只是不再关联这条投递）" : "资料库里的文件";
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "删除这条投递？", Content = $"删除后无法恢复。岗位也会从岗位看板上移除。\n会删除：{removed}\n会保留：{kept}",
            PrimaryButtonText = "删除", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) _perform("delete", Item);
    }

    /// <summary>有岗位记录时进入完整岗位详情（10.01）；原岗位已删除时退回只读描述。</summary>
    void OpenJob()
    {
        var id = Raw.Text("job_description_id");
        if (id.Length == 0) ShowJob(); else Go(new Route.Job(id));
    }

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
}
