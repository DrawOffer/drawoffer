using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Career.CareerKit;

namespace DrawOffer.App.Views.Career;

/// <summary>05.N21 导入笔试题（Mac `CareerWrittenImportSheet`）：三种来源 → 编号预览 → 存为这一场的题目。</summary>
public sealed class CareerWrittenImportSheet : CareerSheetControl
{
    public enum Source { Text, Images, Dataset }

    readonly JsonNode _detail;
    readonly Action _close;
    readonly Action<int> _saved;
    Source _source = Source.Text;
    readonly CareerTextArea _text;
    List<string> _images = [];
    List<JsonNode>? _datasets;
    string _datasetId = "";
    JsonNode? _preview;
    string? _busy;
    string? _error;

    JsonNode Session => _detail.Get("session") ?? new JsonObject();
    JsonNode Application => _detail.Get("application") ?? new JsonObject();
    bool Ready => _source == Source.Text ? _text.Text.Trim().Length > 0 : _source == Source.Images ? _images.Count > 0 : _datasetId.Length > 0;
    List<JsonNode> Questions => _preview.Items("questions");

    public CareerWrittenImportSheet(JsonNode detail, Action close, Action<int> saved)
    {
        (_detail, _close, _saved) = (detail, close, saved);
        _text = new CareerTextArea("题目内容", placeholder: "把笔试题目粘贴到这里，一道题一段或带题号都可以", minHeight: 120);
        _text.Box.TextChanged += (_, _) => { _preview = null; Render(); };
        Render();
    }

    static string Raw(Source source) => source switch { Source.Text => "text", Source.Images => "images", _ => "dataset" };

    protected override (string, string, double, double?, IEnumerable<UIElement>, IEnumerable<UIElement>) Build()
    {
        var guide = new StackPanel { Spacing = 12, Padding = new Thickness(16), Width = 260, MinHeight = 360, CornerRadius = new CornerRadius(12), Background = Brush(CareerPalette.ChipGray), VerticalAlignment = VerticalAlignment.Top };
        guide.Children.Add(Sans("导入后", 11, CareerPalette.Hint));
        foreach (var (title, sub) in new[] { ("题目列表", "按题号拆分，保存为这一场的题目"), ("作答记录", "逐题记录作答结果与思路"), ("截图不保存", "截图只用于这一次识别，识别后即丢弃") })
            guide.Children.Add(VStack(2, Sans(title, 12.5, CareerPalette.Text, Medium), Sans(sub, 11.5, CareerPalette.Sub).Wrap()));
        if (Session.Text("questions_markdown").Trim().Length > 0) guide.Children.Add(Sans("确认导入会替换这一场现有的题目。", 11.5, CareerPalette.Orange).Wrap());

        var right = new StackPanel { Spacing = 14 };
        right.Children.Add(Sans("导入方式", 12, CareerPalette.Text, Medium));
        FrameworkElement Option(Source item, string glyph, string title) =>
            Choice(Sans(glyph, 13, CareerPalette.Sub), title, _source == item, () => { _source = item; _preview = null; _error = null; Render(); if (item == Source.Dataset) _ = LoadDatasetsAsync(); }, _busy is null);
        right.Children.Add(Row(Option(Source.Text, "≡", "粘贴文本"), Option(Source.Images, "▣", "上传截图"), Option(Source.Dataset, "⇪", "资料库文档")));
        switch (_source)
        {
            case Source.Text: right.Children.Add(Detach(_text)); break;
            case Source.Images:
                var hint = Sans(_images.Count == 0 ? "最多 5 张，按顺序识别，每张不超过 5MB" : string.Join("、", _images.Select(System.IO.Path.GetFileName)), 12, CareerPalette.Hint).Wrap(2);
                right.Children.Add(Columns(10, (Auto, new CareerAction(_images.Count == 0 ? "选择截图" : "重新选择截图", () => _ = PickImagesAsync()) { Enabled = _busy is null }), (Star(), hint)));
                break;
            default:
                var picker = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = _datasets is not null, FontFamily = SansFamily, FontSize = 13 }.Named("资料库文档");
                picker.Items.Add(new ComboBoxItem { Content = _datasets is null ? "正在加载…" : _datasets.Count == 0 ? "资料库还没有可用的文档" : "选择一份已解析的 PDF 或 Word 文档", Tag = "" });
                foreach (var item in _datasets ?? []) picker.Items.Add(new ComboBoxItem { Content = item.Text("file_name"), Tag = item.Text("id") });
                picker.SelectedIndex = Math.Max(0, (_datasets ?? []).FindIndex(x => x.Text("id") == _datasetId) + 1);
                picker.SelectionChanged += (_, _) =>
                {
                    var id = (picker.SelectedItem as ComboBoxItem)?.Tag as string ?? "";
                    if (id == _datasetId) return;
                    _datasetId = id; _preview = null; Render();
                };
                right.Children.Add(picker);
                if (_datasets is null) _ = LoadDatasetsAsync();
                break;
        }
        if (_error is { } error) right.Children.Add(ErrorText(error));
        right.Children.Add(Spread(Sans("识别结果", 12, CareerPalette.Text, Medium), _preview is not null ? Sans($"识别到 {Questions.Count} 题", 12, CareerPalette.Hint) : new Border(), 8));
        if (_preview is not null)
        {
            var list = new StackPanel { Padding = new Thickness(12, 4, 12, 4) };
            for (var index = 0; index < Questions.Count; index++)
            {
                var item = Questions[index];
                if (index > 0) list.Children.Add(Divider(CareerPalette.Line));
                var number = item.Number("no") is { } no ? (int)no : index + 1;
                var row = Columns(12, (Auto, Mono(Two(number), 11, CareerPalette.Hint, Medium)), (Star(), Sans(item.Text("text"), 12.5, CareerPalette.Text).Wrap()));
                foreach (var child in row.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Top;
                row.Padding = new Thickness(0, 8, 0, 8);
                list.Children.Add(row);
            }
            right.Children.Add(new Border
            {
                Child = new ScrollViewer { Content = list, MaxHeight = 220, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
                CornerRadius = new CornerRadius(10), BorderBrush = Brush(CareerPalette.Border), BorderThickness = new Thickness(1),
            });
        }
        else right.Children.Add(Sans(_busy == "extract" ? "正在识别…" : "点击「识别题目」后在这里预览，确认无误再导入", 12, CareerPalette.Hint).Wrap());

        var body = Columns(20, (Px(260), guide), (Star(), right));
        right.VerticalAlignment = VerticalAlignment.Top;
        var footer = new List<UIElement> { Large("取消", _close, _busy is null) };
        footer.Add(_preview is not null
            ? Large(_busy == "save" ? "保存中…" : $"导入 {Questions.Count} 题", () => _ = SaveAsync(), _busy is null, CareerAction.Kind.Primary)
            : Large(_busy == "extract" ? "正在识别…" : "识别题目", () => _ = ExtractAsync(), Ready && _busy is null, CareerAction.Kind.Primary));
        var subtitle = string.Join(" · ", Application.Text("company_name_snapshot"), Application.Text("job_title_snapshot"), Session.Text("stage_label"), CareerFormat.MonthDay(Session.Text("start_at")));
        return ("导入笔试题", subtitle, 880, 640, [body], footer);
    }

    bool _loadingDatasets;

    async Task LoadDatasetsAsync()
    {
        if (_datasets is not null || _loadingDatasets) return;
        _loadingDatasets = true;
        try
        {
            var result = await App.Session.Api.CareerRequestAsync("/api/datasets");
            var items = result.Items("datasets") is { Count: > 0 } found ? found : result.Items("items");
            _datasets = items.Where(x => (x.Text("asset_kind").Length == 0 || x.Text("asset_kind") == "document") && x.Text("parse_status") == "succeeded").ToList();
        }
        catch (Exception error) { Fail(error); _datasets = []; }
        _loadingDatasets = false;
        Render();
    }

    async Task PickImagesAsync()
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        foreach (var ext in new[] { ".png", ".jpg", ".jpeg", ".webp" }) picker.FileTypeFilter.Add(ext);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        var picked = await picker.PickMultipleFilesAsync();
        if (picked is null || picked.Count == 0) return;
        if (picked.Count > CareerUpload.MaxImages) { _error = "一次最多上传 5 张截图。"; Render(); return; }
        if (picked.Any(file => { try { return new FileInfo(file.Path).Length > CareerUpload.MaxImageBytes; } catch (IOException) { return true; } }))
        { _error = "每张截图不能超过 5MB。"; Render(); return; }
        _error = null; _preview = null; _images = picked.Select(x => x.Path).ToList();
        Render();
    }

    async Task ExtractAsync()
    {
        _busy = "extract"; _error = null; Render();
        try
        {
            var body = new JsonObject { ["source"] = Raw(_source) };
            switch (_source)
            {
                case Source.Text: body["text"] = _text.Text; break;
                case Source.Dataset: body["dataset_id"] = _datasetId; break;
                default:
                    var images = new JsonArray();
                    foreach (var path in _images)
                    {
                        var type = System.IO.Path.GetExtension(path).TrimStart('.').ToLowerInvariant() switch
                        {
                            "png" => "image/png", "jpg" or "jpeg" => "image/jpeg", "webp" => "image/webp", _ => "application/octet-stream",
                        };
                        images.Add(new JsonObject { ["base64"] = Convert.ToBase64String(await File.ReadAllBytesAsync(path)), ["content_type"] = type });
                    }
                    body["images"] = images;
                    break;
            }
            _preview = await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{Session.Text("id")}/written-questions:extract", "POST", body: body);
        }
        catch (Exception error) { Fail(error); _error = CareerErrors.Message(error); }
        _busy = null; Render();
    }

    async Task SaveAsync()
    {
        if (_preview is not { } preview) return;
        _busy = "save"; _error = null; Render();
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{Session.Text("id")}", "PUT",
                body: new JsonObject { ["questions_markdown"] = preview.Get("markdown")?.DeepClone(), ["base_lock_version"] = Lock(Session) });
            _busy = null;
            _saved(Questions.Count);
        }
        catch (Exception error) { Fail(error); _error = CareerErrors.Message(error); _busy = null; Render(); }
    }
}

/// <summary>开放窗口笔试里的个人作答计划（Mac `CareerPlanSheet`）：须落在官方开放与截止时间之内。</summary>
public sealed class CareerPlanSheet : CareerSheetControl
{
    readonly JsonNode _session;
    readonly Action _close, _saved;
    DateTimeOffset _start, _end;
    bool _busy;
    string? _error;

    public CareerPlanSheet(JsonNode session, Action close, Action saved)
    {
        (_session, _close, _saved) = (session, close, saved);
        var windowStart = CareerApplication.Date(session.Text("start_at")) ?? DateTimeOffset.Now;
        _start = CareerApplication.Date(session.Text("answer_plan_start_at")) ?? windowStart;
        _end = CareerApplication.Date(session.Text("answer_plan_end_at")) ?? _start.AddSeconds(3600);
        Render();
    }

    protected override (string, string, double, double?, IEnumerable<UIElement>, IEnumerable<UIElement>) Build()
    {
        var content = new List<UIElement>
        {
            DateTimeRow("开始时间", _start, value => _start = value),
            DateTimeRow("结束时间", _end, value => _end = value),
            Sans("计划只提醒自己，须落在开放与截止时间之内。", 12, CareerPalette.Hint).Wrap(),
        };
        if (_error is { } error) content.Add(ErrorText(error));
        return ("作答计划", "开放窗口 " + CareerFormat.Range(_session.Text("start_at"), _session.Text("end_at")), 520, null, content,
        [
            Large("取消", _close, !_busy),
            Large(_busy ? "正在保存…" : "保存", () => _ = SaveAsync(), !_busy, CareerAction.Kind.Primary),
        ]);
    }

    async Task SaveAsync()
    {
        var windowStart = CareerApplication.Date(_session.Text("start_at")) ?? DateTimeOffset.MinValue;
        var windowEnd = CareerApplication.Date(_session.Text("end_at")) ?? DateTimeOffset.MaxValue;
        if (!(_end > _start && _start >= windowStart && _end <= windowEnd)) { _error = "我的作答计划必须在开放与截止时间内，结束须晚于开始。"; Render(); return; }
        _busy = true; _error = null; Render();
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_session.Text("id")}/answer-plan", "PUT",
                body: new JsonObject { ["base_lock_version"] = Lock(_session), ["answer_plan_start_at"] = Iso(_start), ["answer_plan_end_at"] = Iso(_end) });
            _busy = false;
            _saved();
        }
        catch (Exception error) { Fail(error); _error = CareerErrors.Message(error); _busy = false; Render(); }
    }
}
