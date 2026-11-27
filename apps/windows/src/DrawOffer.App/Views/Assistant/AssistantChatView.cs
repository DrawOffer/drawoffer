using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Agent;
using DrawOffer.Core.Api;
using DrawOffer.Core.Home;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Assistant;

/// <summary>待发送的对话附件（Mac `ChatScreenshot`，Web `AttachmentDraft`）：选好后立即上传到当前对话，发送时带上 `attachment_ids`。</summary>
public sealed class ChatAttachment
{
    public enum States { Pending, Uploading, Ready, Failed }
    public required string Id { get; init; }
    public required string Label { get; init; }
    public required string File { get; init; }
    public byte[]? Data { get; init; }
    public States Status { get; set; } = States.Pending;
    public string? AttachmentId { get; set; }
    public string? Error { get; set; }
    public string Kind => AgentAttachments.Kind(Label);
    public long Size => new FileInfo(File).Exists ? new FileInfo(File).Length : 0;
    public ChatPreviewTab Tab => new(ChatPreviewTab.Kinds.Image, Id, Label) { ImageData = Data };
}

/// <summary>
/// AI 对话（Windows 稿 02B 页，逻辑对齐 Mac `AssistantChatView.swift`）：
/// 新建对话（一行问句 + 快捷输入）、对话中（流式回复、准备过程、对话卡片、修改建议、追问、编辑最后一条）、右侧文件预览。
/// 状态集中在字段里，任何变化后调用 <see cref="Render"/> 整页重建；输入框焦点与光标在重建时保留。
/// </summary>
public sealed partial class AssistantChatView : UserControl
{
    /// <summary>浮在输入框上方的弹层：同一时间只开一个。</summary>
    enum Floating { Usage, Materials, Mention }

    readonly string? _sessionId, _initialMessage, _initialModelId, _initialDraft;

    string? _currentId;
    string _title = "新对话";
    List<JsonNode> _messages = [];
    List<JsonNode> _proposals = [];
    string _draft = "";
    string _streaming = "";
    string? _status, _runId, _error, _modelName, _modelId, _proposalBusy, _notice;
    bool _sending, _steering, _consumedInitial, _previewOpen, _slashDismissed, _mentionDismissed, _previewFullscreen, _processExpanded;
    bool? _ready;
    List<JsonNode> _models = [];
    int? _copiedMessage;
    List<JsonNode> _contexts = [];
    List<JsonNode> _contextGroups = [];
    readonly Dictionary<string, string> _answers = [];
    readonly Dictionary<string, string> _otherAnswers = [];
    List<ChatPreviewTab> _previewTabs = [];
    string? _previewActive;
    double _previewWidth = 520;
    readonly HashSet<string> _unavailableFiles = [];
    readonly HashSet<string> _savedDocuments = [];
    List<ChatAttachment> _attachments = [];
    JsonNode? _contextUsage;
    int _clarificationPage;
    /// <summary>额度拦截（Web `CreditNotice`）：额度用完，或当前模型不可用于当前额度；保留原消息以便重发。</summary>
    (string kind, string content)? _creditBlock;
    /// <summary>每轮回复的准备过程，按 runId 保留（回复完成后折成回答上方一行）；`_live` 是当前这一轮正在显示的步骤。</summary>
    readonly Dictionary<string, ProcessSnapshot> _processes = [];
    ProcessSnapshot _live = new();
    readonly HashSet<string> _openFolds = [];
    DateTimeOffset _phaseStarted = DateTimeOffset.Now;
    /// <summary>编辑最后一条消息（02B·08 E）：正在编辑的消息位置与草稿。</summary>
    int? _editingIndex;
    string _editDraft = "";
    /// <summary>新建对话的标语与快捷输入（02B·02），按首页同一套场景规则挑选。</summary>
    string? _greetingTitle;
    List<AssistantGreeting.Prompt> _greetingPrompts = [];
    CancellationTokenSource? _streamCancel;

    Floating? _floating;
    Flyout? _floatingFlyout;
    AssistantContextPanel? _floatingPanel;
    bool _rebuilding;

    readonly Grid _root = new() { Background = Brush(White) };
    ScrollViewer? _scroller;
    TextBox? _input;
    Border? _inputBox;
    bool _stickToBottom = true;

    static IApiClient Api => App.Session.Api;

    /// <param name="initialMessage">首页带过来的第一条消息（直接发送）。</param>
    /// <param name="initialDraft">只填进输入框、不替用户发（站内“带一句话去对话”）。</param>
    public AssistantChatView(string? sessionId, string? initialMessage, string? initialModelId, string? initialDraft)
    {
        _sessionId = sessionId;
        _initialMessage = initialMessage;
        _initialModelId = initialModelId;
        _initialDraft = initialDraft;
        Content = _root;
        AllowDrop = true;
        DragOver += (_, e) => { if (e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy; };
        Drop += async (_, e) =>
        {
            if (!e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
            var items = await e.DataView.GetStorageItemsAsync();
            AddFiles(items.OfType<Windows.Storage.StorageFile>().Select(f => f.Path).ToList());
        };
        Loaded += async (_, _) => await OpenAsync();
        Unloaded += (_, _) => { _streamCancel?.Cancel(); _floatingFlyout?.Hide(); };
        Render();
    }

    JsonNode? PendingClarification
    {
        get
        {
            if (_sending || _messages.LastOrDefault() is not { } last || last.Text("role") != "assistant") return null;
            return last["clarification"] is JsonObject clarification && clarification.Items("questions").Count > 0 ? last : null;
        }
    }

    bool Sending
    {
        get => _sending;
        set
        {
            if (_sending == value) return;
            _sending = value;
            if (value) CloseFloating();
            if (_currentId is { } id) Shell.WorkspaceShell.Current.SetRunning(id, value);
        }
    }

    bool IsBlank => _currentId is null && _messages.Count == 0 && !_sending;
    bool PreviewShown => _previewOpen && _previewTabs.Count > 0;
    /// <summary>正文列宽（02B·06）：720，右侧打开预览时收到 560。</summary>
    double ColumnWidth => PreviewShown ? 560 : 720;
    string? ActivePreviewKey => _previewOpen ? _previewActive : null;
    int? LastUserIndex => _messages.FindLastIndex(m => m.Text("role") == "user") is var i and >= 0 ? i : null;

    // MARK: 布局

    void Render()
    {
        var focused = _input?.FocusState is not null and not FocusState.Unfocused;
        var selection = _input?.SelectionStart ?? _draft.Length;
        var offset = _scroller?.VerticalOffset ?? 0;
        var floating = _floating;
        if (_floatingFlyout is { } open) { _rebuilding = true; open.Hide(); open.Content = null; _rebuilding = false; _floatingFlyout = null; }
        _root.Children.Clear();
        _root.ColumnDefinitions.Clear();
        var showChat = !(_previewFullscreen && PreviewShown);
        if (showChat) _root.ColumnDefinitions.Add(new ColumnDefinition { Width = Star(), MinWidth = 420 });
        if (PreviewShown)
        {
            _root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
            _root.ColumnDefinitions.Add(new ColumnDefinition { Width = _previewFullscreen ? Star() : new GridLength(_previewWidth) });
        }
        if (showChat)
        {
            var chat = new Grid();
            chat.Children.Add(IsBlank ? NewChat() : Conversation());
            if (FilesToggle() is { } toggle) chat.Children.Add(toggle);
            _root.Children.Add(chat);
        }
        if (PreviewShown)
        {
            if (showChat)
            {
                var handle = ResizeHandle();
                Grid.SetColumn(handle, 1);
                _root.Children.Add(handle);
            }
            else _root.ColumnDefinitions.Clear();
            var panel = new ChatPreviewPanel(new ChatPreviewPanel.Options(
                _previewTabs.Select(t => t.Kind == ChatPreviewTab.Kinds.Generated ? t with { Saved = _savedDocuments.Contains(t.Content) } : t).ToList(),
                _previewActive, _unavailableFiles,
                key => { _previewActive = key; Render(); }, ClosePreview, () => { _previewOpen = false; Render(); },
                tab => ShowSaveDocument(tab.Content), key => { _unavailableFiles.Add(key); Render(); },
                _previewFullscreen, value => { _previewFullscreen = value; Render(); }));
            if (showChat) Grid.SetColumn(panel, 2);
            _root.Children.Add(panel);
        }
        if (focused && _input is { } input)
            input.Loaded += (_, _) => { input.Focus(FocusState.Programmatic); input.SelectionStart = Math.Min(selection, input.Text.Length); };
        if (_scroller is { } scroller)
            scroller.Loaded += (_, _) => scroller.ChangeView(null, _stickToBottom ? scroller.ScrollableHeight : offset, null, true);
        // 弹层跟着重建后的输入框重新打开（选资料时加减引用会重建输入框上方的标签）
        if (floating is { } kind && _inputBox is { } box) box.Loaded += (_, _) => ShowFloating(kind);
    }

    /// <summary>预览面板左边缘（02B·06 面板规则）：默认 520，可拖拽 400–720。</summary>
    FrameworkElement ResizeHandle()
    {
        var grid = new Grid { Width = 1, Background = Brush(Line) };
        var hit = new Border { Width = 8, Margin = new Thickness(-4, 0, -4, 0), Background = Brush(Clear), Opacity = _previewFullscreen ? 0 : 1 };
        hit.PointerEntered += (_, _) => ProtectedCursor = Microsoft.UI.Input.InputSystemCursor.Create(Microsoft.UI.Input.InputSystemCursorShape.SizeWestEast);
        hit.PointerExited += (_, _) => ProtectedCursor = null;
        double? start = null, baseWidth = null;
        hit.PointerPressed += (_, e) => { start = e.GetCurrentPoint(_root).Position.X; baseWidth = _previewWidth; hit.CapturePointer(e.Pointer); e.Handled = true; };
        hit.PointerMoved += (_, e) =>
        {
            if (start is not { } s || baseWidth is not { } w) return;
            _previewWidth = Math.Min(720, Math.Max(400, w - (e.GetCurrentPoint(_root).Position.X - s)));
            if (_root.ColumnDefinitions.Count == 3) _root.ColumnDefinitions[2].Width = new GridLength(_previewWidth);
        };
        hit.PointerReleased += (_, e) => { start = null; hit.ReleasePointerCapture(e.Pointer); Render(); };
        grid.Children.Add(hit);
        return grid;
    }

    // MARK: 02B·02 新建对话

    FrameworkElement NewChat()
    {
        var column = new StackPanel { MaxWidth = 720, Padding = new Thickness(24, 32, 24, 32), VerticalAlignment = VerticalAlignment.Center };
        column.Children.Add(AssistantGreeting.TitleRow(_greetingTitle).Pad(0, 0, 0, 58));
        column.Children.Add(Composer());
        column.Children.Add(new Border
        {
            Height = 156, Margin = new Thickness(0, 21, 0, 0), VerticalAlignment = VerticalAlignment.Top,
            Child = AssistantGreeting.PromptList(_greetingPrompts, text => { _draft = text; Render(); _input?.Focus(FocusState.Programmatic); }),
        });
        return new ScrollViewer { Content = column, HorizontalScrollMode = ScrollMode.Disabled, MinWidth = 420 };
    }

    async Task LoadGreetingAsync()
    {
        HomeScene? scene = null;
        try { scene = await AssistantGreeting.LoadSceneAsync(); } catch { }
        if (scene is not null)
        {
            _greetingTitle = AssistantGreeting.Title(scene);
            _greetingPrompts = AssistantGreeting.Prompts(scene);
        }
        else _greetingTitle = "有什么想问的？";
        if (IsBlank) Render();
    }

    // MARK: 02B·03 对话中

    FrameworkElement Conversation()
    {
        var list = new StackPanel { Spacing = 28, MaxWidth = ColumnWidth, Padding = new Thickness(24, 48, 24, 24) };
        var anchored = AnchoredGroups();
        for (var index = 0; index < _messages.Count; index++)
        {
            var message = _messages[index];
            if (message.Text("message_type") == "compaction") list.Children.Add(CompactionDivider(message));
            else if (message.Text("message_type") != "clarification" || message.Text("content").Length > 0) list.Children.Add(Row(message, index));
            if (anchored.TryGetValue(index, out var groups)) foreach (var group in groups) list.Children.Add(SuggestionList(group.items));
        }
        var anchoredKeys = anchored.Values.SelectMany(g => g.Select(x => x.key)).ToHashSet();
        foreach (var group in ProposalGroups().Where(g => !anchoredKeys.Contains(g.key))) list.Children.Add(SuggestionList(group.items));
        if (Sending) list.Children.Add(Thinking());
        if (PendingClarification is { } clarification) list.Children.Add(ClarificationCard(clarification));
        if (_creditBlock is { } block && !Sending) list.Children.Add(CreditNotice(block));
        if (_currentId is { } current && !Sending) list.Children.Add(new MemoryReceipt(current, _messages.Count));
        if (_error is { } error) list.Children.Add(Sans(error, 12.5, Red).Wrap());

        _scroller = new ScrollViewer { Content = list, HorizontalScrollMode = ScrollMode.Disabled };
        _scroller.ViewChanged += (s, _) => { var v = (ScrollViewer)s!; _stickToBottom = v.VerticalOffset >= v.ScrollableHeight - 24; };
        var grid = new Grid { MinWidth = 420 };
        grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Children.Add(_scroller);
        var composer = Composer();
        composer.MaxWidth = ColumnWidth;
        composer.Margin = new Thickness(24, 8, 24, 27);
        Grid.SetRow(composer, 1);
        grid.Children.Add(composer);
        return grid;
    }

    /// <summary>等待回复（02B·03 / 04）：正文还没开始时是山茶花 + 当前一步 + 工具卡；正文开始后过程折成一行放在正文上方。</summary>
    FrameworkElement Thinking()
    {
        if (_streaming.Length == 0)
            return new AssistantThinking(_status ?? "AI 正在处理…", _phaseStarted, _live.Steps, _processExpanded, value => { _processExpanded = value; Render(); },
                _status == "正在压缩上下文…");
        var stack = new StackPanel { Spacing = 12 };
        if (_runId is { } run && _processes.TryGetValue(run, out var snapshot) && Fold(run, snapshot) is { } fold) stack.Children.Add(fold);
        stack.Children.Add(NativeMarkdownView.Render(_streaming, 13.5, 24));
        return stack;
    }

    FrameworkElement? Fold(string run, ProcessSnapshot snapshot) =>
        ProcessViews.Fold(snapshot, _openFolds.Contains(run), () => { if (!_openFolds.Remove(run)) _openFolds.Add(run); Render(); });

    // MARK: 预览

    /// <summary>本次对话涉及的全部文件：消息附加的简历与资料、AI 生成的文档、图片附件。</summary>
    List<ChatPreviewTab> SessionFiles()
    {
        var tabs = new List<ChatPreviewTab>();
        for (var index = 0; index < _messages.Count; index++)
        {
            var message = _messages[index];
            foreach (var context in message.Items("contexts")) if (ChatPreviewTab.ForContext(context) is { } tab) tabs = ChatPreviewTab.Open(tabs, tab);
            if (message.Text("role") == "assistant" && GeneratedTab(message, index) is { } generated) tabs = ChatPreviewTab.Open(tabs, generated);
        }
        foreach (var shot in _attachments.Where(a => a.Kind == "image")) tabs = ChatPreviewTab.Open(tabs, shot.Tab);
        return tabs;
    }

    static ChatPreviewTab? GeneratedTab(JsonNode message, int index)
    {
        if (DocumentTitle(message.Text("content")) is not { } title) return null;
        var id = message.Number("sequence_no") is { } number ? ((int)number).ToString() : $"m{index}";
        return new ChatPreviewTab(ChatPreviewTab.Kinds.Generated, id, title + ".md") { Content = message.Text("content") };
    }

    void OpenPreview(ChatPreviewTab tab)
    {
        if (_unavailableFiles.Contains(tab.Key)) return;
        if (tab.Kind == ChatPreviewTab.Kinds.Resume)
            tab = tab with
            {
                Pending = _proposals.Where(p => p.Text("status") == "pending" && p.Text("resume_id") == tab.Id)
                    .SelectMany(p => p["preview"].Items("changes").Select(c => c.Text("before"))).Where(x => x.Length > 0).ToList(),
            };
        _previewTabs = ChatPreviewTab.Open(_previewTabs, tab);
        _previewActive = tab.Key;
        _previewOpen = true;
        Render();
    }

    void OpenAllFiles()
    {
        var tabs = _previewTabs;
        foreach (var tab in SessionFiles()) tabs = ChatPreviewTab.Open(tabs, tab);
        _previewTabs = tabs;
        _previewActive ??= tabs.FirstOrDefault()?.Key;
        _previewOpen = tabs.Count > 0;
        Render();
    }

    void ClosePreview(string key)
    {
        _previewTabs.RemoveAll(t => t.Key == key);
        if (_previewActive == key) _previewActive = _previewTabs.LastOrDefault()?.Key;
        if (_previewTabs.Count == 0) _previewOpen = false;
        Render();
    }

    /// <summary>右上角「N 个文件」（02B·06）：白底细边圆角 7.5、28 高，预览面板打开时隐藏。</summary>
    FrameworkElement? FilesToggle()
    {
        var files = SessionFiles().Count;
        if (files == 0 || _previewOpen || IsBlank) return null;
        var button = new Border
        {
            Child = HStack(8, Icon("sidebar.right", 10.5, Sub).Align(v: VerticalAlignment.Center), Label($"{files} 个文件", 12, Sub, Medium).Align(v: VerticalAlignment.Center)),
            Padding = new Thickness(10, 0, 10, 0), Height = 28, Background = Brush(White), CornerRadius = new CornerRadius(7.5),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(16),
        };
        return button.OnTap(OpenAllFiles, $"查看本会话的 {files} 个文件");
    }

    // MARK: 消息

    FrameworkElement Row(JsonNode message, int index)
    {
        var user = message.Text("role") == "user";
        var content = user ? UserMessage(message, index) : AssistantMessage(message, index);
        content.MaxWidth = user ? (_editingIndex == index ? ColumnWidth : Math.Min(560, ColumnWidth * 0.82)) : double.PositiveInfinity;
        content.HorizontalAlignment = user ? HorizontalAlignment.Right : HorizontalAlignment.Stretch;
        return content;
    }

    FrameworkElement UserMessage(JsonNode message, int index)
    {
        var text = message.Text("content");
        var attached = message.Items("contexts").Where(c => c.Text("label").Length > 0).ToList();
        // 正文里没 @ 到的简历引用排在气泡上方（24 高小标签、靠右），其余引用作为正文内的蓝色字
        var resumes = attached.Where(c => c.Text("type") is "resume" or "resume_version" && !text.Contains("@" + c.Text("label"))).ToList();
        var inline = attached.Where(c => !resumes.Contains(c)).ToList();
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right };
        if (resumes.Count > 0)
        {
            var flow = new VariableSizedFlow(6, trailing: true);
            foreach (var context in resumes) flow.Add(ResumeTag(context));
            stack.Children.Add(flow.Panel.Pad(0, 0, 0, 8));
        }
        var files = message.Items("attachments");
        if (files.Count > 0) stack.Children.Add(MessageAttachments(files, true));
        if (_editingIndex == index) { stack.Children.Add(EditBox(message, index)); return stack; }
        // 气泡（02B·03）：#F4F4F2、圆角 12、内边距 14/11，13 号字
        var body = UserSegments(text, inline, ActivePreviewKey, context => { if (ChatPreviewTab.ForContext(context) is { } tab && !_unavailableFiles.Contains(tab.Key)) OpenPreview(tab); });
        var bubble = new Border { Child = body, Padding = new Thickness(14, 11, 14, 11), Background = Brush(Field), CornerRadius = new CornerRadius(12), HorizontalAlignment = HorizontalAlignment.Right };
        var host = new Grid { HorizontalAlignment = HorizontalAlignment.Right, Background = Brush(Clear) };
        host.Children.Add(bubble);
        if (text.Length > 0) Hovered(host, MessageActions(message, index, CanEdit(index)), HorizontalAlignment.Right, 6);
        stack.Children.Add(host);
        return stack;
    }

    /// <summary>简历引用小标签（02B·06）：24 高、12 号字，正在右侧预览的那张描蓝。</summary>
    FrameworkElement ResumeTag(JsonNode context)
    {
        var tab = ChatPreviewTab.ForContext(context);
        var gone = tab is null || _unavailableFiles.Contains(tab.Key);
        var active = tab is not null && ActivePreviewKey == tab.Key;
        var chip = new Border
        {
            Child = HStack(5, Icon("doc.text", 9.5, active ? Blue : Sub).Align(v: VerticalAlignment.Center),
                Label(context.Text("type") == "user_profile" ? "个人画像" : context.Text("label"), 12, active ? Blue : Txt, Medium).Wrap(1).Align(v: VerticalAlignment.Center),
                Sans("简历", 11, Faint).Align(v: VerticalAlignment.Center)),
            Padding = new Thickness(7, 0, 7, 0), Height = 24, MaxWidth = 260, CornerRadius = new CornerRadius(6.5),
            Background = Brush(active ? Alpha(Blue, 0.08) : White), BorderBrush = Brush(active ? Blue : Cl), BorderThickness = new Thickness(1),
        };
        return chip.OnTap(() => { if (tab is not null) OpenPreview(tab); }, $"引用文件 {context.Text("label")}", () => !gone);
    }

    FrameworkElement AssistantMessage(JsonNode message, int index)
    {
        var cards = message.Items("cards").Where(c => AssistantActionCards.ActionTypes.Contains(c.Text("type"))).ToList();
        var document = GeneratedTab(message, index);
        var stack = new StackPanel();
        var run = message.Text("run_id");
        if (run.Length > 0 && _processes.TryGetValue(run, out var snapshot) && FirstReply(run) == index && Fold(run, snapshot) is { } fold)
            stack.Children.Add(fold.Pad(0, 0, 0, 12));
        var files = message.Items("attachments");
        if (files.Count > 0) stack.Children.Add(MessageAttachments(files, false));
        stack.Children.Add(NativeMarkdownView.Render(message.Text("content").NonEmpty() ?? (message.Text("message_type") == "clarification" ? "需要你补充一些信息。" : ""), 13.5, 24));
        if (message.Text("status") == "stopped") stack.Children.Add(Sans("已停止生成", 11, Fnt).Top(6));
        if (message.Text("status") == "failed") stack.Children.Add(Sans("生成未完成", 11, Fnt).Top(6));
        if (cards.Count > 0 || document is not null)
            stack.Children.Add(AssistantActionCards.Make(cards, _currentId, (int?)message.Number("sequence_no"), document, ActivePreviewKey, OpenPreview,
                card => ReplaceCard(index, card)).Pad(0, 16, 0, 0));
        var host = new Grid { Background = Brush(Clear) };
        host.Children.Add(stack);
        if (message.Text("content").Length > 0) Hovered(host, MessageActions(message, index, false), HorizontalAlignment.Left, 4);
        return host;
    }

    /// <summary>操作行绝对定位在正文下方，不占高度，悬停才显示。</summary>
    void Hovered(Grid host, FrameworkElement actions, HorizontalAlignment align, double gap)
    {
        actions.HorizontalAlignment = align;
        actions.VerticalAlignment = VerticalAlignment.Bottom;
        actions.RenderTransform = new TranslateTransform { Y = 22 + gap };
        actions.Opacity = 0;
        host.Children.Add(actions);
        host.OnHover(on => actions.Opacity = on ? 1 : 0);
    }

    /// <summary>同一轮回复里第一条助手消息才挂折叠行。</summary>
    int FirstReply(string run) => _messages.FindIndex(m => m.Text("role") == "assistant" && m.Text("run_id") == run);

    void ReplaceCard(int index, JsonNode card)
    {
        if (index >= _messages.Count || _messages[index] is not JsonObject fields) return;
        fields["cards"] = new JsonArray(fields.Items("cards").Select(c => (c.Text("id") == card.Text("id") ? card : c).DeepClone()).ToArray());
    }

    /// <summary>悬停操作（02B·08 E）：时间、复制；最后一条自己发的消息、且没有运行中时多一个「编辑」。</summary>
    FrameworkElement MessageActions(JsonNode message, int index, bool editable)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Height = 22 };
        if (Json.Date(message.Text("created_at")) is { } date)
            row.Children.Add(Number(date.ToOffset(TimeSpan.FromHours(8)).ToString("HH:mm"), 12, Fnt, Regular).Pad(0, 0, 2, 0).Align(v: VerticalAlignment.Center));
        var copied = _copiedMessage == index;
        var copy = new Grid { Width = 22, Height = 22, Background = Brush(Clear), Children = { Icon(copied ? "checkmark" : "doc.on.doc", 11, Fnt).Align(HorizontalAlignment.Center, VerticalAlignment.Center) } }
            .Tip(copied ? "已复制" : "复制消息");
        copy.OnTap(() =>
        {
            var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(message.Text("content"));
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
            _copiedMessage = index;
            Render();
            _ = Task.Delay(2000).ContinueWith(_ => DispatcherQueue.TryEnqueue(() => { if (_copiedMessage == index) { _copiedMessage = null; Render(); } }), TaskScheduler.Default);
        }, copied ? "已复制消息" : "复制消息");
        row.Children.Add(copy);
        if (editable)
        {
            var edit = new Grid { Width = 22, Height = 22, Background = Brush(Clear), Children = { Icon("pencil", 11, Fnt).Align(HorizontalAlignment.Center, VerticalAlignment.Center) } }.Tip("编辑");
            edit.OnTap(() => { _editDraft = message.Text("content"); _editingIndex = index; Render(); }, "编辑这条消息");
            row.Children.Add(edit);
        }
        return row;
    }

    bool CanEdit(int index) => !Sending && _currentId is not null && index == LastUserIndex && (_messages[index].Number("sequence_no") ?? 0) > 0
        && _messages[index]["clarification_answers"] is null;

    /// <summary>编辑框（02B·08 E ②）：气泡被输入框原位替换，右对齐；Esc 或「取消」还原，内容没变时「发送」置灰。</summary>
    FrameworkElement EditBox(JsonNode message, int index)
    {
        bool Changed() => _editDraft.Trim() != message.Text("content").Trim() && _editDraft.Trim().Length > 0;
        var box = new TextBox
        {
            Text = _editDraft, PlaceholderText = "改写这条消息", FontSize = 13, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 50, MaxHeight = 160,
            BorderThickness = new Thickness(0), Background = Brush(Clear), Padding = new Thickness(0, 4, 0, 4),
        };
        Quiet(box.Resources);
        AutomationProperties.SetName(box, "改写这条消息");
        var send = new V3Button("发送", () => _ = SubmitEditAsync(index), V3Button.Kind.Ghost, height: 28) { Enabled = Changed() && !Sending };
        box.TextChanged += (_, _) => { _editDraft = box.Text; send.Enabled = Changed() && !Sending; };
        box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; _editingIndex = null; Render(); }
            else if (e.Key == Windows.System.VirtualKey.Enter && !Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down))
            { e.Handled = true; if (Changed()) _ = SubmitEditAsync(index); }
        };
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectionStart = box.Text.Length; };
        var stack = new StackPanel { Spacing = 8, MaxWidth = Math.Min(560, ColumnWidth) };
        stack.Children.Add(new Border { Child = box, Padding = new Thickness(10, 6, 10, 6), Background = Brush(White), CornerRadius = new CornerRadius(10), BorderBrush = Brush(Hex(0xD6D6D0)), BorderThickness = new Thickness(1) });
        stack.Children.Add(Sans("发送后，这条消息之后的回复会被新的回复替换；已经采用的修改不会撤销。", 12, Fnt).Wrap());
        var buttons = HStack(12, Sans("取消", 13, Sub).Align(v: VerticalAlignment.Center).OnTap(() => { _editingIndex = null; Render(); }, "取消"), send);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        stack.Children.Add(buttons);
        return stack;
    }

    /// <summary>
    /// Web `composerSegments`：正文里的 `@名称` 换成蓝色 500 字重的名称（正在右侧预览的加下划线），点击打开预览；正文没提到的引用排在最前，后接一个空格。
    /// </summary>
    public static RichTextBlock UserSegments(string content, IReadOnlyList<JsonNode> contexts, string? active, Action<JsonNode> open)
    {
        var block = new RichTextBlock { FontFamily = SansFamily, FontSize = 13, LineHeight = 21, LineStackingStrategy = LineStackingStrategy.BlockLineHeight, Foreground = Brush(Txt), IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
        var paragraph = new Paragraph();
        block.Blocks.Add(paragraph);
        void Token(JsonNode context)
        {
            var current = active is not null && ChatPreviewTab.ForContext(context)?.Key == active;
            var link = new Hyperlink { Foreground = Brush(Link), FontWeight = Medium, UnderlineStyle = current ? UnderlineStyle.Single : UnderlineStyle.None };
            link.Inlines.Add(new Run { Text = context.Text("type") == "user_profile" ? "个人画像" : context.Text("label") });
            link.Click += (_, _) => open(context);
            paragraph.Inlines.Add(link);
        }
        var missing = contexts.Where(c => !content.Contains("@" + c.Text("label"))).ToList();
        foreach (var context in missing) Token(context);
        if (missing.Count > 0 && content.Length > 0) paragraph.Inlines.Add(new Run { Text = " " });
        var cursor = 0;
        while (cursor < content.Length)
        {
            (JsonNode context, int at, int length)? next = null;
            foreach (var context in contexts)
            {
                var needle = "@" + context.Text("label");
                var at = content.IndexOf(needle, cursor, StringComparison.Ordinal);
                if (at >= 0 && (next is null || at < next.Value.at)) next = (context, at, needle.Length);
            }
            if (next is not { } found) { paragraph.Inlines.Add(new Run { Text = content[cursor..] }); break; }
            if (found.at > cursor) paragraph.Inlines.Add(new Run { Text = content[cursor..found.at] });
            Token(found.context);
            cursor = found.at + found.length;
        }
        return block;
    }

    static FrameworkElement CompactionDivider(JsonNode message)
    {
        var row = Columns(10, (Star(), Divider().Align(v: VerticalAlignment.Center)), (GridLength.Auto, Sans("较早的对话已压缩成摘要", 11.5, Fnt)), (Star(), Divider().Align(v: VerticalAlignment.Center)));
        ToolTipService.SetToolTip(row, message.Text("content"));
        return row;
    }

    /// <summary>附件按类型显示图标（02B·08 F）：每个文件一张卡，22 号线性图标，名称 12/500，下面一行类型与大小。</summary>
    static FrameworkElement MessageAttachments(IReadOnlyList<JsonNode> files, bool trailing)
    {
        var flow = new VariableSizedFlow(8, trailing);
        foreach (var file in files)
        {
            var name = file.Text("file_name");
            var kind = file.Text("kind").NonEmpty() ?? AgentAttachments.Kind(name);
            var size = file.Number("file_size") is { } bytes ? FileSize((long)bytes) : null;
            var type = kind == "audio" ? "录音" : Path.GetExtension(name).TrimStart('.').ToUpperInvariant();
            flow.Add(AttachmentCard(name, FileSymbol(name, kind), string.Join(" · ", new[] { type, size }.Where(x => !string.IsNullOrEmpty(x))), false));
        }
        return flow.Panel.Pad(0, 0, 0, 8);
    }

    static FrameworkElement AttachmentCard(string name, string symbol, string detail, bool failed)
    {
        var texts = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Label(name, 12, Txt, Medium).Also(t => { t.TextTrimming = TextTrimming.CharacterEllipsis; t.MaxLines = 1; }));
        if (detail.Length > 0) texts.Children.Add(Sans(detail, 11, failed ? Red : Faint).Wrap(1));
        return new Border
        {
            Child = HStack(8, Icon(symbol, 15, Sub).Frame(22, 22).Align(v: VerticalAlignment.Center), texts),
            Padding = new Thickness(10, 8, 16, 8), MinWidth = 120, MaxWidth = 240, Background = Brush(White), CornerRadius = new CornerRadius(8),
            BorderBrush = Brush(failed ? Red : Cl), BorderThickness = new Thickness(1),
        };
    }

    static string FileSymbol(string name, string kind)
    {
        if (kind == "audio") return "mic";
        if (kind == "image") return "photo";
        return Path.GetExtension(name).TrimStart('.').ToLowerInvariant() is "md" or "txt" or "markdown" ? "text.alignleft" : "doc";
    }

    static string FileSize(long bytes) => bytes < 1024 ? $"{bytes} B" : bytes < 1024 * 1024 ? $"{Math.Round(bytes / 1024.0)} KB" : $"{bytes / 1024.0 / 1024.0:0.0} MB";

    /// <summary>追问卡（Web `AgentPanel` 的澄清）：一次显示一题，上一题/下一题，最后一题确认；允许时有“其他”自由填写。</summary>
    FrameworkElement ClarificationCard(JsonNode message)
    {
        var clarification = message["clarification"];
        var questions = clarification.Items("questions");
        var page = Math.Min(_clarificationPage, Math.Max(0, questions.Count - 1));
        var question = questions.Count == 0 ? new JsonObject() : questions[page];
        var qid = question.Text("id");
        var allowsCustom = question["allow_custom"] is JsonValue own ? own.Bool() : clarification?["allow_custom"] is JsonValue shared ? shared.Bool() : true;
        bool Answered(JsonNode q) => _answers.TryGetValue(q.Text("id"), out var answer) && (answer != "__other__" || (_otherAnswers.GetValueOrDefault(q.Text("id")) ?? "").Trim().Length > 0);
        var complete = questions.All(Answered);
        var stack = new StackPanel { Spacing = 12 };
        stack.Children.Add(Spread(Sans(question.Text("header"), 11.5, Fnt), questions.Count > 1 ? Number($"{page + 1}/{questions.Count}", 11, Fnt, Regular) : new Border()));
        stack.Children.Add(Label(question.Text("question").NonEmpty() ?? question.Text("header"), 13.5, Txt, Medium).Wrap());
        var options = new StackPanel { Spacing = 6 };
        foreach (var option in question.Items("options"))
        {
            var id = option.Text("id");
            options.Children.Add(Choice(option.Text("label"), option.Text("description"), _answers.GetValueOrDefault(qid) == id, () => { _answers[qid] = id; Render(); }));
        }
        if (allowsCustom)
        {
            options.Children.Add(Choice("其他", "", _answers.GetValueOrDefault(qid) == "__other__", () => { _answers[qid] = "__other__"; Render(); }));
            if (_answers.GetValueOrDefault(qid) == "__other__")
            {
                var box = Input("写下你的回答", _otherAnswers.GetValueOrDefault(qid) ?? "", 500);
                box.TextChanged += (_, _) => _otherAnswers[qid] = box.Text;
                box.LostFocus += (_, _) => Render();
                options.Children.Add(box);
            }
        }
        stack.Children.Add(options);
        var left = page > 0 ? new V3Button("上一题", () => { _clarificationPage = page - 1; Render(); }, V3Button.Kind.Text) : (UIElement)new Border();
        // 卡片里的确认用白底细边（02B·08：黑色只留给输入框发送）
        UIElement right = page < questions.Count - 1
            ? new V3Button("下一题", () => { _clarificationPage = page + 1; Render(); }) { Enabled = Answered(question) }
            : new V3Button("确认", () => _ = AnswerClarificationAsync(message, questions)) { Enabled = complete && !Sending };
        stack.Children.Add(Spread(left, right));
        return new Border { Child = stack, Padding = new Thickness(16), Background = Brush(White), CornerRadius = new CornerRadius(12), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1) };
    }

    static FrameworkElement Choice(string label, string detail, bool selected, Action action)
    {
        var texts = new StackPanel { Spacing = 2 };
        texts.Children.Add(Sans(label, 13));
        if (detail.Length > 0) texts.Children.Add(Sans(detail, 11.5, Fnt).Wrap());
        var row = Columns(8, (GridLength.Auto, Icon(selected ? "largecircle.fill.circle" : "circle", 13, selected ? Txt : Fnt).Align(v: VerticalAlignment.Top).Top(2)), (Star(), texts));
        var button = new Border
        {
            Child = row, Padding = new Thickness(10, 8, 10, 8), CornerRadius = new CornerRadius(8), Background = Brush(White),
            BorderBrush = Brush(selected ? Alpha(Txt, 0.5) : Cl), BorderThickness = new Thickness(1),
        };
        button.OnTap(action, label);
        if (selected) AutomationProperties.SetItemStatus(button, "已选择");
        return button;
    }

    /// <summary>Web 文档生成规则：完整回复中有一级 Markdown 标题时视为可保存的文档。</summary>
    public static string? DocumentTitle(string content) =>
        content.Split('\n').FirstOrDefault(l => l.StartsWith("# ", StringComparison.Ordinal)) is { } line && line[2..].Trim() is { Length: > 0 } title ? title : null;

    /// <summary>生成中也可插话（服务端开放 steering 时），消息会排进当前运行。</summary>
    bool CanSend => (!Sending || (_steering && _runId is not null)) && _ready != false && _draft.Trim().Length > 0;
    string? CurrentModelName => _models.FirstOrDefault(m => m.Text("id") == _modelId)?.Text("name").NonEmpty() ?? _modelName;

    static string ContextTypeLabel(string type) => type switch
    {
        "user_profile" => "求职资料", "resume" => "简历", "resume_version" => "简历版本", "dataset" => "资料",
        "job" => "岗位", "application" => "求职进程", "interview" => "面试记录", _ => type,
    };

    JsonNode? FreeModel => _models.FirstOrDefault(m => m.Bool("isFreeTier") && m.Text("id") != _modelId);

    FrameworkElement CreditNotice((string kind, string content) block)
    {
        var title = block.kind == "exhausted" ? "本月额度已用完，未能生成回复" : CurrentModelName is { } name ? $"{name} 暂不可用于当前额度" : "这项功能暂不可用于当前额度";
        var body = block.kind == "exhausted" ? "你的消息已保留，额度恢复后可以直接重新发送。" : "当前额度只能使用基础模型，可以改用基础模型重新发送。";
        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(Label(title, 13.5, Txt, Semibold));
        stack.Children.Add(Sans(body, 12.5, Sub).Wrap());
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (block.kind == "model" && FreeModel is { } free)
            actions.Children.Add(new V3Button($"改用 {free.Text("name")} 重新发送", async () => { await ChooseModelAsync(free); _creditBlock = null; await SendAsync(block.content); }));
        if (block.kind == "exhausted")
            actions.Children.Add(new V3Button("我的额度", () => Shell.PlansDialog.Show(Shell.WorkspaceShell.Current, "credits")));
        actions.Children.Add(Sans("把消息放回输入框", 12, Link).Align(v: VerticalAlignment.Center).OnTap(() => { _draft = block.content; _creditBlock = null; Render(); }, "把消息放回输入框"));
        stack.Children.Add(actions);
        var card = new Border { Child = stack, Padding = new Thickness(16), Background = Brush(White), CornerRadius = new CornerRadius(12), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1) };
        AutomationProperties.SetName(card, title);
        return card;
    }

    // MARK: 修改建议（02B·11）

    /// <summary>同一轮提问产生的建议合在一块（Web `proposalGroup`）。</summary>
    List<(string key, List<JsonNode> items)> ProposalGroups()
    {
        var users = _messages.Where(m => m.Text("role") == "user").ToList();
        var order = new List<string>();
        var groups = new Dictionary<string, List<JsonNode>>();
        foreach (var proposal in _proposals)
        {
            var source = proposal.Number("source_user_sequence_no") is { } n ? (int?)n : null;
            var owner = users.FirstOrDefault(u => source is not null ? (int?)u.Number("sequence_no") == source : proposal.Text("run_id").Length > 0 && u.Text("run_id") == proposal.Text("run_id"));
            var key = owner is not null ? ((int)(owner.Number("sequence_no") ?? 0)).ToString() : $"history-{proposal.Text("run_id")}";
            if (!groups.ContainsKey(key)) { order.Add(key); groups[key] = []; }
            groups[key].Add(proposal);
        }
        return order.Select(k => (k, groups[k])).ToList();
    }

    /// <summary>建议块挂在这一轮最后一条消息下面（下一条用户消息之前）；这一轮还在生成时放到末尾。</summary>
    Dictionary<int, List<(string key, List<JsonNode> items)>> AnchoredGroups()
    {
        var result = new Dictionary<int, List<(string key, List<JsonNode> items)>>();
        foreach (var group in ProposalGroups())
        {
            var owner = _messages.FindIndex(m => m.Text("role") == "user" && ((int)(m.Number("sequence_no") ?? -1)).ToString() == group.key);
            if (owner < 0) continue;
            var next = _messages.FindIndex(owner + 1, m => m.Text("role") == "user");
            var anchor = (next < 0 ? _messages.Count : next) - 1;
            if (anchor == _messages.Count - 1 && Sending) continue;
            if (!result.TryGetValue(anchor, out var list)) result[anchor] = list = [];
            list.Add(group);
        }
        return result;
    }

    FrameworkElement SuggestionList(List<JsonNode> items) =>
        new AssistantSuggestionList(items, _proposalBusy, Sending, p => DecideAsync(p, true), p => DecideAsync(p, false), RewriteProposal);

    /// <summary>没能采用时「按现在的内容重写」（Web `rewriteProposal`）：输入框空就直接发，有草稿就接在草稿后面。</summary>
    void RewriteProposal(string place)
    {
        var text = $"简历里「{place}」这一处刚改过，请按现在的内容重新给这一处的修改建议。";
        if (_draft.Trim().Length == 0 && _attachments.Count == 0) { _ = SendAsync(text); return; }
        _draft = _draft.Trim().Length == 0 ? text : _draft.Trim() + " " + text;
        Render();
    }
}
