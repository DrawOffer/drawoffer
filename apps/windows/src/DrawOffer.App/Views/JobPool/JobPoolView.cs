using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.JobPool.PoolUI;

namespace DrawOffer.App.Views.JobPool;

/// <summary>公司页的筛选条件（Mac `JobPoolView.Query`）。</summary>
public sealed record PoolQuery(string Keyword = "", string City = "", string Category = "", string Type = "")
{
    public bool Filtered => Keyword.Length > 0 || City.Length > 0 || Category.Length > 0 || Type.Length > 0;
}

/// <summary>
/// 岗位广场，对应 Mac `JobPoolView.swift`（Web `features/jobs/OpportunitiesPage.tsx`，Figma「12 · 官网岗位池」）：
/// 公司目录 → 公司岗位列表 → 岗位详情。路由栈与 Mac `path: [Route]` 一致。
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

/// <summary>A · 公司目录：行业胶囊、公司搜索、排序与三列公司卡片。</summary>
sealed class JobPoolDirectory : UserControl
{
    readonly Action<string> _open;
    readonly StackPanel _content = new();
    readonly Grid _stats = new();
    readonly Grid _chips = new();
    readonly V3SearchField _search = new("搜索公司", width: 280, height: 34);
    JsonNode? _data;
    bool _failed;
    string _industry = "", _text = "", _sort = "open";

    public JobPoolDirectory(Action<string> open)
    {
        _open = open;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_search, "搜索公司");
        _search.Changed += text => { _text = text; RenderContent(); };
        var head = Columns(24,
            (Star(), VStack(0, Sans("OPPORTUNITIES · 企业官网直招", 12, Fnt, Medium).Frame(height: 18), Serif("岗位广场", 28).Frame(height: 36).Top(8))),
            (Auto, _stats));
        head.VerticalAlignment = VerticalAlignment.Bottom;
        var filters = Columns(16, (Star(), _chips.Pad(0, 2, 0, 0)), (Auto, _search.Align(v: VerticalAlignment.Top)));
        filters.Margin = new Thickness(0, 22, 0, 0);
        Content = new V3Page(VStack(0, head, filters, _content));
        Loaded += async (_, _) => await LoadAsync();
        RenderContent();
    }

    List<JsonNode> Companies
    {
        get
        {
            var needle = Trim(_text).ToLowerInvariant();
            var items = _data.Items("items").Where(company =>
                (_industry.Length == 0 || company.Text("industry") == _industry)
                && (needle.Length == 0 || new[] { company.Text("name") }.Concat(company.Items("aliases").Select(x => x.String()).OfType<string>()).Any(x => x.ToLowerInvariant().Contains(needle)))).ToList();
            int Open(JsonNode item) => item.Integer("open_count");
            // Swift `sorted` 稳定；按元组降序
            return _sort switch
            {
                "today" => items.OrderByDescending(x => x.Integer("today_new")).ThenByDescending(Open).ToList(),
                "latest" => items.OrderByDescending(x => x.Text("latest_at"), StringComparer.Ordinal).ThenByDescending(Open).ToList(),
                "name" => items.OrderBy(x => x.Text("name"), StringComparer.Create(System.Globalization.CultureInfo.GetCultureInfo("zh-CN"), false)).ToList(),
                _ => items,
            };
        }
    }

    IEnumerable<(string, string, int?)> ChipItems()
    {
        var items = _data.Items("items");
        var industries = _data.Items("industries").Select(x => x.String()).OfType<string>()
            .Select(name => (name, name, (int?)items.Count(x => x.Text("industry") == name))).Where(x => x.Item3 > 0);
        return new[] { ("", "全部", _data is null ? null : (int?)items.Count) }.Concat(industries);
    }

    void RenderContent()
    {
        _stats.Children.Clear();
        if (_data?.Get("total") is { } total)
            _stats.Children.Add(Stats(total.Integer("open_count"), total.Integer("today_new"), $"收录 {total.Integer("company_count")} 家公司"));
        _chips.Children.Clear();
        _chips.Children.Add(Chips(ChipItems(), _industry, "按行业筛选", value => { _industry = value; RenderContent(); }));
        _content.Children.Clear();
        if (_failed)
        {
            _content.Children.Add(Error("公司目录暂时无法加载", "网络不稳定或服务暂时不可用，稍后重试即可。", () => _ = LoadAsync()));
            return;
        }
        if (_data is null)
        {
            var grid = Grid(Enumerable.Range(0, 9).Select(_ => SkeletonCard()));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(grid, "正在加载公司目录…");
            _content.Children.Add(grid);
            return;
        }
        var companies = Companies;
        if (companies.Count == 0)
        {
            var text = Trim(_text);
            var filtered = _industry.Length > 0 || text.Length > 0;
            var summary = string.Join(" · ", new[] { _industry, text }.Where(x => x.Length > 0));
            _content.Children.Add(State(filtered ? "没有找到这家公司" : "暂时还没有收录公司",
                filtered ? "换个公司名称，或切换到全部行业试试。" : "企业官网的岗位同步后会出现在这里，稍后再来看看。",
                PoolArt.Empty(filtered ? summary : "企业官网直招"),
                filtered ? [new V3Button("清除筛选", () => { _search.Box.Text = ""; _text = ""; _industry = ""; RenderContent(); }, V3Button.Kind.Dark)] : []));
            return;
        }
        var bar = Spread(Sans($"共 {companies.Count} 家公司", 12.5, Fnt),
            Select("排序", _sort, Core.Models.JobPool.Sorts.Select(x => (x.Value, x.Label)).ToList(), value => { _sort = value; RenderContent(); }));
        bar.MinHeight = 44;
        bar.Margin = new Thickness(0, 14, 0, 0);
        _content.Children.Add(bar);
        _content.Children.Add(Grid(companies.Select(Card)));
    }

    /// <summary>`LazyVGrid` 三等列、间距 16，上 12、下 40。</summary>
    static Grid Grid(IEnumerable<FrameworkElement> cells)
    {
        var grid = new Grid { ColumnSpacing = 16, RowSpacing = 16, Margin = new Thickness(0, 12, 0, 40) };
        for (var i = 0; i < 3; i++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        var index = 0;
        foreach (var cell in cells)
        {
            if (index % 3 == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            cell.VerticalAlignment = VerticalAlignment.Top;
            Microsoft.UI.Xaml.Controls.Grid.SetRow(cell, index / 3);
            Microsoft.UI.Xaml.Controls.Grid.SetColumn(cell, index % 3);
            grid.Children.Add(cell);
            index++;
        }
        return grid;
    }

    static FrameworkElement SkeletonCard()
    {
        var body = VStack(16,
            HStack(12, Skeleton(40, 40, 9), VStack(3, Skeleton(96, 14), Skeleton(56, 10))),
            Ratio(0.45, 26),
            Skeleton(null, 12));
        return new Border
        {
            Child = body, Padding = new Thickness(18, 18, 18, 16), CornerRadius = new CornerRadius(12), Background = Brush(V3.White),
            BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(1),
        };
    }

    FrameworkElement Card(JsonNode company)
    {
        var today = company.Integer("today_new");
        var name = Sans(company.Text("name"), 15, Txt, Medium);
        var head = Columns(12,
            (Auto, Logo(company.Text("name"), company.Text("logo_url"), 40)),
            (Star(), VStack(3, name, Sans(company.Text("industry"), 12, Fnt)).Align(v: VerticalAlignment.Center)),
            (Auto, (today > 0 ? Badge($"今日 +{today}") : (FrameworkElement)Sans("今日无新增", 11.5, Fnt2)).Align(v: VerticalAlignment.Center)));
        var count = HStack(6, Number(Grouped(company.Integer("open_count")), 26, Txt), Sans("个在招岗位", 12, Fnt).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 4));
        var figure = Columns(16, (Star(), count.Align(v: VerticalAlignment.Bottom)), (Auto, Trend(company.Items("daily_new").Select(x => (int)(x.Number() ?? 0)).ToList())));
        figure.Height = 37;
        var types = new Grid { Height = 22, Margin = new Thickness(0, 13, 0, 0) };
        var index = 0;
        foreach (var type in Core.Models.JobPool.Types)
        {
            types.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            var value = (int)(company.Get("counts").Number(type.Value) ?? 0);
            var cell = HStack(6, Sans(type.Label, 12, Fnt), value > 0 ? Number(Grouped(value), 13, Txt, Medium) : Sans("暂无", 12, Fnt2));
            Microsoft.UI.Xaml.Controls.Grid.SetColumn(cell, index++);
            types.Children.Add(cell);
        }
        var foot = VStack(0, Divider(V3.Line), types);
        var card = new Border
        {
            Child = VStack(18, head, figure, foot), Padding = new Thickness(18, 18, 18, 16), CornerRadius = new CornerRadius(12), Background = Brush(V3.White),
            BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(1),
        };
        card.OnHover(hover =>
        {
            name.Foreground = Brush(hover ? Blue : Txt);
            card.BorderBrush = Brush(hover ? Cl : V3.Line);
            card.Translation = new System.Numerics.Vector3(0, hover ? -1 : 0, 0);
        });
        return card.OnTap(() => _open(company.Text("id")), company.Text("name"));
    }

    /// <summary>`.pool-trend`：近 7 天新增的小柱图（84×28、间距 4），今天为蓝色，最矮 12%。</summary>
    static FrameworkElement Trend(List<int> values)
    {
        var top = Math.Max(1, values.DefaultIfEmpty(1).Max());
        var grid = new Grid { Width = 84, Height = 28, ColumnSpacing = 4, VerticalAlignment = VerticalAlignment.Bottom };
        for (var i = 0; i < values.Count; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            var percent = Math.Max(12, (int)Math.Round((double)values[i] / top * 100, MidpointRounding.AwayFromZero));
            var bar = new Border { Height = 28.0 * percent / 100, CornerRadius = new CornerRadius(2), Background = Brush(i == values.Count - 1 ? Blue : Hl), VerticalAlignment = VerticalAlignment.Bottom };
            Microsoft.UI.Xaml.Controls.Grid.SetColumn(bar, i);
            grid.Children.Add(bar);
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(grid, "近 7 天新增：" + string.Join("、", values));
        return grid;
    }

    async Task LoadAsync()
    {
        _failed = false;
        RenderContent();
        try { _data = await App.Session.Api.CareerRequestAsync("/api/job-pool/companies", "GET", [], null); }
        catch (ApiException error) when (error.Status == System.Net.HttpStatusCode.Unauthorized) { App.Session.ReportAuthenticationFailure(); _failed = true; }
        catch (Exception) { _failed = true; }
        RenderContent();
    }
}
