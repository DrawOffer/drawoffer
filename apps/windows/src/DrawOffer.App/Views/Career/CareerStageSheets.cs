using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Career.CareerKit;

namespace DrawOffer.App.Views.Career;

/// <summary>阶段弹窗基类：状态变化时整体重建 `CareerSheet`，输入框实例跨重建保留。</summary>
public abstract class CareerSheetControl : UserControl
{
    protected abstract (string Title, string Subtitle, double Width, double? Height, IEnumerable<UIElement> Content, IEnumerable<UIElement> Footer) Build();

    protected void Render() => KeepFocus(XamlRoot, Rebuild);

    void Rebuild()
    {
        var (title, subtitle, width, height, content, footer) = Build();
        var sheet = CareerSheet.Make(title, width, content.ToList(), footer.ToList(), subtitle);
        if (height is { } h) sheet.Height = h;
        Content = sheet;
    }

    protected static TextBlock Error(string? error) => error is null ? null! : ErrorText(error);

    /// <summary>`Button(…).buttonStyle(CareerActionStyle(large: true))`。</summary>
    protected static CareerAction Large(string title, Action action, bool enabled = true, CareerAction.Kind kind = CareerAction.Kind.Outline)
        => new(title, action, kind, large: true) { Enabled = enabled };

    /// <summary>三选一的来源卡片（上传 / 资料库 / 粘贴）：白底 10 圆角，选中 1.5 黑边，否则 1px #E6E6E2。</summary>
    protected static FrameworkElement Choice(UIElement icon, string title, bool selected, Action action, bool enabled)
    {
        var label = Sans(title, 12, selected ? CareerPalette.Text : CareerPalette.Sub, selected ? Medium : Regular);
        if (icon is FontIcon glyph) glyph.Foreground = Brush(selected ? CareerPalette.Text : CareerPalette.Sub);
        if (icon is TextBlock text) text.Foreground = Brush(selected ? CareerPalette.Text : CareerPalette.Sub);
        var stack = VStack(4, icon, label);
        foreach (var child in stack.Children.OfType<FrameworkElement>()) child.HorizontalAlignment = HorizontalAlignment.Center;
        var card = new Border
        {
            Child = stack, Padding = new Thickness(0, 12, 0, 12), CornerRadius = new CornerRadius(10), Background = Brush(V3.White),
            BorderBrush = Brush(selected ? CareerPalette.Text : CareerPalette.Border), BorderThickness = new Thickness(selected ? 1.5 : 1),
            Opacity = enabled ? 1 : 0.6,
        };
        return card.OnTap(action, title, () => enabled);
    }

    protected static Grid Row(params FrameworkElement[] items)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        for (var i = 0; i < items.Length; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            Grid.SetColumn(items[i], i);
            grid.Children.Add(items[i]);
        }
        return grid;
    }

    /// <summary>资料库里的一份文件（`CareerFileBadge` 34 + 名称 / 类型），右侧放操作。</summary>
    protected static Border FileRow(string name, string meta, UIElement? trailing, string? badge = null)
    {
        var icon = badge is null ? CareerFileBadge.Make(name, 34) : new Border
        {
            Width = 34, Height = 34, CornerRadius = new CornerRadius(8), BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1),
            Child = Sans(badge, 8, CareerPalette.Sub, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        };
        var title = Sans(name, 13, CareerPalette.Text, Medium);
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        var row = Columns(12, (Auto, icon), (Star(), VStack(2, title, Sans(meta, 11, CareerPalette.Faint))), (Auto, trailing ?? new Border()));
        return new Border { Child = row, Padding = new Thickness(12, 10, 12, 10), CornerRadius = new CornerRadius(10), BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1) };
    }
}

/// <summary>05.N20 添加记录（Mac `CareerAddContentSheet`）：上传录音或文档到这一场、从资料库关联，或粘贴文字。</summary>
public sealed class CareerAddContentSheet : CareerSheetControl
{
    public enum Mode { Upload, Library, Text }

    readonly JsonNode _session;
    readonly string _recordKind;
    readonly Action _close;
    readonly Action _saved;
    Mode _mode;
    string? _file;
    readonly CareerTextArea _text;
    List<JsonNode>? _datasets;
    bool _busy;
    string? _error;
    DatasetUpload? _upload;

    public CareerAddContentSheet(JsonNode session, string recordKind, Mode initialMode, Action close, Action saved)
    {
        _session = session;
        _recordKind = recordKind;
        _close = close;
        _saved = saved;
        _mode = initialMode;
        _text = new CareerTextArea("", placeholder: $"粘贴{recordKind}过程、逐字稿或整理后的文字记录…", minHeight: 220);
        _text.Box.TextChanged += (_, _) => Render();
        Unloaded += (_, _) => { if (!_busy) { _upload?.Discard(); _upload = null; } };
        Render();
        if (_mode == Mode.Library) _ = LoadDatasetsAsync();
    }

    protected override (string, string, double, double?, IEnumerable<UIElement>, IEnumerable<UIElement>) Build()
    {
        var content = new List<UIElement>();
        content.Add(Row(
            Choice(Icon("square.and.arrow.up", 14), "上传文件", _mode == Mode.Upload, () => Switch(Mode.Upload), !_busy),
            Choice(Icon("folder", 14), "从资料库选择", _mode == Mode.Library, () => Switch(Mode.Library), !_busy),
            Choice(Icon("doc.text", 14), "粘贴文字", _mode == Mode.Text, () => Switch(Mode.Text), !_busy)));
        switch (_mode)
        {
            case Mode.Upload:
                var drop = VStack(6,
                    Icon("square.and.arrow.up", 18, CareerPalette.Sub),
                    Sans(_file is null ? "点击选择或拖放文件" : System.IO.Path.GetFileName(_file), 13, CareerPalette.Text, Medium),
                    Sans(_file is null ? "支持音视频与 PDF、DOCX、Markdown、TXT" : "已选择", 12, CareerPalette.Faint));
                foreach (var child in drop.Children.OfType<FrameworkElement>()) child.HorizontalAlignment = HorizontalAlignment.Center;
                drop.Padding = new Thickness(0, 32, 0, 32);
                var zone = Dashed(drop, 12, CareerPalette.Rail, CareerPalette.Soft);
                zone.AllowDrop = true;
                zone.DragOver += (_, e) => { e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy; };
                zone.Drop += async (_, e) =>
                {
                    if (!e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
                    var items = await e.DataView.GetStorageItemsAsync();
                    if (items.FirstOrDefault() is Windows.Storage.StorageFile file) { _file = file.Path; Render(); }
                };
                content.Add(Tappable(zone, () => _ = ChooseAsync(), "点击选择或拖放文件", () => !_busy && _upload is null));
                if (_recordKind.Length > 0 && _recordKind == "面试") content.Add(Sans("录音上传后会自动转写为文字稿。", 12, CareerPalette.Hint));
                break;
            case Mode.Library:
                if (_datasets is { } datasets)
                {
                    if (datasets.Count == 0) content.Add(Sans("资料库还没有可用的文件。", 12, CareerPalette.Hint));
                    var list = new StackPanel { Spacing = 8 };
                    foreach (var item in datasets)
                    {
                        var id = item.Text("id");
                        var kind = item.Text("asset_kind") switch { "audio" => "录音", "video" => "视频", _ => "文档" };
                        list.Children.Add(FileRow(item.Text("file_name"), kind, new CareerAction("添加", () => _ = AttachAsync(id)) { Enabled = !_busy }));
                    }
                    content.Add(list);
                }
                else content.Add(Spinner("正在加载资料库…"));
                break;
            default:
                content.Add(Detach(_text));
                break;
        }
        if (_error is { } error) content.Add(ErrorText(error));
        var footer = new List<UIElement> { Large("取消", () => { _upload?.Discard(); _upload = null; _close(); }, !_busy) };
        if (_mode != Mode.Library)
            footer.Add(Large(_busy ? "保存中…" : _upload is not null ? "重试上传" : "保存内容", () => _ = SaveAsync(),
                !(_busy || (_mode == Mode.Text ? _text.Text.Trim().Length == 0 : _file is null)), CareerAction.Kind.Primary));
        return ($"添加{_recordKind}内容", $"选择一种方式保存本场{_recordKind}记录。", 640, 560, content, footer);
    }

    void Switch(Mode mode)
    {
        _mode = mode; _error = null; Render();
        if (mode == Mode.Library && _datasets is null) _ = LoadDatasetsAsync();
    }

    async Task LoadDatasetsAsync()
    {
        try
        {
            var result = await App.Session.Api.CareerRequestAsync("/api/datasets");
            var items = result.Items("datasets") is { Count: > 0 } found ? found : result.Items("items");
            _datasets = items.Where(x => new DatasetRecord(x).Ready).ToList();
        }
        catch (Exception error) { Fail(error); _datasets = []; _error = CareerErrors.Message(error); }
        Render();
    }

    async Task ChooseAsync()
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        foreach (var ext in new[] { ".mp3", ".m4a", ".wav", ".aac", ".flac", ".ogg", ".mp4", ".mov", ".m4v", ".webm", ".pdf", ".txt", ".docx", ".md" }) picker.FileTypeFilter.Add(ext);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        if (await picker.PickSingleFileAsync() is { } file) { _file = file.Path; _error = null; Render(); }
    }

    async Task SaveAsync()
    {
        _busy = true; _error = null; Render();
        try
        {
            if (_mode == Mode.Text)
                await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_session.Text("id")}", "PUT",
                    body: new JsonObject { ["questions_markdown"] = _text.Text.Trim(), ["base_lock_version"] = Lock(_session) });
            else if (_file is { } file)
            {
                // 快照与幂等键在失败后保留，重试不会产生第二份
                _upload ??= DatasetUpload.Snapshot(file, "1", 512L * 1024 * 1024);
                if (App.Session.Api is not DrawOffer.Core.Api.HttpApiClient client) throw new InvalidDataException();
                await client.Coordinator.UploadSessionAssetAsync(_session.Text("id"), _upload);
                _upload.Discard(); _upload = null;
            }
            _busy = false;
            _saved();
        }
        catch (Exception error)
        {
            Fail(error);
            if (Server(error, out var status, out _) && status is >= 400 and < 500 && status != 409) { _upload?.Discard(); _upload = null; }
            _error = CareerErrors.Message(error);
            _busy = false; Render();
        }
    }

    async Task AttachAsync(string datasetId)
    {
        _busy = true; _error = null; Render();
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_session.Text("id")}/assets/attach", "POST", body: new JsonObject { ["dataset_id"] = datasetId });
            _busy = false;
            _saved();
        }
        catch (Exception error) { Fail(error); _error = CareerErrors.Message(error); _busy = false; Render(); }
    }
}

/// <summary>编辑这一场的文字记录或题目（Mac `CareerTextSheet`）。</summary>
public sealed class CareerTextSheet : CareerSheetControl
{
    readonly string _title, _subtitle;
    readonly JsonNode _session;
    readonly Action _close, _saved;
    readonly CareerTextArea _text;
    bool _busy;
    string? _error;

    public CareerTextSheet(string title, string subtitle, string initial, JsonNode session, Action close, Action saved)
    {
        (_title, _subtitle, _session, _close, _saved) = (title, subtitle, session, close, saved);
        _text = new CareerTextArea("", initial, minHeight: 300);
        _text.Box.TextChanged += (_, _) => Render();
        Render();
    }

    protected override (string, string, double, double?, IEnumerable<UIElement>, IEnumerable<UIElement>) Build()
    {
        var content = new List<UIElement> { Detach(_text) };
        if (_error is { } error) content.Add(ErrorText(error));
        return (_title, _subtitle, 640, 520, content,
        [
            Large("取消", _close, !_busy),
            Large(_busy ? "保存中…" : "保存修改", () => _ = SaveAsync(), !(_busy || _text.Text.Trim().Length == 0), CareerAction.Kind.Primary),
        ]);
    }

    async Task SaveAsync()
    {
        _busy = true; _error = null; Render();
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_session.Text("id")}", "PUT",
                body: new JsonObject { ["questions_markdown"] = _text.Text.Trim(), ["base_lock_version"] = Lock(_session) });
            _busy = false;
            _saved();
        }
        catch (Exception error) { Fail(error); _error = CareerErrors.Message(error); _busy = false; Render(); }
    }
}

/// <summary>复盘笔记（Mac `CareerNotesSheet`）：这一轮的复盘与下次怎么答。</summary>
public sealed class CareerNotesSheet : CareerSheetControl
{
    readonly JsonNode _session;
    readonly Action _close, _saved;
    readonly CareerTextArea _summary, _improvement;
    bool _busy;
    string? _error;

    public CareerNotesSheet(JsonNode session, Action close, Action saved)
    {
        (_session, _close, _saved) = (session, close, saved);
        _summary = new CareerTextArea("这一轮的复盘", session.Text("review_summary"), "哪些问题答得好，哪里卡住了");
        _improvement = new CareerTextArea("下次怎么答", session.Text("improvement_markdown"), "先一句结论，再讲动机和自己负责的部分");
        Render();
    }

    protected override (string, string, double, double?, IEnumerable<UIElement>, IEnumerable<UIElement>) Build()
    {
        var content = new List<UIElement> { Detach(_summary), Detach(_improvement) };
        if (_error is { } error) content.Add(ErrorText(error));
        return ("复盘笔记", _session.Text("stage_label"), 640, 480, content,
        [
            Large("取消", _close, !_busy),
            Large(_busy ? "保存中…" : "保存", () => _ = SaveAsync(), !_busy, CareerAction.Kind.Primary),
        ]);
    }

    async Task SaveAsync()
    {
        _busy = true; _error = null; Render();
        static JsonNode? Value(string text) { var trimmed = text.Trim(); return trimmed.Length == 0 ? null : JsonValue.Create(trimmed); }
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_session.Text("id")}", "PUT",
                body: new JsonObject { ["review_summary"] = Value(_summary.Text), ["improvement_markdown"] = Value(_improvement.Text), ["base_lock_version"] = Lock(_session) });
            _busy = false;
            _saved();
        }
        catch (Exception error) { Fail(error); _error = CareerErrors.Message(error); _busy = false; Render(); }
    }
}

/// <summary>05.N22 AI 复盘（Mac `CareerAnalysisSheet`）：先展示分析依据，再在后台开始生成。</summary>
public sealed class CareerAnalysisSheet : CareerSheetControl
{
    readonly JsonNode _detail;
    readonly string? _audioName;
    readonly Action _close, _started;
    bool _busy;
    string? _error;
    string _requestId = Guid.NewGuid().ToString("D");

    JsonNode Session => _detail.Get("session") ?? new JsonObject();
    JsonNode Application => _detail.Get("application") ?? new JsonObject();

    public CareerAnalysisSheet(JsonNode detail, string? audioName, Action close, Action started)
    {
        (_detail, _audioName, _close, _started) = (detail, audioName, close, started);
        Render();
    }

    protected override (string, string, double, double?, IEnumerable<UIElement>, IEnumerable<UIElement>) Build()
    {
        var range = CareerFormat.Range(Session.Text("start_at"), Session.Text("end_at"));
        var written = Session.Text("questions_markdown").Trim().Length > 0;
        (string Badge, string Name, string Meta, bool Ready)[] sources =
        [
            ("PDF", Application.Text("resume_title_snapshot").Or("投递简历"), "投递简历", Application.Text("resume_title_snapshot").Length > 0),
            (_audioName is { } audio ? CareerFileBadge.Badge(audio) : "TXT", _audioName ?? "面试文字稿", _audioName is null ? "文字记录" : "录音 · 已转写", written),
            ("INFO", Session.Text("stage_label"), string.Join(" · ", new[] { range, Session.Text("interviewer_name") }.Where(x => x.Length > 0)), true),
            ("MD", Application.Text("company_name_snapshot") + "_岗位JD.md", "岗位要求", Application.Text("job_description_id").Length > 0),
            ("LIB", "资料库", "按题自动召回相关资料作为佐证", true),
        ];
        var list = new StackPanel { Spacing = 8 };
        foreach (var source in sources)
            list.Children.Add(FileRow(source.Name, source.Meta, CareerChipView.Make(source.Ready ? "已就绪" : "未提供", source.Ready ? CareerTone.Green : CareerTone.Gray), source.Badge));
        var content = new List<UIElement> { Sans("分析依据", 12, CareerPalette.Text, Medium), list };
        if (_error is { } error) content.Add(ErrorText(error));
        var subtitle = string.Join(" · ", Application.Text("company_name_snapshot"), Application.Text("job_title_snapshot"), Session.Text("stage_label"), CareerFormat.MonthDay(Session.Text("start_at")));
        return ("AI 复盘", subtitle, 560, 560, content,
        [
            Large("取消", _close, !_busy),
            Large(_busy ? "正在分析…" : "开始分析", () => _ = StartAsync(), !(_busy || !written), CareerAction.Kind.Primary),
        ]);
    }

    async Task StartAsync()
    {
        _busy = true; _error = null; Render();
        try
        {
            // 重试沿用同一个 request id，结果未知时不会开始第二次生成
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{Session.Text("id")}/review:generate", "POST",
                body: new JsonObject { ["request_id"] = _requestId, ["base_lock_version"] = Lock(Session) });
            _busy = false;
            _started();
        }
        catch (Exception error)
        {
            Fail(error);
            var server = Server(error, out var status, out var code);
            if (server && status is 400 or 404 or 409) _requestId = Guid.NewGuid().ToString("D");
            _error = server && code == "LLM_MODEL_NOT_CONFIGURED" ? CareerErrors.Message(error) : "复盘生成失败，原记录和已有报告已保留。";
            _busy = false; Render();
        }
    }
}
