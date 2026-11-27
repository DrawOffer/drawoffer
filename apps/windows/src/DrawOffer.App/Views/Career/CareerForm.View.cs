using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>`CareerForm.body`：标题区、左侧摘要、右侧表单与页脚。</summary>
public sealed partial class CareerForm
{
    bool Locked => _busy || (_frozenStage is not null && !_staged) || _frozenSession is not null || _frozenOffer is not null;

    void Render()
    {
        _root.Children.Clear();
        _root.RowDefinitions.Clear();
        if (_action.Compact) { _root.Children.Add(CompactApply()); return; }
        _root.RowDefinitions.Add(new RowDefinition { Height = Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = Star() });
        _root.RowDefinitions.Add(new RowDefinition { Height = Auto });

        var close = new Border { Width = 22, Height = 22, Background = Brush(Clear), Child = Icon("xmark", 12, Fnt).Also(i => i.FontWeight = Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center) }
            .OnTap(_close, "关闭", () => !_busy);
        var head = VStack(5, Spread(Serif(DialogTitle, 20).Frame(height: 29), close));
        if (_current is { } current)
            head.Children.Add(Sans(string.Join(" · ", new[] { current.Company, current.Title, "现在：" + CareerBoard.Projection(current.Raw).StageLabel }.Where(x => x.Length > 0)), 12.5, Sub));
        else if (NeedsStage)
            head.Children.Add(Sans(StartsPending ? "选择当前实际进度，可直接补录已经发生的阶段。" : "选择下一阶段，也可以直接补录已发生的阶段。", 12.5, Sub));
        head.Padding = new Thickness(32, 28, 32, 14);
        _root.Children.Add(head);

        var form = new StackPanel { Spacing = 24 };
        foreach (var section in Sections()) form.Children.Add(section);
        if (_error is { } error) form.Children.Add(Label(error, 13, Red).Wrap().Also(t => t.IsTextSelectionEnabled = true));
        form.IsHitTestVisible = !Locked;
        form.Opacity = Locked && !_busy ? 0.6 : 1;
        var scroll = new ScrollViewer { Content = form, Width = 516, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var summary = FormSummary();
        summary.Width = 272; summary.MinHeight = 550;
        var body = HStack(28, summary, scroll);
        body.VerticalAlignment = VerticalAlignment.Stretch;
        foreach (var child in body.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Stretch;
        body.Margin = new Thickness(32, 0, 32, 0);
        Grid.SetRow(body, 1);
        _root.Children.Add(body);

        var actions = HStack(10, new V3Button("取消", _close, height: 36) { Enabled = !_busy }.Also(b => b.MinWidth = 80));
        if (_kind is not ("detail" or "plugin"))
            actions.Children.Add(new V3Button(_busy ? "保存中…" : SubmitLabel, () => _ = SaveAsync(), _kind == "delete" ? V3Button.Kind.Danger : V3Button.Kind.Dark, height: 36) { Enabled = !(_busy || _creationUnknown) }.Also(b => b.MinWidth = 108));
        var footer = Spread(Sans(_current is not null && Creation ? "岗位已保存；后续步骤可继续重试。" : FooterHint, 11.5, Fnt), actions, 10);
        footer.Padding = new Thickness(32, 0, 32, 0);
        footer.Height = 88;
        var foot = new Border { Child = footer, BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 1, 0, 0) };
        Grid.SetRow(foot, 2);
        _root.Children.Add(foot);
    }

    IEnumerable<UIElement> Sections()
    {
        if (_kind == "plugin")
        {
            yield return Label("浏览器插件在 Chrome / Edge 中采集岗位，保存后刷新客户端即可查看。", 13).Wrap();
            yield return Label("在 Web 的岗位看板选择安装浏览器插件，下载并解压 ZIP；打开浏览器扩展管理，启用开发者模式后加载已解压的扩展。", 13).Wrap();
        }
        if (_kind is "arranged" or "schedule")
        {
            var options = new List<(string Id, string Label)> { ("", "创建新岗位") };
            options.AddRange(_applications.Where(a => a.Movable).Select(a => (a.Id, a.Company + " · " + a.Title)));
            var picker = Picker("岗位", options, _selectedExisting, ChangeSelectedExisting);
            picker.IsHitTestVisible = _current is null && _frozenStage is null;
            picker.Opacity = picker.IsHitTestVisible ? 1 : 0.6;
            yield return picker;
        }
        if (_kind == "schedule" && _applications.FirstOrDefault(a => a.Id == _selectedExisting) is { } chosen && ReusableCurrent(chosen))
        {
            var reuse = new CheckBox { Content = "为当前阶段添加排期", IsChecked = _reuseCurrentStage, IsEnabled = !_staged, FontSize = 13 };
            reuse.Click += (_, _) => ChangeReuse(reuse.IsChecked == true);
            yield return reuse;
        }
        if (Creation)
        {
            yield return Label("填写岗位信息，保存到你的云端账号。", 13, Hex(0x96968F));
            yield return Columns(16, (Star(), Field("公司", _company, v => _company = v)), (Star(), Field("岗位名称", _role, v => _role = v)));
            yield return CategoryPicker();
            yield return Field("工作城市", _city, v => _city = v);
            yield return Label("岗位描述 / JD", 13, Txt, Medium);
            var jd = new TextBox { Text = _description, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 140, FontSize = 13, Padding = new Thickness(8), BorderBrush = Brush(0xE4E4E0), CornerRadius = new CornerRadius(8) };
            jd.TextChanged += (_, _) => _description = jd.Text;
            yield return jd;
            yield return SystemButton("选择岗位截图", () => _ = ChooseImageAsync(), !_busy && _current is null);
            yield return SystemButton("智能提取岗位信息", () => _ = ParseDraftAsync(), !_busy && _description.Trim().Length > 0 && _current is null);
        }
        if (_kind == "category") yield return CategoryPicker();
        if (NeedsStage)
        {
            var stack = new StackPanel();
            if (!(_reuseCurrentStage || _kind == "schedule-current")) stack.Children.Add(StageTiles());
            if (StartsPending) stack.Children.Add(PendingFields());
            if (_stage == "offer") stack.Children.Add(_offerIntent == "none" ? OcFields() : FormalOfferFields().Top(24));
            else if (_stage == "screening")
            {
                if (!StartsPending) stack.Children.Add(Sans("保存后进入筛选中，等待公司筛选结果。", 13, Sub).Top(28));
            }
            else
            {
                if (_stage == "interview" && !IsHR) stack.Children.Add(RoundFields());
                stack.Children.Add(new CareerStageScheduleFields(_stage, IsHR, _window, v => { _window = v; Render(); }, _slotSet, v => { _slotSet = v; Render(); }, _start, v => { _start = v; Render(); },
                    _deadlineSet, v => { _deadlineSet = v; Render(); }, _end, v => { _end = v; Render(); }, _duration, v => { _duration = v; Render(); },
                    _planSet, v => { _planSet = v; Render(); }, _planStart, v => { _planStart = v; Render(); }, _planDuration, v => { _planDuration = v; Render(); },
                    _interviewMode, v => _interviewMode = v, _meeting, v => _meeting = v, _interviewer, v => _interviewer = v, _prepNote, v => { _prepNote = v; RenderSummaryOnly(); }));
            }
            if (_staged) stack.Children.Add(Sans("阶段已保存，剩余排期或 Offer 信息尚待确认。重试将复用原请求。", 12, V3.Orange).Wrap().Top(16));
            yield return stack;
        }
        if (_kind == "notes") yield return Field("备注", _notes, v => _notes = v);
        if (_kind is "accept" or "decline" or "archive" or "restore")
            yield return Label(_kind == "accept" ? "确认接受这份正式 Offer？本次求职流程将结束，阶段记录会保留。" : _kind == "decline" ? "确认婉拒这份正式 Offer？本次求职流程将结束，阶段记录会保留。"
                : _kind == "archive" ? "归档后仍可在已结束列查看并恢复。" : "恢复显示该岗位，已结束的流程不会重新开始。", 13).Wrap();
        if (_kind == "offer") { yield return StageTiles(); yield return FormalOfferFields(); }
        if (_kind == "terminate")
        {
            yield return Label("终止后会保留岗位、阶段与排期历史。", 13);
            yield return Picker("结束原因", [("user_withdrew", "主动结束"), ("company_rejected", "公司拒绝"), ("completed", "已完成"), ("other", "其他原因")], _reason, v => _reason = v);
        }
        if (_kind == "delete") yield return Label("确定永久删除这个岗位及其求职进程、阶段、排期和复盘？已关联的资料会保留在资料库。此操作不能撤销。", 13, Red).Wrap();
        if (_kind == "detail" && _current is { } detail) foreach (var part in DetailSections(detail)) yield return part;
    }

    IEnumerable<UIElement> DetailSections(CareerApplication current)
    {
        yield return HStack(8, Label(current.CategoryLabel, 13), Label(current.StatusLabel, 13, Fnt));
        if (_description.Length > 0) { yield return Label("岗位描述", 15, Txt, Semibold); yield return Label(_description, 13).Wrap().Also(t => t.IsTextSelectionEnabled = true); }
        yield return Label("求职阶段", 15, Txt, Semibold);
        foreach (var entry in current.Raw.Items("stages"))
            yield return Spread(HStack(8, new Ellipse { Width = 7, Height = 7, Fill = Brush(0x3976CF) }, Label(entry.Text("stage_label"), 13)),
                Label(new string(entry.Text("entered_at").Take(10).ToArray()), 13, Fnt));
        if (_sessions.Count > 0) yield return Label("排期", 15, Txt, Semibold);
        var statuses = new Dictionary<string, string> { ["scheduled"] = "已安排", ["completed"] = "已完成", ["cancelled"] = "已取消" };
        var commands = new Dictionary<string, string> { ["reschedule"] = "改期", ["answer-plan"] = "个人作答计划", ["complete"] = "标记完成", ["cancel"] = "取消安排" };
        foreach (var item in _sessions)
        {
            var block = VStack(8,
                Label(item.Text("stage_label") + " · " + (statuses.TryGetValue(item.Text("status"), out var s) ? s : item.Text("status")), 13),
                Label(item.Text("start_at") + " — " + item.Text("end_at"), 12, Fnt));
            if (item.Text("status") == "scheduled")
            {
                var row = HStack(8);
                foreach (var (command, title) in commands)
                {
                    var key = command; var session = item;
                    row.Children.Add(SystemButton(title, () =>
                    {
                        _editingSession = session; _sessionCommand = key; _commandPayload = null;
                        _start = CareerApplication.Date(session.Text("start_at")) ?? Beijing.Now;
                        _end = CareerApplication.Date(session.Text("end_at")) ?? _start.AddSeconds(3600);
                        Render();
                    }, !_busy));
                }
                block.Children.Add(row);
            }
            yield return block;
        }
        if (_editingSession is { } editing)
        {
            var titles = new Dictionary<string, string> { ["reschedule"] = "确认改期", ["answer-plan"] = "个人作答计划", ["complete"] = "确认标记为完成", ["cancel"] = "确认取消安排" };
            yield return Label(titles.TryGetValue(_sessionCommand, out var t) ? t : "", 15, Txt, Semibold);
            if (_sessionCommand is "reschedule" or "answer-plan")
            {
                yield return Labeled("开始时间", DateTimeField(_start, v => _start = v, _commandPayload is null));
                yield return Labeled("结束时间", DateTimeField(_end, v => _end = v, _commandPayload is null));
            }
            yield return HStack(8, SystemButton("确认", () => _ = SaveSessionAsync(editing), !_busy), SystemButton("返回", () => { _editingSession = null; _commandPayload = null; Render(); }, !_busy));
        }
        yield return Field("备注", _notes, v => _notes = v);
        var actions = HStack(8);
        if (current.Movable) actions.Children.Add(SystemButton("推进流程", () => { _kind = "stage"; Render(); }, true));
        if (!current.Ended) actions.Children.Add(SystemButton("终止求职", () => { _kind = "terminate"; Render(); }, true));
        if (current.Ended) actions.Children.Add(SystemButton("删除岗位", () => { _kind = "delete"; Render(); }, true, danger: true));
        yield return Spread(SystemButton("保存备注", () => _ = SaveNotesAsync(), !_busy), actions);
    }

    /// <summary>`.cd3-stage-choices`：一行八个阶段格。与 Web 一样，可以补录更早的阶段。</summary>
    FrameworkElement StageTiles()
    {
        var row = new Grid { ColumnSpacing = 8 };
        string[] choices = ["screening", "assessment", "written_test", "ai_interview", "interview", "hr", "oc", "formal"];
        var icons = new Dictionary<string, string> { ["screening"] = "filter", ["assessment"] = "text", ["written_test"] = "edit", ["ai_interview"] = "spark", ["interview"] = "user", ["hr"] = "brief", ["oc"] = "phone", ["formal"] = "mail" };
        var names = new Dictionary<string, string> { ["hr"] = "HR 面", ["oc"] = "OC", ["formal"] = "Offer", ["interview"] = "面试", ["screening"] = "筛选" };
        for (var i = 0; i < choices.Length; i++)
        {
            var choice = choices[i];
            var key = choice switch { "hr" => "interview", "oc" or "formal" => "offer", _ => choice };
            var chosen = _stage == key && (key != "offer" || _offerIntent == (choice == "formal" ? "received" : "none")) && (key != "interview" || (choice == "hr") == (_label == "HR 面"));
            var allowed = _kind == "offer" ? choice == "formal"
                : _kind == "schedule" ? choice is "assessment" or "written_test" or "ai_interview" or "interview" or "hr"
                : StartsPending || choice != "screening";
            var enabled = allowed && !_staged && _frozenStage is null && !_reuseCurrentStage;
            var tile = new Grid
            {
                Height = 58, Background = Brush(V3.White), CornerRadius = new CornerRadius(10), BorderBrush = Brush(chosen ? Txt : Cl),
                BorderThickness = new Thickness(chosen ? 1.5 : 1), Opacity = allowed ? 1 : 0.38,
            };
            tile.Children.Add(VStack(6, CareerIcon.Make(icons[choice], 16, true, chosen ? Txt : Sub).Align(HorizontalAlignment.Center),
                Sans(names.TryGetValue(choice, out var n) ? n : CareerStage.Label(key), 12, chosen ? Txt : Sub).Align(HorizontalAlignment.Center)).Align(HorizontalAlignment.Center, VerticalAlignment.Center));
            if (chosen)
                tile.Children.Add(new Border
                {
                    Width = 14, Height = 14, CornerRadius = new CornerRadius(7), Background = Brush(Txt), Margin = new Thickness(6),
                    HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
                    Child = Icon("checkmark", 7, V3.White).Also(x => x.FontWeight = Bold).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
                });
            if (chosen) Microsoft.UI.Xaml.Automation.AutomationProperties.SetItemStatus(tile, "已选中");
            tile.OnTap(() =>
            {
                _stage = key; _window = key == "assessment";
                if (choice == "hr") _label = "HR 面"; else if (choice == "interview" && _label == "HR 面") _label = DefaultRound(_current);
                if (key == "offer") _offerIntent = choice == "formal" ? "received" : "none";
                _error = null;
                Render();
            }, names.TryGetValue(choice, out var name) ? name : CareerStage.Label(key), () => enabled);
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            Grid.SetColumn(tile, i);
            row.Children.Add(tile);
        }
        return VStack(8, Sans(_kind == "offer" ? "阶段" : StartsPending ? "当前进度" : "阶段", 12, Txt, Medium).Frame(height: 14), row);
    }

    /// <summary>`.cd3-apply-dialog`：上方插图，下方投递日期与渠道。</summary>
    FrameworkElement CompactApply()
    {
        var paper = new Border
        {
            Width = 70, Height = 92, CornerRadius = new CornerRadius(6), Background = Brush(V3.White), Padding = new Thickness(10),
            Child = VStack(6, Fill(Txt, 2, 30, 5).Align(HorizontalAlignment.Left), Fill(V3.Line, 1, 46, 3), Fill(V3.Line, 1, 46, 3), Fill(V3.Line, 1, 46, 3), Fill(V3.Line, 1, 46, 3)),
            RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5), RenderTransform = new Microsoft.UI.Xaml.Media.RotateTransform { Angle = -4 },
        }.Elevate(4);
        var dash = new Line { X2 = 60, Stroke = Brush(Fnt2), StrokeThickness = 1.4, StrokeDashArray = [3 / 1.4, 3 / 1.4], Width = 60, Height = 1 };
        var tags = VStack(10, TagCard(_current?.Company.NonEmpty() ?? "目标公司", Blue), TagCard("筛选中", V3.Orange));
        var art = new V3DotStage(HStack(14, paper, dash, tags).Align(HorizontalAlignment.Center, VerticalAlignment.Center), 148) { Margin = new Thickness(24, 24, 24, 0) };
        var title = string.Join(" · ", new[] { _current?.Company ?? "", _current?.Title ?? "" }.Where(x => x.Length > 0));
        var body = VStack(0,
            Serif(Heading, 20),
            Sans(title.NonEmpty() ?? "记录投递信息", 12.5, Sub).Top(5),
            FormField("投递日期（选填）", DateField(_appliedAt, v => _appliedAt = v)).Top(20),
            FormField("投递渠道", IconInput("link", "例如：同事内推、官网、招聘平台", _channel, v => _channel = v), hint: "选填").Top(18),
            Sans("保存后岗位从「待投递」进入「筛选中」，等待公司筛选结果。", 11.5, Fnt).Wrap().Top(12));
        if (_error is { } error) body.Children.Add(Sans(error, 12, Red).Wrap().Top(10));
        body.Padding = new Thickness(28, 22, 28, 4);
        var foot = HStack(10, new V3Button("取消", _close, height: 36) { Enabled = !_busy },
            new V3Button(_busy ? "保存中…" : "保存求职进度", () => _ = SaveAsync(), V3Button.Kind.Dark, height: 36) { Enabled = !_busy });
        foot.HorizontalAlignment = HorizontalAlignment.Right;
        foot.Margin = new Thickness(28, 20, 28, 20);
        return VStack(0, art, body, foot);
    }

    static FrameworkElement TagCard(string text, Color dot) => new Border
    {
        Child = HStack(6, new Ellipse { Width = 6, Height = 6, Fill = Brush(dot) }, Sans(text, 10, Txt, Medium)),
        Padding = new Thickness(10, 0, 10, 0), Height = 24, Background = Brush(V3.White), CornerRadius = new CornerRadius(6), HorizontalAlignment = HorizontalAlignment.Left,
    }.Elevate(3);

    /// <summary>`.cd3-pending-fields`：首次投递记录的日期、渠道与简历。</summary>
    FrameworkElement PendingFields()
    {
        var options = new List<(string, string)> { ("", _resumes.Count == 0 ? "还没有简历" : "不关联简历") };
        options.AddRange(_resumes.Select(r => (r.Display("id"), r.Text("title"))));
        var resume = PickerBox(options, _selectedResume, v => { _selectedResume = v; RenderSummaryOnly(); });
        resume.IsEnabled = _frozenStage is null;
        return VStack(22,
            FormField("投递日期", DateField(_appliedAt, v => { _appliedAt = v; RenderSummaryOnly(); }), hint: "选填"),
            FormField("投递渠道", IconInput("link", "例如：同事内推、官网、招聘平台", _channel, v => { _channel = v; RenderSummaryOnly(); }), hint: "选填"),
            FormField("关联简历", resume, hint: "选填")).Top(22);
    }

    /// <summary>`.cd3-oc-fields`：口头意向记成 OC 阶段，有自己的字段。</summary>
    FrameworkElement OcFields() => VStack(22,
        Columns(16, (Star(), FormField("沟通时间", DateTimeField(_ocAt, v => { _ocAt = v; _ocAtSet = true; RenderSummaryOnly(); }), required: true)),
            (Star(), FormField("沟通方式", IconInput(null, "例如：电话 · HR", _ocContact, v => _ocContact = v)))),
        Columns(16, (Star(), FormField("口头薪酬", IconInput(null, "例如：35K × 16 薪", _oralSalary, v => { _oralSalary = v; RenderSummaryOnly(); }))),
            (Star(), FormField("预计到岗", IconInput(null, "例如：11 月上旬", _ocStartText, v => _ocStartText = v)))),
        FormField("补充说明", IconInput(null, "口头意向不等于正式 Offer，等书面确认后再更新结果", _ocNote, v => _ocNote = v), hint: "可选 · 只提醒自己")).Top(24);

    FrameworkElement FormalOfferFields()
    {
        var reply = OptionalDate("回复截止", _replySet, v => { _replySet = v; Render(); }, _replyDate, v => { _replyDate = v; RenderSummaryOnly(); });
        var start = OptionalDate("预计入职", _startSet, v => { _startSet = v; Render(); }, _startDate, v => _startDate = v);
        var structured = VStack(12,
            Field("薪资数额", _offerSalary, v => _offerSalary = v),
            HStack(12, Picker("币种", [("CNY", "CNY"), ("USD", "USD")], _currency, v => _currency = v), Picker("计薪周期", [("month", "月"), ("year", "年")], _salaryPeriod, v => _salaryPeriod = v)),
            Field("福利待遇", _benefits, v => _benefits = v)).Top(12);
        structured.Visibility = _structuredOpen ? Visibility.Visible : Visibility.Collapsed;
        var disclosure = HStack(6, Icon(_structuredOpen ? "chevron.down" : "chevron.right", 10, Sub), Label("结构化薪资与福利（可选）", 13))
            .OnTap(() => { _structuredOpen = !_structuredOpen; Render(); }, "结构化薪资与福利（可选）");
        return VStack(24,
            Columns(16, (Star(), Labeled("收到日期", DateField(_offerReceived, v => { _offerReceived = v; RenderSummaryOnly(); }))), (Star(), reply)),
            Columns(16, (Star(), Field("薪酬说明（如 35K × 16 薪）", _salaryDescription, v => { _salaryDescription = v; RenderSummaryOnly(); })), (Star(), Field("工作地点", _offerBase, v => { _offerBase = v; RenderSummaryOnly(); }))),
            Columns(16, (Star(), start), (Star(), Field("试用期（可选）", _probation, v => _probation = v))),
            Field("Offer 材料（资料库文件名或备注，可选）", _offerMaterials, v => _offerMaterials = v),
            VStack(0, disclosure, structured));
    }

    /// <summary>`.cd3-interview-round`：一面 / 二面 / 三面或自定义名称。</summary>
    FrameworkElement RoundFields()
    {
        string[] presets = ["一面", "二面", "三面"];
        var value = presets.Contains(_label) ? _label : _label.Length == 0 ? "" : "custom";
        var options = new List<(string, string)>();
        if (!presets.Contains(_label) && _label.Length == 0) options.Add(("", "选择轮次"));
        options.AddRange(presets.Select(p => (p, p)));
        options.Add(("custom", "自定义"));
        var picker = PickerBox(options, value, v =>
        {
            _label = v == "custom" ? "自定义面试" : v;
            var index = Array.IndexOf(presets, v);
            if (index >= 0) _round = index + 1;
            Render();
        });
        FrameworkElement second = presets.Contains(_label) ? new Border() : FormField("面试名称", IconInput(null, "例如：技术终面", _label, v => { _label = v; RenderSummaryOnly(); }));
        var row = Columns(16, (Star(), FormField("面试轮次", picker)), (Star(), second)).Top(22);
        row.IsHitTestVisible = _frozenStage is null && !_reuseCurrentStage;
        return row;
    }
}
