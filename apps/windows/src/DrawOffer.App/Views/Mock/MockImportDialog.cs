using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

/// <summary>
/// 导入面试记录（Windows 稿 09 · 09.01 弹窗、09.02 粘贴文字；Mac `MockImportDialog`、Web `v2/ImportDialog.tsx`）：只要文件或文字、公司和时间，不用先有投递。
/// 文字和文档当场拆题、生成复盘；录音先上传转写，转写好后在这场的面试资料里接着生成。
/// </summary>
internal sealed class MockImportDialog : UserControl
{
    static readonly string[] Media = ["mp3", "m4a", "wav", "webm", "ogg", "mp4", "mov", "aac"];
    static readonly string[] Documents = ["pdf", "docx", "doc", "txt", "md"];

    readonly Action _close, _done;
    readonly TextBox _text = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, PlaceholderText = "把面试问答贴在这里", FontSize = 13.5, FontFamily = SansFamily, Height = 160 };
    readonly TextBox _company = new() { PlaceholderText = "比如云川科技", MaxLength = 100, FontSize = 13.5, FontFamily = SansFamily };
    readonly CalendarDatePicker _date = new() { Date = Beijing.Now, MaxDate = Beijing.Now, PlaceholderText = "选择日期", HorizontalAlignment = HorizontalAlignment.Stretch };
    bool _paste, _busy, _over;
    string? _file, _failed;
    (string Key, string Session)? _created;
    DatasetUpload? _upload;
    readonly Border _textBox, _companyBox;
    V3Button? _submit;

    MockImportDialog(Action close, Action done)
    {
        (_close, _done) = (close, done);
        AutomationProperties.SetName(_text, "面试文字稿");
        AutomationProperties.SetName(_company, "公司");
        AutomationProperties.SetName(_date, "时间");
        // 输入时只刷新按钮，不重建（保住焦点）
        _text.TextChanged += (_, _) => { if (_submit is not null) _submit.Enabled = Ready && !_busy; };
        _company.TextChanged += (_, _) => { if (_submit is not null) _submit.Enabled = Ready && !_busy; };
        _textBox = Field(_text, MP.Field);
        _companyBox = Field(_company, V3.White);
        Unloaded += (_, _) => _upload?.Discard();
        Render();
    }

    public static void Show(XamlRoot root, Action done)
    {
        V3Overlay? overlay = null;
        overlay = V3Overlay.Show(root, close => new MockImportDialog(close, () => { overlay?.Close(); done(); }));
    }

    bool Ready => _company.Text.Trim().Length > 0 && (_paste ? _text.Text.Trim().Length > 0 : _file is not null);

    static void Detach(FrameworkElement element)
    {
        if (element.Parent is Panel panel) panel.Children.Remove(element);
        else if (element.Parent is Border border) border.Child = null;
    }

    void Render()
    {
        Detach(_textBox); Detach(_companyBox); Detach(_date);
        var body = new StackPanel();
        if (_paste)
        {
            body.Children.Add(_textBox.Top(18));
            body.Children.Add(MP.Link("‹ 改为上传文件", () => { _paste = false; Render(); }, blue: true).Top(8));
        }
        else
        {
            var drop = new Grid { Height = 112, AllowDrop = true, Background = Brush(Clear) };
            drop.Children.Add(new Rectangle { RadiusX = 12, RadiusY = 12, Fill = Brush(MP.RowHover), Stroke = Brush(_over ? MP.Blue : MP.Cl), StrokeThickness = 1, StrokeDashArray = [4, 3] });
            drop.Children.Add(VStack(2,
                Sans(_file is null ? "拖入录音或文字稿，或点击选择" : System.IO.Path.GetFileName(_file), 14, MP.Ink).Also(t => { t.TextTrimming = TextTrimming.CharacterEllipsis; t.HorizontalAlignment = HorizontalAlignment.Center; }),
                Sans(_file is null ? "mp3、m4a、wav、PDF、Word" : "点击换一个文件", 13, MP.Fnt).Also(t => t.HorizontalAlignment = HorizontalAlignment.Center))
                .Align(HorizontalAlignment.Stretch, VerticalAlignment.Center).Pad(16, 0, 16, 0));
            drop.DragOver += (_, e) =>
            {
                e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy;
                if (!_over) { _over = true; Render(); }
            };
            drop.DragLeave += (_, _) => { _over = false; Render(); };
            drop.Drop += async (_, e) =>
            {
                _over = false;
                if (e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)
                    && (await e.DataView.GetStorageItemsAsync()).OfType<Windows.Storage.StorageFile>().FirstOrDefault() is { } file && Allowed(file.Path))
                    Choose(file.Path);
                else Render();
            };
            drop.OnTap(() => _ = Pick(), "选择录音或文字稿");
            body.Children.Add(drop.Top(18));
            body.Children.Add(MP.Link("粘贴文字 ›", () => { _paste = true; Render(); }, blue: true).Top(8));
        }
        var fields = HStack(12, Labeled("公司", _companyBox), Labeled("时间", _date));
        body.Children.Add(fields.Top(20));
        UIElement? left = _failed is null ? null : Sans(_failed, 12.5, MP.Orange).Wrap().Also(t => t.MaxWidth = 200);
        Content = MP.Form("导入面试记录", "录音或文字稿都可以，导入后会记进你的长期记忆。", body, left,
            [MP.Ghost("取消", _close, 36, !_busy), _submit = MP.Dark(_busy ? "正在导入…" : "开始导入", () => _ = Run(), 36, Ready && !_busy)], large: true);
    }

    static FrameworkElement Labeled(string label, FrameworkElement content)
    {
        Detach(content);
        return VStack(6, Sans(label, 13, MP.Sub).Frame(height: 20), content.Frame(height: 40)).Frame(width: 192);
    }

    static Border Field(Control input, Windows.UI.Color background)
    {
        input.BorderThickness = new Thickness(0);
        input.Background = Brush(Clear);
        input.Padding = new Thickness(12, 9, 12, 0);
        input.VerticalAlignment = VerticalAlignment.Stretch;
        return new Border { Child = input, CornerRadius = new CornerRadius(10), Background = Brush(background), BorderBrush = Brush(MP.Cl), BorderThickness = new Thickness(1) };
    }

    static bool Allowed(string path) => Media.Concat(Documents).Contains(System.IO.Path.GetExtension(path).TrimStart('.').ToLowerInvariant());

    void Choose(string path)
    {
        _file = path;
        _upload?.Discard();
        _upload = null;
        _failed = null;
        Render();
    }

    async Task Pick()
    {
        if (_busy || App.NativeWindow is not { } window) return;
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        foreach (var extension in Media.Concat(Documents)) picker.FileTypeFilter.Add("." + extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
        if (await picker.PickSingleFileAsync() is { } file) Choose(file.Path);
    }

    string Day => (_date.Date ?? Beijing.Now).ToString("yyyy-MM-dd");

    static Task<JsonNode> Request(string path, string method = "GET", JsonNode? body = null) => App.Session.Api.CareerRequestAsync(path, method, [], body);

    async Task Run()
    {
        _busy = true; _failed = null; Render();
        try
        {
            var name = _company.Text.Trim();
            var key = $"{name}|{Day}";
            // 失败后重试不再建一条新的面试记录
            if (_created?.Key != key)
            {
                var record = await Request("/api/mock-interviews/imports", "POST", new JsonObject { ["company_name"] = name, ["occurred_on"] = Day });
                _created = (key, record.Display("session_id"));
            }
            var session = _created!.Value.Session;
            JsonNode source = new JsonObject { ["source"] = "text", ["text"] = _text.Text.Trim() };
            if (!_paste && _file is { } file)
            {
                _upload ??= await Task.Run(() => DatasetUpload.Snapshot(file, "1", 512L * 1024 * 1024));
                if (App.Session.Api is not HttpApiClient client) throw new InvalidDataException();
                var result = await client.Coordinator.UploadSessionAssetAsync(session, _upload);
                _upload.Discard(); _upload = null;
                if (Media.Contains(System.IO.Path.GetExtension(file).TrimStart('.').ToLowerInvariant()))
                {
                    // 录音交给后台转写：转写好后在这场的面试资料里生成复盘
                    _done();
                    return;
                }
                var asset = result.Get("asset").Display("id").NonEmpty() ?? result.Display("id");
                if (!await WaitForParse(asset)) { _failed = "这个文件读不出文字，换一份试试。"; _busy = false; Render(); return; }
                source = new JsonObject { ["source"] = "dataset", ["dataset_id"] = asset };
            }
            var draft = await Request($"/api/interview-sessions/{session}/record:structure", "POST", source);
            var markdown = InterviewRecord.Serialize(InterviewRecord.Draft(draft));
            var before = await Request($"/api/interview-sessions/{session}");
            await Request($"/api/interview-sessions/{session}", "PUT",
                new JsonObject { ["questions_markdown"] = markdown.Length == 0 ? null : markdown, ["base_lock_version"] = before.Get("session").Get("lock_version")?.DeepClone() ?? 1 });
            var saved = await Request($"/api/interview-sessions/{session}");
            await Request($"/api/interview-sessions/{session}/review:generate", "POST",
                new JsonObject { ["request_id"] = Guid.NewGuid().ToString().ToLowerInvariant(), ["base_lock_version"] = saved.Get("session").Get("lock_version")?.DeepClone() ?? 1 });
            _done();
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: var status } && (int)status is >= 400 and < 500 && status != System.Net.HttpStatusCode.Conflict) { _upload?.Discard(); _upload = null; }
            _failed = error is ApiException { Code: "INTERVIEW_QUESTIONS_NOT_FOUND" } ? "没找到面试问题，换一份文字稿试试。" : "导入没有完成：" + MP.Error(error);
            _busy = false;
            Render();
        }
    }

    static async Task<bool> WaitForParse(string id)
    {
        for (var i = 0; i < 30; i++)
        {
            var dataset = await Request($"/api/datasets/{id}");
            var status = dataset.Get("dataset").Text("parse_status").NonEmpty() ?? dataset.Text("parse_status");
            if (status == "succeeded") return true;
            if (status == "failed") return false;
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
        return false;
    }
}
