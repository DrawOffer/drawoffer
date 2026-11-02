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
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>Mac `JobAction`：打开求职表单的一次请求（导入、推进阶段、终止等）。</summary>
public sealed record JobAction(string Kind, CareerApplication? Application)
{
    public string Stage { get; init; } = "interview";
    public string Label { get; init; } = "一面";
    public int? Round { get; init; }
    public DateTimeOffset? Start { get; init; }
    public DateTimeOffset? End { get; init; }
    /// <summary>Web 480 宽的投递弹窗：待投递卡片拖到「筛选中」时只需要日期和渠道。</summary>
    public bool Compact { get; init; }
}

/// <summary>
/// 04.1 投递看板，对应 Mac `JobsBoardView.swift`：页头、四个统计、看板 / 列表工具栏、阶段栏与卡片。
/// 对应 Web `InterviewCenterPage`（ApplicationsHeader / ApplicationViewControls）与 `ApplicationsBoard.tsx`。
/// </summary>
public sealed partial class JobsBoardView : UserControl
{
    readonly Action _requireAccount;
    readonly Grid _root = new();
    List<CareerApplication> _applications = [];
    List<JsonNode> _sessions = [];
    JsonNode? _overview;
    readonly Dictionary<string, ImageSource> _logos = [];
    readonly HashSet<string> _pendingLogos = [];
    bool _loading, _stagesOpen, _earliest, _grouped, _active;
    string? _failure, _notice, _pendingAction, _hoveredCard;
    string _query = "", _mode = "board";
    readonly HashSet<string> _hidden = [];
    List<string> _order = [];
    CareerApplication? _selected;
    int _generation;
    readonly V3SearchField _search = new("搜索公司、岗位…", width: 180, height: 30);
    static readonly (string Key, string Label)[] Categories = [("internship", "实习"), ("campus", "校招"), ("full_time", "正式"), ("", "未分类")];

    /// <summary>其他页面（岗位广场）要求打开的求职进程；加载完成后进入详情并清空（Mac `openApplication`）。</summary>
    public static string? OpenApplication { get; set; }

    static string Account => App.Session.Phase == Core.Session.SessionViewModel.SessionPhase.SignedIn ? App.Session.User?.Id ?? "" : "";

    public JobsBoardView(Action requireAccount)
    {
        _requireAccount = requireAccount;
        _search.Changed += text => { _query = text; RenderContent(); };
        Content = _root;
        Loaded += async (_, _) => { _active = true; await LoadAsync(); };
        Unloaded += (_, _) => _active = false;
        Render();
    }

    List<string> AllColumns
    {
        get
        {
            var available = CareerStage.Columns(_applications);
            return _order.Where(available.Contains).Concat(available.Where(c => !_order.Contains(c))).ToList();
        }
    }

    List<CareerApplication> Visible
    {
        get
        {
            var needle = _query.Trim();
            return CareerStage.Sorted(_applications.Where(item => needle.Length == 0 ||
                new[] { item.Company, item.Title, CareerBoard.Projection(item.Raw).StageLabel }.Any(x => x.Contains(needle, StringComparison.CurrentCultureIgnoreCase))), _earliest).ToList();
        }
    }

    string ColumnStage(string column) => _applications.FirstOrDefault(a => a.Column == column)?.Stage ?? (column.StartsWith("interview:") ? "interview" : column);
    static string ColumnTitle(string column) => column.StartsWith("interview:") ? column[10..] : CareerStage.Label(column);
    static bool Completed(CareerApplication item) => item.CompletedSchedule is not null;

    // MARK: 布局

    readonly Grid _content = new();

    void Render()
    {
        _root.Children.Clear();
        if (_selected is { } selected)
        {
            _root.Children.Add(new CareerApplicationDetailView(selected, () => { _selected = null; Render(); _ = LoadAsync(); }, (kind, app) =>
            {
                var next = CareerStage.NextStages(app);
                Open(new JobAction(kind, app)
                {
                    Stage = kind == "apply" ? "screening" : kind == "schedule-current" ? app.Stage : next.FirstOrDefault(s => s == "interview") ?? next.FirstOrDefault() ?? "screening",
                    Label = kind == "stage" ? RoundLabel(app.Raw.Integer("current_round_no") + 1) : app.StageLabel,
                    Round = kind == "schedule-current" ? app.Raw.Integer("current_round_no") : null,
                });
            }));
            return;
        }
        var page = new Grid();
        for (var i = 0; i < 3; i++) page.RowDefinitions.Add(new RowDefinition { Height = Auto });
        page.RowDefinitions.Add(new RowDefinition { Height = Star() });
        page.Children.Add(V3PageHead.Make(["JOBS", "本周 " + WeekLabel], "投递看板", Subtitle, subtitleHeight: 20,
            actions: [new V3Button("导入岗位", () => OpenKind("import"), V3Button.Kind.Dark, width: 100)]));
        var stats = Statistics().Top(29);
        Grid.SetRow(stats, 1); page.Children.Add(stats);
        if (_notice is { } notice)
        {
            var close = Icon("xmark", 10, Fnt).OnTap(() => { _notice = null; Render(); }, "关闭提示");
            var bar = new Border
            {
                Child = Spread(Sans(notice, 12.5, Txt), close, 10), Padding = new Thickness(14, 0, 14, 0), Height = 36,
                Background = Brush(OrangeSoft), CornerRadius = new CornerRadius(8), Margin = new Thickness(0, 14, 0, 0),
            };
            Grid.SetRow(bar, 2); page.Children.Add(bar);
        }
        Grid.SetRow(_content, 3);
        page.Children.Add(_content);
        RenderContent();
        // Web `.v3-page` 容器宽度分档（与 V3Page 相同的左右留白）；看板要撑满高度，所以不套 V3Page 的滚动
        var host = new Border { Child = page, Padding = new Thickness(32, 52, 32, 20) };
        host.SizeChanged += (_, e) => { var gutter = Math.Max(0, V3Page.Gutter(e.NewSize.Width)); host.Padding = new Thickness(gutter, 52, gutter, 20); };
        _root.Children.Add(host);
    }

    void RenderContent()
    {
        _content.Children.Clear();
        _content.RowDefinitions.Clear();
        if (_loading)
        {
            _content.Children.Add(HStack(8, new ProgressRing { Width = 16, Height = 16, IsActive = true }, Sans("正在加载求职数据…", 13)).Align(HorizontalAlignment.Center, VerticalAlignment.Center));
            return;
        }
        if (_failure is { } failure)
        {
            _content.Children.Add(VStack(16, Sans(failure, 13, Red).Align(HorizontalAlignment.Center),
                new V3Button("重试", () => _ = LoadAsync()).Align(HorizontalAlignment.Center)).Align(HorizontalAlignment.Center, VerticalAlignment.Center));
            return;
        }
        _content.RowDefinitions.Add(new RowDefinition { Height = Auto });
        _content.RowDefinitions.Add(new RowDefinition { Height = Star() });
        // Web：没有任何求职进程时不显示看板 / 列表与排序筛选
        if (_applications.Count > 0) _content.Children.Add(Controls().Pad(0, 20, 0, 18));
        var visible = Visible;
        FrameworkElement body = visible.Count == 0 ? Empty() : _mode == "list" ? List(visible) : BoardArea(visible);
        Grid.SetRow(body, 1);
        _content.Children.Add(body);
    }

    // MARK: 页头与统计

    static DateTimeOffset WeekStart
    {
        get
        {
            // Calendar.firstWeekday = 2：周一为一周开始
            var today = Beijing.Now;
            var start = new DateTimeOffset(today.Date, today.Offset);
            return start.AddDays(-(((int)today.DayOfWeek + 6) % 7));
        }
    }

    static string WeekLabel => WeekStart.ToString("MM-dd") + " 至 " + WeekStart.AddDays(6).ToString("MM-dd");
    int ActiveCount => _applications.Count(a => a.Raw.Text("status") == "active" && a.Raw.Text("archived_at").Length == 0 && a.Raw.Text("lifecycle_status") != "terminated");

    int WeeklyInterviews
    {
        get
        {
            if (_overview.Get("metrics").Get("weekly_interviews") is { } value) return (int)(value.Number() ?? 0);
            var end = WeekStart.AddDays(7);
            return _sessions.Count(s => s.Text("status") != "cancelled" && CareerApplication.Date(s.Text("start_at")) is { } at && at >= WeekStart && at < end);
        }
    }

    int PendingOffers => _applications.Count(a => a.Raw.Text("current_stage_type") == "offer" && a.Raw.Text("offer_status") == "received" && a.Raw.Text("status") == "active");

    string Subtitle => Account.Length == 0 || _loading ? "登录后查看你的求职进程" : $"{WeeklyInterviews} 场面试" + (PendingOffers > 0 ? $" · {PendingOffers} 个 Offer 待回复" : "");

    FrameworkElement Statistics()
    {
        // Web `summarizeApplicationFunnel`：已投递为基数；进过面试 / HR / Offer 阶段算进面，到了 Offer 算拿到 Offer
        var applied = _applications.Where(a => a.Raw.Text("phase") != "pending").ToList();
        var reached = applied.Count(a => a.Raw.Bool("reached_interview") || a.Raw.Text("current_stage_type") is "interview" or "hr" or "offer");
        var offered = applied.Count(a => a.Raw.Text("current_stage_type") == "offer");
        var ready = Account.Length > 0 && !_loading;
        static string Percent(int part, int whole) => $"{(int)Math.Round((double)part / whole * 100, MidpointRounding.AwayFromZero)}%";
        (string title, string value, (string, string)? rate)[] values =
        [
            ("投递总数", ready ? $"{applied.Count}" : "—", null),
            ("进行中", ready ? $"{ActiveCount}" : "—", null),
            ("进入面试", ready ? $"{reached}" : "—", ready && applied.Count > 0 ? ("进面率", Percent(reached, applied.Count)) : null),
            ("Offer", ready ? $"{offered}" : "—", ready && reached > 0 ? ("面试通过率", Percent(offered, reached)) : null),
        ];
        var row = new Grid { Height = 59 };
        for (var i = 0; i < values.Length; i++)
        {
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            var (title, value, rate) = values[i];
            var top = HStack(8, Number(value, 28, Txt));
            if (rate is { } r)
            {
                var text = new TextBlock { FontSize = 12, FontFamily = SansFamily, FontWeight = Medium };
                text.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = r.Item1 + " ", Foreground = Brush(Fnt) });
                text.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = r.Item2, FontFamily = new FontFamily("Segoe UI"), FontWeight = Semibold, Foreground = Brush(Txt) });
                top.Children.Add(text);
            }
            var cell = VStack(5, top.Frame(height: 36), Sans(title, 12, Fnt));
            cell.Padding = new Thickness(i == 0 ? 0 : 20, 0, 0, 0);
            var box = new Grid { Children = { cell } };
            if (i > 0) box.Children.Add(new Border { Width = 1, Background = Brush(V3.Line), HorizontalAlignment = HorizontalAlignment.Left });
            Grid.SetColumn(box, i);
            row.Children.Add(box);
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, "投递看板统计");
        return new Border { Child = row, Padding = new Thickness(0, 0, 0, 13), BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 0, 0, 1) };
    }

    // MARK: 工具栏

    FrameworkElement Controls()
    {
        var mode = new V3Segmented<string>([("board", "看板"), ("list", "列表")], _mode, segmentWidth: 60).Tip("显示方式");
        mode.Changed += value => { _mode = value; RenderContent(); };
        FrameworkElement sort = null!;
        sort = ToolbarLink("排序", "list.bullet").OnTap(() =>
        {
            var menu = new MenuFlyout();
            var recent = new ToggleMenuFlyoutItem { Text = "最近排期", IsChecked = !_earliest };
            recent.Click += (_, _) => { _earliest = false; RenderContent(); };
            var first = new ToggleMenuFlyoutItem { Text = "最先添加", IsChecked = _earliest };
            first.Click += (_, _) => { _earliest = true; RenderContent(); };
            var refresh = new MenuFlyoutItem { Text = "刷新岗位" };
            refresh.Click += (_, _) => _ = LoadAsync();
            menu.Items.Add(recent); menu.Items.Add(first); menu.Items.Add(new MenuFlyoutSeparator()); menu.Items.Add(refresh);
            menu.ShowAt(sort);
        }, "排序");
        FrameworkElement filter = null!;
        filter = ToolbarLink(_hidden.Count == 0 && !_grouped ? "筛选" : "筛选 · 已启用", "line.3.horizontal.decrease")
            .OnTap(() => V3Popover.Show(filter, FilterPanel()), "视图设置");
        if (_search.Parent is Panel old) old.Children.Remove(_search);
        return Spread(mode, HStack(18, _search, sort, filter), 16).Frame(height: 30);
    }

    static FrameworkElement ToolbarLink(string title, string icon) =>
        HStack(5, Icon(icon, 12, Fnt), Sans(title, 14, Sub)).Also(s => { s.Height = 28; s.Background = Brush(Clear); });

    FrameworkElement FilterPanel()
    {
        var panel = new StackPanel { Width = 240, Padding = new Thickness(6) };
        void Rebuild()
        {
            panel.Children.Clear();
            var group = new ComboBox { Items = { "不分组", "求职分类" }, SelectedIndex = _grouped ? 1 : 0, FontSize = 12, MinHeight = 0 };
            group.SelectionChanged += (_, _) => { _grouped = group.SelectedIndex == 1; RenderContent(); };
            panel.Children.Add(FilterField("分组", group));
            var sort = new ComboBox { Items = { "最近排期", "最先添加" }, SelectedIndex = _earliest ? 1 : 0, FontSize = 12, MinHeight = 0 };
            sort.SelectionChanged += (_, _) => { _earliest = sort.SelectedIndex == 1; RenderContent(); };
            panel.Children.Add(FilterField("排序", sort));
            if (_mode != "board") return;
            panel.Children.Add(Divider().Pad(0, 4, 0, 4));
            var toggle = Spread(Sans("展示阶段", 12.5, Txt), Icon(_stagesOpen ? "chevron.up" : "chevron.down", 10, Fnt));
            toggle.Padding = new Thickness(10, 0, 10, 0);
            toggle.Height = 34;
            toggle.Background = Brush(Clear);
            panel.Children.Add(toggle.OnTap(() => { _stagesOpen = !_stagesOpen; Rebuild(); }, "展示阶段"));
            if (!_stagesOpen) return;
            var list = new StackPanel();
            foreach (var column in AllColumns)
            {
                var box = new CheckBox { Content = Sans(ColumnTitle(column), 12.5, Txt), IsChecked = !_hidden.Contains(column), Height = 34, MinHeight = 0, Padding = new Thickness(6, 0, 0, 0), Margin = new Thickness(10, 0, 10, 0) };
                var key = column;
                box.Click += (_, _) => { if (box.IsChecked == true) _hidden.Remove(key); else _hidden.Add(key); RenderContent(); };
                list.Children.Add(box);
            }
            panel.Children.Add(new ScrollViewer { Content = list, MaxHeight = 260 });
        }
        Rebuild();
        return panel;
    }

    static FrameworkElement FilterField(string title, FrameworkElement content)
    {
        var row = HStack(8, Sans(title, 12, Sub).Frame(width: 44), content);
        row.Padding = new Thickness(6, 4, 6, 4);
        return row;
    }

    // MARK: 看板

    FrameworkElement BoardArea(List<CareerApplication> visible)
    {
        var host = new Grid();
        void Build(double width, double height)
        {
            host.Children.Clear();
            var column = Math.Min(280, Math.Max(220, (width - 40) / 5));
            if (_grouped)
            {
                var stack = new StackPanel { Spacing = 24, Padding = new Thickness(0, 0, 0, 24) };
                foreach (var (key, label) in Categories)
                {
                    var items = visible.Where(x => x.Category == key || (key.Length == 0 && x.Category is not ("internship" or "campus" or "full_time"))).ToList();
                    stack.Children.Add(VStack(6, HStack(8, Sans(label, 12, Txt, Medium), Sans($"{items.Count}", 11, Fnt)), Board(items, column, null)));
                }
                host.Children.Add(new ScrollViewer { Content = stack, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
            }
            else
                host.Children.Add(new ScrollViewer
                {
                    Content = Board(visible, column, Math.Max(320, height - 4)), HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                    VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                });
        }
        host.SizeChanged += (_, e) => { if (Math.Abs(e.NewSize.Width - e.PreviousSize.Width) > 0.5 || Math.Abs(e.NewSize.Height - e.PreviousSize.Height) > 0.5) Build(e.NewSize.Width, e.NewSize.Height); };
        return host;
    }

    FrameworkElement Board(List<CareerApplication> items, double width, double? height)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Top };
        foreach (var column in AllColumns.Where(c => !_hidden.Contains(c)))
        {
            var matches = items.Where(x => x.Column == column).ToList();
            var key = column;
            var head = HStack(7, new Ellipse { Width = 7, Height = 7, Fill = Brush(ColumnTone(column)) },
                Sans(ColumnTitle(column), 12, Txt, Medium), Sans($"{matches.Count}", 11, Fnt, Medium));
            head.Padding = new Thickness(6, 0, 6, 0);
            head.Height = 40;
            head.Background = Brush(Clear);
            ToolTipService.SetToolTip(head, "拖动调整栏目位置");
            head.CanDrag = true;
            head.DragStarting += (_, e) => e.Data.SetText("column:" + key);
            var menu = new MenuFlyout();
            var left = new MenuFlyoutItem { Text = "向左移动" }; left.Click += (_, _) => MoveColumn(key, -1);
            var right = new MenuFlyoutItem { Text = "向右移动" }; right.Click += (_, _) => MoveColumn(key, 1);
            menu.Items.Add(left); menu.Items.Add(right);
            head.ContextFlyout = menu;
            var cards = new StackPanel { Spacing = 8 };
            if (matches.Count == 0) cards.Children.Add(Sans("暂无进程", 11, Fnt2).Pad(2, 12, 2, 0));
            foreach (var item in matches) cards.Children.Add(Card(item));
            UIElement scroller = height is null ? cards : new ScrollViewer { Content = cards, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden };
            var grid = new Grid { Width = width, Padding = new Thickness(6, 0, 6, 6), Background = Brush(V3.Column), CornerRadius = new CornerRadius(10), AllowDrop = true, VerticalAlignment = VerticalAlignment.Top };
            grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
            grid.Children.Add(head);
            Grid.SetRow((FrameworkElement)scroller, 1);
            grid.Children.Add(scroller);
            if (height is { } h) grid.Height = h; else grid.MinHeight = 160;
            grid.DragOver += (_, e) => e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Move;
            grid.Drop += async (_, e) =>
            {
                if (!e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text)) return;
                DropValue(await e.DataView.GetTextAsync(), key);
            };
            row.Children.Add(grid);
        }
        return row;
    }

    bool DropValue(string value, string column)
    {
        if (value.StartsWith("column:"))
        {
            var source = value[7..];
            var columns = AllColumns;
            int from = columns.IndexOf(source), to = columns.IndexOf(column);
            if (source == column || from < 0 || to < 0) return false;
            columns.RemoveAt(from); columns.Insert(to, source); _order = columns;
            RenderContent();
            return true;
        }
        var id = value.StartsWith("job:") ? value[4..] : value.StartsWith("locked:") ? value[7..] : "";
        if (_applications.FirstOrDefault(a => a.Id == id) is not { } item || item.Column == column) return false;
        if (DropBlockReason(item, column) is { } reason) { _notice = reason; Render(); return false; }
        var target = ColumnStage(column);
        if (column == "ended") { Open(new JobAction("terminate", item)); return true; }
        var sample = _applications.FirstOrDefault(a => a.Column == column);
        Open(new JobAction(item.Stage == "pending" ? "apply" : "stage", item)
        {
            Stage = target,
            Label = target == "interview" ? (sample is not null ? ColumnTitle(column) : "一面") : CareerStage.Label(target),
            Round = sample?.Raw.Get("current_round_no").Number() is { } n ? (int)n : null,
            Compact = item.Stage == "pending" && target == "screening",
        });
        return true;
    }

    /// <summary>`validateApplicationDrop` 拒绝移动时的文案。</summary>
    string? DropBlockReason(CareerApplication item, string column)
    {
        if (item.Raw.Text("archived_at").Length > 0) return "该求职流程已归档，不能拖入其他状态栏。";
        if (item.Ended) return "该求职流程已经结束，不能拖入其他状态栏。";
        if (item.Stage == "offer" && column != "ended") return "该求职流程已经进入 Offer 阶段，只能拖到「已结束」。";
        if (item.Stage == "pending" && column == "pending") return "该记录已经位于待投递。";
        if (CareerStage.CanAdvance(item, column, ColumnStage(column))) return null;
        if (column.StartsWith("interview:") && item.Column.StartsWith("interview:")) return "不能拖回当前或更早的面试阶段。";
        if (column is "assessment" or "written_test") return $"当前已经在{ColumnTitle(item.Column)}，不能退回{ColumnTitle(column)}。";
        return "只能拖动到后续的测评、笔试、面试或 Offer 阶段。";
    }

    void MoveColumn(string column, int direction)
    {
        var columns = AllColumns;
        var index = columns.IndexOf(column);
        if (index < 0 || index + direction < 0 || index + direction >= columns.Count) return;
        (columns[index], columns[index + direction]) = (columns[index + direction], columns[index]);
        _order = columns;
        RenderContent();
    }

    static Color ColumnTone(string key)
    {
        if (key.StartsWith("interview") || key == "ai_interview") return Blue;
        if (key is "assessment" or "written_test") return V3.Orange;
        return key == "offer" ? Green : Fnt;
    }

    static Color ToneColor(CareerTone tone) => tone switch
    {
        CareerTone.Blue => Blue, CareerTone.Orange => V3.Orange, CareerTone.Green => Green, CareerTone.Red => Red, _ => Fnt,
    };

    FrameworkElement Card(CareerApplication item)
    {
        var done = Completed(item);
        var status = CareerBoard.CardStatus(item.Raw, done);
        var tone = CareerBoard.Tone(item.Raw, done);
        var today = done ? null : CareerBoard.Today(item.Raw);
        var time = done ? null : CareerBoard.CardTime(item.Raw);
        var hovering = _hoveredCard == item.Id;
        var title = Sans(item.Company + " · " + item.Title, 12, Txt, Medium).Frame(height: 14).Pad(0, 0, 22, 0).Tip(item.Company + " · " + item.Title);
        var layer = new Grid { Children = { title.Align(v: VerticalAlignment.Top) } };
        if (item.Category.Length > 0 && Categories.FirstOrDefault(c => c.Key == item.Category) is { Label: { } label } && label.Length > 0)
            layer.Children.Add(V3Chip.Make(label).Align(HorizontalAlignment.Left, VerticalAlignment.Top).Top(24));
        StackPanel bottom;
        if (today is not null)
        {
            // `.progress-card-today`：22 高胶囊、蓝色（测评 / 笔试的作答窗口为橙色）浅底与 20% 描边、12 号时钟、11px 数字
            var window = CareerBoard.StableType(item.Raw) is "assessment" or "written_test";
            var accent = window ? V3.Orange : Blue;
            var ink = Mix(accent, Txt, 0.35);
            var clock = Icon("clock", 10, ink); clock.FontWeight = Medium;
            var pill = new Border
            {
                Child = HStack(5, clock, Number(today, 11, ink, Medium)), Padding = new Thickness(8, 0, 8, 0), Height = 22, CornerRadius = new CornerRadius(11),
                Background = Brush(window ? OrangeSoft : BlueSoft), BorderBrush = Brush(Alpha(accent, 0.2)), BorderThickness = new Thickness(1),
            }.Tip(status);
            bottom = HStack(6, pill);
        }
        else bottom = HStack(6, new Ellipse { Width = 5, Height = 5, Fill = Brush(ToneColor(tone)) }, Sans(status, 10.5, tone == CareerTone.Red ? Red : Fnt));
        bottom.Height = 20;
        bottom.VerticalAlignment = VerticalAlignment.Bottom;
        bottom.Margin = new Thickness(0, 0, 26, -6);
        if (time is not null) ToolTipService.SetToolTip(bottom, time);
        layer.Children.Add(bottom);
        var logo = Logo(item);
        logo.HorizontalAlignment = HorizontalAlignment.Right; logo.VerticalAlignment = VerticalAlignment.Bottom;
        logo.Margin = new Thickness(0, 0, 0, -4);
        layer.Children.Add(logo);
        var more = Icon("ellipsis", 13, Fnt).Also(i => i.FontWeight = Medium);
        var moreBox = new Border { Width = 22, Height = 22, Child = more.Align(HorizontalAlignment.Center, VerticalAlignment.Center), Background = Brush(Clear),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, -5, -5, 0), Opacity = hovering ? 1 : 0 };
        moreBox.OnTap(() => CardMenu(item).ShowAt(moreBox), $"更多求职操作 {item.Company} {item.Title}");
        layer.Children.Add(moreBox);
        var card = new Border
        {
            Child = layer, Padding = new Thickness(11), Height = 86, CornerRadius = new CornerRadius(8), Background = Brush(V3.White),
            BorderBrush = Brush(hovering ? Sk2 : Hex(0xEBEBE7)), BorderThickness = new Thickness(1),
        }.Elevate(hovering ? 4 : 1);
        card.ContextFlyout = CardMenu(item);
        card.CanDrag = true;
        card.DragStarting += (_, e) => e.Data.SetText(item.Movable ? "job:" + item.Id : "locked:" + item.Id);
        card.OnHover(inside =>
        {
            _hoveredCard = inside ? item.Id : _hoveredCard == item.Id ? null : _hoveredCard;
            moreBox.Opacity = inside ? 1 : 0;
            card.BorderBrush = Brush(inside ? Sk2 : Hex(0xEBEBE7));
            card.Translation = new System.Numerics.Vector3(0, 0, inside ? 4 : 1);
        });
        card.OnTap(() => { _selected = item; Render(); }, $"{item.Company} {item.Title}，{status}");
        card.Loaded += async (_, _) => await LoadLogoAsync(item, logo);
        return card;
    }

    MenuFlyout CardMenu(CareerApplication item)
    {
        var menu = new MenuFlyout();
        void Add(string text, string? symbol, Action action, bool enabled = true, bool danger = false)
        {
            var entry = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
            if (symbol is not null) entry.Icon = new FontIcon { Glyph = Icons.Glyph(symbol), FontFamily = IconFamily };
            if (danger) entry.Foreground = Brush(Red);
            entry.Click += (_, _) => action();
            menu.Items.Add(entry);
        }
        Add("查看详情", "eye", () => { _selected = item; Render(); });
        if (item.Column != "ended" && !item.Ended)
        {
            Add("修改分类", null, () => Open(new JobAction("category", item)));
            Add("推进流程", "arrow.right", () => Advance(item), item.Movable);
            if (item.Raw.Text("offer_status") is "none" or "") Add("终止求职", "nosign", () => Open(new JobAction("terminate", item)), danger: true);
        }
        else if (item.Column == "ended") Add("删除岗位", "trash", () => Open(new JobAction("delete", item)), danger: true);
        return menu;
    }

    /// <summary>`applicationAdvanceAction`：打开阶段弹窗，并选好流程里的下一步。</summary>
    void Advance(CareerApplication item)
    {
        if (item.Stage == "pending") { Open(new JobAction("apply", item) { Stage = "screening", Label = "筛选中" }); return; }
        if (CareerBoard.AdvanceStage(item) is not { } next) return;
        var round = item.Raw.Integer("current_round_no") + 1;
        Open(new JobAction("stage", item) { Stage = next.Stage, Label = next.Label.Length == 0 ? RoundLabel(round) : next.Label });
    }

    /// <summary>`interviewRoundLabel`。</summary>
    public static string RoundLabel(int round) => round <= 1 ? "一面" : round == 2 ? "二面" : $"第 {round} 轮";

    Border Logo(CareerApplication item)
    {
        var initial = item.Company.Trim();
        UIElement child = _logos.TryGetValue(item.Id, out var image)
            ? new Image { Source = image, Stretch = Stretch.Uniform }
            : Sans(initial.Length == 0 ? "企" : initial[..1], 9, Sub, Semibold).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        var logo = new Border
        {
            Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = Brush(Field), BorderBrush = Brush(0xEBEBE7), BorderThickness = new Thickness(1), Child = child,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(logo, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return logo;
    }

    async Task LoadLogoAsync(CareerApplication item, Border target)
    {
        if (item.LogoRequest is not { } logo || _logos.ContainsKey(item.Id) || _pendingLogos.Contains(item.Id) || _logos.Count + _pendingLogos.Count >= 128) return;
        var owner = Account;
        _pendingLogos.Add(item.Id);
        try
        {
            var result = await App.Session.Api.CareerRequestAsync(logo.Path, "GET", new Dictionary<string, string> { ["v"] = logo.Revision });
            if (owner != Account || !_active) return;
            var bytes = Convert.FromBase64String(result.Text("image_base64"));
            var bitmap = new BitmapImage();
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            await stream.WriteAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(bytes));
            stream.Seek(0);
            await bitmap.SetSourceAsync(stream);
            _logos[item.Id] = bitmap;
            target.Child = new Image { Source = bitmap, Stretch = Stretch.Uniform };
        }
        catch (Exception) { /* 保留公司首字 */ }
        finally { if (owner == Account) _pendingLogos.Remove(item.Id); }
    }

    // MARK: 列表

    FrameworkElement List(List<CareerApplication> visible)
    {
        var stack = new StackPanel { Spacing = 18, Padding = new Thickness(0, 0, 0, 24) };
        if (_grouped)
        {
            foreach (var (key, label) in Categories)
            {
                var items = visible.Where(x => x.Category == key || (key.Length == 0 && x.Category is not ("internship" or "campus" or "full_time"))).ToList();
                if (items.Count == 0) continue;
                stack.Children.Add(VStack(6, HStack(10, Sans(label, 12, Txt, Medium), Sans($"{items.Count}", 12, Fnt)), Table(items, false)));
            }
        }
        else stack.Children.Add(Table(visible, true));
        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    FrameworkElement Table(List<CareerApplication> items, bool showCategory)
    {
        var stack = new StackPanel();
        stack.Children.Add(Row(true, showCategory, new[] { "公司 / 岗位", "求职分类", "当前进度", "最近安排", "投递日期", "更新时间" }.Select(t => (UIElement)Sans(t, 11, Fnt)).ToArray()));
        foreach (var item in items)
        {
            var done = Completed(item);
            var label = CareerBoard.ProgressLabel(item.Raw, done);
            var next = NextSession(item);
            var name = HStack(6, Sans(item.Company, 12, Txt, Medium), Sans("·", 12, Fnt), Sans(item.Title, 12, Txt, Medium));
            var row = Row(false, showCategory, [
                name,
                V3Chip.Make(item.CategoryLabel, height: 20, size: 10),
                Sans(label, 12, ListTone(CareerBoard.Tone(item.Raw, done)), Medium),
                Sans(next is null ? "暂无安排" : CareerBoard.SessionRange(next) + " · " + next.Text("stage_label"), 12, Sub),
                Sans(CareerBoard.RelativeDay(item.Raw.Text("applied_at")) ?? "未投递", 12, Sub),
                Sans(CareerBoard.RelativeDay(item.Raw.Text("updated_at")) ?? "—", 11, Fnt),
            ]);
            // `.career-application-table-row` 悬停底色
            row.Background = Brush(Clear);
            row.OnHover(hover => row.Background = Brush(hover ? Hex(0xFAFAF8) : Clear));
            stack.Children.Add(row.OnTap(() => { _selected = item; Render(); }, $"{item.Company} {item.Title}"));
        }
        return stack;
    }

    /// <summary>`.career-application-table`：`table-layout: fixed` 等分列；单元格左右 12，首列不留左边距。</summary>
    static Border Row(bool header, bool showCategory, UIElement[] cells)
    {
        var grid = new Grid();
        var column = 0;
        for (var index = 0; index < cells.Length; index++)
        {
            if (index == 1 && !showCategory) continue;
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            if (cells[index] is FrameworkElement cell)
            {
                cell.Margin = new Thickness(index == 0 ? 0 : 12, 0, 12, 0);
                cell.VerticalAlignment = VerticalAlignment.Center;
                cell.HorizontalAlignment = HorizontalAlignment.Left;
            }
            Grid.SetColumn((FrameworkElement)cells[index], column++);
            grid.Children.Add(cells[index]);
        }
        return new Border { Child = grid, Height = header ? 36 : 56, BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 0, 0, 1) };
    }

    static Color ListTone(CareerTone tone) => ToneColor(tone);

    JsonNode? NextSession(CareerApplication item)
    {
        if (item.Raw.Text("status") != "active" || item.Raw.Text("archived_at").Length > 0) return null;
        var now = DateTimeOffset.UtcNow;
        return _sessions.Where(s => s.Text("application_id") == item.Id && s.Text("status") == "scheduled" && (CareerApplication.Date(s.Text("end_at")) ?? DateTimeOffset.MinValue) > now)
            .MinBy(s => CareerApplication.Date(s.Text("start_at")) ?? DateTimeOffset.MaxValue);
    }

    // MARK: 空状态

    FrameworkElement Empty()
    {
        if (_query.Trim().Length > 0)
        {
            var card = new Border
            {
                Child = VStack(10, Serif("没有匹配的求职进程", 18), Sans("换个公司、职位或阶段关键词试试。", 13, Sub)),
                Padding = new Thickness(32, 30, 32, 30), MaxWidth = 520, CornerRadius = new CornerRadius(16), Background = Brush(V3.White),
                BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top,
            };
            card.Margin = new Thickness(0, 40, 0, 0);
            return card;
        }
        var plugin = new V3Button("安装浏览器插件", () => OpenKind("plugin"), height: 36, icon: "puzzlepiece.extension");
        var empty = V3EmptyCard.Make(Account.Length == 0 ? "登录后查看求职进程" : "还没有求职进程", "装上浏览器插件，在招聘网站上一键把岗位存进来；也可以粘贴岗位文字导入。",
            CareerEmptyBoardArt.Make(), [plugin, new CareerAction("粘贴岗位文字导入", () => OpenKind("import"), CareerAction.Kind.Link),
                new CareerAction("创建第一条求职进程", () => OpenKind("arranged"), CareerAction.Kind.Link)], stageHeight: 216, width: 560);
        empty.Margin = new Thickness(0, 40, 0, 0);
        empty.HorizontalAlignment = HorizontalAlignment.Center;
        empty.VerticalAlignment = VerticalAlignment.Top;
        return new ScrollViewer { Content = empty };
    }

    void OpenKind(string kind)
    {
        if (Account.Length == 0) { _pendingAction = kind; _requireAccount(); }
        else Open(new JobAction(kind, null));
    }

    void Open(JobAction action) => CareerForm.Show(XamlRoot, action, _applications, () => _ = LoadAsync());

    async Task LoadAsync()
    {
        var generation = ++_generation;
        var account = Account;
        if (account.Length == 0) { _loading = false; _failure = null; Render(); return; }
        // 登录后接着打开登录前点的入口（Mac `onChange(of: account)` 的 pendingAction）
        if (_pendingAction is { } pending) { _pendingAction = null; Open(new JobAction(pending, null)); }
        _loading = true; _failure = null; _logos.Clear(); _pendingLogos.Clear(); Render();
        try
        {
            var result = new List<CareerApplication>();
            var cursor = ""; var seen = new HashSet<string>();
            do
            {
                var query = new Dictionary<string, string> { ["scope"] = "all", ["limit"] = "200" };
                if (cursor.Length > 0) query["cursor"] = cursor;
                var page = await App.Session.Api.CareerRequestAsync("/api/job-applications", "GET", query);
                if (generation != _generation) return;
                result.AddRange(page.Items("items").Select(x => new CareerApplication(x)));
                cursor = page.Text("next_cursor");
                if (cursor.Length > 0 && !seen.Add(cursor)) throw new InvalidDataException();
            } while (cursor.Length > 0);
            var metrics = await App.Session.Api.CareerRequestAsync("/api/interview-overview", "GET", new Dictionary<string, string> { ["timezone"] = TimeZoneId() });
            var arrangements = new List<JsonNode>(); cursor = ""; seen.Clear();
            do
            {
                var query = new Dictionary<string, string> { ["limit"] = "500", ["include_archived"] = "true" };
                if (cursor.Length > 0) query["cursor"] = cursor;
                var page = await App.Session.Api.CareerRequestAsync("/api/interview-sessions", "GET", query);
                if (generation != _generation) return;
                arrangements.AddRange(page.Items("items"));
                cursor = page.Text("next_cursor");
                if (cursor.Length > 0 && !seen.Add(cursor)) throw new InvalidDataException();
            } while (cursor.Length > 0);
            if (generation != _generation) return;
            _applications = result.Select(a => a.IncludingSessions(arrangements)).ToList();
            _sessions = arrangements; _overview = metrics;
            if (OpenApplication is { } target) { _selected = _applications.FirstOrDefault(a => a.Id == target); OpenApplication = null; }
        }
        catch (OperationCanceledException) { return; }
        catch (ApiException error) when (error.Status == System.Net.HttpStatusCode.Unauthorized) { App.Session.ReportAuthenticationFailure(); _failure = "登录已失效，请重新登录。"; }
        catch (Exception) { _failure = "岗位加载失败，请检查服务连接后重试。"; }
        if (generation != _generation) return;
        _loading = false;
        if (_active) Render();
    }

    /// <summary>`TimeZone.current.identifier`：后端要 IANA 名；Windows 时区先转 IANA，转不了时用原名。</summary>
    internal static string TimeZoneId() =>
        TimeZoneInfo.TryConvertWindowsIdToIanaId(Beijing.Zone.Id, out var iana) ? iana : Beijing.Zone.Id;
}

/// <summary>`EmptyBoardArt`（Mac `CareerEmptyBoardArt`）：544×216，四个迷你栏目、一张示例卡与插件角标。</summary>
public static class CareerEmptyBoardArt
{
    public static FrameworkElement Make()
    {
        var canvas = new Canvas { Width = 544, Height = 216, IsHitTestVisible = false };
        (string Title, Color Dot)[] columns = [("待投递", Fnt), ("笔试", V3.Orange), ("面试中", Blue), ("Offer", Green)];
        for (var index = 0; index < columns.Length; index++)
        {
            var dash = new Rectangle { Width = 74, Height = 44, RadiusX = 6, RadiusY = 6, Stroke = Brush(0xE9E9E5), StrokeThickness = 1, StrokeDashArray = [3, 3] };
            var inner = new Canvas { Width = 86, Height = 168 };
            Put(inner, new Ellipse { Width = 6, Height = 6, Fill = Brush(columns[index].Dot) }, 9, 12);
            Put(inner, Sans(columns[index].Title, 9.5, Sub, Medium), 20, 8);
            Put(inner, dash, 6, 32);
            var column = new Border { Width = 86, Height = 168, CornerRadius = new CornerRadius(8), Background = Brush(0xFBFBFA), BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(1), Child = inner };
            Put(canvas, column, 85 + index * 96, 24);
        }
        var figure = new PathFigure { StartPoint = new Windows.Foundation.Point(175, 92) };
        figure.Segments.Add(new BezierSegment { Point1 = new(255, 102), Point2 = new(375, 122), Point3 = new(447, 148) });
        var curve = new Microsoft.UI.Xaml.Shapes.Path { Data = new PathGeometry { Figures = { figure } }, Stroke = Brush(Fnt2), StrokeThickness = 1.4, StrokeDashArray = [3 / 1.4, 3 / 1.4] };
        canvas.Children.Add(curve);
        var card = new Canvas { Width = 120, Height = 54 };
        Put(card, Sans("美团 · Java 开发", 10, Txt, Medium), 10, 9);
        Put(card, new Border { Child = Sans("校招", 8, Sub, Medium).Align(v: VerticalAlignment.Center), Padding = new Thickness(5, 0, 5, 0), Height = 14, Background = Brush(Field), CornerRadius = new CornerRadius(3) }, 10, 31);
        Put(card, new Ellipse { Width = 4, Height = 4, Fill = Brush(Red) }, 46, 36);
        Put(card, Number("09-30 截止", 8, Red, Regular), 54, 32);
        Put(canvas, new Border { Width = 120, Height = 54, CornerRadius = new CornerRadius(8), Background = Brush(V3.White), Child = card }.Elevate(4), 95, 54);
        Put(canvas, new Border
        {
            Width = 40, Height = 40, CornerRadius = new CornerRadius(12), Background = Brush(Txt),
            Child = Icon("puzzlepiece.extension.fill", 17, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        }, 369, 146);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(canvas, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return canvas;
    }

    static void Put(Canvas canvas, FrameworkElement element, double x, double y)
    {
        Canvas.SetLeft(element, x);
        Canvas.SetTop(element, y);
        canvas.Children.Add(element);
    }
}
