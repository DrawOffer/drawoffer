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

/// <summary>C · 岗位详情：主栏（公司、标题、状态、事实、正文、来源）+ 320 宽侧栏（加入、官网、截止与职位 ID、公司卡、同方向岗位）。</summary>
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
        _host.Children.Add(new V3Page(page, bottom: 48));
    }

    static FrameworkElement Skeletons()
    {
        var stack = VStack(14, Skeleton(180, 12), Skeleton(96, 14), Skeleton(350, 30, 6), Skeleton(245, 12),
            Skeleton(700, 56), Skeleton(80, 16), Skeleton(630, 12), Skeleton(560, 12));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(stack, "正在加载岗位详情…");
        return stack;
    }

    FrameworkElement Detail(JsonNode job)
    {
        var companyId = job.Get("company").Text("id");
        var companyName = job.Get("company").Text("name");
        var main = Main(job, companyId, companyName);
        main.MaxWidth = 700;
        main.HorizontalAlignment = HorizontalAlignment.Left;
        var row = Columns(40, (Star(), main), (Px(320), Side(job, companyId, companyName)));
        row.VerticalAlignment = VerticalAlignment.Top;
        return VStack(0, Crumbs(_root, [(companyName, () => _openCompany(companyId, new PoolQuery()))], job.Text("title")), row);
    }

    static List<(string Label, string Value)> Facts(JsonNode job) => new List<(string, string)>
    {
        ("工作城市", string.Join("、", Core.Models.JobPool.Cities(job))), ("招聘类型", Core.Models.JobPool.JobType(job)), ("岗位方向", job.Text("category")),
        ("招聘项目", Core.Models.JobPool.Attribute(job, "batch") ?? ""), ("毕业届别", Core.Models.JobPool.Attribute(job, "graduation_year") ?? ""),
        ("学历要求", Core.Models.JobPool.Attribute(job, "education_requirement") ?? ""), ("经验要求", Core.Models.JobPool.Attribute(job, "experience_requirement") ?? ""),
        ("薪资", job.Text("salary_text")), ("投递截止", Core.Models.JobPool.Attribute(job, "deadline") ?? ""),
    }.Where(x => x.Item2.Length > 0).ToList();

    StackPanel Main(JsonNode job, string companyId, string companyName)
    {
        var closed = job.Text("availability_status") == "closed";
        var missing = job.Text("availability_status") == "missing";
        (Color Color, string Text) status = closed ? (Fnt, "已从官网下线") : missing ? (Orange, "本轮未发现") : (Hex(0x2E7D50), "官网在招");
        var published = job.Text("published_at").NonEmpty() is { } at ? $"官网 {Core.Models.JobPool.Date(at)} 发布" : null;
        var stack = VStack(0,
            HStack(8, Logo(companyName, job.Get("company").Text("logo_url"), 24), Sans(companyName, 13, Sub)).OnTap(() => _openCompany(companyId, new PoolQuery()), companyName),
            Label(Title(job), 26, Txt, Semibold).LineHeight(37.7).Wrap().Top(18));
        var statusRow = HStack(12);
        if (Core.Models.JobPool.IsToday(job.Text("new_at")) && !closed) statusRow.Children.Add(Badge("今日新增"));
        statusRow.Children.Add(HStack(6, new Ellipse { Width = 6, Height = 6, Fill = Brush(status.Color) }, Sans(status.Text, 12.5, status.Color, Medium)));
        if (published is not null) statusRow.Children.Add(Sans(published, 12.5, Fnt));
        statusRow.Height = 22;
        statusRow.Margin = new Thickness(0, 10, 0, 0);
        stack.Children.Add(statusRow);
        if (!closed && missing) stack.Children.Add(Note("本轮同步未发现该岗位，暂时保留；请到官网确认招聘状态。", icon: true).Top(16));
        var facts = Facts(job);
        if (facts.Count > 0)
        {
            var flow = new VariableSizedFlow(0);
            for (var i = 0; i < facts.Count; i++)
            {
                var cell = VStack(4, Sans(facts[i].Label, 12, Fnt).Frame(height: 20), Sans(facts[i].Value, 14, Txt, Medium).Frame(height: 24));
                flow.Add(new Border
                {
                    Child = cell, Padding = new Thickness(i == 0 ? 0 : 20, 0, 20, 0),
                    BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(i == 0 ? 0 : 1, 0, 0, 0),
                });
            }
            stack.Children.Add(new Border
            {
                Child = flow.Panel, Padding = new Thickness(0, 17, 0, 17), Margin = new Thickness(0, 22, 0, 0),
                BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 1, 0, 1),
            });
        }
        stack.Children.Add(Body(job.Text("description")));
        var source = Columns(16, (Star(), Sans($"内容同步自{companyName}招聘官网，投递要求与最新状态以官网为准。", 12, Fnt).Align(v: VerticalAlignment.Center)),
            (Auto, Web(job.Text("source_url")) is { } url ? Link("查看原文", url, 12, Sub, Medium) : new Border()));
        source.Height = 21;
        stack.Children.Add(new Border
        {
            Child = source, Padding = new Thickness(0, 15, 0, 0), Margin = new Thickness(0, 36, 0, 0),
            BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 1, 0, 0),
        });
        return stack;
    }

    /// <summary>`JobBody`：已知小标题分段，编号行对齐成 01、02 要点。</summary>
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
                var list = new StackPanel { Spacing = 8, Margin = new Thickness(0, 12, 0, 0) };
                for (var i = 0; i < points.Items.Count; i++)
                    list.Children.Add(Columns(0,
                        (Px(28), Number(i + 1 < 10 ? $"0{i + 1}" : $"{i + 1}", 12, Fnt2).Pad(0, 4, 0, 0).Align(v: VerticalAlignment.Top)),
                        (Star(), Sans(points.Items[i], 14, Hex(0x3A3A36)).LineHeight(24).Wrap().Also(t => t.MinHeight = 24))));
                blocks.Add(list);
            }
            stack.Children.Add(Section(item.Title, blocks));
        }
        return stack;
    }

    static FrameworkElement Section(string title, IEnumerable<UIElement> content)
    {
        var stack = VStack(0, Label(title, 16, Txt, Semibold).Frame(height: 22));
        foreach (var child in content) stack.Children.Add(child);
        stack.Margin = new Thickness(0, 30, 0, 0);
        return stack;
    }

    /// <summary>14px、`lineSpacing(7)`（行高 14 × 1.2 + 7 ≈ 24）、上距 10。</summary>
    static TextBlock Paragraph(string text) => Sans(text, 14, Hex(0x3A3A36)).LineHeight(24).Wrap().Also(t => t.MinHeight = 24).Top(10);

    FrameworkElement Side(JsonNode job, string companyId, string companyName)
    {
        var closed = job.Text("availability_status") == "closed";
        var joined = job.Text("joined_application_id").NonEmpty();
        var deadline = Core.Models.JobPool.Attribute(job, "deadline");
        var sourceId = job.Text("source_job_id").NonEmpty();
        var source = Web(job.Text("source_url"));
        var action = new StackPanel { Spacing = 10 };
        if (joined is { } application)
        {
            action.Children.Add(StatusBlock("已加入求职进程", check: true));
            if (source is not null) action.Children.Add(Official(source));
            action.Children.Add(Hint(closed ? "岗位已从官网下线，已有记录仍可管理。" : "可在投递看板跟进投递和面试。", ("在投递看板查看 →", () => _openApplication(application))));
        }
        else if (closed)
        {
            action.Children.Add(StatusBlock("岗位已从官网下线", check: false));
            action.Children.Add(Hint("以下为收录时的内容，无法再加入求职进程。", ($"查看{companyName}的其他岗位 →", () => _openCompany(companyId, new PoolQuery()))));
        }
        else
        {
            var joining = _join.JoiningId == job.Text("id");
            action.Children.Add(new V3Button(joining ? "正在加入…" : "加入求职进程", () => _ = JoinAsync(job), V3Button.Kind.Dark, height: 36, width: 280, icon: joining ? null : "plus")
                { Enabled = _join.JoiningId is null }.Also(b => b.HorizontalAlignment = HorizontalAlignment.Stretch));
            if (source is not null) action.Children.Add(Official(source));
            action.Children.Add(Hint("加入后在投递看板跟进投递进度、安排面试。", null));
        }
        if (deadline is not null || sourceId is not null)
        {
            var rows = new StackPanel { Spacing = 10 };
            if (deadline is not null) rows.Children.Add(Row("投递截止", Sans(deadline, 12.5, Txt, Medium)));
            if (sourceId is { } id)
            {
                var copy = TextLink(_copied ? "已复制" : "复制", () => Copy(id), 12, V3.Link, Regular);
                rows.Children.Add(Row("职位 ID", HStack(10, Number(id, 12.5, Txt, Medium), copy)));
            }
            action.Children.Add(new Border
            {
                Child = rows, Padding = new Thickness(0, 14, 0, 0), Margin = new Thickness(0, 6, 0, 0),
                BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 1, 0, 0),
            });
        }
        var side = VStack(16, Card(action, padding: new Thickness(20), border: V3.Line));
        if (_company is { } company) side.Children.Add(CompanyCard(company));
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

    static FrameworkElement StatusBlock(string text, bool check)
    {
        var color = check ? Hex(0x2E7D50) : Fnt;
        return new Border
        {
            Child = HStack(6, check ? Icon("checkmark", 11, color) : null, Sans(text, 14, color, Medium)).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            Height = 40, CornerRadius = new CornerRadius(8), Background = Brush(check ? GreenSoft : Field),
        };
    }

    static FrameworkElement Official(Uri url) => new Border
    {
        Child = HStack(6, Sans("去官网投递", 14, Txt, Medium), Icon("arrow.up.right.square", 11, Txt)).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        Height = 36, CornerRadius = Capsule(36), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
    }.OnTap(() => Launch(url), "去官网投递");

    static FrameworkElement Hint(string text, (string Title, Action Action)? link)
    {
        var stack = VStack(6, Sans(text, 12, Fnt).LineHeight(18).Wrap());
        if (link is { } item) stack.Children.Add(TextLink(item.Title, item.Action, 12, V3.Link));
        stack.Margin = new Thickness(0, 2, 0, 0);
        return stack;
    }

    static FrameworkElement Row(string label, FrameworkElement value)
    {
        var row = Columns(12, (Star(), Sans(label, 12.5, Fnt).Align(v: VerticalAlignment.Center)), (Auto, value.Align(v: VerticalAlignment.Center)));
        row.Height = 21;
        return row;
    }

    FrameworkElement CompanyCard(JsonNode company)
    {
        var today = company.Integer("today_new");
        var head = HStack(14, Logo(company.Text("name"), company.Text("logo_url"), 40),
            VStack(0, Sans(company.Text("name"), 15, Txt, Medium).Frame(height: 26), Sans(company.Text("industry"), 12, Fnt).Frame(height: 20)));
        var left = HStack(12, HStack(0, Number(Grouped(company.Integer("open_count")), 13, Txt), Sans(" 个在招", 12, Fnt)),
            today > 0 ? Sans($"今日 +{today}", 12, Blue) : null);
        var foot = Columns(12, (Star(), left.Align(v: VerticalAlignment.Center)),
            (Auto, TextLink("全部岗位 →", () => _openCompany(company.Text("id"), new PoolQuery()), 12, Txt).Align(v: VerticalAlignment.Center)));
        foot.Height = 22;
        var footer = new Border { Child = foot, Padding = new Thickness(0, 13, 0, 0), BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 1, 0, 0) };
        return Card(VStack(14, head, footer), padding: new Thickness(20), border: V3.Line);
    }

    FrameworkElement Related(JsonNode job, string companyId)
    {
        var category = job.Text("category");
        var same = _company.Items("categories").FirstOrDefault(x => x.Text("name") == category) is { } match && match.Get("count") is not null ? match.Integer("count") : (int?)null;
        var head = Columns(0, (Star(), Label("同方向岗位", 14, Txt, Semibold).Frame(height: 24)),
            (Auto, category.Length == 0 ? new Border() : TextLink($"全部{(same is { } n ? $" {n} 个" : "")} →", () => _openCompany(companyId, new PoolQuery(Category: category)), 12, Fnt, Regular)));
        head.Margin = new Thickness(0, 8, 0, 4);
        var stack = VStack(0, head);
        for (var i = 0; i < _related.Count; i++)
        {
            var item = _related[i];
            var meta = string.Join(" · ", new[] { Core.Models.JobPool.Cities(item).FirstOrDefault() ?? "", Core.Models.JobPool.Recruitment(item), Core.Models.JobPool.Relative(item.Text("published_at")) }.Where(x => x.Length > 0));
            var cell = new Border
            {
                Child = VStack(4, Sans(Title(item), 13.5, Txt).Frame(height: 23), Sans(meta, 12, Fnt).Frame(height: 20)),
                Padding = new Thickness(0, 13, 0, 12), Background = Brush(Clear),
                BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, i > 0 ? 1 : 0, 0, 0),
            };
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
