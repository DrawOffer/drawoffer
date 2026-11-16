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

/// <summary>
/// B · 公司页（Windows 稿 06「公司页 · 岗位类型与标签」）：面包屑 → 公司头（Logo 56、名称 24、行业 / 城市标签与官网）与在招统计
/// → 方向 FilterChip 与本公司搜索 → 分隔线 → 招聘类型 SelectorBar（全部 / 校招 / 实习）与城市、排序 → 岗位列表（游标分页）。
/// </summary>
sealed class JobPoolCompany : UserControl
{
    readonly string _companyId;
    readonly Action _root;
    readonly Action<string> _openJob;
    readonly Action<string> _openApplication;
    readonly Grid _host = new();
    readonly PoolJoin _join;
    readonly V3SearchField _keywordBox;
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
        _keywordBox = new V3SearchField("搜索本公司岗位", initial.Keyword, width: 220, height: 32);
        _keywordBox.Changed += _ => { if (_keywordError) { _keywordError = false; Render(); } };
        _keywordBox.Box.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; Submit(); } };
        Content = _host;
        Loaded += async (_, _) => { await Task.WhenAll(LoadCompanyAsync(), LoadJobsAsync()); };
        Render();
    }

    string CompanyName => _company.Text("name");

    /// <summary>公司头城市标签：已加载岗位里出现最多的工作城市。</summary>
    string? MainCity => _jobs.SelectMany(Core.Models.JobPool.Cities).GroupBy(x => x)
        .OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.Ordinal).Select(g => g.Key).FirstOrDefault();

    /// <summary>公司头「HH:mm 同步」：岗位所属官网来源最近一次完整同步时间。</summary>
    string? SyncedAt => _jobs.Select(x => x.Get("source").Text("last_complete_at")).Where(x => x.Length > 0)
        .OrderByDescending(x => x, StringComparer.Ordinal).Select(x => Core.Models.JobPool.Synced(x)).FirstOrDefault(x => x is not null);

    void Render()
    {
        _host.Children.Clear();
        if (_companyState == "missing")
        {
            _host.Children.Add(new V3Page(VStack(0, Crumbs(_root, current: "公司不存在"),
                State("没有找到这家公司", "公司可能已不再收录，或链接不完整。", PoolArt.Unavailable("链接已失效"),
                    [TextLink("返回岗位广场", _root, 14, V3.Link)], width: 314, stage: 96)), top: 56));
            return;
        }
        var categories = new[] { ("", "全部", _company?.Get("open_count") is null ? null : (int?)_company.Integer("open_count")) }
            .Concat(_company.Items("categories").Select(x => (x.Text("name"), x.Text("name"), (int?)x.Integer("count"))));
        _keywordBox.Box.PlaceholderText = CompanyName.Length == 0 ? "搜索本公司岗位" : $"搜索{CompanyName}的岗位";
        if (_keywordBox.Parent is Panel parent) parent.Children.Remove(_keywordBox);
        var filters = Columns(16,
            (Star(), Chips(categories, _query.Category, "按方向筛选", value => Change(_query with { Category = value }))),
            (Auto, _keywordBox.Align(v: VerticalAlignment.Top)));
        var page = VStack(0,
            Crumbs(_root, current: CompanyName.Length == 0 ? "公司" : CompanyName),
            Head().Top(10),
            filters.Top(24),
            new Border { Height = 1, Background = Brush(V3.Line), Margin = new Thickness(0, 20, 0, 0) },
            ResultBar().Top(19),
            _keywordError ? Note(Core.Models.JobPool.KeywordError).Top(12) : null,
            List());
        _host.Children.Add(new V3Page(page, top: 56));
    }

    FrameworkElement Head()
    {
        if (_company is { } company)
        {
            var tags = HStack(6);
            if (company.Text("industry").NonEmpty() is { } industry) tags.Children.Add(MetaTag(industry));
            if (MainCity is { } city) tags.Children.Add(MetaTag(city));
            if (company.Text("careers_url").NonEmpty() is { } careers && Web(careers) is { } url)
                tags.Children.Add(Link(Core.Models.JobPool.Host(careers), url, 12, Sub).Align(v: VerticalAlignment.Center).Pad(4, 0, 0, 0));
            var name = Label(company.Text("name"), 24, Txt, Semibold).Frame(height: 32).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis);
            var identity = Columns(16, (Auto, Logo(company.Text("name"), company.Text("logo_url"), 56)), (Star(), VStack(6, name, tags).Pad(0, -4, 0, 0)));
            var synced = SyncedAt is { } at ? $"{at} 同步" : null;
            return Columns(24, (Star(), identity), (Auto, Stats(company.Integer("open_count"), company.Integer("today_new"), synced)));
        }
        if (_companyState == "error")
            return Note("公司信息暂时无法加载。", trailing: TextLink("重试", Reload, 12.5, Sub, Medium));
        var skeleton = HStack(16, Skeleton(56, 56, 12), VStack(10, Skeleton(140, 24), Skeleton(90, 12)).Align(v: VerticalAlignment.Center));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(skeleton, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return skeleton;
    }

    /// <summary>招聘类型只列 全部 / 校招 / 实习；有未分类岗位时才补「未分类」。</summary>
    IEnumerable<(string Value, string Label, int? Count)> Tabs()
    {
        var counts = _company.Get("counts");
        var unclassified = (int)(counts.Number("unclassified") ?? 0);
        yield return ("", "全部", _company is null || _company.Get("open_count") is null ? null : _company.Integer("open_count"));
        foreach (var type in Core.Models.JobPool.Types)
            yield return (type.Value, type.Label, counts.Number(type.Value) is { } n ? (int)n : null);
        if (unclassified > 0 || _query.Type == "unclassified") yield return ("unclassified", "未分类", unclassified);
    }

    /// <summary>
    /// SelectorBar（Windows 稿）：选中项墨色 500 字，底部居中 16×3 指示条；数量 12 号灰字。右侧清除筛选、城市（96）与排序（120）ComboBox。
    /// </summary>
    FrameworkElement ResultBar()
    {
        var tabs = HStack(28);
        foreach (var tab in Tabs())
        {
            var active = _query.Type == tab.Value;
            var row = HStack(4, Sans(tab.Label, 14, active ? Txt : Sub, active ? Medium : Regular));
            if (tab.Count is { } count) row.Children.Add(Number(Grouped(count), 12, Fnt, Regular).Align(v: VerticalAlignment.Bottom).Pad(0, 0, 0, 1));
            var cell = new Grid { Height = 31 };
            cell.Children.Add(row.Align(v: VerticalAlignment.Top).Frame(height: 22));
            cell.Children.Add(new Border
            {
                Width = 16, Height = 3, CornerRadius = new CornerRadius(1.5), Background = Brush(active ? Txt : Clear),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom,
            });
            var value = tab.Value;
            tabs.Children.Add(cell.OnTap(() => Change(_query with { Type = value }), tab.Label));
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(tabs, "招聘类型");
        var tools = HStack(8);
        if (_query.Filtered) tools.Children.Add(TextLink("清除筛选", Clear, 12, Sub).Align(v: VerticalAlignment.Center).Pad(0, 0, 4, 0));
        var cities = new[] { ("all", "全部城市") }.Concat(_company.Items("cities").Select(x => x.String()).OfType<string>().Select(x => (x, x))).ToList();
        tools.Children.Add(Select("城市", _query.City, cities, value => Change(_query with { City = value == "all" ? "" : value }), "城市", width: 96));
        tools.Children.Add(Select("排序", _query.Sort, [("published", "最新发布"), ("collected", "最新收录")], value => Change(_query with { Sort = value })));
        tools.VerticalAlignment = VerticalAlignment.Top;
        tools.Margin = new Thickness(0, -6, 0, 0);
        return Columns(16, (Star(), tabs), (Auto, tools));
    }

    FrameworkElement List()
    {
        if (_failed) return Error("岗位暂时无法加载", "网络不稳定或服务暂时不可用，筛选条件已保留。", Reload);
        if (_loading)
        {
            var stack = new StackPanel { Spacing = 12, Margin = new Thickness(-20, 13, -20, 0) };
            for (var i = 0; i < 5; i++)
                stack.Children.Add(VStack(10, Ratio(0.38, 16), Ratio(0.3, 12), Ratio(0.7, 12), Ratio(0.55, 12)).Also(s => { s.Height = 92; s.Margin = new Thickness(20, 14, 20, 14); }));
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
                _query.Filtered ? [new V3Button("清除筛选", Clear, V3Button.Kind.Ghost)] : []);
        }
        var rows = new StackPanel { Spacing = 12, Margin = new Thickness(-20, 13, -20, 0) };
        foreach (var job in _jobs)
            rows.Children.Add(JobRow(job, _join.JoiningId, () => _openJob(job.Text("id")), _openApplication, () => _ = JoinAsync(job)));
        FrameworkElement more;
        if (_moreFailed) more = HStack(0, Sans("加载失败，", 12.5, Fnt), TextLink("重试", () => _ = LoadMoreAsync(), 12.5, V3.Link));
        else if (_loadingMore) more = Sans("正在加载…", 12.5, Fnt);
        else if (_cursor is not null) more = new V3Button("加载更多", () => _ = LoadMoreAsync(), V3Button.Kind.Ghost, height: 32);
        else more = Sans("没有更多了", 12.5, Fnt2);
        var footer = new Grid { MinHeight = 64 };
        footer.Children.Add(more.Align(HorizontalAlignment.Center, VerticalAlignment.Center));
        return VStack(0, rows, footer);
    }

    /// <summary>
    /// 岗位条目（Windows 稿 JobRow）：标题「岗位名 - 团队」16/500 + 今日新增；细竖线分隔的属性行（城市｜类型｜方向标签｜招聘项目｜发布时间，
    /// 今天发布用蓝字）；灰色简介最多两行。列表无分隔线；悬停整条浮起为白底圆角 12 卡片，右侧出现「官网 ↗」与唯一黑色胶囊「加入求职进程」；
    /// 已加入的条目在属性行末尾常显灰色「✓ 已加入求职进程」。
    /// </summary>
    internal static FrameworkElement JobRow(JsonNode job, string? joining, Action open, Action<string> openApplication, Action join)
    {
        var closed = job.Text("availability_status") == "closed";
        var joined = job.Text("joined_application_id").NonEmpty();
        var title = Sans(Title(job), 16, closed ? Fnt : Txt, Medium).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis);
        var titleRow = HStack(8, title.Frame(height: 22));
        if (Core.Models.JobPool.IsToday(job.Text("new_at"))) titleRow.Children.Add(Badge("今日新增"));
        if (job.Text("availability_status") == "missing") titleRow.Children.Add(Badge("本轮未发现", warn: true));

        var fresh = Core.Models.JobPool.IsToday(job.Text("published_at"));
        var relative = Core.Models.JobPool.Relative(job.Text("published_at"));
        var parts = new List<FrameworkElement>
        {
            Sans(string.Join("、", Core.Models.JobPool.Cities(job)).NonEmpty() ?? "地点未标明", 12.5, Sub),
            Sans(Core.Models.JobPool.Recruitment(job), 12.5, Sub),
        };
        if (job.Text("category").NonEmpty() is { } category) parts.Add(MetaTag(category, 20));
        if (Core.Models.JobPool.Attribute(job, "batch") is { } batch) parts.Add(Sans(batch, 12.5, Sub));
        if (job.Text("salary_text").NonEmpty() is { } salary) parts.Add(Sans(salary, 12.5, Sub));
        if (relative.Length > 0) parts.Add(Sans(fresh ? "今天发布" : relative, 12.5, fresh ? Blue : Sub));
        var meta = HStack(0);
        for (var i = 0; i < parts.Count; i++)
        {
            if (i > 0) meta.Children.Add(new Border { Width = 1, Height = 11, Background = Brush(Cl), Margin = new Thickness(10, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center });
            meta.Children.Add(parts[i].Align(v: VerticalAlignment.Center));
        }
        if (joined is { } application)
            meta.Children.Add(new Border
            {
                Child = Sans("✓ 已加入求职进程", 11.5, Fnt).Align(v: VerticalAlignment.Center), Height = 22, Padding = new Thickness(9, 0, 9, 0), Margin = new Thickness(10, 0, 0, 0),
                CornerRadius = Capsule(22), Background = Brush(Field), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            }.OnTap(() => openApplication(application), "已加入求职进程，打开求职记录"));
        meta.Height = 22;
        var body = VStack(0, titleRow, meta.Top(10));
        // 最多两行（行高 22），超出以省略号截断；不设固定高度
        if (job.Text("summary").NonEmpty() is { } summary) body.Children.Add(Sans(summary, 12.5, Fnt).LineHeight(22).Wrap(2).Top(10));
        body.Padding = new Thickness(20, 20, 250, 20);

        var actions = HStack(9);
        if (joined is null)
        {
            if (Web(job.Text("source_url")) is { } url)
                actions.Children.Add(new Border
                {
                    Child = Sans("官网 ↗", 12.5, Txt, Medium).Align(v: VerticalAlignment.Center), Height = 32, Padding = new Thickness(14, 0, 14, 0),
                    CornerRadius = Capsule(32), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
                }.OnTap(() => Launch(url), "官网"));
            if (!closed)
                actions.Children.Add(new V3Button(joining == job.Text("id") ? "正在加入…" : "加入求职进程", join, V3Button.Kind.Dark, height: 32) { Enabled = joining is null });
        }
        actions.HorizontalAlignment = HorizontalAlignment.Right;
        actions.VerticalAlignment = VerticalAlignment.Center;
        actions.Margin = new Thickness(0, 0, 20, 0);
        actions.Visibility = Visibility.Collapsed;

        var surface = new Border { CornerRadius = new CornerRadius(12), Background = Brush(Clear), BorderBrush = Brush(Clear), BorderThickness = new Thickness(1), Child = body };
        surface.OnTap(open, Title(job));
        var card = new Grid();
        card.Children.Add(surface);
        card.Children.Add(actions);
        card.OnHover(hover =>
        {
            surface.Background = Brush(hover ? V3.White : Clear);
            surface.BorderBrush = Brush(hover ? V3.Line : Clear);
            surface.Shadow = hover ? new ThemeShadow() : null;
            surface.Translation = new System.Numerics.Vector3(0, 0, hover ? 6 : 0);
            title.Foreground = Brush(closed ? Fnt : hover ? Blue : Txt);
            actions.Visibility = hover && actions.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
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
        _query = new PoolQuery(Sort: _query.Sort);
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
        var result = new Dictionary<string, string> { ["company_ids"] = _companyId, ["sort"] = _query.Sort };
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
