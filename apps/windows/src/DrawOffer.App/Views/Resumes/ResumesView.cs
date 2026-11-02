using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Paper;
using DrawOffer.App.Shell;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using DrawOffer.Core.Session;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Resumes;

/// <summary>
/// 「我的简历」，对应 Mac `ResumesView.swift`：按 Web `features/home/HomePage.tsx` 的 02.1 列表结构，读取本人简历、预览纸面、导出 PDF，
/// 并提供编辑、导入、重命名、复制、分享与删除。新建经新建弹窗；编辑进入原生编辑器（正文、格式、版式与模板）。
/// </summary>
public sealed class ResumesView : UserControl
{
    readonly Action _browse;
    readonly Action _login;
    readonly string _account;
    readonly StackPanel _root = new();
    readonly V3SearchField _search;
    List<ResumeSummary> _resumes = [];
    string? _defaultId;
    bool _loaded, _loading, _loadError, _active, _deleteBusy;
    /// <summary>Mac 的 `importing` 只由直接上传（`importFile`，界面未接入）置位；导入都走导入弹窗，这里保持 false。</summary>
    readonly bool _importing = false;
    string _query = "";
    string? _exportingId;
    (string text, bool failed)? _notice;
    List<JsonNode> _imports = [];
    CancellationTokenSource? _poll;
    /// <summary>刚创建的简历：列表加载后自动打开预览（Mac `focusResumeID`）。</summary>
    string? _focusResumeId;

    bool AtLimit => _loaded && _resumes.Count >= ResumeRequest.MaximumPerUser;

    IEnumerable<ResumeSummary> Visible
    {
        get
        {
            var text = _query.Trim();
            return text.Length == 0 ? _resumes : _resumes.Where(r => r.Title.Contains(text, StringComparison.CurrentCultureIgnoreCase));
        }
    }

    public ResumesView(string account, Action browse, Action login)
    {
        _account = account;
        _browse = browse;
        _login = login;
        _search = new V3SearchField("搜索简历…", width: 220, height: 30);
        _search.Box.FontSize = 12;
        _search.Box.CornerRadius = new CornerRadius(7);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_search.Box, "搜索简历");
        _search.Changed += text => { _query = text; RenderList(); };
        // `.hv3-page`：顶部 51（内容卡自带 1px 描边，合起来是画板的 52）
        Content = new V3Page(_root, top: 51);
        Render();
        Loaded += async (_, _) =>
        {
            _active = true;
            if (WorkspaceShell.Current.ImportRequest is not null && _account.Length > 0) { WorkspaceShell.Current.ImportRequest = null; OpenImport(); }
            await LoadAsync();
        };
        Unloaded += (_, _) => { _active = false; _poll?.Cancel(); };
    }

    // MARK: 布局

    readonly StackPanel _listHost = new();

    void Render()
    {
        _root.Children.Clear();
        var signedIn = _account.Length > 0;
        var actions = new List<UIElement>();
        // Web 空列表时不显示头部按钮（空态里有同样的两个入口）
        if (signedIn && !(_loaded && _resumes.Count == 0 && _imports.Count == 0))
        {
            actions.Add(new V3Button(_importing ? "正在上传…" : "导入简历", OpenImport, icon: "square.and.arrow.up") { Enabled = !_importing });
            actions.Add(new V3Button("新建简历", CheckCapacityThenBrowse, V3Button.Kind.Dark, icon: "plus"));
        }
        _root.Children.Add(V3PageHead.Make(["RESUMES", !signedIn ? "游客预览" : _loaded ? $"{_resumes.Count} 份" : "个人工作区"],
            "我的简历", "每份简历独立编辑，需要时复制一份按岗位修改。", compact: true, actions: actions.ToArray()));
        if (!signedIn) _root.Children.Add(GuestEmpty());
        else if (_loadError && !_loaded) _root.Children.Add(LoadFailure());
        else if (!_loaded) _root.Children.Add(Skeleton());
        else if (_resumes.Count == 0 && _imports.Count == 0) _root.Children.Add(EmptyList());
        else { _root.Children.Add(_listHost); RenderList(); }
        if (_notice is { } notice)
        {
            var close = Icon("xmark", 10, Fnt).OnTap(() => { _notice = null; Render(); }, "关闭提示");
            _root.Children.Add(Spread(Sans(notice.text, 12.5, notice.failed ? Red : Sub).Wrap(), close, 10).Top(16));
        }
    }

    void RenderList()
    {
        _listHost.Children.Clear();
        // `.hv3-toolbar`：距头部 26、高 30；标题 16px 半粗，数字 11px；搜索 220×30、圆角 7、输入 12px
        var heading = new TextBlock { FontSize = 16 };
        heading.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = "全部简历 ", FontWeight = Semibold, Foreground = Brush(Txt) });
        heading.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = $"{_resumes.Count}", FontSize = 11, FontWeight = Medium, Foreground = Brush(Fnt) });
        if (_search.Parent is Panel old) old.Children.Remove(_search);
        _listHost.Children.Add(Spread(heading, _search).Frame(height: 30).Top(26));
        _listHost.Children.Add(Divider().Top(2));
        var visible = Visible.ToList();
        if (visible.Count == 0)
        {
            // Web `.hv3-empty.is-search`
            _listHost.Children.Add(VStack(8,
                Serif($"没有找到「{_query.Trim()}」", 18).Align(HorizontalAlignment.Center),
                Sans("试试更短的关键词，比如公司名或岗位名；也可以回到「全部」查看所有简历。", 13, Sub).Align(HorizontalAlignment.Center),
                new V3Button("清除搜索", () => _search.Box.Text = "", icon: "magnifyingglass").Align(HorizontalAlignment.Center).Top(8))
                .Also(s => { s.MinHeight = 200; s.VerticalAlignment = VerticalAlignment.Center; }).Top(60));
            return;
        }
        var grid = new AdaptiveGrid(199, 20, 37) { Margin = new Thickness(0, 27, 0, 0) };
        if (_query.Length == 0) foreach (var task in _imports) grid.Children.Add(ImportCard(task));
        var defaultId = ResumeRequest.DefaultResume(_resumes, _defaultId)?.Id;
        foreach (var resume in visible) grid.Children.Add(Card(resume, resume.Id == defaultId));
        if (_query.Length == 0)
        {
            var dash = new Rectangle { RadiusX = 6, RadiusY = 6, Stroke = Brush(0xC9C9C3), StrokeThickness = 1, StrokeDashArray = [4, 4] };
            var label = VStack(10, Icon("plus", 20, Fnt).Align(HorizontalAlignment.Center), Sans("新建空白简历", 12, Fnt))
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            var blank = new A4Box(Layer(new Border { Background = Brush(V3.White), CornerRadius = new CornerRadius(6) }, dash, label));
            grid.Children.Add(blank.OnTap(CheckCapacityThenBrowse, "新建空白简历"));
        }
        _listHost.Children.Add(grid);
    }

    static FrameworkElement Skeleton()
    {
        var grid = new AdaptiveGrid(199, 20, 37) { Margin = new Thickness(0, 55, 0, 0) };
        for (var i = 0; i < 4; i++)
            grid.Children.Add(VStack(10,
                new A4Box(Fill(Field, 6)),
                Fill(Field, 3, 120, 12).Align(HorizontalAlignment.Left),
                Fill(Field, 3, 80, 10).Align(HorizontalAlignment.Left)));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(grid, "正在加载我的简历…");
        return grid;
    }

    /// <summary>`.hv3-load-error`：分隔线距头部 58，下方 55 处 480 宽的卡片，150 高点阵舞台，112×36 的「重新加载」。</summary>
    FrameworkElement LoadFailure()
    {
        var art = new Border
        {
            Width = 56, Height = 48, CornerRadius = new CornerRadius(14), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            Child = Icon("exclamationmark.arrow.triangle.2.circlepath", 18, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        }.Elevate(6).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        var card = V3EmptyCard.Make("简历列表没能加载出来", "网络不稳定或服务暂时不可用，你的简历都还在，刷新一下试试。", art,
            [new V3Button("重新加载", () => _ = LoadAsync(), height: 36, width: 112, icon: "arrow.clockwise") { Enabled = !_loading }],
            stageHeight: 150, width: 480, inset: 8, messageTop: 8, actionsTop: 13);
        return VStack(0, Divider().Top(58), card.Top(55).Align(HorizontalAlignment.Center));
    }

    /// <summary>`.hv3-empty.is-list`：分隔线距头部 24，下方 53 处 520 宽的卡片，236 高点阵舞台，120×36 的深色「新建简历 →」与文字链「导入简历」。</summary>
    FrameworkElement EmptyList()
    {
        var create = new V3Button("新建简历", CheckCapacityThenBrowse, V3Button.Kind.Dark, height: 36, width: 120);
        create.Also(b => ((StackPanel)((Border)b.Content).Child).Children.Add(Icon("arrow.right", 10, V3.White)));
        var import = HStack(5, Icon("square.and.arrow.up", 11, Sub), Sans("导入简历", 14, Sub, Medium)).OnTap(OpenImport, "导入简历", () => !_importing);
        var card = V3EmptyCard.Make("从第一份简历开始", "新建时选一套模板、起个名字；已有简历文件可以用「导入简历」。",
            EmptyResumeArt.Make().Frame(504, 236), [create, import], stageHeight: 236, inset: 8, messageTop: 8, actionsTop: 32);
        return VStack(0, Divider().Top(24), card.Top(53).Align(HorizontalAlignment.Center));
    }

    /// <summary>游客空状态：沿用 Web 新用户引导，不代表已查询到账号没有简历。</summary>
    FrameworkElement GuestEmpty()
    {
        var import = HStack(6, Icon("square.and.arrow.up", 13, Txt), Label("导入简历", 13)).OnTap(_login, "导入简历");
        var body = VStack(12,
            EmptyResumeArt.Make().Frame(504, 236).Align(HorizontalAlignment.Center),
            Serif("从第一份简历开始", 18).Align(HorizontalAlignment.Center),
            Sans("新建时选一套模板、起个名字；已有简历文件可以用「导入简历」。", 13, Sub).Align(HorizontalAlignment.Center),
            HStack(20, WebAction("新建简历 →", _browse), import).Align(HorizontalAlignment.Center).Top(8),
            Sans("内置示例可离线预览；登录后可查看和导出你的简历。", 12, Fnt).Align(HorizontalAlignment.Center).Top(8));
        return VStack(0, Divider(Hex(0xE4E4E0)).Top(24), body.Top(42));
    }

    /// <summary>Mac `WebActionStyle`：13px 中粗白字，左右 16、上下 10，#17191C 底、圆角 8，按下 80% 不透明。</summary>
    internal static FrameworkElement WebAction(string title, Action action, Func<bool>? enabled = null)
    {
        var button = new Border
        {
            Child = Label(title, 13, V3.White, Medium), Padding = new Thickness(16, 10, 16, 10), CornerRadius = new CornerRadius(8), Background = Brush(0x17191C),
        };
        button.PointerPressed += (_, _) => button.Opacity = 0.8;
        button.PointerReleased += (_, _) => button.Opacity = 1;
        button.PointerExited += (_, _) => button.Opacity = 1;
        button.Loaded += (_, _) => { if (enabled is not null && !enabled()) button.Opacity = 0.5; };
        return button.OnTap(action, title, enabled);
    }

    // MARK: 卡片

    /// <summary>`.hv3-card`：A4 缩略纸面 + 标题 + 更新时间；悬停出现 ⋯ 菜单。</summary>
    FrameworkElement Card(ResumeSummary resume, bool isDefault)
    {
        var exporting = _exportingId == resume.Id;
        var more = new Border
        {
            Width = 28, Height = 28, CornerRadius = new CornerRadius(6), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            Child = Icon("ellipsis", 12, Txt).Align(HorizontalAlignment.Center, VerticalAlignment.Center), Margin = new Thickness(8),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Opacity = exporting ? 1 : 0,
        };
        more.OnTap(() => Menu(resume, isDefault, exporting).ShowAt(more), $"更多简历操作 {resume.Title}");
        var thumbnail = new A4Box(new ResumeThumbnail(resume)).OnTap(() => Edit(resume.Id), $"打开 {resume.Title}");
        var meta = HStack(6);
        if (isDefault)
            meta.Children.Add(new Border
            {
                Child = Sans("默认", 10.5, Blue, Medium).Align(v: VerticalAlignment.Center), Padding = new Thickness(5, 0, 5, 0), Height = 16,
                Background = Brush(BlueSoft), CornerRadius = new CornerRadius(4),
            });
        meta.Children.Add(Number(exporting ? "正在导出 PDF…" : $"{resume.UpdatedLabel()} · 已保存", 11, Fnt, Regular));
        // `.hv3-card-meta`：纸面下 14、名称与时间间隔 6
        var card = VStack(6,
            Layer(thumbnail, more),
            Sans(resume.Title, 13, Txt, Medium).Frame(height: 16).Tip(resume.Title).Top(4),
            meta);
        card.Background = Brush(Clear);
        return card.OnHover(hover => more.Opacity = hover || exporting ? 1 : 0);
    }

    MenuFlyout Menu(ResumeSummary resume, bool isDefault, bool exporting)
    {
        var menu = new MenuFlyout();
        void Add(string text, string symbol, Action action, bool enabled = true, bool danger = false)
        {
            var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = Icons.Glyph(symbol), FontFamily = IconFamily }, IsEnabled = enabled };
            if (danger) item.Foreground = Brush(Red);
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        // 与 Web 同一组菜单：点卡片本身就能打开编辑，这里放「设为默认简历」（已是默认时不显示）
        if (!isDefault) Add("设为默认简历", "pin", () => _ = SetDefaultAsync(resume));
        Add("重命名", "character.cursor.ibeam", () => ResumeTitleSheet.Show(XamlRoot, ResumeTitleSheet.Mode.Rename, resume, title => { _notice = ($"已将简历重命名为「{title}」", false); _ = LoadAsync(); }));
        Add("复制为新简历", "doc.on.doc", () => CheckCapacity(() => ResumeTitleSheet.Show(XamlRoot, ResumeTitleSheet.Mode.Copy, resume, title => { _notice = ($"已复制为「{title}」", false); _ = LoadAsync(); })));
        Add("分享链接", "link", () => ResumeShareSheet.Show(XamlRoot, resume));
        Add(exporting ? "正在导出…" : "导出 PDF", "arrow.down.doc", () => _ = ExportAsync(resume), !exporting);
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("删除", "trash", () => _ = ConfirmDeleteAsync(resume), danger: true);
        return menu;
    }

    FrameworkElement ImportCard(JsonNode task)
    {
        var failed = task.Text("upload_status") == "failed" || task.Text("parse_status") == "failed";
        var stage = task.Text("upload_status") == "uploading" ? "正在上传" : "正在解析";
        var state = VStack(10,
            failed ? Icon("exclamationmark.triangle", 24, Red).Align(HorizontalAlignment.Center) : new ProgressRing { Width = 16, Height = 16, IsActive = true },
            Sans(failed ? (task.Text("upload_status") == "failed" ? "上传失败" : "解析失败") : stage + "…", 12, failed ? Red : Sub).Align(HorizontalAlignment.Center))
            .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        var foot = failed
            ? Spread(Sans("可以删除记录后重新导入", 11, Red), Sans("删除记录", 11, Link).OnTap(() => _ = DeleteImportAsync(task), "删除记录"), 8)
            : (FrameworkElement)Sans($"{stage} · 请稍候", 11, Fnt);
        return VStack(10,
            new A4Box(new Border { Background = Brush(failed ? RedSoft : V3.Stage), CornerRadius = new CornerRadius(6), Child = state }),
            Sans(task.Text("source_filename"), 13, Txt, Medium),
            foot);
    }

    // MARK: 数据

    async Task LoadAsync()
    {
        if (_account.Length == 0) return;
        _loading = true; _loadError = false;
        try
        {
            var page = await App.Session.Api.CareerRequestAsync("/api/resumes");
            if (!_active) return;
            _resumes = page.Items("resumes").Select(ResumeSummary.From).OfType<ResumeSummary>().ToList();
            _defaultId = page["default_resume_id"].String();
            _loaded = true;
            await LoadImportsAsync();
            if (_focusResumeId is { } focus)
            {
                _focusResumeId = null;
                if (_resumes.FirstOrDefault(r => r.Id == focus) is { } created) { _notice = ($"已创建「{created.Title}」", false); ResumePreviewSheet.Show(XamlRoot, created, this); }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            if (!_active) return;
            if (SheetErrors.Unauthorized(error)) return;
            _loadError = true;
            if (_loaded) _notice = ("刷新简历列表失败，当前显示的是上次读取的结果。", true);
        }
        finally { _loading = false; if (_active) Render(); }
    }

    /// <summary>导入任务卡（`GET /api/resume-overview` 的进行中与失败任务）；有进行中的任务时每 3 秒刷新，完成后刷新列表。</summary>
    async Task LoadImportsAsync()
    {
        JsonNode overview;
        try { overview = await App.Session.Api.CareerRequestAsync("/api/resume-overview"); }
        catch (Exception) { return; }
        if (!_active) return;
        var active = overview.Items("active_imports");
        var previousActive = _imports.Count(t => t.Text("upload_status") != "failed" && t.Text("parse_status") != "failed");
        _imports = active.Concat(overview.Items("failed_imports")).ToList();
        // 有任务结束（成功生成简历或失败）时刷新简历列表
        if (previousActive > active.Count) _ = LoadAsync();
        if (active.Count > 0) _ = PollImportsAsync();
        Render();
    }

    async Task PollImportsAsync()
    {
        _poll?.Cancel();
        var poll = _poll = new CancellationTokenSource();
        try { await Task.Delay(TimeSpan.FromSeconds(3), poll.Token); }
        catch (OperationCanceledException) { return; }
        if (_active && _imports.Count > 0) await LoadImportsAsync();
    }

    async Task DeleteImportAsync(JsonNode task)
    {
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/resume-imports/{task.Text("id")}", "DELETE");
            _imports.RemoveAll(t => t.Text("id") == task.Text("id"));
            _notice = ($"已删除「{task.Text("source_filename")}」的失败记录", false);
        }
        catch (Exception) { _notice = ("删除失败记录失败，请稍后重试。", true); }
        Render();
    }

    void OpenImport() => ResumeImportSheet.Show(XamlRoot, title =>
    {
        _notice = ($"已开始导入「{title}」，解析完成后会出现在列表中。", false);
        _ = LoadImportsAsync();
    });

    internal async Task ExportAsync(ResumeSummary resume)
    {
        if (_exportingId is not null) return;
        var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = FileName(resume.Title)[..^4] };
        picker.FileTypeChoices.Add("PDF", [".pdf"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        if (await picker.PickSaveFileAsync() is not { } destination) return;
        _exportingId = resume.Id; _notice = null; Render();
        try
        {
            if (App.Session.Api is not HttpApiClient client) throw new InvalidOperationException();
            var data = await client.Coordinator.DownloadResumePdfAsync(resume.Id, resume.LockVersion);
            try { await Windows.Storage.FileIO.WriteBytesAsync(destination, data); }
            catch (Exception) { _notice = ("PDF 已生成，但保存到所选位置失败，请换个位置重试。", true); return; }
            _notice = ($"已导出「{resume.Title}」", false);
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            if (SheetErrors.Unauthorized(error)) return;
            if (error is ApiException { Code: "RESUME_PDF_SNAPSHOT_STALE" }) { _notice = ("简历已在其他设备更新，已刷新列表，请重新导出。", true); _ = LoadAsync(); }
            else if (error is ApiException { Code: "RESUME_NOT_FOUND" }) { _notice = ("这份简历已不存在，已刷新列表。", true); _ = LoadAsync(); }
            else _notice = ("导出 PDF 失败，请稍后重试。", true);
        }
        finally { _exportingId = null; if (_active) Render(); }
    }

    async Task ConfirmDeleteAsync(ResumeSummary resume)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "删除这份简历？", CloseButtonText = "取消", PrimaryButtonText = "删除",
            Content = $"「{resume.Title}」删除后无法恢复：公开分享链接会立即失效，关联的求职记录会解除关联，其他简历不受影响。",
        };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            dialog.PrimaryButtonText = "正在删除…";
            dialog.IsPrimaryButtonEnabled = false;
            await DeleteAsync(resume);
            deferral.Complete();
        };
        await dialog.ShowAsync();
    }

    async Task DeleteAsync(ResumeSummary resume)
    {
        if (_deleteBusy) return;
        _deleteBusy = true;
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/resumes/{resume.Id}", "DELETE");
            _resumes.RemoveAll(r => r.Id == resume.Id);
            _notice = ($"已删除「{resume.Title}」", false);
            _ = LoadAsync();
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            if (SheetErrors.Unauthorized(error)) return;
            if (error is ApiException { Status: System.Net.HttpStatusCode.NotFound }) { _notice = ("这份简历已不存在，已刷新列表。", true); _ = LoadAsync(); return; }
            _notice = ($"删除「{resume.Title}」失败，请刷新列表确认后重试。", true);
        }
        finally { _deleteBusy = false; if (_active) Render(); }
    }

    /// <summary>设为默认简历（`PUT /api/resumes/{id}/default`）：模拟面试、岗位匹配等默认用它。</summary>
    async Task SetDefaultAsync(ResumeSummary resume)
    {
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/resumes/{resume.Id}/default", "PUT");
            _defaultId = resume.Id;
            _notice = ($"已将「{resume.Title}」设为默认简历", false);
        }
        catch (Exception error)
        {
            if (SheetErrors.Unauthorized(error)) return;
            _notice = ("设为默认简历失败，请稍后重试。", true);
        }
        Render();
    }

    /// <summary>新建前的容量预检（`GET /api/resumes/capacity`）：已达上限时提示，不进入新建。</summary>
    void CheckCapacityThenBrowse() => CheckCapacity(() => ResumeCreateSheet.Show(XamlRoot, null, id =>
    {
        _ = LoadAsync();
        if (id.Length > 0) Edit(id);
    }));

    /// <summary>Web `requestCreation`：新建与复制前先查容量，已满或查询失败都只提示、不继续。</summary>
    async void CheckCapacity(Action proceed)
    {
        try
        {
            await App.Session.Api.CareerRequestAsync("/api/resumes/capacity");
            proceed();
        }
        catch (ApiException error) when (error.Code == "RESUME_LIMIT_REACHED")
        {
            _notice = ($"简历数量已达上限（{ResumeRequest.MaximumPerUser} 份），请删除不需要的简历后重试。", true); Render();
        }
        catch (Exception) { _notice = ("暂时无法检查简历数量，请稍后重试。", true); Render(); }
    }

    internal void Edit(string id) => WorkspaceShell.Current.EditResume(id);

    /// <summary>与后端 Content-Disposition 一致：保留中文标题，只替换文件系统不接受的字符。</summary>
    public static string FileName(string title)
    {
        var cleaned = new string(title.Select(c => "/:\\\0".Contains(c) ? '-' : c).ToArray()).Trim();
        return (cleaned.Length == 0 ? "resume" : cleaned) + ".pdf";
    }

    /// <summary>新建成功后由外壳调用：列表加载完自动打开预览（Mac `focusResumeID`）。</summary>
    public void Focus(string id) => _focusResumeId = id;
}

/// <summary>A4 比例（210 : 297）的框，宽度随列宽。</summary>
sealed class A4Box : Grid
{
    public A4Box(UIElement child)
    {
        Children.Add(child);
        SizeChanged += (_, e) => { if (Math.Abs(Height - e.NewSize.Width * 297 / 210) > 0.5) Height = e.NewSize.Width * 297 / 210; };
    }
}

/// <summary>
/// `LazyVGrid(columns: [GridItem(.adaptive(minimum:), spacing:)], spacing:)`：列数 = ⌊(宽 + 列距) / (最小宽 + 列距)⌋，列宽均分，行距固定。
/// </summary>
sealed class AdaptiveGrid(double minimum, double spacing, double rowSpacing) : Panel
{
    int Columns(double width) => Math.Max(1, (int)Math.Floor((width + spacing) / (minimum + spacing)));
    double ColumnWidth(double width, int columns) => (width - spacing * (columns - 1)) / columns;

    protected override Windows.Foundation.Size MeasureOverride(Windows.Foundation.Size available)
    {
        var width = double.IsInfinity(available.Width) ? minimum : available.Width;
        var columns = Columns(width);
        var column = ColumnWidth(width, columns);
        double height = 0, row = 0;
        for (var i = 0; i < Children.Count; i++)
        {
            Children[i].Measure(new Windows.Foundation.Size(column, double.PositiveInfinity));
            row = Math.Max(row, Children[i].DesiredSize.Height);
            if (i % columns == columns - 1 || i == Children.Count - 1) { height += row + (i < Children.Count - 1 ? rowSpacing : 0); row = 0; }
        }
        return new Windows.Foundation.Size(width, height);
    }

    protected override Windows.Foundation.Size ArrangeOverride(Windows.Foundation.Size final)
    {
        var columns = Columns(final.Width);
        var column = ColumnWidth(final.Width, columns);
        double y = 0, row = 0;
        for (var i = 0; i < Children.Count; i++)
        {
            var c = i % columns;
            // 一行的高度取该行最高的子元素
            if (c == 0) { row = 0; for (var j = i; j < Math.Min(i + columns, Children.Count); j++) row = Math.Max(row, Children[j].DesiredSize.Height); }
            Children[i].Arrange(new Windows.Foundation.Rect(c * (column + spacing), y, column, row));
            if (c == columns - 1) y += row + rowSpacing;
        }
        return final;
    }
}

/// <summary>卡片里的缩略纸面：794 宽的纸按列宽缩放，只取第一页；1px #D3D3CE 边、圆角 6。</summary>
sealed class ResumeThumbnail : UserControl
{
    public ResumeThumbnail(ResumeSummary resume)
    {
        var root = new Grid { Background = Brush(V3.White) };
        var frame = new Border { CornerRadius = new CornerRadius(6), BorderBrush = Brush(0xD3D3CE), BorderThickness = new Thickness(1), Child = root };
        Content = frame;
        var loading = new ProgressRing { Width = 16, Height = 16, IsActive = true };
        root.Children.Add(loading);
        void Fail()
        {
            root.Children.Clear();
            root.Children.Add(Sans("预览不可用", 11, Fnt).Align(HorizontalAlignment.Center, VerticalAlignment.Center));
        }
        Loaded += async (_, _) =>
        {
            if (resume.ToRenderRequest() is not { } request) { Fail(); return; }
            try
            {
                var prepared = await App.Session.Api.PreparePaperAsync(request);
                var paper = new ResumePaperView { Width = 794, Height = 1123, IsHitTestVisible = false };
                paper.RenderFailed += (_, _) => Fail();
                paper.Render(prepared.Request);
                root.Children.Clear();
                root.Children.Add(new Viewbox { Stretch = Stretch.UniformToFill, VerticalAlignment = VerticalAlignment.Top, Child = paper });
                frame.Clip(6);
            }
            catch (OperationCanceledException) { }
            catch (Exception) { Fail(); }
        };
    }
}

static class ClipExtensions
{
    /// <summary>圆角裁切（SwiftUI `.clipShape(RoundedRectangle)`）：Border 的 CornerRadius 会裁掉子元素，这里只需确保背景透明。</summary>
    public static void Clip(this Border border, double radius) => border.CornerRadius = new CornerRadius(radius);
}

/// <summary>只读预览，对应 Mac `ResumePreviewSheet`（960×720）：连续纸面 + 导出 PDF。私有图片经桌面会话下载后注入，失败时保留正文并提示。</summary>
static class ResumePreviewSheet
{
    public static void Show(XamlRoot root, ResumeSummary resume, ResumesView owner)
    {
        V3Overlay.Show(root, close =>
        {
            var exporting = false;
            V3Button export = null!;
            export = new V3Button("导出 PDF", async () =>
            {
                if (exporting) return;
                exporting = true; export.Title = "正在导出…"; export.Enabled = false;
                await owner.ExportAsync(resume);
                exporting = false; export.Title = "导出 PDF"; export.Enabled = true;
            }, V3Button.Kind.Dark);
            var head = Spread(
                VStack(4, Label(resume.Title, 15, Txt, Semibold), Sans($"{resume.UpdatedLabel()} · 已保存", 12, Fnt)),
                HStack(12,
                    new V3Button("编辑", () => { close(); owner.Edit(resume.Id); }),
                    new V3Button("分享", () => { close(); ResumeShareSheet.Show(root, resume); }),
                    export,
                    Label("关闭", 13).OnTap(close, "关闭")), 12);
            head.Padding = new Thickness(20);
            var hint = Sans("点“编辑”在原生编辑器修改内容、格式、版式与模板。最终排版以 PDF 为准，字体、换行与分页可能不同。", 12, Fnt).Wrap().Pad(20, 0, 20, 12);
            var missing = Sans("部分图片不可用，正文仍可预览", 12, V3.Orange).Pad(0, 0, 0, 8).Align(HorizontalAlignment.Center);
            missing.Visibility = Visibility.Collapsed;
            var error = Sans("", 12.5, Red).Pad(0, 0, 0, 8).Align(HorizontalAlignment.Center);
            error.Visibility = Visibility.Collapsed;
            var paperHost = new Grid { Padding = new Thickness(24) };
            var loading = VStack(8, new ProgressRing { Width = 20, Height = 20, IsActive = true }, Sans("加载预览…", 13, Sub)).Align(HorizontalAlignment.Center).Pad(40, 40, 40, 40);
            paperHost.Children.Add(loading);
            var scroller = new ScrollViewer
            {
                Content = paperHost, Background = Brush(V3.Stage),
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Auto,
            };
            void Fail(string text) { error.Text = text; error.Visibility = Visibility.Visible; paperHost.Children.Remove(loading); }
            scroller.Loaded += async (_, _) =>
            {
                if (resume.ToRenderRequest() is not { } request) { Fail("这份简历暂时没有可用的预览，请打开编辑器保存一次后重试。"); return; }
                try
                {
                    var result = await App.Session.Api.PreparePaperAsync(request);
                    var paper = new ResumePaperView { Width = 794, Height = 1123 };
                    paper.Rendered += (_, height) => paper.Height = Math.Max(1123, height);
                    paper.RenderFailed += (_, message) => Fail(message);
                    paper.Render(result.Request);
                    paperHost.Children.Clear();
                    paperHost.Children.Add(paper);
                    if (result.MissingImageCount > 0) missing.Visibility = Visibility.Visible;
                }
                catch (OperationCanceledException) { }
                catch (Exception failure)
                {
                    if (SheetErrors.Unauthorized(failure)) { Fail("登录已失效，请重新登录。"); return; }
                    Fail("预览加载失败，请重试。");
                }
            };
            var grid = new Grid();
            for (var i = 0; i < 4; i++) grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
            grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
            grid.Children.Add(head);
            Grid.SetRow(hint, 1); grid.Children.Add(hint);
            Grid.SetRow(missing, 2); grid.Children.Add(missing);
            Grid.SetRow(error, 3); grid.Children.Add(error);
            Grid.SetRow(scroller, 4); grid.Children.Add(scroller);
            var frame = V3Dialog.Frame(grid, 960);
            frame.Height = 720;
            return frame;
        });
    }
}

/// <summary>Mac `EmptyResumeArt`（Shell/WorkspaceView.swift）：504×236，12 点距灰点阵、居中一张带虚线模块的空白简历纸与三张倾斜的模块标签。</summary>
public static class EmptyResumeArt
{
    public static FrameworkElement Make()
    {
        var canvas = new Canvas { Width = 504, Height = 236, IsHitTestVisible = false };
        var dot = Brush(Alpha(Microsoft.UI.Colors.Gray, 0.15));
        for (var x = 0.0; x <= 504; x += 12)
            for (var y = 0.0; y <= 236; y += 12)
            {
                var e = new Ellipse { Width = 1, Height = 1, Fill = dot };
                Canvas.SetLeft(e, x); Canvas.SetTop(e, y);
                canvas.Children.Add(e);
            }
        var blocks = VStack(14,
            Fill(Hex(0x17191C), 2, 48, 7).Align(HorizontalAlignment.Left),
            Fill(Hex(0xDCDCD8), 0, 72, 3).Align(HorizontalAlignment.Left));
        for (var i = 0; i < 3; i++)
            blocks.Children.Add(new Rectangle { Height = 28, RadiusX = 4, RadiusY = 4, Stroke = Brush(0xE9E9E5), StrokeThickness = 1, StrokeDashArray = [3, 3] });
        var paper = new Border
        {
            Width = 132, Height = 176, Padding = new Thickness(16), Background = Brush(V3.White), CornerRadius = new CornerRadius(5),
            BorderBrush = Brush(0xE4E4E0), BorderThickness = new Thickness(1), Child = blocks,
        }.Elevate(4);
        Canvas.SetLeft(paper, 186); Canvas.SetTop(paper, 30);
        canvas.Children.Add(paper);
        canvas.Children.Add(Chip("教育经历", 90, 68, -4));
        canvas.Children.Add(Chip("项目经历", 336, 110, 3));
        canvas.Children.Add(Chip("专业技能", 104, 158, 2));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(canvas, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return canvas;
    }

    static FrameworkElement Chip(string title, double x, double y, double angle)
    {
        var chip = new Border
        {
            Padding = new Thickness(10), Background = Brush(V3.White), BorderBrush = Brush(0xE4E4E0), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(5),
            Child = HStack(6, Icon("square.grid.2x2", 11), Label(title, 11)),
            RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5), RenderTransform = new RotateTransform { Angle = angle },
        };
        Canvas.SetLeft(chip, x); Canvas.SetTop(chip, y);
        return chip;
    }
}
