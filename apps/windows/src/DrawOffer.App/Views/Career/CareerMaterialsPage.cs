using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Career.CareerKit;

namespace DrawOffer.App.Views.Career;

/// <summary>
/// 资料整页（Mac `CareerMaterialsPage`，Web `progress/MaterialsPage.tsx`）：顶部按轮次切换，一次只看一轮；
/// 上面是这一轮的成果（面试记录 + AI 复盘，笔试是笔试题，投递是简历和岗位 JD），下面是资料缩略图，最后一格添加。
/// 文件添加沿用「添加记录」弹窗（上传、资料库、粘贴），不做 Web 页底的拖放待处理栏。
/// </summary>
public sealed partial class CareerMaterialsPage : UserControl
{
    readonly JsonNode _application;
    readonly CareerDeck _deck;
    readonly IReadOnlyDictionary<string, JsonNode> _details;
    readonly string? _initialSessionId;
    readonly IReadOnlySet<string> _splitting;
    readonly Action _back;
    readonly Action<string, CareerRecordPage.Mode> _openRecord;
    readonly Action<JsonNode> _openReview;
    readonly Action<JsonNode> _generateReview;
    readonly Action<JsonNode> _add;
    readonly Action<JsonNode> _addFromLibrary;
    readonly Action _openResume;
    readonly Action _openJob;
    readonly bool _fromLibrary;
    readonly Action? _openProgress;
    string? _selected;
    bool _writtenOpen;
    readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    readonly StackPanel _column = new();

    public CareerMaterialsPage(JsonNode application, CareerDeck deck, IReadOnlyDictionary<string, JsonNode> details, string? initialSessionId,
        IReadOnlySet<string> splitting, Action back, Action<string, CareerRecordPage.Mode> openRecord, Action<JsonNode> openReview,
        Action<JsonNode> generateReview, Action<JsonNode> add, Action<JsonNode> addFromLibrary, Action openResume, Action openJob,
        bool fromLibrary = false, Action? openProgress = null)
    {
        (_application, _deck, _details, _initialSessionId, _splitting, _back, _openRecord, _openReview) =
            (application, deck, details, initialSessionId, splitting, back, openRecord, openReview);
        (_generateReview, _add, _addFromLibrary, _openResume, _openJob, _fromLibrary, _openProgress) =
            (generateReview, add, addFromLibrary, openResume, openJob, fromLibrary, openProgress);
        _scroll.Content = _column;
        Content = _scroll;
        SizeChanged += (_, e) => Fit(e.NewSize.Width);
        Render();
    }

    void Fit(double width)
    {
        var gutter = V3Page.Gutter(width);
        var column = Math.Min(920, Math.Max(0, width - gutter * 2));
        var side = Math.Max(gutter, (width - column) / 2);
        _column.Width = column;
        _column.Margin = new Thickness(side, 52, side, 120);
        _column.HorizontalAlignment = HorizontalAlignment.Left;
    }

    List<CareerStation> Rounds => _deck.Stations.Reverse()
        .Where(x => x.Kind == CareerStationKind.Apply || (x.Session is { } session && session.Text("status") != "cancelled")).ToList();

    void Render()
    {
        var rounds = Rounds;
        var fallback = rounds.FirstOrDefault(x => x.Current && x.Session is not null) ?? rounds.FirstOrDefault(x => x.Session is not null) ?? rounds.FirstOrDefault();
        var station = (_selected is { } key ? rounds.FirstOrDefault(x => x.Id == key) : null)
            ?? (_initialSessionId is { } id ? rounds.FirstOrDefault(x => x.Session?.Text("id") == id) : null)
            ?? fallback;
        _column.Children.Clear();
        if (_fromLibrary)
        {
            var back = Tappable(HStack(6, Icon("arrow.left", 13, Fnt), Sans("资料库", 16, Fnt)), _back, "返回资料库");
            var slash = Sans("/", 16, Fnt);
            Hidden(slash);
            var crumb = HStack(12, back, slash, Sans("求职进程", 16, Fnt));
            crumb.Height = 20;
            crumb.Margin = new Thickness(0, 0, 0, 12);
            _column.Children.Add(crumb);
        }
        else
        {
            var back = Tappable(HStack(6, Icon("arrow.left", 13, Fnt), Sans("求职进度", 14, Fnt)).Frame(height: 20), _back, "返回求职进度");
            back.Margin = new Thickness(0, 0, 0, 12);
            back.HorizontalAlignment = HorizontalAlignment.Left;
            _column.Children.Add(back);
        }
        var titles = VStack(4,
            Sans(string.Join(" · ", new[] { _application.Text("company_name_snapshot"), _application.Text("job_title_snapshot") }.Where(x => x.Length > 0)), 13, PD.Body, Medium).Frame(height: 20),
            Serif("资料", 30).Frame(height: 40));
        var target = station?.Session ?? rounds.Select(x => x.Session).FirstOrDefault(x => x is not null);
        var actions = HStack(8);
        if (_openProgress is { } progress) actions.Children.Add(new PDButton("打开求职进度 ↗", progress));
        actions.Children.Add(new PDButton("上传资料", () => { if (target is not null) _add(target); }, PDButton.Kind.Primary, icon: "square.and.arrow.up") { Enabled = target is not null });
        _column.Children.Add(Spread(titles, actions, 16, VerticalAlignment.Bottom));
        if (rounds.Count > 0) _column.Children.Add(Tabs(rounds, station?.Id));
        if (station is not null) foreach (var child in Panel(station)) _column.Children.Add(child);
        else _column.Children.Add(Sans("这条投递还没有记录，记下投递后资料会按轮次放在这里。", 13, PD.Mute).Wrap().Top(28));
    }

    UIElement Tabs(List<CareerStation> rounds, string? on)
    {
        var row = HStack(4);
        foreach (var item in rounds)
        {
            var count = item.Session is { } session
                ? _details.GetValueOrDefault(session.Text("id")).Items("assets").Count
                : (_application.Text("resume_id").Length == 0 ? 0 : 1) + (_application.Text("job_description_id").Length == 0 ? 0 : 1);
            var selected = item.Id == on;
            var cell = HStack(8);
            if (item.Current) cell.Children.Add(Dot(PD.Blue, 6).Named("现在"));
            cell.Children.Add(Sans(item.Short, 13.5, selected ? PD.Ink : PD.Body, Medium));
            cell.Children.Add(Label(CareerDeckFormat.MonthDay(CareerApplication.Date(item.Session?.Text("start_at") ?? "") ?? item.Start), 12, PD.Mute));
            cell.Children.Add(Label($"{count}", 12, selected ? PD.BlueText : PD.Mute, Medium));
            var tab = new Border { Child = cell, Padding = new Thickness(16, 0, 16, 0), Height = 36, CornerRadius = new CornerRadius(10), Background = Brush(selected ? V3.White : Clear) };
            if (selected) tab.Elevate(1.5f);
            var key = item.Id;
            var tap = Tappable(tab, () => { _selected = key; _writtenOpen = false; Render(); }, item.Short);
            if (selected) Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(tap, "已选中");
            row.Children.Add(tap);
        }
        row.Padding = new Thickness(4);
        var strip = new Border { Child = new ScrollViewer { Content = row, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollMode = ScrollMode.Disabled },
            Background = Brush(0xF5F5F2), CornerRadius = new CornerRadius(14), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 28, 0, 0) };
        return strip.Named("轮次");
    }

    // MARK: 这一轮

    sealed class Outcome(string id, string icon, string tone, string title)
    {
        public string Id { get; } = id;
        public string IconName { get; } = icon;
        public string Tone { get; } = tone;
        public string Title { get; } = title;
        public (string Value, string Unit)? Number { get; set; }
        public (string Text, bool Muted)? State { get; set; }
        public string? Body { get; set; }
        public string? Meta { get; set; }
        public List<(string Label, bool Filled, Action Run)> Actions { get; set; } = [];
        public bool Wide { get; set; }
    }

    IEnumerable<UIElement> Panel(CareerStation station)
    {
        var detail = station.Session is { } summary ? _details.GetValueOrDefault(summary.Text("id")) : null;
        if (station.Session is not null && detail is null)
        {
            yield return Sans("正在读取这一轮的资料…", 13, PD.Mute).Top(28);
            yield break;
        }
        var (hint, outcomes) = Outcomes(station, detail);
        yield return Section("这一轮的成果", hint);
        yield return OutcomeGrid(outcomes);
        if (station.Kind == CareerStationKind.Written && _writtenOpen && detail is not null) yield return Written(detail);
        if (station.Session is { } session && detail is not null)
        {
            var assets = detail.Items("assets");
            // Mac 不做拖放待处理栏，说明里不写「拖文件到这里」
            yield return Section("资料", assets.Count == 0 ? "还没有" : $"{assets.Count} 份", ("从资料库选", () => _addFromLibrary(session)));
            var grid = new Grid { ColumnSpacing = 16, RowSpacing = 16 };
            for (var i = 0; i < 4; i++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            var cells = assets.Select(asset => (FrameworkElement)Tile(asset, detail)).ToList();
            var plus = VStack(6, Icon("plus", 16, PD.Body), Sans("添加资料", 13, PD.Body, Medium),
                Sans(station.Kind == CareerStationKind.Written ? "题目、截图、做题笔记都行" : "录音、笔记、截图都行", 11.5, PD.Mute));
            foreach (var child in plus.Children.OfType<FrameworkElement>()) child.HorizontalAlignment = HorizontalAlignment.Center;
            plus.VerticalAlignment = VerticalAlignment.Center;
            var addCell = Dashed(plus, 16, Hex(0xD6D6D0), width: 1.2);
            addCell.MinHeight = 182;
            cells.Add(Tappable(addCell, () => _add(session), "添加资料"));
            for (var index = 0; index < cells.Count; index++)
            {
                if (index % 4 == 0) grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
                Grid.SetColumn(cells[index], index % 4);
                Grid.SetRow(cells[index], index / 4);
                grid.Children.Add(cells[index]);
            }
            yield return grid;
        }
        else yield return Sans("其他资料可以放进后面的笔试或面试。", 13, PD.Mute).Wrap().Top(28);
    }

    static UIElement Section(string title, string hint, (string Label, Action Run)? link = null)
    {
        var left = HStack(8, Sans(title, 15, Txt, Medium), Sans(hint, 12.5, PD.Mute));
        UIElement row = left;
        if (link is { } action) row = Spread(left, Tappable(Sans(action.Label, 12.5, PD.Ink, Medium), action.Run, action.Label), 8);
        return new Border { Child = row, Height = 23, Margin = new Thickness(0, 32, 0, 12) };
    }

    UIElement OutcomeGrid(List<Outcome> outcomes)
    {
        var grid = new Grid { ColumnSpacing = 16, RowSpacing = 16 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        int row = 0, column = 0;
        foreach (var item in outcomes)
        {
            if (column == 0) grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
            var card = OutcomeCard(item);
            Grid.SetRow(card, row);
            Grid.SetColumn(card, column);
            if (item.Wide) { Grid.SetColumnSpan(card, 2); row++; column = 0; }
            else if (++column == 2) { column = 0; row++; }
            grid.Children.Add(card);
        }
        return grid;
    }

    FrameworkElement OutcomeCard(Outcome item)
    {
        var tint = item.Tone == "blue" ? PD.BlueText : item.Tone == "purple" ? Hex(0x7C5CD6) : PD.Body;
        var fill = item.Tone == "blue" ? PD.Tint : item.Tone == "purple" ? Hex(0xF2EEFD) : Hex(0xF5F5F2);
        var badge = new Border { Width = 32, Height = 32, CornerRadius = new CornerRadius(10), Background = Brush(fill), Child = Icon(item.IconName, 14, tint).Align(HorizontalAlignment.Center, VerticalAlignment.Center) };
        var head = new Grid { ColumnSpacing = 10, MinHeight = 32 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = Auto });
        head.Children.Add(badge);
        var title = Sans(item.Title, 14, Txt, Medium).Align(v: VerticalAlignment.Center);
        Grid.SetColumn(title, 1);
        head.Children.Add(title);
        var buttons = HStack(10);
        foreach (var (label, filled, run) in item.Actions)
        {
            var button = new Border
            {
                Child = Sans(label, 14, PD.Ink).Align(v: VerticalAlignment.Center), Padding = new Thickness(14, 0, 14, 0), Height = 30, CornerRadius = new CornerRadius(15),
                Background = Brush(filled ? Hex(0xEFEFEC) : V3.White), BorderBrush = Brush(filled ? Clear : Hex(0xE7E5DF)), BorderThickness = new Thickness(1),
            };
            buttons.Children.Add(button.OnTap(run, label));
        }
        Grid.SetColumn(buttons, 2);
        head.Children.Add(buttons);
        var stack = new StackPanel();
        stack.Children.Add(head);
        if (item.Number is { } number)
        {
            var big = Label(number.Value, 34, Txt, Medium);
            big.CharacterSpacing = -20;
            var unit = Sans(number.Unit, 14, PD.Body);
            unit.VerticalAlignment = VerticalAlignment.Bottom;
            unit.Margin = new Thickness(0, 0, 0, 6);
            var line = HStack(6, big, unit);
            line.Height = 40;
            line.Margin = new Thickness(0, 18, 0, 0);
            stack.Children.Add(line);
        }
        if (item.State is { } state) stack.Children.Add(Sans(state.Text, 17, state.Muted ? PD.Mute : PD.Ink, Medium).Frame(height: 26).Top(18));
        if (item.Body is { } body) stack.Children.Add(Sans(body, 13.5, PD.Body).Spaced(5).Wrap().Top(14));
        if (item.Meta is { } meta) stack.Children.Add(Sans(meta, 12, PD.Mute).Wrap().Also(t => t.MinHeight = 18).Top(6));
        return new Border
        {
            Child = stack, Padding = new Thickness(22, 20, 22, 20), CornerRadius = new CornerRadius(18), Background = Brush(V3.White),
            BorderBrush = Brush(0xE7E5DF), BorderThickness = new Thickness(1), VerticalAlignment = VerticalAlignment.Stretch,
        }.Named(item.Title);
    }
}
