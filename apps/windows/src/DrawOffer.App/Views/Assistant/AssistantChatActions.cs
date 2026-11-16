using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Agent;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Assistant;

public sealed partial class AssistantChatView
{
    // MARK: 快捷命令与 @ 引用

    /// <summary>输入框里以 / 开头的快捷命令（Web `slashCommands.ts`），只列出当前对话能执行的。</summary>
    List<(string id, string label, string detail, string symbol)> SlashCommands()
    {
        (string, string, string, string)[] all =
        [
            ("compact", "压缩上下文", "把较早的对话压缩成摘要，腾出上下文", "clock.arrow.circlepath"),
            ("context", "查看上下文用量", "看看离自动压缩还有多远、用在了哪里", "gauge.with.dots.needle.33percent"),
            ("ref", "引用简历或资料", "从简历和资料库里选几份带进对话", "doc.text"),
            ("upload", "上传文件", "图片、文档和录音", "square.and.arrow.up"),
            ("new", "新对话", "从空白对话重新开始", "bubble.left"),
        ];
        return all.Where(c => c.Item1 switch
        {
            "compact" => _currentId is not null && _contextUsage.Number("tokens") is not null && !Sending,
            "context" => _contextUsage.Number("context_window") is not null,
            _ => true,
        }).ToList();
    }

    List<(string id, string label, string detail, string symbol)> SlashMatches()
    {
        if (_slashDismissed || !_draft.StartsWith('/') || _draft[1..].Any(c => c is ' ' or '/' or '\n')) return [];
        var query = _draft[1..].ToLowerInvariant();
        return SlashCommands().Where(c => query.Length == 0 || c.id.StartsWith(query, StringComparison.Ordinal) || c.label.ToLowerInvariant().Contains(query)).ToList();
    }

    void RunSlash(string id)
    {
        _draft = "";
        // 弹层在输入框重建、加载后打开（见 Render 末尾）
        _floating = id switch { "context" => Floating.Usage, "ref" => Floating.Materials, _ => null };
        Render();
        switch (id)
        {
            case "compact": _ = CompactAsync(); break;
            case "upload": _ = PickFilesAsync(); break;
            case "new": NewConversation(); break;
        }
    }

    static readonly Regex MentionPattern = new(@"@[^\s@]{0,24}$");

    /// <summary>输入 @ 时（02B·06 ②）：光标前的 `@词` 用来筛选可引用的资料。</summary>
    string? MentionQuery => _mentionDismissed || _floating is Floating.Usage or Floating.Materials || MentionPattern.Match(_draft) is not { Success: true } match ? null : match.Value[1..];

    void ToggleContext(JsonNode item)
    {
        static string Key(JsonNode value) => value.Text("type") + ":" + value.Text("id") + ":" + value.Text("version_id");
        var index = _contexts.FindIndex(c => Key(c) == Key(item));
        if (index >= 0) _contexts.RemoveAt(index); else _contexts.Add(item.DeepClone());
        Render();
    }

    void PickMention(JsonNode item)
    {
        _draft = MentionPattern.Replace(_draft, "@" + (item.Text("type") == "user_profile" ? "个人画像" : item.Text("label")) + " ");
        if (!_contexts.Any(c => c.Text("type") == item.Text("type") && c.Text("id") == item.Text("id"))) _contexts.Add(item.DeepClone());
        _floating = null;
        Render();
        _input?.Focus(FocusState.Programmatic);
    }

    Dictionary<string, string> UsageDetails()
    {
        var shown = _messages.Count(m => m.Text("message_type") != "compaction");
        var unique = new Dictionary<string, JsonNode>();
        foreach (var reference in _messages.SelectMany(m => m.Items("contexts"))) unique[reference.Text("type") + ":" + reference.Text("id")] = reference;
        var resumes = unique.Values.Count(r => r.Text("type") is "resume" or "resume_version");
        var others = unique.Count - resumes;
        var files = _messages.Sum(m => m.Items("attachments").Count);
        var result = new Dictionary<string, string>();
        if (shown > 0) result["conversation"] = $"{shown} 条消息";
        var materials = new[] { resumes > 0 ? $"{resumes} 份简历" : "", others > 0 ? $"{others} 份资料" : "" }.Where(x => x.Length > 0).ToList();
        if (materials.Count > 0) result["materials"] = string.Join(" · ", materials);
        if (files > 0) result["attachments"] = $"{files} 个附件";
        return result;
    }

    // MARK: 浮层（贴在输入框上沿）

    void ToggleFloating(Floating kind)
    {
        if (_floating == kind) CloseFloating();
        else ShowFloating(kind);
    }

    void ShowFloating(Floating kind)
    {
        if (_inputBox is not { } anchor || anchor.XamlRoot is null) return;
        if (_floatingFlyout is { } previous) { _rebuilding = true; previous.Hide(); previous.Content = null; _rebuilding = false; }
        // 同一种资料面板重建时沿用原来的实例，保留搜索词和分类
        var reuse = _floating == kind && kind != Floating.Usage ? _floatingPanel : null;
        _floating = kind;
        _floatingPanel = null;
        UIElement content;
        double padding = 0;
        switch (kind)
        {
            case Floating.Usage:
                content = AssistantUsage.Panel(_contextUsage, CurrentModelName, UsageDetails(), Sending || _currentId is null, () => { CloseFloating(); _ = CompactAsync(); });
                padding = 0;
                content = new Border { Child = content, Padding = new Thickness(19, 17, 19, 15) };
                break;
            default:
                var mention = kind == Floating.Mention;
                _floatingPanel = reuse ?? new AssistantContextPanel(() => _contextGroups, () => _contexts, ContextTypeLabel, () => mention ? MentionQuery ?? "" : null,
                    mention ? PickMention : ToggleContext, () => { CloseFloating(); if (mention) _mentionDismissed = true; _ = PickFilesAsync(); });
                content = _floatingPanel;
                _floatingPanel.Refresh();
                _ = LoadContextsAsync().ContinueWith(_ => DispatcherQueue.TryEnqueue(() => _floatingPanel?.Refresh()), TaskScheduler.Default);
                break;
        }
        var flyout = V3Popover.Make(content, kind == Floating.Usage ? FlyoutPlacementMode.TopEdgeAlignedRight : FlyoutPlacementMode.TopEdgeAlignedLeft, padding);
        flyout.Closed += (_, _) =>
        {
            if (_rebuilding || _floatingFlyout != flyout) return;
            _floatingFlyout = null; _floatingPanel = null; _floating = null;
        };
        _floatingFlyout = flyout;
        // @ 筛选时不抢输入框焦点
        flyout.ShowAt(anchor, new FlyoutShowOptions { ShowMode = kind == Floating.Mention ? FlyoutShowMode.Transient : FlyoutShowMode.Standard, Placement = flyout.Placement });
    }

    void CloseFloating()
    {
        _floating = null;
        if (_floatingFlyout is { } flyout) { _floatingFlyout = null; _floatingPanel = null; flyout.Hide(); }
    }

    // MARK: 输入框（02B·03：57 高、圆角 17.5、#D6D6D0 描边；下方 12 处是「＋ 添加资料」与上下文圆环、模型）

    FrameworkElement Composer()
    {
        var stack = new StackPanel { MaxWidth = 720 };
        var matches = SlashMatches();
        if (matches.Count > 0)
        {
            var menu = new StackPanel { Spacing = 2 };
            foreach (var command in matches)
            {
                var row = Columns(10, (new GridLength(16), Icon(command.symbol, 12, Sub).Align(v: VerticalAlignment.Center)),
                    (Auto, Number("/" + command.id, 12.5, Fnt, Regular).Align(v: VerticalAlignment.Center)),
                    (Auto, Sans(command.label, 13).Align(v: VerticalAlignment.Center)),
                    (Star(), Sans(command.detail, 11.5, Fnt).Wrap(1).Align(v: VerticalAlignment.Center)));
                row.Height = 32;
                row.Padding = new Thickness(10, 0, 10, 0);
                var id = command.id;
                menu.Children.Add(MenuRow(row, () => RunSlash(id), command.label));
            }
            stack.Children.Add(new Border
            {
                Child = menu, Padding = new Thickness(6), MaxWidth = 560, HorizontalAlignment = HorizontalAlignment.Left, Background = Brush(White), CornerRadius = new CornerRadius(8),
                BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), Margin = new Thickness(0, 0, 0, 8),
            }.Elevate(10));
        }
        if (_attachments.Count > 0) stack.Children.Add(AttachmentStrip().Pad(0, 0, 0, 8));
        if (_contexts.Count > 0)
        {
            var flow = new VariableSizedFlow(6);
            foreach (var item in _contexts.ToList()) flow.Add(ContextChip(item));
            stack.Children.Add(flow.Panel.Pad(4, 0, 0, 11));
        }
        stack.Children.Add(InputBox());

        var add = HStack(6, Icon("plus", 10, Sub).Align(v: VerticalAlignment.Center), Sans("添加资料", 12.5, Sub));
        add.OnTap(() => ToggleFloating(Floating.Materials), "添加资料", () => !Sending);
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        left.Children.Add(add);
        if (_notice is { } notice) left.Children.Add(Sans(notice, 11.5, Orange).Wrap(2).Align(v: VerticalAlignment.Center));
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };
        if (AssistantUsage.Ring(_contextUsage, _ => ToggleFloating(Floating.Usage)) is { } ring) right.Children.Add(ring.Align(v: VerticalAlignment.Center));
        right.Children.Add(new ModelPicker(_models, _modelId, id => { if (_models.FirstOrDefault(m => m.Text("id") == id) is { } model) _ = ChooseModelAsync(model); }, disabled: Sending)
            .Align(v: VerticalAlignment.Center));
        var foot = Columns(10, (Star(), left.Align(v: VerticalAlignment.Center)), (GridLength.Auto, right));
        foot.MinHeight = 16;
        foot.Margin = new Thickness(12, 12, 12, 0);
        stack.Children.Add(foot);
        return stack;
    }

    static Border MenuRow(FrameworkElement content, Action action, string name)
    {
        var row = new Border { Child = content, CornerRadius = new CornerRadius(4), Background = Brush(Clear) };
        row.OnHover(on => row.Background = Brush(on ? Field : Clear));
        return row.OnTap(action, name);
    }

    /// <summary>输入框上方的引用标签（02B·03 · Context/Resume）：白底细边圆角 6.5、23 高，图标 + 名称 + 灰色类型 + ×。</summary>
    FrameworkElement ContextChip(JsonNode item)
    {
        var type = item.Text("type");
        var symbol = type is "resume" or "resume_version" ? "doc.text" : type == "dataset" ? "folder" : "doc";
        var remove = new Grid { Width = 12, Height = 12, Background = Brush(Clear), Children = { Icon("xmark", 7, Fnt).Align(HorizontalAlignment.Center, VerticalAlignment.Center) } }
            .OnTap(() => { _contexts.Remove(item); Render(); }, $"移除 {item.Text("label")}");
        return new Border
        {
            Child = HStack(6, Icon(symbol, 9, Sub).Align(v: VerticalAlignment.Center),
                Label(type == "user_profile" ? "个人画像" : item.Text("label"), 12, Txt, Medium).Wrap(1).Align(v: VerticalAlignment.Center),
                Sans(ContextTypeLabel(type).Replace("版本", ""), 11, Faint).Align(v: VerticalAlignment.Center), remove.Align(v: VerticalAlignment.Center)),
            Padding = new Thickness(9, 0, 6, 0), Height = 23, MaxWidth = 280, CornerRadius = new CornerRadius(6.5), Background = Brush(White),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        };
    }

    Border InputBox()
    {
        var input = ChatInputField(_ready == false ? "AI 助手暂未开放" : IsBlank ? "有什么想问的？" : "继续提问或说明调整要求…");
        UIElement action;
        if (Sending && _runId is not null)
        {
            var stop = new Grid { Width = 32, Height = 32 };
            stop.Children.Add(new Border { CornerRadius = new CornerRadius(16), Background = Brush(Txt) });
            stop.Children.Add(new Border { Width = 9, Height = 9, CornerRadius = new CornerRadius(2), Background = Brush(White) });
            stop.OnTap(() => _ = CancelAsync(), "停止生成");
            action = stop;
        }
        else
        {
            // 发送钮是这一页唯一的黑色：有内容时墨黑，否则 #C9C9C3
            var send = new Border { Width = 32, Height = 32, CornerRadius = new CornerRadius(16), Background = Brush(CanSend ? Txt : Hex(0xC9C9C3)), Child = Icon("arrow.up", 13, White).Align(HorizontalAlignment.Center, VerticalAlignment.Center) };
            send.OnTap(() => _ = SendAsync(_draft), "发送", () => CanSend);
            input.TextChanged += (_, _) => send.Background = Brush(CanSend ? Txt : Hex(0xC9C9C3));
            action = send;
        }
        var row = Columns(12, (Star(), input), (GridLength.Auto, ((FrameworkElement)action).Align(v: VerticalAlignment.Bottom)));
        _inputBox = new Border
        {
            Child = row, Padding = new Thickness(18, 12, 12, 12), MinHeight = 57, Background = Brush(White), CornerRadius = new CornerRadius(17.5),
            BorderBrush = Brush(Hex(0xD6D6D0)), BorderThickness = new Thickness(1),
        };
        return _inputBox;
    }

    /// <summary>
    /// 对话输入框（Mac `ChatInputField`）：14 号字，回车发送、Shift + 回车换行、输入法组字时回车照常确认；
    /// Esc 依次收起弹层 / @ 列表 / 快捷命令；Ctrl + V 粘贴图片或文件时走附件。
    /// </summary>
    TextBox ChatInputField(string placeholder)
    {
        var box = new TextBox
        {
            Text = _draft, PlaceholderText = placeholder, FontSize = 14, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
            BorderThickness = new Thickness(0), Background = Brush(Clear), Padding = new Thickness(0, 6, 0, 0), MinHeight = 32, MaxHeight = 132,
            PlaceholderForeground = Brush(Faint), IsSpellCheckEnabled = false, FontFamily = SansFamily,
        };
        Quiet(box.Resources);
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Auto);
        AutomationProperties.SetName(box, "告诉助手你想完成什么");
        _input = box;
        var composing = false;
        box.TextCompositionStarted += (_, _) => composing = true;
        box.TextCompositionEnded += (_, _) => composing = false;
        box.TextChanged += (_, _) =>
        {
            var before = SlashMatches().Count;
            var mentionBefore = MentionQuery;
            _draft = box.Text;
            if (!_draft.StartsWith('/')) _slashDismissed = false;
            if (!_draft.Contains('@')) _mentionDismissed = false;
            if (_draft.EndsWith('@')) _ = LoadContextsAsync().ContinueWith(_ => DispatcherQueue.TryEnqueue(() => _floatingPanel?.Refresh()), TaskScheduler.Default);
            var mention = MentionQuery;
            if (mention is not null && _floating != Floating.Mention) ShowFloating(Floating.Mention);
            else if (mention is null && _floating == Floating.Mention) CloseFloating();
            else if (mention != mentionBefore) _floatingPanel?.Refresh();
            // 快捷命令列表出现 / 消失时重建，其余情况只改发送钮颜色
            if (SlashMatches().Count != before) Render();
        };
        box.PreviewKeyDown += async (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape)
            {
                if (_floating is not null) { e.Handled = true; if (_floating == Floating.Mention) _mentionDismissed = true; CloseFloating(); }
                else if (SlashMatches().Count > 0) { e.Handled = true; _slashDismissed = true; Render(); }
                return;
            }
            var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (ctrl && e.Key == Windows.System.VirtualKey.V)
            {
                var content = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
                if (content.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems) || content.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Bitmap))
                { e.Handled = true; await PasteAsync(); }
                return;
            }
            if (e.Key != Windows.System.VirtualKey.Enter || composing) return;
            var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (shift) return;
            e.Handled = true;
            if (SlashMatches().FirstOrDefault() is { id: not null } first) RunSlash(first.id);
            else if (MentionQuery is { } query && _contextGroups.SelectMany(g => g.Items("items"))
                         .FirstOrDefault(i => query.Length == 0 || i.Text("label").Contains(query, StringComparison.OrdinalIgnoreCase)) is { } hit) PickMention(hit);
            else if (CanSend) await SendAsync(_draft);
        };
        return box;
    }

    // MARK: 附件

    /// <summary>输入框里待发送的附件（02B·06 / 08 F）：图片 56×56 缩略图，其余文件卡；失败时细边变红、下面写「重试」。</summary>
    FrameworkElement AttachmentStrip()
    {
        var stack = new StackPanel { Spacing = 4 };
        var flow = new VariableSizedFlow(8);
        foreach (var shot in _attachments.ToList())
        {
            var cell = new Grid();
            FrameworkElement body;
            if (shot.Kind == "image" && shot.Data is { Length: > 0 } data)
            {
                var bitmap = new BitmapImage();
                using (var stream = new MemoryStream(data)) bitmap.SetSource(stream.AsRandomAccessStream());
                body = new Border
                {
                    Width = 56, Height = 56, CornerRadius = new CornerRadius(8), BorderBrush = Brush(shot.Status == ChatAttachment.States.Failed ? Red : Cl), BorderThickness = new Thickness(1),
                    Background = new ImageBrush { ImageSource = bitmap, Stretch = Stretch.UniformToFill },
                };
                body.OnTap(() => OpenPreview(shot.Tab), $"预览 {shot.Label}");
                if (shot.Status == ChatAttachment.States.Uploading) cell.Children.Add(new ProgressRing { Width = 14, Height = 14, IsActive = true });
            }
            else
            {
                var detail = shot.Status switch
                {
                    ChatAttachment.States.Uploading => "正在上传…",
                    ChatAttachment.States.Failed => "上传失败",
                    _ => string.Join(" · ", new[] { shot.Kind == "audio" ? "录音" : Path.GetExtension(shot.Label).TrimStart('.').ToUpperInvariant(), FileSize(shot.Size) }.Where(x => x.Length > 0)),
                };
                body = AttachmentCard(shot.Label, FileSymbol(shot.Label, shot.Kind), detail, shot.Status == ChatAttachment.States.Failed);
            }
            cell.Children.Insert(0, body);
            var remove = new Border
            {
                Width = 15, Height = 15, CornerRadius = new CornerRadius(7.5), Background = Brush(White), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
                Child = Icon("xmark.circle.fill", 13, Fnt), RenderTransform = new TranslateTransform { X = 5, Y = -5 },
            };
            remove.OnTap(() => RemoveAttachment(shot), $"移除附件 {shot.Label}");
            cell.Children.Add(remove);
            flow.Add(cell);
        }
        stack.Children.Add(flow.Panel);
        foreach (var shot in _attachments.Where(a => a.Error is not null))
        {
            var id = shot.Id;
            stack.Children.Add(HStack(6, Sans($"{shot.Label}：{shot.Error}", 11.5, Red), Sans("重试", 11.5, Red).OnTap(() => _ = UploadAsync(id), "重试")));
        }
        return stack;
    }

    /// <summary>添加附件：与 Web 同样的类型与数量限制，选好就上传到当前对话（还没有会话时先建会话）。</summary>
    void AddFiles(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return;
        if (Sending) { _notice = "请等待当前请求完成后添加附件。"; Render(); return; }
        if (!paths.All(p => AgentAttachments.Extensions.Contains(Path.GetExtension(p).TrimStart('.').ToLowerInvariant())))
        { _notice = "支持图片、PDF、DOCX、MD、TXT，以及 MP3、WAV、M4A、OGG、WebM 录音。"; Render(); return; }
        var sizes = paths.Select(p => new FileInfo(p).Exists ? new FileInfo(p).Length : 0).ToList();
        var total = _attachments.Sum(a => a.Size) + sizes.Sum();
        if (_attachments.Count + paths.Count > AgentAttachments.MaxFiles || !sizes.All(s => s is > 0 and <= AgentAttachments.MaxBytes) || total > AgentAttachments.MaxTotalBytes)
        { _notice = "最多添加 10 个附件，单个不超过 10 MiB，合计不超过 30 MiB。"; Render(); return; }
        _notice = null;
        var drafts = paths.Select(p => new ChatAttachment
        {
            Id = Guid.NewGuid().ToString("D"), Label = Path.GetFileName(p), File = p,
            Data = AgentAttachments.Kind(Path.GetFileName(p)) == "image" ? TryRead(p) : null,
        }).ToList();
        _attachments.AddRange(drafts);
        Render();
        _ = Task.Run(async () => { foreach (var draft in drafts) await DispatchAsync(() => UploadAsync(draft.Id)); });
    }

    static byte[]? TryRead(string path) { try { return File.ReadAllBytes(path); } catch { return null; } }

    Task DispatchAsync(Func<Task> work)
    {
        var done = new TaskCompletionSource();
        DispatcherQueue.TryEnqueue(async () => { try { await work(); } finally { done.SetResult(); } });
        return done.Task;
    }

    async Task UploadAsync(string id)
    {
        if (_attachments.FirstOrDefault(a => a.Id == id) is not { } shot || Api is not HttpApiClient client) return;
        shot.Status = ChatAttachment.States.Uploading;
        shot.Error = null;
        Render();
        try
        {
            var sessionId = await EnsureSessionAsync();
            var bytes = await File.ReadAllBytesAsync(shot.File);
            AgentAttachments.Validate(shot.Label, bytes.Length);
            var result = await client.Coordinator.UploadAgentAttachmentAsync(sessionId, shot.Label, bytes, shot.Id);
            var attachment = result.Get("attachment") ?? result;
            if (_attachments.FirstOrDefault(a => a.Id == id) is not { } current)
            {
                // 上传期间被移除：删掉服务端的附件
                try { await Api.CareerRequestAsync($"/api/agent/sessions/{sessionId}/attachments/{attachment.Text("id")}", "DELETE"); } catch { }
                return;
            }
            var uploaded = attachment.Text("status") is "ready" or "uploaded" or "";
            current.AttachmentId = attachment.Text("id");
            current.Status = uploaded ? ChatAttachment.States.Ready : ChatAttachment.States.Failed;
            current.Error = uploaded ? null : "上传失败，请重试。";
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            if (_attachments.FirstOrDefault(a => a.Id == id) is { } current) { current.Status = ChatAttachment.States.Failed; current.Error = AgentAttachments.ErrorMessage(error); }
        }
        Render();
    }

    void RemoveAttachment(ChatAttachment shot)
    {
        _attachments.RemoveAll(a => a.Id == shot.Id);
        _previewTabs.RemoveAll(t => t.Key == shot.Tab.Key);
        if (_previewTabs.Count == 0) _previewOpen = false;
        if (shot.AttachmentId is { } attachment && _currentId is { } current)
            _ = Task.Run(async () =>
            {
                try { await Api.CareerRequestAsync($"/api/agent/sessions/{current}/attachments/{attachment}", "DELETE"); }
                catch (Exception error) { DispatcherQueue.TryEnqueue(() => { _notice = AgentErrors.Message(error); Render(); }); }
            });
        Render();
    }

    /// <summary>剪贴板或截图得到的图片先写成私有临时 PNG，再走同一条上传路径。</summary>
    async Task AddImageDataAsync(Windows.Storage.Streams.IRandomAccessStreamReference reference, string label)
    {
        try
        {
            var directory = DatasetUpload.PrivateDirectory();
            var path = Path.Combine(directory, Guid.NewGuid() + "-" + label);
            using (var source = await reference.OpenReadAsync())
            await using (var target = File.Create(path))
                await source.AsStreamForRead().CopyToAsync(target);
            AddFiles([path]);
        }
        catch { _notice = "图片读取失败。"; Render(); }
    }

    async Task PasteAsync()
    {
        var content = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
        if (content.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems))
        {
            var items = await content.GetStorageItemsAsync();
            var files = items.OfType<Windows.Storage.StorageFile>().Select(f => f.Path).ToList();
            if (files.Count > 0) { AddFiles(files); return; }
        }
        if (content.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Bitmap)) { await AddImageDataAsync(await content.GetBitmapAsync(), "粘贴的截图.png"); return; }
        _notice = "剪贴板里没有图片或文件。";
        Render();
    }

    async Task PickFilesAsync()
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        foreach (var extension in AgentAttachments.Extensions) picker.FileTypeFilter.Add("." + extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        var files = await picker.PickMultipleFilesAsync();
        AddFiles(files.Select(f => f.Path).ToList());
    }

    // MARK: 动作

    async Task OpenAsync()
    {
        _currentId = _sessionId;
        if (_sessionId is null) _ = LoadGreetingAsync();
        try
        {
            var readiness = TryAsync(() => Api.CareerRequestAsync("/api/agent/readiness"));
            var model = TryAsync(() => Api.CareerRequestAsync("/api/agent/model"));
            await Task.WhenAll(readiness, model);
            _ready = readiness.Result.Get("ready") is JsonValue flag && flag.GetValueKind() is System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False
                ? flag.Bool() : readiness.Result is null ? null : false;
            if (readiness.Result.Get("steering") is JsonValue steering) _steering = steering.Bool();
            _modelName = model.Result.Get("model").Text("name").NonEmpty();
            if (await TryAsync(() => Api.CareerRequestAsync("/api/agent/models")) is { } list)
            {
                _models = list.Items("models");
                _modelId = (_sessionId is null ? _initialModelId : null) ?? list.Text("defaultModelId").NonEmpty() ?? model.Result.Get("model").Text("id").NonEmpty();
            }
            Render();
            if (_sessionId is { } id)
            {
                await ReloadAsync(id);
                if (await TryAsync(() => Api.CareerRequestAsync($"/api/agent/sessions/{id}/active-run")) is { } active && active.Get("run").Text("run_id") is { Length: > 0 } run)
                    await StreamAsync($"/api/agent/runs/{run}/events", "GET", null, id);
            }
            if (_initialMessage is { } initial && !_consumedInitial && initial.Trim().Length > 0)
            {
                _consumedInitial = true;
                await SendAsync(initial);
            }
            else if (_initialDraft is { } draft && !_consumedInitial && _draft.Length == 0)
            {
                _consumedInitial = true;
                _draft = draft;
                Render();
            }
            await LoadContextsAsync();
        }
        catch (Exception error) { _error = AgentErrors.Message(error); Render(); }
    }

    static async Task<JsonNode?> TryAsync(Func<Task<JsonNode>> request) { try { return await request(); } catch { return null; } }

    async Task ReloadAsync(string id)
    {
        try
        {
            var result = await Api.CareerRequestAsync($"/api/agent/sessions/{id}");
            if (_currentId != id) return;
            var session = result.Get("session");
            _messages = session.Items("messages");
            _title = session.Text("title").NonEmpty() ?? "新对话";
            _contextUsage = session.Get("context_usage");
            if (session.Get("selected_model_id").String() is { } selected) _modelId = selected;
            if (await TryAsync(() => Api.CareerRequestAsync("/api/agent/proposals", "GET", new() { ["session_id"] = id })) is { } list && _currentId == id)
                _proposals = list.Items("proposals");
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            if (_currentId == id) _error = AgentErrors.Message(error);
        }
        Render();
    }

    async Task LoadContextsAsync()
    {
        if (_contextGroups.Count > 0 || await TryAsync(() => Api.CareerRequestAsync("/api/agent/contexts", "GET", new() { ["limit"] = "50" })) is not { } result) return;
        var groups = result.Items("groups");
        if (groups.Count > 0) { _contextGroups = groups; return; }
        var flat = result.Items("contexts");
        var types = flat.Select(c => c.Text("type")).Distinct().ToList();
        _contextGroups = types.Select(type => (JsonNode)new JsonObject { ["type"] = type, ["items"] = new JsonArray(flat.Where(c => c.Text("type") == type).Select(c => c.DeepClone()).ToArray()) }).ToList();
    }

    async Task<string> EnsureSessionAsync()
    {
        if (_currentId is { } current) return current;
        var body = _modelId is { } model ? new JsonObject { ["modelId"] = model } : new JsonObject();
        var result = await Api.CareerRequestAsync("/api/agent/sessions", "POST", body: body);
        var id = result.Get("session").Text("id").NonEmpty() ?? throw new InvalidDataException();
        _currentId = id;
        _title = result.Get("session").Text("title").NonEmpty() ?? "新对话";
        Shell.WorkspaceShell.Current.ReloadSessions();
        return id;
    }

    async Task SendAsync(string text, int? replyTo = null, JsonArray? clarificationAnswers = null)
    {
        var content = text.Trim();
        if (replyTo is null && _attachments.Any(a => a.Status != ChatAttachment.States.Ready))
        {
            _notice = _attachments.Any(a => a.Status == ChatAttachment.States.Uploading) ? "附件还在上传，请稍候。" : "有附件没有上传成功，请重试或移除。";
            Render();
            return;
        }
        if (Sending && _steering && _runId is { } running && content.Length > 0) { await SteerAsync(content, running); return; }
        if (content.Length == 0 || Sending) return;
        Sending = true;
        _error = null; _streaming = ""; _status = null; _creditBlock = null;
        var attached = _contexts.ToList();
        Render();
        try
        {
            var id = await EnsureSessionAsync();
            var body = new JsonObject { ["content"] = content, ["idempotency_key"] = Guid.NewGuid().ToString("D") };
            if (attached.Count > 0)
                body["contexts"] = new JsonArray(attached.Select(item =>
                {
                    var reference = new JsonObject { ["type"] = item.Text("type"), ["id"] = item.Text("id"), ["presentation"] = "mention" };
                    if (item.Text("version_id").Length > 0) reference["version_id"] = item.Text("version_id");
                    return (JsonNode)reference;
                }).ToArray());
            var files = replyTo is null ? _attachments.ToList() : [];
            if (files.Count > 0) body["attachment_ids"] = new JsonArray(files.Select(f => f.AttachmentId).OfType<string>().Select(x => (JsonNode)x).ToArray());
            if (replyTo is { } reply) body["reply_to_sequence_no"] = reply;
            if (clarificationAnswers is not null) body["clarification_answers"] = clarificationAnswers;
            _draft = ""; _contexts = []; _answers.Clear();
            if (replyTo is null) _attachments = [];
            var sentFiles = new JsonArray(files.Select(f => (JsonNode)new JsonObject { ["file_name"] = f.Label, ["kind"] = f.Kind, ["file_size"] = f.Size }).ToArray());
            _messages.Add(new JsonObject { ["role"] = "user", ["content"] = content, ["contexts"] = new JsonArray(attached.Select(c => c.DeepClone()).ToArray()), ["attachments"] = sentFiles });
            _stickToBottom = true;
            await StreamAsync($"/api/agent/sessions/{id}/messages", "POST", body, id);
        }
        catch (Exception error)
        {
            Sending = false;
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            if (error is ApiException { Code: "CREDIT_INSUFFICIENT" or "PAID_CREDIT_REQUIRED" } credit)
            {
                _creditBlock = (credit.Code == "CREDIT_INSUFFICIENT" ? "exhausted" : "model", content);
                if (_messages.LastOrDefault() is { } last && last.Text("role") == "user" && last.Text("content") == content) _messages.RemoveAt(_messages.Count - 1);
                Render();
                return;
            }
            _error = AgentErrors.Message(error);
            Render();
        }
    }

    /// <summary>编辑最后一条消息（02B·08 E）：`POST …/messages/{seq}:edit`，这条之后的回复会被新的回复替换。</summary>
    async Task SubmitEditAsync(int index)
    {
        if (_currentId is not { } id || index >= _messages.Count || Sending || _messages[index].Number("sequence_no") is not { } seq) return;
        var content = _editDraft.Trim();
        if (content.Length == 0) return;
        var original = _messages[index];
        _editingIndex = null; _error = null; _streaming = ""; _status = null; _creditBlock = null;
        _messages = _messages.Take(index).Append(new JsonObject
        {
            ["role"] = "user", ["content"] = content,
            ["contexts"] = original["contexts"]?.DeepClone() ?? new JsonArray(), ["attachments"] = original["attachments"]?.DeepClone() ?? new JsonArray(),
        }).ToList();
        _stickToBottom = true;
        await StreamAsync($"/api/agent/sessions/{id}/messages/{(int)seq}:edit", "POST",
            new JsonObject { ["content"] = content, ["idempotency_key"] = Guid.NewGuid().ToString("D") }, id);
    }

    async Task StreamAsync(string path, string method, JsonNode? body, string id)
    {
        if (Api is not HttpApiClient client) return;
        Sending = true;
        _phaseStarted = DateTimeOffset.Now;
        _live = new ProcessSnapshot { Started = _phaseStarted };
        _processExpanded = false;
        _streamCancel = new CancellationTokenSource();
        Render();
        try
        {
            await client.Coordinator.StreamAgentAsync(path, method, body, frame =>
            {
                if (AgentEvent.Parse(frame) is not { } agentEvent) return Task.FromResult(false);
                DispatcherQueue.TryEnqueue(() => { if (_currentId == id) Handle(agentEvent); });
                return Task.FromResult(agentEvent.IsTerminal);
            }, _streamCancel.Token);
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            if (_currentId == id) _error = AgentErrors.Message(error);
        }
        finally
        {
            if (_runId is { } run && _processes.TryGetValue(run, out var snapshot) && snapshot.Ended is null) snapshot.Ended = DateTimeOffset.Now;
            Sending = false; _runId = null; _status = null;
        }
        _streaming = "";
        if (_currentId == id) await ReloadAsync(id);
        Shell.WorkspaceShell.Current.ReloadSessions();
        Render();
    }

    /// <summary>准备过程：同一份改动同时记在当前显示（`_live`）和按 runId 保留的快照里。</summary>
    void UpdateProcess(Action<ProcessSnapshot> change)
    {
        change(_live);
        if (_runId is not { } run) return;
        if (!_processes.TryGetValue(run, out var snapshot)) _processes[run] = snapshot = new ProcessSnapshot { Started = _phaseStarted };
        change(snapshot);
    }

    void Handle(AgentEvent agentEvent)
    {
        var data = agentEvent.Data;
        if (_runId is null && data.Text("runId").Length > 0) _runId = data.Text("runId");
        switch (agentEvent.Type)
        {
            case "run.phase": _status = data.Text("label").NonEmpty() ?? _status; break;
            case "assistant.activity.status":
            {
                var key = data.Text("callKey");
                if (key.Length == 0) { _status = data.Text("label").NonEmpty() ?? _status; break; }
                var activity = new ProcessSnapshot.Activity(key, data.Text("label"), data.Text("status").NonEmpty() ?? "running", data.Text("summary"));
                UpdateProcess(snapshot => snapshot.Apply(activity));
                break;
            }
            case "assistant.activity.delta":
            {
                var delta = data.Text("delta");
                UpdateProcess(snapshot => snapshot.AppendText(delta));
                break;
            }
            case "assistant.activity.clear": _live = new ProcessSnapshot { Started = _phaseStarted }; _processExpanded = false; break;
            case "tool.started": if (_live.Activities.Count == 0) _status = "正在调用工具…"; break;
            case "assistant.delta": _streaming += data.Text("delta"); break;
            case "assistant.message.completed":
            {
                var message = new JsonObject { ["role"] = "assistant", ["content"] = data.Text("content"), ["sequence_no"] = data.Get("sequenceNo")?.DeepClone(), ["run_id"] = _runId ?? "" };
                if (data.Get("clarification") is { } clarification) message["clarification"] = clarification.DeepClone();
                if (data.Get("cards") is { } cards) message["cards"] = cards.DeepClone();
                _messages.Add(message);
                _streaming = "";
                if (_runId is { } run && _processes.TryGetValue(run, out var snapshot)) snapshot.Ended = DateTimeOffset.Now;
                break;
            }
            case "clarification.requested":
            {
                var index = _messages.FindLastIndex(m => m.Text("role") == "assistant");
                if (index >= 0 && _messages[index] is JsonObject fields) fields["clarification"] = data.Get("clarification")?.DeepClone();
                break;
            }
            case "proposal.created": if (data.Get("proposal") is { } proposal) _proposals.Add(proposal.DeepClone()); break;
            case "context.usage" or "context.compaction.completed":
            {
                var window = data.Get("contextWindow") ?? _contextUsage.Get("context_window");
                _contextUsage = new JsonObject
                {
                    ["tokens"] = data.Get("tokens")?.DeepClone(), ["context_window"] = window?.DeepClone(), ["breakdown"] = (data.Get("breakdown") ?? _contextUsage.Get("breakdown"))?.DeepClone(),
                };
                break;
            }
            case "context.compaction.started": _status = "正在压缩上下文…"; break;
            case "user.message.rejected": _error = AgentErrors.Message(new ApiException(System.Net.HttpStatusCode.Conflict, data.Text("error"))); break;
            case "run.failed":
            {
                var code = data.Text("error");
                if (code is "CREDIT_INSUFFICIENT" or "PAID_CREDIT_REQUIRED" && _messages.LastOrDefault(m => m.Text("role") == "user") is { } last)
                    _creditBlock = (code == "CREDIT_INSUFFICIENT" ? "exhausted" : "model", last.Text("content"));
                else _error = AgentErrors.Message(new ApiException(System.Net.HttpStatusCode.InternalServerError, code));
                break;
            }
            case "run.cancelled":
                _status = null;
                if (_streaming.Length > 0) { _messages.Add(new JsonObject { ["role"] = "assistant", ["content"] = _streaming + "\n\n（已停止生成）" }); _streaming = ""; }
                break;
        }
        Render();
    }

    async Task AnswerClarificationAsync(JsonNode message, IReadOnlyList<JsonNode> questions)
    {
        string Value(JsonNode question)
        {
            var id = question.Text("id");
            var answer = _answers.GetValueOrDefault(id);
            return answer == "__other__" ? (_otherAnswers.GetValueOrDefault(id) ?? "").Trim() : question.Items("options").FirstOrDefault(o => o.Text("id") == answer)?.Text("label") ?? "";
        }
        var text = string.Join("\n", questions.Select(q => $"{q.Text("header")}：{Value(q)}"));
        var payload = new JsonArray(questions.Select(question =>
        {
            var id = question.Text("id");
            var item = new JsonObject { ["question_id"] = id, ["option_id"] = _answers.GetValueOrDefault(id) ?? "" };
            if (_answers.GetValueOrDefault(id) == "__other__") item["value"] = (_otherAnswers.GetValueOrDefault(id) ?? "").Trim();
            return (JsonNode)item;
        }).ToArray());
        _clarificationPage = 0;
        _otherAnswers.Clear();
        await SendAsync(text, (int?)message.Number("sequence_no"), payload);
    }

    async Task<bool> DecideAsync(JsonNode proposal, bool confirm)
    {
        var id = proposal.Text("id");
        if (_proposalBusy is not null) return false;
        _proposalBusy = id;
        Render();
        try
        {
            await Api.CareerRequestAsync($"/api/agent/proposals/{id}/{(confirm ? "confirm" : "reject")}", "POST");
            if (_proposals.FirstOrDefault(p => p.Text("id") == id) is JsonObject fields) fields["status"] = confirm ? "applied" : "rejected";
            _error = null;
            return true;
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            // 简历刚被改过：这一处标“没能采用”，原位换成「按现在的内容重写」
            if (error is ApiException { Code: "AGENT_PROPOSAL_CONFLICT" } && _proposals.FirstOrDefault(p => p.Text("id") == id) is JsonObject conflicted)
            {
                conflicted["status"] = "conflicted";
                return false;
            }
            _error = AgentErrors.Message(error);
            if (_currentId is { } current) await ReloadAsync(current);
            return false;
        }
        finally { _proposalBusy = null; Render(); }
    }

    /// <summary>插话：`POST /api/agent/runs/{id}/steer`，回执的应用结果随当前流的 `user.message.applied/rejected` 返回。</summary>
    async Task SteerAsync(string content, string runId)
    {
        try
        {
            await Api.CareerRequestAsync($"/api/agent/runs/{runId}/steer", "POST", body: new JsonObject { ["content"] = content, ["idempotency_key"] = Guid.NewGuid().ToString("D") });
            _draft = "";
            _messages.Add(new JsonObject { ["role"] = "user", ["content"] = content });
            _status = "已插入，将在当前步骤后处理";
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            _error = AgentErrors.Message(error);
        }
        Render();
    }

    async Task ChooseModelAsync(JsonNode model)
    {
        var id = model.Text("id");
        if (id == _modelId) return;
        var previous = _modelId;
        _modelId = id;
        Render();
        if (_currentId is not { } current) return;
        try { await Api.CareerRequestAsync($"/api/agent/sessions/{current}", "PATCH", body: new JsonObject { ["modelId"] = id }); }
        catch (Exception error) { _modelId = previous; _error = AgentErrors.Message(error); Render(); }
    }

    /// <summary>压缩上下文（Web `compactConversation`）：流式执行，结束后刷新会话与用量。</summary>
    async Task CompactAsync()
    {
        if (_currentId is not { } current || Sending) return;
        _status = "正在压缩上下文…";
        _error = null;
        await StreamAsync($"/api/agent/sessions/{current}/compact", "POST", new JsonObject { ["idempotency_key"] = Guid.NewGuid().ToString("D") }, current);
    }

    void NewConversation()
    {
        _currentId = null; _messages = []; _proposals = []; _streaming = ""; _error = null; _title = "新对话";
        _attachments = []; _contexts = []; _contextUsage = null; _processes.Clear(); _live = new ProcessSnapshot(); _editingIndex = null;
        Shell.WorkspaceShell.Current.NewChat();
    }

    async Task CancelAsync()
    {
        if (_runId is not { } run) return;
        try { await Api.CareerRequestAsync($"/api/agent/runs/{run}/cancel", "POST"); } catch { }
    }

    /// <summary>保存 AI 文档到资料库：Windows ContentDialog 样式的对话框。</summary>
    void ShowSaveDocument(string content)
    {
        V3Overlay.Show(XamlRoot, close => new SaveDocumentDialog(content, DocumentTitle(content) ?? "AI 文档", close, () => { _savedDocuments.Add(content); Render(); }));
    }
}
