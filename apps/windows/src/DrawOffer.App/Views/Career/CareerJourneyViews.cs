using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>投递详情各块的颜色（Windows 稿 07 页 04–09 分区，Mac `CareerJourneyStyle`）。</summary>
static class JS
{
    public static readonly Color Ink = Hex(0x1D1D1B), Body = Hex(0x55554F), Sub = Hex(0x6C6C65), Mute = Hex(0x96968F),
        Line = Hex(0xE4E4E0), Track = Hex(0xC9C9C3), Blue = Hex(0x3F6FD8), Orange = Hex(0xD9822B), Check = Hex(0xB9B9B3);
}

/// <summary>
/// 投递详情各块的画法（Windows 稿 07 页 04–09 分区，Mac `CareerJourneyViews.swift`）。
/// 文案与状态在 Core `CareerJourney`；数据、弹窗和跳转在 `CareerApplicationDetailView`。
/// </summary>
static class CareerJourneyUI
{
    /// <summary>灰色文字按钮，悬停变墨色（不加底色）。</summary>
    public static TextBlock TextButton(string title, Action action, double size = 13, Color? color = null)
    {
        var tint = color ?? JS.Body;
        var text = Sans(title, size, tint);
        text.OnHover(h => text.Foreground = Brush(h ? JS.Ink : tint));
        return text.OnTap(action, title);
    }

    /// <summary>蓝色文字链，悬停加下划线。</summary>
    public static TextBlock Link(string title, Action action, double size = 13)
    {
        var text = Sans(title, size, JS.Blue);
        text.OnHover(h => text.TextDecorations = h ? TextDecorations.Underline : TextDecorations.None);
        return text.OnTap(action, title);
    }

    // 这一步（各分区上半左侧）

    /// <summary>
    /// 眉题（公司 · 岗位 + 蓝色阶段）→ 结论标题 30/600 → 一句说明 → 地点或会议链接 → 这一轮的资料 → 按钮（右侧已有黑按钮时左边只留白按钮）。
    /// </summary>
    public static StackPanel Hero(string job, CareerJourneyStep step, IReadOnlyList<JsonNode> files, bool sideHasBlack, bool disabled,
        Action<CareerJourneyAction> act, Action<string> copy, Action<JsonNode> openFile, Action addFromComputer, Action addFromLibrary)
    {
        var stack = VStack(0,
            HStack(20, Sans(job, 12.5, JS.Ink, Medium).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis), Sans(step.Stage, 12.5, JS.Blue, Medium)),
            Label(step.Title, 30, JS.Ink, Semibold).LineHeight(40).Wrap().Top(10).Also(t => AutomationProperties.SetHeadingLevel(t, AutomationHeadingLevel.Level1)));
        if (step.Desc is { Length: > 0 } desc) stack.Children.Add(Sans(desc, 14, JS.Body).LineHeight(23).Wrap().Top(10));
        if (step.Place is { } place) stack.Children.Add(PlaceRow(place, act, copy).Top(22));
        if (files.Count > 0) stack.Children.Add(FilesRow(files, openFile, addFromComputer, addFromLibrary).Top(20));
        if (step.Primary is not null || step.Secondary is not null)
        {
            var buttons = HStack(10);
            if (step.Primary is { } primary) buttons.Children.Add(Button(primary, !sideHasBlack, disabled, act));
            if (step.Secondary is { } secondary)
                buttons.Children.Add(Button(secondary, step.Primary is null && !sideHasBlack && secondary.Action != CareerJourneyAction.BackToNow, disabled, act));
            stack.Children.Add(buttons.Top(26));
        }
        return stack;
    }

    static PDButton Button(CareerJourneyButton item, bool black, bool disabled, Action<CareerJourneyAction> act) =>
        new(item.Label, () => act(item.Action), black ? PDButton.Kind.Primary : PDButton.Kind.Normal, enabled: !disabled);

    static FrameworkElement PlaceRow(CareerJourneyPlace place, Action<CareerJourneyAction> act, Action<string> copy)
    {
        var text = Sans(place.Text, 13.5, JS.Ink).Also(t => { t.TextTrimming = TextTrimming.CharacterEllipsis; t.MaxWidth = 360; });
        if (place.Url is { } url)
        {
            text.OnHover(h => text.TextDecorations = h ? TextDecorations.Underline : TextDecorations.None);
            text.OnTap(() => _ = Windows.System.Launcher.LaunchUriAsync(url), place.Text);
        }
        var row = HStack(10, Icon("link", 13, JS.Mute), text, TextButton("复制", () => copy(place.Copy), 13, JS.Sub));
        if (place.Editable) { row.Children.Add(Sans("·", 13, JS.Mute)); row.Children.Add(TextButton("修改安排", () => act(CareerJourneyAction.Reschedule), 13, JS.Sub)); }
        foreach (var child in row.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
        return row;
    }

    static FrameworkElement FilesRow(IReadOnlyList<JsonNode> files, Action<JsonNode> openFile, Action addFromComputer, Action addFromLibrary)
    {
        var flow = new VariableSizedFlow(8);
        flow.Add(Sans("资料", 12.5, JS.Mute).Frame(height: 28).Also(t => { t.Padding = new Thickness(0, 5, 4, 0); }));
        foreach (var asset in files)
        {
            var name = asset.Text("original_file_name");
            var chip = new Border
            {
                Child = HStack(6, Icon("doc", 11, JS.Body), Sans(name, 12.5, JS.Body).Also(t => { t.TextTrimming = TextTrimming.CharacterEllipsis; t.MaxWidth = 180; })).Align(v: VerticalAlignment.Center),
                Height = 28, Padding = new Thickness(10, 0, 10, 0), CornerRadius = new CornerRadius(8),
                Background = Brush(V3.White), BorderBrush = Brush(JS.Line), BorderThickness = new Thickness(1),
            }.Tip(name);
            flow.Add(chip.OnTap(() => openFile(asset), name));
        }
        var add = new Grid { Height = 28 };
        add.Children.Add(new Rectangle { RadiusX = 8, RadiusY = 8, Stroke = Brush(JS.Line), StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 3, 2 } });
        add.Children.Add(Sans("＋ 添加", 12.5, JS.Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center).Pad(10, 0, 10, 0));
        add.OnTap(() => V3Popover.Menu(add, 140, [new V3MenuRow("从电脑选", addFromComputer), new V3MenuRow("从资料库选", addFromLibrary)]), "添加资料");
        flow.Add(add);
        return flow.Panel;
    }

    // 右侧公共件

    /// <summary>灰色小标题（strong 时墨色 16/500），右侧可带文字按钮。</summary>
    public static FrameworkElement SideHead(string title, bool strong = false, string? count = null, string? more = null, Action? onMore = null)
    {
        var left = HStack(10, Sans(title, strong ? 16 : 13, strong ? JS.Ink : JS.Sub, strong ? Medium : Regular));
        if (count is not null) left.Children.Add(Number(count, 12.5, JS.Mute, Medium).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 1));
        return Columns(12, (Star(), left), (Auto, more is null ? new Border() : TextButton(more, onMore ?? (() => { }))));
    }

    /// <summary>虚线入口（录音、生成清单、笔试题）：#FAFAF8 底、圆角 12；转写中换成实线和细进度条。</summary>
    public static FrameworkElement Drop(string icon, string title, string text, bool busy = false, params UIElement[] actions)
    {
        var body = VStack(6,
            Icon(icon, 18, JS.Sub).Align(HorizontalAlignment.Center).Frame(height: 22).Pad(0, 0, 0, 8),
            Sans(title, 16, JS.Ink, Medium).LineHeight(24).Wrap().Also(t => { t.TextAlignment = TextAlignment.Center; t.HorizontalAlignment = HorizontalAlignment.Center; }));
        if (busy) body.Children.Add(new ProgressBar { IsIndeterminate = true, MaxWidth = 240, Height = 3, MinHeight = 3, Foreground = Brush(JS.Blue), Background = Brush(JS.Line), Margin = new Thickness(0, 8, 0, 4) });
        body.Children.Add(Sans(text, 12.5, JS.Body).LineHeight(19).Wrap().Also(t => { t.TextAlignment = TextAlignment.Center; t.MaxWidth = 340; t.HorizontalAlignment = HorizontalAlignment.Center; }));
        if (actions.Length > 0)
        {
            var row = HStack(10, actions);
            row.HorizontalAlignment = HorizontalAlignment.Center;
            foreach (var child in row.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
            body.Children.Add(row.Top(10));
        }
        body.Padding = new Thickness(28, 40, 28, 38);
        var grid = new Grid();
        grid.Children.Add(new Rectangle
        {
            RadiusX = 12, RadiusY = 12, Fill = Brush(Hex(0xFAFAF8)), Stroke = Brush(busy ? JS.Line : Hex(0xD8D8D3)), StrokeThickness = 1,
            StrokeDashArray = busy ? null : new DoubleCollection { 4, 3 },
        });
        grid.Children.Add(body);
        return grid;
    }

    /// <summary>三个大数字。</summary>
    public static FrameworkElement Stats(params (int Value, string Label, bool Orange)[] items)
    {
        var row = HStack(48);
        foreach (var item in items)
            row.Children.Add(VStack(4, Number($"{item.Value}", 30, item.Orange ? JS.Orange : JS.Ink, Medium).Frame(height: 36), Sans(item.Label, 12.5, JS.Sub)));
        return row;
    }

    /// <summary>题目卡片（问到的题、没答到位的地方）：白底圆角 12、#E4E4E0 细边。</summary>
    public static FrameworkElement Card(string title, string meta, string? quote, string link, Action action)
    {
        var stack = VStack(0,
            Sans(title, 16, JS.Ink, Medium).Frame(height: 22).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis),
            Sans(meta, 12.5, JS.Sub).Wrap().Top(6));
        if (quote is not null) stack.Children.Add(Sans(quote, 12.5, JS.Body).LineHeight(17).Wrap(2).Top(5));
        stack.Children.Add(Link(link, action, 12.5).Top(10));
        return new Border
        {
            Child = stack, Padding = new Thickness(16, 14, 16, 14), CornerRadius = new CornerRadius(12),
            Background = Brush(V3.White), BorderBrush = Brush(JS.Line), BorderThickness = new Thickness(1),
        };
    }

    /// <summary>一张简历纸的缩略（没选简历时线条变淡）。</summary>
    public static FrameworkElement Paper(bool empty)
    {
        Border Bar(double width, double height, Color color) => new()
        {
            Width = width, Height = height, CornerRadius = new CornerRadius(1), HorizontalAlignment = HorizontalAlignment.Left,
            Background = Brush(empty ? Alpha(Hex(0xE1E1DC), 0.45) : color),
        };
        var stack = VStack(0, Bar(58, 6, Hex(0x3D3D39)), Bar(84, 3, Hex(0xD6D6D1)).Top(6));
        double[][] groups = [[100, 92, 64], [100, 96, 80, 52], [100, 70]];
        for (var g = 0; g < groups.Length; g++)
        {
            stack.Children.Add(Bar(28, 3, Hex(0x9A9A93)).Top(g == 0 ? 15 : 13));
            for (var r = 0; r < groups[g].Length; r++) stack.Children.Add(Bar(groups[g][r], 2.5, Hex(0xE1E1DC)).Top(r == 0 ? 6 : 4.5));
        }
        var paper = new Border
        {
            Child = stack, Width = 132, Height = 176, Padding = new Thickness(15, 17, 15, 17), CornerRadius = new CornerRadius(4),
            Background = Brush(V3.White), BorderBrush = Brush(JS.Line), BorderThickness = new Thickness(1), Opacity = empty ? 0.6 : 1,
        };
        if (!empty) paper.Elevate(6);
        AutomationProperties.SetAccessibilityView(paper, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return paper;
    }

    // 右侧：这场面试的记录（07.01 / 07.02）

    public static FrameworkElement RecordEntrySide(CareerJourney.RecordState state, bool busy, Action upload, Action paste, Action<string> retry)
    {
        FrameworkElement drop = state switch
        {
            CareerJourney.RecordState.Transcribing t => Drop("mic", $"正在把「{t.File}」转成文字",
                t.Minutes is { } minutes ? $"大约 {minutes} 分钟，好了会自动按问题拆好，可以先离开。" : "好了会自动按问题拆好，可以先离开。", busy: true),
            CareerJourney.RecordState.Failed f => Drop("exclamationmark.circle", $"「{f.File}」没能转成文字", "可以重新转一次，或者换成粘贴文字。", false,
                new PDButton("重新转文字", () => retry(f.DatasetId), PDButton.Kind.Primary, enabled: !busy), new PDButton("粘贴文字", paste)),
            _ => Drop("mic", "把录音放到这里", "自动转文字、按问题拆好；没录音也可以贴一段回忆。", false,
                new PDButton("上传录音", upload, PDButton.Kind.Primary, enabled: !busy), new PDButton("粘贴文字", paste)),
        };
        var stack = VStack(14, SideHead("这场面试的记录"), drop);
        AutomationProperties.SetName(stack, "这场面试的记录");
        return stack;
    }

    // 右侧：复盘结论（07.07）、这次留下的（09.05 / 09.06）

    public static FrameworkElement WeakList(IEnumerable<CareerJourney.WeakPoint> points, Action<string> practice) =>
        VStack(12, points.Select(p => (UIElement)Card(p.Title, p.Detail, p.Quote, "去模拟面试练这一处 ›", () => practice(p.Title))).ToArray());

    public static FrameworkElement ReviewSide(JsonNode session, JsonNode? detail, Action openReview, Action<string> practice)
    {
        var report = session.Get("review_report");
        var points = CareerJourney.WeakPoints(session);
        var asked = CareerReview.IsV2(report)
            ? report.Items("questions").Count(x => x.Text("kind") is not ("reverse" or "follow_up"))
            : InterviewRecord.Parse(CareerJourney.Markdown(session, detail)).Count;
        var stack = VStack(14, Stats((asked, "问到的题", false), (Math.Max(0, asked - points.Count), "答到位", false), (points.Count, "没答到位", points.Count > 0)));
        if (points.Count == 0)
            stack.Children.Add(Sans(CareerJourney.ReviewDetail(session).NonEmpty() ?? "每道题都答到了位。", 14, JS.Sub).LineHeight(23).Wrap());
        else
        {
            stack.Children.Add(SideHead("没答到位的地方", more: points.Count > 2 ? $"还有 {points.Count - 2} 处 ›" : null, onMore: openReview).Top(16));
            stack.Children.Add(WeakList(points.Take(2), practice));
        }
        AutomationProperties.SetName(stack, "复盘结论");
        return stack;
    }

    public static FrameworkElement LeftSide(CareerDeck deck, IReadOnlyDictionary<string, JsonNode> details, Action openReview, Action<string> practice)
    {
        var interviews = deck.Stations.Count(x => x.Kind == CareerStationKind.Interview && x.Session is { } s && s.Text("status") != "cancelled");
        var recorded = deck.Stations.Sum(x => x.Session is { } s ? InterviewRecord.Parse(CareerJourney.Markdown(s, details.GetValueOrDefault(s.Text("id")))).Count : 0);
        var points = deck.Stations.SelectMany(x => CareerJourney.WeakPoints(x.Session, x.Short)).ToList();
        var stack = VStack(14, Stats((deck.Days, "天", false), (interviews, "场面试", false), (recorded, "道题记下来", false)));
        if (points.Count > 0)
        {
            stack.Children.Add(SideHead("下次还要补的", more: points.Count > 2 ? $"全部 {points.Count} 处 ›" : null, onMore: openReview).Top(16));
            stack.Children.Add(WeakList(points.Take(2), practice));
        }
        AutomationProperties.SetName(stack, "这次留下的");
        return stack;
    }

    // 右侧：笔试题

    public static FrameworkElement WrittenSide(JsonNode session, JsonNode? detail, Action open, Action add)
    {
        var questions = detail.Get("session")?.Get("written_questions") is JsonArray fromDetail ? fromDetail.Items() : session.Items("written_questions");
        var wrong = questions.Count(x => x.Text("correctness") == "wrong");
        var correct = questions.Count(x => x.Text("correctness") == "correct");
        var stack = VStack(14, SideHead("笔试题", more: questions.Count == 0 ? null : "查看全部 ›", onMore: open));
        if (questions.Count == 0)
            stack.Children.Add(Drop("doc", "还没有题目", "上传题目截图或文档，AI 读出题目后可以逐题标答对、答错。", false, new PDButton("添加笔试题", add)));
        else
        {
            stack.Children.Add(Stats((questions.Count, "道题", false), (correct, "答对", false), (wrong, "答错", wrong > 0)));
            var list = new StackPanel();
            foreach (var item in questions.Take(4))
            {
                var isWrong = item.Text("correctness") == "wrong";
                var row = Columns(10,
                    (Px(24), Number(item.Display("question_no"), 12, JS.Mute, Medium).Align(v: VerticalAlignment.Center)),
                    (Star(), Sans(item.Text("question_text"), 13.5, JS.Ink).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis).Align(v: VerticalAlignment.Center)),
                    (Px(8), new Ellipse { Width = 6, Height = 6, Fill = Brush(isWrong ? JS.Orange : Clear), VerticalAlignment = VerticalAlignment.Center }));
                if (isWrong) AutomationProperties.SetName(row, "答错");
                list.Children.Add(new Border { Child = row, Padding = new Thickness(0, 10, 0, 10), BorderBrush = Brush(JS.Line), BorderThickness = new Thickness(0, 1, 0, 0) });
            }
            stack.Children.Add(list);
        }
        AutomationProperties.SetName(stack, "笔试题");
        return stack;
    }

    // 右侧：Offer 与 OC（09.01 / 09.02 / 09.04）

    public static FrameworkElement OfferSide(JsonNode app, bool oc, bool accepted)
    {
        var stack = new StackPanel { Spacing = 14 };
        if (oc)
        {
            var at = app.Text("oc_communicated_at");
            stack.Children.Add(SideHead("电话里说的"));
            stack.Children.Add(Salary(app.Text("oc_salary_text").NonEmpty() ?? "没说薪资", "口头，以正式 Offer 为准"));
            stack.Children.Add(Rows([("预计入职", app.Text("oc_start_text").NonEmpty()), ("联系人", app.Text("oc_contact").NonEmpty()),
                ("沟通时间", at.Length == 0 ? null : CareerFormat.MonthDay(at))]));
        }
        else
        {
            var due = CareerJourney.OfferDate(app.Text("offer_reply_due_on"));
            stack.Children.Add(SideHead("这份 Offer"));
            stack.Children.Add(Salary(CareerJourney.OfferSalary(app) ?? "还没填薪资", CareerJourney.OfferYearly(app)));
            stack.Children.Add(Rows([("入职", CareerJourney.DotDate(app.Text("offer_start_on"))), ("试用期", app.Text("offer_probation").NonEmpty()),
                ("地点", app.Text("offer_base_location").NonEmpty()),
                accepted ? ("接受日期", app.Text("terminated_at").Length == 0 ? "—" : CareerFormat.MonthDay(app.Text("terminated_at")))
                         : ("答复截止", due is { } d ? CareerDeckFormat.MonthDay(d) : null)]));
        }
        AutomationProperties.SetName(stack, oc ? "电话里说的" : "这份 Offer");
        return stack;
    }

    static FrameworkElement Salary(string text, string? note)
    {
        var big = new Viewbox { Child = Label(text, 40, JS.Ink, Semibold), StretchDirection = StretchDirection.DownOnly, HorizontalAlignment = HorizontalAlignment.Left, MaxHeight = 56 };
        return Columns(12, (Auto, big), (Star(), note is null ? new Border() : Sans(note, 13, JS.Sub).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 10)));
    }

    static FrameworkElement Rows(IReadOnlyList<(string Label, string? Value)> items)
    {
        var grid = new Grid { ColumnSpacing = 24, RowSpacing = 18, Margin = new Thickness(0, 10, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        for (var i = 0; i < items.Count; i++)
        {
            if (i % 2 == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var cell = VStack(4, Sans(items[i].Label, 12.5, JS.Sub), Sans(items[i].Value ?? "没填", 15, JS.Ink, Medium).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis));
            Grid.SetRow(cell, i / 2);
            Grid.SetColumn(cell, i % 2);
            grid.Children.Add(cell);
        }
        return grid;
    }
}

/// <summary>右侧：投的这份简历（04.01 / 04.02 / 04.03）：简历纸缩略 + 标签、标题、匹配度说明与「打开简历 › / 换一份 ›」。</summary>
sealed class CareerJourneyResumeSide : UserControl
{
    readonly JsonNode _app;
    readonly bool _pending;
    readonly Action _open, _pick;
    JobMatch? _match;

    public CareerJourneyResumeSide(JsonNode app, bool pending, Action open, Action pick)
    {
        (_app, _pending, _open, _pick) = (app, pending, open, pick);
        Render();
        Loaded += async (_, _) => await LoadMatchAsync();
    }

    string? Note()
    {
        if (_match is { Ready: true, Score: { } score } match)
        {
            var gaps = match.Gaps.Take(2).ToList();
            return gaps.Count == 0 ? $"和这个岗位匹配 {score} 分。" : $"和这个岗位匹配 {score} 分，还缺 {string.Join("、", gaps)}。";
        }
        if (_pending) return "投递时会用这一份，也可以换。";
        var applied = _app.Text("applied_at");
        return string.Join(" · ", new[] { CareerDeck.Source(_app), applied.Length == 0 ? null : CareerFormat.MonthDay(applied) + " 投递" }.OfType<string>());
    }

    void Render()
    {
        var title = _app.Text("resume_title_snapshot");
        var label = _pending ? "准备投的简历" : "投的这份简历";
        var info = VStack(0, Sans(label, 12.5, JS.Sub, Medium).Frame(height: 16));
        if (title.Length == 0)
        {
            info.Children.Add(Label(_pending ? "还没选简历" : "还没记是哪一份", 18, JS.Sub, Semibold).Top(10));
            info.Children.Add(Sans(_pending ? "记录投递时选一份，之后的准备和复盘都会参考它。" : "补上投的那份简历，复盘会更准。", 13.5, JS.Body).LineHeight(22).Wrap().Top(8));
            info.Children.Add(CareerJourneyUI.TextButton("选一份简历 ›", _pick).Top(14));
        }
        else
        {
            info.Children.Add(Label(title, 18, JS.Ink, Semibold).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis).Tip(title).Top(10));
            if (Note() is { Length: > 0 } note) info.Children.Add(Sans(note, 13.5, JS.Body).LineHeight(22).Wrap().Top(8));
            var links = HStack(24);
            if (_app.Text("resume_id").Length > 0) links.Children.Add(CareerJourneyUI.TextButton("打开简历 ›", _open));
            if (_pending) links.Children.Add(CareerJourneyUI.TextButton("换一份 ›", _pick));
            info.Children.Add(links.Top(14));
        }
        var row = Columns(28, (Auto, CareerJourneyUI.Paper(title.Length == 0)), (Star(), info.Align(v: VerticalAlignment.Center)));
        AutomationProperties.SetName(row, label);
        Content = row;
    }

    async Task LoadMatchAsync()
    {
        var job = _app.Text("job_description_id");
        var resume = _app.Text("resume_id");
        if (job.Length == 0 || resume.Length == 0) return;
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/job-descriptions/{job}/match", "GET", new Dictionary<string, string> { ["resume_id"] = resume }, null);
            _match = JobMatch.From(result.Get("match"));
            Render();
        }
        catch (Exception) { }
    }
}

/// <summary>
/// 右侧：准备清单（05.02 / 06.x / 08.01–08.03）：标题「X 前要准备的 n / m」；还没生成时虚线入口里的「生成准备清单」是唯一黑按钮；
/// 勾选圆点、标题可删除线；技术 / 系统设计 / 项目类带「去练这一处 ›」；超过 6 项时框内滚动、已完成折叠；底部一行自己加。
/// </summary>
sealed class CareerJourneyPrepSide : UserControl
{
    static readonly HashSet<string> PracticeCategories = ["technical", "system_design", "project"];
    static readonly Dictionary<string, string> CategoryLabels = new()
    {
        ["technical"] = "技术知识", ["system_design"] = "系统设计", ["project"] = "项目深挖", ["behavioral"] = "行为面试", ["company"] = "公司调研", ["logistics"] = "面试安排",
    };

    readonly string _short;
    readonly JsonNode? _session;
    readonly bool _busy;
    readonly string? _cost;
    readonly Action<List<JsonNode>> _save;
    readonly Action _generate;
    readonly Action<string> _practice;
    bool _showDone;

    public CareerJourneyPrepSide(string shortName, JsonNode? session, bool busy, string? cost, Action<List<JsonNode>> save, Action generate, Action<string> practice)
    {
        (_short, _session, _busy, _cost, _save, _generate, _practice) = (shortName, session, busy, cost, save, generate, practice);
        Render();
    }

    static bool Done(JsonNode item) => item.Bool("done");

    void Render()
    {
        var title = $"{_short}前要准备的";
        var stack = new StackPanel { Spacing = 14 };
        if (_session is { } session)
        {
            var items = session.Items("prep_items");
            var done = items.Count(Done);
            stack.Children.Add(CareerJourneyUI.SideHead(title, strong: true, count: items.Count == 0 ? null : $"{done} / {items.Count}"));
            if (items.Count == 0)
            {
                if (session.Get("prep_generated_at") is null)
                {
                    // 08.02：还没有清单时，右侧的「生成准备清单」是唯一的黑按钮
                    var actions = new List<UIElement> { new PDButton("生成准备清单", _generate, PDButton.Kind.Primary, enabled: !_busy) };
                    if (_cost is not null) actions.Add(Sans(_cost, 12, JS.Mute));
                    stack.Children.Add(CareerJourneyUI.Drop("list.bullet", _busy ? "正在生成准备清单…" : "还没有准备清单",
                        "按岗位要求、你的简历和上一轮复盘，列出这一轮前该补的几件事。每场面试只能生成一次。", false, actions.ToArray()));
                }
                else stack.Children.Add(Sans("清单已经清空了，可以自己加几条。", 13.5, JS.Sub).LineHeight(22).Wrap());
            }
            else stack.Children.Add(List(items));
            stack.Children.Add(AddRow(items));
        }
        else
        {
            stack.Children.Add(CareerJourneyUI.SideHead(title, strong: true));
            stack.Children.Add(Sans("安排好时间以后，可以按岗位要求和你的简历生成准备清单。", 13.5, JS.Sub).LineHeight(22).Wrap());
        }
        AutomationProperties.SetName(stack, title);
        Content = stack;
    }

    FrameworkElement List(List<JsonNode> items)
    {
        var order = items.Select((item, index) => (Index: index, Item: item)).ToList();
        var open = order.Where(x => !Done(x.Item)).ToList();
        var closed = order.Where(x => Done(x.Item)).ToList();
        var fold = items.Count > 6;
        var rows = new StackPanel();
        foreach (var (index, item) in open) rows.Children.Add(Row(index, item, items));
        if (!fold || _showDone) foreach (var (index, item) in closed) rows.Children.Add(Row(index, item, items));
        if (!fold) return rows;
        // 08.03：清单很长时右侧高度固定，超出在框内滚动、底部渐隐
        var scroll = V3.Scroll(rows.Pad(0, 0, 14, 0));
        scroll.MaxHeight = 342;
        var fade = new Border
        {
            Height = 24, VerticalAlignment = VerticalAlignment.Bottom, IsHitTestVisible = false,
            Background = new LinearGradientBrush { StartPoint = new Windows.Foundation.Point(0, 0), EndPoint = new Windows.Foundation.Point(0, 1), GradientStops = { new GradientStop { Color = Alpha(V3.White, 0), Offset = 0 }, new GradientStop { Color = V3.White, Offset = 1 } } },
        };
        var box = new Grid();
        box.Children.Add(scroll);
        box.Children.Add(fade);
        var stack = VStack(0, box);
        if (closed.Count > 0)
        {
            var toggle = Columns(8, (Star(), Sans($"已完成 {closed.Count} 项", 13, JS.Mute)), (Auto, Sans(_showDone ? "收起" : "展开 ›", 13, JS.Sub)));
            stack.Children.Add(new Border { Child = toggle, Padding = new Thickness(0, 11, 0, 0), BorderBrush = Brush(JS.Line), BorderThickness = new Thickness(0, 1, 0, 0), Background = Brush(Clear) }
                .OnTap(() => { _showDone = !_showDone; Render(); }, _showDone ? "收起已完成" : "展开已完成"));
        }
        return stack;
    }

    FrameworkElement Row(int index, JsonNode item, List<JsonNode> items)
    {
        var done = Done(item);
        var category = item.Text("category");
        var detail = string.Join(" · ", new[] { item.Text("source_label").NonEmpty(), item.Text("reason").NonEmpty(), category != "other" ? CategoryLabels.GetValueOrDefault(category) : null }.OfType<string>());
        var mark = new Grid { Width = 18, Height = 18 };
        mark.Children.Add(new Ellipse { Fill = Brush(done ? JS.Ink : V3.White), Stroke = Brush(done ? JS.Ink : JS.Check), StrokeThickness = 1.5 });
        if (done) mark.Children.Add(Icon("checkmark", 9, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center));
        mark.OnTap(() => Toggle(index, items), item.Text("title"), () => !_busy);
        var title = Sans(item.Text("title"), 13.5, done ? JS.Mute : JS.Ink).Wrap(2);
        if (done) title.TextDecorations = TextDecorations.Strikethrough;
        var text = VStack(3, title);
        if (detail.Length > 0) text.Children.Add(Sans(detail, 12, done ? JS.Check : JS.Mute).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis));
        var row = Columns(14, (Auto, mark.Align(v: VerticalAlignment.Center)), (Star(), text.Align(v: VerticalAlignment.Center)),
            (Auto, !done && PracticeCategories.Contains(category) ? CareerJourneyUI.Link("去练这一处 ›", () => _practice(item.Text("title")), 12.5).Align(v: VerticalAlignment.Center) : new Border()));
        row.Padding = new Thickness(0, 11, 0, 11);
        return row;
    }

    void Toggle(int index, List<JsonNode> items) => _save(items.Select((item, position) =>
    {
        var copy = item.DeepClone();
        if (position == index && copy is JsonObject fields) fields["done"] = !Done(item);
        return copy;
    }).ToList());

    FrameworkElement AddRow(List<JsonNode> items)
    {
        var box = new TextBox
        {
            PlaceholderText = items.Count == 0 ? "不生成，自己加一条" : "加一条准备事项", FontSize = 13.5, FontFamily = SansFamily, MaxLength = 80,
            BorderThickness = new Thickness(0), Background = Brush(Clear), Foreground = Brush(JS.Ink), PlaceholderForeground = Brush(JS.Mute),
            MinHeight = 0, Padding = new Thickness(0, 6, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsEnabled = !_busy && items.Count < 20,
        };
        foreach (var key in new[] { "TextControlBackgroundFocused", "TextControlBackgroundPointerOver" }) box.Resources[key] = Brush(Clear);
        foreach (var key in new[] { "TextControlBorderBrushFocused", "TextControlBorderBrushPointerOver" }) box.Resources[key] = Brush(Clear);
        AutomationProperties.SetName(box, "加一条准备事项");
        box.KeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Enter) return;
            e.Handled = true;
            var text = box.Text.Trim();
            if (text.Length == 0) return;
            var next = items.Select(x => x.DeepClone()).ToList();
            next.Add(new JsonObject { ["title"] = text.Length > 80 ? text[..80] : text, ["category"] = "other", ["reason"] = null, ["done"] = false });
            box.Text = "";
            _save(next);
        };
        return new Border
        {
            Child = Columns(10, (Auto, Icon("plus", 12, JS.Mute).Align(v: VerticalAlignment.Center)), (Star(), box)),
            Height = 39, Padding = new Thickness(14, 0, 14, 0), CornerRadius = new CornerRadius(8), BorderBrush = Brush(JS.Line), BorderThickness = new Thickness(1),
        };
    }
}

/// <summary>
/// 右侧：面试中问到（07.06）：按考点归组列原话（最多三张卡），考点没整理好时先按题列；每份记录只请求一次考点，失败不重试。
/// </summary>
sealed class CareerJourneyQuestionsSide : UserControl
{
    static readonly HashSet<string> Requested = [];
    readonly JsonNode _session;
    readonly JsonNode? _detail;
    readonly Action<int> _open;
    (string Markdown, List<JsonNode> Groups)? _fetched;

    public CareerJourneyQuestionsSide(JsonNode session, JsonNode? detail, Action<int> open)
    {
        (_session, _detail, _open) = (session, detail, open);
        Render();
        Loaded += async (_, _) => await FetchAsync();
    }

    string Markdown => CareerJourney.Markdown(_session, _detail);

    List<JsonNode>? Stored
    {
        get
        {
            var fromDetail = _detail.Get("session").Items("record_topics");
            if (fromDetail.Count > 0) return fromDetail;
            var fromSession = _session.Items("record_topics");
            if (fromSession.Count > 0) return fromSession;
            return _fetched is { } f && f.Markdown == Markdown ? f.Groups : null;
        }
    }

    void Render()
    {
        var questions = InterviewRecord.Parse(Markdown);
        var cards = CareerJourney.TopicCards(questions, Stored);
        var list = VStack(12, cards.Select(card => (UIElement)CareerJourneyUI.Card(card.Title, card.Meta, card.Quote, card.Many ? "看这几题 ›" : "看这一题 ›", () => _open(card.Position))).ToArray());
        var stack = VStack(14, CareerJourneyUI.SideHead($"面试中问到 · {questions.Count} 题", more: "看完整记录 ›", onMore: () => _open(0)), list);
        AutomationProperties.SetName(stack, "面试中问到");
        Content = stack;
    }

    async Task FetchAsync()
    {
        var markdown = Markdown;
        var key = _session.Text("id") + ":" + markdown;
        var list = CareerJourney.TopicQuestions(InterviewRecord.Parse(markdown));
        if (Stored is not null || list.Count == 0 || !Requested.Add(key)) return;
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_session.Text("id")}/record-topics", "POST", [],
                new JsonObject { ["questions"] = new JsonArray(list.Select(x => (JsonNode)JsonValue.Create(x)!).ToArray()) });
            var groups = result.Get("session").Items("record_topics");
            if (groups.Count > 0) { _fetched = (markdown, groups); Render(); }
        }
        catch (Exception) { }
    }
}

/// <summary>
/// 全程时间线（各分区底部；07.08 / 07.09 回看过去的节点）：节点等分整行，首尾贴边；实线已走、蓝线当前段、虚线未来；
/// 段上写天数，「今天」是一条墨色竖线；点过去的节点回看那一轮。
/// </summary>
sealed class CareerJourneyTimeline : UserControl
{
    readonly CareerJourney.Timeline _timeline;
    readonly string? _picked;
    readonly Action<string> _pick;
    readonly Canvas _canvas = new() { Height = 128 };

    public CareerJourneyTimeline(CareerJourney.Timeline timeline, string? picked, Action<string> pick)
    {
        (_timeline, _picked, _pick) = (timeline, picked, pick);
        Content = VStack(0, Sans(timeline.Head, 12.5, JS.Sub).Frame(height: 16), _canvas.Top(30));
        _canvas.SizeChanged += (_, e) => { if (Math.Abs(e.NewSize.Width - e.PreviousSize.Width) > 0.5) Layout(e.NewSize.Width); };
        AutomationProperties.SetName(this, "全程时间线");
    }

    void Layout(double width)
    {
        _canvas.Children.Clear();
        var nodes = _timeline.Nodes;
        var count = nodes.Count;
        double X(int index) => count > 1 ? width * index / (count - 1) : 0;
        for (var i = 0; i < _timeline.Segments.Count; i++)
        {
            var segment = _timeline.Segments[i];
            var from = X(i);
            var to = X(i + 1);
            FrameworkElement line = segment.Style == CareerJourney.SegmentStyle.Future
                ? new Line { X1 = 0, Y1 = 1, X2 = Math.Max(0, to - from), Y2 = 1, Stroke = Brush(JS.Track), StrokeThickness = 1.5, StrokeDashArray = new DoubleCollection { 2, 3.3 } }
                : new Border { Width = Math.Max(0, to - from), Height = 2, Background = Brush(segment.Style == CareerJourney.SegmentStyle.Current ? JS.Blue : JS.Track) };
            line.IsHitTestVisible = false;
            Put(line, from, 30);
            if (segment.Days is { } days)
            {
                var label = Sans($"{days} 天", 12, JS.Mute, Medium);
                label.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
                Put(label, from + (to - from - label.DesiredSize.Width) / 2, 6);
            }
        }
        if (_timeline.Today is { } today && today.Segment + 1 < count)
        {
            var left = X(today.Segment) + today.Ratio * (X(today.Segment + 1) - X(today.Segment));
            Put(new Border { Width = 1, Height = 30, Background = Brush(JS.Ink), IsHitTestVisible = false }, left, 16);
            Put(Sans("今天", 12, JS.Ink, Medium), left + 6, 0);
        }
        for (var i = 0; i < count; i++)
        {
            var edge = i == 0 ? 0 : i == count - 1 ? 2 : 1;
            var node = NodeView(nodes[i], edge);
            node.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
            var w = node.DesiredSize.Width;
            // 首个节点左缘在 -10，末个右缘在 width + 10，中间的居中对齐节点
            var x = edge == 0 ? -10 : edge == 2 ? width + 10 - w : X(i) - w / 2;
            Put(node, x, 16);
        }
    }

    void Put(FrameworkElement element, double x, double y)
    {
        Canvas.SetLeft(element, x);
        Canvas.SetTop(element, y);
        _canvas.Children.Add(element);
    }

    FrameworkElement NodeView(CareerJourney.Node node, int edge)
    {
        var picked = node.StationId is not null && node.StationId == _picked;
        var clickable = node.StationId is not null && node.Kind != CareerJourney.NodeKind.Future;
        var align = edge == 0 ? HorizontalAlignment.Left : edge == 2 ? HorizontalAlignment.Right : HorizontalAlignment.Center;
        var labelColor = picked ? JS.Ink : node.Kind switch { CareerJourney.NodeKind.Current => JS.Blue, CareerJourney.NodeKind.Future => JS.Mute, _ => JS.Ink };
        var weight = picked ? Semibold : node.Kind == CareerJourney.NodeKind.Future ? Regular : Medium;
        var texts = VStack(5, Sans(node.Label, 13.5, labelColor, weight).Align(align).Frame(height: 17));
        if (node.Line is not null) texts.Children.Add(Sans(node.Line, 12, node.Kind == CareerJourney.NodeKind.Current ? JS.Body : JS.Sub).Align(align).Frame(height: 15));
        if (node.Note is not null)
            texts.Children.Add(HStack(6, new Ellipse { Width = 5, Height = 5, Fill = Brush(JS.Orange), VerticalAlignment = VerticalAlignment.Center }, Sans(node.Note, 12, JS.Body)).Align(align).Frame(height: 15));
        texts.Padding = new Thickness(10, 34, 10, 8);

        var size = picked ? 12 : node.Kind == CareerJourney.NodeKind.Current ? 14 : 10;
        var halo = new Ellipse { Width = size + 8, Height = size + 8, Fill = Brush(Clear) };
        var dot = new Grid { Width = size + 8, Height = size + 8 };
        dot.Children.Add(halo);
        if (picked)
        {
            halo.Width = halo.Height = 22; dot.Width = dot.Height = 22;
            halo.Fill = Brush(Alpha(JS.Ink, 0.12));
            dot.Children.Add(new Ellipse { Width = 12, Height = 12, Fill = Brush(JS.Ink) });
        }
        else if (node.Kind == CareerJourney.NodeKind.Current)
            dot.Children.Add(new Ellipse { Width = 14, Height = 14, Fill = Brush(V3.White), Stroke = Brush(JS.Blue), StrokeThickness = 2 });
        else if (node.Kind == CareerJourney.NodeKind.Future)
            dot.Children.Add(new Ellipse { Width = 10, Height = 10, Fill = Brush(V3.White), Stroke = Brush(JS.Check), StrokeThickness = 1.5, StrokeDashArray = new DoubleCollection { 1.3, 1.3 } });
        else
            dot.Children.Add(new Ellipse { Width = 10, Height = 10, Fill = Brush(JS.Ink) });
        // 圆点中心落在线上（y = 31）
        dot.HorizontalAlignment = align;
        dot.VerticalAlignment = VerticalAlignment.Top;
        dot.Margin = new Thickness(edge == 1 ? 0 : 10 - (dot.Width - 10) / 2, 15 - dot.Height / 2, edge == 1 ? 0 : 10 - (dot.Width - 10) / 2, 0);
        var cell = new Grid { Background = Brush(Clear) };
        cell.Children.Add(texts);
        cell.Children.Add(dot);
        if (clickable && node.StationId is { } id)
        {
            var hoverTint = node.Kind == CareerJourney.NodeKind.Current ? Alpha(JS.Blue, 0.12) : Alpha(JS.Ink, 0.1);
            if (!picked) cell.OnHover(h => halo.Fill = Brush(h ? hoverTint : Clear));
            cell.OnTap(() => _pick(id), string.Join("，", new[] { node.Label, node.Line, node.Note }.OfType<string>()));
            if (!picked && node.Kind != CareerJourney.NodeKind.Current) cell.Tip($"查看{node.Label}");
        }
        else AutomationProperties.SetName(cell, string.Join("，", new[] { node.Label, node.Line, node.Note }.OfType<string>()));
        return cell;
    }
}

/// <summary>
/// 09.07 · 投递详情右上 ⋯ 菜单：白底圆角浮层，编辑类都收在这里；「日历颜色」后面带当前颜色小圆点，点开在下面展开一排色块；删除在结束或归档后才能点。
/// </summary>
sealed class CareerDetailMenu : UserControl
{
    public sealed record Item(string Title, Action Action, bool Danger = false, bool Enabled = true, bool Colors = false);

    public static readonly (string Value, string Label, Color Color)[] Swatches =
    [
        ("blue", "蓝", Hex(0x3F6FD8)), ("purple", "紫", Hex(0x7C5CD6)), ("green", "绿", Hex(0x2F9E6E)),
        ("orange", "橙", Hex(0xD9822B)), ("yellow", "黄", Hex(0xD4A82A)), ("red", "红", Hex(0xC2412D)), ("gray", "灰", Hex(0x96968F)),
    ];

    readonly IReadOnlyList<Item> _items;
    readonly string _color;
    readonly Action<string> _pickColor;
    readonly Action _close;
    bool _colorsOpen;

    public CareerDetailMenu(IReadOnlyList<Item> items, string color, Action<string> pickColor, Action close)
    {
        (_items, _color, _pickColor, _close) = (items, color, pickColor, close);
        Render();
    }

    void Render()
    {
        var current = Swatches.FirstOrDefault(x => x.Value == _color);
        if (current.Value is null) current = Swatches[0];
        var stack = new StackPanel { Width = 206 };
        foreach (var item in _items)
        {
            if (item.Colors)
            {
                var trailing = HStack(8, new Ellipse { Width = 8, Height = 8, Fill = Brush(current.Color), VerticalAlignment = VerticalAlignment.Center },
                    Icon(_colorsOpen ? "chevron.down" : "chevron.right", 8, JS.Mute).Align(v: VerticalAlignment.Center));
                stack.Children.Add(Row(item.Title, true, false, trailing, () => { _colorsOpen = !_colorsOpen; Render(); }));
                if (_colorsOpen)
                {
                    var swatches = HStack(8);
                    foreach (var swatch in Swatches)
                    {
                        var chosen = swatch.Value == current.Value;
                        var cell = new Grid { Width = 22, Height = 22 };
                        cell.Children.Add(new Ellipse { Width = 20, Height = 20, Stroke = Brush(chosen ? JS.Ink : Cl), StrokeThickness = chosen ? 2 : 1 });
                        cell.Children.Add(new Ellipse { Width = 14, Height = 14, Fill = Brush(swatch.Color) });
                        var value = swatch.Value;
                        swatches.Children.Add(cell.OnTap(() => _pickColor(value), swatch.Label));
                    }
                    swatches.Margin = new Thickness(12, 4, 12, 8);
                    stack.Children.Add(swatches);
                }
                continue;
            }
            if (item.Danger) stack.Children.Add(new Border { Height = 1, Background = Brush(V3.Line), Margin = new Thickness(6, 4, 6, 4) });
            stack.Children.Add(Row(item.Title, item.Enabled, item.Danger, null, () => { _close(); item.Action(); }));
        }
        AutomationProperties.SetName(stack, "这条投递的操作");
        Content = stack;
    }

    static FrameworkElement Row(string title, bool enabled, bool danger, UIElement? trailing, Action action)
    {
        var row = new Border
        {
            Child = Columns(8, (Star(), Sans(title, 13, !enabled ? Hex(0xC4C4BE) : danger ? PD.Red : JS.Ink).Align(v: VerticalAlignment.Center)), (Auto, trailing ?? new Border())),
            Height = 34, Padding = new Thickness(12, 0, 12, 0), CornerRadius = new CornerRadius(6), Background = Brush(Clear),
        };
        if (enabled)
        {
            // 菜单项的选中高亮（同系统菜单），不是列表悬停
            row.OnHover(h => row.Background = Brush(h ? Hex(0xF2F2EF) : Clear));
            row.OnTap(action, title);
        }
        return row;
    }
}
