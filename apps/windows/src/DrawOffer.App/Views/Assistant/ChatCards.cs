using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Assistant;

/// <summary>这次记下的记忆（Mac `MemoryReceipt`，Web `CitationCard` 的“这次记下”）：可逐条撤销（写入排除约束）或恢复；可收起、关闭。</summary>
public sealed class MemoryReceipt : UserControl
{
    // 父视图重画会重建本卡，按会话保存已读结果与操作状态
    static readonly Dictionary<string, (List<JsonNode> items, Dictionary<string, string> undone, bool folded, bool closed, int refresh)> Cache = [];
    readonly string _sessionId;

    public MemoryReceipt(string sessionId, int refresh)
    {
        _sessionId = sessionId;
        if (!Cache.TryGetValue(sessionId, out var state) || state.refresh != refresh)
        {
            Cache[sessionId] = (state.items ?? [], state.undone ?? [], state.folded, state.closed, refresh);
            Loaded += async (_, _) => await LoadAsync();
        }
        Render();
    }

    async Task LoadAsync()
    {
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/agent/sessions/{_sessionId}/memory/recorded");
            if (!result.Bool("enabled")) return;
            var state = Cache[_sessionId];
            Cache[_sessionId] = state with { items = result.Items("items") };
            Render();
        }
        catch { }
    }

    void Render()
    {
        var state = Cache[_sessionId];
        if (state.closed || state.items.Count == 0) { Content = null; return; }
        if (state.folded)
        {
            var chip = new Border
            {
                Child = HStack(6, Icon("brain", 11, Sub), Sans($"这次记下 {state.items.Count} 条", 12, Sub).Align(v: VerticalAlignment.Center), Icon("chevron.down", 9, Sub)),
                Padding = new Thickness(10, 0, 10, 0), Height = 26, CornerRadius = new CornerRadius(13), Background = Brush(Field), HorizontalAlignment = HorizontalAlignment.Left,
            };
            chip.OnTap(() => { Cache[_sessionId] = Cache[_sessionId] with { folded = false }; Render(); }, $"这次记下 {state.items.Count} 条");
            Content = chip;
            return;
        }
        var stack = new StackPanel { Spacing = 8 };
        var actions = HStack(8,
            Icon("chevron.up", 11, Sub).OnTap(() => { Cache[_sessionId] = Cache[_sessionId] with { folded = true }; Render(); }, "收起记下的内容"),
            Icon("xmark", 11, Sub).OnTap(() => { Cache[_sessionId] = Cache[_sessionId] with { closed = true }; Render(); }, "关闭"));
        stack.Children.Add(Spread(Sans($"这次记下 {state.items.Count} 条", 12.5, Txt, Medium), actions));
        foreach (var item in state.items)
        {
            var key = item.Text("key");
            var undone = state.undone.ContainsKey(key);
            var dot = new Ellipse { Width = 6, Height = 6, Fill = Brush(undone ? Fnt2 : V3.Blue), VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 6, 0, 0) };
            var text = Sans(undone ? "已撤销，这条不会记下" : item.Text("value").NonEmpty() ?? item.Text("quote").NonEmpty() ?? item.Text("label"), 12.5, undone ? Fnt : Txt).Wrap();
            var toggle = Sans(undone ? "恢复" : "撤销", 12, Link).OnTap(() => _ = ToggleAsync(item), undone ? "恢复" : "撤销");
            stack.Children.Add(Columns(8, (GridLength.Auto, dot), (Star(), text), (GridLength.Auto, toggle)));
        }
        Content = Card(stack, 8, new Thickness(14));
    }

    async Task ToggleAsync(JsonNode item)
    {
        var key = item.Text("key");
        var undone = Cache[_sessionId].undone;
        try
        {
            if (undone.TryGetValue(key, out var id))
            {
                await App.Session.Api.CareerRequestAsync($"/api/memory/constraints/{id}", "DELETE");
                undone.Remove(key);
            }
            else
            {
                var created = await App.Session.Api.CareerRequestAsync("/api/memory/constraints", "POST",
                    body: new JsonObject { ["kind"] = "exclude", ["target"] = new JsonObject { ["target"] = item.Text("delete") } });
                undone[key] = created.Text("id");
            }
        }
        catch { }
        Render();
    }
}

/// <summary>
/// 把 AI 生成的文档以 `.md` 保存到资料库所选文件夹（Mac `SaveDocumentSheet`，Web “保存到资料库”）。重名时加时间后缀保留两份；
/// 上传使用固定标识，网络结果不确定时重试不会重复保存。
/// </summary>
public sealed class SaveDocumentDialog : UserControl
{
    readonly string _content, _title;
    readonly Action _close, _saved;
    List<JsonNode> _folders = [];
    string _folder = "";
    string _newFolder = "";
    bool _busy;
    string? _error;
    DatasetUpload? _upload;

    public SaveDocumentDialog(string content, string title, Action close, Action saved)
    {
        _content = content;
        _title = title;
        _close = close;
        _saved = saved;
        Render();
        Loaded += async (_, _) => await LoadFoldersAsync();
    }

    void Render()
    {
        var stack = new StackPanel { Spacing = 14 };
        stack.Children.Add(V3DialogHead.Make("保存到资料库", $"「{_title}」将以 Markdown 文件保存。"));
        var picker = new ComboBox { PlaceholderText = "选择文件夹", HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = !_busy && _upload is null, Height = 32 };
        foreach (var folder in _folders) picker.Items.Add(new ComboBoxItem { Content = folder.Text("name"), Tag = folder.Text("id") });
        picker.SelectedIndex = _folders.FindIndex(f => f.Text("id") == _folder);
        picker.SelectionChanged += (_, _) => { if (picker.SelectedItem is ComboBoxItem { Tag: string id }) { _folder = id; Render(); } };
        AutomationProperties.SetName(picker, "文件夹");
        stack.Children.Add(picker);
        var name = Input("或新建文件夹", _newFolder, 40);
        name.TextChanged += (_, _) => _newFolder = name.Text;
        var create = new V3Button("新建", () => _ = CreateFolderAsync()) { Enabled = !_busy };
        stack.Children.Add(Columns(8, (Star(), name), (GridLength.Auto, create)));
        if (_error is { } error) stack.Children.Add(Sans(error, 12.5, Red).Wrap());
        var cancel = new V3Button("取消", () => { _upload?.Discard(); _close(); }) { Enabled = !_busy };
        var save = new V3Button(_busy ? "正在保存…" : "保存", () => _ = SaveAsync(), V3Button.Kind.Dark) { Enabled = !_busy && _folder.Length > 0 };
        Content = V3Dialog.Make(stack, [cancel, save], () => { if (!_busy) { _upload?.Discard(); _close(); } }, 440);
    }

    async Task LoadFoldersAsync()
    {
        try
        {
            var result = await App.Session.Api.CareerRequestAsync("/api/datasets/folders");
            var folders = result.Items("folders");
            _folders = (folders.Count > 0 ? folders : result.Items("items")).Where(f => f.Text("id").Length > 0).ToList();
            if (_folder.Length == 0) _folder = _folders.FirstOrDefault()?.Text("id") ?? "";
        }
        catch { _error = "文件夹读取失败，请稍后重试。"; }
        Render();
    }

    async Task CreateFolderAsync()
    {
        if (_newFolder.Trim().Length == 0) return;
        _busy = true;
        Render();
        try
        {
            var result = await App.Session.Api.CareerRequestAsync("/api/datasets/folders", "POST", body: new JsonObject { ["name"] = _newFolder.Trim() });
            _newFolder = "";
            await LoadFoldersAsync();
            if ((result.Get("folder") ?? result).Get("id").String() is { } id) _folder = id;
        }
        catch { _error = "新建文件夹失败，可能已有同名文件夹。"; }
        finally { _busy = false; Render(); }
    }

    async Task SaveAsync()
    {
        _busy = true;
        _error = null;
        Render();
        try
        {
            if (_upload is null || _upload.Folder != _folder)
            {
                _upload?.Discard();
                var safe = new string(_title.Select(c => "/:\\\0".Contains(c) ? '-' : c).Take(80).ToArray());
                var directory = DatasetUpload.PrivateDirectory();
                try
                {
                    var source = System.IO.Path.Combine(directory, safe + ".md");
                    await File.WriteAllTextAsync(source, _content, new System.Text.UTF8Encoding(false));
                    _upload = DatasetUpload.Snapshot(source, _folder, 50 * 1024 * 1024);
                }
                finally { try { Directory.Delete(directory, true); } catch { } }
            }
            var current = _upload!;
            try { await App.Session.Api.UploadDatasetAsync(current); }
            catch (ApiException error) when (error.Code is "DATASET_NAME_CONFLICT" or "DATASET_FILENAME_CONFLICT")
            {
                current = current with { Id = Guid.NewGuid().ToString("D"), Name = _title + "-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".md" };
                _upload = current;
                await App.Session.Api.UploadDatasetAsync(current);
            }
            current.Discard();
            _upload = null;
            _saved();
            _close();
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            _error = "保存失败：结果尚未确认时可直接重试，不会重复保存。";
        }
        finally { _busy = false; Render(); }
    }
}
