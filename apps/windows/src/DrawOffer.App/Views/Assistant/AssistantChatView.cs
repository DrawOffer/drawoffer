using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Agent;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;
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
/// AI 对话（Mac `AssistantChatView.swift`，Web `features/assistant/AssistantPage.tsx` 的核心流程）：会话消息、流式回复、追问选项、
/// 简历修改建议的应用/不采用、附加资料、附件与停止生成。消息带固定幂等键，中断后刷新即可确认结果。
/// 状态集中在字段里，任何变化后调用 <see cref="Render"/> 整页重建（与 SwiftUI 的 body 重算对应）；输入框焦点与光标在重建时保留。
/// </summary>
public sealed partial class AssistantChatView : UserControl
{
    readonly string? _sessionId;
    readonly string? _initialMessage;
    readonly string? _initialModelId;

    string? _currentId;
    string _title = "新对话";
    List<JsonNode> _messages = [];
    List<JsonNode> _proposals = [];
    string _draft = "";
    string _streaming = "";
    string? _status, _runId, _error, _modelName, _modelId, _savingDocument, _proposalBusy, _revisionProposalId, _notice;
    bool _sending, _steering, _consumedInitial, _previewOpen, _usageOpen, _slashDismissed, _previewFullscreen;
    bool? _ready;
    List<JsonNode> _models = [];
    int? _hoveredMessage, _copiedMessage;
    List<JsonNode> _contexts = [];
    List<JsonNode> _contextGroups = [];
    readonly Dictionary<string, string> _answers = [];
    readonly Dictionary<string, string> _otherAnswers = [];
    List<ChatPreviewTab> _previewTabs = [];
    string? _previewActive;
    readonly HashSet<string> _unavailableFiles = [];
    readonly HashSet<string> _savedDocuments = [];
    List<ChatAttachment> _attachments = [];
    JsonNode? _contextUsage;
    int _clarificationPage;
    /// <summary>额度拦截（Web `CreditNotice`）：额度用完，或当前模型不可用于当前额度；保留原消息以便重发。</summary>
    (string kind, string content)? _creditBlock;
    (string key, int completed, int total)? _batchProgress;
    CancellationTokenSource? _streamCancel;

    readonly Grid _root = new();
    ScrollViewer? _scroller;
    TextBox? _input;
    bool _stickToBottom = true;

    static IApiClient Api => App.Session.Api;

    public AssistantChatView(string? sessionId, string? initialMessage, string? initialModelId)
    {
        _sessionId = sessionId;
        _initialMessage = initialMessage;
        _initialModelId = initialModelId;
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
        Unloaded += (_, _) => _streamCancel?.Cancel();
        Render();
    }

    JsonNode? PendingClarification
    {
        get
        {
            if (_sending || _messages.LastOrDefault() is not { } last || last.Text("role") != "assistant") return null;
            return last.Get("clarification") is JsonObject clarification && clarification.Items("questions").Count > 0 ? last : null;
        }
    }

    bool Sending
    {
        get => _sending;
        set
        {
            if (_sending == value) return;
            _sending = value;
            if (_currentId is { } id) Shell.WorkspaceShell.Current.SetRunning(id, value);
        }
    }

    // MARK: 布局

    void Render()
    {
        var focused = _input?.FocusState is not null and not FocusState.Unfocused;
        var selection = _input?.SelectionStart ?? _draft.Length;
        var offset = _scroller?.VerticalOffset ?? 0;
        _root.Children.Clear();
        _root.ColumnDefinitions.Clear();
        var showPreview = _previewOpen && _previewTabs.Count > 0;
        var showChat = !(_previewFullscreen && showPreview);
        if (showChat) _root.ColumnDefinitions.Add(new ColumnDefinition { Width = Star(), MinWidth = 420 });
        if (showPreview)
        {
            _root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
            _root.ColumnDefinitions.Add(new ColumnDefinition { Width = _previewFullscreen ? Star() : new GridLength(460) });
        }
        if (showChat)
        {
            var chat = new Grid();
            chat.Children.Add(Chat());
            if (FilesToggle() is { } toggle) chat.Children.Add(toggle);
            _root.Children.Add(chat);
        }
        if (showPreview)
        {
            var divider = Divider(vertical: true);
            Grid.SetColumn(divider, showChat ? 1 : 0);
            if (showChat) _root.Children.Add(divider);
            var panel = new ChatPreviewPanel(new ChatPreviewPanel.Options(
                _previewTabs.Select(t => t.Kind == ChatPreviewTab.Kinds.Generated ? t with { Saved = _savedDocuments.Contains(t.Content) } : t).ToList(),
                _previewActive, _unavailableFiles,
                key => { _previewActive = key; Render(); }, ClosePreview, () => { _previewOpen = false; Render(); },
                tab => { _savingDocument = tab.Content; ShowSaveDocument(); }, key => { _unavailableFiles.Add(key); Render(); },
                _previewFullscreen, value => { _previewFullscreen = value; Render(); }));
            if (showChat) { Grid.SetColumn(panel, 2); }
            else { _root.ColumnDefinitions.Clear(); }
            _root.Children.Add(panel);
        }
        if (focused && _input is { } input)
            input.Loaded += (_, _) => { input.Focus(FocusState.Programmatic); input.SelectionStart = Math.Min(selection, input.Text.Length); };
        if (_scroller is { } scroller)
            scroller.Loaded += (_, _) => scroller.ChangeView(null, _stickToBottom ? scroller.ScrollableHeight : offset, null, true);
    }

    FrameworkElement Chat()
    {
        var list = new StackPanel { Spacing = 24, MaxWidth = 900, Padding = new Thickness(24, 48, 24, 24), HorizontalAlignment = HorizontalAlignment.Stretch };
        for (var index = 0; index < _messages.Count; index++)
        {
            var message = _messages[index];
            if (message.Text("message_type") == "compaction") list.Children.Add(CompactionDivider(message));
            else if (message.Text("message_type") != "clarification" || message.Text("content").Length > 0) list.Children.Add(Bubble(message, index));
        }
        foreach (var group in ProposalGroups())
        {
            var key = group.key;
            list.Children.Add(new SuggestionCard(new SuggestionCard.Options(
                group.items, key != NewestProposalGroup, ProposalResumeLabel(group.items.FirstOrDefault().Text("resume_id")),
                _proposalBusy, Sending, _batchProgress is { } p && p.key == key ? p : null, _batchProgress is not null,
                proposal => DecideAsync(proposal, true), proposal => DecideAsync(proposal, false),
                () => _ = ApplyAllAsync(key, group.items),
                proposal => { _draft = "继续调整："; _revisionProposalId = proposal.Text("id"); Render(); _input?.Focus(FocusState.Programmatic); },
                proposal => OpenPreview(new ChatPreviewTab(ChatPreviewTab.Kinds.Resume, proposal.Text("resume_id"), proposal.Text("resume_title").NonEmpty() ?? "简历")))));
        }
        if (Sending)
        {
            var live = new StackPanel { Spacing = 6 };
            if (_streaming.Length > 0) live.Children.Add(NativeMarkdownView.Render(_streaming));
            live.Children.Add(HStack(6, new ProgressRing { Width = 14, Height = 14, IsActive = true }, Sans(_status ?? "正在思考…", 12, Fnt).Align(v: VerticalAlignment.Center)));
            list.Children.Add(live);
        }
        if (PendingClarification is { } clarification) list.Children.Add(ClarificationCard(clarification));
        if (_creditBlock is { } block && !Sending) list.Children.Add(CreditNotice(block));
        if (_currentId is { } current && !Sending) list.Children.Add(new MemoryReceipt(current, _messages.Count));
        if (_error is { } error) list.Children.Add(Sans(error, 12.5, Red).Wrap());

        _scroller = new ScrollViewer { Content = list, HorizontalScrollMode = ScrollMode.Disabled };
        _scroller.ViewChanged += (s, _) => { var v = (ScrollViewer)s!; _stickToBottom = v.VerticalOffset >= v.ScrollableHeight - 24; };
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Children.Add(_scroller);
        var composer = Composer();
        composer.Margin = new Thickness(24, 8, 24, 8);
        Grid.SetRow(composer, 1);
        grid.Children.Add(composer);
        return grid;
    }

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
                    .SelectMany(p => p.Get("preview").Items("changes").Select(c => c.Text("before"))).Where(x => x.Length > 0).ToList(),
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

    // MARK: 片段

    /// <summary>Web `.assistant-files-toggle`：对话页右上角浮动的「N 个文件」，预览面板打开时隐藏。</summary>
    FrameworkElement? FilesToggle()
    {
        var files = SessionFiles().Count;
        if (files == 0 || _previewOpen) return null;
        var row = HStack(6, Icon("sidebar.right", 12, Sub), Sans($"{files} 个文件", 12, Sub, Medium).Align(v: VerticalAlignment.Center));
        var button = new Border
        {
            Child = row, Padding = new Thickness(9, 0, 10, 0), Height = 29, Background = Brush(V3.White), CornerRadius = new CornerRadius(8),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(16),
        };
        button.OnTap(OpenAllFiles, $"查看本会话的 {files} 个文件");
        return button;
    }

    FrameworkElement Bubble(JsonNode message, int index)
    {
        var user = message.Text("role") == "user";
        var content = message.Text("content");
        var attached = message.Items("contexts").Where(c => c.Text("label").Length > 0).ToList();
        var stack = new StackPanel { HorizontalAlignment = user ? HorizontalAlignment.Right : HorizontalAlignment.Stretch };
        // Web `UserMessageContent`：正文里没 @ 到的简历引用排在气泡上方（24 高小标签、靠右），其余引用作为正文内的蓝色字
        var resumes = attached.Where(c => c.Text("type") is "resume" or "resume_version" && !content.Contains("@" + c.Text("label"))).ToList();
        if (user && resumes.Count > 0)
        {
            var flow = new VariableSizedFlow(6, trailing: true);
            foreach (var context in resumes)
            {
                var tab = ChatPreviewTab.ForContext(context);
                var gone = tab is null || _unavailableFiles.Contains(tab.Key);
                var active = tab is not null && _previewOpen && _previewActive == tab.Key;
                var chip = new Border
                {
                    Child = HStack(5, Icon("doc.text", 10, active ? V3.Blue : Sub),
                        Sans(context.Text("type") == "user_profile" ? "个人画像" : context.Text("label"), 12, active ? V3.Blue : Txt, Medium).Align(v: VerticalAlignment.Center),
                        Sans("简历", 12, Fnt).Align(v: VerticalAlignment.Center)),
                    Padding = new Thickness(7, 0, 7, 0), Height = 24, MaxWidth = 260, CornerRadius = new CornerRadius(7),
                    Background = Brush(active ? Alpha(V3.Blue, 0.08) : V3.White), BorderBrush = Brush(active ? V3.Blue : Cl), BorderThickness = new Thickness(1),
                };
                chip.OnTap(() => { if (tab is not null) OpenPreview(tab); }, $"引用文件 {context.Text("label")}", () => !gone);
                flow.Add(chip);
            }
            stack.Children.Add(flow.Panel.Pad(0, 0, 0, 8));
        }
        var inline = attached.Where(c => !resumes.Contains(c)).ToList();
        if (inline.Count > 0 && !user)
        {
            var flow = new VariableSizedFlow(6);
            foreach (var context in inline) flow.Add(Sans(context.Text("label"), 11.5, Fnt));
            stack.Children.Add(flow.Panel);
        }
        var files = message.Items("attachments");
        if (files.Count > 0) stack.Children.Add(MessageAttachments(files, user));
        if (user)
        {
            // `.assistant-message.is-user`：#F4F4F2 气泡，圆角 12、内边距 9/14、14px 行高 22，最宽 min(560, 82%)
            var text = UserSegments(content, inline, context => { if (ChatPreviewTab.ForContext(context) is { } tab && !_unavailableFiles.Contains(tab.Key)) OpenPreview(tab); });
            stack.Children.Add(new Border { Child = text, Padding = new Thickness(14, 9, 14, 9), Background = Brush(Field), CornerRadius = new CornerRadius(12), HorizontalAlignment = HorizontalAlignment.Right });
        }
        else
        {
            stack.Children.Add(NativeMarkdownView.Render(content.NonEmpty() ?? (message.Text("message_type") == "clarification" ? "需要你补充一些信息。" : ""), 16, 26));
            if (message.Text("status") == "stopped") stack.Children.Add(Sans("已停止生成", 11, Fnt));
            if (message.Text("status") == "failed") stack.Children.Add(Sans("生成未完成", 11, Fnt));
            if (GeneratedTab(message, index) is { } tab)
            {
                var saved = _savedDocuments.Contains(tab.Content);
                stack.Children.Add(HStack(8,
                    new V3Button("预览文档", () => OpenPreview(tab), icon: "sidebar.right"),
                    new V3Button(saved ? "已保存" : "保存到资料库", () => { _savingDocument = content; ShowSaveDocument(); }, icon: "tray.and.arrow.down") { Enabled = !saved }).Top(8));
            }
        }
        // Web 覆盖规则：操作行绝对定位在正文下方 4px，不占高度，悬停才显示
        var host = new Grid { MaxWidth = user ? 560 : double.PositiveInfinity, HorizontalAlignment = user ? HorizontalAlignment.Right : HorizontalAlignment.Stretch, Background = Brush(Clear) };
        host.Children.Add(stack);
        if (content.Length > 0)
        {
            var actions = MessageActions(message, index);
            actions.HorizontalAlignment = user ? HorizontalAlignment.Right : HorizontalAlignment.Left;
            actions.VerticalAlignment = VerticalAlignment.Bottom;
            actions.RenderTransform = new TranslateTransform { Y = 22 + 4 };
            actions.Opacity = _hoveredMessage == index || _copiedMessage == index ? 1 : 0;
            host.Children.Add(actions);
            host.OnHover(on => { actions.Opacity = on || _copiedMessage == index ? 1 : 0; _hoveredMessage = on ? index : _hoveredMessage == index ? null : _hoveredMessage; });
        }
        return host;
    }

    /// <summary>Web `MessageActions`：时间与复制按钮。</summary>
    FrameworkElement MessageActions(JsonNode message, int index)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Height = 22 };
        if (Json.Date(message.Text("created_at")) is { } date) row.Children.Add(Number(date.ToLocalTime().ToString("HH:mm"), 12, Fnt, Regular).Frame(height: 18).Align(v: VerticalAlignment.Center));
        var copied = _copiedMessage == index;
        var copy = Icon(copied ? "checkmark" : "doc.on.doc", 12, Fnt).Frame(22, 22).Tip(copied ? "已复制" : "复制消息");
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
        return row;
    }

    /// <summary>
    /// Web `composerSegments`：正文里的 `@名称` 换成蓝色 500 字重的名称，点击打开预览；正文没提到的引用排在最前，后接一个空格。
    /// </summary>
    public static RichTextBlock UserSegments(string content, IReadOnlyList<JsonNode> contexts, Action<JsonNode> open)
    {
        var block = new RichTextBlock { FontFamily = SansFamily, FontSize = 14, LineHeight = 22, LineStackingStrategy = LineStackingStrategy.BlockLineHeight, Foreground = Brush(Txt), IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
        var paragraph = new Paragraph();
        block.Blocks.Add(paragraph);
        void Token(JsonNode context)
        {
            var link = new Hyperlink { Foreground = Brush(Link), FontWeight = Medium, UnderlineStyle = UnderlineStyle.None };
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

    FrameworkElement CompactionDivider(JsonNode message)
    {
        var row = Columns(10, (Star(), Divider().Align(v: VerticalAlignment.Center)), (GridLength.Auto, Sans("较早的对话已整理成摘要", 11.5, Fnt)), (Star(), Divider().Align(v: VerticalAlignment.Center)));
        ToolTipService.SetToolTip(row, message.Text("content"));
        return row;
    }

    /// <summary>Web `ChatAttachments`（已发送）：每个文件一张卡，边框、圆角 8、内边距 8/28/8/8，22 号文件夹或麦克风图标，名称 12/500，录音下注「录音」。</summary>
    static FrameworkElement MessageAttachments(IReadOnlyList<JsonNode> files, bool trailing)
    {
        var flow = new VariableSizedFlow(8, trailing);
        foreach (var file in files)
        {
            var audio = file.Text("kind") == "audio";
            var texts = new StackPanel { Spacing = 3 };
            texts.Children.Add(Sans(file.Text("file_name"), 12, Txt, Medium));
            if (audio) texts.Children.Add(Sans("录音", 11, Sub));
            flow.Add(new Border
            {
                Child = HStack(8, Icon(audio ? "mic" : "folder", 17, Txt).Frame(22, 22), texts.Align(v: VerticalAlignment.Center)),
                Padding = new Thickness(8, 8, 28, 8), MinWidth = 120, MaxWidth = 240, Background = Brush(V3.White), CornerRadius = new CornerRadius(8),
                BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            });
        }
        return flow.Panel.Pad(0, 8, 0, 8);
    }

    /// <summary>追问卡（Web `AgentPanel` 的澄清）：一次显示一题，上一题/下一题，最后一题提交；允许时有“其他”自由填写。</summary>
    FrameworkElement ClarificationCard(JsonNode message)
    {
        var clarification = message.Get("clarification");
        var questions = clarification.Items("questions");
        var page = Math.Min(_clarificationPage, Math.Max(0, questions.Count - 1));
        var question = questions.Count == 0 ? new JsonObject() : questions[page];
        var qid = question.Text("id");
        var allowsCustom = question.Get("allow_custom") is JsonValue own ? own.Bool() : clarification.Get("allow_custom") is JsonValue shared ? shared.Bool() : true;
        bool Answered(JsonNode q) => _answers.TryGetValue(q.Text("id"), out var answer) && (answer != "__other__" || (_otherAnswers.GetValueOrDefault(q.Text("id")) ?? "").Trim().Length > 0);
        var complete = questions.All(Answered);
        var stack = new StackPanel { Spacing = 12 };
        var head = Spread(Sans(question.Text("header"), 11.5, Fnt), questions.Count > 1 ? Number($"{page + 1}/{questions.Count}", 11, Fnt, Regular) : new Border());
        stack.Children.Add(head);
        stack.Children.Add(Sans(question.Text("question").NonEmpty() ?? question.Text("header"), 13.5, Txt, Medium).Wrap());
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
                var box = new TextBox { Text = _otherAnswers.GetValueOrDefault(qid) ?? "", PlaceholderText = "写下你的回答", MaxLength = 500, FontSize = 13, FontFamily = SansFamily };
                box.TextChanged += (_, _) => _otherAnswers[qid] = box.Text;
                box.LostFocus += (_, _) => Render();
                options.Children.Add(box);
            }
        }
        stack.Children.Add(options);
        var left = page > 0 ? new V3Button("上一题", () => { _clarificationPage = page - 1; Render(); }) : (UIElement)new Border();
        UIElement right = page < questions.Count - 1
            ? new V3Button("下一题", () => { _clarificationPage = page + 1; Render(); }, V3Button.Kind.Dark) { Enabled = Answered(question) }
            : new V3Button("提交回答", () => _ = AnswerClarificationAsync(message, questions), V3Button.Kind.Dark) { Enabled = complete && !Sending };
        stack.Children.Add(Spread(left, right));
        return Card(stack, 14, new Thickness(16));
    }

    static FrameworkElement Choice(string label, string detail, bool selected, Action action)
    {
        var texts = new StackPanel { Spacing = 2 };
        texts.Children.Add(Sans(label, 13));
        if (detail.Length > 0) texts.Children.Add(Sans(detail, 11.5, Fnt).Wrap());
        var row = Columns(8, (GridLength.Auto, Icon(selected ? "largecircle.fill.circle" : "circle", 13, selected ? Txt : Fnt).Align(v: VerticalAlignment.Top).Top(2)), (Star(), texts));
        var button = new Border
        {
            Child = row, Padding = new Thickness(10, 8, 10, 8), CornerRadius = new CornerRadius(8), Background = Brush(selected ? Field : Clear),
            BorderBrush = Brush(selected ? Alpha(Txt, 0.4) : Cl), BorderThickness = new Thickness(1),
        };
        button.OnTap(action, label);
        if (selected) AutomationProperties.SetItemStatus(button, "已选择");
        return button;
    }

    /// <summary>Web `isDocumentRequest`：明确要求生成文档（且没有否定）的请求。</summary>
    public static bool IsDocumentRequest(string prompt) =>
        !Regex.IsMatch(prompt, "(?:不要|不必|不用|不需要|无需|别).{0,8}(?:生成|整理|写|输出|制作|准备)")
        && Regex.IsMatch(prompt, @"(?:生成|整理成|写|输出|制作|准备).{0,30}(?:文档|\.md|markdown)", RegexOptions.IgnoreCase);

    /// <summary>Web 文档生成规则：完整回复中有一级 Markdown 标题时视为可保存的文档。</summary>
    public static string? DocumentTitle(string content) =>
        content.Split('\n').FirstOrDefault(l => l.StartsWith("# ", StringComparison.Ordinal)) is { } line && line[2..].Trim() is { Length: > 0 } title ? title : null;

    /// <summary>生成中也可插话（服务端开放 steering 时），消息会排进当前运行。</summary>
    bool CanSend => (!Sending || (_steering && _runId is not null)) && _ready != false && _draft.Trim().Length > 0;
    string? CurrentModelName => _models.FirstOrDefault(m => m.Text("id") == _modelId)?.Text("name").NonEmpty() ?? _modelName;

    static string ContextTypeLabel(string type) => type switch
    {
        "user_profile" => "求职资料", "resume" => "简历", "resume_version" => "简历版本", "dataset" => "资料库",
        "job" => "岗位", "application" => "求职进程", "interview" => "面试", _ => type,
    };

    JsonNode? FreeModel => _models.FirstOrDefault(m => m.Bool("isFreeTier") && m.Text("id") != _modelId);

    FrameworkElement CreditNotice((string kind, string content) block)
    {
        var title = block.kind == "exhausted" ? "本月额度已用完，未能生成回复" : CurrentModelName is { } name ? $"{name} 暂不可用于当前额度" : "这项功能暂不可用于当前额度";
        var body = block.kind == "exhausted" ? "你的消息已保留，额度恢复后可以直接重新发送。" : "当前额度只能使用基础模型，可以改用基础模型重新发送。";
        var stack = new StackPanel { Spacing = 8 };
        stack.Children.Add(Sans(title, 13.5, Txt, Semibold));
        stack.Children.Add(Sans(body, 12.5, Sub).Wrap());
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (block.kind == "model" && FreeModel is { } free)
            actions.Children.Add(new V3Button($"改用 {free.Text("name")} 重新发送", async () => { await ChooseModelAsync(free); _creditBlock = null; await SendAsync(block.content); }, V3Button.Kind.Dark));
        if (block.kind == "exhausted")
            actions.Children.Add(new V3Button("我的额度", () => Shell.WorkspaceShell.Current.OpenPlans()));
        actions.Children.Add(Sans("把消息放回输入框", 12, Link).Align(v: VerticalAlignment.Center).OnTap(() => { _draft = block.content; _creditBlock = null; Render(); }, "把消息放回输入框"));
        stack.Children.Add(actions);
        var card = new Border { Child = stack, Padding = new Thickness(16), Background = Brush(OrangeSoft), CornerRadius = new CornerRadius(14) };
        AutomationProperties.SetName(card, title);
        return card;
    }

    /// <summary>与 Web `proposalResumeLabel` 相同：取对话里引用的那份简历的名字，否则“简历 #id”。</summary>
    string ProposalResumeLabel(string resumeId)
    {
        var referenced = _contexts.Concat(_messages.SelectMany(m => m.Items("contexts"))).FirstOrDefault(c =>
            c.Text("type") is "resume" or "resume_version" && (c.Text("resume_id").NonEmpty() ?? c.Text("id")) == resumeId);
        return referenced?.Text("label").NonEmpty() ?? $"简历 #{resumeId}";
    }

    /// <summary>同一轮提问产生的建议合并在一张卡里（Web `proposalGroup`）。</summary>
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

    string NewestProposalGroup => _messages.LastOrDefault(m => m.Text("role") == "user") is { } last ? ((int)(last.Number("sequence_no") ?? 0)).ToString() : "none";
}
