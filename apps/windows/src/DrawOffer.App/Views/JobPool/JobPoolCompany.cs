using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.JobPool.PoolUI;

namespace DrawOffer.App.Views.JobPool;

/// <summary>B · 公司页：公司头、方向胶囊、招聘类型页签、本公司搜索与城市，岗位列表按游标分页。</summary>
sealed class JobPoolCompany : UserControl
{
    readonly string _companyId;
    readonly Action _root;
    readonly Action<string> _openJob;
    readonly Action<string> _openApplication;
    readonly Grid _host = new();
    readonly PoolJoin _join;
    readonly TextBox _keywordBox;
    PoolQuery _query;
    bool _keywordError;
    JsonNode? _company;
    string _companyState = "loading";
    List<JsonNode> _jobs = [];
    string? _cursor;
    bool _loading = true, _loadingMore, _failed, _moreFailed;
    int _generation;

    public JobPoolCompany(string companyId, PoolQuery initial, Action root, Action<string> openJob, Action<string> openApplication)
    {
        _companyId = companyId;
        _root = root;
        _openJob = openJob;
        _openApplication = openApplication;
        _query = initial;
        _join = new PoolJoin(() => XamlRoot, _host, openApplication, Render);
        _keywordBox = new TextBox
        {
            Text = initial.Keyword, FontSize = 14, FontFamily = SansFamily, BorderThickness = new Thickness(0), Background = Brush(V3.Clear), Foreground = Brush(Txt),
            PlaceholderForeground = Brush(Fnt), Padding = new Thickness(0, 5, 0, 0), MinHeight = 0, Height = 30, VerticalContentAlignment = VerticalAlignment.Center,
        };
        _keywordBox.TextChanged += (_, _) => { if (_keywordError) { _keywordError = false; Render(); } };
        _keywordBox.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Submit(); } };
        Content = _host;
        Loaded += async (_, _) => { await Task.WhenAll(LoadCompanyAsync(), LoadJobsAsync()); };
        Render();
    }

    string CompanyName => _company.Text("name");

    void Render()
    {
        _host.Children.Clear();
        if (_companyState == "missing")
        {
            _host.Children.Add(new V3Page(VStack(0, Crumbs(_root, current: "公司不存在"),
                State("没有找到这家公司", "公司可能已不再收录，或链接不完整。", PoolArt.Unavailable("链接已失效"),
                    [TextLink("返回岗位广场", _root, 14, V3.Link)], width: 314, stage: 96))));
            return;
        }
        var categories = new[] { ("", "全部方向", (int?)null) }
            .Concat(_company.Items("categories").Select(x => (x.Text("name"), x.Text("name"), (int?)x.Integer("count"))));
        var page = VStack(0,
            Crumbs(_root, current: CompanyName.Length == 0 ? "公司" : CompanyName),
            Head(),
            Chips(categories, _query.Category, "按方向筛选", value => Change(_query with { Category = value })).Top(22),
            ResultBar(),
            _keywordError ? Note(Core.Models.JobPool.KeywordError).Top(12) : null,
            List());
        _host.Children.Add(new V3Page(page));
    }

    FrameworkElement Head()
    {
        if (_company is { } company)
        {
            var tags = HStack(10, new Border
            {
                Child = Sans(company.Text("industry"), 12, Sub).Align(v: VerticalAlignment.Center), Height = 20, Padding = new Thickness(7, 0, 7, 0),
                CornerRadius = new CornerRadius(4), Background = Brush(Field),
            });
            if (company.Text("careers_url").NonEmpty() is { } careers && Web(careers) is { } url)
                tags.Children.Add(Link(Core.Models.JobPool.Host(careers), url, 12.5, Fnt, Regular, spacing: 4));
            var identity = HStack(14, Logo(company.Text("name"), company.Text("logo_url"), 48), VStack(6, Serif(company.Text("name"), 28).Frame(height: 36), tags));
            return Columns(24, (Star(), identity.Align(v: VerticalAlignment.Bottom)), (Auto, Stats(company.Integer("open_count"), company.Integer("today_new"))));
        }
        if (_companyState == "error")
            return Note("公司信息暂时无法加载。", trailing: TextLink("重试", Reload, 12.5, Sub, Medium));
        var skeleton = HStack(14, Skeleton(48, 48, 10), VStack(8, Skeleton(140, 24), Skeleton(90, 12)));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(skeleton, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return skeleton;
    }

    IEnumerable<(string Value, string Label, int? Count)> Tabs()
    {
        var counts = _company.Get("counts");
        var unclassified = (int)(counts.Number("unclassified") ?? 0);
        yield return ("", "全部", _company is null || _company.Get("open_count") is null ? null : _company.Integer("open_count"));
        foreach (var type in Core.Models.JobPool.Types)
            yield return (type.Value, type.Label, counts.Number(type.Value) is { } n ? (int)n : null);
        if (unclassified > 0 || _query.Type == "unclassified") yield return ("unclassified", "未分类", unclassified);
    }

    FrameworkElement ResultBar()
    {
        var tabs = HStack(26);
        foreach (var tab in Tabs())
        {
            var active = _query.Type == tab.Value;
            var row = HStack(5, Sans(tab.Label, 14, active ? Txt : Sub, active ? Medium : Regular));
            if (tab.Count is { } count) row.Children.Add(Number(Grouped(count), 12, Fnt, Regular));
            var cell = new Grid { Height = 36 };
            cell.Children.Add(row.Align(v: VerticalAlignment.Center));
            if (active) cell.Children.Add(new Border { Height = 2, CornerRadius = new CornerRadius(1), Background = Brush(Txt), VerticalAlignment = VerticalAlignment.Bottom });
            var value = tab.Value;
            tabs.Children.Add(cell.OnTap(() => Change(_query with { Type = value }), tab.Label));
        }
        tabs.Margin = new Thickness(0, 0, 0, -7);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(tabs, "招聘类型");
        // Web 的城市选择比搜索框低 4px，「清除筛选」顶端比搜索框低 6px，三者并非居中对齐。
        var tools = HStack(8);
        tools.VerticalAlignment = VerticalAlignment.Top;
        if (_query.Filtered) tools.Children.Add(TextLink("清除筛选", Clear, 12, Sub).Frame(height: 20).Pad(0, 6, 6, 0).Align(v: VerticalAlignment.Top));
        tools.Children.Add(Search().Align(v: VerticalAlignment.Top));
        var cities = new[] { ("all", "全部城市") }.Concat(_company.Items("cities").Select(x => x.String()).OfType<string>().Select(x => (x, x))).ToList();
        tools.Children.Add(Select("城市", _query.City, cities, value => Change(_query with { City = value == "all" ? "" : value }), "城市").Pad(0, 4, 0, 0).Align(v: VerticalAlignment.Top));
        var row2 = Columns(16, (Star(), tabs.Align(v: VerticalAlignment.Bottom)), (Auto, tools));
        row2.MinHeight = 44;
        row2.VerticalAlignment = VerticalAlignment.Bottom;
        return new Border
        {
            Child = row2, Padding = new Thickness(0, 0, 0, 6), Margin = new Thickness(0, 14, 0, 0),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(0, 0, 0, 1),
        };
    }

    FrameworkElement Search()
    {
        _keywordBox.PlaceholderText = CompanyName.Length == 0 ? "搜索本公司岗位" : $"搜索{CompanyName}的岗位";
        if (_keywordBox.Parent is Panel parent) parent.Children.Remove(_keywordBox);
        var box = new Border
        {
            Child = Columns(8, (Auto, Icon("magnifyingglass", 12, Fnt).Align(v: VerticalAlignment.Center)), (Star(), _keywordBox)),
            Width = 220, Height = 32, Padding = new Thickness(10, 0, 10, 0), CornerRadius = new CornerRadius(8), Background = Brush(V3.White),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_keywordBox, "搜索本公司岗位");
        return box;
    }

    FrameworkElement List()
    {
        if (_failed) return Error("岗位暂时无法加载", "网络不稳定或服务暂时不可用，筛选条件已保留。", Reload);
        if (_loading)
        {
            var stack = new StackPanel { Margin = new Thickness(-16, 8, -16, 0) };
            for (var i = 0; i < 6; i++)
                stack.Children.Add(VStack(10, Ratio(0.38, 16), Ratio(0.3, 12), Ratio(0.92, 12), Ratio(0.7, 12)).Also(s => { s.Height = 92; s.Margin = new Thickness(16, 20, 16, 20); }));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(stack, "正在加载岗位…");
            return stack;
        }
        if (_jobs.Count == 0)
        {
            var type = Core.Models.JobPool.Types.FirstOrDefault(t => t.Value == _query.Type).Label ?? "";
            var summary = string.Join(" · ", new[] { _query.Keyword, _query.Category, type, _query.City }.Where(x => x.Length > 0));
            return State(_query.Filtered ? "没有符合条件的岗位" : "这家公司暂时没有在招岗位",
                _query.Filtered ? "换个关键词，或减少方向、类型、城市的筛选条件试试。" : "官网的岗位同步后会出现在这里，稍后再来看看。",
                PoolArt.Empty(summary.Length == 0 ? CompanyName : summary),
                _query.Filtered ? [new V3Button("清除筛选", Clear, V3Button.Kind.Dark)] : []);
        }
        var rows = new StackPanel { Margin = new Thickness(-16, 8, -16, 0) };
        foreach (var job in _jobs)
            rows.Children.Add(JobRow(job, _join.JoiningId, () => _openJob(job.Text("id")), _openApplication, () => _ = JoinAsync(job)));
        FrameworkElement more;
        if (_moreFailed) more = HStack(0, Sans("加载失败，", 12.5, Fnt), TextLink("重试", () => _ = LoadMoreAsync(), 12.5, V3.Link));
        else if (_loadingMore) more = Sans("正在加载…", 12.5, Fnt);
        else if (_cursor is not null) more = new V3Button("加载更多", () => _ = LoadMoreAsync());
        else more = Sans("没有更多了", 12.5, Fnt);
        var footer = new Grid { MinHeight = 64 };
        footer.Children.Add(more.Align(HorizontalAlignment.Center, VerticalAlignment.Center));
        return VStack(0, rows, footer);
    }

    /// <summary>`PoolJobRow`：悬停白底卡片，右上角在悬停或已加入时显示「官网 / 加入求职进程」或「已加入求职进程」。</summary>
    internal static FrameworkElement JobRow(JsonNode job, string? joining, Action open, Action<string> openApplication, Action join)
    {
        var closed = job.Text("availability_status") == "closed";
        var joined = job.Text("joined_application_id").NonEmpty();
        var title = Sans(Title(job), 16, closed ? Fnt : Txt, Medium);
        var titleRow = HStack(10, title.Frame(height: 22));
        if (Core.Models.JobPool.IsToday(job.Text("new_at"))) titleRow.Children.Add(Badge("今日新增"));
        if (job.Text("availability_status") == "missing") titleRow.Children.Add(Badge("本轮未发现", warn: true));
        titleRow.Margin = new Thickness(0, 0, 220, 0);
        var meta = HStack(0);
        var parts = Core.Models.JobPool.Meta(job);
        for (var i = 0; i < parts.Count; i++)
        {
            if (i > 0) meta.Children.Add(new Border { Width = 1, Height = 11, Background = Brush(Cl), Margin = new Thickness(10, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center });
            meta.Children.Add(Sans(parts[i], 13, Sub));
        }
        meta.Height = 22;
        var body = VStack(8, titleRow, meta);
        // 两行 × 22 行高（`-webkit-line-clamp: 2`）
        if (job.Text("summary").NonEmpty() is { } summary) body.Children.Add(Sans(summary, 13, Fnt).LineHeight(22).Wrap(2).Frame(height: 44));
        body.Padding = new Thickness(16, 18, 16, 18);

        var actions = HStack(14);
        if (joined is { } application)
        {
            actions.Children.Add(new Border
            {
                Child = HStack(4, Icon("checkmark", 9, Hex(0x2E7D50)), Sans("已加入求职进程", 12, Hex(0x2E7D50), Medium)),
                Padding = new Thickness(10, 3, 10, 3), CornerRadius = new CornerRadius(12), Background = Brush(GreenSoft),
            }.OnTap(() => openApplication(application), "已加入求职进程"));
        }
        else
        {
            if (Web(job.Text("source_url")) is { } url) actions.Children.Add(Link("官网", url, 12.5, Sub, Medium).Align(v: VerticalAlignment.Center));
            if (!closed)
                actions.Children.Add(new V3Button(joining == job.Text("id") ? "正在加入…" : "加入求职进程", join, V3Button.Kind.Dark, height: 28, small: true) { Enabled = joining is null });
        }
        actions.HorizontalAlignment = HorizontalAlignment.Right;
        actions.VerticalAlignment = VerticalAlignment.Top;
        actions.Margin = new Thickness(0, 14, 16, 0);
        actions.Opacity = joined is not null ? 1 : 0;

        var card = new Grid { CornerRadius = new CornerRadius(12), Background = Brush(V3.Clear) };
        var surface = new Border { CornerRadius = new CornerRadius(12), Background = Brush(V3.Clear), Child = body };
        surface.OnTap(open, Title(job));
        card.Children.Add(surface);
        card.Children.Add(actions);
        card.OnHover(hover =>
        {
            surface.Background = Brush(hover ? V3.White : V3.Clear);
            surface.Shadow = hover ? new ThemeShadow() : null;
            surface.Translation = new System.Numerics.Vector3(0, 0, hover ? 4 : 0);
            title.Foreground = Brush(closed ? Fnt : hover ? Blue : Txt);
            actions.Opacity = hover || joined is not null ? 1 : 0;
        });
        return card;
    }

    /// <summary>Mac `revision += 1`：公司信息与岗位列表一起重新加载。</summary>
    void Reload() => _ = Task.WhenAll(LoadCompanyAsync(), LoadJobsAsync());

    void Change(PoolQuery query)
    {
        if (query == _query) return;
        _query = query;
        _ = LoadJobsAsync();
    }

    void Clear()
    {
        _keywordBox.Text = "";
        _keywordError = false;
        _query = new PoolQuery();
        _ = LoadJobsAsync();
    }

    void Submit()
    {
        var text = Trim(_keywordBox.Text);
        var count = new System.Globalization.StringInfo(text).LengthInTextElements;
        if (text.Length > 0 && (count < 2 || count > 100)) { _keywordError = true; Render(); return; }
        _keywordError = false;
        if (_query.Keyword == text) { Render(); return; }
        Change(_query with { Keyword = text });
    }

    Dictionary<string, string> Params(string? cursor = null)
    {
        var result = new Dictionary<string, string> { ["company_ids"] = _companyId };
        if (_query.Keyword.Length > 0) result["keyword"] = _query.Keyword;
        if (_query.City.Length > 0) result["city"] = _query.City;
        if (_query.Category.Length > 0) result["job_category"] = _query.Category;
        if (_query.Type.Length > 0) result["recruitment_type"] = _query.Type;
        if (cursor is not null) result["cursor"] = cursor;
        return result;
    }

    async Task LoadCompanyAsync()
    {
        _companyState = "loading";
        Render();
        try
        {
            _company = await App.Session.Api.CareerRequestAsync($"/api/job-pool/companies/{_companyId}", "GET", [], null);
            _companyState = "ready";
        }
        catch (ApiException error) when (error.Code == "JOB_POOL_COMPANY_NOT_FOUND") { _companyState = "missing"; }
        catch (Exception) { _companyState = "error"; }
        Render();
    }

    async Task LoadJobsAsync()
    {
        var generation = ++_generation;
        _loading = true; _loadingMore = false; _failed = false; _moreFailed = false; _cursor = null; _jobs = [];
        Render();
        try
        {
            var page = await App.Session.Api.CareerRequestAsync("/api/job-pool", "GET", Params(), null);
            if (generation != _generation) return;
            _jobs = page.Items("items");
            _cursor = page.Text("next_cursor").NonEmpty();
        }
        catch (Exception) { if (generation != _generation) return; _failed = true; }
        _loading = false;
        Render();
    }

    async Task LoadMoreAsync()
    {
        if (_cursor is not { } current || _loadingMore) return;
        var generation = _generation;
        _loadingMore = true; _moreFailed = false;
        Render();
        try
        {
            var page = await App.Session.Api.CareerRequestAsync("/api/job-pool", "GET", Params(current), null);
            if (generation != _generation) return;
            var known = _jobs.Select(x => x.Text("id")).ToHashSet();
            _jobs.AddRange(page.Items("items").Where(x => !known.Contains(x.Text("id"))));
            _cursor = page.Text("next_cursor").NonEmpty();
        }
        catch (Exception) { if (generation == _generation) _moreFailed = true; }
        finally { if (generation == _generation) { _loadingMore = false; Render(); } }
    }

    Task JoinAsync(JsonNode job) => _join.JoinAsync(job,
        (id, application) => _jobs = _jobs.Select(x => x.Text("id") == id ? With(x, "joined_application_id", application) : x).ToList(),
        id => _jobs = _jobs.Select(x => x.Text("id") == id ? With(x, "availability_status", "closed") : x).ToList());

    internal static JsonNode With(JsonNode value, string key, string text)
    {
        if (value is not JsonObject) return value;
        var copy = value.DeepClone();
        copy[key] = text;
        return copy;
    }
}
