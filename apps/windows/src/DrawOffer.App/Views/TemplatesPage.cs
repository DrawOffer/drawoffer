using System.Globalization;
using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.App.Paper;
using DrawOffer.App.Shell;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using DrawOffer.Core.Paper;
using DrawOffer.Core.Session;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views;

/// <summary>
/// 简历模板（Web `features/templates/ResumeTemplatesPage.tsx`），对应 Mac `TemplatesView`。
/// 登录后读取 `GET /api/resume-templates` 的真实启用模板与使用次数，并可直接创建简历；
/// 游客没有模板接口权限，只展示随包的虚构示例，“使用此模板”先登录，登录后按模板 key 匹配真实模板继续创建。
/// 账号变化时外壳会重建本页（Mac `.onChange(of: account)` 清空状态）。
/// </summary>
public sealed class TemplatesPage : Page
{
    public const int PageSize = 20;

    readonly StackPanel _body = new();
    readonly CancellationTokenSource _cancel = new();
    IReadOnlyList<ResumeTemplate> _templates = [];
    string _source = "";
    bool _loading;
    string? _loadError;
    /// <summary>Web `TemplateFilterPopover`：风格与适用场景多选，同组内任一命中、两组同时满足。</summary>
    readonly List<string> _selectedStyles = [];
    readonly List<string> _selectedUses = [];
    int _page = 1;
    V3Overlay? _preview, _creating;
    /// <summary>预览里点了主按钮：预览关闭后再进入创建（Mac `createAfterDismiss`）。</summary>
    ResumeTemplate? _createAfterDismiss;

    // 工具栏常驻：筛选浮层锚在 TemplateFilter 上，筛选变化时只换结果区，不重建锚点
    readonly TextBlock _found = Sans("", 12, Sub);
    readonly BorderControl _clear;
    readonly TemplateFilter _filter;
    readonly StackPanel _results = new();

    static string Account => App.Session.Phase == SessionViewModel.SessionPhase.SignedIn ? App.Session.User?.Id ?? "" : "";
    static bool Guest => Account.Length == 0;
    bool Ready => _source == (Guest ? "guest" : Account);

    List<ResumeTemplate> Filtered => _templates.Where(t =>
        (_selectedStyles.Count == 0 || _selectedStyles.Intersect(t.StyleCategories).Any())
        && (_selectedUses.Count == 0 || _selectedUses.Intersect(t.UseCases).Any())).ToList();
    int PageCount => Math.Max(1, (Filtered.Count + PageSize - 1) / PageSize);
    List<ResumeTemplate> PageItems => Filtered.Skip((Math.Min(_page, PageCount) - 1) * PageSize).Take(PageSize).ToList();
    int FilterCount => _selectedStyles.Count + _selectedUses.Count;

    /// <summary>与 Web 相同的筛选空态文案。</summary>
    string EmptyMessage
    {
        get
        {
            static string Quote(IEnumerable<string> values) => string.Concat(values.Select(v => $"「{v}」"));
            return (_selectedStyles.Count == 0, _selectedUses.Count == 0) switch
            {
                (false, true) => $"{Quote(_selectedStyles)}风格下没有模板。试试换一个筛选条件。",
                (true, false) => $"{Quote(_selectedUses)}场景下没有模板。试试换一个筛选条件。",
                (false, false) => $"{Quote(_selectedStyles)}风格和{Quote(_selectedUses)}场景同时选中时没有模板。试试减少一个筛选条件。",
                _ => "没有符合条件的模板",
            };
        }
    }

    public TemplatesPage()
    {
        _clear = new BorderControl { Child = Sans("清除筛选", 12, Txt, Medium), Background = Brush(Clear) }.OnTap(ClearFilters, "清除筛选");
        _filter = new TemplateFilter(_selectedStyles, _selectedUses, FiltersChanged);
        Content = new V3Page(_body);
        Loaded += (_, _) => { Render(); _ = LoadAsync(); };
        Unloaded += (_, _) => { _cancel.Cancel(); _createAfterDismiss = null; _preview?.Close(); _creating?.Close(); };
    }

    void Render()
    {
        _body.Children.Clear();
        _body.Children.Add(V3PageHead.Make(["TEMPLATES", Ready ? $"{_templates.Count}" : "–"], "简历模板",
            "浏览当前可用版式，选择后填写简历名称并进入编辑器。", compact: true));
        if (Guest) _body.Children.Add(Sans("当前展示随包的虚构示例，可离线预览；登录后显示线上全部可用模板。", 12, Fnt).Top(6));
        if (_loadError is { } error && !Ready)
        {
            var retry = new V3Button("重新加载", () => _ = LoadAsync(), V3Button.Kind.Ghost, icon: "arrow.clockwise") { Enabled = !_loading };
            _body.Children.Add(Centered(64,
                Icon("arrow.clockwise", 26, Fnt).Frame(height: 150),
                Serif("模板暂时无法加载", 18).Top(13),
                Sans(error, 13, Sub),
                retry.Top(28)));
        }
        else if (!Ready)
        {
            // ProgressView("正在加载简历模板…")：转圈在上、文字在下，占 250 高
            var loading = VStack(8, new ProgressRing { IsActive = true, Width = 20, Height = 20 }, Sans("正在加载简历模板…", 13))
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            _body.Children.Add(new Grid { MinHeight = 250, Children = { loading } });
        }
        else if (_templates.Count == 0)
        {
            _body.Children.Add(Centered(64,
                Serif("当前没有可用模板", 18),
                Sans("模板启用后会显示在这里，你仍可以从已有简历继续编辑。", 13, Sub),
                new V3Button("返回全部简历", BackToResumes, V3Button.Kind.Ghost, icon: "doc").Top(28)));
        }
        else
        {
            // `.tpl-toolbar`：距头部 28、高 30、间距 12
            var toolbar = Columns(12, (Auto, Detach(_found)), (Auto, Detach(_clear)), (Star(), new Border()),
                (Auto, Sans("按展示顺序", 12, Fnt).Pad(0, 0, 4, 0)), (Auto, Detach(_filter)));
            foreach (var child in toolbar.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
            toolbar.Height = 30;
            _body.Children.Add(toolbar.Top(28));
            _body.Children.Add(Detach(_results));
            RenderResults();
        }
    }

    /// <summary>筛选或翻页后只更新工具栏文字与结果区。</summary>
    void RenderResults()
    {
        var filtered = Filtered;
        _found.Text = $"找到 {filtered.Count} 套模板";
        _clear.Visibility = FilterCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        _filter.Refresh();
        _results.Children.Clear();
        if (filtered.Count == 0)
        {
            _results.Children.Add(Centered(42,
                Icon("line.3.horizontal.decrease", 24, Fnt).Frame(height: 150),
                Serif("没有符合条件的模板", 18).Top(13),
                Sans(EmptyMessage, 13, Sub),
                new V3Button("清除筛选", ClearFilters, V3Button.Kind.Ghost, icon: "line.3.horizontal.decrease").Top(28)));
        }
        var grid = new AdaptiveGrid(200, 20, 32).Top(24);
        foreach (var template in PageItems) grid.Children.Add(Cell(template));
        _results.Children.Add(grid);
        if (filtered.Count > 0)
            _results.Children.Add(V3Pagination.Make(Math.Min(_page, PageCount), filtered.Count, page => { _page = page; RenderResults(); }, PageSize));
    }

    FrameworkElement Cell(ResumeTemplate template)
    {
        var chips = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        foreach (var label in template.StyleCategories.Concat(template.UseCases)) chips.Children.Add(V3Chip.Make(label).Align(v: VerticalAlignment.Center));
        var meta = Columns(6, (Star(), chips),
            (Auto, template.UseCount is { } count ? Number($"{FormatUses(count)} 使用", 10.5, Fnt, Regular).Align(v: VerticalAlignment.Center) : new Border()));
        meta.Height = 20;
        var body = VStack(0,
            TemplateThumbnail.Make(template, Guest),
            Sans(template.Name, 14, Txt, Medium).Frame(height: 20).Top(14),
            meta.Top(4));
        return new BorderControl { Child = body, Background = Brush(Clear) }.OnTap(() => ShowPreview(template), $"查看模板：{template.Name}");
    }

    async Task LoadAsync()
    {
        var owner = Account;
        _loading = true; _loadError = null;
        Render();
        try
        {
            IReadOnlyList<ResumeTemplate> result;
            if (owner.Length == 0) result = await GuestTemplates.LoadAsync(_cancel.Token);
            // Mac `HTTPAPIClient.listResumeTemplates` 在客户端层过滤退役模板；Windows 客户端层没有过滤，在这里补上
            else result = (await App.Session.Api.ListResumeTemplatesAsync(_cancel.Token)).Where(t => !ResumeRequest.RetiredTemplateKeys.Contains(t.Key)).ToList();
            _cancel.Token.ThrowIfCancellationRequested();
            if (owner != Account) return;
            _templates = result; _source = owner.Length == 0 ? "guest" : owner;
        }
        catch (OperationCanceledException) { return; }
        catch (Exception error)
        {
            if (owner != Account) return;
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) { _loading = false; App.Session.ReportAuthenticationFailure(); return; }
            _loadError = owner.Length == 0 ? "随包示例读取失败，请重新打开模板页。" : "请检查网络后重试，已有简历不会受到影响。";
        }
        if (owner == Account) _loading = false;
        Render();
        OpenPendingCreate();
    }

    void ClearFilters() { _selectedStyles.Clear(); _selectedUses.Clear(); FiltersChanged(); }

    void FiltersChanged() { _page = 1; RenderResults(); }

    static void BackToResumes() => WorkspaceShell.Current.Select(WorkspaceSection.Resumes);

    void Use(ResumeTemplate template)
    {
        if (Guest) _ = WorkspaceShell.Current.RequestLoginAsync(template);
        else OpenCreate(template);
    }

    /// <summary>登录前选的是随包示例，ID 与线上不同，按模板 key 找到对应的真实模板。</summary>
    void OpenPendingCreate()
    {
        var shell = WorkspaceShell.Current;
        if (Guest || !Ready || shell.PendingCreateKey is not { } key) return;
        shell.PendingCreateKey = null;
        if (_templates.FirstOrDefault(t => t.Key == key) is { } template) OpenCreate(template);
    }

    void ShowPreview(ResumeTemplate template)
    {
        if (_preview is { IsOpen: true } || XamlRoot is null) return;
        // Web 预览只在当前这一页里切换上一套 / 下一套
        var list = PageItems;
        var guest = Guest;
        _preview = V3Overlay.Show(XamlRoot, close => new TemplatePreview(template, guest, list, XamlRoot.Size.Height, close, picked =>
        {
            _createAfterDismiss = picked;
            close();
        }).Root, dismissed: () =>
        {
            _preview = null;
            if (_createAfterDismiss is { } picked) { _createAfterDismiss = null; Use(picked); }
        });
    }

    void OpenCreate(ResumeTemplate template)
    {
        if (_creating is { IsOpen: true } || XamlRoot is null) return;
        _creating = V3Overlay.Show(XamlRoot, close => CreateResumeSheet.Make(template, close, id =>
        {
            close();
            // Mac `onCreated`：editResumeID = id.isEmpty ? nil : id; selection = .resumes
            if (id.Length == 0) WorkspaceShell.Current.Select(WorkspaceSection.Resumes);
            else WorkspaceShell.Current.EditResume(id);
        }), dismissed: () => _creating = null);
    }

    /// <summary>Web `formatTemplateUses`：千以下写原数，千以上写成 3.2k。</summary>
    public static string FormatUses(int count)
    {
        if (count < 1000) return count.ToString(CultureInfo.InvariantCulture);
        var value = Math.Round(count / 100.0, MidpointRounding.AwayFromZero) / 10;
        return value == Math.Round(value) ? $"{(int)value}k" : value.ToString("0.0", CultureInfo.InvariantCulture) + "k";
    }

    /// <summary>`VStack(spacing: 8) { … }.frame(maxWidth: .infinity).padding(.top, n)`：居中的状态块。</summary>
    static StackPanel Centered(double top, params FrameworkElement[] children)
    {
        foreach (var child in children) child.HorizontalAlignment = HorizontalAlignment.Center;
        return VStack(8, children).Top(top);
    }

    /// <summary>常驻元素换到新的父容器前先从旧容器取下。</summary>
    static T Detach<T>(T element) where T : FrameworkElement
    {
        if (element.Parent is Panel panel) panel.Children.Remove(element);
        else if (element.Parent is Border border) border.Child = null;
        return element;
    }

    /// <summary>真实模板经会话准备私有图片；随包示例不读取会话、不发请求。</summary>
    internal static Task<PaperPreparation> PreparePaperAsync(ResumeTemplate template, bool guest, CancellationToken ct) =>
        guest ? GuestTemplates.PrepareAsync(template, ct) : App.Session.Api.PreparePaperAsync(template.ToRenderRequest(), ct);
}

/// <summary>
/// `LazyVGrid(columns: [GridItem(.adaptive(minimum:), spacing:)], alignment: .leading, spacing:)`：
/// 按最小列宽放尽量多的等宽列，列距 columnSpacing、行距 rowSpacing。
/// </summary>
sealed class AdaptiveGrid(double minimum, double columnSpacing, double rowSpacing) : Panel
{
    int _columns = 1;
    double _width;

    protected override Size MeasureOverride(Size available)
    {
        var total = double.IsInfinity(available.Width) ? minimum : available.Width;
        _columns = Math.Max(1, (int)Math.Floor((total + columnSpacing) / (minimum + columnSpacing)));
        _width = (total - columnSpacing * (_columns - 1)) / _columns;
        double height = 0;
        for (var start = 0; start < Children.Count; start += _columns)
        {
            double row = 0;
            for (var i = start; i < Math.Min(Children.Count, start + _columns); i++)
            {
                Children[i].Measure(new Size(_width, double.PositiveInfinity));
                row = Math.Max(row, Children[i].DesiredSize.Height);
            }
            height += row + (start > 0 ? rowSpacing : 0);
        }
        return new Size(total, height);
    }

    protected override Size ArrangeOverride(Size final)
    {
        double y = 0;
        for (var start = 0; start < Children.Count; start += _columns)
        {
            var end = Math.Min(Children.Count, start + _columns);
            double row = 0;
            for (var i = start; i < end; i++) row = Math.Max(row, Children[i].DesiredSize.Height);
            for (var i = start; i < end; i++) Children[i].Arrange(new Rect((i - start) * (_width + columnSpacing), y, _width, row));
            y += row + rowSpacing;
        }
        return final;
    }
}

/// <summary>`.aspectRatio(210.0 / 297, contentMode: .fit)`：宽度跟随容器，高度按 A4 比例。</summary>
sealed class AspectPanel(double ratio) : Panel
{
    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsInfinity(available.Width) ? 200 : available.Width;
        var size = new Size(width, width / ratio);
        foreach (var child in Children) child.Measure(size);
        return size;
    }

    protected override Size ArrangeOverride(Size final)
    {
        foreach (var child in Children) child.Arrange(new Rect(0, 0, final.Width, final.Height));
        return final;
    }
}

/// <summary>缩略纸面（Mac `TemplateThumbnail`）：A4 比例白底、圆角 6、#D3D3CE 描边；新建简历弹窗与编辑器模板面板共用。</summary>
public static class TemplateThumbnail
{
    public static FrameworkElement Make(ResumeTemplate template, bool guest)
    {
        var cancel = new CancellationTokenSource();
        var failed = false;
        var content = new Grid { Background = Brush(V3.White), CornerRadius = new CornerRadius(6) };
        var progress = new ProgressRing { IsActive = true, Width = 16, Height = 16, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        content.Children.Add(progress);
        void Fail()
        {
            if (failed) return;
            failed = true;
            progress.Visibility = Visibility.Collapsed;
            content.Children.Add(new Border
            {
                Child = Label("预览不可用", 10), Padding = new Thickness(8), Background = Brush(V3.White),
                HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            });
        }
        var stroke = new Border { CornerRadius = new CornerRadius(6), BorderBrush = Brush(0xD3D3CE), BorderThickness = new Thickness(1), IsHitTestVisible = false };
        var panel = new AspectPanel(210.0 / 297) { Children = { content, stroke } };
        panel.Loaded += async (_, _) =>
        {
            try
            {
                var result = await TemplatesPage.PreparePaperAsync(template, guest, cancel.Token);
                cancel.Token.ThrowIfCancellationRequested();
                // 794×1123 的纸面按宽度缩放，左上对齐，不接收点按
                var paper = new ResumePaperView { Width = 794, Height = 1123, IsHitTestVisible = false };
                paper.RenderFailed += (_, _) => Fail();
                progress.Visibility = Visibility.Collapsed;
                content.Children.Insert(0, new Viewbox
                {
                    Child = paper, Stretch = Stretch.Uniform, IsHitTestVisible = false,
                    HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
                });
                paper.Render(result.Request);
            }
            catch (OperationCanceledException) { }
            catch (Exception) { Fail(); }
        };
        panel.Unloaded += (_, _) => cancel.Cancel();
        return panel;
    }
}

/// <summary>
/// 03.1a 模板预览（Mac `TemplatePreview`），对齐 Web `TemplatePreviewDialog`（760×900，放不下时随窗口收矮）：标题与标签、使用次数，
/// 点阵舞台里 420 宽（100%）的 A4，两侧圆形切换钮（循环，← → 同样），底部缩放条，页脚「第 n / N 套」、取消与主按钮。
/// </summary>
sealed class TemplatePreview
{
    const double MinZoom = 0.5, MaxZoom = 2.0, Step = 0.1;
    /// <summary>100% 时纸面宽 420（A4 794 × 0.5292）。</summary>
    const double Base = 0.5292;

    readonly bool _guest;
    readonly IReadOnlyList<ResumeTemplate> _list;
    readonly Action _close;
    readonly Action<ResumeTemplate> _use;
    readonly Grid _content = new();
    ResumeTemplate _template;
    CancellationTokenSource _cancel = new();
    double _zoom = 1.0;
    double _height = 1123;
    string? _error;
    ResumePaperView? _paper;
    Border? _paperBox;
    Viewbox? _paperScale;
    TextBlock? _zoomLabel;
    BorderControl? _zoomOut, _zoomIn;

    public Border Root { get; }

    public TemplatePreview(ResumeTemplate template, bool guest, IReadOnlyList<ResumeTemplate> list, double windowHeight, Action close, Action<ResumeTemplate> use)
    {
        _template = template; _guest = guest; _list = list; _close = close; _use = use;
        Root = V3Dialog.Frame(_content, 760);
        // Web：760×900，窗口放不下时减去上下各 24 的遮罩留白
        Root.Height = Math.Min(900, windowHeight - 48);
        // ← → 切换上一套 / 下一套；用 PreviewKeyDown 抢在滚动区之前
        Root.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Left && Previous is { } previous) { e.Handled = true; Show(previous); }
            else if (e.Key == Windows.System.VirtualKey.Right && Next is { } next) { e.Handled = true; Show(next); }
        };
        Root.Unloaded += (_, _) => _cancel.Cancel();
        Show(template);
    }

    int? Index { get { var i = _list.ToList().FindIndex(t => t.Id == _template.Id); return i < 0 ? null : i; } }
    ResumeTemplate? Previous => Index is { } i && _list.Count > 1 ? _list[(i - 1 + _list.Count) % _list.Count] : null;
    ResumeTemplate? Next => Index is { } i && _list.Count > 1 ? _list[(i + 1) % _list.Count] : null;

    void Show(ResumeTemplate template)
    {
        _cancel.Cancel();
        _cancel = new CancellationTokenSource();
        _template = template;
        _paper = null; _error = null; _height = 1123;
        Render();
        _ = LoadAsync(template, _cancel.Token);
    }

    async Task LoadAsync(ResumeTemplate template, CancellationToken ct)
    {
        try
        {
            var result = await TemplatesPage.PreparePaperAsync(template, _guest, ct);
            ct.ThrowIfCancellationRequested();
            var paper = new ResumePaperView { Width = 794, Height = _height };
            paper.Rendered += (_, height) => { _height = Math.Max(1123, height); UpdateZoom(); };
            paper.RenderFailed += (_, message) => _error = message;
            _paper = paper;
            Render();
            paper.Render(result.Request);
        }
        catch (OperationCanceledException) { }
        catch (Exception) { if (!ct.IsCancellationRequested) { _error = "预览加载失败，请重试。"; Render(); } }
    }

    void Render()
    {
        _content.Children.Clear();
        _content.RowDefinitions.Clear();
        _content.RowDefinitions.Add(new RowDefinition { Height = Px(100) });
        _content.RowDefinitions.Add(new RowDefinition { Height = Star() });
        _content.RowDefinitions.Add(new RowDefinition { Height = Auto });

        // 头部：标题 20 半粗（29 高、右留 40 给关闭钮），标签与使用次数（20 高），左右 32、顶 28
        var tags = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Height = 20 };
        foreach (var label in _template.StyleCategories.Concat(_template.UseCases)) tags.Children.Add(V3Chip.Make(label).Align(v: VerticalAlignment.Center));
        if (_template.UseCount is { } count) tags.Children.Add(Number($"{TemplatesPage.FormatUses(count)} 使用", 11, Fnt, Regular).Pad(6, 0, 0, 0).Align(v: VerticalAlignment.Center));
        var head = VStack(7, Label(_template.Name, 20, Txt, Semibold).Frame(height: 29).Pad(0, 0, 40, 0), tags).Pad(32, 28, 32, 0);
        head.VerticalAlignment = VerticalAlignment.Top;
        var close = new BorderControl { Width = 28, Height = 28, Background = Brush(Clear), Child = Icon("xmark", 12, Fnt).Align(HorizontalAlignment.Center, VerticalAlignment.Center) }
            .OnTap(_close, "关闭").Align(HorizontalAlignment.Right, VerticalAlignment.Top).Pad(0, 26, 26, 0);
        _content.Children.Add(head);
        _content.Children.Add(close);

        // 舞台：点阵底 + 可双向滚动的纸面 + 两侧切换钮 + 底部缩放条，圆角 11，左右 31、底 24
        var scroll = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Auto, VerticalScrollMode = ScrollMode.Auto,
        };
        var host = new Grid();
        scroll.SizeChanged += (_, e) => host.MinWidth = e.NewSize.Width;
        if (_paper is not null)
        {
            Detach(_paper);
            _paperScale = new Viewbox { Child = _paper, Stretch = Stretch.Fill };
            _paperBox = new Border
            {
                Child = _paperScale, CornerRadius = new CornerRadius(4), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(76, 34, 76, 80),
            }.Elevate(12);
            host.Children.Add(_paperBox);
        }
        else if (_error is { } error) host.Children.Add(Sans(error, 13, Red).Pad(40, 40, 40, 40).Align(HorizontalAlignment.Center, VerticalAlignment.Top));
        else host.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16, Margin = new Thickness(40), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top });
        scroll.Content = host;

        _zoomOut = ZoomButton("−", "缩小模板", () => Change(-1));
        _zoomIn = ZoomButton("+", "放大模板", () => Change(1));
        _zoomLabel = Number("", 11.5, Txt, Medium);
        AutomationProperties.SetName(_zoomLabel, "模板预览缩放比例");
        var zoomRow = Columns(0, (Auto, _zoomOut), (Star(), _zoomLabel.Align(HorizontalAlignment.Center, VerticalAlignment.Center)), (Auto, _zoomIn));
        zoomRow.Padding = new Thickness(6, 0, 6, 0);
        var zoomBar = new Border
        {
            Child = zoomRow, Width = 132, Height = 32, CornerRadius = new CornerRadius(8), Background = Brush(V3.White),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, 16),
        }.Elevate(3);
        AutomationProperties.SetName(zoomBar, "模板预览缩放");

        var stage = new Grid { CornerRadius = new CornerRadius(11), Margin = new Thickness(31, 0, 31, 24) };
        stage.Children.Add(new V3DotStage(null, height: null));
        stage.Children.Add(scroll);
        // 两侧圆形切换钮（左右各 20），只占两侧，不挡住纸面滚动
        stage.Children.Add(NavButton(Previous, left: true).Align(HorizontalAlignment.Left, VerticalAlignment.Center).Pad(20, 0, 0, 0));
        stage.Children.Add(NavButton(Next, left: false).Align(HorizontalAlignment.Right, VerticalAlignment.Center).Pad(0, 0, 20, 0));
        stage.Children.Add(zoomBar);
        Grid.SetRow(stage, 1);
        _content.Children.Add(stage);

        // 页脚：「第 n / N 套」、取消（36 高 80 宽）与主按钮（36 高 100 宽），左右 32、至少 88 高、顶线
        var buttons = HStack(10,
            new V3Button("取消", _close, V3Button.Kind.Ghost, height: 36, width: 80),
            new V3Button(_guest ? "使用此模板" : "创建简历", () => _use(_template), V3Button.Kind.Dark, height: 36, width: 100));
        UIElement position = Index is { } index ? Sans($"第 {index + 1} / {_list.Count} 套", 11.5, Fnt) : new Border();
        var foot = Spread(position, buttons, 10);
        foot.Padding = new Thickness(32, 0, 32, 0);
        foot.MinHeight = 88;
        var footBorder = new Border { Child = foot, BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 1, 0, 0) };
        Grid.SetRow(footBorder, 2);
        _content.Children.Add(footBorder);
        UpdateZoom();
    }

    /// <summary>缩放只改纸面外框与百分比，不重新渲染纸面。</summary>
    void UpdateZoom()
    {
        var scale = _zoom * Base;
        if (_paper is not null) _paper.Height = _height;
        if (_paperBox is not null) { _paperBox.Width = 794 * scale; _paperBox.Height = _height * scale; }
        if (_zoomLabel is not null) _zoomLabel.Text = $"{(int)Math.Round(_zoom * 100, MidpointRounding.AwayFromZero)}%";
        if (_zoomOut is not null) _zoomOut.Opacity = _zoom > MinZoom ? 1 : 0.35;
        if (_zoomIn is not null) _zoomIn.Opacity = _zoom < MaxZoom ? 1 : 0.35;
    }

    void Change(double direction)
    {
        _zoom = Math.Min(MaxZoom, Math.Max(MinZoom, Math.Round((_zoom + direction * Step) * 100, MidpointRounding.AwayFromZero) / 100));
        UpdateZoom();
    }

    BorderControl NavButton(ResumeTemplate? target, bool left)
    {
        var button = new BorderControl
        {
            Width = 36, Height = 36, CornerRadius = new CornerRadius(18), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            Child = Icon(left ? "chevron.left" : "chevron.right", 12, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            Opacity = target is null ? 0.4 : 1,
        }.Elevate(3);
        var name = target is not null ? $"{(left ? "上一个" : "下一个")}模板：{target.Name}" : left ? "没有上一个模板" : "没有下一个模板";
        return button.OnTap(() => { if (target is not null) Show(target); }, name, () => target is not null);
    }

    BorderControl ZoomButton(string title, string label, Action action)
    {
        var plus = title == "+";
        return new BorderControl { Width = 24, Height = 24, Background = Brush(Clear), Child = Label(title, 14, Sub, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center) }
            .OnTap(action, label, () => plus ? _zoom < MaxZoom : _zoom > MinZoom);
    }

    static T Detach<T>(T element) where T : FrameworkElement
    {
        if (element.Parent is Viewbox box) box.Child = null;
        else if (element.Parent is Panel panel) panel.Children.Remove(element);
        return element;
    }
}

/// <summary>
/// Web 模板页的“创建简历”弹窗（Mac `TemplatesView.swift` 私有的 `CreateResumeSheet`）：基于所选模板创建，输入一个便于识别的名称。
/// 创建接口没有幂等标识；结果不确定时提示先查看简历列表，避免重复创建。
/// </summary>
static class CreateResumeSheet
{
    public static FrameworkElement Make(ResumeTemplate template, Action close, Action<string> created)
    {
        var busy = false;
        var uncertain = false;
        string? error = null;
        var host = new Border();
        V3TextInput? input = null;

        void Close() { if (!busy) close(); }

        async void Submit()
        {
            if (busy) return;
            if (uncertain) { created(""); return; }
            var name = (input!.Text).Trim();
            if (name.Length == 0) { error = "请输入简历名称。"; input.Error = error; return; }
            busy = true; error = null;
            Render();
            try
            {
                var result = await App.Session.Api.CareerRequestAsync("/api/resumes", "POST", [],
                    new JsonObject { ["title"] = name, ["template_id"] = template.Id, ["guide"] = true });
                busy = false;
                created(result["resume"]?["id"].String() ?? "");
                return;
            }
            catch (Exception failure)
            {
                var unauthorized = failure is ApiException { Status: System.Net.HttpStatusCode.Unauthorized };
                if (unauthorized) App.Session.ReportAuthenticationFailure();
                if (failure is ApiException && !unauthorized) error = Message(failure);
                else if (unauthorized) error = ResumeRequest.ErrorMessage(failure, "");
                else
                {
                    uncertain = true;
                    error = "网络中断，无法确认是否已创建。请先查看简历列表，避免重复创建。";
                }
            }
            busy = false;
            Render();
        }

        void Render()
        {
            if (input is null)
            {
                input = new V3TextInput("简历名称", "例如：2026 产品经理简历", submit: Submit);
                input.Box.TextChanged += (_, _) => { if (error is not null && !uncertain) { error = null; input.Error = null; } };
            }
            if (input.Parent is Panel old) old.Children.Remove(input);
            input.Error = error;
            input.Box.IsEnabled = !busy;
            var content = VStack(0,
                V3DialogHead.Make("创建简历", $"基于“{template.Name}”创建简历，输入一个便于识别的名称。"),
                input.Top(20));
            var cancel = new V3Button("取消", Close, V3Button.Kind.Ghost, height: 36) { Enabled = !busy };
            var confirm = new V3Button(busy ? "正在创建…" : uncertain ? "查看简历列表" : "确认创建", Submit, V3Button.Kind.Dark, height: 36) { Enabled = !busy };
            host.Child = V3Dialog.Make(content, [cancel, confirm], Close, closable: !busy);
        }

        Render();
        // 创建中不响应 Esc（与关闭按钮一同隐藏）
        host.KeyDown += (_, e) => { if (busy && e.Key == Windows.System.VirtualKey.Escape) e.Handled = true; };
        return host;
    }

    /// <summary>Web `createErrorMessage`。</summary>
    static string Message(Exception error) => (error as ApiException)?.Code switch
    {
        "RESUME_LIMIT_REACHED" => $"简历数量已达上限（{ResumeRequest.MaximumPerUser} 份），请删除不需要的简历后重试。",
        "INVALID_RESUME_TITLE" => "请输入 1–255 个字符的简历名称。",
        "RESUME_TITLE_CONFLICT" => "该名称已经存在，请换一个名称。",
        "TEMPLATE_INACTIVE" => "所选模板已不可用，请重新选择。",
        _ => "创建简历失败，请稍后重试。",
    };
}

/// <summary>
/// Web `V3TemplateFilter`（Mac `TemplateFilter`）：`.tpl-filter-trigger` 按钮（默认 30 高，圆角 8，有筛选时蓝底蓝字「筛选 · N」）+
/// 300 宽 `.tpl-filter-pop`（标题与重置，风格、适用场景两组胶囊多选）。模板页与编辑器模板面板共用；选中项直接改传入的列表，再调 changed。
/// </summary>
public sealed class TemplateFilter : BorderControl
{
    public static readonly string[] StyleOptions = ["简约", "经典", "现代", "创意"];
    public static readonly string[] UseOptions = ["实习", "校招", "社招"];

    readonly List<string> _styles, _uses;
    readonly Action _changed;
    readonly FontIcon _icon = Icon("line.3.horizontal.decrease", 11);
    readonly TextBlock _title = Sans("", 12, Txt, Medium);
    readonly FontIcon _chevron = Icon("chevron.down", 9);
    readonly RotateTransform _rotation = new() { CenterX = 4.5, CenterY = 4.5 };
    Flyout? _flyout;
    bool _open;

    int Count => _styles.Count + _uses.Count;

    public TemplateFilter(List<string> styles, List<string> uses, Action changed, double height = 30)
    {
        _styles = styles; _uses = uses; _changed = changed;
        _chevron.RenderTransform = _rotation;
        Child = HStack(6, _icon, _title, _chevron);
        Height = height;
        Padding = new Thickness(11, 0, 18, 0);
        CornerRadius = new CornerRadius(8);
        BorderThickness = new Thickness(1);
        this.OnTap(Toggle, "筛选简历模板");
        Refresh();
    }

    /// <summary>筛选值或开合变化后重画按钮与浮层内容。</summary>
    public void Refresh()
    {
        var on = Count > 0;
        _icon.Foreground = Brush(on ? Blue : Sub);
        _title.Text = on ? $"筛选 · {Count}" : "筛选";
        _title.Foreground = Brush(on ? Blue : Txt);
        _chevron.Foreground = Brush(on ? Blue : Fnt);
        _rotation.Angle = _open ? 180 : 0;
        Background = Brush(on ? BlueSoft : _open ? Field : V3.White);
        BorderBrush = Brush(on ? Hex(0xC9D7F4) : Cl);
        if (_flyout is not null) _flyout.Content = Popover();
    }

    void Toggle()
    {
        if (_open) { _flyout?.Hide(); return; }
        _open = true;
        _flyout = V3Popover.Show(this, Popover(), FlyoutPlacementMode.Bottom, padding: 0);
        _flyout.Closed += (_, _) => { _open = false; _flyout = null; Refresh(); };
        Refresh();
    }

    UIElement Popover()
    {
        var reset = new BorderControl { Width = 22, Height = 22, Background = Brush(Clear), Child = Icon("arrow.clockwise", 12, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center), Opacity = Count == 0 ? 0.4 : 1 }
            .OnTap(() => { _styles.Clear(); _uses.Clear(); Changed(); }, enabled: () => Count > 0).Tip("重置筛选");
        var head = Spread(Sans("筛选简历模板", 13, Txt, Medium), reset, 0);
        head.Height = 16;
        var body = VStack(0, head, Group("风格", StyleOptions, _styles).Top(20), Group("适用场景", UseOptions, _uses).Top(18));
        body.Padding = new Thickness(18, 16, 18, 18);
        body.Width = 300;
        AutomationProperties.SetName(body, "筛选简历模板");
        return body;
    }

    StackPanel Group(string title, string[] options, List<string> values)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var option in options)
        {
            var on = values.Contains(option);
            row.Children.Add(new BorderControl
            {
                Child = Sans(option, 12, on ? Blue : Sub, Medium).Align(v: VerticalAlignment.Center),
                Padding = new Thickness(12, 0, 12, 0), Height = 28, CornerRadius = Capsule(28), Background = Brush(on ? BlueSoft : Field),
            }.OnTap(() => { if (on) values.Remove(option); else values.Add(option); Changed(); }, option)
             .Also(chip => { if (on) AutomationProperties.SetItemStatus(chip, "已选中"); }));
        }
        return VStack(9, Sans(title, 11, Fnt).Frame(height: 13), row);
    }

    void Changed() { _changed(); Refresh(); }
}
