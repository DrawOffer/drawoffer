using DrawOffer.App.DesignSystem;
using static DrawOffer.App.DesignSystem.V3;
using System.Text.Json.Nodes;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using DrawOffer.Core.Session;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace DrawOffer.App.Views;

public sealed partial class DatasetLibraryPage
{
    async Task<bool> Login(){if(SignedIn)return true;_pending=true;await DrawOffer.App.Shell.WorkspaceShell.Current.RequestLoginAsync(reason:"登录后管理你的资料；游客也可查看资料库界面。");return false;}
    V3Overlay? _overlay;
    async Task<bool> Dialog(string title, UIElement content, string primary, Func<Task> save)
    {
        if (_busy || _overlay is not null || _disposed) return false;
        var owner = AccountStamp; var completion = new TaskCompletionSource<bool>(); var ok = false;
        var error = T("", 12); error.Foreground = Brush(Red);
        var body = VStack(20, Serif(title, 20).Wrap(), content, error);
        _overlay = V3Overlay.Show(XamlRoot, close =>
        {
            V3Button? submit = null;
            var cancel = B("取消", () => { if (!_busy) close(); });
            submit = new V3Button(primary, () => _ = Save(), title.StartsWith("删除") || title.StartsWith("永久删除") ? V3Button.Kind.Danger : V3Button.Kind.Dark);
            async Task Save()
            {
                if (_busy) return; _busy = true; body.IsHitTestVisible = false; submit!.Enabled = cancel.Enabled = false; submit.Title = "处理中…";
                try { await save(); if (_disposed || owner != AccountStamp) throw new OperationCanceledException(); ok = true; close(); }
                catch (OperationCanceledException) { close(); }
                catch (Exception ex) { error.Text = Explain(ex); }
                finally { if (owner == AccountStamp && !_disposed) { _busy = false; body.IsHitTestVisible = true; submit.Enabled = cancel.Enabled = true; submit.Title = primary; } }
            }
            return LibraryDialog(body, [cancel, submit], () => { if (!_busy) close(); }, title == "管理关联" ? 540 : title.Contains("移动") || title == "从资料库选择" ? 520 : 440);
        }, dismissible: false, dismissed: () => { _overlay = null; completion.TrySetResult(ok); });
        var result = await completion.Task;
        if (!_disposed && owner == AccountStamp) { if (result) await Task.WhenAll(Load(true), LoadJobs(), LoadStorage()); else Render(); }
        return result;
    }
    static Border LibraryDialog(UIElement body, UIElement[] actions, Action close, double width)
    {
        var inset = width <= 500 ? 20 : 32;
        var content = new Border { Child = body, Padding = new Thickness(inset, width <= 500 ? 24 : 28, inset, 32) };
        var footer = HStack(10, actions); footer.Padding = new Thickness(inset, 0, inset, 0); footer.Height = 88; footer.VerticalAlignment = VerticalAlignment.Center;
        if (width > 500) footer.HorizontalAlignment = HorizontalAlignment.Right;
        var layout = new Grid(); layout.RowDefinitions.Add(new()); layout.RowDefinitions.Add(new() { Height = GridLength.Auto });
        layout.Children.Add(new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        var foot = new Border { Child = footer, BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 1, 0, 0) }; Grid.SetRow(foot, 1); layout.Children.Add(foot);
        var x = V3Dialog.CloseButton(close).Align(HorizontalAlignment.Right, VerticalAlignment.Top).Pad(0, width <= 500 ? 20 : 26, width <= 500 ? 16 : 26, 0); layout.Children.Add(x);
        return V3Dialog.Frame(layout, width);
    }
    async Task Rename(string kind, JsonNode? item = null)
    {
        if (!await Login()) return;
        var project = kind is "folder" or "create";
        var field = new TextBox { Text = project ? S(item, "name") : S(item, "file_name"), PlaceholderText = kind == "create" ? "例如：系统设计复习、英文简历与求职信" : "", MaxLength = project ? 64 : 255, FontFamily = SansFamily, FontSize = 13, Height = 40 };
        var about = new TextBox { AcceptsReturn = true, MaxLength = 500, Height = 60, FontFamily = SansFamily, FontSize = 13 };
        var content = Stack(T(kind == "create" ? "把同一件事的资料放进一个项目，例如一次面试冲刺或一份作品集。" : project ? "只修改项目名称，项目内的资料不受影响。" : "只修改资料显示名称，不改变文件格式或已保存的内容。", 14, true), T(project ? "项目名称" : "资料名称", 14), field);
        if (kind == "create") { content.Children.Add(T("项目说明（可选）", 14)); content.Children.Add(about); }
        await Dialog(kind == "create" ? "新建项目" : project ? "重命名项目" : "重命名资料", content, kind == "create" ? "创建项目" : "保存名称", async () =>
        {
            var name = field.Text.Trim(); if (name.Length == 0) throw new InvalidOperationException(project ? "项目名称不能为空" : "资料名称不能为空");
            if (project && (name.Contains('/') || name.Contains('\\'))) throw new InvalidOperationException("项目名称不能包含斜杠符号");
            var body = new JsonObject { ["name"] = name }; if (kind == "create" && about.Text.Trim().Length > 0) body["description"] = about.Text.Trim();
            await Request(kind == "create" ? "/api/datasets/folders" : project ? "/api/datasets/folders/" + S(item, "id") : "/api/datasets/" + S(item, "id"), kind == "create" ? "POST" : "PATCH", body);
        });
    }
    void EditDescription(JsonNode folder)
    {
        var draft = new TextBox { Text = S(folder, "description"), MaxLength = 500, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 116, FontFamily = SansFamily, FontSize = 14 };
        var count = T($"{draft.Text.Length}/500", 11, true); draft.TextChanged += (_, _) => count.Text = $"{draft.Text.Length}/500";
        var owner = AccountStamp;
        var cancel = B("取消", Render); V3Button? saveButton = null;
        saveButton = B("保存", () => _ = Save(), true);
        var editor = Stack(draft, Row(count, cancel, saveButton));
        async Task Save()
        {
            if (_busy || _disposed || owner != AccountStamp) return;
            _busy = true; draft.IsEnabled = false; cancel.Enabled = saveButton!.Enabled = false; saveButton.Title = "正在保存…";
            try { await Request("/api/datasets/folders/" + S(folder, "id"), "PATCH", new JsonObject { ["description"] = draft.Text.Trim() }); _notice = "项目说明已保存。"; }
            catch (OperationCanceledException) { return; }
            catch (Exception ex) { if (owner == AccountStamp) _error = Explain(ex); }
            finally { if (owner == AccountStamp && !_disposed) _busy = false; }
            if (owner == AccountStamp && !_disposed) await Load(true);
        }
        draft.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Escape) { e.Handled = true; Render(); } else if (e.Key == Windows.System.VirtualKey.Enter && Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down)) { e.Handled = true; _ = Save(); } };
        var index = _head.Children.ToList().FindIndex(x => x is Border border && border.BorderThickness.Left == 2);
        if (index >= 0) { _head.Children.RemoveAt(index); _head.Children.Insert(index, editor.Top(14)); }
    }
    async Task PickExisting()
    {
        var target = _folder; var picked = new HashSet<string>();
        var candidates = _files.Where(x => x.Folder != target && x.Text("interview_session_id").Length == 0 && x.Text("upload_status") == "succeeded").ToList();
        var search = new V3SearchField("搜索资料…", width: null, height: 30); var list = new StackPanel { Spacing = 6 }; var labels = Labels;
        void Draw(string query) { list.Children.Clear(); foreach (var item in candidates.Where(x => x.Name.Contains(query, StringComparison.OrdinalIgnoreCase))) { var check = new CheckBox { Content = item.Name + " · " + labels.GetValueOrDefault(item.Id, "未归入"), IsChecked = picked.Contains(item.Id), MinHeight = 48 }; check.Click += (_, _) => { if (check.IsChecked == true) picked.Add(item.Id); else picked.Remove(item.Id); }; list.Children.Add(check); } if (list.Children.Count == 0) list.Children.Add(T("资料库里没有可以移入的资料", 12, true)); }
        search.Changed += Draw; Draw("");
        await Dialog("从资料库选择", Stack(T("选中的资料会移到「" + Title + "」。", 14, true), search, new ScrollViewer { Content = list, MaxHeight = 300 }), "移入项目", async () => { if (picked.Count == 0) throw new InvalidOperationException("请选择资料"); await Request("/api/datasets/move-batch", "POST", new JsonObject { ["folder_id"] = target, ["dataset_ids"] = new JsonArray(picked.Order().Select(x => (JsonNode?)JsonValue.Create(x)).ToArray()) }); });
    }
    async Task Move()
    {
        var ids = _selected.Order().ToArray(); var current = ids.Length == 1 ? _files.FirstOrDefault(x => x.Id == ids[0])?.Folder : null; var destination = "";
        var list = new StackPanel { Spacing = 6 };
        foreach (var folder in _folders.Where(x => S(x, "id") != current)) { var id = S(folder, "id"); var option = new RadioButton { GroupName = "dataset-destination", Content = S(folder, "name") + " · " + folder.Integer("dataset_count") + " 份", MinHeight = 38 }; option.Checked += (_, _) => destination = id; list.Children.Add(option); }
        if (list.Children.Count == 0) list.Children.Add(T("还没有其他项目", 12, true));
        await Dialog(ids.Length == 1 ? "移动资料到项目" : $"移动 {ids.Length} 份资料到项目", Stack(T($"已选择 {ids.Length} 份资料 · 选择目标项目", 14, true), T("选择目标分类", 11, true), new ScrollViewer { Content = list, MaxHeight = 228 }), "确定移动", async () => { if (!DatasetRequest.Id(destination)) throw new InvalidOperationException("请选择目标项目"); await Request("/api/datasets/move-batch", "POST", new JsonObject { ["folder_id"] = destination, ["dataset_ids"] = new JsonArray(ids.Select(x => (JsonNode?)JsonValue.Create(x)).ToArray()) }); _selected.Clear(); });
    }
    async Task DeleteFolder(JsonNode folder)
    {
        var count = folder.Integer("dataset_count");
        await Dialog("删除项目「" + S(folder, "name") + "」及其中的资料？", T(count > 0 ? $"项目里的 {count} 份资料会和项目一起永久删除（包括源文件和解析结果），无法恢复。想保留的资料，请先移到其他项目。" : "这个项目里没有资料，删除后无法恢复。", 14, true).Wrap(), count > 0 ? "连同资料一起删除" : "确认删除", async () => { await Request("/api/datasets/folders/" + S(folder, "id"), "DELETE", query: new() { ["confirm_contents"] = "true" }); });
    }
    async Task DeleteFiles()
    {
        var items = _files.Where(x => _selected.Contains(x.Id)).ToArray();
        if (items.Length == 0) return;
        if (items.Any(x => x.Busy)) { _error = "资料正在处理，暂时不能删除或替换。"; Render(); return; }
        await Dialog(items.Length == 1 ? "永久删除「" + items[0].Name + "」？" : $"永久删除所选资料（{items.Length} 份）？", Stack(T(items.Length == 1 ? "删除后将移除源文件、解析结果和资料记录，且无法恢复。" : $"将删除所选 {items.Length} 份资料，移除源文件、解析结果和资料记录，且无法恢复。", 13, true).Wrap(), items.Length > 1 ? new ScrollViewer { Content = T(string.Join("\n", items.Select(x => x.Name)), 12, true).Wrap(), MaxHeight = 160 } : new Border()), items.Length == 1 ? "永久删除" : "永久删除所选", async () =>
        {
            List<string> failures = []; var removed = 0;
            foreach (var item in items.Where(x => _selected.Contains(x.Id))) { try { await Request("/api/datasets/" + item.Id, "DELETE"); _selected.Remove(item.Id); removed++; } catch (OperationCanceledException) { throw; } catch (Exception ex) { failures.Add(item.Name + "：" + Explain(ex)); } }
            _notice = $"已删除 {removed} 份资料"; await Load();
            if (failures.Count > 0) throw new InvalidOperationException(string.Join("；", failures));
        });
    }
    async Task Associate(DatasetRecord item)
    {
        if (_busy || _overlay is not null || _disposed) return;
        var associationOwner = AccountStamp;
        try
        {
            var sessions = await Pages("/api/interview-sessions", new() { ["limit"] = "500" });
            var old = item.Text("interview_session_id"); var next = old;
            var search = new V3SearchField("搜索公司、岗位或轮次…", width: null, height: 38); var list = new StackPanel { Spacing = 8 };
            void Draw(string query)
            {
                list.Children.Clear();
                foreach (var session in sessions.OrderByDescending(x => S(x, "id") == old).ThenByDescending(x => S(x, "start_at")).Where(x => (S(x, "company_name") + " " + S(x, "job_title") + " " + S(x, "stage_label")).Contains(query, StringComparison.OrdinalIgnoreCase)))
                {
                    var id = S(session, "id");
                    var option = new RadioButton { GroupName = "dataset-association", IsChecked = next == id, Content = Stack(T(S(session, "company_name") + " · " + S(session, "job_title"), 13), T(SessionMeta(session) + (id == old ? " · 当前" : ""), 11, true)), MinHeight = 50 };
                    option.Checked += (_, _) => next = id; list.Children.Add(option);
                }
                if (list.Children.Count == 0) list.Children.Add(T(query.Length == 0 ? "还没有面试安排，可以先在投递看板里添加" : "没有匹配的面试", 12, true));
            }
            search.Changed += Draw; Draw("");
            var content = Stack(AssociationArt(item), T("「" + item.Name + "」可以关联到一场面试，关联后在求职记录里也能看到它。", 14, true), search, T("选择要关联的面试                         一份资料只能关联一场", 11, true), new ScrollViewer { Content = list, Height = 240 });
            if (old.Length > 0) content.Children.Add(B("取消关联", () => _ = Unlink()));
            async Task Unlink() { if (_busy || associationOwner != AccountStamp || _disposed) return; _busy = true; try { await Request("/api/interview-sessions/" + old + "/assets/" + item.Id, "DELETE"); old = next = ""; _notice = "旧关联已解除"; _overlay?.Close(); await Task.WhenAll(Load(true), LoadJobs()); } catch (OperationCanceledException) { } catch (Exception ex) { if (associationOwner == AccountStamp) _error = Explain(ex); } finally { if (associationOwner == AccountStamp && !_disposed) { _busy = false; Render(); } } }
            content.Children.Add(T("换场次先解除旧关联；新关联失败时旧关联不会自动恢复。", 12, true));
            await Dialog("管理关联", content, "保存", async () =>
            {
                if (old.Length > 0 && old != next) { await Request("/api/interview-sessions/" + old + "/assets/" + item.Id, "DELETE"); old = ""; _notice = "旧关联已解除"; }
                if (next.Length > 0 && next != old) { await Request("/api/interview-sessions/" + next + "/assets/attach", "POST", new JsonObject { ["dataset_id"] = item.Id }); old = next; }
            });
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { _error = Explain(ex); Render(); }
    }
    static string SessionMeta(JsonNode session)
    {
        var date = CareerApplication.Date(S(session, "start_at"))?.ToBeijing();
        var when = date is {} value ? value.ToString("MM-dd") + " 周" + "日一二三四五六"[(int)value.DayOfWeek] + " " + value.ToString("HH:mm") : "";
        var tail = S(session, "status") switch { "completed" => "已完成", "cancelled" => "已取消", _ => S(session, "location").NonEmpty() ?? (S(session, "mode") switch { "video" => "视频面试", "onsite" => "现场", "phone" => "电话", "other" => "其他", _ => "" }) };
        return string.Join(" · ", new[] { S(session, "stage_label"), when, tail }.Where(x => x.Length > 0));
    }
    UIElement PreviewMeta(DatasetRecord item) => Row(T(item.Format + " · " + JobProjects.Size(item.Raw.Number("file_size") ?? 0) + " · 上传于 " + Date(item.Text("created_at")), 12, true), T(item.Text("interview_label").Length == 0 ? "" : "已关联：面试 · " + item.Text("interview_label"), 12, true), B("管理关联", () => { _overlay?.Close(); _ = Associate(item); }));
    async Task Open(DatasetRecord item)
    {
        if (_busy || _overlay is not null) return;
        if (!item.Ready) { _notice = item.Status + "，暂时无法预览。"; Render(); return; }
        if (item.Media) { await Media(item); return; }
        var owner = AccountStamp; var completion = new TaskCompletionSource();
        var preview = new StackPanel(); preview.Children.Add(T("正在读取解析结果…", 13, true));
        var panel = Stack(Serif(item.Name, 20).Wrap(), PreviewMeta(item), new Border { Background = Brush(Stage), CornerRadius = new CornerRadius(11), Padding = new Thickness(24), Height = 612, Child = V3.Card(new ScrollViewer { Content = preview }, 6, new Thickness(32, 28, 32, 28)) }, B("下载原文件", () => _ = Download(item)));
        _overlay = V3Overlay.Show(XamlRoot, close => V3Dialog.Make(panel, [B("关闭", close)], close, 820), dismissed: () => { _overlay = null; completion.TrySetResult(); });
        var overlay = _overlay;
        async Task Read()
        {
            try { var result = await Request("/api/datasets/" + item.Id + "/content"); if (owner != AccountStamp || overlay != _overlay) return; preview.Children.Clear(); preview.Children.Add(NativeMarkdownView.Render(S(result, "markdown"))); }
            catch (OperationCanceledException) { }
            catch (Exception ex) { if (owner == AccountStamp && overlay == _overlay) { preview.Children.Clear(); preview.Children.Add(T(Explain(ex), 13, true)); preview.Children.Add(B("重新加载", () => _ = Read())); } }
        }
        await Read(); await completion.Task;
    }
    async Task Media(DatasetRecord item)
    {
        DatasetFile? file = null; Windows.Media.Playback.MediaPlayer? player = null; var owner = AccountStamp;
        var completion = new TaskCompletionSource(); var body = new StackPanel { Spacing = 12 }; body.Children.Add(T("正在读取音频…", 14, true));
        var panel = Stack(Serif(item.Name, 20).Wrap(), PreviewMeta(item), body, B("下载文件", () => _ = Download(item)));
        if (item.Text("asset_kind") == "audio" && !item.Raw.Bool("has_transcript")) panel.Children.Add(Stack(T("音频转文字", 16), T(item.Text("parse_status") switch { "queued" => "等待转写", "processing" => "正在转写…", "failed" => item.Text("failure_reason") switch { "service_unavailable" => "语音识别服务未配置或暂不可用，请检查模型设置后重试。", "content_invalid" => "未识别到有效语音，请检查音频后重试。", "size_exceeded" => "音频超过语音服务大小限制；AIHubMix 单次转写最多支持 25 MB。", _ => "转写失败，请稍后重试。" }, _ => "这份音频还没有文字稿，可以在网页版资料库开始转写。" }, 14, true)));
        _overlay = V3Overlay.Show(XamlRoot, close => V3Dialog.Make(panel, [B("关闭", close)], close, 820), dismissed: () => { player?.Dispose(); player = null; file?.Discard(); file = null; _overlay = null; completion.TrySetResult(); });
        var overlay = _overlay;
        try
        {
            var downloaded = await App.Session.Api.DownloadDatasetAsync(item.Id, MediaLimit, _life.Token);
            if (_disposed || owner != AccountStamp || overlay != _overlay) { downloaded.Discard(); return; }
            file = downloaded;
            var playable = Path.Combine(file.Directory, "preview." + item.Format.ToLowerInvariant()); File.Move(file.File, playable);
            var source = await Windows.Storage.StorageFile.GetFileFromPathAsync(playable);
            if (_disposed || owner != AccountStamp || overlay != _overlay) return;
            player = new() { Source = Windows.Media.Core.MediaSource.CreateFromStorageFile(source) };
            var element = new MediaPlayerElement { AreTransportControlsEnabled = true, Height = item.Text("asset_kind") == "audio" ? 80 : 380 }; element.SetMediaPlayer(player); body.Children.Clear(); body.Children.Add(element);
            await completion.Task;
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (owner == AccountStamp && overlay == _overlay) { body.Children.Clear(); body.Children.Add(T(Explain(ex), 14, true)); await completion.Task; } }
        finally { player?.Dispose(); file?.Discard(); }
    }
    async Task Download(DatasetRecord item){if(_busy||_disposed||App.NativeWindow is not {} window)return;var picker=new Windows.Storage.Pickers.FileSavePicker{SuggestedFileName=Path.GetFileNameWithoutExtension(item.Name)};var extension=Path.GetExtension(item.Name);if(extension.Length==0&&item.Format.Length>0)extension="."+item.Format.ToLowerInvariant();picker.FileTypeChoices.Add(item.Format.NonEmpty()??"文件",new List<string>{extension.Length>0?extension:".bin"});WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(window));var owner=AccountStamp;var destination=await picker.PickSaveFileAsync();if(destination is null||owner!=AccountStamp||_disposed)return;await Act(async()=>{var file=await App.Session.Api.DownloadDatasetAsync(item.Id,MediaLimit,_life.Token);try{if(owner!=AccountStamp)throw new OperationCanceledException();File.Copy(file.File,destination.Path,true);_notice="已保存「"+item.Name+"」";}finally{file.Discard();}});}
    IEnumerable<string> Extensions=>Items(_limits?["allowed_extensions"]).Concat(Items(_limits?["media_allowed_extensions"])).Select(x=>x.GetValue<string>().TrimStart('.'));
    async Task Pick(){if(_busy||!DatasetRequest.Id(_folder)||!await Login()||App.NativeWindow is not {} window)return;var picker=new Windows.Storage.Pickers.FileOpenPicker();var extensions=Extensions.ToArray();foreach(var extension in extensions.Length>0?extensions:new[]{"pdf","docx","md","txt","webm","m4a","mp3","wav","ogg","mp4","mov"})picker.FileTypeFilter.Add("."+extension);WinRT.Interop.InitializeWithWindow.Initialize(picker,WinRT.Interop.WindowNative.GetWindowHandle(window));var folder=_folder;var owner=AccountStamp;var chosen=await picker.PickMultipleFilesAsync();if(!_disposed&&owner==AccountStamp)await Enqueue(chosen.Select(x=>x.Path),folder);}
    async Task Enqueue(IEnumerable<string> paths,string folder){var owner=AccountStamp;foreach(var path in paths.Take(Math.Max(0,Batch-_queue.Count(x=>x.Status!="accepted")))){try{var media=new[]{"webm","m4a","mp3","wav","ogg","mp4","mov"}.Contains(Path.GetExtension(path).TrimStart('.').ToLowerInvariant());var limit=media?MediaLimit:Math.Min(MediaLimit,_limits?["max_file_bytes"]?.GetValue<long>()??20L*1024*1024);var upload=await Task.Run(()=>DatasetUpload.Snapshot(path,folder,limit));if(_life.IsCancellationRequested||owner!=AccountStamp||_queue.Count(x=>x.Status!="accepted")>=Batch){upload.Discard();return;}_queue.Add(new(upload));}catch(Exception e){if(!_life.IsCancellationRequested&&owner==AccountStamp)_error=Explain(e);}}Render();}
    void Queue(){var content=Stack(T("上传队列",17),B("上传 / 重试",()=>_=Upload(),true));foreach(var item in _queue){var controls=Row(T(item.Upload.Name),T((S(_folders.FirstOrDefault(x=>S(x,"id")==item.Upload.Folder),"name").NonEmpty()??"项目")+" · "+item.Message,12,true));if(item.Status=="conflict"){controls.Children.Add(B("保留两份",()=>_=KeepBoth(item)));var existing=_files.FirstOrDefault(x=>x.Folder==item.Upload.Folder&&x.Name.Normalize()==item.Upload.Name.Normalize()&&x.Text("asset_kind")=="document");if(existing is not null)controls.Children.Add(B("替换…",()=>_=Replace(item,existing)));}if(item.Status!="uploading")controls.Children.Add(B(item.Status=="accepted"?"关闭":"移出",()=>{item.Upload.Discard();_queue.Remove(item);Render();}));content.Children.Add(controls);}content.Children.Add(T("目标文件夹已固定。结果不确定时沿用原标识重试；退出账号或离开资料库会清理临时文件。",11,true));_results.Children.Add(V3.Card(content,14,new Thickness(20),Hex(0xF7F7F4)));}
    async Task KeepBoth(Queued item){var field=new TextBox{Text=item.Upload.Name};await Dialog("保留两份",Stack(T("请为新文件设置不同名称"),field),"保存",()=>{var ext=Path.GetExtension(item.Upload.Name);var name=field.Text.EndsWith(ext,StringComparison.OrdinalIgnoreCase)?field.Text:field.Text+ext;item.Upload=item.Upload with{Id=Guid.NewGuid().ToString("D"),Name=name};item.Status="selected";item.Message="等待重新上传";return Task.CompletedTask;});}
    async Task Replace(Queued item,DatasetRecord existing)=>await Dialog("替换现有文档？",Stack(T("确认替换「"+existing.Name+"」？旧原文件和解析结果永久删除，无法恢复；保留资料 ID、文件夹和面试关联。")),"确认替换",()=>{item.Upload=item.Upload with{Id=Guid.NewGuid().ToString("D"),Replacing=existing.Id,Revision=existing.Text("content_revision"),Name=existing.Name};item.Status="selected";item.Message="已确认替换，等待上传";return Task.CompletedTask;});
    async Task Upload(){if(_busy||_disposed)return;await Act(async()=>{var owner=AccountStamp;foreach(var item in _queue.Where(x=>x.Status is "selected" or "unknown" or "rejected").ToArray()){_life.Token.ThrowIfCancellationRequested();item.Status="uploading";item.Message="正在上传…";Render();try{await App.Session.Api.UploadDatasetAsync(item.Upload,_life.Token);if(owner!=AccountStamp)throw new OperationCanceledException();item.Status="accepted";item.Message="服务器已接受";item.Upload.Discard();}catch(OperationCanceledException){throw;}catch(Exception e){if(owner!=AccountStamp)throw new OperationCanceledException();if(e is ApiException api&&(int)api.Status is >=400 and <500){item.Status=api.Code.Contains("CONFLICT")?"conflict":"rejected";item.Upload=item.Upload with{Id=Guid.NewGuid().ToString("D")};item.Message=Explain(e);}else{item.Status="unknown";item.Message="结果尚未确认；重试沿用原标识。";}}}});await Load(true);}
    async Task Act(Func<Task> work){if(_busy||!SignedIn)return;var owner=AccountStamp;_busy=true;_error="";Render();try{await work();}catch(OperationCanceledException){}catch(Exception e){if(owner==AccountStamp)_error=Explain(e);}finally{if(owner==AccountStamp&&!_life.IsCancellationRequested){_busy=false;Render();}}await Load(true);}
    static string Date(string s)=>DateTimeOffset.TryParse(s,out var d)?d.ToBeijing().ToString("yyyy-MM-dd"):"—";
    static string Explain(Exception error) => error is ApiException api ? api.Code switch
    {
        "FOLDER_NAME_CONFLICT" or "FOLDER_NAME_DUPLICATE" => "文件夹名称已存在。",
        "DATASET_NAME_CONFLICT" or "DATASET_FILENAME_CONFLICT" => "同一文件夹已有同名文件，请选择保留两份或确认替换。",
        "DATASET_CONTENT_CONFLICT" or "PRECONDITION_FAILED" => "资料已更新，请刷新后重新确认替换。",
        "DATASET_BUSY" or "DATASET_IN_PROGRESS" => "资料正在处理，暂时不能删除或替换。",
        "DATASET_NOT_RETRYABLE" => "只有解析失败的文档可重新解析。",
        "DATASET_FILE_TOO_LARGE" => "文件超出上传限制。",
        "INVALID_DATASET_NAME" => "名称无效，请去除路径符号或控制字符。",
        "INVALID_FOLDER_DESCRIPTION" => "项目说明最多 500 字，且不能包含特殊控制字符",
        "DATASET_ALREADY_LINKED" => "已关联其他面试，请刷新后重试。",
        "FOLDER_NOT_FOUND" => "文件夹已不存在，请刷新后选择。",
        "DATASET_NOT_FOUND" => "资料已不存在或不可访问。",
        "ASSET_DELETE_FAILED" => "原文件清理失败，请刷新确认后重试。",
        _ => (int)api.Status == 401 ? "登录已失效，请重新登录。" : $"操作未完成（{api.Code}）。请刷新确认状态后再试。"
    } : error is InvalidOperationException ? error.Message : error is IOException ? "文件操作失败，请确认权限或连接后刷新。" : "连接失败，结果尚未确认。请刷新或沿用原标识重试。";
}
