using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Career.CareerKit;

namespace DrawOffer.App.Views.Career;

/// <summary>
/// 面试记录整页（Mac `CareerRecordPage`，Web `progress/RecordPage.tsx` + `RecordReader.tsx`）。
/// 看：所有题连着读，我的回答在右、面试官追问在左，右侧细目录跟着读到的题高亮；
/// 粘贴：贴文字，点「拆成问题」回到上一页，后台拆好直接存成面试记录。
/// </summary>
public sealed class CareerRecordPage : UserControl
{
    public enum Mode { Record, Paste }

    readonly JsonNode _application;
    readonly CareerStation _station;
    readonly JsonNode _session;
    readonly Mode _mode;
    readonly bool _splitting;
    readonly string? _splitError;
    readonly string _backLabel;
    readonly Action _back;
    readonly Action<string> _split;
    readonly Action _generateReview;
    int _active;
    readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    readonly StackPanel _column = new();
    readonly TextBox _paste;
    readonly TextBlock _count = Sans("0 字", 12, PD.Mute);
    PDButton? _splitButton;
    RecordReaderView? _reader;

    List<RecordQuestion> Questions { get; }

    public CareerRecordPage(JsonNode application, CareerStation station, JsonNode session, Mode mode, bool splitting, string? splitError,
        string backLabel, Action back, Action<string> split, Action generateReview)
    {
        (_application, _station, _session, _mode, _splitting, _splitError, _backLabel, _back, _split, _generateReview) =
            (application, station, session, mode, splitting, splitError, backLabel, back, split, generateReview);
        Questions = InterviewRecord.Parse(session.Text("questions_markdown"));
        _paste = new TextBox
        {
            AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontSize = 14, FontFamily = SansFamily, MinHeight = 360, Padding = new Thickness(10),
            BorderThickness = new Thickness(0), Background = Brush(Clear), Foreground = Brush(Txt), MaxLength = 30_000,
            PlaceholderText = "比如：问了订单服务，我讲了拆单和预占；追问对账任务挂了怎么办……", PlaceholderForeground = Brush(Fnt2),
        }.Named("粘贴面试文字");
        _paste.TextChanged += (_, _) =>
        {
            _count.Text = $"{Count(_paste.Text)} 字";
            if (_splitButton is not null) _splitButton.Enabled = _paste.Text.Trim().Length > 0 && !_splitting;
        };
        _scroll.Content = _column;
        Content = _scroll;
        Build();
        SizeChanged += (_, e) => Fit(e.NewSize.Width);
    }

    void Fit(double width)
    {
        var gutter = V3Page.Gutter(width);
        _column.Width = Math.Min(Math.Max(0, width - gutter * 2), V3Page.MaxWidthFor(width));
        _column.Margin = new Thickness(gutter, 52, gutter, 80);
        _column.HorizontalAlignment = HorizontalAlignment.Left;
    }

    void Build()
    {
        _column.Children.Clear();
        _column.Children.Add(Head());
        if (_mode == Mode.Paste) _column.Children.Add(PasteBody());
        else if (_splitting) _column.Children.Add(SplittingBody());
        else if (Questions.Count == 0) _column.Children.Add(Sans("还没有问题。", 13, Hex(0x9E9B91)).Align(HorizontalAlignment.Center).Top(80));
        else
        {
            _reader = new RecordReaderView(Questions, _active, value => _active = value, _scroll);
            _column.Children.Add(_reader);
        }
    }

    UIElement Head()
    {
        var start = CareerApplication.Date(_session.Text("start_at"));
        var when = start is { } date ? $"{CareerDeckFormat.MonthDay(date)} {CareerDeckFormat.Weekday(date)}" : CareerDeckFormat.MonthDay(_station.Start);
        string?[] meta = _mode == Mode.Paste || _splitting ? [when, "粘贴文字"]
            : [when, _session.Text("transcript_source") == "transcription" ? "录音转写" : null, $"{Questions.Count} 道题"];
        var back = Tappable(HStack(6, Icon("arrow.left", 13, Fnt), Sans(_backLabel, 14, Fnt)), _back, "返回" + _backLabel);
        var crumb = HStack(12, back, Sans("/", 14, Fnt), Sans("面试记录", 14, Fnt));
        crumb.Height = 20;
        crumb.Margin = new Thickness(0, 0, 0, 12);
        var titles = VStack(0,
            Sans($"{_application.Text("company_name_snapshot")} · {_application.Text("job_title_snapshot")}", 13, Txt).Frame(height: 21),
            Serif($"{_station.Short}的面试记录", 30).Frame(height: 42).Pad(0, 0, 0, 6),
            Sans(string.Join("  ·  ", meta.OfType<string>()), 13, Hex(0x7D7A72)).Frame(height: 21));
        var actions = HStack(14);
        if (_mode == Mode.Record && (Questions.Count > 0 || _splitting)) actions.Children.Add(new PDButton("生成 AI 复盘", _generateReview, PDButton.Kind.Primary) { Enabled = !_splitting });
        if (_mode == Mode.Paste)
        {
            actions.Children.Add(Sans("拆题按实际用量扣积分", 12, Hex(0x9E9B91)));
            _splitButton = new PDButton("拆成问题", () => _split(_paste.Text.Trim()), PDButton.Kind.Primary) { Enabled = _paste.Text.Trim().Length > 0 && !_splitting };
            actions.Children.Add(_splitButton);
        }
        var row = Spread(titles, actions, 24);
        row.Margin = new Thickness(0, 0, 0, 26);
        return VStack(0, crumb, row);
    }

    UIElement PasteBody()
    {
        var stack = new StackPanel { Spacing = 10 };
        if (_splitError is { } error) stack.Children.Add(Sans(error + " 原文已经保留在下面。", 13, Hex(0xA35A12)).Wrap());
        else if (Questions.Count > 0) stack.Children.Add(Sans($"拆好后会替换现在的 {Questions.Count} 道题。", 13, Hex(0xA35A12)).Wrap());
        stack.Children.Add(Sans("随便贴：面试后的笔记、和朋友的聊天记录都行，不用整理格式", 13, PD.Body).Wrap());
        stack.Children.Add(new Border
        {
            Child = _paste, MinHeight = 360, CornerRadius = new CornerRadius(10), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        });
        var note = Sans("点“拆成问题”后会回到资料，AI 在后台按问题拆开、把回答和追问归到对应的题下面；拆好后直接存成面试记录。", 12, PD.Mute).Wrap();
        stack.Children.Add(Spread(note, _count, 16, VerticalAlignment.Top));
        return stack;
    }

    static UIElement SplittingBody()
    {
        var stack = new StackPanel { Spacing = 10, Margin = new Thickness(0, 80, 0, 0), HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        stack.Children.Add(Sans("正在把你贴的文字拆成问题", 15, Txt, Medium).Align(HorizontalAlignment.Center));
        var detail = Sans("一般 20–40 秒。可以先回资料做别的，拆好后会直接存成面试记录，这里也会自动刷新。", 13, PD.Body).Wrap();
        detail.TextAlignment = TextAlignment.Center;
        stack.Children.Add(detail);
        return stack;
    }
}

/// <summary>
/// 面试记录阅读（Mac `RecordReaderView`，Web `progress/RecordReader.tsx`）：所有题连着读 + 右侧 200 宽细目录。
/// 求职进度的面试记录、模拟面试的「翻看面试记录」共用。Mac 由外层按 `RecordOffsets` 算 active；这里直接监听外层 ScrollViewer：
/// 读到哪一题＝最后一个顶边越过目录顶部（视口顶 60）的题。
/// </summary>
public sealed class RecordReaderView : UserControl
{
    readonly List<RecordQuestion> _questions;
    int _active;
    readonly Action<int> _setActive;
    readonly ScrollViewer _proxy;
    readonly Func<RecordQuestion, int, string?> _missing;
    readonly List<FrameworkElement> _blocks = [];
    readonly List<(Border Badge, TextBlock Number)> _badges = [];
    readonly StackPanel _index = new() { Spacing = 2, Width = 200, Margin = new Thickness(0, 20, 0, 0), VerticalAlignment = VerticalAlignment.Top };

    public RecordReaderView(IReadOnlyList<RecordQuestion> questions, int active, Action<int> setActive, ScrollViewer proxy, Func<RecordQuestion, int, string?>? missing = null)
    {
        _questions = questions.ToList();
        _active = active;
        _setActive = setActive;
        _proxy = proxy;
        _missing = missing ?? ((_, _) => null);
        var list = new StackPanel();
        for (var position = 0; position < _questions.Count; position++)
        {
            var block = Block(_questions[position], position);
            _blocks.Add(block);
            list.Children.Add(block);
        }
        _index.Named("目录");
        var row = Columns(60, (Star(), list), (Px(200), _index));
        list.VerticalAlignment = VerticalAlignment.Top;
        Content = row;
        RenderIndex();
        _proxy.ViewChanged += OnScroll;
        Unloaded += (_, _) => _proxy.ViewChanged -= OnScroll;
    }

    void OnScroll(object? sender, ScrollViewerViewChangedEventArgs e)
    {
        const double line = 60;
        var next = 0;
        for (var position = 0; position < _blocks.Count; position++)
        {
            var top = _blocks[position].TransformToVisual(_proxy).TransformPoint(new Windows.Foundation.Point(0, 0)).Y;
            if (top <= line) next = position;
        }
        if (next != _active) Select(next);
    }

    void Select(int position)
    {
        _active = position;
        _setActive(position);
        for (var i = 0; i < _badges.Count; i++)
        {
            _badges[i].Badge.Background = Brush(i == _active ? Hex(0xEEF3FD) : Hex(0xF6F6F3));
            _badges[i].Number.Foreground = Brush(i == _active ? PD.BlueText : Hex(0x9E9B91));
        }
        RenderIndex();
    }

    static string Title(RecordQuestion item) => item.Question.Trim() is { Length: > 0 } question ? question : "（没记下问题）";

    FrameworkElement Block(RecordQuestion item, int position)
    {
        var follows = item.FollowUps.Where(x => x.Question.Trim().Length > 0 || x.Answer.Trim().Length > 0).ToList();
        var number = Label(Two(position + 1), 11, position == _active ? PD.BlueText : Hex(0x9E9B91), Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        var badge = new Border { Width = 26, Height = 26, CornerRadius = new CornerRadius(7), Background = Brush(position == _active ? Hex(0xEEF3FD) : Hex(0xF6F6F3)), Child = number, VerticalAlignment = VerticalAlignment.Top };
        _badges.Add((badge, number));
        var question = Sans(Title(item), 17, Txt, Medium).Spaced(5).Wrap();
        question.MinHeight = 26;
        var head = Columns(14, (Auto, badge), (Star(), question));
        var bubbles = new StackPanel { Spacing = 10, Margin = new Thickness(40, 0, 0, 0) };
        bubbles.Children.Add(item.Answer.Trim().Length == 0 ? Bubble(_missing(item, position) ?? "这道题没记下回答", true, true) : Bubble(item.Answer, true));
        if (item.Reply is { } reply && reply.Trim().Length > 0) bubbles.Children.Add(Bubble(reply, false));
        foreach (var follow in follows)
        {
            if (follow.Question.Trim().Length > 0) bubbles.Children.Add(Bubble(follow.Question, false));
            if (follow.Answer.Trim().Length > 0) bubbles.Children.Add(Bubble(follow.Answer, true));
        }
        var block = new Border
        {
            Child = VStack(14, head, bubbles), Padding = new Thickness(0, 28, 0, 28), BorderBrush = Brush(Cl), BorderThickness = new Thickness(0, 0, 0, 1),
        }.Named($"第 {position + 1} 题");
        return block;
    }

    /// <summary>`.rp-say`：14px / 24 行高，没记回答时 13px / 22、虚线框；我的回答右对齐（最宽 520），对方左对齐（最宽 420）。</summary>
    static FrameworkElement Bubble(string text, bool me, bool missing = false)
    {
        var label = Sans(text, missing ? 13 : 14, missing ? Hex(0x9E9B91) : Txt).LineHeight(missing ? 22 : 24).Wrap().Selectable();
        var radius = new CornerRadius(16, 16, me ? 6 : 16, me ? 16 : 6);
        var bubble = new Border
        {
            Child = label, Padding = new Thickness(16, missing ? 11 : 12, 16, missing ? 11 : 12), CornerRadius = radius,
            Background = Brush(missing ? Clear : me ? Hex(0xEEF3FD) : Hex(0xF6F6F3)),
        };
        var grid = new Grid { MaxWidth = me ? 520 : 420, HorizontalAlignment = me ? HorizontalAlignment.Right : HorizontalAlignment.Left };
        grid.Children.Add(bubble);
        if (missing)
        {
            var outline = new Microsoft.UI.Xaml.Shapes.Path { Stroke = Brush(Cl), StrokeThickness = 1, StrokeDashArray = [4, 3], IsHitTestVisible = false };
            grid.SizeChanged += (_, e) => outline.Data = Uneven(e.NewSize.Width, e.NewSize.Height, 16, 16, me ? 6 : 16, me ? 16 : 6);
            grid.Children.Add(outline);
        }
        return grid;
    }

    void RenderIndex()
    {
        _index.Children.Clear();
        var head = Spread(Sans("目录", 12, Hex(0x7D7A72), Medium), Sans($"{_questions.Count} 道题", 12, Hex(0x9E9B91)), 8);
        head.Height = 18;
        head.Margin = new Thickness(0, 0, 0, 6);
        _index.Children.Add(head);
        for (var position = 0; position < _questions.Count; position++)
        {
            var item = _questions[position];
            var on = position == _active;
            var title = Sans(Title(item), 12, on ? PD.BlueText : position < _active ? Txt : Hex(0x7D7A72), on ? Medium : Regular);
            var row = new Grid { ColumnSpacing = 8, Height = 18 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = Auto });
            row.Children.Add(Label(Two(position + 1), 11, on ? PD.BlueText : Hex(0x9E9B91), Medium).Align(v: VerticalAlignment.Center));
            Grid.SetColumn(title, 1);
            title.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(title);
            if (item.FollowUps.Count > 0)
            {
                var dot = Dot(V3.Orange, 6).Named("被追问过");
                Grid.SetColumn(dot, 2);
                row.Children.Add(dot);
            }
            var cell = new Border
            {
                Child = row, Padding = new Thickness(on ? 11 : 12, 5, 4, 5), BorderBrush = Brush(on ? PD.Blue : Cl), BorderThickness = new Thickness(on ? 2 : 1, 0, 0, 0),
                Background = Brush(Clear),
            };
            var target = position;
            _index.Children.Add(cell.OnTap(() => ScrollTo(target), Title(item)));
        }
        if (_questions.Any(x => x.FollowUps.Count > 0))
        {
            var legend = HStack(6, Dot(V3.Orange, 6), Sans("被追问过", 11, Hex(0x9E9B91)));
            legend.Margin = new Thickness(12, 14, 0, 0);
            _index.Children.Add(legend);
        }
    }

    void ScrollTo(int position)
    {
        if (position >= _blocks.Count) return;
        var top = _blocks[position].TransformToVisual((UIElement)_proxy.Content).TransformPoint(new Windows.Foundation.Point(0, 0)).Y;
        _proxy.ChangeView(null, top, null, false);
        Select(position);
    }
}
