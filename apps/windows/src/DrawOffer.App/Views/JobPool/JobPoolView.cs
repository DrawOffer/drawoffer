using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.JobPool.PoolUI;

namespace DrawOffer.App.Views.JobPool;

/// <summary>公司页的筛选条件；Sort 是岗位排序（`published` 最新发布 / `collected` 最新收录），不算筛选。</summary>
public sealed record PoolQuery(string Keyword = "", string City = "", string Category = "", string Type = "", string Sort = "published")
{
    public bool Filtered => Keyword.Length > 0 || City.Length > 0 || Category.Length > 0 || Type.Length > 0;
}

/// <summary>
/// 岗位广场（Windows 稿 06，Mac `JobPoolView.swift`）：公司目录 → 公司岗位列表 → 岗位详情。路由栈与 Mac `path: [Route]` 一致。
/// </summary>
public sealed class JobPoolView : UserControl
{
    abstract record Route;
    sealed record CompanyRoute(string Id, PoolQuery Query) : Route;
    sealed record JobRoute(string Id) : Route;

    readonly Action<string> _openApplication;
    readonly List<Route> _path = [];

    public JobPoolView(Action<string> openApplication)
    {
        _openApplication = openApplication;
        Render();
    }

    void Render()
    {
        Content = _path.LastOrDefault() switch
        {
            CompanyRoute company => new JobPoolCompany(company.Id, company.Query, Root, id => Push(new JobRoute(id)), _openApplication),
            JobRoute job => new JobPoolJob(job.Id, Root, (company, query) => { _path.Clear(); Push(new CompanyRoute(company, query)); }, id => Push(new JobRoute(id)), _openApplication),
            _ => new JobPoolDirectory(id => Push(new CompanyRoute(id, new PoolQuery()))),
        };
    }

    void Push(Route route) { _path.Add(route); Render(); }
    void Root() { _path.Clear(); Render(); }
}

/// <summary>
/// A · 公司目录（Windows 稿 06「紧凑公司卡片与分页」）：页头与在招统计 → 行业 FilterChip → 结果栏（共 N 家、排序、搜索）
/// → 112 高紧凑卡片（三列 → 两列 → 单列）→ 分页（每页 20 家；筛选、搜索或排序后回到第 1 页）。分页、搜索、行业与排序都在服务端完成。
/// </summary>
sealed class JobPoolDirectory : UserControl
{
    const int PageSize = 20;
    readonly Action<string> _open;
    readonly Grid _stats = new();
    readonly ContentControl _chips = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    readonly TextBlock _summary = Sans("", 12.5, Fnt);
    readonly ContentControl _sort = new();
    readonly V3SearchField _search = new("搜索公司名称或别名", width: 260, height: 32);
    readonly StackPanel _content = new();
    JsonNode? _data;
    bool _busy = true, _failed;
    string _industry = "", _applied = "", _sortValue = "open";
    int _page = 1, _generation, _typing;

    public JobPoolDirectory(Action<string> open)
    {
        _open = open;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_search, "搜索公司");
        _search.Changed += _ => Debounce();
        var head = Columns(24, (Star(), V3PageHead.Make(["OPPORTUNITIES", "企业官网直招"], "岗位广场")), (Auto, _stats.Pad(0, 12, 0, 0)));
        var bar = Columns(8, (Star(), _summary.Align(v: VerticalAlignment.Center)), (Auto, _sort), (Auto, _search));
        bar.Height = 32;
        Content = new V3Page(VStack(0, head, _chips.Top(44), bar.Top(28), _content), top: 64);
        Loaded += (_, _) => _ = LoadAsync();
        Render();
    }

    int Total => _data.Integer("total");
    int PageCount => Math.Max(1, (Total + PageSize - 1) / PageSize);

    void Debounce()
    {
        var token = ++_typing;
        _ = Task.Delay(250).ContinueWith(_ => DispatcherQueue.TryEnqueue(() =>
        {
            if (token != _typing) return;
            var next = Trim(_search.Text);
            if (next.Length > 100) next = next[..100];
            if (next == _applied) return;
            _applied = next; _page = 1;
            _ = LoadAsync();
        }));
    }

    void Change(Action apply) { apply(); _page = 1; _ = LoadAsync(); }

    void Render()
    {
        _stats.Children.Clear();
        if (_data?.Get("summary") is { } summary)
            _stats.Children.Add(Stats(summary.Integer("open_count"), summary.Integer("today_new"), $"收录 {Grouped(summary.Integer("company_count"))} 家公司"));
        // 行业计数描述整份目录，与当前筛选和页码无关
        var chips = new[] { ("", "全部", _data?.Get("summary") is { } s ? (int?)s.Integer("company_count") : null) }
            .Concat(_data.Items("industries").Select(x => (x.Text("name"), x.Text("name"), (int?)x.Integer("count"))));
        _chips.Content = Chips(chips, _industry, "按行业筛选", value => Change(() => _industry = value));
        _summary.Text = _failed ? "公司目录暂时无法加载" : _busy ? "正在查询公司…" : $"共 {Grouped(Total)} 家公司";
        _sort.Content = Select("排序", _sortValue, Core.Models.JobPool.Sorts.Select(x => (x.Value, x.Label)).ToList(), value => Change(() => _sortValue = value));

        _content.Children.Clear();
        if (_failed)
        {
            _content.Children.Add(Error("公司目录暂时无法加载", "网络不稳定或服务暂时不可用，筛选条件已保留。", () => _ = LoadAsync()));
            return;
        }
        if (_busy)
        {
            var skeleton = new CardGrid(Enumerable.Range(0, 9).Select(_ => SkeletonCard()));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(skeleton, "正在加载公司目录…");
            _content.Children.Add(skeleton.Top(16));
            return;
        }
        var items = _data.Items("items");
        if (items.Count == 0)
        {
            var filtered = _industry.Length > 0 || _applied.Length > 0;
            var summary = string.Join(" · ", new[] { _industry, _applied }.Where(x => x.Length > 0));
            _content.Children.Add(State(filtered ? "没有找到这家公司" : "暂时还没有收录公司",
                filtered ? "换个公司名称，或切换到全部行业试试。" : "企业官网的岗位同步后会出现在这里，稍后再来看看。",
                PoolArt.Empty(filtered ? summary : "企业官网直招"),
                filtered ? [new V3Button("清除筛选", () => { _search.Text = ""; _typing++; Change(() => { _applied = ""; _industry = ""; }); }, V3Button.Kind.Ghost)] : []));
            return;
        }
        _content.Children.Add(new CardGrid(items.Select(Card)).Top(16));
        if (PageCount > 1) _content.Children.Add(V3Pagination.Make(Math.Min(_page, PageCount), Total, page => { _page = page; _ = LoadAsync(); }, PageSize).Pad(16, 0, 16, 0));
    }

    static FrameworkElement SkeletonCard()
    {
        var body = VStack(0,
            HStack(12, Skeleton(32, 32, 8), VStack(5, Skeleton(96, 13), Skeleton(56, 10)).Align(v: VerticalAlignment.Center)).Frame(height: 40),
            Spread(Skeleton(80, 18), Skeleton(120, 12)).Frame(height: 27).Top(16));
        return new Border
        {
            Child = body, Height = 112, Padding = new Thickness(16, 16, 16, 12), CornerRadius = new CornerRadius(8),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        };
    }

    /// <summary>
    /// 紧凑公司卡片（112 高）：Logo 32（灰底首字）+ 公司名 13 / 行业 11，右上仅有新增时显示蓝字「今日 +N」；
    /// 下行左侧在招总数，右侧校招 / 实习分项（为零直接写 0）。悬停公司名变蓝、边线加深，不加底色与阴影。
    /// </summary>
    FrameworkElement Card(JsonNode company)
    {
        var today = company.Integer("today_new");
        var name = Sans(company.Text("name"), 13, Txt, Medium).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis);
        var head = Columns(12,
            (Auto, Logo(company.Text("name"), company.Text("logo_url"), 32, filled: true)),
            (Star(), VStack(4, name, Sans(company.Text("industry"), 11, Fnt).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis)).Align(v: VerticalAlignment.Center)),
            (Auto, today > 0 ? Sans($"今日 +{Grouped(today)}", 11.5, Blue).Align(v: VerticalAlignment.Top) : new Border()));
        head.Height = 40;
        var types = HStack(13);
        foreach (var type in Core.Models.JobPool.Types)
            types.Children.Add(HStack(4, Sans(type.Label, 11.5, Fnt), Number(Grouped((int)(company.Get("counts").Number(type.Value) ?? 0)), 12.5, Sub, Regular)));
        var count = HStack(5, Number(Grouped(company.Integer("open_count")), 20, Txt, Regular), Sans("在招", 11.5, Fnt).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 3));
        var foot = Columns(8, (Star(), count.Align(v: VerticalAlignment.Bottom)), (Auto, types.Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 2)));
        foot.Height = 27;
        foot.Margin = new Thickness(0, 16, 0, 0);
        var card = new Border
        {
            Child = VStack(0, head, foot), Height = 112, Padding = new Thickness(16, 16, 16, 12), CornerRadius = new CornerRadius(8),
            Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        };
        card.OnHover(hover => { name.Foreground = Brush(hover ? Blue : Txt); card.BorderBrush = Brush(hover ? Sk2 : Cl); });
        return card.OnTap(() => _open(company.Text("id")), company.Text("name"));
    }

    async Task LoadAsync()
    {
        var generation = ++_generation;
        var page = _page;
        _busy = true; _failed = false;
        Render();
        var query = new Dictionary<string, string> { ["page"] = $"{page}", ["page_size"] = $"{PageSize}", ["sort"] = _sortValue };
        if (_applied.Length > 0) query["q"] = _applied;
        if (_industry.Length > 0) query["industry"] = _industry.Length > 100 ? _industry[..100] : _industry;
        try
        {
            var value = await App.Session.Api.CareerRequestAsync("/api/job-pool/companies/page", "GET", query, null);
            if (generation != _generation) return;
            // 目录在两次翻页之间变短：当前页越界时退到最后一页重新请求
            var last = Math.Max(1, (value.Integer("total") + PageSize - 1) / PageSize);
            if (value.Items("items").Count == 0 && last < page) { _page = last; _ = LoadAsync(); return; }
            _data = value;
        }
        catch (ApiException error) when (error.Status == System.Net.HttpStatusCode.Unauthorized)
        {
            if (generation != _generation) return;
            App.Session.ReportAuthenticationFailure(); _failed = true;
        }
        catch (Exception) { if (generation != _generation) return; _failed = true; }
        _busy = false;
        Render();
    }
}

/// <summary>公司卡片网格：宽 ≥ 900 三列、≥ 580 两列，否则单列；列距 13、行距 12，卡片高度不变。</summary>
sealed class CardGrid : Grid
{
    readonly List<FrameworkElement> _cells;
    int _columns;

    public CardGrid(IEnumerable<FrameworkElement> cells)
    {
        _cells = cells.ToList();
        ColumnSpacing = 13;
        RowSpacing = 12;
        foreach (var cell in _cells) { cell.VerticalAlignment = VerticalAlignment.Top; Children.Add(cell); }
        Layout(3);
        SizeChanged += (_, e) => Layout(e.NewSize.Width >= 900 ? 3 : e.NewSize.Width >= 580 ? 2 : 1);
    }

    void Layout(int columns)
    {
        if (columns == _columns) return;
        _columns = columns;
        ColumnDefinitions.Clear();
        RowDefinitions.Clear();
        for (var i = 0; i < columns; i++) ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var i = 0; i < (_cells.Count + columns - 1) / columns; i++) RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (var i = 0; i < _cells.Count; i++) { SetRow(_cells[i], i / columns); SetColumn(_cells[i], i % columns); }
    }
}
