using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Home;
using DrawOffer.Core.Models;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Home;

/// <summary>
/// 首页数据（Mac `HomeImproveModel`）：并行读取简历、资料、近 60 天到之后 30 天的面试、记忆首页与求职画像，
/// 交给 Core `HomeScenes.Pick` 挑画面。账号切换后丢弃旧结果。
/// </summary>
public sealed class HomeImproveModel
{
    public enum Phase { Loading, Failed, Ready }
    public Phase State { get; private set; } = Phase.Loading;
    public HomeInput? Input { get; private set; }
    public JsonNode? Profile { get; private set; }
    string _owner = "";
    string _disclosed = "";

    public async Task LoadAsync(IApiClient api, string account)
    {
        _owner = account;
        if (account.Length == 0) return;
        State = Phase.Loading;
        var now = DateTimeOffset.Now;
        static string Iso(DateTimeOffset value) => value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture);
        async Task<JsonNode?> Try(string path, Dictionary<string, string>? query = null)
        {
            try { return await api.CareerRequestAsync(path, "GET", query); } catch { return null; }
        }
        try
        {
            var resumes = api.CareerRequestAsync("/api/resumes");
            var datasets = Try("/api/datasets");
            var sessions = Try("/api/interview-sessions", new() { ["start_at"] = Iso(now.AddDays(-60)), ["end_at"] = Iso(now.AddDays(30)) });
            var home = Try("/api/memory/home");
            var profile = Try("/api/account/user-profile");
            var resumeList = await resumes;
            await Task.WhenAll(datasets, sessions, home, profile);
            if (_owner != account) return;
            Profile = profile.Result;
            Input = new HomeInput(now,
                home.Result is { } memory ? new MemoryHome(memory) : null,
                resumeList.Items("resumes").Select(r => new HomeResume(r.Display("id"), r.Text("title"), r.Text("updated_at"))).ToList(),
                datasets.Result.Items("datasets").Select(d => new HomeDataset(d)).ToList(),
                sessions.Result.Items("items").Select(x => HomeSession.FromJson(x)).OfType<HomeSession>().ToList(),
                Profile.Items("job_directions").Select(x => x.String()).OfType<string>().ToList(),
                Profile.Text("target_role").NonEmpty() ?? "");
            State = Phase.Ready;
        }
        catch
        {
            if (_owner != account) return;
            State = Phase.Failed;
        }
    }

    /// <summary>这一屏列出的问题登记为已告知（同一屏只报一次，失败下次再报）。</summary>
    public void Disclose(IApiClient api, IReadOnlyList<string> keys)
    {
        var signature = string.Join("|", keys);
        if (keys.Count == 0 || signature == _disclosed) return;
        _disclosed = signature;
        _ = Task.Run(async () =>
        {
            try { await api.CareerRequestAsync("/api/memory/home/disclosures", "POST", body: new JsonObject { ["issues"] = new JsonArray(keys.Select(k => (JsonNode)k).ToArray()) }); }
            catch { if (_disclosed == signature) _disclosed = ""; }
        });
    }

    public void UpdateProfile(JsonNode value)
    {
        Profile = value;
        if (Input is { } input)
        {
            input.Directions = value.Items("job_directions").Select(x => x.String()).OfType<string>().ToList();
            input.TargetRole = value.Text("target_role");
        }
    }
}

/// <summary>
/// 首页 · 哪里要提升（Mac `HomeImproveView.swift`，Web `homeImprove/HomeImproveMap.tsx`）：左上结论与先补的几处，右边星图，
/// 底部地平线时间轴与输入框。坐标是 1151×828 设计稿，整体等比缩放（<see cref="DesignCanvas.Fit"/>）。
/// </summary>
public sealed class HomeImproveView : UserControl
{
    readonly Func<string> _draft;
    readonly Action<string> _setDraft;
    readonly Action<string, string?> _send;
    readonly Action<PracticeFocus?> _practice;
    readonly Action<string> _editResume;
    readonly Action<WorkspaceSection> _navigate;
    readonly Action _importResume;
    readonly string _account;

    readonly HomeImproveModel _model = new();
    readonly Canvas _canvas = new() { Width = HomeCanvas.Width, Height = HomeCanvas.Height };
    readonly Dictionary<string, Point> _offsets = [];
    string? _suggestion, _picked, _toast, _hover, _modelId;
    IReadOnlyList<JsonNode> _models = [];
    (string id, Point start, Point origin)? _dragging;
    HomeScene? _scene;
    HomeLayout? _layout;
    // 每次重画都会新建的星图层，悬停 / 拖动只换这一层
    Canvas? _mapLayer;
    int _toastToken;
    TextBox? _composer;

    static IApiClient Api => App.Session.Api;

    public HomeImproveView(string account, Func<string> draft, Action<string> setDraft, Action<string, string?> send, Action<PracticeFocus?> practice,
        Action<string> editResume, Action<WorkspaceSection> navigate, Action importResume)
    {
        _account = account;
        _draft = draft;
        _setDraft = setDraft;
        _send = send;
        _practice = practice;
        _editResume = editResume;
        _navigate = navigate;
        _importResume = importResume;
        // 设计稿外的区域点一下 / 双击空白处复位拖动
        _canvas.Background = Brush(Alpha(V3.White, 0.004));
        _canvas.Clip = new RectangleGeometry { Rect = new Rect(0, 0, HomeCanvas.Width, HomeCanvas.Height) };
        _canvas.OnDoubleTap(() => { if (_offsets.Count > 0) { _offsets.Clear(); Render(); } });
        _canvas.PointerMoved += (_, e) => Drag(e);
        _canvas.PointerReleased += (_, _) => EndDrag();
        _canvas.PointerCaptureLost += (_, _) => EndDrag();
        Content = DesignCanvas.Fit(_canvas, HomeCanvas.Width, HomeCanvas.Height);
        KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Escape && _picked is not null) { _picked = null; e.Handled = true; Render(); } };
        Loaded += async (_, _) => await LoadAsync();
        Render();
    }

    async Task LoadAsync()
    {
        Render();
        await _model.LoadAsync(Api, _account);
        _scene = _model.State == HomeImproveModel.Phase.Ready && _model.Input is { } input ? HomeScenes.Pick(input) : null;
        _layout = _scene is { } scene ? HomeLayouts.Layout(scene) : null;
        Render();
        if (_scene is { } shown) _model.Disclose(Api, shown.Disclose);
        try
        {
            var list = await Api.CareerRequestAsync("/api/agent/models");
            _models = list.Items("models");
            _modelId ??= list.Text("defaultModelId").NonEmpty() ?? _models.FirstOrDefault()?.Text("id");
            Render();
        }
        catch { }
    }

    void Rescene()
    {
        _scene = _model.Input is { } input ? HomeScenes.Pick(input) : null;
        _layout = _scene is { } scene ? HomeLayouts.Layout(scene) : null;
        Render();
        if (_scene is { } shown) _model.Disclose(Api, shown.Disclose);
    }

    // MARK: 画布

    void Render()
    {
        var keepFocus = _composer?.FocusState is not null and not FocusState.Unfocused;
        var selection = _composer?.SelectionStart ?? 0;
        _canvas.Children.Clear();
        _canvas.Children.Add(HomeBackdrop.Make());
        var scene = _scene;
        var layout = _layout;
        if (scene is not null && layout is not null)
        {
            if (scene.MapTitle.Length > 0 || scene.MapNote.Length > 0)
            {
                var head = new StackPanel { Spacing = 6 };
                if (scene.MapTitle.Length > 0) { var t = Label(scene.MapTitle, 11, Hex(0x6B6963), Medium); t.CharacterSpacing = HomeStarMap.Spacing(1.5, 11); head.Children.Add(t); }
                if (scene.MapNote.Length > 0) { var n = Label(scene.MapNote, 11, Hex(0xA8A49A)); n.CharacterSpacing = HomeStarMap.Spacing(0.5, 11); head.Children.Add(n); }
                _canvas.Children.Add(head.At(580, 96));
            }
            _mapLayer = HomeStarMap.Make(scene, layout, _offsets, _picked, _hover);
            _canvas.Children.Add(_mapLayer);
            foreach (var target in NodeTargets(scene, layout)) _canvas.Children.Add(target);
            _canvas.Children.Add(HomeLegend.Make(scene.Legend));
        }
        _canvas.Children.Add(LeftPanel(scene).At(40, 30));
        if (scene is not null && layout is not null && _picked is { } picked && scene.Nodes.FirstOrDefault(n => n.Id == picked) is { } node && layout.At.TryGetValue(picked, out var at))
            _canvas.Children.Add(PickMenu(node, at));
        _canvas.Children.Add(HomeHorizon.Make());
        if (scene is not null) { var timeline = HomeTimeline.Make(scene.Marks, DateTimeOffset.Now); timeline.IsHitTestVisible = false; _canvas.Children.Add(timeline); }
        _canvas.Children.Add(Composer(scene).At(0, 708));
        if (_toast is { } toast) _canvas.Children.Add(Toast(toast));
        if (keepFocus && _composer is { } box)
        {
            box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectionStart = Math.Min(selection, box.Text.Length); };
        }
    }

    /// <summary>只换星图层（悬停、拖动中），不重建左栏与输入框，避免输入框失焦。</summary>
    void RenderMap()
    {
        if (_scene is null || _layout is null || _mapLayer is null) { Render(); return; }
        var index = _canvas.Children.IndexOf(_mapLayer);
        if (index < 0) { Render(); return; }
        _mapLayer = HomeStarMap.Make(_scene, _layout, _offsets, _picked, _hover);
        _canvas.Children[index] = _mapLayer;
        // 命中区跟随点的位置
        var positions = HomeStarMap.Positions(_layout, _offsets);
        foreach (var child in _canvas.Children.OfType<FrameworkElement>())
            if (child.Tag is string id && positions.TryGetValue(id, out var point))
            {
                Canvas.SetLeft(child, point.X - child.Width / 2);
                Canvas.SetTop(child, point.Y - child.Height / 2);
            }
    }

    void ShowToast(string text)
    {
        _toast = text;
        var token = ++_toastToken;
        Render();
        _ = Task.Delay(TimeSpan.FromSeconds(4)).ContinueWith(_ => DispatcherQueue.TryEnqueue(() =>
        {
            if (token != _toastToken) return;
            _toast = null;
            Render();
        }), TaskScheduler.Default);
    }

    FrameworkElement Toast(string text)
    {
        var row = HStack(12, Label(text, 12.5).Align(v: VerticalAlignment.Center),
            Label("知道了", 12.5, Link).Align(v: VerticalAlignment.Center).OnTap(() => { _toast = null; Render(); }, "知道了"));
        var card = new Border
        {
            Child = row, Padding = new Thickness(16, 10, 16, 10), Background = Brush(V3.White), CornerRadius = new CornerRadius(10),
            BorderBrush = Brush(Hex(0xE6E3DC)), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Center,
        }.Elevate(12);
        var host = new Grid { Width = HomeCanvas.Width };
        host.Children.Add(card);
        return host.At(0, HomeCanvas.HorizonTop - 70);
    }

    // MARK: 左栏

    FrameworkElement LeftPanel(HomeScene? scene)
    {
        if (_model.State == HomeImproveModel.Phase.Ready && scene is not null)
        {
            if (scene.Key == "start")
                return new HomeOnboarding(_model.Profile, value => { _model.UpdateProfile(value); Rescene(); }, ShowToast,
                    () => StartGuide([]), _importResume, _navigate, () => _practice(null));
            return ScenePanel.Make(scene, Run, item => { if (item.Focus is { } focus) _practice(focus); });
        }
        var failed = _model.State == HomeImproveModel.Phase.Failed;
        var stack = new StackPanel { Width = 400 };
        stack.Children.Add(Label(failed ? "暂时读不到" : "正在整理", 12, V3.Blue));
        stack.Children.Add(Serif(failed ? "首页信息暂时无法读取" : "正在读你的记忆……", 26).Top(6));
        stack.Children.Add(Label(failed ? "简历、面试和记忆暂时没有读出来，可以先直接提问。" : "简历、资料和练过的题会画到右边", 13, Hex(0x6B6963)).Top(8));
        if (failed) stack.Children.Add(HomeButtons.Outline("重新加载", () => _ = LoadAsync()).Top(26));
        return stack;
    }

    void Run(HomeAction action)
    {
        switch (action)
        {
            case HomeAction.Mock mock: _practice(mock.Focus); break;
            case HomeAction.Guide guide: StartGuide(guide.Ids); break;
            case HomeAction.Chat chat: _send(chat.Prompt, _modelId); break;
            case HomeAction.Suggest suggest: _suggestion = suggest.Text; Render(); break;
        }
    }

    /// <summary>首页“写第一份简历”：用默认模板新建（固定名字，重名加序号）并进编辑器引导，首页已有的资料预选到第一步。</summary>
    async void StartGuide(IReadOnlyList<string> datasetIds)
    {
        foreach (var title in new[] { "我的第一份简历", "我的第一份简历 2", "我的第一份简历 3" })
        {
            var body = new JsonObject { ["title"] = title, ["guide"] = true };
            if (datasetIds.Count > 0) body["guide_dataset_ids"] = new JsonArray(datasetIds.Take(10).Select(id => (JsonNode)id).ToArray());
            try
            {
                var result = await Api.CareerRequestAsync("/api/resumes", "POST", body: body);
                var id = (result.Get("resume") ?? result).Display("id");
                if (id.Length > 0) _editResume(id);
                return;
            }
            catch (ApiException error) when (error.Code == "RESUME_TITLE_CONFLICT") { continue; }
            catch (ApiException error)
            {
                ShowToast(error.Code == "RESUME_LIMIT_REACHED" ? "简历数量已到上限，删掉一份再新建。" : error.Code == "TEMPLATE_INACTIVE" ? "暂时没有可用的模板，稍后再试。" : "没能新建简历，请重试。");
                return;
            }
            catch { ShowToast("没能新建简历，请重试。"); return; }
        }
        ShowToast("没能新建简历，请重试。");
    }

    // MARK: 星图交互

    IEnumerable<FrameworkElement> NodeTargets(HomeScene scene, HomeLayout layout)
    {
        var positions = HomeStarMap.Positions(layout, _offsets);
        foreach (var node in scene.Nodes)
        {
            if (!positions.TryGetValue(node.Id, out var point)) continue;
            var size = node.Sym == HomeSym.Anchor ? 40.0 : 28;
            var actionable = node.Focus is not null || node.Ask is not null;
            var target = new Border
            {
                Width = size, Height = size, CornerRadius = new CornerRadius(size / 2), Background = Brush(Alpha(V3.White, 0.004)), Tag = node.Id,
            };
            Canvas.SetLeft(target, point.X - size / 2);
            Canvas.SetTop(target, point.Y - size / 2);
            target.PointerEntered += (_, _) => { _hover = node.Id; RenderMap(); };
            target.PointerExited += (_, _) => { if (_hover == node.Id && _dragging is null) { _hover = null; RenderMap(); } };
            target.PointerPressed += (_, e) =>
            {
                var at = e.GetCurrentPoint(_canvas).Position;
                _dragging = (node.Id, _offsets.TryGetValue(node.Id, out var current) ? current : default, at);
                _canvas.CapturePointer(e.Pointer);
                _moved = false;
                e.Handled = true;
            };
            target.PointerReleased += (_, e) =>
            {
                var wasDrag = _moved;
                EndDrag();
                _canvas.ReleasePointerCaptures();
                e.Handled = true;
                if (wasDrag || !actionable) return;
                _picked = _picked == node.Id ? null : node.Id;
                Render();
            };
            AutomationProperties.SetName(target, node.Label);
            yield return target;
        }
    }

    bool _moved;

    /// <summary>拖动一个点（移动 4 以上才算拖），子链跟着走、越往下越松（Mac `DragGesture` 的同一套系数）。</summary>
    void Drag(PointerRoutedEventArgs e)
    {
        if (_dragging is not { } drag || _scene is null) return;
        var now = e.GetCurrentPoint(_canvas).Position;
        double tx = now.X - drag.origin.X, ty = now.Y - drag.origin.Y;
        if (!_moved && Math.Sqrt(tx * tx + ty * ty) < 4) return;
        _moved = true;
        var delta = new Point(drag.start.X + tx, drag.start.Y + ty);
        var previous = _offsets.TryGetValue(drag.id, out var p) ? p : default;
        _offsets[drag.id] = delta;
        var depth = 0;
        foreach (var child in Descendants(drag.id, _scene))
        {
            var factor = Math.Pow(0.68, depth / 3 + 1);
            var old = _offsets.TryGetValue(child, out var o) ? o : default;
            _offsets[child] = new Point(old.X + (delta.X - previous.X) * factor, old.Y + (delta.Y - previous.Y) * factor);
            depth++;
        }
        RenderMap();
    }

    void EndDrag() => _dragging = null;

    static List<string> Descendants(string id, HomeScene scene)
    {
        var output = new List<string>();
        var queue = new Queue<string>([id]);
        while (queue.TryDequeue(out var current))
            foreach (var child in scene.Nodes)
                if (child.Parent == current) { output.Add(child.Id); queue.Enqueue(child.Id); }
        return output;
    }

    FrameworkElement PickMenu(HomeMapNode node, HomePlaced at)
    {
        var stack = new StackPanel { Spacing = 2 };
        if (node.Focus is { } focus)
            stack.Children.Add(HomeButtons.MenuRow(Label("带着它去练", 12.5), () => { _picked = null; _practice(focus); }, "带着它去练"));
        if (node.Ask is { } ask)
        {
            var row = Spread(Label("问问它", 12.5), Label("填进下方输入框", 10.5, Hex(0xA8A49A)), 8);
            stack.Children.Add(HomeButtons.MenuRow(row, () => { _suggestion = ask; _picked = null; Render(); }, "问问它"));
        }
        var menu = new Border
        {
            Child = stack, Padding = new Thickness(6), Width = 168, Background = Brush(V3.White), CornerRadius = new CornerRadius(10),
            BorderBrush = Brush(Hex(0xE6E3DC)), BorderThickness = new Thickness(1),
        }.Elevate(15);
        AutomationProperties.SetName(menu, $"{node.Label} 的操作");
        return menu.At(Math.Min(HomeCanvas.Width - 190, at.X + 16), Math.Min(HomeCanvas.Height - 210, at.Y + 14));
    }

    // MARK: 输入框

    string ShownSuggestion => _suggestion ?? _scene?.Suggestion ?? "";

    /// <summary>
    /// 对齐 Web `.hm-input-row`（顶 708、宽 458、间距 14）与 `.hm-hint`（顶 770、10px、#9b978c）：
    /// 输入为居中的 19px 衬线；输入为空时有建议也能直接发送，发出的是建议本身。
    /// </summary>
    FrameworkElement Composer(HomeScene? scene)
    {
        var placeholder = scene?.Key == "start" ? "没有简历？说说你做过什么，我来写第一版" : "有什么想问的？";
        var suggestion = ShownSuggestion;
        string Outgoing() { var typed = _draft().Trim(); return typed.Length == 0 ? suggestion : typed; }
        void Submit() { var text = Outgoing(); if (text.Length > 0) _send(text, _modelId); }

        var field = HomeComposerField.Make(_draft(), suggestion, placeholder, Submit, text => { _setDraft(text); });
        _composer = field.Box;
        var sendDot = new Border { Width = 32, Height = 32, CornerRadius = new CornerRadius(16), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Child = Icon("arrow.up", 13, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center) };
        var sendButton = new Grid { Width = 44, Height = 44 };
        sendButton.Children.Add(new Border { CornerRadius = new CornerRadius(22), Background = Brush(V3.White), BorderBrush = Brush(Hex(0xE6E3DC)), BorderThickness = new Thickness(1) }.Elevate(4));
        sendButton.Children.Add(sendDot);
        void Paint() => sendDot.Background = Brush(Outgoing().Length == 0 ? Hex(0xC5C1B6) : Hex(0x1D1D1B));
        Paint();
        field.Box.TextChanged += (_, _) => Paint();
        sendButton.OnTap(Submit, "发送", () => Outgoing().Length > 0);

        var input = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14, Width = 458, Height = 46, HorizontalAlignment = HorizontalAlignment.Center };
        input.Children.Add(field.Root.Frame(400, 42).Align(v: VerticalAlignment.Center));
        input.Children.Add(sendButton.Align(v: VerticalAlignment.Center));

        // 提示行的字间距 0.6pt
        TextBlock Hint(string text) { var block = Label(text, 10, Hex(0x9B978C)); block.CharacterSpacing = HomeStarMap.Spacing(0.6, 10); return block.Align(v: VerticalAlignment.Center); }
        var hint = new StackPanel { Orientation = Orientation.Horizontal, Height = 14, HorizontalAlignment = HorizontalAlignment.Center };
        var tabHint = Hint("Tab 填 入 建 议　·　");
        tabHint.Visibility = suggestion.Length > 0 && _draft().Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        field.Box.TextChanged += (_, _) => tabHint.Visibility = suggestion.Length > 0 && field.Box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        hint.Children.Add(tabHint);
        hint.Children.Add(Hint("回 车 发 送　·　⇧ 回 车 换 行　·　"));
        hint.Children.Add(new ModelPicker(_models, _modelId, id => { _modelId = id; Render(); }, inline: true).Align(v: VerticalAlignment.Center));
        hint.Children.Add(Hint("　·　"));
        hint.Children.Add(Hint("添加资料").OnTap(_importResume, "添加资料"));

        var root = new Grid { Width = HomeCanvas.Width, Height = 770 - 708 + 14 };
        root.Children.Add(input.Align(HorizontalAlignment.Center, VerticalAlignment.Top));
        root.Children.Add(hint.Align(HorizontalAlignment.Center, VerticalAlignment.Top).Top(770 - 708));
        return root;
    }
}

/// <summary>
/// 地平线下的输入框（Mac `HomeComposerField`）：19px 居中衬线，灰字建议按 Tab 填入，回车发送，Shift + 回车换行，输入法组字时回车不发送。
/// Web 用 Noto Serif SC，本机没有时回退到宋体，与 Web 的字体回退一致。
/// </summary>
public static class HomeComposerField
{
    public static readonly FontFamily Font = new("Noto Serif SC, Source Han Serif SC, SimSun");

    public sealed record Parts(Grid Root, TextBox Box);

    public static Parts Make(string text, string suggestion, string placeholder, Action submit, Action<string> changed)
    {
        var box = new TextBox
        {
            Text = text, FontFamily = Font, FontSize = 19, TextAlignment = TextAlignment.Center, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
            Foreground = Brush(Hex(0x1D1D1B)), Background = Brush(Clear), BorderThickness = new Thickness(0), Padding = new Thickness(0, 6, 0, 0),
            MinHeight = 0, IsSpellCheckEnabled = false,
        };
        // TextBox 的默认模板在悬停 / 聚焦时会换底色与下划线，这里统一改成透明
        foreach (var key in new[] { "TextControlBackgroundPointerOver", "TextControlBackgroundFocused", "TextControlBorderBrushFocused", "TextControlBorderBrushPointerOver" })
            box.Resources[key] = Brush(Clear);
        AutomationProperties.SetName(box, "告诉助手你想完成什么");
        AutomationProperties.SetHelpText(box, suggestion.Length == 0 ? placeholder : suggestion);
        var hint = new TextBlock
        {
            Text = suggestion.Length == 0 ? placeholder : suggestion, FontFamily = Font, FontSize = 19, Foreground = Brush(Hex(0xA29E93)),
            TextAlignment = TextAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, IsHitTestVisible = false,
            Margin = new Thickness(5, 6, 5, 0), VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Stretch,
            Visibility = text.Length == 0 ? Visibility.Visible : Visibility.Collapsed,
        };
        var composing = false;
        box.TextCompositionStarted += (_, _) => composing = true;
        box.TextCompositionEnded += (_, _) => composing = false;
        box.TextChanged += (_, _) => { changed(box.Text); hint.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; };
        box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Tab && box.Text.Length == 0 && suggestion.Length > 0)
            {
                e.Handled = true;
                box.Text = suggestion;
                box.SelectionStart = suggestion.Length;
                return;
            }
            if (e.Key != Windows.System.VirtualKey.Enter || composing) return;
            var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (shift) return;
            e.Handled = true;
            submit();
        };
        var root = new Grid();
        root.Children.Add(box);
        root.Children.Add(hint);
        return new Parts(root, box);
    }
}

/// <summary>首页按钮与行样式（Mac `HomeRowStyle` / `HomeMenuRow` / `HomeOutlineButton`）。</summary>
public static class HomeButtons
{
    /// <summary>`HomeRowStyle`：悬停或按下时 #F3F2EE、8 圆角。</summary>
    public static Border Row(UIElement content, Action action, string name, Action<bool>? hover = null)
    {
        var row = new Border { Child = content, CornerRadius = new CornerRadius(8), Background = Brush(Clear) };
        row.OnHover(on => { row.Background = Brush(on ? Hex(0xF3F2EE) : Clear); hover?.Invoke(on); });
        row.OnTap(action, name);
        return row;
    }

    /// <summary>`HomeMenuRow`：12.5px、左右 10、30 高、悬停 #F4F3EF、6 圆角。</summary>
    public static Border MenuRow(FrameworkElement content, Action action, string name)
    {
        var row = new Border { Child = content.Align(v: VerticalAlignment.Center), Height = 30, Padding = new Thickness(10, 0, 10, 0), CornerRadius = new CornerRadius(6), Background = Brush(Clear) };
        row.OnHover(on => row.Background = Brush(on ? Hex(0xF4F3EF) : Clear));
        row.OnTap(action, name);
        return row;
    }

    /// <summary>`HomeOutlineButton`：12.5/500、左右 14 上下 7、白底 8 圆角、55% 墨色描边，按下 0.7。</summary>
    public static Border Outline(string title, Action action)
    {
        var button = new Border
        {
            Child = Label(title, 12.5, Txt, Medium), Padding = new Thickness(14, 7, 14, 7), Background = Brush(V3.White),
            CornerRadius = new CornerRadius(8), BorderBrush = Brush(Alpha(Txt, 0.55)), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Left,
        };
        button.PointerPressed += (_, _) => button.Opacity = 0.7;
        button.PointerReleased += (_, _) => button.Opacity = 1;
        button.PointerExited += (_, _) => button.Opacity = 1;
        button.OnTap(action, title);
        return button;
    }

    /// <summary>`.buttonStyle(.plain)` 的文字链接。</summary>
    public static TextBlock Link(string title, double size, Color color, Action action, bool enabled = true)
    {
        var block = Label(title, size, color);
        block.OnTap(action, title, () => enabled);
        return block;
    }
}

/// <summary>左栏结论（Mac `ScenePanel`）：眉题、标题、说明、列表与行动行、次要入口；行高对齐 Web：眉题 16、标题 26px × 1.4、说明 20、列表标题 16。</summary>
public static class ScenePanel
{
    public static FrameworkElement Make(HomeScene scene, Action<HomeAction> run, Action<HomeListItem> item)
    {
        var actionRow = scene.Action is not null && !scene.List.Any(x => x.Focus is not null) ? scene.Action : null;
        var stack = new StackPanel { Width = 400 };
        if (scene.Eyebrow.Length > 0) stack.Children.Add(Label(scene.Eyebrow, 12, HomeColors.Tone(scene.EyebrowTone)).LineHeight(16).Pad(0, 0, 0, 4));
        stack.Children.Add(Serif(scene.Title, 26).LineHeight(36.4).Wrap().Top(6));
        stack.Children.Add(Label(scene.Sub, 13, Hex(0x6B6963)).LineHeight(20).Wrap().Top(8));
        if (scene.List.Count > 0 || actionRow is not null)
        {
            if (scene.List.Count > 0 && scene.ListTitle.Length > 0)
                stack.Children.Add(Label(scene.ListTitle, 12, Hex(0x6B6963)).LineHeight(16).Pad(0, 32, 0, 6));
            var list = new StackPanel { Spacing = 2, Width = 340 + 20, Margin = new Thickness(-10, scene.List.Count == 0 ? 26 : 0, -10, 0), HorizontalAlignment = HorizontalAlignment.Left };
            foreach (var row in scene.List) list.Children.Add(ListRow(row, () => item(row)));
            if (actionRow is not null && scene.List.Count > 0)
                list.Children.Add(new Border { Height = 1, Background = Brush(Hex(0xE6E3DE)), Margin = new Thickness(10, 6, 10, 6) });
            if (actionRow is not null)
            {
                var texts = new StackPanel { Spacing = 2 };
                texts.Children.Add(Label(actionRow.Label, 14, Txt, Medium));
                if (actionRow.Hint is { } hint) texts.Children.Add(Label(hint, 12, Hex(0x6B6963)));
                var verb = HStack(4, Label(actionRow.Verb ?? "去练", 12.5, Txt, Medium).Align(v: VerticalAlignment.Center), Label("›", 17, Txt).Align(v: VerticalAlignment.Center));
                var grid = Columns(10, (Px(24), new Border { Height = 22 }), (Star(), texts.Align(v: VerticalAlignment.Center)), (GridLength.Auto, verb.Align(v: VerticalAlignment.Center)));
                grid.Padding = new Thickness(10, 9, 12, 9);
                list.Children.Add(HomeButtons.Row(grid, () => run(actionRow.Run), actionRow.Label));
            }
            stack.Children.Add(list);
        }
        if (scene.Secondary is { } secondary)
            stack.Children.Add(HomeButtons.Link(secondary.Label, 12.5, Hex(0x6B6963), () => run(secondary.Run)).Top(14));
        return stack;
    }

    static FrameworkElement ListRow(HomeListItem item, Action open)
    {
        FrameworkElement icon = item.Badge is { } badge
            ? new Border { Width = 18, Height = 18, CornerRadius = new CornerRadius(9), Background = Brush(HomeColors.Orange),
                Child = Label($"{badge}", 11, V3.White, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }
            : HomeSymbols.Glyph(item.Sym, 24, 22, item.Level ?? 2, item.Sym == HomeSym.Planet ? 0.65 : 1);
        var texts = new StackPanel { Spacing = 2 };
        texts.Children.Add(Label(item.Title, 14, Txt, Medium).Frame(height: 19));
        texts.Children.Add(Label(item.Sub, 12, Hex(0x6B6963)).Frame(height: 16));
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        if (item.Right is { } right) trailing.Children.Add(Label(right, 12, HomeColors.Orange).Align(v: VerticalAlignment.Center));
        TextBlock? verb = null, chevron = null;
        if (item.Focus is not null)
        {
            verb = Label("去练", 12.5, Txt, Medium).Align(v: VerticalAlignment.Center);
            verb.Visibility = Visibility.Collapsed;
            chevron = Label("›", 17, Hex(0xA8A49A)).Align(v: VerticalAlignment.Center);
            trailing.Children.Add(HStack(4, verb, chevron));
        }
        var grid = Columns(10, (Px(24), new Grid { Height = 22, Children = { icon } }), (Star(), texts.Align(v: VerticalAlignment.Center)), (GridLength.Auto, trailing));
        grid.Padding = new Thickness(10, 9, 12, 9);
        if (item.Focus is null) return grid;
        return HomeButtons.Row(grid, open, $"{item.Title}，去练", on =>
        {
            verb!.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
            chevron!.Foreground = Brush(on ? Txt : Hex(0xA8A49A));
        });
    }
}

/// <summary>① 起步的三步引导（Mac `HomeOnboarding`，Web `homeImprove/Onboarding.tsx`）。</summary>
public sealed class HomeOnboarding : UserControl
{
    static readonly (string name, string? direction)[] Roles =
    [
        ("新媒体运营", "operations"), ("产品经理", "product"), ("管培生", null), ("销售", "marketing"),
        ("财务 / 审计", "finance"), ("人力资源", "hr"), ("教师", "teacher"), ("软件开发", "rd"),
    ];

    JsonNode? _profile;
    readonly Action<JsonNode> _onProfile;
    readonly Action<string> _toast;
    readonly Action _guide, _importResume, _practice;
    readonly Action<WorkspaceSection> _navigate;
    string _role;
    bool _busy;
    readonly StackPanel _root = new() { Width = 400 };
    TextBox? _field;

    string Saved => _profile.Text("target_role");

    public HomeOnboarding(JsonNode? profile, Action<JsonNode> onProfile, Action<string> toast, Action guide, Action importResume, Action<WorkspaceSection> navigate, Action practice)
    {
        _profile = profile;
        _onProfile = onProfile;
        _toast = toast;
        _guide = guide;
        _importResume = importResume;
        _navigate = navigate;
        _practice = practice;
        _role = Saved;
        Content = _root;
        Render();
    }

    void Render()
    {
        var focused = _field?.FocusState is not null and not FocusState.Unfocused;
        _root.Children.Clear();
        _root.Children.Add(Label("欢迎来到职绘", 12, V3.Blue));
        _root.Children.Add(Serif("先让我认识你", 26).Top(6));
        _root.Children.Add(Label("首页会画出你会什么、哪里要补。三步就能开始，随时可以跳过。", 13, Hex(0x6B6963)).Top(8));
        var steps = new StackPanel { Margin = new Thickness(0, 34, 0, 0) };
        steps.Children.Add(Step(1, Saved.Length == 0 ? "now" : "done", "你想找什么工作", RoleStep()));
        steps.Children.Add(Step(2, Saved.Length == 0 ? "later" : "now", "有材料就交给我，写出第一份简历", MaterialStep()));
        var practice = new StackPanel();
        practice.Children.Add(Label("有了第一份简历就能练；答完右边会亮起第一批点，告诉你哪里要补", 11.5, Hex(0xA8A49A)).Wrap().Top(10));
        practice.Children.Add(HomeButtons.Link("先看看模拟面试 →", 11.5, V3.Blue, _practice).Top(6));
        steps.Children.Add(Step(3, "later", "练一场模拟面试", practice));
        _root.Children.Add(steps);
        if (focused && _field is { } field) field.Loaded += (_, _) => { field.Focus(FocusState.Programmatic); field.SelectionStart = field.Text.Length; };
    }

    UIElement RoleStep()
    {
        var stack = new StackPanel();
        var box = new TextBox
        {
            Text = _role, PlaceholderText = "比如 新媒体运营、管培生、Java 后端", FontSize = 13, MaxLength = 64, IsEnabled = !_busy,
            BorderThickness = new Thickness(0), Background = Brush(Clear), Padding = new Thickness(0, 8, 0, 0), MinHeight = 0, VerticalAlignment = VerticalAlignment.Center,
        };
        foreach (var key in new[] { "TextControlBackgroundPointerOver", "TextControlBackgroundFocused", "TextControlBorderBrushFocused", "TextControlBorderBrushPointerOver" })
            box.Resources[key] = Brush(Clear);
        AutomationProperties.SetName(box, "想找的岗位");
        _field = box;
        var status = Label(Status(), 11, Hex(0xA8A49A)).Align(v: VerticalAlignment.Center);
        box.TextChanged += (_, _) => { _role = box.Text; status.Text = Status(); };
        box.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Save(_role, null); } };
        box.LostFocus += (_, _) => { if (_role.Trim() != Saved) Save(_role, null); };
        var row = Columns(10, (Star(), box), (GridLength.Auto, status));
        stack.Children.Add(new Border
        {
            Child = row, Height = 36, Padding = new Thickness(14, 0, 14, 0), Background = Brush(V3.White), CornerRadius = new CornerRadius(8),
            BorderBrush = Brush(Alpha(V3.Blue, 0.55)), BorderThickness = new Thickness(0.8), Margin = new Thickness(0, 12, 0, 0),
        });
        var chips = new VariableSizedFlow(8);
        chips.Add(Label("常见岗位", 11.5, Hex(0xA8A49A)).Frame(height: 26).Align(v: VerticalAlignment.Center));
        foreach (var (name, direction) in Roles)
        {
            var on = _role.Trim() == name;
            var chip = new Border
            {
                Child = Label(name, 12, on ? V3.White : Sub).Align(v: VerticalAlignment.Center), Height = 26, Padding = new Thickness(10, 0, 10, 0),
                CornerRadius = new CornerRadius(13), Background = Brush(on ? Txt : V3.White), BorderBrush = Brush(on ? Clear : Hex(0xE4E1DA)), BorderThickness = new Thickness(1),
            };
            chip.OnTap(() => { _role = name; Save(name, direction); Render(); }, name, () => !_busy);
            if (on) AutomationProperties.SetItemStatus(chip, "已选择");
            chips.Add(chip);
        }
        stack.Children.Add(chips.Panel.Top(12));
        return stack;
    }

    string Status()
    {
        var value = _role.Trim();
        return value.Length == 0 ? "什么专业、岗位都可以" : value == Saved ? "已保存" : "回车保存";
    }

    UIElement MaterialStep()
    {
        var stack = new StackPanel();
        var texts = new StackPanel { Spacing = 2 };
        texts.Children.Add(Label("把旧简历拖到这里", 13, Txt, Medium));
        texts.Children.Add(Label("PDF、Word 都行，直接转成可编辑的简历", 11.5, Hex(0x6B6963)));
        var row = Columns(12, (Px(40), HomeSymbols.Glyph(HomeSym.Planet, 40, 40, 3)), (Star(), texts.Align(v: VerticalAlignment.Center)),
            (GridLength.Auto, HomeButtons.Outline("选择文件", _importResume).Align(v: VerticalAlignment.Center)));
        // 虚线框（`StrokeStyle(lineWidth: 1, dash: [4, 3])`）：WinUI 的 Border 不支持虚线，用 Rectangle 叠在下面
        var frame = new Grid { Margin = new Thickness(0, 12, 0, 0), AllowDrop = true };
        frame.Children.Add(new Microsoft.UI.Xaml.Shapes.Rectangle
        {
            RadiusX = 10, RadiusY = 10, Fill = Brush(Alpha(V3.White, 0.7)), Stroke = Brush(Hex(0xCCC9C2)), StrokeThickness = 1,
            StrokeDashArray = [4, 3],
        });
        frame.Children.Add(new Border { Child = row, Padding = new Thickness(16, 18, 16, 18) });
        frame.DragOver += (_, e) => { if (e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy; };
        frame.Drop += (_, _) => _importResume();
        stack.Children.Add(frame);
        var guide = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
        guide.Children.Add(Label("没有简历？", 11.5, Hex(0x6B6963)));
        guide.Children.Add(HomeButtons.Link("跟着引导写第一份 →", 11.5, V3.Blue, _guide, !_busy));
        stack.Children.Add(guide);
        var more = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        more.Children.Add(Label("也可以把课程报告、作品集", 11.5, Hex(0xA8A49A)));
        more.Children.Add(HomeButtons.Link("放进资料库", 11.5, V3.Blue, () => _navigate(WorkspaceSection.Datasets)));
        more.Children.Add(Label("，或", 11.5, Hex(0xA8A49A)));
        more.Children.Add(HomeButtons.Link("从模板开始", 11.5, V3.Blue, () => _navigate(WorkspaceSection.Templates)));
        stack.Children.Add(more);
        return stack;
    }

    static UIElement Step(int n, string state, string title, UIElement content)
    {
        var dot = new Grid { Width = 18, Height = 18, VerticalAlignment = VerticalAlignment.Top };
        dot.Children.Add(new Border { CornerRadius = new CornerRadius(9), Background = Brush(V3.White), BorderBrush = Brush(state == "now" ? V3.Blue : Hex(0xCCC9C2)), BorderThickness = new Thickness(1) });
        dot.Children.Add(Label(state == "done" ? "✓" : $"{n}", 11, state == "now" ? V3.Blue : Hex(0xA8A49A), Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center));
        var body = new StackPanel();
        body.Children.Add(Label(title, 14, state == "later" ? Hex(0x6B6963) : Txt, Semibold));
        body.Children.Add(content);
        var row = Columns(14, (Px(18), dot), (Star(), body));
        row.Margin = new Thickness(0, 0, 0, 26);
        return row;
    }

    /// <summary>存岗位：带方向时放到第一位（最多三个）；并发改过画像（409）或网络失败时重新读一次再存。</summary>
    async void Save(string next, string? direction)
    {
        var value = next.Trim();
        if (_profile is null || _busy || value.Length == 0) return;
        _busy = true;
        Render();
        try
        {
            try { Apply(await PutAsync(_profile, value, direction)); }
            catch
            {
                try
                {
                    var latest = await App.Session.Api.CareerRequestAsync("/api/account/user-profile");
                    Apply(await PutAsync(latest, value, direction));
                }
                catch { _toast("没有保存成功，请稍后再试"); }
            }
        }
        finally { _busy = false; Render(); }
    }

    void Apply(JsonNode value)
    {
        _profile = value;
        _onProfile(value);
    }

    static Task<JsonNode> PutAsync(JsonNode profile, string role, string? direction)
    {
        if (profile.DeepClone() is not JsonObject body) throw new InvalidDataException();
        var held = profile.Items("job_directions").Select(x => x.String()).OfType<string>().ToList();
        foreach (var key in new[] { "lock_version", "created_at", "updated_at", "job_directions" }) body.Remove(key);
        body["base_lock_version"] = profile.Get("lock_version")?.DeepClone() ?? 0;
        body["target_role"] = role;
        if (direction is not null)
            body["job_directions"] = new JsonArray(new[] { direction }.Concat(held.Where(x => x != direction)).Take(3).Select(x => (JsonNode)x).ToArray());
        return App.Session.Api.CareerRequestAsync("/api/account/user-profile", "PUT", body: body);
    }
}

/// <summary>把登录后的首页注册给外壳（首页文件只在 Core 首页规则存在时参与编译）。</summary>
static class HomeRegistration
{
    [System.Runtime.CompilerServices.ModuleInitializer]
    internal static void Register() => Shell.WorkspaceShell.SignedInHome = (account, draft, setDraft) => new HomeImproveView(account, draft, setDraft,
        (text, model) => Shell.WorkspaceShell.Current.StartChat(text, model),
        focus => Shell.WorkspaceShell.Current.Practice(focus),
        id => Shell.WorkspaceShell.Current.EditResume(id),
        section => Shell.WorkspaceShell.Current.Select(section),
        () => Shell.WorkspaceShell.Current.RequestImport());
}
