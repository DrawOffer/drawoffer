using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Shell;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Mock.MockReportData;

namespace DrawOffer.App.Views.Mock;

/// <summary>Mac MockReportV2 / ReviewReportView: overview, question deck, abilities, next actions.</summary>
public sealed partial class MockReportView : UserControl
{
    readonly string _id; readonly Action _home, _records; readonly Action<PracticeFocus> _practice; readonly Action<string> _open;
    readonly Grid _root = new();
    V3Page? _reportPage; readonly List<FrameworkElement> _sections = []; double _reportOffset;
    MockViewLifetime? _life; JsonNode? _detail; JsonNode? _next;
    string? _error, _notice, _question; bool _busy, _reading; int _section, _card; string? _ability;
    V3Overlay? _dialog;
    DateTimeOffset _wheelAt; int _wheelDirection; int _animatedCard = -1; double _readerOffset;
    public MockReportView(string id, Action home, Action records, Action<PracticeFocus> practice, Action<string> open)
    {
        (_id, _home, _records, _practice, _open) = (id, home, records, practice, open);
        Background = Brush(White); Content = _root;
        Loaded += (_, _) => { _life = new(this, ClearPrivate); Render(); _ = Load(); };
        Unloaded += (_, _) => _dialog?.Close();
        KeyDown += (_, e) =>
        {
            if (_reading || _question is not null) return;
            if (e.Key is Windows.System.VirtualKey.PageDown or Windows.System.VirtualKey.Down) { Go(Math.Min(3, _section + 1)); e.Handled = true; }
            else if (e.Key is Windows.System.VirtualKey.PageUp or Windows.System.VirtualKey.Up) { Go(Math.Max(0, _section - 1)); e.Handled = true; }
            else if (_section == 1 && e.Key is Windows.System.VirtualKey.Left or Windows.System.VirtualKey.Right) { _card += e.Key == Windows.System.VirtualKey.Left ? -1 : 1; Render(); e.Handled = true; }
        };
    }
    void ClearPrivate() { _dialog?.Close(); _detail = null; _next = null; _question = null; _notice = null; _error = "登录状态已变化，请返回模拟面试。"; Render(); }
    string Base => "/api/mock-interviews/" + _id;
    async Task Load()
    {
        if (_life is null) return;
        _error = null;
        try
        {
            var result = await _life.Request(Base);
            _detail = result.Get("mock_interview") ?? throw new InvalidDataException(); Render();
            if (_detail.Display("job_application_id") is { Length: > 0 } application)
            {
                try { var next = await _life.Request("/api/interview-sessions", query: new() { ["status"] = "scheduled", ["start_at"] = DateTimeOffset.UtcNow.ToString("O"), ["application_id"] = application }); _next = next.Items("items").OrderBy(x => x.Text("start_at")).FirstOrDefault(); Render(); }
                catch (OperationCanceledException) { } catch { /* Optional schedule does not block a report. */ }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { if (_life.Alive) { _error = Error(e); Render(); } }
    }
    void Go(int section)
    {
        _section = section;
        if (_reportPage is null || section >= _sections.Count) return;
        var y = _sections[section].TransformToVisual((UIElement)_reportPage.Scroller.Content).TransformPoint(new(0, 0)).Y;
        _reportPage.Scroller.ChangeView(null, section == 0 ? 0 : Math.Max(0, y - 24), null);
    }
    void OpenQuestion(string id) { _question = id; Render(); }
    void Focus(Row row) => _practice(new PracticeFocus("topic", "", row.Topic));
    void Render()
    {
        _root.Children.Clear();
        if (_question is {} question && _detail is {} source)
        {
            var rows = Rows(source); var row = rows.FirstOrDefault(r => r.Id == question);
            if (row is not null)
            {
                _root.Children.Add(new MockQuestionDetail(source, row, next => { _question = next; Render(); }, _home, Focus, updated => { _detail = updated; }, message => _notice = message));
                return;
            }
            _question = null;
        }
        if (_detail is null)
        {
            var empty = VStack(10, Serif(_error is null ? "正在加载面试复盘…" : _error.Contains("不存在") ? "找不到这场模拟面试" : "模拟面试没有加载出来", 18),
                _error is null ? new ProgressRing { IsActive = true, Width = 24, Height = 24 } : Paragraph(_error),
                new V3Button("返回模拟面试", _home), _error is null ? null : new V3Button("重新加载", () => _ = Load()));
            empty.HorizontalAlignment = HorizontalAlignment.Center; empty.VerticalAlignment = VerticalAlignment.Center; _root.Children.Add(empty); return;
        }
        if (_reading) { _root.Children.Add(RecordPage(_detail)); return; }
        var report = _detail.Get("report");
        if (report is null)
        {
            _root.Children.Add(new V3Page(VStack(10, Serif("这场还没有评估报告", 18), new V3Button("刷新", () => _ = Load()), new V3Button("返回模拟面试", _home)))); return;
        }
        var rowsNow = Rows(_detail);
        var body = new StackPanel();
        body.Children.Add(Spread(HStack(12, LinkButton("← 模拟面试", _home), Sans("/", 16, Fnt), LinkButton("面试复盘", _records)),
            HStack(10, new V3Button("翻看面试记录", () => { _reading = true; Render(); }), new V3Button(_busy ? "正在准备…" : "再练一次", () => _ = Repeat(), V3Button.Kind.Dark) { Enabled = !_busy }, Menu())));
        if (_notice is not null) body.Children.Add(Paragraph(_notice, 12, Red).Top(12));
        _sections.Clear();
        var screens = new FrameworkElement[] { Overview(_detail, report, rowsNow), QuestionDeck(_detail, rowsNow), Ability(_detail, report, rowsNow), Next(_detail, report, rowsNow) };
        foreach (var screen in screens)
        {
            screen.Margin = new Thickness(0, 32, 0, 56);
            screen.MinHeight = Math.Max(600, ActualHeight - 160);
            _sections.Add(screen); body.Children.Add(screen);
        }
        _reportPage = new V3Page(body, 44, 48);
        _reportPage.Scroller.ViewChanged += (_, _) =>
        {
            _reportOffset = _reportPage.Scroller.VerticalOffset;
            for (var i = 0; i < _sections.Count; i++)
                if (_sections[i].TransformToVisual(body).TransformPoint(new(0, 0)).Y <= _reportOffset + 100) _section = i;
        };
        _reportPage.Scroller.AddHandler(UIElement.PointerWheelChangedEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, e) =>
        {
            if (_reading || _question is not null) return;
            var point = e.GetCurrentPoint(_reportPage.Scroller);
            if (point.Properties.IsHorizontalMouseWheel || point.Properties.MouseWheelDelta == 0) return;
            e.Handled = true;
            var direction = point.Properties.MouseWheelDelta < 0 ? 1 : -1;
            var now = DateTimeOffset.UtcNow;
            // Treat a wheel/touchpad burst as one page turn, including its momentum tail.
            if (direction == _wheelDirection && (now - _wheelAt).TotalMilliseconds < 360) { _wheelAt = now; return; }
            _wheelDirection = direction; _wheelAt = now;
            var scroll = _reportPage.Scroller;
            var offset = scroll.VerticalOffset;
            var stops = new List<double> { 0 };
            foreach (var screen in _sections.Skip(1))
                stops.Add(Math.Max(0, screen.TransformToVisual((UIElement)scroll.Content).TransformPoint(new(0, 0)).Y - 24));
            stops.Add(scroll.ScrollableHeight);
            // Long cards remain readable: step by a viewport before entering the next section.
            var boundary = direction > 0 ? stops.Where(y => y > offset + 2).DefaultIfEmpty(scroll.ScrollableHeight).Min() : stops.Where(y => y < offset - 2).DefaultIfEmpty(0).Max();
            var step = Math.Max(100, scroll.ViewportHeight - 48);
            var target = direction > 0 ? Math.Min(boundary, offset + step) : Math.Max(boundary, offset - step);
            scroll.ChangeView(null, Math.Clamp(target, 0, scroll.ScrollableHeight), null);
        }), true);
        _reportPage.Loaded += (_, _) => _reportPage.Scroller.ChangeView(null, _reportOffset, null, true);
        _root.Children.Add(_reportPage);
    }
    FrameworkElement Menu()
    {
        V3Button? button = null; button = new V3Button("···", () =>
        {
            var flyout = new MenuFlyout(); var item = new MenuFlyoutItem { Text = "删除本场练习", IsEnabled = !_busy };
            item.Click += (_, _) => { if (XamlRoot is null) return; _dialog = V3Overlay.Show(XamlRoot, close => V3Dialog.Make(VStack(12, V3DialogHead.Make("删除练习记录？"), Paragraph("永久删除本场练习、报告及录音，无法恢复。")), [new V3Button("取消", close), new V3Button("删除记录", () => { close(); _ = Delete(); }, V3Button.Kind.Danger)], close)); };
            flyout.Items.Add(item); flyout.ShowAt(button!);
        }, V3Button.Kind.Text).Tip("报告菜单"); return button;
    }
    FrameworkElement Overview(JsonNode detail, JsonNode report, List<Row> rows)
    {
        var target = Target(detail); var reached = rows.Count(r => r.Outcome(target) == "reached"); var missed = rows.Count(r => r.Outcome(target) == "missed");
        var verdict = report.Get("verdict").Text("level");
        var finished = detail.Text("finished_at").NonEmpty() ?? detail.Text("created_at");
        var minutes = Json.Date(detail.Text("finished_at")) is {} end && Json.Date(detail.Text("started_at")) is {} start ? $" · {Math.Max(1, (int)Math.Round((end - start).TotalMinutes))} 分钟" : "";
        var stats = Columns(20, (Star(), VStack(4, Number($"{reached} / {rows.Count} 道", 20), Sans("答到位", 11, Fnt))), (Star(), VStack(4, Number($"{missed} 道", 20, missed > 0 ? Orange : Txt), Sans("没答上", 11, Fnt))), (Star(), VStack(4, Number($"{detail.Items("questions").Count(q => q.Text("kind") == "follow_up")} 次", 20), Sans("追问", 11, Fnt))));
        var panel = VStack(0, Serif($"{Date(finished)}  {Type(detail)}", 26), Sans($"{detail.Text("company_name").NonEmpty() ?? "通用练习"} · {Difficulty(detail)} · {(detail.Text("answer_mode") == "voice" ? "语音" : "文字")} · {rows.Count} 题{minutes}", 12, Fnt).Wrap().Top(4),
            HStack(8, Serif(report.Number("total_score")?.ToString("F0") ?? "—", 64), Sans("/ 100", 13, Fnt), V3Chip.Make(Verdict(verdict), Tone(verdict), verdict is "likely_pass" or "meets" ? BlueSoft : OrangeSoft)).Top(8),
            Serif(report.Text("headline"), 17).Wrap(2).LineHeight(25.5).Top(12), Paragraph(report.Text("summary"), 12.5).Top(8), stats.Top(24));
        panel.Width = 380;
        var map = Map(rows, target, OpenQuestion, 560, 470);
        var main = Columns(32, (Px(380), panel), (Star(), map));
        var line = new Canvas { Height = 112, HorizontalAlignment = HorizontalAlignment.Stretch };
        line.SizeChanged += (_, e) =>
        {
            line.Children.Clear(); var width = Math.Max(300, e.NewSize.Width); var draw = new Draw(width, 112); var arc = new Func<double,double>(x => 28 + 3000 - Math.Sqrt(9_000_000 - Math.Pow(x - width / 2, 2)));
            draw.Stroke(Draw.Lines(Enumerable.Range(0, 101).Select(i => new Windows.Foundation.Point(width * i / 100, arc(width * i / 100)))), Cl, 1);
            line.Children.Add(draw.Surface);
            foreach (var (row, i) in rows.Select((r, i) => (r, i)))
            {
                var x = 50 + (width - 100) * (i + 0.5) / Math.Max(1, rows.Count); var y = arc(x); var outcome = row.Outcome(target);
                var bead = new Button { Content = VStack(4, Sans($"Q{row.No}  {row.Topic}", 11, Sub).Frame(width: Math.Max(40, (width - 100) / Math.Max(1, rows.Count) - 8)).Wrap(2), Fill(Tone(outcome), 7, 14, 14)), Background = Brush(Clear), BorderThickness = new Thickness(0), Padding = new Thickness(4) };
                ToolTipService.SetToolTip(bead, $"Q{row.No} {row.Topic} · {Outcome(outcome)}"); bead.Click += (_, _) => OpenQuestion(row.Id); line.Children.Add(bead); Canvas.SetLeft(bead, x - Math.Max(40, (width - 100) / Math.Max(1, rows.Count)) / 2); Canvas.SetTop(bead, y - 34);
            }
        };
        return VStack(16, main, line, Sans("← 按提问顺序 · 点题目看完整问答", 10.5, Fnt), new V3Button("往下看没答到位的题 ↓", () => Go(1)));
    }
    internal static FrameworkElement Map(List<Row> rows, double target, Action<string> open, double width, double height, string? selected = null)
    {
        var shared = MockReview.OverviewMapOf(rows.Select(r => r.Question).OfType<MockReview.Question>().ToList());
        var points = shared?.Points ?? []; var sectors = selected is null ? shared?.Sectors ?? [] : new List<MockMap.Sector>();
        var geo = new MockMap.Geo(width / 2, height / 2, Math.Min(width, height) / 660);
        var path = shared?.Path.Where(p => selected is null || p.Id == selected).ToList() ?? [];
        var layout = MockLayout.LayoutOf(new MockLayout.Input(geo, MockMap.Place(geo, points), path, sectors, new MockLayout.Box(8, 8, width - 8, height - 8)) { LabelIds = selected is null ? null : [selected] });
        var map = new MockMasteryMap(width, height, geo, points, sectors, target, selected is null ? $"{Level(target)}目标线" : null, open)
        { Plain = true, Selected = selected, PathSteps = path, LabelLayout = layout, Bounds = shared?.Bounds, LabelOnly = selected is null ? null : [selected] };
        return new Viewbox { Child = map, Stretch = Stretch.Uniform, MaxHeight = height };
    }
    FrameworkElement QuestionDeck(JsonNode detail, List<Row> rows)
    {
        var target = Target(detail); var weak = rows.Where(r => r.Outcome(target) == "missed").Concat(rows.Where(r => r.Outcome(target) == "one_short")).ToList(); var rest = rows.Except(weak).ToList(); var total = weak.Count + (rest.Count > 0 ? 1 : 0); _card = Math.Clamp(_card, 0, Math.Max(0, total - 1));
        var result = VStack(6, Sans(weak.Count == 0 ? "这场每道题都答到位了" : $"{weak.Count} 道题没答到位", 32, Txt, Bold), Sans(weak.Count == 0 ? "下面是这场的全部题目，点一格进那道题。" : "先看没答上的，再看差一点的；左右翻，一张一道。", 15.5, Fnt).Wrap());
        var card = new StackPanel { Spacing = 16, MaxWidth = 760, Padding = new Thickness(40, 28, 40, 26) };
        if (_card < weak.Count)
        {
            var row = weak[_card]; var outcome = row.Outcome(target); var last = row.Turns.Last();
            card.Children.Add(Spread(HStack(10, V3Chip.Make(Outcome(outcome), White, Tone(outcome)), Sans($"第 {row.No} 题 · 主问题 · 被追问 {row.Turns.Count - 1} 次", 13, Sub)), Number(row.Evaluation.Number("score")?.ToString("F0") ?? "—", 52, Tone(outcome))));
            card.Children.Add(Steps(row.Level, row.Evaluation.Number("target_depth") ?? target, Tone(outcome)));
            card.Children.Add(Sans(row.Topic, 24, Txt, Bold).Wrap()); card.Children.Add(Sans("面试官", 12, Fnt));
            card.Children.Add(Card(Paragraph(last.Text("content"), 14.5, Txt), 16, new Thickness(16, 12, 16, 12), Field, Clear));
            card.Children.Add(Card(Paragraph(last.Text("answer_status") == "answered" ? last.Text("answer_text") : "跳过了这道题", 14.5, White), 16, new Thickness(16, 12, 16, 12), Blue, Clear));
            card.Children.Add(Sans("换个说法 · 该说到这", 12, Blue)); card.Children.Add(Paragraph(row.Evaluation.Text("reference_answer").NonEmpty() ?? row.Evaluation.Items("weaknesses").FirstOrDefault()?.String() ?? "—", 14));
            card.Children.Add(Spread(LinkButton("看完整问答 ›", () => OpenQuestion(row.Id)), new V3Button("练这一题", () => Focus(row))));
        }
        else { card.Children.Add(Sans($"其余 {rest.Count} 道", 24, Txt, Bold)); foreach (var row in rest) card.Children.Add(Tap(Spread(Sans($"Q{row.No}  {row.Topic}", 15).Wrap(), Sans(Outcome(row.Outcome(target)), 13, Tone(row.Outcome(target)))), () => OpenQuestion(row.Id), row.Topic)); card.Children.Add(new V3Button("往下看能力表现 ↓", () => Go(2))); }
        var deck = new Grid { MaxWidth = 800, HorizontalAlignment = HorizontalAlignment.Center, Padding = new Thickness(0, 12, 36, 0) };
        if (_card < total - 2) deck.Children.Add(new Border { Background = Brush(Hex(0xFAF4EA)), CornerRadius = new CornerRadius(22), Margin = new Thickness(34, 0, -34, 10), RenderTransform = new Microsoft.UI.Xaml.Media.RotateTransform { Angle = 3.2 }, RenderTransformOrigin = new(.5, 1) });
        if (_card < total - 1) deck.Children.Add(new Border { Background = Brush(Hex(0xFDF8F0)), CornerRadius = new CornerRadius(22), Margin = new Thickness(18, 0, -18, 6), RenderTransform = new Microsoft.UI.Xaml.Media.RotateTransform { Angle = 1.6 }, RenderTransformOrigin = new(.5, 1) });
        var front = Card(card, 22, background: White);
        deck.Children.Add(front);
        if (_animatedCard >= 0 && _animatedCard != _card)
            front.Loaded += (_, _) =>
            {
                if (!new Windows.UI.ViewManagement.UISettings().AnimationsEnabled) return;
                var storyboard = new Storyboard();
                var fade = new DoubleAnimation { From = .35, To = 1, Duration = new Duration(TimeSpan.FromMilliseconds(180)) };
                Storyboard.SetTarget(fade, front); Storyboard.SetTargetProperty(fade, "Opacity");
                storyboard.Children.Add(fade); storyboard.Begin();
            };
        _animatedCard = _card;
        result.Children.Add(deck.Top(30));
        var prev = new V3Button("‹ 上一张", () => { _card--; Render(); }) { Enabled = _card > 0 }; var next = new V3Button("下一张 ›", () => { _card++; Render(); }) { Enabled = _card < total - 1 };
        result.Children.Add(Spread(prev, next).Top(20)); return result;
    }
    internal static FrameworkElement Steps(double level, double target, Windows.UI.Color color)
    {
        var grid = new Grid { ColumnSpacing = 10, Height = 160 };
        for (var i = 1; i <= 5; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() }); var height = 32 + (i - 1) * 20;
            var label = VStack(4, i == (int)target ? Sans("面试官想听到", 11, Blue).Wrap() : null, i == (int)level ? Sans("你", 12, Txt, Bold) : null, Fill(i <= level ? color : Field, 10, height: height, child: Sans(Level(i), 13, i <= level ? White : Fnt).Align(HorizontalAlignment.Center, VerticalAlignment.Bottom).Pad(0, 0, 0, 8)));
            label.VerticalAlignment = VerticalAlignment.Bottom; Grid.SetColumn(label, i - 1); grid.Children.Add(label);
        }
        return grid;
    }
    FrameworkElement Ability(JsonNode detail, JsonNode report, List<Row> rows)
    {
        var view = MockReview.ViewOf(detail, report, MockReview.Rows(detail, report), "", "");
        var dimensions = view.Dimensions.Take(6).ToList();
        var chosen = dimensions.FirstOrDefault(d => d.Key == _ability) ?? dimensions.Where(d => d.Assessed).OrderBy(d => d.Score).FirstOrDefault() ?? dimensions.FirstOrDefault();
        var result = VStack(8, Sans("能力表现", 32, Txt, Bold), Sans($"{dimensions.Count} 项能力按每道题考到的要点打分，满分 100，按 5 格画。", 15.5, Fnt).Wrap());
        if (dimensions.Count == 0) result.Children.Add(Sans("这场没有能力项的评分", 14, Fnt).Top(32));
        var chart = new Grid { ColumnSpacing = 28, Margin = new Thickness(0, 24, 0, 24) };
        foreach (var (item, index) in dimensions.Select((d, i) => (d, i)))
        {
            chart.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() }); var bars = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Bottom };
            for (var step = 5; step >= 1; step--) bars.Children.Add(Fill(item.Assessed && item.Steps >= step ? item.Score < 50 ? Orange : Blue : Field, 4, height: 30));
            var cell = Tap(VStack(8, Number(item.Score?.ToString() ?? "—", 22), bars, Sans(item.Label, 13).Wrap(), Sans(item.Assessed ? "" : item.OffReason ?? "这场没考到", 11, Fnt)), () => { _ability = item.Key; Render(); }, item.Label);
            Grid.SetColumn(cell, index); chart.Children.Add(cell);
        }
        result.Children.Add(chart);
        if (chosen is not null)
        {
            result.Children.Add(Sans(chosen.Label, 24, Txt, Bold)); result.Children.Add(Paragraph(chosen.Assessed ? chosen.Comment ?? "有依据" : chosen.OffReason ?? "这场没考到", 16));
            if (rows.FirstOrDefault(r => r.No == chosen.EvidenceNo) is {} row) result.Children.Add(LinkButton($"看第 {row.No} 题 ›", () => OpenQuestion(row.Id)));
        }
        if (detail.Text("answer_mode") == "voice" && report.Get("voice_metrics") is {} metrics)
        {
            var reference = metrics.Get("reference"); bool Outside(string key, double low, double high) { var range = reference.Items(key); return metrics.Number(key) is {} value && (value < (range.ElementAtOrDefault(0)?.Number() ?? low) || value > (range.ElementAtOrDefault(1)?.Number() ?? high)); }
            result.Children.Add(Sans("语音表现 · 只在语音面试里有", 14, Txt, Semibold).Top(20));
            result.Children.Add(HStack(40, VStack(4, Sans("语速", 12, Fnt), Number($"{metrics.Number("chars_per_minute"):F0} 字/分", 22, Outside("chars_per_minute", 180, 240) ? Orange : Txt)), VStack(4, Sans("长停顿", 12, Fnt), Number($"{metrics.Number("long_pauses"):F0} 次", 22, Outside("long_pauses", 0, 3) ? Orange : Txt)), VStack(4, Sans("口头禅", 12, Fnt), Number($"{metrics.Number("filler_ratio") * 100:F0}%", 22, Outside("filler_ratio", 0, .05) ? Orange : Txt))));
            result.Children.Add(Paragraph(metrics.Text("tip"), 12.5)); if (!detail.Bool("recordings_deleted")) result.Children.Add(new V3Button(_busy ? "正在删除…" : "删除本场录音", ConfirmRecordings, V3Button.Kind.Text) { Enabled = !_busy });
        }
        result.Children.Add(new V3Button("往下看下一步 ↓", () => Go(3)).Top(24)); return result;
    }
    static string DimensionLabel(string key) => new Dictionary<string,string> { ["structured_thinking"] = "结构化思考", ["analysis"] = "分析判断", ["planning"] = "计划组织协调", ["resilience"] = "应变与抗压", ["collaboration"] = "协作与影响", ["learning"] = "学习能力", ["professionalism"] = "职业素养" }.GetValueOrDefault(key, MockInterview.Dimensions.GetValueOrDefault(key, key));
    FrameworkElement Next(JsonNode detail, JsonNode report, List<Row> rows)
    {
        var actions = report.Items("actions").Take(3).ToList(); var done = detail.Items("done_actions").Select(x => (int)(x.Number() ?? -1)).ToHashSet();
        var title = actions.Count == 0 ? "这场没有特别要准备的事" : _next is null ? $"下一场之前，建议准备这 {actions.Count} 件事" : $"{_next.Text("stage_label")}前，建议准备这 {actions.Count} 件事";
        var result = VStack(8, Sans(title, 32, Txt, Bold).Wrap(), Sans("根据这场的回答给的建议，按重要程度排，可以挑着做；点题号回到那道题。", 15.5, Fnt).Wrap());
        if (_next is not null && Json.Date(_next.Text("start_at")) is {} date) result.Children.Add(Sans($"下一场 · {Date(_next.Text("start_at"))} · 还有 {Math.Max(0, (date.ToBeijing().Date - Beijing.Today).Days)} 天", 13, Sub));
        foreach (var (action, index) in actions.Select((a, i) => (a, i)))
        {
            var check = new CheckBox { Content = "做完了", IsChecked = done.Contains(index), IsEnabled = !_busy }; check.Click += (_, _) => _ = Toggle(index, check.IsChecked == true);
            var links = HStack(10); foreach (var number in action.Items("question_refs").Select(x => x.Number())) if (rows.FirstOrDefault(r => r.Main.Number("sequence_no") == number) is {} row) links.Children.Add(LinkButton($"Q{row.No}", () => OpenQuestion(row.Id)));
            links.Children.Add(LinkButton(action.Text("kind") switch { "resume" => "打开简历 ›", "material" => "去资料库 ›", _ => "练这一处 ›" }, () => RunAction(action, rows)));
            result.Children.Add(VStack(12, Divider(), Spread(Sans($"{index + 1:00}  {action.Text("title")}", 20, Txt, Semibold).Wrap(), check), Paragraph(action.Text("resume_quote").Length > 0 ? action.Text("resume_quote") + " → " + action.Text("detail") : action.Text("detail"), 14), links).Top(32));
        }
        var facts = report.Get("fact_check").Items("items").Take(3).ToList();
        if (facts.Count > 0)
        {
            result.Children.Add(Sans("对照资料", 17, Txt, Bold).Top(40)); result.Children.Add(Sans(string.Join("、", facts.Select(f => f.Text("file_name")).Distinct()) + " · 只核对你说过的数字和事实，不影响分数", 12.5, Fnt).Wrap());
            foreach (var fact in facts) result.Children.Add(VStack(8, Paragraph("你说：" + fact.Text("claim"), 13.5, Txt), Paragraph(fact.Text("quote").Length == 0 ? "资料里没有找到相关记录" : "资料：「" + fact.Text("quote") + "」", 13.5), Sans(fact.Text("verdict") switch { "consistent" => "一致", "conflict" => "冲突", "material_stronger" => "资料更强", _ => "没找到" }, 13.5, Tone(fact.Text("verdict") == "conflict" ? "missed" : "reached")), Divider()).Top(12));
        }
        result.Children.Add(HStack(16, LinkButton("复盘看完了 · 回到第 1 页 ↑", () => Go(0)), Sans($"评分规则 {report.Text("rubric_version")} · 总分是各主问题的平均分", 12.5, Fnt)).Top(32)); return result;
    }
    void RunAction(JsonNode action, List<Row> rows)
    {
        if (action.Text("kind") == "resume") { var resume = _detail.Display("resume_id"); if (resume.Length > 0) WorkspaceShell.Current.EditResume(resume); else WorkspaceShell.Current.Navigate(WorkspaceSection.Resumes); }
        else if (action.Text("kind") == "material") WorkspaceShell.Current.Navigate(WorkspaceSection.Datasets);
        else { var refs = action.Items("question_refs").Select(x => x.Number()).ToList(); if (rows.FirstOrDefault(r => refs.Contains(r.Main.Number("sequence_no"))) is {} row) Focus(row); else _ = Repeat(); }
    }
    FrameworkElement RecordPage(JsonNode detail)
    {
        var stack = VStack(0, HStack(12, LinkButton("← 模拟面试", _home), Sans("/", 16, Fnt), LinkButton("面试复盘", () => { _reading = false; Render(); }), Sans("/ 面试记录", 16, Fnt)), Sans(Job(detail), 13).Top(12), Serif($"{Date(When(detail))} {Type(detail)}的面试记录", 30).Top(6), Sans(Settings(detail), 13, Fnt).Top(6));
        var rows = Rows(detail, true); var text = new StackPanel { Spacing = 28 }; var anchors = new List<FrameworkElement>(); var toc = new StackPanel { Spacing = 8, Width = 190, VerticalAlignment = VerticalAlignment.Top }; var tocButtons = new List<V3Button>(); var sticky = new TranslateTransform(); toc.RenderTransform = sticky; V3Page? page = null;
        foreach (var row in rows)
        {
            var block = new StackPanel { Spacing = 12 }; block.Children.Add(Sans($"{row.No:00}  {row.Main.Text("content")}", 18, Txt, Semibold).Wrap());
            foreach (var turn in row.Turns) { if (turn != row.Main) block.Children.Add(Paragraph("追问 · " + turn.Text("content"), 14, Blue)); block.Children.Add(Paragraph(turn.Text("answer_status") == "skipped" ? "跳过了这道题" : turn.Text("answer_text").NonEmpty() ?? "这道题没有作答", 14)); }
            block.Children.Add(Divider()); anchors.Add(block); text.Children.Add(block);
            var button = LinkButton($"{row.No:00}  {row.Topic}", () => { if (page is null) return; var y = block.TransformToVisual((UIElement)page.Scroller.Content).TransformPoint(new(0, 0)).Y; page.Scroller.ChangeView(null, Math.Max(0, y - 60), null); });
            tocButtons.Add(button); toc.Children.Add(button);
        }
        var columns = Columns(48, (Star(), text), (Px(190), toc)).Top(26);
        stack.Children.Add(columns); page = new V3Page(stack, 104, 80);
        void SyncReader()
        {
            var scroll = page.Scroller; _readerOffset = scroll.VerticalOffset;
            var active = 0;
            for (var i = 0; i < anchors.Count; i++)
                if (anchors[i].TransformToVisual((UIElement)scroll.Content).TransformPoint(new(0, 0)).Y <= _readerOffset + 64) active = i;
            for (var i = 0; i < tocButtons.Count; i++)
            {
                tocButtons[i].Background = Brush(i == active ? BlueSoft : Clear);
                tocButtons[i].BorderBrush = Brush(i == active ? Blue : Clear);
                tocButtons[i].BorderThickness = new Thickness(i == active ? 2 : 0, 0, 0, 0);
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(tocButtons[i], $"{(i == active ? "当前阅读 · " : "")}{rows[i].No:00} {rows[i].Topic}");
            }
            var top = columns.TransformToVisual((UIElement)scroll.Content).TransformPoint(new(0, 0)).Y;
            sticky.Y = Math.Clamp(_readerOffset + 24 - top, 0, Math.Max(0, text.ActualHeight - toc.ActualHeight));
        }
        page.Scroller.ViewChanged += (_, _) => SyncReader();
        page.Loaded += (_, _) => { page.Scroller.ChangeView(null, _readerOffset, null, true); SyncReader(); };
        return page;
    }
    async Task Act(Func<Task> work)
    {
        if (_busy || _life is null || !_life.Alive) return; _busy = true; _notice = null; Render();
        try { await work(); } catch (OperationCanceledException) { } catch (Exception e) { if (_life.Alive) _notice = Error(e); }
        finally { _busy = false; if (_life.Alive) Render(); }
    }
    Task Repeat() => Act(async () => { var result = await _life!.Request(Base + "/repeat", "POST"); var id = result.Get("mock_interview").Display("id"); if (id.Length == 0) throw new InvalidDataException(); _open(id); });
    Task Delete() => Act(async () => { await _life!.Request(Base, "DELETE"); _records(); });
    Task Toggle(int index, bool done) => Act(async () => { var result = await _life!.Request(Base + $"/actions/{index}", "PUT", new JsonObject { ["done"] = done }); _detail = result.Get("mock_interview") ?? _detail; });
    void ConfirmRecordings()
    {
        if (XamlRoot is null || _busy) return; _dialog = V3Overlay.Show(XamlRoot, close => V3Dialog.Make(VStack(12, V3DialogHead.Make("删除本场录音？"), Paragraph("删除后无法回放或手动修改识别稿。识别文字和评估结果都会保留。")), [new V3Button("取消", close), new V3Button("删除录音", () => { close(); _ = Act(async () => { var result = await _life!.Request(Base + "/recordings", "DELETE"); _detail = result.Get("mock_interview") ?? _detail; _notice = "本场录音已删除，识别文字和评估结果都已保留。"; }); }, V3Button.Kind.Danger)], close));
    }
}
