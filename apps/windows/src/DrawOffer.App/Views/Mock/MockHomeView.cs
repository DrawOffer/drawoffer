using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Mock;

/// <summary>Mac MockHomeV2：掌握图、地平线和面试设置。</summary>
public sealed partial class MockHomeView : UserControl
{
    readonly Action<string> _open, _report;
    readonly Action _records, _resumes, _jobs, _library, _schedule;
    readonly PracticeFocus? _incoming;
    readonly MockViewLifetime _life;
    List<JsonNode> _list = [], _applications = [], _sessions = [], _resumesData = [], _datasets = [], _prices = [];
    JsonNode? _atlas, _outline, _match, _detail, _application;
    string? _chosen, _selected, _selectedSession, _focus, _targetRole, _remind;
    string _resume = "", _type = "comprehensive", _difficulty = "intermediate", _mode = "voice", _language = "zh", _error = "";
    bool _loaded, _speech, _busy, _unknownCreate, _typeTouched, _focusTouched, _resumeTouched, _follow = true, _materials = true;
    int _count = 8, _generation;
    readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromSeconds(5) };
    DateTimeOffset _now = Beijing.Now;
    MockMap.Target Target => MockMap.PickTarget(_applications, _sessions, _now, _chosen);
    double TargetLevel => MockMap.DiffLevel.GetValueOrDefault(_difficulty, 3);
    string TargetLabel => $"{MockMap.DiffName[_difficulty]}目标线 · 要答到「{MockMap.Levels[(int)TargetLevel - 1]}」";
    (List<MockMap.HomePoint> Points, List<MockMap.Sector> Sectors) Home => MockMap.HomePoints(_atlas, _outline, _match, _type);
    JsonNode? Active => _list.FirstOrDefault(x => x.Text("status") is "preparing" or "in_progress");
    JsonNode? Evaluating => _list.OrderByDescending(x => x.Text("created_at")).FirstOrDefault() is { } last && last.Text("status") is "evaluating" or "evaluation_failed" ? last : null;
    JsonNode? Blocking => Active ?? Evaluating;
    bool Fresh => _loaded && !_list.Any(x => x.Text("status") == "completed") && _atlas.Items("nodes").Count == 0 && Target.Kind == MockMap.TargetKind.General && _chosen != "general";
    public MockHomeView(PracticeFocus? focus, Action<string> open, Action<string> report, Action records, Action resumes, Action jobs, Action library, Action schedule)
    {
        (_incoming, _open, _report, _records, _resumes, _jobs, _library, _schedule) = (focus, open, report, records, resumes, jobs, library, schedule);
        _life = new(this, () => Content = null);
        Loaded += async (_, _) => await Load(); Unloaded += (_, _) => _poll.Stop();
        _poll.Tick += async (_, _) => { _poll.Stop(); await Load(); };
        Render();
    }
    Task<JsonNode> Request(string path, string method = "GET", JsonNode? body = null, Dictionary<string,string>? query = null) => _life.Request(path, method, body, query);
    async Task<JsonNode?> Optional(string path, Dictionary<string,string>? query = null)
    {
        try { return await Request(path, query: query); } catch (OperationCanceledException) { throw; } catch { return null; }
    }
    async Task Load()
    {
        var generation = ++_generation;
        try
        {
            var list = Request("/api/mock-interviews", query: new() { ["limit"] = "100" });
            var apps = Optional("/api/job-applications", new() { ["scope"] = "active", ["limit"] = "200" });
            var sessions = Optional("/api/interview-sessions", new() { ["status"] = "scheduled", ["start_at"] = DateTimeOffset.UtcNow.AddHours(-6).ToString("O"), ["limit"] = "500" });
            var resumes = Optional("/api/resumes"); var atlas = Optional("/api/memory/atlas"); var datasets = Optional("/api/datasets");
            var speech = Optional("/api/mock-interviews/speech-capability"); var profile = Optional("/api/account/user-profile"); var prices = Optional("/api/billing/feature-prices");
            await Task.WhenAll(new Task[] { list, apps, sessions, resumes, atlas, datasets, speech, profile, prices });
            if (!_life.Alive || generation != _generation) return;
            _list = list.Result.Items("items"); _applications = apps.Result.Items("items"); _sessions = sessions.Result.Items("items");
            _resumesData = resumes.Result.Items("resumes"); _atlas = atlas.Result; _datasets = datasets.Result.Items("datasets"); _prices = prices.Result.Items("items");
            _speech = speech.Result.Get("stt").Bool() && speech.Result.Get("tts").Bool(); if (!_loaded && !_speech) _mode = "text";
            _targetRole = profile.Result.Get("profile").Text("target_role").NonEmpty() ?? profile.Result.Text("target_role").NonEmpty();
            _loaded = true; _now = Beijing.Now; ApplyDefaults();
            await LoadTarget(generation);
            if (_unknownCreate) _unknownCreate = false;
            if (_remind is { } id && _list.Any(x => x.Text("id") == id && x.Text("status") == "completed")) { _error = "评估报告好了，这场报告已经生成。"; _remind = null; }
        }
        catch (OperationCanceledException) { return; }
        catch (Exception e) { if (_life.Alive) _error = MockReportData.Error(e); }
        if (!_life.Alive || generation != _generation) return;
        Render(); if (Evaluating?.Text("status") == "evaluating") _poll.Start();
    }
    async Task LoadTarget(int generation)
    {
        var target = Target; var app = target.Application?.Display("id"); var job = target.Kind == MockMap.TargetKind.General ? "" : target.Application.Display("job_description_id");
        var application = string.IsNullOrEmpty(app) ? Task.FromResult<JsonNode?>(null) : Optional($"/api/job-applications/{app}");
        var outline = Optional("/api/memory/outline", job.Length > 0 ? new() { ["job_id"] = job } : null);
        var match = job.Length > 0 && _resume.Length > 0 ? Optional("/api/memory/match-evidence", new() { ["job_id"] = job, ["resume_id"] = _resume }) : Task.FromResult<JsonNode?>(null);
        var id = _selectedSession ?? Blocking?.Text("id");
        var detail = id is null ? Task.FromResult<JsonNode?>(null) : Optional($"/api/mock-interviews/{id}");
        await Task.WhenAll(application, outline, match, detail);
        if (!_life.Alive || generation != _generation) return;
        _application = application.Result.Get("application"); _outline = outline.Result; _match = match.Result; _detail = detail.Result.Get("mock_interview"); ApplyDefaults();
    }
    void ApplyDefaults()
    {
        var linked = Target.Application.Display("resume_id");
        if (!_resumeTouched && linked.Length > 0 && _resumesData.Any(x => x.Display("id") == linked)) _resume = linked;
        else if (!_resumesData.Any(x => x.Display("id") == _resume)) _resume = _resumesData.OrderByDescending(x => x.Text("updated_at")).FirstOrDefault().Display("id");
        if (!_typeTouched) _type = (Target.Session.Text("stage_label").NonEmpty() ?? Target.Application.Text("current_stage_label")).Trim().StartsWith("HR", StringComparison.OrdinalIgnoreCase) ? "hr" : "comprehensive";
        if (_focusTouched) return;
        _focus = _incoming is { } incoming ? Home.Points.FirstOrDefault(x => x.Focus is { } f && (f.Ref == incoming.Ref || x.Point.Name == incoming.Label || f.Label == incoming.Label))?.Point.Id
            : Fresh ? null : MockMap.SuggestFocus(Home.Points, TargetLevel)?.Point.Id;
    }
    async Task ChangeTarget(string id)
    {
        _chosen = id; _selected = _selectedSession = null; _focusTouched = _resumeTouched = false; ApplyDefaults(); var generation = ++_generation;
        try { await LoadTarget(generation); if (_life.Alive && generation == _generation) Render(); } catch (OperationCanceledException) { }
    }
    void Render()
    {
        var canvas = new Canvas { Width = 1151, Height = 828, Background = Brush(White) };
        if (!_loaded && _error.Length > 0)
        {
            MockCanvas.Put(canvas, VStack(12, Serif("模拟面试没有加载出来", 18), Sans(_error, 13, Sub).Wrap(), new V3Button("重新加载", () => _ = Load())), 430, 310);
            Content = MockCanvas.Stage(canvas); return;
        }
        var (points, sectors) = Home;
        var mapPoints = points.Select(p => p.Point).ToList();
        var slots = _detail is null ? null : MockLayout.SlotsOf(_detail, mapPoints);
        var map = new MockMasteryMap(1151, 828, MockLayout.Home.At, slots?.Points ?? mapPoints, slots?.Sectors ?? sectors, TargetLevel, TargetLabel, id => { _selected = _selected == id ? null : id; _selectedSession = null; Render(); })
        { Selected = _selected, Focus = slots is null ? _focus : null, PathSteps = slots?.Path, Center = Target.Kind == MockMap.TargetKind.General ? "只按简历" : Fresh ? "先练一场" : MockMap.CompanyName(Target) };
        var subs = MockMap.PointSubs(points, TargetLevel, _focus);
        map.LabelLayout = slots is null ? MockLayout.HomeMap(MockMap.Place(MockLayout.Home.At, mapPoints), sectors, TargetLevel, TargetLabel, subs.ToDictionary(x => x.Key, x => x.Value.Text), new[] { _selected, _focus }.OfType<string>().ToList(), true) : MockLayout.HomeSession(slots, TargetLevel, TargetLabel);
        map.Bounds = slots?.Bounds; map.LabelOnly = slots?.Path.Select(x => x.Id).ToList();
        map.Subs = slots is null ? subs : new Dictionary<string, (string, MockMap.SubTone)>();
        map.Dim = _type == "project_deep_dive" ? sectors.Where(x => x.Name != MockMap.ProjectSector).Select(x => x.Name).ToList() : _type == "hr" ? sectors.Where(x => x.Name != MockMap.ExpressSector).Select(x => x.Name).ToList() : [];
        if (Blocking is null) { var x = MockMap.SlotXs(_count)[0]; map.DropTarget = (x, MockMap.ArcY(1151, MockMap.HomeHorizonTop)(x)); map.DropFocus = id => { if (points.FirstOrDefault(p => p.Point.Id == id)?.Focus is null) return; _focusTouched = true; _focus = id; Render(); }; }
        canvas.Children.Add(map);
        MockCanvas.Put(canvas, Panel(points), 56, 28);
        var top = HStack(18);
        if (_loaded && Active is null) top.Children.Add(new V3Button(Fresh ? "选岗位 ⌄" : "换一场 ⌄", ShowJobs, V3Button.Kind.Text, small: true));
        if (!Fresh) top.Children.Add(new V3Button("全部练习记录 ›", _records, V3Button.Kind.Text, small: true));
        top.Children.Add(new V3Button("图例 ⓘ", ShowLegend, V3Button.Kind.Text, small: true)); top.Measure(new Windows.Foundation.Size(double.PositiveInfinity, 40));
        MockCanvas.Put(canvas, top, 1126 - top.DesiredSize.Width, 24);
        DrawHorizon(canvas);
        FrameworkElement composer;
        if (Active is { } active) composer = HStack(14, Serif($"上次没答完 · {active.Text("company_name").NonEmpty() ?? "通用练习"} {MockMap.TypeName(active)}", 16, Sub), new V3Button("继续 →", () => _open(active.Text("id")), V3Button.Kind.Dark, 40), new V3Button("放弃", () => Abandon(active.Text("id")), V3Button.Kind.Text));
        else composer = HStack(12, new V3Button("面试设置", ShowSettings, height: 40), new V3Button(_busy ? "正在准备…" : Fresh ? "开始第一场 →" : "开始练习 →", () => _ = Start(), V3Button.Kind.Dark, 40) { Enabled = _loaded && !_busy && Blocking is null && !_unknownCreate });
        composer.Measure(new Windows.Foundation.Size(double.PositiveInfinity, 50)); MockCanvas.Put(canvas, composer, (1151 - composer.DesiredSize.Width) / 2, 760);
        var note = !_loaded ? "正在加载模拟面试…" : Active is not null ? "同一时间只能进行一场 · 放弃后这场不生成报告" : Evaluating is not null ? "上一场评估完成或放弃后才能开始新的一场" : "";
        MockCanvas.Text(canvas, note, 575.5, 806, 10.5, Fnt, true);
        if (_error.Length > 0) MockCanvas.Put(canvas, VStack(4, Sans(_error, 12, Orange).Wrap(), new V3Button(_unknownCreate ? "刷新确认创建结果" : "关闭提示", () => { _error = ""; if (_unknownCreate) _ = Load(); else Render(); }, V3Button.Kind.Text, small: true)).Frame(width: 330), 797, 700);
        if (_settingsOpen && Blocking is null)
        {
            var settings = SettingsPanel(); settings.Measure(new Windows.Foundation.Size(360, double.PositiveInfinity));
            MockCanvas.Put(canvas, settings, (1151 - 360) / 2d, 744 - settings.DesiredSize.Height);
        }
        Content = MockCanvas.Stage(canvas);
    }
    FrameworkElement Panel(List<MockMap.HomePoint> points)
    {
        var body = VStack(8); body.Width = 295;
        void Text(string text, double size = 13) => body.Children.Add(Sans(text, size, Sub).Wrap().LineHeight(size + 8));
        if (_selected is { } id && points.FirstOrDefault(x => x.Point.Id == id) is { } point)
        {
            Text(point.Source == "hook" ? "简历说法" : point.Source == "job" ? "岗位要求" : "知识点", 11); body.Children.Add(Serif(point.Point.Name, 28).Wrap());
            Text($"{point.Point.Sector} · 被问概率 {(point.Point.Ask >= 3 ? "高" : point.Point.Ask == 2 ? "中" : "低")}");
            Text(point.Point.Level == 0 ? "还没被问过" : $"只答到「{MockMap.LevelName(point.Point.Level)}」");
            foreach (var follow in point.FollowUps.Take(2)) Text($"接下来可能被追问「{follow}」");
            if (point.Focus is not null) body.Children.Add(new V3Button(_focus == id ? "已设为先问 ✓" : "设为先问", () => { _focusTouched = true; _focus = _focus == id ? null : id; Render(); }));
            var last = point.Node.Items("asks").LastOrDefault(x => x.Text("kind") == "mock");
            if (last is not null) body.Children.Add(new V3Button($"看 {MockMap.MmddDot(last.Text("date"))} 那道题 ›", () => _report(last.Text("source_id")), V3Button.Kind.Text));
        }
        else if (_detail is not null && _selectedSession is not null)
        {
            Text("一场练习", 11); body.Children.Add(Serif($"{MockMap.MmddDot(_detail.Text("created_at"))} {MockMap.TypeName(_detail)}", 27).Wrap());
            Text(MockReportData.Settings(_detail)); Text(_detail.Text("status") == "completed" ? $"{_detail.Number("total_score"):0} 分" : "还没有分数", 16);
            Text(_detail.Get("report").Text("headline")); body.Children.Add(new V3Button("看评估报告 ›", () => _report(_detail.Text("id"))));
            body.Children.Add(new V3Button("用同样设置再练", () => _ = Repeat(_detail.Text("id")), V3Button.Kind.Text));
        }
        else if (Evaluating is { } evaluating)
        {
            Text("刚练完", 11); body.Children.Add(Serif(MockMap.TypeName(evaluating), 30));
            if (evaluating.Text("status") == "evaluation_failed") { Text("评估报告没能生成", 15); Text("作答记录都还在，重新评估不另扣积分"); body.Children.Add(new V3Button("重新评估", () => _ = Retry(evaluating.Text("id")), V3Button.Kind.Dark)); body.Children.Add(new V3Button("放弃这场", () => Abandon(evaluating.Text("id")), V3Button.Kind.Text)); }
            else { Text("报告生成中，约 1 分钟", 15); Text("可以先离开，好了会提醒你"); body.Children.Add(new V3Button(_remind is null ? "好了提醒我" : "好了会提醒你 ✓", () => { _remind = evaluating.Text("id"); Render(); })); }
        }
        else
        {
            Text(Fresh ? "还没练过" : Target.Kind == MockMap.TargetKind.General ? "通用练习" : Target.Session is null ? "在投岗位" : "下一场", 11);
            body.Children.Add(Serif(Fresh ? "先练一场" : Target.Kind == MockMap.TargetKind.General ? "不挑岗位" : MockMap.CompanyName(Target), 32).Wrap());
            Text(Target.Kind == MockMap.TargetKind.General ? "只按简历出题" : Target.Application.Text("job_title_snapshot"), 14);
            foreach (var stage in MockMap.StageChain(_application ?? Target.Application, Target.Session, _now)) Text((stage.Check ? "✓ " : "") + stage.Label, 12);
            if (Active is not null) Text($"这场还没答完，继续后从第 {Math.Max(1, _detail.Integer("answered_main_questions"))} 题开始");
            else if (Fresh) { Text("面试官按你的简历出题。练完以后，每个知识点会落到它答到的那一圈。"); Text("外圈虚线 = 简历里写了、还没被问过", 12); }
            else { var missing = points.Count(p => p.Point.Level > 0 && p.Point.Level < TargetLevel); Text($"{MockMap.DiffName[_difficulty]}要答到「{MockMap.LevelName(TargetLevel)}」，还有 {missing} 个点没到"); Text("圈越往里答得越深，点越大越可能被问", 12); }
        }
        return body;
    }
    void DrawHorizon(Canvas canvas)
    {
        var horizon = MockMap.HorizonOf(_list, Target, _difficulty, _now); var arc = MockMap.ArcY(1151, MockMap.HomeHorizonTop);
        var ground = new Microsoft.UI.Xaml.Shapes.Polygon { Fill = Brush(Hex(0xEFEDE7)), IsHitTestVisible = false };
        for (var i = 0; i <= 240; i++) { var x = 1151d * i / 240; ground.Points.Add(new(x, arc(x))); }
        ground.Points.Add(new(1151, 828)); ground.Points.Add(new(0, 828)); canvas.Children.Add(ground);
        foreach (var offset in new[] { 0, 7, 18, 32 })
            for (var i = 0; i < 240; i++) { var x = 1151d * i / 240; var next = 1151d * (i + 1) / 240; MockCanvas.Line(canvas, x, arc(x) + offset, next, arc(next) + offset, offset == 0 ? Txt : Alpha(Hex(0xCFCABD), offset < 18 ? 1 : offset == 18 ? .75 : .57), offset == 0 ? 1.3 : offset == 7 ? 1 : .8); }
        for (var x = 16; x < 1141; x += 13) MockCanvas.Line(canvas, x, arc(x), x, arc(x) - ((x - 16) / 13 % 5 == 0 ? 6 : 3), Hex(0xA9A59A), .7);
        Border? hoverCard = null;
        void ShowCard(MockMap.HorizonSession session, double y)
        {
            if (hoverCard is not null) canvas.Children.Remove(hoverCard);
            var body = VStack(6, Sans(session.Title, 11.5, Txt, Bold));
            if (session.Score is { } score) body.Children.Add(HStack(6, Number(score.ToString(), 24), Sans("分" + (session.Delta is { } delta ? $" · 比上一场同岗位 {(delta >= 0 ? "+" : "")}{delta}" : ""), 11, Sub)));
            body.Children.Add(Sans(session.Detail, 11, Sub));
            if (session.Score is not null) body.Children.Add(new V3Button("查看这场报告 ›", () => _report(session.Id), V3Button.Kind.Text, small: true));
            hoverCard = Card(body, 10, new Thickness(14, 12, 14, 12), White, Hex(0xE6E3DC));
            hoverCard.Measure(new Windows.Foundation.Size(300, double.PositiveInfinity));
            MockCanvas.Put(canvas, hoverCard, Math.Clamp(session.X + 24, 8, 1143 - hoverCard.DesiredSize.Width), Math.Max(8, y - 23 - hoverCard.DesiredSize.Height));
            hoverCard.PointerExited += (_, _) => { if (_selectedSession != session.Id && hoverCard is not null) canvas.Children.Remove(hoverCard); };
        }
        foreach (var session in horizon.Sessions)
        {
            var y = session.Score is { } score ? MockMap.HomeScoreY(arc, session.X, score) : arc(session.X) - 22;
            var latest = horizon.Sessions.LastOrDefault(s => s.Score is not null)?.Id == session.Id;
            MockCanvas.Line(canvas, session.X, y, session.X, arc(session.X), Alpha(session.Mine ? Txt : Fnt, .7), 1, session.Score is null);
            MockCanvas.Circle(canvas, session.X, y, session.Score is null ? 9 : 13, session.Mine ? Txt : Fnt, latest ? Txt : White, session.Score is null);
            MockCanvas.Text(canvas, session.Score?.ToString() ?? "—", session.X, y - 8.5, 11.5, latest ? White : Txt, true);
            MockCanvas.Text(canvas, session.Date, session.X, arc(session.X) + 9, 9.5, session.Mine ? Sub : Fnt, true);
            var b = new Button { Width = 30, Height = 30, Background = Brush(Clear), BorderThickness = new Thickness(0) }.Tip($"{session.Title} · {session.Score?.ToString() ?? "放弃"} · {session.Detail}");
            b.Click += async (_, _) => { _selectedSession = session.Id; _selected = null; try { await LoadTarget(++_generation); if (_life.Alive) Render(); } catch (OperationCanceledException) { } };
            b.PointerEntered += (_, _) => ShowCard(session, y);
            MockCanvas.Put(canvas, b, session.X - 15, y - 15);
        }
        MockCanvas.Line(canvas, horizon.Today, arc(horizon.Today), horizon.Today, arc(horizon.Today) - 16, Txt);
        MockCanvas.Text(canvas, Evaluating is null ? $"今天 {MockMap.MmddDot(_now)}" : Evaluating.Text("status") == "evaluation_failed" ? "今天 · 评估没完成" : "今天 · 报告生成中", horizon.Today, arc(horizon.Today) - 34, 10.5, Txt, true);
        if (Blocking is not null)
        {
            var color = Active is not null ? Blue : Orange; MockCanvas.Circle(canvas, horizon.Today, arc(horizon.Today), 16, Clear, Alpha(color, .12)); MockCanvas.Circle(canvas, horizon.Today, arc(horizon.Today), 7, color, color);
        }
        else
        {
            var xs = MockMap.SlotXs(_count); foreach (var x in xs) MockCanvas.Circle(canvas, x, arc(x), 8, x == xs[0] ? Txt : Hex(0xA9A59A), White, Fresh);
            if (_focus is { } focus && MockMap.Place(MockLayout.Home.At, Home.Points.Select(x => x.Point)).FirstOrDefault(x => x.Point.Id == focus) is { } placed)
            {
                MockCanvas.Circle(canvas, xs[0], arc(xs[0]), 8.5, Orange, White); MockCanvas.Circle(canvas, xs[0], arc(xs[0]), 3.4, Orange, Orange);
                var figure = new Microsoft.UI.Xaml.Media.PathFigure { StartPoint = new(placed.X, placed.Y) };
                figure.Segments.Add(new Microsoft.UI.Xaml.Media.BezierSegment { Point1 = new(placed.X, placed.Y + 140), Point2 = new(xs[0], arc(xs[0]) - 160), Point3 = new(xs[0], arc(xs[0]) - 10) });
                var geometry = new Microsoft.UI.Xaml.Media.PathGeometry(); geometry.Figures.Add(figure);
                canvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Stroke = Brush(Alpha(Orange, .65)), StrokeThickness = 1, StrokeDashArray = new Microsoft.UI.Xaml.Media.DoubleCollection { 4, 4 }, IsHitTestVisible = false });
            }
            var middle = (xs[0] + xs[^1]) / 2; MockCanvas.Text(canvas, $"这一场 · {_count} 题 · 约 {_count * 5} 分钟", middle, arc(middle) + 14, 10.5, Sub, true);
        }
        foreach (var day in horizon.Days) { MockCanvas.Line(canvas, day.X, arc(day.X), day.X, arc(day.X) - 12, Alpha(Txt, .6)); MockCanvas.Text(canvas, day.Label, day.X, arc(day.X) + 12, 10, Fnt, true); }
        MockCanvas.Text(canvas, horizon.Past.Title, 40, 760, 14, Txt);
        if (horizon.Past.Sub is not null) MockCanvas.Text(canvas, horizon.Past.Sub, 40, 784, 10.5, Fnt);
        if (horizon.Interview is { } interview)
        {
            var panel = VStack(4, Serif(interview.Title, 14), new V3Button((interview.Sub is null ? "" : interview.Sub + " · ") + "面试日程 ›", _schedule, V3Button.Kind.Text, small: true));
            panel.HorizontalAlignment = HorizontalAlignment.Right; panel.Width = 300;
            MockCanvas.Put(canvas, panel, 811, 760);
        }
    }
    async Task Start()
    {
        if (_busy || Blocking is not null || _unknownCreate) return;
        if (_resume.Length == 0) { _error = "还没有简历，先导入或新建一份简历。"; Render(); return; }
        _busy = true; Render();
        var target = Target;
        var body = new JsonObject { ["resume_id"] = _resume, ["interview_type"] = _type, ["difficulty"] = _difficulty, ["question_count"] = _count, ["follow_up_enabled"] = _follow, ["language"] = _language, ["answer_mode"] = _mode };
        if (target.Kind != MockMap.TargetKind.General) body["job_application_id"] = target.Application.Display("id"); else if (_targetRole is not null) body["target_role"] = _targetRole;
        if (_materials) body["material_ids"] = new JsonArray(LibraryDocs.Take(10).Select(x => JsonValue.Create(x.Display("id"))).Cast<JsonNode?>().ToArray());
        if (Home.Points.FirstOrDefault(x => x.Point.Id == _focus)?.Focus is { } focus) { var json = focus.Json; json["origin"] = _incoming?.Ref == focus.Ref ? "outline" : "settings"; body["practice_focus"] = json; }
        body["display"] = new JsonObject { ["resume_title"] = _resumesData.FirstOrDefault(x => x.Display("id") == _resume).Text("title"), ["company_name"] = target.Application.Text("company_name_snapshot"), ["job_title"] = target.Application.Text("job_title_snapshot"), ["stage_label"] = target.Session.Text("stage_label").NonEmpty() ?? target.Application.Text("current_stage_label") };
        try { var result = await Request("/api/mock-interviews", "POST", body); var id = result.Get("mock_interview").Text("id"); if (id.Length == 0) throw new InvalidOperationException(); _open(id); }
        catch (OperationCanceledException) { }
        catch (Exception e) { if (_life.Alive) { _unknownCreate = true; _error = MockReportData.Error(e) + "请刷新确认是否已创建，再开始新的一场。"; } }
        finally { _busy = false; if (_life.Alive) Render(); }
    }
    List<JsonNode> LibraryDocs => _datasets.Where(x => (x.Text("asset_kind").NonEmpty() ?? "document") == "document" && x.Text("upload_status") == "succeeded" && x.Text("parse_status") == "succeeded").ToList();
    async Task Repeat(string id) { if (_busy) return; _busy = true; try { var result = await Request($"/api/mock-interviews/{id}/repeat", "POST"); _open(result.Get("mock_interview").Text("id")); } catch (OperationCanceledException) { } catch (Exception e) { if (_life.Alive) { _unknownCreate = true; _error = MockReportData.Error(e); } } finally { _busy = false; if (_life.Alive) Render(); } }
    async Task Retry(string id) { if (_busy) return; _busy = true; try { await Request($"/api/mock-interviews/{id}/retry", "POST"); await Load(); } catch (OperationCanceledException) { } catch (Exception e) { if (_life.Alive) _error = MockReportData.Error(e); } finally { _busy = false; if (_life.Alive) Render(); } }
    void Abandon(string id) => V3Overlay.Show(XamlRoot, close => V3Dialog.Make(VStack(12, V3DialogHead.Make("放弃这场练习？", "放弃后这场不生成报告。")), [new V3Button("取消", close), new V3Button("确认放弃", async () => { close(); if (_busy) return; _busy = true; try { await Request($"/api/mock-interviews/{id}/abandon", "POST"); await Load(); } catch (OperationCanceledException) { } catch (Exception e) { if (_life.Alive) _error = MockReportData.Error(e); } finally { _busy = false; if (_life.Alive) Render(); } }, V3Button.Kind.Danger)], close));
}
