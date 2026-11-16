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
/// 「我的简历」（Windows 稿 02.1，对应 Mac `ResumesView.swift`）：读取本人简历、预览纸面、导出 PDF，
/// 并提供编辑、导入、重命名、复制、分享与删除。新建经新建弹窗；编辑进入原生编辑器。游客不会进入本页（外壳只给游客首页）。
/// </summary>
public sealed class ResumesView : UserControl
{
    /// <summary>稿中眉题、数量与时间的浅灰字 #96968F。</summary>
    static readonly Windows.UI.Color Hint = Hex(0x96968F);

    readonly Action _browse;
    readonly string _account;
    readonly StackPanel _root = new();
    readonly V3SearchField _search;
    List<ResumeSummary> _resumes = [];
    string? _defaultId;
    bool _loaded, _loading, _loadError, _active, _deleteBusy;
    string _query = "";
    string? _exportingId;
    (string text, bool failed)? _notice;
    List<JsonNode> _imports = [];
    CancellationTokenSource? _poll;

    bool AtLimit => _loaded && _resumes.Count >= ResumeRequest.MaximumPerUser;

    IEnumerable<ResumeSummary> Visible
    {
        get
        {
            var text = _query.Trim();
            return text.Length == 0 ? _resumes : _resumes.Where(r => r.Title.Contains(text, StringComparison.CurrentCultureIgnoreCase));
        }
    }

    public ResumesView(string account, Action browse)
    {
        _account = account;
        _browse = browse;
        // 02.1 工具行搜索：220×30、圆角 7、#F4F4F2 底、12 号字
        _search = new V3SearchField("搜索简历…", width: 220, height: 30);
        _search.Box.FontSize = 12;
        _search.Box.CornerRadius = new CornerRadius(7);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_search.Box, "搜索简历");
        _search.Changed += text => { _query = text; RenderList(); };
        // Figma 02.1：内容区距顶 64（眉题）
        Content = new V3Page(_root, top: 64);
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
        // 页头按钮：胶囊。「导入简历」31 高白底细边，「新建简历」32 高墨黑；12/500 字、图标 9
        var import = new V3Button("导入简历", OpenImport, height: 31, icon: "square.and.arrow.up") { Enabled = !AtLimit };
        var create = new V3Button("新建简历", CheckCapacityThenBrowse, V3Button.Kind.Dark, height: 32, icon: "plus");
        _root.Children.Add(Head(_loaded ? $"{_resumes.Count} 份" : "个人工作区",
            AtLimit ? $"已达到 {ResumeRequest.MaximumPerUser} 份上限。删除不用的简历后，才能新建、导入或复制。" : "每份简历独立编辑，需要时复制一份按岗位修改。",
            AtLimit, import, create));
        if (_loadError && !_loaded) _root.Children.Add(LoadFailure());
        else if (!_loaded) _root.Children.Add(Skeleton());
        else if (_resumes.Count == 0 && _imports.Count == 0) _root.Children.Add(EmptyList());
        else { _root.Children.Add(_listHost); RenderList(); }
        if (_notice is { } notice)
        {
            var close = Icon("xmark", 10, Fnt).OnTap(() => { _notice = null; Render(); }, "关闭提示");
            _root.Children.Add(Spread(Sans(notice.text, 12.5, notice.failed ? Red : Sub).Wrap(), close, 10).Top(16));
        }
    }

    /// <summary>02.1 页头：眉题 11 灰「RESUMES · N 份」，标题 28 衬线，说明 13（到上限时橙色）；按钮距顶 32。</summary>
    static FrameworkElement Head(string count, string subtitle, bool warn, params UIElement[] actions)
    {
        var text = VStack(0,
            Sans($"RESUMES · {count}", 11, Hint).Frame(height: 13),
            Serif("我的简历", 28, Txt).Frame(height: 40).Top(13),
            Sans(subtitle, 13, warn ? V3.Orange : Sub).Frame(height: 16).Top(2));
        var buttons = HStack(10, actions);
        buttons.VerticalAlignment = VerticalAlignment.Top;
        return Spread(text, buttons.Top(32), 24);
    }

    void RenderList()
    {
        _listHost.Children.Clear();
        // 02.1 工具行：距头部 32、高 30；「全部简历」13/500，数字 11 灰
        var heading = new TextBlock { FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
        heading.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = "全部简历  ", FontWeight = Medium, Foreground = Brush(Txt) });
        heading.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = $"{_resumes.Count}", FontSize = 11, FontWeight = Medium, Foreground = Brush(Hint) });
        if (_search.Parent is Panel old) old.Children.Remove(_search);
        _listHost.Children.Add(Spread(heading, _search).Frame(height: 30).Top(32));
        _listHost.Children.Add(Divider().Top(2));
        var visible = Visible.ToList();
        if (visible.Count == 0)
        {
            // 02.1 ③ 搜索没有结果：三张小纸 + 放大镜，标题 17/500，说明 13，「清除搜索」胶囊
            _listHost.Children.Add(VStack(0,
                SearchArt().Align(HorizontalAlignment.Center),
                Sans($"没有找到「{_query.Trim()}」", 17, Txt, Medium).Align(HorizontalAlignment.Center).Top(42),
                Sans("试试更短的关键词，比如公司名或岗位名；也可以回到「全部」查看所有简历。", 13, Sub).Align(HorizontalAlignment.Center).Top(13),
                new V3Button("清除搜索", () => _search.Box.Text = "", height: 31, icon: "magnifyingglass").Align(HorizontalAlignment.Center).Top(27))
                .Top(160));
            return;
        }
        var grid = new AdaptiveGrid(199, 20, 37) { Margin = new Thickness(0, 18, 0, 0) };
        if (_query.Length == 0) foreach (var task in _imports) grid.Children.Add(ImportCard(task));
        var defaultId = ResumeRequest.DefaultResume(_resumes, _defaultId)?.Id;
        foreach (var resume in visible) grid.Children.Add(Card(resume, resume.Id == defaultId));
        if (_query.Length == 0)
        {
            // 02.1 ② 达到上限时这一格变成「已达 N 份上限」，不能点
            var atLimit = AtLimit;
            var dash = new Rectangle { RadiusX = 6, RadiusY = 6, Stroke = Brush(0xC9C9C3), StrokeThickness = 1, StrokeDashArray = [4, 4] };
            var label = VStack(12, Icon("plus", 14, Hint).Align(HorizontalAlignment.Center),
                    Sans(atLimit ? $"已达 {ResumeRequest.MaximumPerUser} 份上限" : "新建空白简历", 12, Hint))
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            label.Opacity = atLimit ? 0.7 : 1;
            var blank = new A4Box(Layer(new Border { Background = Brush(V3.White), CornerRadius = new CornerRadius(6) }, dash, label));
            grid.Children.Add(blank.OnTap(CheckCapacityThenBrowse, atLimit ? "已达简历上限" : "新建空白简历", () => !AtLimit));
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

    /// <summary>
    /// 02.1 空列表：分隔线下居中一张小纸（两侧「教育经历」「项目经历」小模块），标题 17/500「还没有简历」，两行 13 号说明；
    /// 入口就是右上角两个按钮，不在空态里重复。
    /// </summary>
    static FrameworkElement EmptyList()
    {
        var message = Sans("用右上角「新建简历」选一套模板开始，每份简历都能复制一份按岗位修改。\n已有简历文件，可以用「导入简历」直接读进来。", 13, Sub)
            .LineHeight(23).Also(t => t.TextAlignment = TextAlignment.Center);
        return VStack(0, Divider().Top(24),
            VStack(0,
                BlankArt().Align(HorizontalAlignment.Center),
                Sans("还没有简历", 17, Txt, Medium).Align(HorizontalAlignment.Center).Top(36),
                message.Align(HorizontalAlignment.Center).Top(13)).Top(222));
    }

    /// <summary>02.1 空列表插图：64×88 白纸（标题条 + 三个虚线模块位），左「教育经历」、右「项目经历」两个小模块签。</summary>
    static FrameworkElement BlankArt()
    {
        var blocks = VStack(0,
            Fill(Txt, 1, 26, 4).Align(HorizontalAlignment.Left).Top(10),
            Fill(Hex(0xD9D9D4), 1, 38, 2).Align(HorizontalAlignment.Left).Top(4));
        for (var i = 0; i < 3; i++)
            blocks.Children.Add(new Rectangle { Width = 47, Height = 12, RadiusX = 2.5, RadiusY = 2.5, Stroke = Brush(0xD6D6D1), StrokeThickness = 1, StrokeDashArray = [3, 2], HorizontalAlignment = HorizontalAlignment.Left }.Top(6));
        var paper = new Border
        {
            Width = 64, Height = 88, Padding = new Thickness(8, 0, 0, 0), Background = Brush(V3.White), CornerRadius = new CornerRadius(4),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), Child = blocks,
        };
        var canvas = new Canvas { Width = 200, Height = 88, IsHitTestVisible = false };
        canvas.Children.Add(paper.At(70, 0));
        canvas.Children.Add(Tag("教育经历").At(0, 18));
        canvas.Children.Add(Tag("项目经历").At(140, 48));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(canvas, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return canvas;

        static Border Tag(string text) => new()
        {
            Width = 60, Height = 24, CornerRadius = new CornerRadius(6), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            Child = Sans(text, 10.5, Sub, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        };
    }

    /// <summary>02.1 ③ 搜索没有结果插图：两侧两张小纸、中间一张稍大的纸，右下压一个放大镜。</summary>
    static FrameworkElement SearchArt()
    {
        var canvas = new Canvas { Width = 81, Height = 47, IsHitTestVisible = false };
        canvas.Children.Add(Paper(32, 43).At(0, 3));
        canvas.Children.Add(Paper(32, 43).At(49, 3));
        canvas.Children.Add(Paper(35, 47).At(23, 0));
        canvas.Children.Add(new Border
        {
            Width = 17, Height = 17, CornerRadius = new CornerRadius(8.5), Background = Brush(V3.White),
            Child = Icon("magnifyingglass", 13, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        }.At(48, 25));
        return canvas;

        static Border Paper(double width, double height)
        {
            var lines = VStack(3, Fill(Txt, 0.5, width * 0.4, 2).Align(HorizontalAlignment.Left));
            for (var i = 0; i < 3; i++) lines.Children.Add(Fill(V3.Line, 0.5, width * 0.6, 1.5).Align(HorizontalAlignment.Left));
            return new Border
            {
                Width = width, Height = height, Padding = new Thickness(5), CornerRadius = new CornerRadius(1.6), Background = Brush(V3.White),
                BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), Child = lines,
            };
        }
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
        Add("重命名", "character.cursor.ibeam", () => ResumeTitleSheet.Show(XamlRoot, ResumeTitleSheet.Mode.Rename, resume,
            title => { _notice = ($"已将简历重命名为「{title}」", false); _ = LoadAsync(); },
            copy: () => CheckCapacity(() => Copy(resume))));
        Add("复制为新简历", "doc.on.doc", () => CheckCapacity(() => Copy(resume)));
        Add("分享链接", "link", () => ResumeShareSheet.Show(XamlRoot, resume));
        Add(exporting ? "正在导出…" : "导出 PDF", "arrow.down.doc", () => _ = ExportAsync(resume), !exporting);
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("删除", "trash", () => ResumeDeleteSheet.Show(XamlRoot, resume, DeleteAsync), danger: true);
        return menu;
    }

    void Copy(ResumeSummary resume) => ResumeTitleSheet.Show(XamlRoot, ResumeTitleSheet.Mode.Copy, resume, title => { _notice = ($"已复制为「{title}」", false); _ = LoadAsync(); });

    /// <summary>
    /// 02.1c 导入任务卡：#F4F4F2 圆角底里一张白纸，中间一个白色状态签（解析中带转圈）；失败时淡红底、红边、红字，右下「移除记录」。
    /// </summary>
    FrameworkElement ImportCard(JsonNode task)
    {
        var failed = task.Text("upload_status") == "failed" || task.Text("parse_status") == "failed";
        var uploading = task.Text("upload_status") == "uploading";
        var stage = uploading ? "正在上传" : "正在解析";
        var label = failed ? (task.Text("upload_status") == "failed" ? "上传失败" : "解析失败") : uploading ? "上传中" : "解析中";
        var failLine = Hex(0xF3D6D6);
        var chipBody = HStack(6);
        if (!failed) chipBody.Children.Add(new ProgressRing { Width = 12, Height = 12, IsActive = true });
        chipBody.Children.Add(Sans(label, 11.5, failed ? Red : Txt, Medium).Align(v: VerticalAlignment.Center));
        var chip = new Border
        {
            Child = chipBody, Padding = new Thickness(14, 0, 14, 0), Height = failed ? 28 : 32, CornerRadius = new CornerRadius(8),
            Background = Brush(V3.White), BorderBrush = Brush(failed ? failLine : Cl), BorderThickness = new Thickness(1),
        }.Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        var paper = new Border
        {
            Margin = new Thickness(23, 19, 23, 19), CornerRadius = new CornerRadius(3.5), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        };
        var stageBox = new A4Box(new Border
        {
            CornerRadius = new CornerRadius(10), Background = Brush(failed ? Hex(0xFDF5F5) : Field),
            BorderBrush = Brush(failed ? failLine : Clear), BorderThickness = new Thickness(1), Child = Layer(paper, chip),
        });
        UIElement foot = Sans(failed ? $"{label} · 可以移除后重新导入" : $"{stage} · 请稍候", 11, failed ? Red : Hint);
        if (failed) foot = Spread(foot, new V3Button("移除记录", () => _ = DeleteImportAsync(task), height: 25, small: true), 4);
        return VStack(6,
            stageBox,
            Sans(task.Text("source_filename"), 13, Txt, Medium).Frame(height: 16).Top(4),
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
