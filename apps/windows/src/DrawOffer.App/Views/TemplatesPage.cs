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
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views;

/// <summary>
/// 简历模板（Windows 稿 05 页 03.1，Web `ResumeTemplatesPage.tsx`，Mac `TemplatesView`）：登录后读取 `GET /api/resume-templates` 的真实启用模板与使用次数，
/// 默认按热度排序、四列卡片、每页 20 套；点卡片打开预览（03.1a），确认后创建简历。游客由外壳拦在首页，这里不再展示随包示例。
/// </summary>
public sealed class TemplatesPage : Page
{
    public const int PageSize = 20;

    readonly StackPanel _body = new();
    readonly CancellationTokenSource _cancel = new();
    IReadOnlyList<ResumeTemplate> _templates = [];
    bool _ready, _loading;
    string? _loadError;
    /// <summary>Web `TemplateFilterPopover`：风格与适用场景多选，同组内任一命中、两组同时满足。</summary>
    readonly List<string> _selectedStyles = [];
    readonly List<string> _selectedUses = [];
    int _page = 1;
    /// <summary>排序：默认按热度（`use_count` 降序，同数保持展示顺序），可切回展示顺序。</summary>
    bool _byPopularity = true;
    V3Overlay? _preview, _creating;
    /// <summary>预览里点了主按钮：预览关闭后再进入创建（Mac `createAfterDismiss`）。</summary>
    ResumeTemplate? _createAfterDismiss;

    // 工具栏常驻：筛选浮层锚在 TemplateFilter 上，筛选变化时只换结果区，不重建锚点
    readonly TextBlock _found = Sans("", 12, Sub);
    readonly BorderControl _clear;
    readonly BorderControl _sort;
    readonly TextBlock _sortLabel = Sans("", 12, Hex(0x96968F));
    readonly TemplateFilter _filter;
    readonly StackPanel _results = new();

    List<ResumeTemplate> Filtered
    {
        get
        {
            var items = _templates.Where(t =>
                (_selectedStyles.Count == 0 || _selectedStyles.Intersect(t.StyleCategories).Any())
                && (_selectedUses.Count == 0 || _selectedUses.Intersect(t.UseCases).Any())).ToList();
            return _byPopularity ? items.Select((t, i) => (t, i)).OrderByDescending(x => x.t.UseCount ?? 0).ThenBy(x => x.i).Select(x => x.t).ToList() : items;
        }
    }
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
        _clear = new BorderControl { Child = Sans("清除筛选", 12, Txt, Medium), Height = 28, Padding = new Thickness(10, 0, 10, 0), CornerRadius = new CornerRadius(4), Background = Brush(Clear) };
        _clear.OnHover(h => _clear.Background = Brush(h ? Field : Clear));
        _clear.OnTap(ClearFilters, "清除筛选");
        _sort = new BorderControl { Child = _sortLabel, Background = Brush(Clear) };
        _sort.OnTap(() => V3Popover.Menu(_sort, 140,
            new V3MenuRow("按热度排序", () => SetSort(true), isChecked: _byPopularity),
            new V3MenuRow("按展示顺序", () => SetSort(false), isChecked: !_byPopularity)), "模板排序");
        _filter = new TemplateFilter(_selectedStyles, _selectedUses, FiltersChanged);
        Content = new V3Page(_body, top: 72);
        Loaded += (_, _) => { Render(); _ = LoadAsync(); };
        Unloaded += (_, _) => { _cancel.Cancel(); _createAfterDismiss = null; _preview?.Close(); _creating?.Close(); };
    }

    void SetSort(bool popularity) { _byPopularity = popularity; _page = 1; RenderResults(); }

    void Render()
    {
        _body.Children.Clear();
        _body.Children.Add(V3PageHead.Make(["TEMPLATES", _ready ? $"{_templates.Count} 套" : "–"], "简历模板",
            "浏览当前可用版式，选择后填写简历名称并进入编辑器。", compact: true));
        if (_loadError is { } error && !_ready)
        {
            var retry = new V3Button("重新加载", () => _ = LoadAsync(), V3Button.Kind.Ghost, icon: "arrow.clockwise") { Enabled = !_loading };
            _body.Children.Add(Blank(TemplatesArt.None(), "模板暂时无法加载", error, retry));
        }
        else if (!_ready)
        {
            // 首次加载：ProgressRing 转圈，文案「正在加载简历模板…」
            var loading = VStack(8, new ProgressRing { IsActive = true, Width = 20, Height = 20 }, Sans("正在加载简历模板…", 13, Sub))
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            _body.Children.Add(new Grid { MinHeight = 320, Children = { loading } });
        }
        else if (_templates.Count == 0)
        {
            // ③ 当前没有可用模板：只给「返回全部简历」
            _body.Children.Add(Blank(TemplatesArt.None(), "当前没有可用模板", "模板启用后会显示在这里，你仍可以从已有简历继续编辑。",
                new V3Button("返回全部简历", BackToResumes, V3Button.Kind.Ghost)));
        }
        else
        {
            // 工具栏：距头部 30、高 32；左摘要与清除筛选，右排序与筛选
            var toolbar = Columns(12, (Auto, Detach(_found)), (Auto, Detach(_clear)), (Star(), new Border()), (Auto, Detach(_sort)), (Auto, Detach(_filter)));
            foreach (var child in toolbar.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
            toolbar.Height = 32;
            _body.Children.Add(toolbar.Top(30));
            _body.Children.Add(Detach(_results));
            RenderResults();
        }
    }

    /// <summary>筛选、排序或翻页后只更新工具栏文字与结果区。</summary>
    void RenderResults()
    {
        var filtered = Filtered;
        _found.Text = $"找到 {filtered.Count} 套模板";
        _clear.Visibility = FilterCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        _sortLabel.Text = _byPopularity ? "按热度排序" : "按展示顺序";
        _filter.Refresh();
        _results.Children.Clear();
        if (filtered.Count == 0)
        {
            // ② 没有符合条件的模板：说明里直接点出冲突的条件
            _results.Children.Add(Blank(TemplatesArt.Filter(FilterCount), "没有符合条件的模板", EmptyMessage,
                new V3Button("清除筛选", ClearFilters, V3Button.Kind.Ghost), top: 90));
            return;
        }
        // 卡片 200 宽、列距 20、行距 30
        var grid = new AdaptiveGrid(200, 20, 30).Top(22);
        foreach (var template in PageItems) grid.Children.Add(Cell(template));
        _results.Children.Add(grid);
        if (PageCount > 1)
            _results.Children.Add(V3Pagination.Make(Math.Min(_page, PageCount), filtered.Count, page => { _page = page; RenderResults(); }, PageSize).Top(24));
    }

    /// <summary>
    /// 模板卡片（稿 TemplateCard 200×320）：白底细边的缩略纸面（圆角 6，悬停描边加深），名称 13/500 距纸 14，
    /// 标签（20 高）与「N 使用」一行，距名称 4。
    /// </summary>
    FrameworkElement Cell(ResumeTemplate template)
    {
        var chips = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        foreach (var label in template.StyleCategories.Concat(template.UseCases)) chips.Children.Add(V3Chip.Make(label, height: 20, size: 11).Align(v: VerticalAlignment.Center));
        var meta = Columns(6, (Star(), chips),
            (Auto, template.UseCount is { } count ? Number($"{FormatUses(count)} 使用", 10.5, Hex(0x96968F), Regular).Align(v: VerticalAlignment.Center) : new Border()));
        meta.Height = 20;
        var paper = new Grid { CornerRadius = new CornerRadius(6), Background = Brush(V3.White) };
        paper.Children.Add(new AspectPanel(200.0 / 266) { Children = { TemplateThumbnail.Make(template).Also(t => t.VerticalAlignment = VerticalAlignment.Top) } });
        var frame = new Border { CornerRadius = new CornerRadius(6), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), IsHitTestVisible = false };
        paper.Children.Add(frame);
        var body = VStack(0, paper, Sans(template.Name, 13, Txt, Medium).Frame(height: 16).Top(14), meta.Top(4));
        var cell = new BorderControl { Child = body, Background = Brush(Clear) };
        cell.OnHover(h => frame.BorderBrush = Brush(h ? Hex(0xC9C9C3) : Cl));
        return cell.OnTap(() => ShowPreview(template), $"查看模板：{template.Name}");
    }

    /// <summary>空状态：插图 + 20/600 标题 + 13 说明 + 描边按钮，整体居中。</summary>
    static StackPanel Blank(FrameworkElement art, string title, string message, FrameworkElement action, double top = 150)
    {
        var heading = Serif(title, 20);
        var text = Sans(message, 13, Sub).Wrap();
        text.TextAlignment = TextAlignment.Center;
        var stack = VStack(0, art, heading.Top(58), text.Top(2), action.Top(28));
        foreach (var child in stack.Children.OfType<FrameworkElement>()) child.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Margin = new Thickness(0, top, 0, 40);
        return stack;
    }

    async Task LoadAsync()
    {
        _loading = true; _loadError = null;
        Render();
        try
        {
            // Mac `HTTPAPIClient.listResumeTemplates` 在客户端层过滤退役模板；Windows 客户端层没有过滤，在这里补上
            _templates = (await App.Session.Api.ListResumeTemplatesAsync(_cancel.Token)).Where(t => !ResumeRequest.RetiredTemplateKeys.Contains(t.Key)).ToList();
            _cancel.Token.ThrowIfCancellationRequested();
            _ready = true;
        }
        catch (OperationCanceledException) { return; }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) { _loading = false; App.Session.ReportAuthenticationFailure(); return; }
            _loadError = "请检查网络后重试，已有简历不会受到影响。";
        }
        _loading = false;
        Render();
        OpenPendingCreate();
    }

    void ClearFilters() { _selectedStyles.Clear(); _selectedUses.Clear(); FiltersChanged(); }

    void FiltersChanged() { _page = 1; RenderResults(); }

    static void BackToResumes() => WorkspaceShell.Current.Select(WorkspaceSection.Resumes);

    /// <summary>登录前在首页选的模板：进入本页后按模板 key 找到线上模板继续创建。</summary>
    void OpenPendingCreate()
    {
        var shell = WorkspaceShell.Current;
        if (!_ready || shell.PendingCreateKey is not { } key) return;
        shell.PendingCreateKey = null;
        if (_templates.FirstOrDefault(t => t.Key == key) is { } template) OpenCreate(template);
    }

    void ShowPreview(ResumeTemplate template)
    {
        if (_preview is { IsOpen: true } || XamlRoot is null) return;
        // Web 预览只在当前这一页里切换上一套 / 下一套
        var list = PageItems;
        _preview = V3Overlay.Show(XamlRoot, close => new TemplatePreview(template, list, XamlRoot.Size.Height, close, picked =>
        {
            _createAfterDismiss = picked;
            close();
        }).Root, dismissed: () =>
        {
            _preview = null;
            if (_createAfterDismiss is { } picked) { _createAfterDismiss = null; OpenCreate(picked); }
        });
    }

    void OpenCreate(ResumeTemplate template)
    {
        if (_creating is { IsOpen: true } || XamlRoot is null) return;
        _creating = V3Overlay.Show(XamlRoot, close => CreateResumeSheet.Make(template, close, id =>
        {
            close();
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

    /// <summary>常驻元素换到新的父容器前先从旧容器取下。</summary>
    static T Detach<T>(T element) where T : FrameworkElement
    {
        if (element.Parent is Panel panel) panel.Children.Remove(element);
        else if (element.Parent is Border border) border.Child = null;
        return element;
    }

    /// <summary>线上模板经会话准备私有图片。</summary>
    internal static Task<PaperPreparation> PreparePaperAsync(ResumeTemplate template, CancellationToken ct) =>
        App.Session.Api.PreparePaperAsync(template.ToRenderRequest(), ct);
}

/// <summary>空状态插图（稿 02 · 模板列表状态）。</summary>
static class TemplatesArt
{
    /// <summary>③ 没有可用模板：三张虚线空白纸面。</summary>
    public static FrameworkElement None()
    {
        var canvas = new Canvas { Width = 202, Height = 108 };
        for (var i = 0; i < 3; i++)
        {
            var paper = new Grid { Width = 82, Height = 106, Background = Brush(V3.White) };
            paper.Children.Add(new Microsoft.UI.Xaml.Shapes.Rectangle { Stroke = Brush(Line), StrokeThickness = 1, StrokeDashArray = new DoubleCollection { 3, 2 } });
            paper.Children.Add(VStack(6, Fill(Line, 1.5, 32, 4), Fill(Line, 1, 52, 3)).Pad(10, 12, 0, 0));
            canvas.Children.Add(paper.At(i * 60, 0));
        }
        AutomationProperties.SetAccessibilityView(canvas, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return canvas;
    }

    /// <summary>② 筛选无结果：三张缩略纸面（两侧带色条、中间墨黑），右下圆形漏斗角标与橙色已选数量。</summary>
    public static FrameworkElement Filter(int count)
    {
        var canvas = new Canvas { Width = 214, Height = 124 };
        canvas.Children.Add(Paper(Hex(0x9CC8AE), 66, 108).Also(p => p.Opacity = 0.85).At(0, 10));
        canvas.Children.Add(Paper(Hex(0x9DB4E6), 64, 108).Also(p => p.Opacity = 0.85).At(150, 10));
        canvas.Children.Add(Paper(Txt, 88, 120).Elevate(3).At(62, 0));
        var badge = new Border
        {
            Width = 54, Height = 54, CornerRadius = new CornerRadius(27), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            Child = Icon("line.3.horizontal.decrease", 18, Txt).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        }.Elevate(4);
        canvas.Children.Add(badge.At(124, 66));
        if (count > 0)
            canvas.Children.Add(new Border
            {
                Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = Brush(Orange),
                Child = Number($"{count}", 10, V3.White, Semibold).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            }.At(166, 60));
        AutomationProperties.SetAccessibilityView(canvas, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return canvas;

        static Border Paper(Color accent, double width, double height)
        {
            var lines = VStack(5, Fill(accent, 1, width * 0.45, 4));
            for (var row = 0; row < 3; row++) { lines.Children.Add(Fill(accent, 1, width * 0.25, 3).Top(4)); lines.Children.Add(Fill(Line, 1, width * 0.68, 2)); }
            return new Border { Width = width, Height = height, Background = Brush(V3.White), BorderBrush = Brush(Line), BorderThickness = new Thickness(1), Padding = new Thickness(8), Child = lines };
        }
    }
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
    public static FrameworkElement Make(ResumeTemplate template, bool guest = false)
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
                var result = await TemplatesPage.PreparePaperAsync(template, cancel.Token);
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
/// 03.1a 模板预览（Windows 稿 ContentDialog 680×854，窗口放不下时收矮）：标题 20/600 与标签、使用次数；#F4F4F1 圆角 8 的舞台里
/// 360 宽（100%）的 A4，两侧 32 圆形切换钮（循环，← → 同样），纸下方 109×28 缩放条；CommandSpace 左「第 n / N 套」，取消与「创建简历」各 140 宽。
/// 不放 ×，Esc 关闭。
/// </summary>
sealed class TemplatePreview
{
    const double MinZoom = 0.5, MaxZoom = 2.0, Step = 0.1;
    /// <summary>100% 时纸面宽 360（A4 794 × 0.4534）。</summary>
    const double Base = 360.0 / 794;

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
    TextBlock? _zoomLabel;
    BorderControl? _zoomOut, _zoomIn;

    public Border Root { get; }

    public TemplatePreview(ResumeTemplate template, IReadOnlyList<ResumeTemplate> list, double windowHeight, Action close, Action<ResumeTemplate> use)
    {
        _template = template; _list = list; _close = close; _use = use;
        Root = V3Dialog.Frame(_content, 680);
        Root.Height = Math.Min(854, windowHeight - 48);
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
            var result = await TemplatesPage.PreparePaperAsync(template, ct);
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
        _content.RowDefinitions.Add(new RowDefinition { Height = Auto });
        _content.RowDefinitions.Add(new RowDefinition { Height = Star() });
        _content.RowDefinitions.Add(new RowDefinition { Height = Auto });

        // 头部：标题 20/600（32 高），标签与使用次数（22 高），左右 24、顶 22
        var tags = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Height = 22 };
        foreach (var label in _template.StyleCategories.Concat(_template.UseCases)) tags.Children.Add(V3Chip.Make(label).Align(v: VerticalAlignment.Center));
        if (_template.UseCount is { } count) tags.Children.Add(Number($"{TemplatesPage.FormatUses(count)} 使用", 11.5, Fnt, Regular).Align(v: VerticalAlignment.Center));
        _content.Children.Add(VStack(6, Serif(_template.Name, 20).Frame(height: 32), tags).Pad(24, 22, 24, 18));

        // 舞台：可双向滚动的纸面（下方缩放条随纸面）+ 两侧切换钮
        var scroll = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Auto, VerticalScrollMode = ScrollMode.Auto,
        };
        var host = new StackPanel();
        scroll.SizeChanged += (_, e) => host.MinWidth = e.NewSize.Width;
        if (_paper is not null)
        {
            Detach(_paper);
            _paperBox = new Border
            {
                Child = new Viewbox { Child = _paper, Stretch = Stretch.Fill }, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(76, 40, 76, 0),
                BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            };
            host.Children.Add(_paperBox);
        }
        else if (_error is { } error) host.Children.Add(Sans(error, 13, Red).Pad(40, 40, 40, 40).Align(HorizontalAlignment.Center));
        else host.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16, Margin = new Thickness(40), HorizontalAlignment = HorizontalAlignment.Center });

        _zoomOut = ZoomButton("−", "缩小模板", () => Change(-1));
        _zoomIn = ZoomButton("+", "放大模板", () => Change(1));
        _zoomLabel = Number("", 12, Txt, Regular);
        AutomationProperties.SetName(_zoomLabel, "模板预览缩放比例");
        var zoomRow = Columns(4, (Auto, _zoomOut), (Star(), _zoomLabel.Align(HorizontalAlignment.Center, VerticalAlignment.Center)), (Auto, _zoomIn));
        zoomRow.Padding = new Thickness(4, 0, 4, 0);
        var zoomBar = new Border
        {
            Child = zoomRow, Width = 109, Height = 28, CornerRadius = new CornerRadius(4), Background = Brush(V3.White),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 20, 0, 40),
        };
        AutomationProperties.SetName(zoomBar, "模板预览缩放");
        if (_paper is not null) host.Children.Add(zoomBar);
        scroll.Content = host;

        var stage = new Grid { CornerRadius = new CornerRadius(8), Background = Brush(Stage), Margin = new Thickness(24, 0, 24, 24) };
        stage.Children.Add(scroll);
        stage.Children.Add(NavButton(Previous, left: true).Align(HorizontalAlignment.Left, VerticalAlignment.Center).Pad(20, 0, 0, 0));
        stage.Children.Add(NavButton(Next, left: false).Align(HorizontalAlignment.Right, VerticalAlignment.Center).Pad(0, 0, 20, 0));
        Grid.SetRow(stage, 1);
        _content.Children.Add(stage);

        // CommandSpace：#F4F4F1、内边距 24；左「第 n / N 套」，右取消与唯一的黑色主按钮（各 140 宽）
        var buttons = HStack(8,
            new V3Button("取消", _close, V3Button.Kind.Ghost, width: 140),
            new V3Button("创建简历", () => _use(_template), V3Button.Kind.Dark, width: 140));
        UIElement position = Index is { } index ? Sans($"第 {index + 1} / {_list.Count} 套", 12, Fnt) : new Border();
        var foot = new Border
        {
            Child = Spread(position, buttons, 12), Padding = new Thickness(24), Background = Brush(Stage),
            BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 1, 0, 0),
        };
        Grid.SetRow(foot, 2);
        _content.Children.Add(foot);
        UpdateZoom();
    }

    /// <summary>缩放只改纸面外框与百分比，不重新渲染纸面。</summary>
    void UpdateZoom()
    {
        var scale = _zoom * Base;
        if (_paper is not null) _paper.Height = _height;
        if (_paperBox is not null) { _paperBox.Width = 794 * scale + 2; _paperBox.Height = _height * scale + 2; }
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
            Width = 32, Height = 32, CornerRadius = new CornerRadius(16), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            Child = Icon(left ? "chevron.left" : "chevron.right", 12, Txt).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            Opacity = target is null ? 0.4 : 1,
        };
        var name = target is not null ? $"{(left ? "上一个" : "下一个")}模板：{target.Name}" : left ? "没有上一个模板" : "没有下一个模板";
        return button.OnTap(() => { if (target is not null) Show(target); }, name, () => target is not null);
    }

    BorderControl ZoomButton(string title, string label, Action action)
    {
        var plus = title == "+";
        return new BorderControl { Width = 28, Height = 22, Background = Brush(Clear), Child = Label(title, 14, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center) }
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
/// 筛选（Windows 稿 Filter ComboBox）：白底 32 高、圆角 4、#E4E4E0 边、底部 1px 深色强调线，「筛选」或「筛选 · N」+ ⌄；
/// 浮层 300 宽（03.1b）：标题「筛选简历模板」与重置，风格、适用场景两组 FilterChip 多选（选中白底细边、未选灰底），选中即生效。
/// </summary>
public sealed class TemplateFilter : BorderControl
{
    public static readonly string[] StyleOptions = ["简约", "经典", "现代", "创意"];
    public static readonly string[] UseOptions = ["实习", "校招", "社招"];

    readonly List<string> _styles, _uses;
    readonly Action _changed;
    readonly TextBlock _title = Sans("", 13, Txt);
    Flyout? _flyout;
    bool _open;

    int Count => _styles.Count + _uses.Count;

    public TemplateFilter(List<string> styles, List<string> uses, Action changed, double height = 32)
    {
        _styles = styles; _uses = uses; _changed = changed;
        _title.VerticalAlignment = VerticalAlignment.Center;
        Child = Columns(12, (Star(), _title), (Auto, Icon("chevron.down", 10, Sub).Align(v: VerticalAlignment.Center)));
        Height = height;
        MinWidth = 96;
        Padding = new Thickness(11, 0, 11, 0);
        CornerRadius = new CornerRadius(4);
        BorderThickness = new Thickness(1, 1, 1, 1);
        this.OnTap(Toggle, "筛选简历模板");
        Refresh();
    }

    /// <summary>筛选值或开合变化后重画按钮与浮层内容。</summary>
    public void Refresh()
    {
        _title.Text = Count > 0 ? $"筛选 · {Count}" : "筛选";
        Background = Brush(_open ? Field : V3.White);
        BorderBrush = new LinearGradientBrush
        {
            StartPoint = new Point(0, 0), EndPoint = new Point(0, 1),
            GradientStops = { new GradientStop { Color = Cl, Offset = 0 }, new GradientStop { Color = Cl, Offset = 0.94 }, new GradientStop { Color = Count > 0 ? Txt : Hex(0x8A8A84), Offset = 0.94 } },
        };
        if (_flyout is not null) _flyout.Content = Popover();
    }

    void Toggle()
    {
        if (_open) { _flyout?.Hide(); return; }
        _open = true;
        _flyout = V3Popover.Show(this, Popover(), FlyoutPlacementMode.BottomEdgeAlignedRight, padding: 0);
        _flyout.Closed += (_, _) => { _open = false; _flyout = null; Refresh(); };
        Refresh();
    }

    UIElement Popover()
    {
        var reset = new BorderControl { Width = 28, Height = 28, CornerRadius = new CornerRadius(4), Background = Brush(Clear), Child = Icon("arrow.clockwise", 13, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center), Opacity = Count == 0 ? 0.4 : 1 }
            .OnTap(() => { _styles.Clear(); _uses.Clear(); Changed(); }, "重置筛选", () => Count > 0).Tip("重置筛选");
        var head = Spread(Sans("筛选简历模板", 13, Txt, Semibold), reset, 0);
        head.Height = 28;
        var body = VStack(0, head, Group("风格", StyleOptions, _styles).Top(10), Group("适用场景", UseOptions, _uses).Top(10));
        body.Padding = new Thickness(17, 13, 17, 17);
        body.Width = 300;
        AutomationProperties.SetName(body, "筛选简历模板");
        return body;
    }

    StackPanel Group(string title, string[] options, List<string> values)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        foreach (var option in options)
        {
            var on = values.Contains(option);
            row.Children.Add(new BorderControl
            {
                Child = Sans(option, 12, Txt, on ? Medium : Regular).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
                MinWidth = 40, Padding = new Thickness(8, 0, 8, 0), Height = 28, CornerRadius = new CornerRadius(14),
                Background = Brush(on ? V3.White : Field), BorderBrush = Brush(on ? Hex(0xC9C9C3) : Field), BorderThickness = new Thickness(1),
            }.OnTap(() => { if (on) values.Remove(option); else values.Add(option); Changed(); }, option)
             .Also(chip => { if (on) AutomationProperties.SetItemStatus(chip, "已选中"); }));
        }
        return VStack(10, Sans(title, 12, Fnt).Frame(height: 18), row);
    }

    void Changed() { _changed(); Refresh(); }
}
