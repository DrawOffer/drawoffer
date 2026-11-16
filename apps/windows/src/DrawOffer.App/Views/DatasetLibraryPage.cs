using System.ComponentModel;
using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Shell;
using DrawOffer.App.Views.Career;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using DrawOffer.Core.Session;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views;

/// <summary>Mac DatasetLibraryView V4：项目双页签、全部文件与求职进程共用资料页。</summary>
public sealed partial class DatasetLibraryPage : Page
{
    readonly Grid _root = new();
    readonly StackPanel _head = new(), _results = new();
    readonly ScrollViewer _scroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    readonly CancellationTokenSource _life = new();
    List<DatasetRecord> _files = [];
    List<JsonNode> _folders = [], _applications = [], _sessions = [];
    JsonNode? _limits, _storage;
    readonly HashSet<string> _selected = [];
    readonly List<Queued> _queue = [];
    string _folder = "", _tab = "mine", _query = "", _error = "", _notice = "", _jobState = "loading", _sort = "recent";
    string _owner = "";
    bool _loaded, _busy, _pending, _batch, _disposed;
    int _generation, _accountEpoch, _toastVersion;
    Border? _toast;
    string AccountStamp => _accountEpoch + ":" + Account;
    sealed class Queued(DatasetUpload upload) { public DatasetUpload Upload = upload; public string Status = "selected", Message = "等待上传"; }
    static string S(JsonNode? n, string key) => n.Display(key);
    static List<JsonNode> Items(JsonNode? n) => n is JsonArray a ? a.OfType<JsonNode>().ToList() : [];
    static TextBlock T(string text, double size = 13, bool muted = false) => Sans(text, size, muted ? Fnt : Txt);
    static StackPanel Stack(params UIElement[] items) => VStack(12, items);
    static StackPanel Row(params UIElement[] items) => HStack(12, items);
    static Border Card(UIElement child) => V3.Card(child, 14, new Thickness(16));
    V3Button B(string label, Action action, bool dark = false) => new(label, action, dark ? V3Button.Kind.Dark : V3Button.Kind.Ghost) { Enabled = !_busy };
    bool SignedIn => App.Session.Phase == SessionViewModel.SessionPhase.SignedIn;
    string Account => SignedIn ? App.Session.User?.Id ?? "" : "";
    string Title => _folder == "" ? "资料库" : _folder == "files" ? "全部文件" : S(CurrentFolder, "name");
    JsonNode? CurrentFolder => _folders.FirstOrDefault(x => S(x, "id") == _folder);
    long MediaLimit => Math.Min(512L * 1024 * 1024, (long)(_limits.Number("max_media_file_bytes") ?? 500L * 1024 * 1024));
    int Batch => Math.Max(1, (int)(_limits.Number("max_files_per_batch") ?? 10));
    IEnumerable<DatasetRecord> Visible => _files.Where(x => (_folder == "files" || x.Folder == _folder) && x.Name.Contains(_query, StringComparison.OrdinalIgnoreCase));
    List<JobProjects.Project> Projects => JobProjects.Build(_applications, _sessions, _files);
    List<JobProjects.Project> Listed => Projects.Where(x => x.DatasetCount > 0 || x.RecordCount > 0).ToList();
    Dictionary<string, string> Labels { get { var labels = JobProjects.Labels(Projects); foreach (var item in _files) labels.TryAdd(item.Id, S(_folders.FirstOrDefault(x => S(x, "id") == item.Folder), "name").NonEmpty() ?? item.Text("interview_label").NonEmpty() ?? "未归入"); return labels; } }

    public DatasetLibraryPage()
    {
        Content = _root;
        _root.RowDefinitions.Add(new() { Height = GridLength.Auto }); _root.RowDefinitions.Add(new());
        _scroll.Content = _results; Grid.SetRow(_scroll, 1);
        SizeChanged += (_, _) => Fit();
        Loaded += async (_, _) => { _owner = Account; App.Session.PropertyChanged += Changed; Render(); await Task.WhenAll(Load(true), LoadJobs(), LoadStorage()); };
        Unloaded += (_, _) => { _disposed = true; ++_generation; _life.Cancel(); _overlay?.Close(); App.Session.PropertyChanged -= Changed; ClearQueue(); };
        AllowDrop = true;
        DragOver += (_, e) => { if (!_busy && SignedIn && DatasetRequest.Id(_folder)) e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy; };
        Drop += async (_, e) => { if (_busy || !SignedIn || !DatasetRequest.Id(_folder) || !e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return; var folder = _folder; var owner = AccountStamp; var files = await e.DataView.GetStorageItemsAsync(); if (owner == AccountStamp && !_disposed) await Enqueue(files.OfType<Windows.Storage.StorageFile>().Select(x => x.Path), folder); };
    }
    void Fit() { var width = Math.Max(0, ActualWidth); var gutter = V3Page.Gutter(width); _head.Margin = new(gutter, _folder == "" ? 68 : 52, gutter, 0); _results.Margin = new(gutter, 0, gutter, 48); }
    void ClearQueue() { foreach (var item in _queue) item.Upload.Discard(); _queue.Clear(); }
    async void Changed(object? sender, PropertyChangedEventArgs e)
    {
        if (_owner == Account) return;
        _owner = Account; ++_accountEpoch; ++_generation; _overlay?.Close(); ClearQueue(); _files = []; _folders = []; _applications = []; _sessions = []; _selected.Clear(); _limits = _storage = null; _folder = _query = _error = _notice = ""; _tab = "mine"; _jobState = "loading"; _loaded = _busy = _batch = false;
        Render(); await Task.WhenAll(Load(true), LoadJobs(), LoadStorage());
        if (SignedIn && _pending) { _pending = false; await Rename("create"); }
    }
    async Task<JsonNode> Request(string path, string method = "GET", JsonNode? body = null, Dictionary<string, string>? query = null)
    {
        var owner = AccountStamp;
        try { var result = await App.Session.Api.CareerRequestAsync(path, method, query, body, _life.Token); if (_disposed || !SignedIn || owner != AccountStamp) throw new OperationCanceledException(); return result; }
        catch { if (_disposed || !SignedIn || owner != AccountStamp) throw new OperationCanceledException(); throw; }
    }
    async Task Load(bool poll = false)
    {
        var generation = ++_generation;
        if (!SignedIn) { _loaded = true; Render(); return; }
        try { do { var files = Request("/api/datasets"); var folders = Request("/api/datasets/folders"); await Task.WhenAll(files, folders); if (generation != _generation) return; _files = Items(files.Result["datasets"]).Select(x => new DatasetRecord(x)).ToList(); _limits = files.Result["limits"]; _folders = Items(folders.Result["folders"]); _loaded = true; _selected.IntersectWith(_files.Select(x => x.Id)); if (DatasetRequest.Id(_folder) && CurrentFolder is null) _folder = ""; Render(); if (!poll || !_files.Any(x => x.Busy)) break; await Task.Delay(3000, _life.Token); } while (generation == _generation); }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (generation == _generation) { _error = Explain(ex); Render(); } }
    }
    async Task<List<JsonNode>> Pages(string path, Dictionary<string, string> query)
    {
        List<JsonNode> values = []; var seen = new HashSet<string>();
        while (true) { var page = await Request(path, query: query); values.AddRange(page.Items("items")); var cursor = S(page, "next_cursor"); if (cursor.Length == 0) return values; if (!seen.Add(cursor)) throw new InvalidDataException(); query["cursor"] = cursor; }
    }
    async Task LoadJobs()
    {
        if (!SignedIn) { _jobState = "ready"; return; }
        var stamp = AccountStamp;
        try { var apps = Pages("/api/job-applications", new() { ["scope"] = "all", ["limit"] = "200" }); var rounds = Pages("/api/interview-sessions", new() { ["include_archived"] = "true", ["limit"] = "500" }); await Task.WhenAll(apps, rounds); if (stamp != AccountStamp || _disposed) return; _applications = apps.Result; _sessions = rounds.Result; _jobState = "ready"; }
        catch (OperationCanceledException) { return; } catch { if (stamp != AccountStamp || _disposed) return; _jobState = "failed"; }
        Render();
    }
    async Task LoadStorage() { if (!SignedIn) return; try { _storage = (await Request("/api/billing/summary"))["storage"]; Render(); } catch (OperationCanceledException) { } catch { } }
    void Navigate(string folder) { if (_busy) return; _folder = folder; _query = ""; _selected.Clear(); _batch = false; Render(); }
    void OpenApplication(string id) { JobsBoardView.OpenApplication = id; WorkspaceShell.Current.Select(WorkspaceSection.Jobs); }
    void Render()
    {
        if (_disposed) return;
        _root.Children.Clear();
        if (_folder.StartsWith("app:")) { var project = Projects.FirstOrDefault(x => x.Id == _folder[4..]); if (project is not null) { var detail = new CareerApplicationDetailView(new(project.Application), () => { _folder = ""; _tab = "jobs"; Render(); _ = Task.WhenAll(Load(true), LoadJobs()); }, (_, app) => OpenApplication(app.Id), true, () => OpenApplication(project.Id)); Grid.SetRowSpan(detail, 2); _root.Children.Add(detail); } else _root.Children.Add(VStack(16, T(_jobState == "loading" ? "正在加载项目…" : _jobState == "failed" ? "求职进程加载失败" : "这个求职进程不存在或已删除", 17), B("返回资料库", () => Navigate(""))).Align(HorizontalAlignment.Center, VerticalAlignment.Center)); return; }
        _head.Children.Clear(); _head.Spacing = 0; _root.Children.Add(_head); _root.Children.Add(_scroll);
        // 页头（Windows 稿 10 · 05.01 首页 / 04.01 项目详情）：首页 30 号衬线「资料库」+ 13 灰字统计，右侧搜索 / 全部文件 / 唯一黑按钮「新建项目」与统计行底对齐；
        // 下面一行是两个文字标签（选中 13.5 中粗墨黑，未选灰色，后跟数量）和右侧「最近活动 ⌄」排序。项目详情：11.5 面包屑 → 28 号衬线标题 → 13 灰字摘要 → 项目说明 → 分隔线。
        var search = new V3SearchField(_folder == "" ? "搜索项目或文件" : "搜索资料…", _query, _folder == "" ? 200 : 180, _folder == "" ? 34 : 32); search.Changed += value => { _query = value; Results(); };
        var actions = HStack(9, search);
        if (_folder == "") { actions.Children.Add(new V3Button("全部文件", () => Navigate("files"), V3Button.Kind.Ghost, 36) { Enabled = !_batch }); actions.Children.Add(new V3Button("新建项目", () => _ = Rename("create"), V3Button.Kind.Dark, 36) { Enabled = !_busy && !_batch }); }
        else
        {
            actions.Children.Add(new V3Button(_batch ? "取消操作" : "批量操作", () => { _batch = !_batch; _selected.Clear(); Render(); }, V3Button.Kind.Ghost) { Enabled = !_busy });
            if (DatasetRequest.Id(_folder))
            {
                V3Button? add = null; Flyout? menu = null;
                add = new V3Button("＋ 添加资料", () => menu = V3Popover.Show(add!, AddMenu(() => menu?.Hide()), Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight, 6), V3Button.Kind.Dark) { Enabled = !_busy && !_batch && _loaded };
                actions.Children.Add(add);
            }
        }
        var count = _folders.Count + Listed.Count;
        string subtitle;
        if (_folder == "")
        {
            subtitle = $"{count} 个项目 · {_files.Count} 份资料";
            if (_storage is not null) subtitle += $" · 资料 {JobProjects.Size(_storage.Number("datasetBytesUsed") ?? 0)} / {JobProjects.Size(_storage.Number("datasetBytesLimit") ?? 0)} · 音视频 {JobProjects.Size(_storage.Number("mediaBytesUsed") ?? 0)} / {JobProjects.Size(_storage.Number("mediaBytesLimit") ?? 0)}";
        }
        else subtitle = _folder == "files" ? $"共 {_files.Count} 份资料，来自 {count} 个项目" : $"共 {_files.Count(x => x.Folder == _folder)} 份资料";
        if (DatasetRequest.Id(_folder)) { var linked = Visible.Count(x => x.Text("interview_session_id").Length > 0 || x.Text("interview_label").Length > 0); if (linked > 0) subtitle += $" · {linked} 份已关联面试"; }
        var summary = _loaded ? (UIElement)Sans(subtitle, 13, _folder == "" ? Faint : Sub).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis) : V3Skeleton.Make(_folder == "" ? 124 : 160, 8);
        if (_folder == "")
        {
            var title = VStack(4, Serif("资料库", 30, Txt).Frame(height: 43), new Border { Child = summary, Height = 16 });
            actions.VerticalAlignment = VerticalAlignment.Bottom;
            _head.Children.Add(Columns(16, (Star(), title), (Auto, actions)));
            var tabs = HStack(22);
            foreach (var (id, label, total) in new[] { ("mine", "我的项目", _loaded ? _folders.Count.ToString() : ""), ("jobs", "求职进程", _jobState == "ready" ? Listed.Count.ToString() : "") })
            {
                var active = _tab == id;
                var tab = HStack(5, Label(label, 13.5, active ? Txt : Faint, active ? Medium : null), Number(total, 12, active ? Sub : Faint).Align(v: VerticalAlignment.Bottom));
                tabs.Children.Add(tab.Frame(height: 20).OnTap(() => { _tab = id; _query = ""; Render(); }, label));
            }
            var tabRow = Columns(16, (Star(), tabs), (Auto, _loaded && _tab == "mine" && _folders.Count > 0 ? SortMenu() : new Border()));
            _head.Children.Add(tabRow.Pad(0, 30, 0, 17));
        }
        else
        {
            var crumb = HStack(8,
                HStack(5, Icon("chevron.left", 9, Sub), Label("资料库", 11.5, Sub, Medium)).OnTap(() => Navigate(""), "返回资料库"),
                Sans("/", 11.5, Fnt2),
                Sans(_folder == "files" ? "全部文件" : Title, 11.5, Faint).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis));
            _head.Children.Add(crumb.Frame(height: 14).Top(4));
            var title = VStack(2, Serif(Title, 28, Txt).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis).Frame(height: 40), new Border { Child = summary, Height = 16 });
            _head.Children.Add(Columns(16, (Star(), title), (Auto, actions.Top(6))).Top(20));
            if (CurrentFolder is { } folder) _head.Children.Add(Description(folder).Top(14));
            _head.Children.Add(Divider().Top(24));
        }
        Fit(); Results();
        if (_batch && _folder != "") { var all = new CheckBox { Content = "全选", IsChecked = Visible.Any() && Visible.All(x => _selected.Contains(x.Id)), IsEnabled = !_busy }; all.Click += (_, _) => { foreach (var item in Visible) { if (all.IsChecked == true) _selected.Add(item.Id); else _selected.Remove(item.Id); } Render(); }; var bar = Card(Row(all, T($"已选 {_selected.Count} 项"), B("移动到项目", () => { if (_selected.Count > 0) _ = Move(); }), B("删除", () => { if (_selected.Count > 0) _ = DeleteFiles(); }), B("×", () => { _batch = false; _selected.Clear(); Render(); }))); bar.HorizontalAlignment = HorizontalAlignment.Center; bar.VerticalAlignment = VerticalAlignment.Bottom; bar.Margin = new(0, 0, 0, 28); Grid.SetRow(bar, 1); _root.Children.Add(bar); }
    }
    /// <summary>「最近活动 ⌄」：我的项目按最近活动 / 名称 / 资料数排序。</summary>
    FrameworkElement SortMenu()
    {
        var label = _sort switch { "name" => "名称", "count" => "资料数量", _ => "最近活动" };
        var anchor = HStack(4, Sans(label, 12.5, Sub), Icon("chevron.down", 8, Faint).Align(v: VerticalAlignment.Center));
        anchor.OnTap(() => V3Popover.Menu(anchor, 140, new[] { ("recent", "最近活动"), ("name", "名称"), ("count", "资料数量") }
            .Select(x => (UIElement)new V3MenuRow(x.Item2, () => { _sort = x.Item1; Render(); }, isChecked: _sort == x.Item1)).ToArray()), "排序方式：" + label);
        return anchor;
    }

    /// <summary>添加资料菜单（05.03）：每项一行标题 + 一行灰字说明，悬停 #F4F4F2 圆角 7。</summary>
    FrameworkElement AddMenu(Action close)
    {
        FrameworkElement Item(string icon, string title, string detail, Action action)
        {
            var row = new Border { Padding = new Thickness(10, 8, 10, 8), CornerRadius = new CornerRadius(7), Background = Brush(Clear) };
            row.Child = Columns(10, (Auto, Icon(icon, 13, Sub).Align(v: VerticalAlignment.Top).Pad(0, 2, 0, 0)), (Star(), VStack(2, Label(title, 12.5, Txt, Medium), Sans(detail, 11, Fnt))));
            row.OnHover(h => row.Background = Brush(h ? Hex(0xF4F4F2) : Clear));
            return row.OnTap(() => { close(); action(); }, title);
        }
        return VStack(2, Item("plus", "上传本地文件", "PDF、Word、Markdown、音视频", () => _ = Pick()), Item("folder", "从资料库选择", "从其他项目挑几份移进来", () => _ = PickExisting())).Frame(width: 228);
    }

    void ShowNotice()
    {
        if (_toast is not null) _root.Children.Remove(_toast);
        var version = ++_toastVersion;
        if (_notice.Length == 0) return;
        _toast = V3.Card(Row(Sans(_notice, 13, Txt, Medium), B("×", () => { _notice = ""; ShowNotice(); })), 20, new Thickness(16, 0, 16, 0));
        _toast.Height = 40; _toast.Margin = new Thickness(0, 20, 0, 0); _toast.HorizontalAlignment = HorizontalAlignment.Center; _toast.VerticalAlignment = VerticalAlignment.Top; _toast.Elevate(4);
        Grid.SetRowSpan(_toast, 2); _root.Children.Add(_toast);
        _ = Dismiss();
        async Task Dismiss() { try { await Task.Delay(3000, _life.Token); if (version == _toastVersion && !_disposed) { _notice = ""; ShowNotice(); } } catch (OperationCanceledException) { } }
    }
    void Results()
    {
        _results.Children.Clear(); _results.Spacing = 16;
        if (!_loaded) _results.Children.Add(Stack(T(_error.Length == 0 ? "正在加载资料…" : "资料加载失败", 17), T("请稍后重试。资料和项目都还在，刷新一下试试。", 13, true), B("重新加载", () => _ = Load(true))).Top(115));
        else if (_folder == "") Home(); else Files();
        if (_error.Length > 0) _results.Children.Add(Row(T(_error, 12), B("重新刷新", () => { _error = ""; _ = Task.WhenAll(Load(true), LoadJobs(), LoadStorage()); })));
        ShowNotice();
        if (_queue.Count > 0) Queue();
    }
}
