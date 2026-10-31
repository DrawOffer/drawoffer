using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Career.CareerKit;

namespace DrawOffer.App.Views.Career;

/// <summary>
/// 04.C03 阶段详情（Mac `CareerStageDetailView`，Web `StageDetailPage.tsx`）：一场面试、HR 沟通或笔试的文字稿 / 题目、
/// 准备、AI 分析与复盘笔记。转写与复盘生成在后台完成，进行中每 10 秒刷新一次。
/// </summary>
public sealed partial class CareerStageDetailView : UserControl
{
    public enum Sheet { Upload, Library, Text, Edit, Notes, Analysis, ImportQuestions, Reschedule, Plan }

    readonly string _sessionId;
    readonly Action _back;
    readonly Action _openReport;
    JsonNode _detail = new JsonObject();
    bool _loading = true;
    string? _error;
    string? _notice;
    bool _expanded;
    bool _busy;
    DateTimeOffset _now = DateTimeOffset.Now;
    int _request;
    bool _alive = true;
    DispatcherTimer? _poll;
    V3Overlay? _sheet;
    CareerAudioBar? _audioBar;
    CareerPrepChecklist? _checklist;
    readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };

    public CareerStageDetailView(string sessionId, Action back, Action openReport)
    {
        _sessionId = sessionId;
        _back = back;
        _openReport = openReport;
        Content = _scroll;
        Loaded += (_, _) => { _alive = true; Render(); Refresh(); };
        Unloaded += (_, _) => { _alive = false; _request++; StopPolling(); _sheet?.Close(); _audioBar?.Stop(); };
    }

    JsonNode Session => _detail.Get("session") ?? new JsonObject();
    JsonNode Application => _detail.Get("application") ?? new JsonObject();
    List<JsonNode> Assets => _detail.Items("assets");
    bool IsWritten => Session.Text("stage_type") == "other";
    bool Archived => Application.Text("archived_at").Length > 0;
    bool Scheduled => Session.Text("status") == "scheduled";
    string RecordText => Session.Text("questions_markdown").Trim();
    JsonNode? Audio => Assets.FirstOrDefault(x => x.Text("asset_type") == "audio");
    JsonNode? Report => Session.Get("review_report") is JsonNode report && report.GetValueKind() != System.Text.Json.JsonValueKind.Null ? report : null;
    bool Generating => Session.Text("review_status") == "generating";
    JsonNode? Transcription => Audio is { } audio ? CareerTranscript.Transcription(Session, audio.Text("id")) : null;
    bool Transcribing => Transcription?.Text("status") is "queued" or "running";
    string Kind => IsWritten ? "笔试" : "面试";

    /// <summary>`refreshed = UUID()`：重新读取并重绘。</summary>
    void Refresh() => _ = LoadAsync();

    void Render() => KeepFocus(XamlRoot, Rebuild);

    void Rebuild()
    {
        var stack = new StackPanel { Spacing = 24 };
        if (Session.Text("id").Length == 0)
        {
            stack.Children.Add(CareerBreadcrumb.Make("← 求职进度", "阶段记录", _back));
            if (_loading) stack.Children.Add(Spinner("正在加载记录…"));
            if (_error is { } error) stack.Children.Add(HStack(8, Sans(error, 13, CareerPalette.Red), new CareerAction("重试", Refresh)));
        }
        else
        {
            stack.Children.Add(Header());
            if (_notice is { } notice) stack.Children.Add(Sans(notice, 12, CareerPalette.Sub).Wrap().Selectable());
            var main = new StackPanel { Spacing = 16 };
            main.Children.Add(RecordCard());
            if (IsWritten && Session.Text("schedule_kind") == "open_window") main.Children.Add(PlanCard());
            if (!IsWritten && (Scheduled || Session.Items("prep_items").Count > 0 || Session.Text("preparation_note").Length > 0))
            {
                main.Children.Add(Checklist());
                if (Session.Text("preparation_note").Length > 0)
                    main.Children.Add(VStack(14, Sans("准备提醒", 15, CareerPalette.Text, Medium), NoteBlock(Session.Text("preparation_note"))).CareerCard(20));
            }
            var side = VStack(14, ReportCard(), NotesCard(), InfoCard());
            side.Width = 276;
            stack.Children.Add(Columns(24, (Star(), main), (Px(276), side)).Also(g => { main.VerticalAlignment = VerticalAlignment.Top; side.VerticalAlignment = VerticalAlignment.Top; }));
        }
        stack.Padding = new Thickness(0, 35, 0, 64);
        // `.frame(maxWidth: 860).padding(.horizontal, 32).frame(maxWidth: .infinity)`：拉伸到最多 860，超出时居中
        var frame = new Grid { Padding = new Thickness(32, 0, 32, 0) };
        frame.Children.Add(new Border { Child = stack, MaxWidth = 860, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Top });
        _scroll.Content = frame;
        UpdatePolling();
    }

    // MARK: Header

    string Meta
    {
        get
        {
            var range = CareerFormat.Range(Session.Text("start_at"), Session.Text("end_at"));
            string?[] parts = IsWritten
                ? [Session.Text("schedule_kind") == "open_window" ? $"截止 {CareerFormat.MonthDay(Session.Text("end_at"))} {CareerFormat.Clock(Session.Text("end_at"))}" : range, CareerSessions.ModeText(Session)]
                : [range, CareerSessions.ModeText(Session), Session.Text("interviewer_name").Length == 0 ? null : "面试官 " + Session.Text("interviewer_name")];
            return string.Join(" · ", parts.OfType<string>());
        }
    }

    UIElement Header()
    {
        var title = HStack(10, Serif(Session.Text("stage_label"), 26), CareerChipView.Make(CareerTranscript.Status(Session, Application, _now)));
        var left = VStack(6,
            CareerBreadcrumb.Make($"← {Application.Text("job_title_snapshot")} · {Application.Text("company_name_snapshot")}", "阶段记录", _back),
            title,
            Sans(Meta, 13, CareerPalette.Sub));
        if (Archived) return left;
        var actions = HStack(8);
        if (IsWritten) actions.Children.Add(new CareerAction("导入题目", () => Open(Sheet.ImportQuestions)));
        else if (Scheduled) actions.Children.Add(new CareerAction("编辑本轮", () => Open(Sheet.Reschedule)));
        actions.Children.Add(MoreMenu());
        return Spread(left, actions, 16, VerticalAlignment.Top);
    }

    /// <summary>「···」更多操作菜单（Mac `Menu` borderless，最小 58×30、圆角 8 描边）。</summary>
    FrameworkElement MoreMenu()
    {
        var menu = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
        void Item(string title, Action action, bool destructive = false)
        {
            var item = new MenuFlyoutItem { Text = title };
            if (destructive) item.Foreground = Brush(CareerPalette.Red);
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        if (IsWritten && Scheduled) Item("修改安排", () => Open(Sheet.Reschedule));
        if (RecordText.Length > 0)
        {
            Item("编辑文字记录", () => Open(Sheet.Edit));
            Item("删除文字记录", () => _ = ConfirmDeleteAsync(), destructive: true);
        }
        Item("从资料库添加", () => Open(Sheet.Library));
        var label = Sans("···", 12, CareerPalette.Text, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        label.CharacterSpacing = 166;
        var button = new Border
        {
            Child = label, MinWidth = 58, MinHeight = 30, CornerRadius = new CornerRadius(8), Background = Brush(V3.White),
            BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1), Padding = new Thickness(8, 0, 8, 0),
        };
        return button.OnTap(() => menu.ShowAt(button), "更多操作");
    }

    async Task ConfirmDeleteAsync()
    {
        if (XamlRoot is null) return;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = $"删除这场{Kind}的文字记录？", Content = "录音与已生成的报告会保留，删除后可以重新添加。",
            PrimaryButtonText = "删除", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await UpdateAsync(new JsonObject { ["questions_markdown"] = null });
    }

    // MARK: Record

    UIElement RecordCard()
    {
        var questions = IsWritten ? CareerTranscript.Questions(RecordText) : [];
        var lines = CareerTranscript.Lines(RecordText);
        var card = new StackPanel { Spacing = 14 };
        var head = new Grid { ColumnSpacing = 8 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = Auto });
        var titleRow = HStack(8, Sans(IsWritten ? "笔试题目" : "面试文字稿", 15, CareerPalette.Text, Medium),
            IsWritten && questions.Count > 0 ? CareerChipView.Make($"{questions.Count} 题", CareerTone.Gray) : null);
        head.Children.Add(titleRow);
        var trailing = HStack(8);
        if (!IsWritten && Audio is { } audio)
        {
            var name = Sans(Session.Text("transcript_source") == "transcription" ? audio.Text("original_file_name") + " · 自动转写" : audio.Text("original_file_name"), 11, CareerPalette.Faint);
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            name.HorizontalAlignment = HorizontalAlignment.Right;
            Grid.SetColumn(name, 1);
            head.Children.Add(name);
        }
        if (!IsWritten && (Audio is not null || RecordText.Length > 0) && !Archived) trailing.Children.Add(new CareerAction("替换", () => Open(Sheet.Upload)));
        Grid.SetColumn(trailing, 2);
        head.Children.Add(trailing);
        card.Children.Add(head);

        if (RecordText.Length == 0 && Audio is null)
        {
            var plus = new Border
            {
                Width = 40, Height = 40, CornerRadius = new CornerRadius(20), Background = Brush(V3.White), BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1),
                Child = Icon("plus", 14, CareerPalette.Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center), HorizontalAlignment = HorizontalAlignment.Center,
            };
            var empty = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(16, 28, 16, 28) };
            empty.Children.Add(plus);
            empty.Children.Add(Sans(IsWritten ? "导入笔试题目，按题记录作答情况" : "上传录音或文字稿，统一整理为文字稿", 14, CareerPalette.Text, Medium).Align(HorizontalAlignment.Center).Wrap());
            empty.Children.Add(Sans(IsWritten ? "可以粘贴题目文本、上传截图，或从资料库选择 PDF / Word 文档" : "支持 mp3 / m4a 录音或 txt / docx 文本，录音会自动转写", 12, CareerPalette.Faint).Align(HorizontalAlignment.Center).Wrap());
            foreach (var child in empty.Children.OfType<TextBlock>()) child.TextAlignment = TextAlignment.Center;
            if (!Archived)
            {
                var buttons = HStack(8);
                buttons.HorizontalAlignment = HorizontalAlignment.Center;
                if (IsWritten) buttons.Children.Add(new CareerAction("导入题目", () => Open(Sheet.ImportQuestions), CareerAction.Kind.Primary));
                else
                {
                    buttons.Children.Add(new CareerAction("上传录音", () => Open(Sheet.Upload), CareerAction.Kind.Primary));
                    buttons.Children.Add(new CareerAction("粘贴文本", () => Open(Sheet.Text)));
                    buttons.Children.Add(new CareerAction("导入文件", () => Open(Sheet.Library)));
                }
                empty.Children.Add(buttons);
            }
            card.Children.Add(Dashed(empty, 12, CareerPalette.Rail, CareerPalette.Soft));
            return card.CareerCard(20);
        }

        if (Audio is { } recording) card.Children.Add(AudioBar(recording));
        if (!IsWritten && TranscriptionStatus() is { } status) card.Children.Add(status);
        if (IsWritten && questions.Count > 0)
        {
            var list = new StackPanel();
            for (var index = 0; index < questions.Count; index++)
            {
                if (index > 0) list.Children.Add(Divider(CareerPalette.Line));
                var row = Columns(12, (Auto, Mono(Two(index + 1), 11, CareerPalette.Faint, Medium)), (Star(), Sans(questions[index], 13, CareerPalette.Text).Wrap().Selectable()));
                row.Padding = new Thickness(0, index == 0 ? 0 : 14, 0, 14);
                foreach (var child in row.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Top;
                list.Children.Add(row);
            }
            card.Children.Add(list);
        }
        else if (RecordText.Length > 0)
        {
            var visible = _expanded ? lines : lines.Take(8).ToList();
            var paragraphs = new StackPanel { Spacing = 12 };
            foreach (var line in visible)
            {
                if (line.Speaker is { } speaker)
                {
                    var chip = new Border
                    {
                        Child = Sans(speaker, 11, line.IsMe ? CareerPalette.Blue : CareerPalette.Sub, Medium), Padding = new Thickness(6, 2, 6, 2),
                        Background = Brush(line.IsMe ? CareerPalette.BlueSoft : CareerPalette.ChipGray), CornerRadius = new CornerRadius(4), HorizontalAlignment = HorizontalAlignment.Left,
                    };
                    var body = new Border
                    {
                        Child = Sans(line.Text, 13, CareerPalette.Text).Spaced(3).Wrap().Selectable(),
                        Padding = line.IsMe ? new Thickness(10, 8, 10, 8) : new Thickness(0), CornerRadius = new CornerRadius(8),
                        Background = Brush(line.IsMe ? CareerPalette.BlueSoft : Clear), HorizontalAlignment = HorizontalAlignment.Left,
                    };
                    var row = Columns(12, (Px(48), chip), (Star(), body));
                    chip.VerticalAlignment = VerticalAlignment.Top;
                    body.VerticalAlignment = VerticalAlignment.Top;
                    paragraphs.Children.Add(row);
                }
                else paragraphs.Children.Add(Sans(line.Text, 13, CareerPalette.Text).Spaced(3).Wrap().Selectable());
            }
            card.Children.Add(paragraphs);
            if (lines.Count > 8)
                card.Children.Add(new CareerAction(_expanded ? "收起" : $"展开全部（共 {lines.Count} 段）↓", () => { _expanded = !_expanded; Render(); }, CareerAction.Kind.Muted));
        }
        else card.Children.Add(Sans("录音已上传，转写完成后显示在这里。", 12, CareerPalette.Hint).Wrap());
        return card.CareerCard(20);
    }

    UIElement AudioBar(JsonNode asset)
    {
        if (_audioBar is null || _audioBar.AssetId != asset.Text("id"))
        {
            _audioBar?.Stop();
            _audioBar = new CareerAudioBar(asset, message => { _notice = message; Render(); });
        }
        return Detach(_audioBar);
    }

    UIElement Checklist()
    {
        var readOnly = Archived || !Scheduled;
        if (_checklist is null || _checklist.SessionId != Session.Text("id"))
            _checklist = new CareerPrepChecklist(Session, readOnly, Refresh, message => { _notice = message; Render(); });
        else _checklist.Update(Session, readOnly);
        return Detach(_checklist);
    }

    UIElement? TranscriptionStatus()
    {
        if (Transcribing) return StatusBanner("正在转写录音，完成后会自动显示文字稿…", false, null, "");
        if (Transcription is { } failed && failed.Text("status") == "failed")
            return StatusBanner(CareerTranscript.TranscriptionError(failed.Text("error_code")), true, Archived ? null : () => _ = TranscriptionCommandAsync("retry"), "重新转写");
        if (Transcription is { } done && done.Text("status") == "succeeded" && done.Bool("pending_replace"))
            return StatusBanner("录音转写已完成，当前保留的是你之前的文字稿。", false, Archived ? null : () => _ = TranscriptionCommandAsync("apply"), "用转写结果替换");
        if (Audio is not null && Transcription is null && RecordText.Length == 0 && !Archived)
            return StatusBanner("这段录音还没有转写。", false, () => _ = TranscriptionCommandAsync("retry"), "开始转写");
        return null;
    }

    UIElement StatusBanner(string message, bool red, Action? action, string title)
    {
        var row = HStack(10, Sans(message, 12, red ? CareerPalette.Red : CareerPalette.Sub).Wrap());
        if (action is not null) row.Children.Add(LinkButton(title, action, 12, CareerPalette.Text, !_busy));
        return new Border { Child = row, Padding = new Thickness(12, 8, 12, 8), CornerRadius = new CornerRadius(10), Background = Brush(red ? CareerPalette.RedSoft : CareerPalette.ChipGray) };
    }

    UIElement PlanCard()
    {
        string start = Session.Text("answer_plan_start_at"), end = Session.Text("answer_plan_end_at");
        var actions = HStack(8);
        if (!Archived && Scheduled)
        {
            if (start.Length > 0) actions.Children.Add(new CareerAction("清除", () => _ = ClearPlanAsync(), CareerAction.Kind.Text) { Enabled = !_busy });
            actions.Children.Add(new CareerAction(start.Length == 0 ? "设置计划" : "修改计划", () => Open(Sheet.Plan)));
        }
        return VStack(10,
            Spread(Sans("作答计划", 15, CareerPalette.Text, Medium), actions, 8),
            Sans("开放窗口 " + CareerFormat.Range(Session.Text("start_at"), Session.Text("end_at")), 12, CareerPalette.Sub),
            Sans(start.Length == 0 ? "还没有设置作答计划。计划只提醒自己，不影响官方截止时间。" : "我的作答计划 " + CareerFormat.Range(start, end), 13, start.Length == 0 ? CareerPalette.Hint : CareerPalette.Text).Wrap()
        ).CareerCard(20);
    }

    static Border NoteBlock(string value, bool clamped = false) => new()
    {
        Child = Sans(value, 13, CareerPalette.Text).Spaced(3).Wrap(clamped ? 4 : 0).Selectable(),
        Padding = new Thickness(12), CornerRadius = new CornerRadius(10), Background = Brush(CareerPalette.Soft), HorizontalAlignment = HorizontalAlignment.Stretch,
    };
}
