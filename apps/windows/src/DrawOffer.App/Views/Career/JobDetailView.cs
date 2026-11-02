using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>
/// 岗位详情，对应 Mac `JobDetailView.swift`（Web `features/jobs/JobDetailPage.tsx` + `JobMatchCard.tsx`）：岗位信息、简历匹配度与 JD 覆盖、
/// 关联简历、个人备注、完整字段编辑与永久删除。分析只由用户触发；进行中每 3 秒轮询，最多 20 次。
/// </summary>
public sealed class JobDetailView : UserControl
{
    readonly string _jobId;
    /// <summary>打开详情的求职进程；用于关联简历与显示当前阶段。</summary>
    readonly JsonNode? _application;
    readonly Action _back;
    readonly Action _deleted;
    readonly StackPanel _page = new() { Spacing = 20, MaxWidth = 860, HorizontalAlignment = HorizontalAlignment.Stretch };

    JsonNode? _job, _app;
    bool _loading = true, _busy, _editingNotes, _matchLoading, _analyzing;
    string? _error, _notice, _matchError;
    List<ResumeSummary>? _resumes;
    JobMatch? _match;
    string _scope = "";
    TextBox? _notesBox;

    public JobDetailView(string jobId, JsonNode? application, Action back, Action deleted)
    {
        _jobId = jobId;
        _application = application;
        _back = back;
        _deleted = deleted;
        var host = new Border { Child = _page, Padding = new Thickness(52, 28, 52, 28) };
        Content = new ScrollViewer { Content = host, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Loaded += async (_, _) => await LoadAsync();
        Render();
    }

    JsonNode? Current => _app ?? _application;
    string ResumeId => Current.Text("resume_id");
    bool HasDescription => _job.Text("description").Trim().Length > 0;
    string MatchScope => $"{_jobId}|{ResumeId}|{HasDescription}";

    // MARK: 布局

    void Render()
    {
        _page.Children.Clear();
        _page.Children.Add(HStack(6, Icon("chevron.left", 11, CareerPalette.Sub), Sans("返回求职进度", 12.5, CareerPalette.Sub)).OnTap(_back, "返回求职进度"));
        if (_loading && _job is null)
        {
            var progress = VStack(8, new ProgressRing { IsActive = true, Width = 20, Height = 20 }, Sans("正在加载岗位详情…", 12, CareerPalette.Sub));
            progress.HorizontalAlignment = HorizontalAlignment.Center;
            progress.MinHeight = 200;
            progress.VerticalAlignment = VerticalAlignment.Center;
            _page.Children.Add(new Grid { MinHeight = 200, Children = { progress.Align(HorizontalAlignment.Center, VerticalAlignment.Center) } });
        }
        else if (_job is { } job) Body(job);
        else
        {
            var failed = VStack(10, Serif("无法打开这个岗位", 20).Align(HorizontalAlignment.Center),
                Sans(_error ?? "岗位服务暂时不可用，请稍后重试。", 13, CareerPalette.Sub).Align(HorizontalAlignment.Center),
                new CareerAction("重试", () => _ = LoadAsync()).Align(HorizontalAlignment.Center));
            _page.Children.Add(new Grid { MinHeight = 240, Children = { failed.Align(HorizontalAlignment.Center, VerticalAlignment.Center) } });
        }
    }

    void Body(JsonNode job)
    {
        _page.Children.Add(Header(job));
        if (_error is { } error) _page.Children.Add(Sans(error, 12.5, CareerPalette.Red).Wrap());
        if (_notice is { } notice) _page.Children.Add(Sans(notice, 12.5, CareerPalette.Sub).Wrap());
        _page.Children.Add(Columns(16, (Star(), MatchCard().Align(v: VerticalAlignment.Top)), (Px(276), NotesCard(job).Align(v: VerticalAlignment.Top))));
        _page.Children.Add(DescriptionCard(job));
        _page.Children.Add(CompanyCard(job));
    }

    FrameworkElement Header(JsonNode job)
    {
        var source = job.Text("source_type") == "external_import" ? "插件导入" : job.Text("source_type") == "manual" ? "手工创建" : "智能导入";
        var site = job.Text("source_site");
        var stage = Current?.Get("current_stage").Text("stage_label").NonEmpty() ?? Current?.Text("current_stage_label");
        var facts = new[]
        {
            job.Text("work_city"), Label(JobDescriptionFields.Employment, job.Text("employment_type")),
            job.Text("education_requirement"), job.Text("experience_requirement"), Label(JobDescriptionFields.WorkMode, job.Text("work_mode")),
        }.Where(x => x.Length > 0).ToList();
        var sourceRow = HStack(6, Icon(job.Text("source_type") == "external_import" ? "puzzlepiece.extension" : "doc.text", 11, CareerPalette.Sub),
            Sans(string.Join(" · ", new[] { source, site }.Where(x => x.Length > 0)) + " · 更新于 " + CareerFormat.MonthDay(job.Text("updated_at")), 12, CareerPalette.Sub));
        if (Uri.TryCreate(job.Text("source_url"), UriKind.Absolute, out var url) && url.Scheme is "http" or "https")
            sourceRow.Children.Add(Sans("打开来源", 12, Blue).OnTap(() => _ = Windows.System.Launcher.LaunchUriAsync(url), "打开来源"));
        var title = new TextBlock { Text = job.Text("job_title"), FontSize = 28, FontFamily = SerifFamily, Foreground = Brush(CareerPalette.Text), IsTextSelectionEnabled = true };
        var titleRow = HStack(10, title);
        if (stage is { Length: > 0 } && Current.Text("status") == "active") titleRow.Children.Add(CareerChipView.Make(stage, CareerTone.Blue).Align(v: VerticalAlignment.Center));
        var delete = new CareerAction("删除", ConfirmDelete, icon: "trash") { Enabled = !_busy };
        var edit = new CareerAction("编辑岗位", Edit, CareerAction.Kind.Primary, icon: "pencil") { Enabled = !_busy };
        var head = Columns(10, (Star(), titleRow), (Auto, HStack(10, delete, edit).Align(v: VerticalAlignment.Center)));
        var salary = HStack(8, Sans(job.Text("salary_text").NonEmptyOr("薪资未填写"), 15, CareerPalette.Text, Medium));
        if (facts.Count > 0) salary.Children.Add(Sans("· " + string.Join(" · ", facts), 13, CareerPalette.Sub).Align(v: VerticalAlignment.Center));
        return VStack(8, Sans($"JOBS · {job.Text("company_name")} · 岗位详情", 12, CareerPalette.Faint, Medium), sourceRow, head, salary);
    }

    FrameworkElement MatchCard()
    {
        UIElement picker;
        if (_resumes is { } resumes) picker = ResumePicker(resumes);
        else picker = new CareerAction(ResumeId.Length == 0 ? "选择关联简历" : "更换简历", () => _ = LoadResumesAsync()) { Enabled = _application is not null && !_busy };
        var stack = VStack(12, Columns(0, (Star(), Sans("简历匹配度", 15, CareerPalette.Text, Medium).Align(v: VerticalAlignment.Center)), (Auto, picker)));
        if (ResumeId.Length == 0)
        {
            stack.Children.Add(Serif("还没有关联简历", 18));
            stack.Children.Add(Sans(_application is null ? "从求职进程打开岗位详情后可关联简历。" : "选一份简历后，会对照 JD 算出匹配度，并告诉你还缺哪些经历。", 12.5, CareerPalette.Sub).Wrap());
        }
        else stack.Children.Add(MatchBody());
        return stack.CareerCard(padding: 20);
    }

    FrameworkElement MatchBody()
    {
        var ready = _match is { Ready: true } && !_analyzing ? _match : null;
        var failedCode = !_analyzing && _match?.Status == "failed" ? _match.ErrorCode : null;
        var failure = _matchError ?? (failedCode is not null ? JobMatch.ErrorMessage(failedCode) : null);
        string title; string? note;
        if (!HasDescription) { title = "补充岗位描述后可分析"; note = "有了岗位描述才能对照简历计算匹配度。"; }
        else if (_matchLoading) { title = "正在读取分析结果…"; note = null; }
        else if (_analyzing) { title = "正在分析…"; note = "正在对照岗位要求逐条检查这份简历，通常需要十几秒。"; }
        else if (failure is not null) { title = "分析没有完成"; note = failure; }
        else if (ready is not null) { title = ready.Headline is { } headline ? $"还缺：{headline}" : "已覆盖主要要求"; note = ready.Stale ? "简历或岗位描述已变化，这个分数可能已过期。" : null; }
        else { title = "还没有分析匹配度"; note = "点击下方按钮，对照岗位描述检查这份简历。"; }
        var score = VStack(2,
            Number(ready?.Score?.ToString() ?? "—", 40, CareerPalette.Text, Semibold).Align(HorizontalAlignment.Center),
            Sans("匹配度", 11, CareerPalette.Faint).Align(HorizontalAlignment.Center),
            new ProgressBar { Value = ready?.Score ?? 0, Maximum = 100, Width = 96, Height = 4, MinHeight = 4 }.Align(HorizontalAlignment.Center));
        var text = VStack(8,
            Sans($"基于「{Current.Text("resume_title_snapshot").NonEmptyOr("关联简历")}」", 12, CareerPalette.Faint),
            Serif(title, 18).Wrap());
        if (note is not null) text.Children.Add(Sans(note, 12.5, CareerPalette.Sub).Wrap());
        if (ready is not null)
        {
            if (ready.Hits.Count > 0) text.Children.Add(TagGroup($"已命中 · {ready.Hits.Count}", ready.Hits, CareerTone.Green));
            if (ready.Gaps.Count > 0) text.Children.Add(TagGroup($"待补充 · {ready.Gaps.Count}", ready.Gaps, CareerTone.Orange));
        }
        text.Children.Add(new CareerAction(_analyzing ? "分析中…" : ready is not null || failure is not null ? "重新分析" : "分析匹配度", () => _ = AnalyzeAsync(), icon: "wand.and.stars")
            { Enabled = HasDescription && !_matchLoading && !_analyzing }.Top(4));
        return Columns(20, (Px(120), score.Align(v: VerticalAlignment.Top)), (Star(), text));
    }

    static FrameworkElement TagGroup(string label, IReadOnlyList<string> words, CareerTone tone) =>
        VStack(6, Sans(label, 11.5, CareerPalette.Faint), FlowTags(words.Take(6).Concat(words.Count > 6 ? [$"等 {words.Count} 项"] : []), tone));

    /// <summary>`FlowTags`：自动换行的色块标签组（间距 6）。</summary>
    static FrameworkElement FlowTags(IEnumerable<string> words, CareerTone tone)
    {
        var flow = new VariableSizedFlow(6);
        foreach (var word in words) flow.Add(CareerChipView.Make(word, tone));
        return flow.Panel;
    }

    FrameworkElement ResumePicker(List<ResumeSummary> resumes)
    {
        var button = new CareerAction("选择简历", () => { }) { Enabled = !_busy };
        var flyout = new MenuFlyout();
        if (resumes.Count == 0) flyout.Items.Add(new MenuFlyoutItem { Text = "还没有简历，请先在“我的简历”创建", IsEnabled = false });
        foreach (var resume in resumes)
        {
            var item = new MenuFlyoutItem { Text = resume.Title + (resume.Id == ResumeId ? "（当前）" : ""), IsEnabled = resume.Id != ResumeId };
            var picked = resume;
            item.Click += (_, _) => _ = LinkResumeAsync(picked);
            flyout.Items.Add(item);
        }
        flyout.Items.Add(new MenuFlyoutSeparator());
        var cancel = new MenuFlyoutItem { Text = "取消" };
        cancel.Click += (_, _) => { _resumes = null; Render(); };
        flyout.Items.Add(cancel);
        button.Tapped += (_, _) => { if (!_busy) flyout.ShowAt(button); };
        return button;
    }

    FrameworkElement NotesCard(JsonNode job)
    {
        var head = Columns(0, (Star(), Sans("个人备注", 15, CareerPalette.Text, Medium)), (Auto, _editingNotes ? new Border() :
            Icon("pencil", 13, CareerPalette.Faint).OnTap(() => { if (_busy) return; _notesBox = null; _editingNotes = true; Render(); }, "编辑备注")));
        var stack = VStack(10, head);
        if (_editingNotes)
        {
            _notesBox ??= new TextBox
            {
                Text = job.Text("notes"), AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontSize = 13, FontFamily = SansFamily, MinHeight = 120,
                CornerRadius = new CornerRadius(8), BorderBrush = Brush(CareerPalette.Control), BorderThickness = new Thickness(1), Background = Brush(V3.White),
            };
            if (_notesBox.Parent is Panel parent) parent.Children.Remove(_notesBox);
            stack.Children.Add(_notesBox);
            var actions = HStack(0,
                new CareerAction("取消", () => { _editingNotes = false; Render(); }, CareerAction.Kind.Text) { Enabled = !_busy },
                new CareerAction(_busy ? "保存中…" : "保存", () => _ = SaveAsync(new Dictionary<string, string> { ["notes"] = _notesBox.Text }, () => _editingNotes = false), CareerAction.Kind.Primary) { Enabled = !_busy });
            actions.HorizontalAlignment = HorizontalAlignment.Right;
            stack.Children.Add(actions);
        }
        else
        {
            var notes = job.Text("notes");
            stack.Children.Add(new TextBlock
            {
                Text = notes.NonEmptyOr("未填写"), FontSize = 13, FontFamily = SansFamily, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
                Foreground = Brush(notes.Length == 0 ? CareerPalette.Faint : CareerPalette.Text),
            });
        }
        return stack.CareerCard(padding: 20);
    }

    FrameworkElement DescriptionCard(JsonNode job)
    {
        var skills = job.Items("skills").Select(x => x.String()).OfType<string>().ToList();
        var ready = _match is { Ready: true } && !_analyzing ? _match : null;
        var head = Columns(0, (Star(), Sans("岗位描述", 15, CareerPalette.Text, Medium)),
            (Auto, ready is not null && !(ready.Covered.Count == 0 && ready.Missing.Count == 0)
                ? Sans($"已覆盖 {ready.Covered.Count} · 待补充 {ready.Missing.Count}", 11.5, CareerPalette.Faint).Align(v: VerticalAlignment.Center) : new Border()));
        var stack = VStack(14, head);
        if (HasDescription)
        {
            stack.Children.Add(NativeMarkdownView.Render(job.Text("description")));
            if (ready is not null)
            {
                if (ready.Covered.Count > 0) stack.Children.Add(TagGroup("JD 中已覆盖", ready.Covered, CareerTone.Green));
                if (ready.Missing.Count > 0) stack.Children.Add(TagGroup("JD 中待补充", ready.Missing, CareerTone.Orange));
            }
            stack.Children.Add(VStack(6, Sans("核心技能", 11.5, CareerPalette.Faint),
                skills.Count == 0 ? Sans("未填写", 12.5, CareerPalette.Faint) : FlowTags(skills, CareerTone.Gray)));
            stack.Children.Add(HStack(24, Info("工作安排", job.Text("work_schedule")), Info("详细地址", job.Text("work_address"))));
        }
        else
        {
            var empty = VStack(10, Serif("岗位描述暂未记录", 18).Align(HorizontalAlignment.Center),
                Sans("粘贴招聘网站上的岗位文字。有了岗位描述才能计算简历匹配度。", 12.5, CareerPalette.Sub).Align(HorizontalAlignment.Center),
                new CareerAction("粘贴岗位文字", Edit, icon: "text.alignleft").Align(HorizontalAlignment.Center));
            empty.Padding = new Thickness(0, 20, 0, 20);
            stack.Children.Add(empty);
        }
        return stack.CareerCard(padding: 20);
    }

    FrameworkElement CompanyCard(JsonNode job)
    {
        var name = job.Text("company_name");
        var initial = name.Length == 0 ? "" : System.Globalization.StringInfo.GetNextTextElement(name);
        var identity = VStack(2, Sans(name, 14, CareerPalette.Text, Medium));
        if (job.Text("company_legal_name").Length > 0) identity.Children.Add(Sans(job.Text("company_legal_name"), 12, CareerPalette.Sub));
        var head = HStack(12, new Border
        {
            Width = 40, Height = 40, CornerRadius = new CornerRadius(10), Background = Brush(CareerPalette.Field),
            Child = Sans(initial, 16, CareerPalette.Text, Semibold).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        }, identity.Align(v: VerticalAlignment.Center));
        var stack = VStack(14, head, HStack(24,
            Info("行业", job.Text("company_industry")), Info("规模", job.Text("company_size")), Info("融资阶段", job.Text("company_financing_stage")),
            Info("招聘者", string.Join(" · ", new[] { job.Text("recruiter_name"), job.Text("recruiter_title") }.Where(x => x.Length > 0)))));
        if (job.Text("company_description").Length > 0)
            stack.Children.Add(new TextBlock
            {
                Text = job.Text("company_description"), FontSize = 13, FontFamily = SansFamily, Foreground = Brush(CareerPalette.Sub),
                TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
            });
        return stack.CareerCard(padding: 20);
    }

    static FrameworkElement Info(string label, string value) =>
        VStack(4, Sans(label, 11.5, CareerPalette.Faint), Sans(value.NonEmptyOr("未填写"), 13, value.Length == 0 ? CareerPalette.Faint : CareerPalette.Text));

    static string Label((string Value, string Label)[] options, string value) => options.FirstOrDefault(o => o.Value == value).Label ?? value;

    void Edit()
    {
        if (_job is not { } job || XamlRoot is null) return;
        JobFieldsSheet.Show(XamlRoot, job, updated => { _job = updated; _notice = "岗位信息已保存"; Render(); });
    }

    async void ConfirmDelete()
    {
        if (_busy || XamlRoot is null) return;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = "永久删除这个岗位？", CloseButtonText = "取消", PrimaryButtonText = "永久删除",
            Content = $"{_job.Text("job_title")} · {_job.Text("company_name")} · 删除后无法恢复。求职进程、阶段、复盘和面试排期会一起删除；关联资料的原文件仍保留在资料库。",
        };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            dialog.PrimaryButtonText = "正在删除…";
            dialog.IsPrimaryButtonEnabled = false;
            await DeleteAsync();
            deferral.Complete();
        };
        await dialog.ShowAsync();
    }

    // MARK: 操作

    async Task LoadAsync()
    {
        _loading = true; _error = null;
        Render();
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/job-descriptions/{_jobId}", "GET", [], null);
            _job = result.Get("job_description");
            if (_application.Text("id").NonEmpty() is { } id)
            {
                try
                {
                    var latest = await App.Session.Api.CareerRequestAsync($"/api/job-applications/{id}", "GET", [], null);
                    _app = latest.Get("application") ?? latest.Get("job_application") ?? _app;
                }
                catch (Exception) { }
            }
        }
        catch (Exception error)
        {
            if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) App.Session.ReportAuthenticationFailure();
            _error = JobDescriptionFields.ErrorMessage(error, "岗位服务暂时不可用，请稍后重试。");
        }
        _loading = false;
        Render();
        await RefreshMatchAsync();
    }

    /// <summary>Mac `.task(id: matchScope)`：岗位、关联简历或是否有描述变化时重新读取分析结果。</summary>
    async Task RefreshMatchAsync()
    {
        if (MatchScope == _scope) return;
        await LoadMatchAsync();
    }

    async Task LoadMatchAsync()
    {
        var scope = _scope = MatchScope;
        _match = null; _matchError = null; _analyzing = false;
        if (ResumeId.Length == 0 || !HasDescription) { Render(); return; }
        _matchLoading = true;
        Render();
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/job-descriptions/{_jobId}/match", "GET", new Dictionary<string, string> { ["resume_id"] = ResumeId }, null);
            if (scope != _scope) return;
            _match = JobMatch.From(result.Get("match"));
            if (_match?.Pending == true) { _matchLoading = false; await PollAsync(scope); }
        }
        catch (Exception) { if (scope == _scope) _matchError = JobMatch.ErrorMessage(null); }
        finally { if (scope == _scope) { _matchLoading = false; Render(); } }
    }

    async Task AnalyzeAsync()
    {
        if (ResumeId.Length == 0 || !HasDescription || _analyzing) return;
        var scope = _scope;
        _matchError = null; _analyzing = true;
        Render();
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/job-descriptions/{_jobId}/match:analyze", "POST", [], new JsonObject { ["resume_id"] = ResumeId });
            if (scope != _scope) return;
            _match = JobMatch.From(result.Get("match")); _analyzing = false;
            if (_match?.Pending == true) await PollAsync(scope);
        }
        catch (ApiException error) when (error.Code == "JOB_MATCH_IN_PROGRESS") { if (scope == _scope) await PollAsync(scope); return; }
        catch (Exception error)
        {
            if (scope != _scope) return;
            _analyzing = false;
            _matchError = JobMatch.ErrorMessage(error is ApiException api && api.Status != System.Net.HttpStatusCode.Unauthorized ? api.Code : null);
        }
        Render();
    }

    async Task PollAsync(string scope)
    {
        _analyzing = true;
        Render();
        try
        {
            for (var i = 0; i < JobMatch.PollLimit; i++)
            {
                await Task.Delay(JobMatch.PollInterval);
                if (scope != _scope || !IsLoaded) return;
                JsonNode result;
                try { result = await App.Session.Api.CareerRequestAsync($"/api/job-descriptions/{_jobId}/match", "GET", new Dictionary<string, string> { ["resume_id"] = ResumeId }, null); }
                catch (Exception) { return; }
                if (scope != _scope) return;
                _match = JobMatch.From(result.Get("match"));
                if (_match?.Pending != true) return;
            }
        }
        finally { if (scope == _scope) { _analyzing = false; Render(); } }
    }

    async Task LoadResumesAsync()
    {
        try
        {
            var page = await App.Session.Api.CareerRequestAsync("/api/resumes", "GET", [], null);
            _resumes = page.Items("resumes").Select(ResumeSummary.From).OfType<ResumeSummary>().ToList();
        }
        catch (Exception) { _notice = "简历列表加载失败，请稍后重试。"; }
        Render();
    }

    async Task LinkResumeAsync(ResumeSummary resume)
    {
        if (Current is not { } current || _busy) return;
        _busy = true;
        Render();
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/job-applications/{current.Text("id")}", "PUT", [],
                new JsonObject { ["resume_id"] = resume.Id, ["base_lock_version"] = (double)(current.Get("lock_version") is null ? 1 : current.Integer("lock_version")) });
            _app = result.Get("application") ?? result.Get("job_application");
            _resumes = null; _notice = $"已关联「{resume.Title}」";
            _busy = false;
            if (_app is null) { await LoadAsync(); return; }
        }
        catch (Exception error) { _notice = CareerErrors.Message(error).Replace("操作失败", "关联简历失败"); }
        _busy = false;
        Render();
        await RefreshMatchAsync();
    }

    async Task SaveAsync(Dictionary<string, string> changes, Action then)
    {
        if (_job is not { } job || _busy) return;
        _busy = true; _error = null;
        Render();
        try
        {
            var result = await App.Session.Api.CareerRequestAsync($"/api/job-descriptions/{_jobId}", "PUT", [], JobDescriptionFields.Payload(job, changes));
            _job = result.Get("job_description") ?? job;
            then();
        }
        catch (Exception error) { _error = JobDescriptionFields.ErrorMessage(error, "保存岗位失败，请稍后重试。"); }
        _busy = false;
        Render();
        await RefreshMatchAsync();
    }

    async Task DeleteAsync()
    {
        if (_busy) return;
        _busy = true; _error = null;
        try
        {
            await App.Session.Api.CareerRequestAsync($"/api/job-descriptions/{_jobId}", "DELETE", [], null);
            _busy = false;
            _deleted();
            return;
        }
        catch (Exception error) { _error = JobDescriptionFields.ErrorMessage(error, "删除岗位失败，请稍后重试。"); }
        _busy = false;
        Render();
    }
}
