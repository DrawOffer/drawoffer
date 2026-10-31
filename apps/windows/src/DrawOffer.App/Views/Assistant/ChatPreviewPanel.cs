using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Paper;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Assistant;

/// <summary>
/// 对话右侧的一个预览标签（Mac `ChatPreviewTab`）：简历纸面、资料库文本、AI 生成文档或本地截图，最多 6 个。
/// </summary>
public sealed record ChatPreviewTab(ChatPreviewTab.Kinds Kind, string Id, string Label)
{
    public enum Kinds { Resume, Dataset, Generated, Image }
    public string Content { get; init; } = "";
    public IReadOnlyList<string> Pending { get; init; } = [];
    public bool Saved { get; init; }
    /// <summary>截图标签的图片数据，只在本机内存中。</summary>
    public byte[]? ImageData { get; init; }
    public string Key => Kind.ToString().ToLowerInvariant() + ":" + Id;

    public const int Maximum = 6;

    /// <summary>同一文件只保留一个标签，内容有变化时就地更新；超出上限时丢掉最早打开的。</summary>
    public static List<ChatPreviewTab> Open(IReadOnlyList<ChatPreviewTab> tabs, ChatPreviewTab tab)
    {
        var next = tabs.ToList();
        var index = next.FindIndex(t => t.Key == tab.Key);
        if (index >= 0) { next[index] = tab; return next; }
        next.Add(tab);
        return next.Skip(Math.Max(0, next.Count - Maximum)).ToList();
    }

    /// <summary>消息上下文（`resume` / `resume_version` / `dataset`）对应的标签；其他类型不可预览。</summary>
    public static ChatPreviewTab? ForContext(JsonNode context)
    {
        switch (context.Text("type"))
        {
            case "resume" or "resume_version":
                var id = context.Text("resume_id").NonEmpty() ?? context.Text("id");
                return id.Length == 0 ? null : new ChatPreviewTab(Kinds.Resume, id, context.Text("label"));
            case "dataset":
                return context.Text("id").Length == 0 ? null : new ChatPreviewTab(Kinds.Dataset, context.Text("id"), context.Text("label"));
            default:
                return null;
        }
    }
}

/// <summary>
/// 对话右侧文件预览（Mac `ChatPreviewPanel`，Web `PreviewPanel.tsx`）：44 高的标签栏（全屏、更多、关闭）、内容区与 48 高的底栏。
/// </summary>
public sealed class ChatPreviewPanel : UserControl
{
    public sealed record Options(
        IReadOnlyList<ChatPreviewTab> Tabs, string? Active, IReadOnlySet<string> Unavailable,
        Action<string> Activate, Action<string> CloseTab, Action Close, Action<ChatPreviewTab> Save, Action<string> MarkUnavailable,
        bool Fullscreen, Action<bool> SetFullscreen);

    readonly Options _o;
    int _reload;
    bool _downloading, _copied;
    string? _downloadError;

    ChatPreviewTab? Current => _o.Tabs.FirstOrDefault(t => t.Key == _o.Active) ?? _o.Tabs.LastOrDefault();

    public ChatPreviewPanel(Options options)
    {
        _o = options;
        Render();
    }

    void Render()
    {
        var grid = new Grid { Background = Brush(V3.White) };
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(44) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        foreach (var tab in _o.Tabs) tabs.Children.Add(TabButton(tab));
        var fullLabel = _o.Fullscreen ? "恢复面板大小" : "全屏查看";
        var full = Icon(_o.Fullscreen ? "arrow.down.left.and.arrow.up.right" : "arrow.up.left.and.arrow.down.right", 11, Txt).Pad(4, 0, 4, 0).Tip(fullLabel)
            .OnTap(() => _o.SetFullscreen(!_o.Fullscreen), fullLabel);
        var more = Icon("ellipsis", 12, Txt).Pad(4, 0, 4, 0);
        AutomationProperties.SetName(more, "更多操作");
        more.OnTap(() =>
        {
            var menu = new MenuFlyout();
            var reload = new MenuFlyoutItem { Text = "重新加载" };
            reload.Click += (_, _) => { _reload++; Render(); };
            var others = new MenuFlyoutItem { Text = "关闭其他标签", IsEnabled = _o.Tabs.Count >= 2 };
            others.Click += (_, _) => { foreach (var t in _o.Tabs.Where(t => t.Key != Current?.Key).ToList()) _o.CloseTab(t.Key); };
            menu.Items.Add(reload);
            menu.Items.Add(others);
            menu.ShowAt(more);
        });
        var close = Icon("xmark", 11, Txt).Pad(6, 0, 6, 0).OnTap(_o.Close, "关闭预览");
        var head = Columns(4, (Star(), new ScrollViewer { Content = tabs, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Auto, VerticalScrollMode = ScrollMode.Disabled }.Align(v: VerticalAlignment.Center)),
            (GridLength.Auto, full.Align(v: VerticalAlignment.Center)), (GridLength.Auto, more.Align(v: VerticalAlignment.Center)), (GridLength.Auto, close.Align(v: VerticalAlignment.Center)));
        head.Padding = new Thickness(10, 0, 10, 0);
        grid.Children.Add(head);
        var line1 = Divider();
        Grid.SetRow(line1, 1);
        grid.Children.Add(line1);
        if (Current is { } current)
        {
            var body = Body(current);
            Grid.SetRow(body, 2);
            grid.Children.Add(body);
            var line2 = Divider();
            Grid.SetRow(line2, 3);
            grid.Children.Add(line2);
            var foot = Footer(current);
            foot.Height = 48;
            foot.Padding = new Thickness(14, 0, 14, 0);
            Grid.SetRow(foot, 4);
            grid.Children.Add(foot);
        }
        grid.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; _o.Close(); } };
        Content = grid;
    }

    FrameworkElement TabButton(ChatPreviewTab tab)
    {
        var selected = tab.Key == Current?.Key;
        var symbol = tab.Kind switch { ChatPreviewTab.Kinds.Resume => "doc.text", ChatPreviewTab.Kinds.Generated => "sparkle", ChatPreviewTab.Kinds.Image => "photo", _ => "doc" };
        var color = _o.Unavailable.Contains(tab.Key) ? Fnt : Txt;
        var label = HStack(5, Icon(symbol, 11, color), Sans(tab.Label.NonEmpty() ?? "未命名", 12, color).Frame().Also(t => t.MaxWidth = 140));
        label.OnTap(() => _o.Activate(tab.Key), tab.Label);
        var close = Icon("xmark", 8, Txt).OnTap(() => _o.CloseTab(tab.Key), $"关闭 {tab.Label}");
        var row = HStack(5, label, close.Align(v: VerticalAlignment.Center));
        return new Border { Child = row, Padding = new Thickness(9, 0, 9, 0), Height = 28, CornerRadius = new CornerRadius(7), Background = Brush(selected ? Field : Clear) }.Tip(tab.Label);
    }

    FrameworkElement Body(ChatPreviewTab tab) => tab.Kind switch
    {
        ChatPreviewTab.Kinds.Resume => new ChatResumePreview(tab.Id, tab.Pending, () => _o.MarkUnavailable(tab.Key)),
        ChatPreviewTab.Kinds.Image => new ChatImagePreview(tab.ImageData, tab.Label),
        ChatPreviewTab.Kinds.Dataset => new ChatDatasetPreview(tab.Id, () => _o.MarkUnavailable(tab.Key)),
        _ => new ScrollViewer { Content = NativeMarkdownView.Render(tab.Content).Pad(20, 20, 20, 20) },
    };

    Grid Footer(ChatPreviewTab tab)
    {
        var note = tab.Kind switch
        {
            ChatPreviewTab.Kinds.Resume => tab.Pending.Count == 0 ? "只读预览 · 编辑请在编辑器中打开" : $"{tab.Pending.Count} 处待确认修改已在简历中标出",
            ChatPreviewTab.Kinds.Dataset => "只读预览 · AI 已读取其中的文字内容",
            ChatPreviewTab.Kinds.Image => "截图 · 仅在本次对话中可见",
            _ => tab.Saved ? "已保存到资料库" : "未保存 · 仅在本次对话中可见",
        };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        switch (tab.Kind)
        {
            case ChatPreviewTab.Kinds.Resume:
                actions.Children.Add(new V3Button("在编辑器中打开", () => Shell.WorkspaceShell.Current.EditResume(tab.Id), icon: "arrow.up.right.square") { Enabled = !_o.Unavailable.Contains(tab.Key) });
                break;
            case ChatPreviewTab.Kinds.Dataset:
                if (_downloadError is { } error) actions.Children.Add(Sans(error, 11, Red).Align(v: VerticalAlignment.Center));
                actions.Children.Add(new V3Button(_downloading ? "正在下载…" : "下载文件", () => _ = DownloadAsync(tab), icon: "arrow.down.circle") { Enabled = !_downloading && !_o.Unavailable.Contains(tab.Key) });
                actions.Children.Add(new V3Button("在资料库中打开", () => Shell.WorkspaceShell.Current.Navigate(WorkspaceSection.Datasets), icon: "arrow.up.right.square"));
                break;
            case ChatPreviewTab.Kinds.Generated:
                actions.Children.Add(new V3Button(_copied ? "已复制" : "复制", () =>
                {
                    var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
                    package.SetText(tab.Content);
                    Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
                    _copied = true;
                    Render();
                    _ = Task.Delay(1500).ContinueWith(_ => DispatcherQueue.TryEnqueue(() => { _copied = false; Render(); }), TaskScheduler.Default);
                }, icon: "doc.on.doc"));
                actions.Children.Add(new V3Button(tab.Saved ? "已保存" : "保存到资料库", () => _o.Save(tab), V3Button.Kind.Dark) { Enabled = !tab.Saved });
                break;
        }
        var row = Columns(8, (Star(), Sans(note, 11.5, Fnt).Align(v: VerticalAlignment.Center)), (GridLength.Auto, actions));
        return row;
    }

    /// <summary>下载资料原文件（Web `downloadDatasetSource`）：先让用户选位置，再经桌面会话下载并复制过去。</summary>
    async Task DownloadAsync(ChatPreviewTab tab)
    {
        var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = tab.Label.NonEmpty() ?? "资料" };
        var extension = Path.GetExtension(tab.Label);
        picker.FileTypeChoices.Add(extension.Length > 0 ? extension.TrimStart('.').ToUpperInvariant() : "文件", [extension.Length > 0 ? extension : ".bin"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        var target = await picker.PickSaveFileAsync();
        if (target is null) return;
        _downloading = true;
        _downloadError = null;
        Render();
        try
        {
            var file = await App.Session.Api.DownloadDatasetAsync(tab.Id, 512L * 1024 * 1024);
            try { File.Copy(file.File, target.Path, overwrite: true); }
            finally { file.Discard(); }
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.NotFound }) _o.MarkUnavailable(tab.Key);
            _downloadError = "下载失败，请重试。";
        }
        finally { _downloading = false; Render(); }
    }
}

/// <summary>预览加载状态（Mac `PreviewStateView`）。</summary>
static class PreviewState
{
    public enum Load { Loading, Ready, Missing, Failed }

    public static bool Missing(Exception error) => error is ApiException api &&
        (api.Status is System.Net.HttpStatusCode.Forbidden or System.Net.HttpStatusCode.NotFound || api.Code.Contains("NOT_FOUND") || api.Code.Contains("FORBIDDEN"));

    public static FrameworkElement View(Load state, bool unsupported = false)
    {
        var stack = new StackPanel { Spacing = 8, Padding = new Thickness(24), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        if (state == Load.Loading) stack.Children.Add(new ProgressRing { Width = 16, Height = 16, IsActive = true });
        else
        {
            stack.Children.Add(Sans(unsupported ? "暂不支持预览此格式" : state == Load.Missing ? "这个文件已不可用" : "预览加载失败", 13.5, Txt, Medium).Align(HorizontalAlignment.Center));
            var detail = Sans(unsupported ? "Word、图片等格式请在资料库下载后查看；AI 已读取其中的文字内容。" : state == Load.Missing ? "它可能已被删除或移动，对话中的引用保留为灰色。" : "网络异常或文件解析未完成，可以从“更多操作”重新加载。", 12, Fnt).Wrap();
            detail.TextAlignment = TextAlignment.Center;
            stack.Children.Add(detail);
        }
        return stack;
    }
}

/// <summary>简历标签：取列表中的预览快照（与“我的简历”卡片同源），按面板宽度缩放显示纸面；待确认修改的原文标黄。</summary>
sealed class ChatResumePreview : UserControl
{
    PreviewState.Load _state = PreviewState.Load.Loading;
    readonly Grid _root = new() { Background = Brush(Stage) };

    public ChatResumePreview(string resumeId, IReadOnlyList<string> highlights, Action onMissing)
    {
        Content = _root;
        _root.Children.Add(PreviewState.View(_state));
        Loaded += async (_, _) =>
        {
            try
            {
                var list = await App.Session.Api.CareerRequestAsync("/api/resumes");
                var resume = list.Items("resumes").FirstOrDefault(r => r.Display("id") == resumeId);
                if (resume is null) { Show(PreviewState.Load.Missing); onMissing(); return; }
                if (resume.Get("preview") is not JsonObject preview) { Show(PreviewState.Load.Failed); return; }
                var request = new ResumeRenderRequest(resume.Text("title"), preview["data"]?.DeepClone() ?? new JsonObject(), preview["style"]?.DeepClone() ?? new JsonObject(), preview["layout_plan"]?.DeepClone());
                var prepared = await App.Session.Api.PreparePaperAsync(request);
                var paper = new ResumePaperView { Width = 794, Height = 1123, IsHitTestVisible = false };
                paper.SetHighlights(highlights);
                paper.Render(prepared.Request);
                var scale = new ScaleTransform();
                var host = new Grid { Margin = new Thickness(16), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
                var holder = new Canvas();
                holder.Children.Add(paper);
                paper.RenderTransform = scale;
                host.Children.Add(holder);
                void Fit()
                {
                    var s = Math.Max(0.3, (ActualWidth - 32) / 794);
                    scale.ScaleX = scale.ScaleY = s;
                    holder.Width = 794 * s;
                    holder.Height = paper.Height * s;
                }
                paper.Rendered += (_, height) => { paper.Height = Math.Max(1123, height); Fit(); };
                paper.RenderFailed += (_, _) => Show(PreviewState.Load.Failed);
                SizeChanged += (_, _) => Fit();
                _root.Children.Clear();
                _root.Children.Add(new ScrollViewer { Content = host });
                _state = PreviewState.Load.Ready;
                Fit();
            }
            catch (Exception error)
            {
                if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
                Show(PreviewState.Missing(error) ? PreviewState.Load.Missing : PreviewState.Load.Failed);
                if (_state == PreviewState.Load.Missing) onMissing();
            }
        };
    }

    void Show(PreviewState.Load state)
    {
        _state = state;
        _root.Children.Clear();
        _root.Children.Add(PreviewState.View(state));
    }
}

/// <summary>资料标签：`GET /api/datasets/{id}/content` 的解析文本；只预览 md/txt/pdf 的文字内容。</summary>
sealed class ChatDatasetPreview : UserControl
{
    public ChatDatasetPreview(string datasetId, Action onMissing)
    {
        Content = PreviewState.View(PreviewState.Load.Loading);
        Loaded += async (_, _) =>
        {
            try
            {
                var content = await App.Session.Api.CareerRequestAsync($"/api/datasets/{datasetId}/content");
                var format = content.Text("file_format").ToLowerInvariant();
                var unsupported = format is not ("md" or "markdown" or "txt" or "pdf");
                Content = unsupported ? PreviewState.View(PreviewState.Load.Failed, unsupported: true)
                    : new ScrollViewer { Content = NativeMarkdownView.Render(content.Text("markdown")).Pad(20, 20, 20, 20) };
            }
            catch (Exception error)
            {
                if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
                var missing = PreviewState.Missing(error);
                Content = PreviewState.View(missing ? PreviewState.Load.Missing : PreviewState.Load.Failed);
                if (missing) onMissing();
            }
        };
    }
}

/// <summary>截图标签（Web `ImageBody`）：25%–300% 缩放查看。</summary>
sealed class ChatImagePreview : UserControl
{
    int _zoom = 100;
    readonly byte[]? _data;

    public ChatImagePreview(byte[]? data, string label)
    {
        _data = data;
        AutomationProperties.SetName(this, label);
        Render();
        SizeChanged += (_, _) => Render();
    }

    void Render()
    {
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Right, Height = 32, Padding = new Thickness(12, 0, 12, 0) };
        bar.Children.Add(Icon("minus", 11, _zoom <= 25 ? Fnt2 : Txt).Align(v: VerticalAlignment.Center).OnTap(() => { _zoom = Math.Max(25, _zoom - 25); Render(); }, "缩小图片", () => _zoom > 25));
        bar.Children.Add(Number($"{_zoom}%", 11.5, Txt, Regular).Align(v: VerticalAlignment.Center).OnTap(() => { _zoom = 100; Render(); }, "恢复图片大小"));
        bar.Children.Add(Icon("plus", 11, _zoom >= 300 ? Fnt2 : Txt).Align(v: VerticalAlignment.Center).OnTap(() => { _zoom = Math.Min(300, _zoom + 25); Render(); }, "放大图片", () => _zoom < 300));
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
        grid.Children.Add(bar);
        FrameworkElement body;
        if (_data is { Length: > 0 })
        {
            var bitmap = new BitmapImage();
            using (var stream = new MemoryStream(_data)) bitmap.SetSource(stream.AsRandomAccessStream());
            var image = new Image { Source = bitmap, Stretch = Stretch.Uniform, Width = Math.Max(40, (ActualWidth - 32) * _zoom / 100), Margin = new Thickness(16) };
            body = new ScrollViewer { Content = image, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Auto, Background = Brush(Stage) };
        }
        else body = PreviewState.View(PreviewState.Load.Failed);
        Grid.SetRow(body, 1);
        grid.Children.Add(body);
        Content = grid;
    }
}
