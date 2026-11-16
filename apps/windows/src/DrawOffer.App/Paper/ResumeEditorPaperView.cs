using System.Text.Json.Nodes;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using DrawOffer.Core.Paper;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;

namespace DrawOffer.App.Paper;

/// <summary>纸上临时显示的一处改法（分区 12：浅蓝底 = 还没换上，橙色 = 要核实）。只是装饰，不改正文（Mac `PaperLineChange`）。</summary>
/// <param name="Before">AI 看到的原句：纸上这一行已经不是它时不预览。</param>
public sealed record PaperLineChange(string LineId, string Before, string Text, IReadOnlyList<string> Risky)
{
    internal JsonObject Json => new()
    {
        ["lineId"] = LineId, ["before"] = Before, ["text"] = Text,
        ["risky"] = new JsonArray(Risky.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray()),
    };
}

/// <summary>检查简历纸边的小圆圈（12.7–12.11）：空心 = 还没看，蓝 = 正在看，灰 = 看过（Mac `PaperMark`）。</summary>
public sealed record PaperMark(string Key, IReadOnlyList<string> NodeIds, PaperMark.State Status)
{
    public enum State { Pending, Current, Done }
    internal JsonObject Json => new()
    {
        ["key"] = Key, ["nodeIds"] = new JsonArray(NodeIds.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray()),
        ["state"] = Status switch { State.Current => "current", State.Done => "done", _ => "pending" },
    };
}

/// <summary>光标 / 选区所在的行（纸面 `line` 事件，Mac `PaperLine`）。坐标是纸面视图里的点（CSS px），已含缩放。</summary>
/// <param name="Selection">只选了一行里的几个字时的字符范围（含 start、不含 end）。</param>
/// <param name="Rect">第一行的位置。</param>
/// <param name="Paper">纸面（第一页所在的整张纸）的位置。</param>
public sealed record PaperLine(string UnitId, IReadOnlyList<string> LineIds, (int Start, int End)? Selection, Windows.Foundation.Rect Rect, Windows.Foundation.Rect Paper);

/// <summary>原生 → 可编辑纸面的指令（editor protocol 1，见 `apps/native/renderer/editor.tsx`），对应 Mac `ResumeEditorCommand`。</summary>
public sealed record ResumeEditorCommand(JsonObject Json)
{
    public static ResumeEditorCommand Undo => new(new JsonObject { ["type"] = "undo" });
    public static ResumeEditorCommand Redo => new(new JsonObject { ["type"] = "redo" });
    public static ResumeEditorCommand Focus => new(new JsonObject { ["type"] = "focus" });
    public static ResumeEditorCommand ResetOrder => new(new JsonObject { ["type"] = "reset-order" });
    public static ResumeEditorCommand Jump(string? id) => new(new JsonObject { ["type"] = "jump", ["nodeId"] = id is null ? null : JsonValue.Create(id) });
    public static ResumeEditorCommand Reorder(IEnumerable<string> ids) => new(new JsonObject { ["type"] = "reorder", ["nodeIds"] = new JsonArray(ids.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray()) });
    public static ResumeEditorCommand Rename(string id, string title) => new(new JsonObject { ["type"] = "rename", ["nodeId"] = id, ["title"] = title });
    public static ResumeEditorCommand Remove(string id) => new(new JsonObject { ["type"] = "remove", ["nodeId"] = id });
    public static ResumeEditorCommand Add(string kind, string title) => new(new JsonObject { ["type"] = "add", ["kind"] = kind, ["title"] = title });
    /// <summary>临时高亮这几行、把改法预览在纸上；同一 source 再发一次即替换，两项都空即清除。</summary>
    public static ResumeEditorCommand Decorate(string source, IEnumerable<string> highlight, IEnumerable<PaperLineChange> preview) => new(new JsonObject
    {
        ["type"] = "decorate", ["source"] = source,
        ["highlight"] = new JsonArray(highlight.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray()),
        ["preview"] = new JsonArray(preview.Select(x => (JsonNode?)x.Json).ToArray()),
    });
    public static ResumeEditorCommand Marks(IEnumerable<PaperMark> marks) => new(new JsonObject
    {
        ["type"] = "marks", ["marks"] = new JsonArray(marks.Select(x => (JsonNode?)x.Json).ToArray()),
    });
    /// <summary>滚到这几行（放在屏幕中间）。</summary>
    public static ResumeEditorCommand Reveal(IEnumerable<string> ids) => new(new JsonObject
    {
        ["type"] = "reveal", ["nodeIds"] = new JsonArray(ids.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray()),
    });
}

/// <summary>纸面 → 原生的事件，对应 Mac `ResumeEditorEvent`。</summary>
public abstract record ResumeEditorEvent
{
    public sealed record Changed(JsonNode Data, JsonNode Style) : ResumeEditorEvent;
    public sealed record History(bool CanUndo, bool CanRedo) : ResumeEditorEvent;
    /// <summary>选区工具栏「问 AI」：选中的那一行与一句修改要求。</summary>
    public sealed record Ask(string UnitId, string LineId, string Text, string Instruction) : ResumeEditorEvent;
    public sealed record Zoom(double Value) : ResumeEditorEvent;
    public sealed record Error(string Message) : ResumeEditorEvent;
    /// <summary>光标所在的可改写行；null 表示不在可改的行上（或正在打字）。</summary>
    public sealed record Line(PaperLine? Value) : ResumeEditorEvent;
    /// <summary>在纸面里按了 Ctrl+K。</summary>
    public sealed record LineOpen(PaperLine Value) : ResumeEditorEvent;
    /// <summary>纸面总页数。</summary>
    public sealed record Pages(int Count) : ResumeEditorEvent;
    /// <summary>点了纸边的小圆圈。</summary>
    public sealed record Mark(string Key) : ResumeEditorEvent;
    /// <summary>Windows 专有：焦点在网页里时 Ctrl+= / Ctrl+- / Ctrl+0 不会到达原生快捷键，由注入脚本转回（Mac 的 ⌘ 菜单快捷键始终先到原生）。</summary>
    public sealed record Key(string Name) : ResumeEditorEvent;
}

/// <summary>把指令排进纸面：编辑器视图持有它，页面 ready 后才真正执行（Mac `ResumeEditorChannel`）。</summary>
public sealed class ResumeEditorChannel
{
    internal ResumeEditorPaperView? Bridge { get; set; }
    public void Send(ResumeEditorCommand command) => Bridge?.Call("command", command.Json);
    /// <summary>原生改写正文（引导写入、AI 采纳）：页面按当前模板重新排版。</summary>
    public void ReplaceData(JsonNode? data) => Bridge?.Call("replaceData", data);
    /// <summary>07.2 模板悬停预览：`template-preview` 接口返回的 preview（data / style / layout_plan）；null 恢复原纸面。不改正文、不保存。</summary>
    public void PreviewTemplate(JsonNode? preview) => Bridge?.Call("previewTemplate", preview);
}

/// <summary>
/// 可编辑简历纸面（Mac `ResumeEditorPaperView` + `EditorBridge` + `PaperSchemeHandler`）：WebView2 挂载与 Web 相同的 TipTap 编辑器、分页、
/// 斜杠菜单与选区工具栏。页面经自定义 scheme `drawoffer-paper://editor/` 加载（与页面 CSP 里的 `drawoffer-paper:` 一致）；
/// 纸面里的 `/api/...` 图片与图片上传由 <see cref="OnResource"/> 带凭据转发，页面本身不持有凭据，也不能访问其他地址。
/// 页面用 `window.webkit.messageHandlers.drawoffer` 回报，文档创建时注入一个转到 `chrome.webview.postMessage` 的同名对象。
/// </summary>
public sealed partial class ResumeEditorPaperView : UserControl
{
    public const string Scheme = "drawoffer-paper";
    public const string EditorUrl = "drawoffer-paper://editor/index.html";
    const int MaxUploadBytes = 14 * 1024 * 1024;

    // WKWebView 的 messageHandlers 在 WebView2 里不存在：用同名对象转发，页面脚本不需要区分平台
    const string BridgeScript = @"(function () {
  if (!window.chrome || !window.chrome.webview || (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.drawoffer)) return;
  window.webkit = { messageHandlers: { drawoffer: { postMessage: function (message) { window.chrome.webview.postMessage(message); } } } };
  window.addEventListener('keydown', function (event) {
    if (!event.ctrlKey || event.altKey || event.metaKey) return;
    var name = event.key === '+' ? '=' : event.key === '_' ? '-' : event.key;
    if (name !== '=' && name !== '-' && name !== '0') return;
    event.preventDefault();
    window.chrome.webview.postMessage({ type: 'native-key', key: name });
  }, true);
})();";

    readonly WebView2 _webView = new();
    readonly string _resumeId;
    readonly IApiClient _api;
    // Mac 用 nonPersistent 数据存储；WebView2 用本实例独占的临时目录，卸载时删除
    readonly string _dataFolder = Path.Combine(Path.GetTempPath(), "DrawOffer-Editor-" + Guid.NewGuid().ToString("N"));
    readonly List<(string method, JsonNode? argument)> _queue = [];
    bool _ready, _unloaded;
    int _styleRevision;
    JsonNode? _lastView;

    public Action<ResumeEditorEvent> OnEvent { get; set; }

    public ResumeEditorPaperView(string resumeId, JsonNode? data, JsonNode? style, JsonNode? layoutPlan, int styleRevision, double zoom, bool horizontal,
        ResumeEditorChannel channel, IApiClient api, Action<ResumeEditorEvent> onEvent)
    {
        _resumeId = resumeId;
        _api = api;
        OnEvent = onEvent;
        Content = _webView;
        channel.Bridge = this;
        Load(resumeId, data, style, layoutPlan, styleRevision);
        SetView(zoom, horizontal);
        _ = InitializeAsync();
        _channel = channel;
    }

    readonly ResumeEditorChannel _channel;

    /// <summary>
    /// Mac `dismantleNSView`：停止加载、丢弃排队的指令、关闭 WebView2 并删除临时数据目录。
    /// 不挂在 Unloaded 上：WinUI 换父容器也会触发 Unloaded，由持有方在真正移除时调用。
    /// </summary>
    public void Dispose()
    {
        if (_unloaded) return;
        _unloaded = true;
        _queue.Clear();
        _ready = false;
        if (_channel.Bridge == this) _channel.Bridge = null;
        _webView.Close();
        try { Directory.Delete(_dataFolder, true); } catch { }
    }

    void Load(string resumeId, JsonNode? data, JsonNode? style, JsonNode? layoutPlan, int styleRevision)
    {
        _styleRevision = styleRevision;
        // features.lineChat：选区工具栏只管格式，纸面上报光标所在的行（改这一条在原生）
        Call("load", new JsonObject
        {
            ["resumeId"] = resumeId, ["data"] = data?.DeepClone(), ["style"] = style?.DeepClone(), ["layout_plan"] = layoutPlan?.DeepClone(),
            ["features"] = new JsonObject { ["lineChat"] = true },
        });
    }

    /// <summary>排版面板改动的版式按 revision 下发；页面内编辑产生的版式变化不回传，避免回环。</summary>
    public void UpdateStyle(JsonNode? style, int revision)
    {
        if (revision == _styleRevision) return;
        _styleRevision = revision;
        Call("setStyle", style);
    }

    public void SetView(double zoom, bool horizontal)
    {
        JsonNode view = new JsonObject { ["zoom"] = zoom, ["arrangement"] = horizontal ? "horizontal" : "vertical" };
        if (JsonNode.DeepEquals(view, _lastView)) return;
        _lastView = view;
        Call("setView", view);
    }

    /// <summary>参数经 System.Text.Json 编码为 JS 字面量，不拼接未转义的用户文字。</summary>
    internal void Call(string method, JsonNode? argument)
    {
        if (!_ready) { _queue.Add((method, argument?.DeepClone())); return; }
        var json = argument?.ToJsonString() ?? "null";
        _ = _webView.CoreWebView2?.ExecuteScriptAsync($"window.drawofferEditor.{method}({json})");
    }

    async Task InitializeAsync()
    {
        try
        {
            var options = new CoreWebView2EnvironmentOptions();
            var registration = new CoreWebView2CustomSchemeRegistration(Scheme);
            // 这一版 WinRT 投影把 BOOL 暴露成 int
            registration.TreatAsSecure = 1;
            registration.HasAuthorityComponent = true;
            options.CustomSchemeRegistrations.Add(registration);
            var environment = await CoreWebView2Environment.CreateWithOptionsAsync("", _dataFolder, options);
            if (_unloaded) return;
            await _webView.EnsureCoreWebView2Async(environment);
            if (_unloaded) return;
            var core = _webView.CoreWebView2;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            // ⌘/Ctrl + 滚轮由页面按 Web 规则缩放并回报给原生；浏览器自带缩放关掉
            core.Settings.IsZoomControlEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            await core.AddScriptToExecuteOnDocumentCreatedAsync(BridgeScript);
            core.AddWebResourceRequestedFilter($"{Scheme}://*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += OnResource;
            core.WebMessageReceived += OnMessage;
            // 只允许编辑器页本身；纸面里的链接不在 App 里打开
            core.NavigationStarting += (_, args) => { if (args.Uri != EditorUrl) args.Cancel = true; };
            core.NewWindowRequested += (_, args) => args.Handled = true;
            _webView.DefaultBackgroundColor = Microsoft.UI.Colors.Transparent;
            core.Navigate(EditorUrl);
        }
        catch (Exception)
        {
            if (!_unloaded) OnEvent(new ResumeEditorEvent.Error("编辑器加载失败，请确认 WebView2 可用。"));
        }
    }

    void OnMessage(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        if (_unloaded) return;
        JsonNode? body;
        try { body = JsonNode.Parse(args.WebMessageAsJson); } catch { return; }
        switch (body.Text("type"))
        {
            case "ready":
                if (body.Number("protocol") != 1) { OnEvent(new ResumeEditorEvent.Error("编辑器资源版本不匹配，请更新客户端。")); return; }
                _ready = true;
                var pending = _queue.ToList();
                _queue.Clear();
                foreach (var (method, argument) in pending) Call(method, argument);
                break;
            case "changed":
                if (body.Get("data") is not (JsonObject or JsonArray) || body.Get("style") is not (JsonObject or JsonArray)) return;
                OnEvent(new ResumeEditorEvent.Changed(body.Get("data")!.DeepClone(), body.Get("style")!.DeepClone()));
                break;
            case "history":
                OnEvent(new ResumeEditorEvent.History(body.Bool("canUndo"), body.Bool("canRedo")));
                break;
            case "ask":
                if (body.Get("unitId").String() is not { } unit || body.Get("lineId").String() is not { } line) return;
                OnEvent(new ResumeEditorEvent.Ask(unit, line, body.Text("text"), body.Text("instruction")));
                break;
            case "zoom":
                if (body.Number("zoom") is { } value) OnEvent(new ResumeEditorEvent.Zoom(value));
                break;
            case "error":
                OnEvent(new ResumeEditorEvent.Error(body.Get("message").String() ?? "编辑器出错，请重试。"));
                break;
            case "line":
                OnEvent(new ResumeEditorEvent.Line(LineOf(body)));
                break;
            case "line-open":
                if (LineOf(body) is { } open) OnEvent(new ResumeEditorEvent.LineOpen(open));
                break;
            case "pages":
                if (body.Number("count") is { } count && count > 0) OnEvent(new ResumeEditorEvent.Pages((int)count));
                break;
            case "mark":
                if (body.Get("key").String() is { } key) OnEvent(new ResumeEditorEvent.Mark(key));
                break;
            case "native-key":
                if (body.Text("key") is "=" or "-" or "0") OnEvent(new ResumeEditorEvent.Key(body.Text("key")));
                break;
        }
    }

    static Windows.Foundation.Rect? BoxOf(JsonNode? value)
    {
        if (value.Number("x") is not { } x || value.Number("y") is not { } y || value.Number("width") is not { } width || value.Number("height") is not { } height) return null;
        return new Windows.Foundation.Rect(x, y, Math.Max(0, width), Math.Max(0, height));
    }

    static PaperLine? LineOf(JsonNode? body)
    {
        if (body.Get("unitId").String() is not { } unit) return null;
        var ids = body.Items("lineIds").Select(x => x.String()).OfType<string>().ToList();
        if (ids.Count == 0 || BoxOf(body.Get("rect")) is not { } rect || BoxOf(body.Get("paper")) is not { } paper) return null;
        (int, int)? selection = null;
        if (body.Get("selection").Number("start") is { } start && body.Get("selection").Number("end") is { } end && end > start) selection = ((int)start, (int)end);
        return new PaperLine(unit, ids, selection, rect, paper);
    }

    /// <summary>`drawoffer-paper://editor/`：编辑器页、模板示例头像、简历图片读取与上传。其余地址一律 404（Mac `PaperSchemeHandler`）。</summary>
    async void OnResource(CoreWebView2 sender, CoreWebView2WebResourceRequestedEventArgs args)
    {
        var deferral = args.GetDeferral();
        try
        {
            var (status, body, type) = await Respond(args.Request);
            if (_unloaded) return;
            var stream = new MemoryStream(body).AsRandomAccessStream();
            args.Response = sender.Environment.CreateWebResourceResponse(stream, status, status == 200 ? "OK" : "Error",
                $"Content-Type: {type}\r\nContent-Length: {body.Length}\r\nCache-Control: no-store");
        }
        catch { }
        finally { deferral.Complete(); }
    }

    async Task<(int status, byte[] body, string type)> Respond(CoreWebView2WebResourceRequest request)
    {
        var notFound = (404, Array.Empty<byte>(), "text/plain");
        if (!Uri.TryCreate(request.Uri, UriKind.Absolute, out var url) || url.Scheme != Scheme || url.Host != "editor") return notFound;
        var path = url.AbsolutePath;
        var method = request.Method ?? "GET";
        var renderer = Path.Combine(AppContext.BaseDirectory, "Assets", "Renderer");
        if (path == "/index.html" && method == "GET")
        {
            var file = Path.Combine(renderer, "editor.html");
            return File.Exists(file) ? (200, await File.ReadAllBytesAsync(file), "text/html; charset=utf-8") : notFound;
        }
        if (path.StartsWith("/templates/", StringComparison.Ordinal) && method == "GET")
        {
            var name = path["/templates/".Length..];
            var file = Path.Combine(renderer, "templates", name);
            if (!PaperAssets.IsBundledTemplate(path) || !File.Exists(file)) return notFound;
            var type = Path.GetExtension(name).TrimStart('.') switch { "png" => "image/png", "jpg" => "image/jpeg", "svg" => "image/svg+xml", _ => "application/octet-stream" };
            return (200, await File.ReadAllBytesAsync(file), type);
        }
        if (path == $"/api/resumes/{_resumeId}/assets" && method == "POST")
        {
            // 页面上传：`{file_name, data_url}`，与 Web `api.uploadResumeAsset` 同一请求体
            var invalid = (400, System.Text.Encoding.UTF8.GetBytes("{\"error\":\"INVALID_ASSET\"}"), "application/json");
            var raw = await ReadBody(request);
            if (raw is null) return invalid;
            JsonNode? payload;
            try { payload = JsonNode.Parse(raw); } catch { return invalid; }
            if (payload.Get("file_name").String() is not { } name || payload.Get("data_url").String() is not { } dataUrl) return invalid;
            try
            {
                var result = await _api.CareerRequestAsync($"/api/resumes/{_resumeId}/assets", "POST", body: new JsonObject
                {
                    ["file_name"] = name.Length > 120 ? name[..120] : name, ["data_url"] = dataUrl,
                });
                return (200, System.Text.Encoding.UTF8.GetBytes(result.ToJsonString()), "application/json");
            }
            catch (Exception error)
            {
                var (status, code) = error switch
                {
                    ApiException { Status: System.Net.HttpStatusCode.Unauthorized } => (401, "UNAUTHORIZED"),
                    ApiException api => ((int)api.Status, api.Code),
                    _ => (502, "UPLOAD_FAILED"),
                };
                return (status, System.Text.Encoding.UTF8.GetBytes(new JsonObject { ["error"] = code }.ToJsonString()), "application/json");
            }
        }
        if (path.StartsWith("/api/", StringComparison.Ordinal) && method == "GET")
        {
            try
            {
                if ((_api as HttpApiClient)?.Coordinator is not { } coordinator) return notFound;
                var image = await coordinator.ResumeImageAsync(path);
                return (200, image.Data, image.ContentType);
            }
            catch { return notFound; }
        }
        return notFound;
    }

    static async Task<byte[]?> ReadBody(CoreWebView2WebResourceRequest request)
    {
        if (request.Content is not { } content) return null;
        using var stream = content.AsStreamForRead();
        using var buffer = new MemoryStream();
        var chunk = new byte[64 * 1024];
        int count;
        while ((count = await stream.ReadAsync(chunk)) > 0)
        {
            buffer.Write(chunk, 0, count);
            if (buffer.Length > MaxUploadBytes) return null;
        }
        return buffer.ToArray();
    }
}
