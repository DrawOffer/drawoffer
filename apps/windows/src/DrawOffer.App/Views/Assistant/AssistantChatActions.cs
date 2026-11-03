using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Agent;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Assistant;

public sealed partial class AssistantChatView
{
    // MARK: 快捷命令

    /// <summary>输入框里以 / 开头的快捷命令（Web `slashCommands.ts`），只列出当前对话能执行的。</summary>
    List<(string id, string label, string detail, string symbol)> SlashCommands()
    {
        (string, string, string, string)[] all =
        [
            ("compact", "整理较早对话", "把较早的对话整理成摘要，腾出上下文", "clock.arrow.circlepath"),
            ("context", "查看上下文用量", "看看离自动整理还有多远、用在了哪里", "gauge.with.dots.needle.33percent"),
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
        switch (id)
        {
            case "compact": _ = CompactAsync(); break;
            case "context": _usageOpen = true; break;
            case "ref": ShowReferencePicker(); break;
            case "upload": _ = PickFilesAsync(); break;
            default: NewConversation(); break;
        }
        Render();
    }

    // MARK: 输入框

    FrameworkElement Composer()
    {
        var stack = new StackPanel { Spacing = 8, MaxWidth = 900 };
        var matches = SlashMatches();
        if (matches.Count > 0)
        {
            var menu = new StackPanel { Spacing = 2 };
            foreach (var command in matches)
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Height = 30, Padding = new Thickness(10, 0, 10, 0) };
                row.Children.Add(Icon(command.symbol, 13, Sub).Frame(16).Align(v: VerticalAlignment.Center));
                row.Children.Add(Number("/" + command.id, 12.5, Fnt, Regular).Align(v: VerticalAlignment.Center));
                row.Children.Add(Sans(command.label, 13).Align(v: VerticalAlignment.Center));
                row.Children.Add(Sans(command.detail, 11.5, Fnt).Align(v: VerticalAlignment.Center));
                var id = command.id;
                menu.Children.Add(MenuRow(row, () => RunSlash(id), command.label));
            }
            stack.Children.Add(new Border { Child = menu, Padding = new Thickness(4), Background = Brush(V3.White), CornerRadius = new CornerRadius(10), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1) });
        }
        if (_attachments.Count > 0) stack.Children.Add(AttachmentStrip());
        if (_contexts.Count > 0)
        {
            var flow = new VariableSizedFlow(6);
            foreach (var item in _contexts.ToList())
            {
                var remove = Icon("xmark", 8, Txt).Align(v: VerticalAlignment.Center).OnTap(() => { _contexts.Remove(item); Render(); }, $"移除 {item.Text("label")}");
                flow.Add(new Border { Child = HStack(4, Sans(item.Text("label"), 12).Align(v: VerticalAlignment.Center), remove), Padding = new Thickness(8, 0, 8, 0), Height = 24, Background = Brush(BlueSoft), CornerRadius = new CornerRadius(6) });
            }
            stack.Children.Add(flow.Panel);
        }

        // `.assistant-input`：最小 58 高、#d6d6d0 描边、圆角 18、内边距 12/12/12/18；32 的发送钮在输入框里，生成中换成停止
        var input = ChatInputField(_ready == false ? "AI 助手暂未开放" : "继续提问或说明调整要求…");
        var lines = Math.Max(1, _draft.Split('\n').Length);
        input.Root.Height = Math.Min(132, 32 + (lines - 1) * 22);
        UIElement action;
        if (Sending && _runId is not null)
        {
            var stop = new Grid { Width = 32, Height = 32 };
            stop.Children.Add(new Border { CornerRadius = new CornerRadius(16), Background = Brush(Txt) });
            stop.Children.Add(new Border { Width = 10, Height = 10, CornerRadius = new CornerRadius(2), Background = Brush(V3.White) });
            stop.OnTap(() => _ = CancelAsync(), "停止生成");
            action = stop;
        }
        else
        {
            var send = new Border { Width = 32, Height = 32, CornerRadius = new CornerRadius(16), Background = Brush(CanSend ? Txt : Hex(0xC9C9C3)), Child = Icon("arrow.up", 13, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center) };
            send.OnTap(() => _ = SendAsync(_draft), "发送", () => CanSend);
            input.Box.TextChanged += (_, _) => send.Background = Brush(CanSend ? Txt : Hex(0xC9C9C3));
            action = send;
        }
        var row2 = Columns(12, (Star(), input.Root), (GridLength.Auto, ((FrameworkElement)action).Align(v: VerticalAlignment.Bottom)));
        stack.Children.Add(new Border
        {
            Child = row2, Padding = new Thickness(18, 12, 12, 12), MinHeight = 58, Background = Brush(V3.White), CornerRadius = new CornerRadius(18),
            BorderBrush = Brush(Hex(0xD6D6D0)), BorderThickness = new Thickness(1),
        });

        // `.assistant-composer-foot`：距输入框 8、22 高；左「＋ 添加资料」12.5px，右侧上下文用量与模型，间距 16
        var add = HStack(6, Icon("plus", 10, Sub), Sans("添加资料", 12.5, Sub).Align(v: VerticalAlignment.Center));
        add.OnTap(() => ShowAddMenu(add), "添加资料", () => !Sending);
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        left.Children.Add(add);
        if (_notice is { } notice) left.Children.Add(Sans(notice, 11.5, V3.Orange).Wrap(2).Align(v: VerticalAlignment.Center));
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        if (ContextUsageRing.Make(_contextUsage, CurrentModelName, _usageOpen, open => _usageOpen = open, Sending || _currentId is null, () => _ = CompactAsync()) is { } ring) right.Children.Add(ring);
        right.Children.Add(new ModelPicker(_models, _modelId, id => { if (_models.FirstOrDefault(m => m.Text("id") == id) is { } model) _ = ChooseModelAsync(model); }, disabled: Sending).Align(v: VerticalAlignment.Center));
        var foot = Columns(10, (Star(), left), (GridLength.Auto, right));
        foot.Height = 22;
        foot.Margin = new Thickness(12, 0, 10, 0);
        stack.Children.Add(foot);
        return stack;
    }

    static Border MenuRow(FrameworkElement content, Action action, string name)
    {
        // Mac `MenuRowStyle`（`.v3-menu-item:hover`）：悬停 #F4F4F2、6 圆角
        var row = new Border { Child = content, CornerRadius = new CornerRadius(6), Background = Brush(Clear) };
        row.OnHover(on => row.Background = Brush(on ? Field : Clear));
        row.OnTap(action, name);
        return row;
    }

    void ShowAddMenu(FrameworkElement anchor)
    {
        _ = LoadContextsAsync();
        var panel = new StackPanel { Width = 260 - 12 };
        Flyout? flyout = null;
        var upload = Columns(10, (Px(16), Icon("plus", 13, Txt)), (Star(), Sans("上传文件", 14)), (GridLength.Auto, Sans("图片、文档和录音", 11, Sub)));
        upload.Padding = new Thickness(10);
        panel.Children.Add(MenuRow(upload, () => { flyout?.Hide(); _ = PickFilesAsync(); }, "上传文件"));
        var reference = Columns(10, (Px(16), Icon("folder", 13, Txt)), (Star(), Sans("引用已有资料", 14)));
        reference.Padding = new Thickness(10);
        panel.Children.Add(MenuRow(reference, () => { flyout?.Hide(); ShowReferencePicker(); }, "引用已有资料"));
        flyout = V3Popover.Show(anchor, panel, Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Top);
    }

    /// <summary>
    /// 对话输入框（Mac `ChatInputField`）：14px 系统字体，回车发送、Shift + 回车换行、输入法组字时回车照常确认；
    /// Esc 收起快捷命令；Ctrl + V 粘贴图片或文件时走附件。
    /// </summary>
    (Grid Root, TextBox Box) ChatInputField(string placeholder)
    {
        var box = new TextBox
        {
            Text = _draft, PlaceholderText = placeholder, FontSize = 14, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
            BorderThickness = new Thickness(0), Background = Brush(Clear), Padding = new Thickness(0, 6, 0, 0), MinHeight = 0,
            PlaceholderForeground = Brush(Fnt2), IsSpellCheckEnabled = false,
        };
        foreach (var key in new[] { "TextControlBackgroundPointerOver", "TextControlBackgroundFocused", "TextControlBorderBrushFocused", "TextControlBorderBrushPointerOver" })
            box.Resources[key] = Brush(Clear);
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Hidden);
        AutomationProperties.SetName(box, "告诉助手你想完成什么");
        _input = box;
        var composing = false;
        box.TextCompositionStarted += (_, _) => composing = true;
        box.TextCompositionEnded += (_, _) => composing = false;
        box.TextChanged += (_, _) =>
        {
            var before = SlashMatches().Count;
            var lineCount = _draft.Split('\n').Length;
            _draft = box.Text;
            if (!_draft.StartsWith('/')) _slashDismissed = false;
            // 快捷命令列表出现 / 消失或行数变化时重建，其余情况只改发送钮颜色
            if (SlashMatches().Count != before || _draft.Split('\n').Length != lineCount) Render();
        };
        box.PreviewKeyDown += async (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape && SlashMatches().Count > 0) { e.Handled = true; _slashDismissed = true; Render(); return; }
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
            else if (CanSend) await SendAsync(_draft);
        };
        var root = new Grid { MinHeight = 32, MaxHeight = 132 };
        root.Children.Add(box);
        return (root, box);
    }

    // MARK: 附件

    FrameworkElement AttachmentStrip()
    {
        var stack = new StackPanel { Spacing = 4 };
        var flow = new VariableSizedFlow(6);
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
                    Width = 52, Height = 52, CornerRadius = new CornerRadius(8), BorderBrush = Brush(shot.Status == ChatAttachment.States.Failed ? Red : Cl), BorderThickness = new Thickness(1),
                    Background = new ImageBrush { ImageSource = bitmap, Stretch = Stretch.UniformToFill },
                };
                body.OnTap(() => OpenPreview(shot.Tab), $"预览 {shot.Label}");
                if (shot.Status == ChatAttachment.States.Uploading) cell.Children.Add(new ProgressRing { Width = 14, Height = 14, IsActive = true });
            }
            else
            {
                var texts = new StackPanel { Spacing = 1 };
                texts.Children.Add(Sans(shot.Label, 12).Also(t => t.MaxWidth = 160));
                if (shot.Status == ChatAttachment.States.Uploading) texts.Children.Add(Sans("正在上传…", 10.5, Fnt));
                else if (shot.Kind == "audio") texts.Children.Add(Sans("录音", 10.5, Fnt));
                body = new Border
                {
                    Child = HStack(6, Icon(shot.Kind == "audio" ? "mic" : "folder", 15, Sub).Align(v: VerticalAlignment.Center), texts.Align(v: VerticalAlignment.Center)),
                    Padding = new Thickness(10, 0, 10, 0), Height = 52, Background = Brush(Field), CornerRadius = new CornerRadius(8),
                    BorderBrush = Brush(shot.Status == ChatAttachment.States.Failed ? Red : Clear), BorderThickness = new Thickness(1),
                };
            }
            cell.Children.Insert(0, body);
            var remove = new Border
            {
                Width = 15, Height = 15, CornerRadius = new CornerRadius(7.5), Background = Brush(V3.White), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
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
            stack.Children.Add(HStack(6, Sans($"{shot.Label}：{shot.Error}", 11.5, Red), Sans("重试", 11.5, Link).OnTap(() => _ = UploadAsync(id), "重试")));
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
        try
        {
            var readiness = TryAsync(() => Api.CareerRequestAsync("/api/agent/readiness"));
            var model = TryAsync(() => Api.CareerRequestAsync("/api/agent/model"));
            await Task.WhenAll(readiness, model);
            _ready = readiness.Result?.Get("ready") is JsonValue flag && flag.GetValueKind() is System.Text.Json.JsonValueKind.True or System.Text.Json.JsonValueKind.False
                ? flag.Bool() : readiness.Result is null ? null : false;
            if (readiness.Result?.Get("steering") is JsonValue steering) _steering = steering.Bool();
            _modelName = model.Result?.Get("model").Text("name").NonEmpty();
            if (await TryAsync(() => Api.CareerRequestAsync("/api/agent/models")) is { } list)
            {
                _models = list.Items("models");
                _modelId = (_sessionId is null ? _initialModelId : null) ?? list.Text("defaultModelId").NonEmpty() ?? model.Result?.Get("model").Text("id").NonEmpty();
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
            if (_revisionProposalId is { } revision) { body["revision_proposal_id"] = revision; _revisionProposalId = null; }
            if (clarificationAnswers is not null) body["clarification_answers"] = clarificationAnswers;
            _draft = ""; _contexts = []; _answers.Clear();
            if (replyTo is null) _attachments = [];
            var sentFiles = new JsonArray(files.Select(f => (JsonNode)new JsonObject { ["file_name"] = f.Label, ["kind"] = f.Kind }).ToArray());
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

    async Task StreamAsync(string path, string method, JsonNode? body, string id)
    {
        if (Api is not HttpApiClient client) return;
        Sending = true;
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
        finally { Sending = false; _runId = null; _status = null; }
        _streaming = "";
        if (_currentId == id) await ReloadAsync(id);
        Shell.WorkspaceShell.Current.ReloadSessions();
        Render();
    }

    void Handle(AgentEvent agentEvent)
    {
        var data = agentEvent.Data;
        if (_runId is null && data.Text("runId").Length > 0) _runId = data.Text("runId");
        switch (agentEvent.Type)
        {
            case "run.phase" or "assistant.activity.status": _status = data.Text("label").NonEmpty() ?? _status; break;
            case "tool.started": _status = "正在调用工具…"; break;
            case "assistant.delta": _streaming += data.Text("delta"); break;
            case "assistant.message.completed":
            {
                var message = new JsonObject { ["role"] = "assistant", ["content"] = data.Text("content"), ["sequence_no"] = data.Get("sequenceNo")?.DeepClone() };
                if (data.Get("clarification") is { } clarification) message["clarification"] = clarification.DeepClone();
                _messages.Add(message);
                _streaming = "";
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
                _contextUsage = new JsonObject { ["tokens"] = data.Get("tokens")?.DeepClone(), ["context_window"] = window?.DeepClone(), ["breakdown"] = (data.Get("breakdown") ?? _contextUsage.Get("breakdown"))?.DeepClone() };
                break;
            }
            case "context.compaction.started": _status = "正在整理较早对话…"; break;
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

    async Task ApplyAllAsync(string key, IReadOnlyList<JsonNode> items)
    {
        var pending = items.Where(p => p.Text("status") == "pending").ToList();
        if (pending.Count <= 1 || _batchProgress is not null || _proposalBusy is not null || Sending) return;
        _batchProgress = (key, 0, pending.Count);
        Render();
        try
        {
            for (var index = 0; index < pending.Count; index++)
            {
                if (!await DecideAsync(pending[index], true)) break;
                _batchProgress = (key, index + 1, pending.Count);
                Render();
            }
        }
        finally { _batchProgress = null; Render(); }
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

    /// <summary>整理较早对话（Web `compactConversation`）：流式执行，结束后刷新会话与用量。</summary>
    async Task CompactAsync()
    {
        if (_currentId is not { } current || Sending) return;
        _status = "正在整理较早对话…";
        _error = null;
        await StreamAsync($"/api/agent/sessions/{current}/compact", "POST", new JsonObject { ["idempotency_key"] = Guid.NewGuid().ToString("D") }, current);
    }

    void NewConversation()
    {
        _currentId = null; _messages = []; _proposals = []; _streaming = ""; _error = null; _title = "新对话";
        _attachments = []; _contexts = []; _contextUsage = null;
        Render();
    }

    async Task CancelAsync()
    {
        if (_runId is not { } run) return;
        try { await Api.CareerRequestAsync($"/api/agent/runs/{run}/cancel", "POST"); } catch { }
    }

    // MARK: 弹窗

    void ShowReferencePicker()
    {
        _ = LoadContextsAsync().ContinueWith(_ => DispatcherQueue.TryEnqueue(() =>
            V3Overlay.Show(XamlRoot, close => ReferencePicker.Make(_contextGroups, _contexts, ContextTypeLabel, picked =>
            {
                foreach (var item in picked) if (!_contexts.Any(c => c.ToJsonString() == item.ToJsonString())) _contexts.Add(item);
                Render();
            }, close))), TaskScheduler.Default);
    }

    void ShowSaveDocument()
    {
        if (_savingDocument is not { } content) return;
        var saved = content;
        V3Overlay.Show(XamlRoot, close => new SaveDocumentDialog(content, DocumentTitle(content) ?? "AI 文档", () => { _savingDocument = null; close(); },
            () => { _savedDocuments.Add(saved); Render(); }), dismissed: () => _savingDocument = null);
    }
}
