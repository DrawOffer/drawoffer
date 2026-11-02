using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Shell;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Career.CareerKit;

namespace DrawOffer.App.Views.Career;

/// <summary>
/// 04.C03.C 面试 AI 分析报告（Mac `CareerReviewReportView`，Web `CareerDetailV3.tsx`）。v2 报告展示结果判断、总分、五维雷达、
/// 逐题得分与笔记、改进建议；v1 报告保留三项评分。生成中每 3 秒刷新；开始 20 分钟仍在生成视为中断，可以重新生成。
/// </summary>
public sealed partial class CareerReviewReportView : UserControl
{
    readonly string _sessionId;
    readonly Action _back;
    JsonNode _detail = new JsonObject();
    bool _loading = true;
    string? _error;
    string? _notice;
    bool _busy;
    int _selected;
    (string Id, int Version)? _attempt;
    List<JsonNode> _targets = [];
    DateTimeOffset _now = Beijing.Now;
    int _request;
    bool _alive = true;
    DispatcherTimer? _poll;
    V3Overlay? _textSheet;
    CareerAudioBar? _audioBar;
    readonly Dictionary<string, CareerQuestionNote> _notes = [];
    readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };

    public CareerReviewReportView(string sessionId, Action back)
    {
        _sessionId = sessionId;
        _back = back;
        Content = _scroll;
        Loaded += (_, _) => { _alive = true; Render(); Refresh(); };
        Unloaded += (_, _) => { _alive = false; _request++; StopPolling(); _textSheet?.Close(); _audioBar?.Stop(); };
    }

    JsonNode Session => _detail.Get("session") ?? new JsonObject();
    JsonNode Application => _detail.Get("application") ?? new JsonObject();
    JsonNode? Report => Session.Get("review_report") is JsonNode report && report.GetValueKind() != System.Text.Json.JsonValueKind.Null ? report : null;
    bool Generating => Session.Text("review_status") == "generating";
    string RecordText => Session.Text("questions_markdown").Trim();
    bool TooLong => Count(RecordText) > 50_000;
    bool Archived => Application.Text("archived_at").Length > 0;
    bool CanGenerate => RecordText.Length > 0 && !TooLong && !Archived;
    bool Interrupted => Generating && CareerApplication.Date(Session.Text("review_started_at")) is { } started && (_now - started).TotalSeconds >= 20 * 60;
    JsonNode? Audio => _detail.Items("assets").FirstOrDefault(x => x.Text("asset_type") == "audio");

    void Refresh() => _ = LoadAsync();

    void Render() => KeepFocus(XamlRoot, Rebuild);

    void Rebuild()
    {
        var stack = new StackPanel { Spacing = 24, Padding = new Thickness(0, 35, 0, 64), MaxWidth = 860 };
        if (Session.Text("id").Length == 0)
        {
            stack.Children.Add(CareerBreadcrumb.Make("← 阶段记录", "AI 分析报告", _back));
            if (_loading) stack.Children.Add(Spinner("正在加载报告…"));
            if (_error is { } error) stack.Children.Add(HStack(8, Sans(error, 13, CareerPalette.Red), new CareerAction("重试", Refresh)));
        }
        else
        {
            stack.Children.Add(Header());
            foreach (var banner in Banners()) stack.Children.Add(banner);
            if (_notice is { } notice) stack.Children.Add(Sans(notice, 12, CareerPalette.Sub).Wrap());
            if (RecordText.Length == 0) stack.Children.Add(EmptyState());
            if (Audio is { } audio)
            {
                if (_audioBar is null || _audioBar.AssetId != audio.Text("id")) { _audioBar?.Stop(); _audioBar = new CareerAudioBar(audio, message => { _notice = message; Render(); }); }
                stack.Children.Add(Detach(_audioBar));
            }
            if (Report is { } report && CareerReview.IsV2(report)) foreach (var child in ReportV2(report)) stack.Children.Add(child);
            else if (Report is { } legacy) stack.Children.Add(ReportV1(legacy));
            else if (RecordText.Length > 0 && Session.Text("review_summary").Length > 0) stack.Children.Add(Banner(Session.Text("review_summary")));
        }
        var frame = new Grid { Padding = new Thickness(32, 0, 32, 0) };
        frame.Children.Add(new Border { Child = stack, MaxWidth = 860, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Top });
        _scroll.Content = frame;
        UpdatePolling();
    }

    // MARK: Header and banners

    string HeaderMeta
    {
        get
        {
            if (Report is not { } report) return CareerFormat.MonthDay(Session.Text("start_at")) + " " + CareerFormat.Clock(Session.Text("start_at"));
            var resume = CareerReview.IsV2(report) ? report.Get("basis").Text("resume_title") : Application.Text("resume_title_snapshot");
            var recording = RecordText.Length == 0 ? "" : "文字记录";
            if (Audio is { } audio)
            {
                var minutes = Math.Max(1, (int)Round((audio.Number("duration_ms") ?? 0) / 60_000));
                recording = $"{minutes} 分钟录音转写";
            }
            var basis = string.Join(" + ", new[] { resume, recording }.Where(x => x.Length > 0));
            var generated = CareerFormat.MonthDay(report.Text("generated_at")) + " " + CareerFormat.Clock(report.Text("generated_at"));
            return basis.Length == 0 ? generated : $"基于 {basis} · {generated}";
        }
    }

    UIElement Header()
    {
        var meta = HStack(8, Report is not null ? CareerChipView.Make(Session.Text("stage_label"), CareerTone.Gray) : null, Sans(HeaderMeta, 12, CareerPalette.Sub));
        var left = VStack(6,
            CareerBreadcrumb.Make($"← {Application.Text("company_name_snapshot")} · {Application.Text("job_title_snapshot")}", Session.Text("stage_label"), _back),
            Serif($"{Session.Text("stage_label")} · AI 分析报告", 26).Wrap(2),
            meta);
        var running = _busy || (Generating && !Interrupted);
        var actions = HStack(8,
            new CareerAction("文字记录", OpenText),
            new CareerAction(running ? "正在生成…" : Report is not null ? "重新生成" : "生成复盘", () => _ = GenerateAsync(), CareerAction.Kind.Primary) { Enabled = CanGenerate && !running });
        return Spread(left, actions, 16, VerticalAlignment.Top);
    }

    IEnumerable<UIElement> Banners()
    {
        if (TooLong) yield return Banner("文字复盘最多支持 50,000 字符，请精简记录后生成。", true);
        if (Session.Bool("review_stale")) yield return Banner("文字记录已修改，以下是旧报告，请重新生成。");
        if (Session.Text("review_status") == "failed") yield return Banner("复盘生成失败，原记录和已有报告已保留。", true);
        if (Interrupted) yield return Banner("上次生成已中断，可以重新生成。");
        if (_busy || (Generating && !Interrupted)) yield return Banner("正在后台生成 AI 复盘，通常需要 1–3 分钟，可以离开页面稍后回来查看。");
        if (Report is { } report && !CareerReview.IsV2(report)) yield return Banner("这是旧版报告，重新生成后可查看结果判断、五维雷达和逐题得分。");
    }

    static Border Banner(string message, bool red = false) => new()
    {
        Child = Sans(message, 12.5, red ? CareerPalette.Red : CareerPalette.Sub).Wrap(), Padding = new Thickness(14, 10, 14, 10), CornerRadius = new CornerRadius(10),
        Background = Brush(red ? CareerPalette.RedSoft : CareerPalette.Soft), HorizontalAlignment = HorizontalAlignment.Stretch,
    };

    UIElement EmptyState()
    {
        var stack = VStack(8,
            Sans("添加面试文字记录", 15, CareerPalette.Text, Medium),
            Sans("保存文字记录或上传录音后生成 AI 复盘，录音会自动转写为文字稿。", 12, CareerPalette.Faint).Wrap().Also(t => t.TextAlignment = TextAlignment.Center),
            new CareerAction("返回阶段记录添加", _back, CareerAction.Kind.Primary).Also(a => a.Margin = new Thickness(0, 6, 0, 0)));
        foreach (var child in stack.Children.OfType<FrameworkElement>()) child.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Padding = new Thickness(16, 32, 16, 32);
        return Dashed(stack, 14, CareerPalette.Rail, CareerPalette.Soft);
    }

    void OpenText()
    {
        if (XamlRoot is null || _textSheet?.IsOpen == true) return;
        _textSheet = V3Overlay.Show(XamlRoot, close =>
        {
            UIElement body = RecordText.Length == 0 ? Sans("还没有文字记录。", 13, CareerPalette.Hint) : Sans(RecordText, 13, CareerPalette.Text).Spaced(3).Wrap().Selectable();
            var sheet = CareerSheet.Make("文字记录与素材", 720, [body], [new CareerAction("关闭", close, CareerAction.Kind.Primary, large: true)], Session.Text("stage_label"));
            sheet.Height = 600;
            return sheet;
        });
    }

    // MARK: Report v2

    IEnumerable<UIElement> ReportV2(JsonNode report)
    {
        var questions = report.Items("questions");
        var notes = CareerReview.Notes(Session, report);
        yield return Verdict(report);
        yield return Scores(report, questions);
        if (questions.Count > 0) yield return QuestionSection(questions, notes.ByKey);
        if (notes.Unmatched.Count > 0) yield return Unmatched(notes.Unmatched);
        if (Improvements(report, questions) is { } improvements) yield return improvements;
        yield return Sans(CareerReview.Basis(report), 11.5, CareerPalette.Faint).Wrap();
    }

    UIElement Verdict(JsonNode report)
    {
        var verdict = report.Get("verdict");
        var chip = CareerReview.Verdict(verdict.Text("level"));
        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(HStack(10, Sans("结果判断", 11.5, CareerPalette.Sub), Serif(chip.Label, 20), CareerChipView.Make(CareerReview.ConfidenceLabel(verdict.Text("confidence")), CareerTone.Gray)));
        stack.Children.Add(Sans(report.Text("headline"), 13.5, CareerPalette.Text).Spaced(4).Wrap());
        if (verdict.Text("confidence_reason").Length > 0) stack.Children.Add(Sans(verdict.Text("confidence_reason"), 12, CareerPalette.Faint).Wrap());
        foreach (var signal in verdict.Items("signals"))
        {
            var positive = signal.Text("polarity") == "positive";
            var row = HStack(8, CareerChipView.Make(positive ? "正向" : "负向", positive ? CareerTone.Green : CareerTone.Red),
                Sans(signal.Text("meaning"), 12, CareerPalette.Sub), Sans($"“{signal.Text("quote")}”", 12, CareerPalette.Faint).Wrap(2));
            stack.Children.Add(row);
        }
        stack.Children.Add(Sans("这是 AI 基于文字稿的判断，不代表最终结果。", 11.5, CareerPalette.Faint));
        stack.Padding = new Thickness(22, 18, 22, 18);
        var accent = new Border { Width = 4, Background = Brush(CareerPalette.Solid(chip.Tone)), HorizontalAlignment = HorizontalAlignment.Left };
        return new Border
        {
            Child = Layer(stack, accent), CornerRadius = new CornerRadius(14), Background = Brush(V3.White),
            BorderBrush = Brush(CareerPalette.PipelineLine), BorderThickness = new Thickness(1),
        };
    }

    UIElement Scores(JsonNode report, List<JsonNode> questions)
    {
        int? total = report.Number("total_score") is { } value ? (int)Round(value) : null;
        var grade = CareerReview.Grade(total);
        var good = questions.Count(x => (x.Number("score") ?? -1) >= 75);
        var weak = questions.Count(x => x.Number("score") is { } s && s < 60);
        var counts = report.Get("category_counts");
        var mix = string.Join("、", new[] { "technical", "project", "behavioral", "hr" }.Select(key => counts.Integer(key) > 0 ? $"{counts.Integer(key)} {CareerReview.CategoryLabel(key)}" : null).OfType<string>());
        var dimensions = report.Items("dimensions");

        var totalColumn = new StackPanel { Spacing = 4, Width = 140 + 24, Padding = new Thickness(0, 0, 24, 0), BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(0, 0, 1, 0) };
        totalColumn.Children.Add(HStack(8, Sans("总分", 11.5, CareerPalette.Sub), grade is { } g ? CareerChipView.Make(g) : null));
        totalColumn.Children.Add(Baseline(Serif(total?.ToString() ?? "—", 48), Sans("/ 100", 13, CareerPalette.Faint)));
        if (report.Number("question_average") is { } average)
            totalColumn.Children.Add(Mono(report.Number("dimension_score") is { } dimension ? $"题目 {Format(average)} × 70% + 维度 {Format(dimension)} × 30%" : $"题目 {Format(average)}", 10.5, CareerPalette.Faint).Wrap());
        var summary = VStack(10, Sans(report.Text("summary"), 15, CareerPalette.Text, Medium).Spaced(4).Wrap(),
            Sans(string.Join(" · ", $"识别问题 {questions.Count} 题", $"表现较好 {good} 题", $"待提升 {weak} 题"), 12, CareerPalette.Sub).Wrap());
        var hero = Columns(28, (Auto, totalColumn), (Star(), summary));
        summary.VerticalAlignment = VerticalAlignment.Center;
        var heroCard = new Border
        {
            Child = hero, Padding = new Thickness(28, 24, 28, 24), CornerRadius = new CornerRadius(14), Background = Brush(CareerPalette.Soft),
            BorderBrush = Brush(CareerPalette.PipelineLine), BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 0, 28),
        };
        var rows = new StackPanel();
        for (var index = 0; index < dimensions.Count; index++)
        {
            if (index > 0) rows.Children.Add(Divider(CareerPalette.Line));
            rows.Children.Add(DimensionRow(dimensions[index]).Pad(0, index == 0 ? 0 : 14, 0, 14));
        }
        var radar = CareerRadar.Make(dimensions);
        radar.Width = 240; radar.Height = 240;
        var body = Columns(24, (Px(240), radar), (Star(), rows));
        radar.VerticalAlignment = VerticalAlignment.Top;
        rows.VerticalAlignment = VerticalAlignment.Top;
        return VStack(0, heroCard, SectionTitle("能力维度", $"1–5 分 · 权重按本场 {(mix.Length == 0 ? "题目" : mix)} 计算"), body);
    }

    static StackPanel Baseline(TextBlock big, TextBlock small)
    {
        small.VerticalAlignment = VerticalAlignment.Bottom;
        small.Margin = new Thickness(0, 0, 0, big.FontSize * 0.18);
        var row = HStack(4, big, small);
        return row;
    }

    FrameworkElement DimensionRow(JsonNode item)
    {
        var assessed = item.Bool("assessed");
        var score = item.Number("score") ?? 0;
        var value = Mono(assessed ? $"{(int)score} / 5" : "未评估", 11.5, CareerPalette.Sub, Medium);
        value.TextAlignment = TextAlignment.Right;
        var head = Columns(16, (Px(72), Sans(CareerReview.DimensionLabel(item.Text("key")), 13, CareerPalette.Text, Medium)), (Star(), Track(score / 5, assessed && score < 3)), (Px(48), value));
        var stack = VStack(6, head, Sans(CareerReview.DimensionNote(item), 12, CareerPalette.Sub).Wrap().Pad(88, 0, 0, 0));
        if (item.Text("evidence").Length > 0) stack.Children.Add(Quote(item.Text("evidence")).Pad(88, 0, 0, 0));
        return stack;
    }

    static FrameworkElement Track(double fraction, bool low)
    {
        var grid = new Grid { Height = 4, VerticalAlignment = VerticalAlignment.Center };
        grid.Children.Add(new Border { CornerRadius = new CornerRadius(2), Background = Brush(CareerPalette.Border) });
        var bar = new Border { CornerRadius = new CornerRadius(2), Background = Brush(low ? CareerPalette.Orange : CareerPalette.Text), HorizontalAlignment = HorizontalAlignment.Left };
        grid.Children.Add(bar);
        grid.SizeChanged += (_, e) => bar.Width = e.NewSize.Width * Math.Max(0, Math.Min(1, fraction));
        return grid;
    }

    static FrameworkElement Quote(string value) => new Border
    {
        Child = Sans(value, 12, CareerPalette.Faint).Wrap().Selectable(), Padding = new Thickness(10, 0, 0, 0),
        BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(2, 0, 0, 0),
    };

    static FrameworkElement SectionTitle(string title, string sub)
    {
        var row = HStack(10, Sans(title, 15, CareerPalette.Text, Medium), Sans(sub, 11.5, CareerPalette.Faint));
        row.Margin = new Thickness(0, 0, 0, 14);
        return row;
    }

    static string Format(double value) => value == Math.Round(value) ? $"{(int)value}" : value.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);
}
