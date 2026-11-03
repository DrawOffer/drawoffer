using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using static DrawOffer.App.DesignSystem.V3;
using G = DrawOffer.Core.Models.ResumeGuideModel;
using S = DrawOffer.App.Views.Resumes.GuideJson;

namespace DrawOffer.App.Views.Resumes;

/// <summary>各步内容（Swift `ResumeGuidePanel` 的 `content` 与各 `xxxStep`）。</summary>
public sealed partial class ResumeGuidePanel
{
    FrameworkElement Body()
    {
        if (_guide.Text("status") == "completed")
            return StepView("wrap_up", "这份简历的引导已经完成", "之后直接在纸面上改就行。", content: Actions(primary: "关闭", onPrimary: _close));
        if (_welcome)
        {
            var counts = G.Welcome(_guide);
            var note = string.Join("　", new[] { counts.Done.Count == 0 ? "" : $"已写好：{string.Join("、", counts.Done)}", $"还差：{string.Join("、", counts.Left)}" }.Where(x => x.Length > 0));
            return StepView(Step, $"欢迎回来，还差 {counts.Left.Count} 步", note, content: [
                Actions(TextLink("结束引导，自己改", () => _ = Try(async () => { await ChangeAsync("dismiss"); _close(); })), "接着写", onPrimary: () => { _welcome = false; Render(); }),
                Sans("结束后，可以从右侧工具栏的「引导」重新打开。", 12, Fnt).Wrap().Top(20),
            ]);
        }
        if (_failure is { } failure)
        {
            var title = failure.Kind == "credit" ? "积分不够了" : failure.Kind == "invalid" ? "这次没写好" : "这次没整理出来";
            var note = failure.Kind == "credit" ? "简历没有改动，你填的内容都还在。充值后点重试，接着写。"
                : failure.Kind == "invalid" ? "写出来的不够具体，没有写上去，简历没有改动。可以回去多写一两句做了什么、用了什么，再试一次。"
                : "没连上或出错了，简历没有改动。你填的内容都还在，重试不用再填一遍。";
            var left = failure.Kind == "credit" ? TextLink("去充值", () => Shell.WorkspaceShell.Current.OpenPlans()) : TextLink("先跳过", () =>
            {
                _failure = null;
                if (Step == "experience") { _experience = G.NextExperience(_data, Materials, _unused); _phase = ListMode ? "list" : "form"; }
                else if (Step == "wrap_up") _wrapPhase = "main";
                else Next();
                Render();
            });
            return StepView(Step, title, note, content: Actions(left, "重试", onPrimary: failure.Retry));
        }
        return Step switch
        {
            "materials" => MaterialsStep(),
            "job_profile" => JobProfileStep(),
            "basics" => BasicsStep(),
            "education" => EducationStep(),
            "skills" => SkillsStep(),
            "experience" => ExperienceStep(),
            _ => WrapUpStep(),
        };
    }

    FrameworkElement LoadingStep(string step, string title, string text) => StepView(step, title, text, thinking: true);

    FrameworkElement JobProfileStep()
    {
        if (_jobIntent is not { } intent) return LoadingStep("job_profile", "你想投什么样的工作？", "正在读你的求职画像");
        var yearHint = intent.YearFromResume && _profile.Get("graduation_year").Number() is null ? "资料里读到" : null;
        var year = Field("2026", intent.GraduationYear, 4, _ => { }, label: "毕业年份", width: 56);
        year.TextChanged += (_, _) =>
        {
            // 只留数字、最多 4 位
            var digits = new string(year.Text.Where(char.IsDigit).Take(4).ToArray());
            if (digits != year.Text) { var caret = year.SelectionStart; year.Text = digits; year.SelectionStart = Math.Min(caret, digits.Length); }
            intent.GraduationYear = digits;
        };
        var rows = VStack(0,
            Row("岗位", Field("比如：后端开发", intent.Role, 60, v => intent.Role = v)),
            Row("城市", CityChips(intent.Cities, v => intent.Cities = v)),
            Row("类型", Choice("求职类型", intent.Type, [("campus", "校招"), ("internship", "实习"), ("any", "都可以")], v => { intent.Type = v; Render(); })),
            Row("毕业", HStack(4, year, Sans("届", 15, Fnt)), yearHint)).Top(24);
        return StepView("job_profile", "你想投什么样的工作？", "后面每一步都按它来写，也会记进求职画像。", back: Back, content: [rows,
            Actions(primary: "确认", disabled: () => _busy || S.Trimmed(intent.Role).Length == 0, onPrimary: () => _ = Try(async () =>
            {
                var ok = await WriteAsync("求职意向", async () =>
                {
                    await SaveProfileAsync(latest => G.JobIntentChanges(intent, latest));
                    await WriteOperationsAsync([new JsonObject { ["op"] = "set_identity", ["headline"] = G.JobIntentHeadline(intent) }]);
                });
                if (ok) { try { await ChangeAsync("confirm_profile"); } catch { _notice = "还差想投的岗位。"; Render(); } }
            }))]);
    }

    FrameworkElement BasicsStep()
    {
        if (_basicInfo is not { } info) return LoadingStep("basics", "简历上怎么称呼你、怎么联系你？", "正在读你的求职资料");
        var rows = VStack(0,
            Row("姓名", Field("真实姓名", info.Name, 60, v => info.Name = v)),
            Row("手机", Field("比如 138 0000 0000", info.Phone, 30, v => info.Phone = v)),
            Row("邮箱", Field("比如 name@example.com", info.Email, 120, v => info.Email = v)),
            Row("链接", Field("GitHub 或个人主页，选填", info.Link, 300, v => info.Link = v))).Top(24);
        return StepView("basics", "简历上怎么称呼你、怎么联系你？", "手机和邮箱至少留一个，也会记进求职资料。", back: Back, content: [rows,
            Actions(TextLink("先跳过", Skip, _busy), "确认", () => _busy || !G.BasicInfoReady(info), () => _ = Try(async () =>
            {
                var ok = await WriteAsync("基本信息", async () =>
                {
                    await WriteOperationsAsync(G.BasicInfoOperations(info));
                    try { await SaveCareerPersonalAsync(G.BasicInfoCareerChanges(info), overwrite: true); } catch { }
                });
                if (ok) Next();
            }))]);
    }

    FrameworkElement EducationStep()
    {
        if (_education is not { } form) return LoadingStep("education", "在哪里读书？", "正在读你的求职画像");
        var time = HStack(8,
            Field("2022.09", form.Start, 20, v => form.Start = v, "入学时间", 88), Sans("–", 15, Fnt),
            Field("2026.06", form.End, 20, v => form.End = v, "毕业时间", 88));
        var rows = VStack(0,
            Row("学校", Field("比如：浙江工业大学", form.School, 100, v => form.School = v)),
            Row("专业", Field("比如：软件工程", form.Major, 100, v => form.Major = v)),
            Row("学历", Choice("学历", form.Degree, G.Degrees.Select(d => (d, d)), v => { form.Degree = v; Render(); })),
            Row("时间", time)).Top(24);
        var optional = VStack(0,
            Row("GPA", Field("比如 3.6 / 4.0", form.Gpa, 40, v => form.Gpa = v)),
            Row("主修课程", Field("挑和岗位相关的几门", form.Courses, 200, v => form.Courses = v)));
        var note = Materials is not null && form.EntryID is null ? "资料里读到的已经填好，也会记进求职画像。" : "写进简历的教育经历，也会记进求职画像。";
        return StepView("education", "在哪里读书？", note, back: Back, content: [rows, Group("选填"), optional,
            Actions(TextLink("先跳过", Skip, _busy), "确认", () => _busy || !G.EducationReady(form), () => _ = Try(async () =>
            {
                var ok = await WriteAsync("教育", async () =>
                {
                    var format = G.EntryFormatOf([_data, _templateSample], ["education"]);
                    await WriteOperationsAsync(G.EducationOperations(form, format, G.SectionTitle([_templateSample], "education")));
                    try { await SaveProfileAsync(latest => G.EducationProfileChanges(latest, form)); } catch { }
                });
                if (ok) Next();
            }))]);
    }

    FrameworkElement SkillsStep()
    {
        var names = string.Join("、", (_skills ?? []).Select(s => s.Name));
        if (_skillPhase == "written")
        {
            var added = G.AddedPoints(_skillLines);
            var note = added.Count == 0 ? "按你选的程度分了方向。哪里不准，直接告诉我怎么改。"
                : added.Any(p => p.Weak) ? "按你选的程度分了方向。下面是按常考点补充的知识点，不会的点掉；带圆点的是面试里没答好的。"
                : "按你选的程度分了方向。下面是按常考点补充的知识点，不会的点掉。";
            FrameworkElement? chips = null;
            if (added.Count > 0)
            {
                var flow = new VariableSizedFlow(14);
                foreach (var point in added)
                {
                    var label = HStack(6, point.Weak ? Fill(Orange, 3, 6, 6) : null, Sans(point.Text, 14, Sub), Icon("xmark", 9, Sub));
                    var disabled = _busy || (_skillLines.Count == 1 && added.Count == 1);
                    var chip = Tap(label, () =>
                    {
                        var next = G.WithoutPoint(_skillLines, point.Line, point.Text);
                        if (next.Count == 0) return;
                        _ = Try(async () =>
                        {
                            var ok = await WriteAsync("专业技能", () => WriteOperationsAsync([new JsonObject
                            {
                                ["op"] = "replace_section", ["semantic_kind"] = "skills",
                                ["bullets"] = S.StringArray(next.Select(x => x.Text("text"))),
                            }]));
                            if (ok) { _skillLines = next; Render(); }
                        });
                    }, point.Weak ? $"去掉 {point.Text}（面试里没答好）" : $"去掉 {point.Text}", () => !disabled);
                    chip.Opacity = disabled ? 0.38 : 1;
                    if (point.Weak) ToolTipService.SetToolTip(chip, "面试里问到过，没答好");
                    flow.Add(chip);
                }
                chips = flow.Panel.Top(20);
            }
            return StepView("skills", "专业技能写好了", note, content: [chips,
                Underline("比如“去掉 Kafka，Redis 写深一点”，会整栏重写", () => _answer, v => _answer = v, _busy, WriteSkills),
                Meta(names, "改技能和程度", () => { _skillPhase = "form"; Render(); }),
                Actions(primary: G.NextLabel("skills"), disabled: () => _busy, onPrimary: Next)]);
        }
        if (_skillPhase == "working")
            return StepView("skills", "正在按方向写专业技能", "大约半分钟，写好前左边先不能改。", thinking: true, content: Sans(names, 13, Fnt).Wrap().Top(16));
        return _skills is null ? new Border() : SkillLevelsStep();
    }

    FrameworkElement ExperienceStep()
    {
        if (_experience is not { } form) return new Border();
        var written = _guide.Get("steps").Get("experience").Text("status") == "written";
        var pendingNext = ExperienceItems.FirstOrDefault(x => x.Status == "pending" && x.Form.Name != S.Trimmed(form.Name));
        var missing = _bullets.Select((b, i) => (b, i)).Where(x => x.b.Get("missing_result").Bool()).Select(x => (x.i + 1).ToString()).ToList();
        switch (_phase)
        {
            case "list": return ExperienceList();
            case "written":
                return StepView("experience", $"这段{form.KindLabel}写好了",
                    missing.Count == 0 ? "看看左边。哪里不满意，直接告诉我怎么改。" : $"第 {string.Join("、", missing)} 条还缺结果。说一句效果（比如快了多少、用的人有多少），我来补上。", content: [
                    Underline(missing.Count == 0 ? "比如“第 2 条突出 Kafka”" : "比如“接口从 1 秒降到 200 毫秒”", () => _answer, v => _answer = v, _busy, text => WriteExperience(form, text)),
                    Meta(form.Summary, "编辑", () => { _phase = "form"; Render(); }),
                    Actions(TextLink("＋ 再加一段", () =>
                    {
                        _opened = null;
                        _experience = ListMode ? new G.ExperienceForm() : G.NextExperience(_data, Materials, _unused);
                        _phase = "form";
                        Render();
                    }, _busy), pendingNext is not null ? $"写下一段：{pendingNext.Form.Name}" : ListMode ? "回到经历清单" : G.NextLabel("experience"), () => _busy, () =>
                    {
                        if (pendingNext is not null) { _opened = pendingNext; _experience = pendingNext.Form; _phase = "form"; Render(); }
                        else if (ListMode) { _phase = "list"; Render(); }
                        else Next();
                    })]);
            case "working":
                return StepView("experience", "正在按 STAR 写成要点", "大约半分钟，写好前左边先不能改。", thinking: true, content: Sans(form.Summary, 13, Fnt).Wrap().Top(16));
            default: return ExperienceForm(form, !written);
        }
    }

    FrameworkElement ExperienceList()
    {
        var items = ExperienceItems;
        var pending = items.Where(x => x.Status == "pending").ToList();
        int written = items.Count(x => x.Status == "written"), unusedCount = items.Count(x => x.Status == "unused");
        var title = pending.Count == 0 ? $"{items.Count} 段经历都处理好了" : written > 0 ? $"还有 {pending.Count} 段没写" : $"资料里有 {items.Count} 段经历";
        var note = pending.Count > 0 ? "一段一段写，写好左边马上更新。不放进这份简历的，点进去选“这段不用”。"
            : string.Join("，", new[] { $"{written} 段已写进左边", unusedCount > 0 ? $"{unusedCount} 段这份简历不用" : "" }.Where(x => x.Length > 0)) + "。点一段可以再改。";
        var list = new StackPanel { Margin = new Thickness(0, 24, 0, 0) };
        foreach (var item in items)
        {
            var name = Sans(item.Form.Name, 15, Txt, Medium);
            name.MaxLines = 1;
            var meta = Sans(item.Form.Meta, 13, Fnt);
            meta.MaxLines = 1;
            var trailing = Sans(item.Status == "unused" ? "不用" : item.Status == "pending" ? "待写" : "›", item.Status == "written" ? 17 : 13, item.Status == "written" ? Fnt2 : Fnt);
            var line = Spread(VStack(3, name, meta), trailing, 12);
            line.Padding = new Thickness(0, 14, 0, 14);
            var disabled = _busy || _running;
            var row = Tap(VStack(0, line, Divider(Cl)), () => OpenItem(item), item.Form.Name, () => !disabled);
            row.Opacity = disabled ? 0.38 : 1;
            list.Children.Add(row);
        }
        return StepView("experience", title, note, back: Back, content: [list,
            Actions(TextLink("＋ 再加一段", () => { _opened = null; _experience = new G.ExperienceForm(); _phase = "form"; Render(); }, _busy),
                pending.FirstOrDefault() is { } first ? $"写这段：{first.Form.Name}" : G.NextLabel("experience"), () => _busy, () =>
                {
                    if (pending.FirstOrDefault() is { } item) OpenItem(item);
                    else if (_guide.Get("steps").Get("experience").Text("status") == "written") Next();
                    else Skip();
                })]);
    }

    void OpenItem(G.ExperienceItem item)
    {
        if (item.Status == "unused") _unused.Remove(item.Form.Name);
        _opened = item;
        _experience = item.Form;
        _phase = "form";
        Render();
    }

    FrameworkElement ExperienceForm(G.ExperienceForm form, bool first)
    {
        var project = form.Kind == "project";
        var fromList = ListMode;
        var heading = fromList && _opened is not null && _opened.Form.EntryID is null ? _opened.Form.Name : null;
        var canUnuse = fromList && _opened is not null && _opened.Form.EntryID is null && form.EntryID is null;
        var title = form.EntryID is not null ? "改一改这段经历" : heading ?? (first ? "说说第一段经历" : "再说一段经历");
        var note = first && S.Trimmed(form.Name).Length == 0 && S.Trimmed(form.Did).Length == 0
            ? "从最近的一段开始，写大白话就行。没有实习也能写：课程设计、毕业设计、比赛、社团和志愿活动都算。"
            : "从最近的一段开始。写大白话就行，我来整理成要点。";
        Action? back = fromList ? () => { _phase = "list"; Render(); } : first ? Back : null;
        var time = HStack(8,
            Field("2025.07", form.Start, 20, v => form.Start = v, "开始时间", 88), Sans("–", 15, Fnt),
            Field("至今", form.End, 20, v => form.End = v, "结束时间", 88));
        var rows = VStack(0,
            Row("类型", Choice("经历类型", form.Kind, G.ExperienceKinds.Select(k => (k.Key, k.Label)), v => { form.Kind = v; Render(); })),
            Row(project ? "项目" : "单位", Field(project ? "项目名称" : "公司或组织名称", form.Name, 100, v => form.Name = v)),
            Row("角色", Field(project ? "比如：后端负责人" : "比如：后端开发实习生", form.Role, 100, v => form.Role = v)),
            Row("时间", time)).Top(24);
        var did = VStack(0,
            Area("比如：订单查询慢，我加了 Redis 缓存和分页，接口快了很多；还参与了压测。", form.Did, 2000, v => form.Did = v, "做了什么"),
            Row("效果", Field("选填，比如：接口从 1 秒降到 200 毫秒", form.Result, 500, v => form.Result = v)));
        UIElement? left = canUnuse
            ? TextLink("这段不用", () => { if (_opened?.Form.Name is { } name) _unused.Add(name); _opened = null; _phase = "list"; Render(); }, _busy)
            : fromList ? null : TextLink(first ? "跳过经历" : "不加了，下一步", () => { if (first) Skip(); else Next(); }, _busy);
        return StepView("experience", title, note, back: back, backLabel: fromList ? "经历清单" : "上一步", content: [rows, Group("做了什么"), did,
            Actions(left, "写进简历", () => _busy || !form.Ready, () => WriteExperience(form, null))]);
    }

    FrameworkElement WrapUpStep()
    {
        switch (_wrapPhase)
        {
            case "profile-working":
                return StepView("wrap_up", "正在按你已写的内容起草个人简介", "大约半分钟，写好前左边先不能改。", thinking: true);
            case "profile":
                return StepView("wrap_up", "个人简介写好了", "看看左边。哪里不准，直接告诉我怎么改。", content: [
                    Underline("比如“突出比赛获奖”“短一点”", () => _answer, v => _answer = v, _busy, WriteProfile),
                    Actions(primary: "好了", disabled: () => _busy, onPrimary: () => { _wrapPhase = "main"; Render(); })]);
            case "honors":
                if (_honors is not { } form) return new Border();
                return StepView("wrap_up", "证书与获奖", "一行一项，没有就空着。", back: () => { _wrapPhase = "main"; Render(); }, backLabel: "收尾", content: [
                    Group("证书"),
                    Area("比如：英语六级 560\n计算机二级", form.Certificates, 1200, v => form.Certificates = v, "证书"),
                    Group("获奖"),
                    Area("比如：2024 年校一等奖学金\n全国大学生数学建模竞赛省二等奖", form.Awards, 1200, v => form.Awards = v, "获奖"),
                    Actions(primary: "写进简历", disabled: () => _busy, onPrimary: () =>
                    {
                        var kinds = G.SectionKinds(_templateSample).Concat(G.SectionKinds(_data)).ToHashSet();
                        var operations = G.HonorsOperations(form, kinds);
                        if (operations.Count == 0) { _wrapPhase = "main"; Render(); return; }
                        _ = Try(async () => { if (await WriteAsync("证书与获奖", () => WriteOperationsAsync(operations))) { _wrapPhase = "main"; Render(); } });
                    })]);
            default:
                var samples = S.Arr(_guide.Get("samples"));
                var samplesLeft = samples.Count;
                var links = new StackPanel();
                links.Children.Add(LinkRow(G.ProfileWritten(_data, Samples) ? "重写个人简介" : "写个人简介", "按已写的内容起草 ›", () => WriteProfile(null), _busy));
                links.Children.Add(LinkRow("填证书与获奖", "六级、奖学金、比赛 ›", () =>
                {
                    _honors = G.HonorsFormOf(_data, Materials, _profile, Samples);
                    _wrapPhase = "honors";
                    Render();
                }, _busy));
                if (samplesLeft > 0)
                    links.Children.Add(LinkRow($"删掉剩下的 {samplesLeft} 处模板示例", "›", () => _ = Try(async () =>
                        await WriteAsync("模板示例", () => WriteOperationsAsync([new JsonObject
                        {
                            ["op"] = "remove_samples", ["node_ids"] = S.StringArray(samples.Select(x => x.Text("node_id"))),
                        }]))), _busy));
                links.Children.Add(LinkRow("导入一个想投的岗位，按岗位再调一遍", "›", () => Shell.WorkspaceShell.Current.Select(WorkspaceSection.Jobs)));
                links.Children.Add(LinkRow("导出 PDF", samplesLeft > 0 ? $"还有 {samplesLeft} 处示例没删 ›" : "›", _exportPdf));
                return StepView("wrap_up", "第一份简历写好了", "点“完成”后，技能和经历也会记进求职画像，下一份简历直接带出。", content: [
                    Group("还可以"), links,
                    Actions(primary: "完成", disabled: () => _busy, onPrimary: () => _ = FinishAsync())]);
        }
    }

    // MARK: 预填

    /// <summary>进入一步时按纸面、资料、画像预填一次（Web 同名 useEffect，Swift `prefill`）。</summary>
    void Prefill()
    {
        switch (Step)
        {
            case "job_profile" when _jobIntent is null && _profile is not null:
                _jobIntent = G.JobIntentOf(_profile, Materials ?? _data);
                break;
            case "basics" when _basicInfo is null && _careerReady:
                var own = G.BasicInfoOf(_data, G.Personal(_career), Samples);
                var read = G.BasicInfoOf(Materials, new Dictionary<string, string>(), new HashSet<string>());
                _basicInfo = new G.BasicInfo
                {
                    Name = own.Name.Length == 0 ? read.Name : own.Name, Phone = own.Phone.Length == 0 ? read.Phone : own.Phone,
                    Email = own.Email.Length == 0 ? read.Email : own.Email, Link = own.Link.Length == 0 ? read.Link : own.Link,
                };
                break;
            case "education" when _education is null && _profile is not null:
                _education = G.Education(_data, Materials, _profile, Samples);
                break;
            case "skills" when _skills is null:
                var onPaper = G.SkillsOnPaper(_data);
                var fromMaterials = G.SkillsOnPaper(Materials);
                var saved = _career.Get("experience").Get("skills").Items().Select(x => (Name: x.Text("name"), Level: x.Get("level").String())).ToList();
                var names = onPaper.Count > 0 ? onPaper : fromMaterials.Count > 0 ? fromMaterials : saved.Count > 0 ? saved
                    : S.Strings(_profile.Get("skills")).Select(x => (Name: x, Level: (string?)null)).ToList();
                var known = new Dictionary<string, string?>();
                foreach (var item in saved) known.TryAdd(item.Name.ToLowerInvariant(), item.Level);
                _skills = names.Select(x => (x.Name, x.Level ?? (known.TryGetValue(x.Name.ToLowerInvariant(), out var level) ? level : null) ?? "familiar")).ToList();
                break;
            case "experience" when _experience is null:
                _experience = G.NextExperience(_data, Materials, _unused);
                _phase = G.ExperienceList(_data, Materials, Samples, _unused).Count >= 2 ? "list" : "form";
                break;
        }
    }

    /// <summary>Swift `.onChange(of: step) { prefill() }`。</summary>
    void StepMaybeChanged()
    {
        if (Step == _lastStep) return;
        _lastStep = Step;
        Prefill();
    }
}
