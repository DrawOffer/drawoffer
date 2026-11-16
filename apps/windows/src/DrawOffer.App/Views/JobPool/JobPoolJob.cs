using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.JobPool.PoolUI;

namespace DrawOffer.App.Views.JobPool;

/// <summary>
/// C · 岗位详情（Windows 稿 06「岗位详情页」）：左正文 680（面包屑 → 公司 → 标题 → 状态 → 横向信息带 → 分段正文 → 来源），
/// 右侧 328 宽：操作卡（未加入 / 已加入 / 已下线三种状态）、公司卡与同方向岗位。
/// </summary>
sealed class JobPoolJob : UserControl
{
    readonly string _jobId;
    readonly Action _root;
    readonly Action<string, PoolQuery> _openCompany;
    readonly Action<string> _openJob;
    readonly Action<string> _openApplication;
    readonly Grid _host = new();
    readonly PoolJoin _join;
    JsonNode? _job, _company;
    string _state = "loading";
    List<JsonNode> _related = [];
    bool _copied;
    int _copyToken;

    public JobPoolJob(string jobId, Action root, Action<string, PoolQuery> openCompany, Action<string> openJob, Action<string> openApplication)
    {
        _jobId = jobId;
        _root = root;
        _openCompany = openCompany;
        _openJob = openJob;
        _openApplication = openApplication;
        _join = new PoolJoin(() => XamlRoot, _host, openApplication, Render);
        Content = _host;
        Loaded += async (_, _) => await LoadAsync();
        Render();
    }

    void Render()
    {
        _host.Children.Clear();
        FrameworkElement page = _state switch
        {
            "missing" => VStack(0, Crumbs(_root, current: "岗位不存在"),
                State("没有找到这个岗位", "岗位可能已被移除，或链接不完整。", PoolArt.Unavailable("链接已失效"), [TextLink("返回岗位广场", _root, 14, V3.Link)], width: 314, stage: 96)),
            "error" => VStack(0, Crumbs(_root, current: "岗位详情"),
                Error("岗位详情暂时无法加载", "网络不稳定或服务暂时不可用，稍后重试即可。", () => _ = LoadAsync())),
            _ => _job is { } job ? Detail(job) : Skeletons(),
        };
        _host.Children.Add(new V3Page(page, top: 56, bottom: 48));
    }

    static FrameworkElement Skeletons()
    {
        var stack = VStack(14, Skeleton(220, 12), Skeleton(96, 14), Skeleton(380, 30, 6), Skeleton(300, 12),
            Skeleton(680, 72), Skeleton(80, 16), Skeleton(630, 12), Skeleton(560, 12));
        stack.HorizontalAlignment = HorizontalAlignment.Left;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(stack, "正在加载岗位详情…");
        return stack;
    }

    FrameworkElement Detail(JsonNode job)
    {
        var companyId = job.Get("company").Text("id");
        var companyName = job.Get("company").Text("name");
        var main = Main(job, companyId, companyName);
        main.MaxWidth = 680;
        main.HorizontalAlignment = HorizontalAlignment.Left;
        var side = Side(job, companyId, companyName);
        side.Margin = new Thickness(0, 16, 0, 0);
        var row = Columns(40, (Star(), main), (Px(328), side));
        row.VerticalAlignment = VerticalAlignment.Top;
        return row;
    }

    static List<(string Label, string Value)> Facts(JsonNode job) => new List<(string, string)>
    {
        ("工作城市", string.Join("、", Core.Models.JobPool.Cities(job))), ("招聘类型", Core.Models.JobPool.JobType(job)), ("岗位方向", job.Text("category")),
        ("招聘项目", Core.Models.JobPool.Attribute(job, "batch") ?? ""), ("毕业届别", Core.Models.JobPool.Attribute(job, "graduation_year") ?? ""),
        ("学历要求", Core.Models.JobPool.Attribute(job, "education_requirement") ?? ""), ("经验要求", Core.Models.JobPool.Attribute(job, "experience_requirement") ?? ""),
        ("薪资", job.Text("salary_text")),
        ("投递截止", Core.Models.JobPool.Attribute(job, "deadline") is { } d ? Core.Models.JobPool.Deadline(d)?.Date ?? d : ""),
    }.Where(x => x.Item2.Length > 0).ToList();

    StackPanel Main(JsonNode job, string companyId, string companyName)
    {
        var closed = job.Text("availability_status") == "closed";
        var missing = job.Text("availability_status") == "missing";
        (Color Color, string Text) status = closed ? (Fnt, "已从官网下线") : missing ? (Orange, "本轮未发现") : (Green, "官网在招");
        var stack = VStack(0,
            Crumbs(_root, [(companyName, () => _openCompany(companyId, new PoolQuery()))], job.Text("title")),
            HStack(8, Logo(companyName, job.Get("company").Text("logo_url"), 20), Sans(companyName, 13, Sub, Medium).Align(v: VerticalAlignment.Center))
                .OnTap(() => _openCompany(companyId, new PoolQuery()), companyName).Top(12),
            Label(Title(job), 26, Txt, Semibold).LineHeight(34).Wrap().Top(12));

        // 状态行：今日新增 · 官网在招 · 今天 09:12 发布 · 官网 10:30 同步
        var statusRow = HStack(8);
        if (Core.Models.JobPool.IsToday(job.Text("new_at")) && !closed) statusRow.Children.Add(Badge("今日新增"));
        statusRow.Children.Add(HStack(5, new Ellipse { Width = 6, Height = 6, Fill = Brush(status.Color), VerticalAlignment = VerticalAlignment.Center }, Sans(status.Text, 12, status.Color, Medium)));
        var trail = new List<string>();
        if (job.Text("published_at").NonEmpty() is { } at) trail.Add($"{Core.Models.JobPool.Date(at)} 发布");
        if (job.Get("source").Text("last_complete_at").NonEmpty() is { } complete && Core.Models.JobPool.Synced(complete) is { } synced) trail.Add($"官网 {synced} 同步");
        foreach (var item in trail) { statusRow.Children.Add(Sans("·", 12, Fnt2)); statusRow.Children.Add(Sans(item, 12, Fnt)); }
        foreach (var child in statusRow.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
        statusRow.Height = 22;
        stack.Children.Add(statusRow.Top(12));
        if (!closed && missing) stack.Children.Add(Note("本轮同步未发现该岗位，暂时保留；请到官网确认招聘状态。", icon: true).Top(16));

        // 横向信息带：上下细线，标签 11 灰、值 14/500，1×32 竖线分隔
        var facts = Facts(job);
        if (facts.Count > 0)
        {
            var flow = new VariableSizedFlow(0);
            for (var i = 0; i < facts.Count; i++)
            {
                var cell = VStack(4, Sans(facts[i].Label, 11, Fnt).Frame(height: 16), Sans(facts[i].Value, 14, Txt, Medium).Frame(height: 22));
                var item = HStack(0);
                if (i > 0) item.Children.Add(new Border { Width = 1, Height = 32, Background = Brush(V3.Line), Margin = new Thickness(20, 0, 20, 0), VerticalAlignment = VerticalAlignment.Center });
                item.Children.Add(cell);
                item.Margin = new Thickness(0, 15, 0, 15);
                flow.Add(item);
            }
            stack.Children.Add(new Border
            {
                Child = flow.Panel, Margin = new Thickness(0, 28, 0, 0),
                BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 1, 0, 1),
            });
        }
        stack.Children.Add(Body(job.Text("description")));

        var source = Columns(16, (Star(), Sans($"内容同步自{companyName}招聘官网，投递要求与最新状态以官网为准。", 12, Fnt).Wrap().Align(v: VerticalAlignment.Center)),
            (Auto, Web(job.Text("source_url")) is { } url ? new V3Button("查看原文 ↗", () => Launch(url), V3Button.Kind.Ghost, height: 28, small: true) : new Border()));
        stack.Children.Add(new Border
        {
            Child = source, Padding = new Thickness(0, 13, 0, 0), Margin = new Thickness(0, 28, 0, 0),
            BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 1, 0, 0),
        });
        return stack;
    }

    /// <summary>正文：已知小标题分段（16/600），段落 14 号行高 24；编号行对齐成 01、02 要点。</summary>
    static FrameworkElement Body(string text)
    {
        var sections = Core.Models.JobPool.Sections(text);
        var stack = new StackPanel();
        if (sections.Count == 0) { stack.Children.Add(Section("岗位描述", [Paragraph("官网暂未提供岗位正文，请查看招聘官网。")])); return stack; }
        foreach (var item in sections)
        {
            var blocks = new List<UIElement>();
            foreach (var block in item.Blocks)
            {
                if (block is Core.Models.JobPool.Block.Paragraph paragraph) { blocks.Add(Paragraph(paragraph.Text)); continue; }
                if (block is not Core.Models.JobPool.Block.Points points) continue;
                var list = new StackPanel { Spacing = 10, Margin = new Thickness(0, 14, 0, 0) };
                for (var i = 0; i < points.Items.Count; i++)
                    list.Children.Add(Columns(0,
                        (Px(26), Number(i + 1 < 10 ? $"0{i + 1}" : $"{i + 1}", 12, Fnt2, Regular).Pad(0, 3, 0, 0).Align(v: VerticalAlignment.Top)),
                        (Star(), Sans(points.Items[i], 14, Hex(0x3A3A36)).LineHeight(22).Wrap().Also(t => t.MinHeight = 22))));
                blocks.Add(list);
            }
            stack.Children.Add(Section(item.Title, blocks));
        }
        return stack;
    }

    static FrameworkElement Section(string title, IEnumerable<UIElement> content)
    {
        var stack = VStack(0, Label(title, 16, Txt, Semibold).Frame(height: 24));
        foreach (var child in content) stack.Children.Add(child);
        stack.Margin = new Thickness(0, 28, 0, 0);
        return stack;
    }

    static TextBlock Paragraph(string text) => Sans(text, 14, Hex(0x3A3A36)).LineHeight(24).Wrap().Also(t => t.MinHeight = 24).Top(14);

    static Border SideCard(UIElement child) => new()
    {
        Child = child, Padding = new Thickness(20), CornerRadius = new CornerRadius(8),
        Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
    };

    StackPanel Side(JsonNode job, string companyId, string companyName)
    {
        var closed = job.Text("availability_status") == "closed";
        var joined = job.Text("joined_application_id").NonEmpty();
        var deadline = Core.Models.JobPool.Attribute(job, "deadline");
        var sourceId = job.Text("source_job_id").NonEmpty();
        var source = Web(job.Text("source_url"));
        var action = new StackPanel { Spacing = 12 };
        if (joined is { } application)
        {
            action.Children.Add(StatusBlock("✓ 已加入求职进程"));
            if (source is not null) action.Children.Add(Official(source));
            action.Children.Add(Columns(8,
                (Star(), Sans(closed ? "岗位已下线，已有记录仍可管理" : "已在投递看板跟进", 12, Fnt).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis)),
                (Auto, TextLink("在投递看板查看 →", () => _openApplication(application), 12, V3.Link, Regular))));
        }
        else if (closed)
        {
            action.Children.Add(StatusBlock("岗位已从官网下线"));
            action.Children.Add(Sans("以下为收录时的内容，无法再加入求职进程。", 12, Fnt).LineHeight(18).Wrap());
            var others = _company?.Get("open_count") is not null ? $" {Grouped(_company.Integer("open_count"))} 个" : "";
            action.Children.Add(TextLink($"查看{companyName}其他{others}岗位 →", () => _openCompany(companyId, new PoolQuery()), 12, V3.Link, Regular));
        }
        else
        {
            var joining = _join.JoiningId == job.Text("id");
            action.Children.Add(new V3Button(joining ? "正在加入…" : "加入求职进程", () => _ = JoinAsync(job), V3Button.Kind.Dark, height: 32, fill: true) { Enabled = _join.JoiningId is null });
            if (source is not null) action.Children.Add(Official(source));
            action.Children.Add(Sans("加入后在投递看板跟进投递进度、安排面试。", 12, Fnt).LineHeight(18).Wrap());
        }
        if (deadline is not null || sourceId is not null)
        {
            var rows = new StackPanel { Spacing = 12 };
            if (deadline is not null)
            {
                // 截止日「11月30日 · 还剩 N 天」；无法解析或已过期只写日期
                var parsed = Core.Models.JobPool.Deadline(deadline);
                rows.Children.Add(Row("投递截止", Sans(string.Join(" · ", new[] { parsed?.Date ?? deadline, parsed?.Left }.OfType<string>()), 12, Txt, Medium)));
            }
            if (sourceId is { } id)
                rows.Children.Add(Row("职位 ID", HStack(8, Number(id, 12, Txt, Medium).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis), TextLink(_copied ? "已复制" : "复制", () => Copy(id), 12, V3.Link, Regular))));
            action.Children.Add(new Border
            {
                Child = rows, Padding = new Thickness(0, 12, 0, 0),
                BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 1, 0, 0),
            });
        }
        var side = VStack(16, SideCard(action));
        if (_company is { } company) side.Children.Add(CompanyCard(company, Core.Models.JobPool.Cities(job).FirstOrDefault()));
        if (_related.Count > 0) side.Children.Add(Related(job, companyId));
        return side;
    }

    void Copy(string id)
    {
        var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
        package.SetText(id);
        Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
        _copied = true;
        var token = ++_copyToken;
        Render();
        _ = Task.Delay(1600).ContinueWith(_ => DispatcherQueue.TryEnqueue(() => { if (token == _copyToken) { _copied = false; Render(); } }));
    }

    /// <summary>已加入 / 已下线时代替主按钮的状态条：32 高灰底，13/500 灰字居中。</summary>
    static FrameworkElement StatusBlock(string text) => new Border
    {
        Child = Sans(text, 13, Sub, Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        Height = 32, CornerRadius = Capsule(32), Background = Brush(Field),
    };

    static FrameworkElement Official(Uri url) =>
        new V3Button("去官网投递 ↗", () => Launch(url), V3Button.Kind.Ghost, height: 32, fill: true);

    static FrameworkElement Row(string label, FrameworkElement value)
    {
        var row = Columns(12, (Star(), Sans(label, 12, Fnt).Align(v: VerticalAlignment.Center)), (Auto, value.Align(v: VerticalAlignment.Center)));
        row.Height = 18;
        return row;
    }

    /// <summary>公司卡：Logo 40 + 名称 14/500 与「行业 · 城市」；细线下「1,240 个在招 今日 +36」与「全部岗位 →」。</summary>
    FrameworkElement CompanyCard(JsonNode company, string? city)
    {
        var today = company.Integer("today_new");
        var sub = string.Join(" · ", new[] { company.Text("industry"), city ?? "" }.Where(x => x.Length > 0));
        var head = HStack(12, Logo(company.Text("name"), company.Text("logo_url"), 40),
            VStack(2, Sans(company.Text("name"), 14, Txt, Medium).Frame(height: 22), Sans(sub, 12, Fnt).Frame(height: 18)).Align(v: VerticalAlignment.Center));
        var left = HStack(6, Number(Grouped(company.Integer("open_count")), 14, Txt, Medium), Sans("个在招", 12, Fnt).Align(v: VerticalAlignment.Center),
            today > 0 ? Sans($"今日 +{Grouped(today)}", 12, Blue).Align(v: VerticalAlignment.Center) : null);
        var foot = Columns(12, (Star(), left.Align(v: VerticalAlignment.Center)),
            (Auto, TextLink("全部岗位 →", () => _openCompany(company.Text("id"), new PoolQuery()), 12, Txt, Medium).Align(v: VerticalAlignment.Center)));
        foot.Height = 22;
        var footer = new Border { Child = foot, Padding = new Thickness(0, 12, 0, 0), Margin = new Thickness(0, 12, 0, 0), BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 1, 0, 0) };
        return SideCard(VStack(0, head, footer));
    }

    /// <summary>同方向岗位：标题 14/600 + 「全部 N 个 →」；条目之间细线，标题 13.5、下一行「城市 · 类型 · 时间」12 灰。</summary>
    FrameworkElement Related(JsonNode job, string companyId)
    {
        var category = job.Text("category");
        var same = _company.Items("categories").FirstOrDefault(x => x.Text("name") == category) is { } match && match.Get("count") is not null ? match.Integer("count") : (int?)null;
        var head = Columns(0, (Star(), Label("同方向岗位", 14, Txt, Semibold).Frame(height: 22)),
            (Auto, category.Length == 0 ? new Border() : TextLink($"全部{(same is { } n ? $" {Grouped(n)} 个" : "")} →", () => _openCompany(companyId, new PoolQuery(Category: category)), 12, Fnt, Regular).Align(v: VerticalAlignment.Center)));
        head.Margin = new Thickness(0, 12, 0, 8);
        var stack = VStack(0, head);
        for (var i = 0; i < _related.Count; i++)
        {
            var item = _related[i];
            var meta = string.Join(" · ", new[] { Core.Models.JobPool.Cities(item).FirstOrDefault() ?? "", Core.Models.JobPool.Recruitment(item), Core.Models.JobPool.Relative(item.Text("published_at")) }.Where(x => x.Length > 0));
            var title = Sans(Title(item), 13.5, Txt).Frame(height: 22).Also(t => t.TextTrimming = TextTrimming.CharacterEllipsis);
            var cell = new Border
            {
                Child = VStack(4, title, Sans(meta, 12, Fnt).Frame(height: 18)),
                Padding = new Thickness(0, 10, 0, 11), Background = Brush(Clear),
                BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, i > 0 ? 1 : 0, 0, 0),
            };
            cell.OnHover(h => title.Foreground = Brush(h ? Blue : Txt));
            var id = item.Text("id");
            stack.Children.Add(cell.OnTap(() => _openJob(id), Title(item)));
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(stack, "同方向岗位");
        return stack;
    }

    async Task LoadAsync()
    {
        _state = "loading";
        Render();
        try
        {
            _job = await App.Session.Api.CareerRequestAsync($"/api/job-pool/{_jobId}", "GET", [], null);
            _state = "ready";
        }
        catch (ApiException error) when (error.Code == "JOB_POOL_NOT_FOUND") { _state = "missing"; Render(); return; }
        catch (Exception) { _state = "error"; Render(); return; }
        Render();
        // 侧栏卡片是附加信息：失败时直接不显示。
        if (_job.Get("company").Text("id").NonEmpty() is not { } companyId) return;
        try { _company = await App.Session.Api.CareerRequestAsync($"/api/job-pool/companies/{companyId}", "GET", [], null); } catch (Exception) { }
        var query = new Dictionary<string, string> { ["company_ids"] = companyId };
        if (_job.Text("category").NonEmpty() is { } category) query["job_category"] = category;
        try
        {
            var page = await App.Session.Api.CareerRequestAsync("/api/job-pool", "GET", query, null);
            _related = page.Items("items").Where(x => x.Text("id") != _jobId).Take(4).ToList();
        }
        catch (Exception) { }
        Render();
    }

    Task JoinAsync(JsonNode value) => _join.JoinAsync(value,
        (_, application) => { if (_job is not null) _job = JobPoolCompany.With(_job, "joined_application_id", application); },
        _ => { if (_job is not null) _job = JobPoolCompany.With(_job, "availability_status", "closed"); });
}
