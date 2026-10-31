using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>`CareerForm` 左侧点阵摘要（`.cd3-stage-summary`）与表单字段积木。</summary>
public sealed partial class CareerForm
{
    sealed record TrackRow(string Key, string Label, string Status, bool Current);
    sealed record SummaryRow(string Icon, string Title, string Text, bool Muted);

    readonly Border _summaryHost = new();

    /// <summary>只改摘要的输入（渠道、备注、薪酬等）不重建右侧表单，避免打断输入框焦点。</summary>
    void RenderSummaryOnly()
    {
        if (_summaryHost.Parent is null) return;
        _summaryHost.Child = SummaryContent();
    }

    List<TrackRow> TrackRows
    {
        get
        {
            if (StartsPending)
                return [new("applied", "提交投递 · " + (ShortDay(_appliedAt) ?? "今天"), "本次", true), new("next", StageName + " · 投递后", "待开始", false)];
            var schedulingOnly = _kind == "schedule-current" || _reuseCurrentStage;
            var currentId = _current?.Raw.Get("current_stage").Text("id") ?? "";
            var stages = (_current?.Raw.Items("stages") ?? [])
                .OrderBy(s => s.Integer("sequence_no"))
                .Where(s => !schedulingOnly || s.Text("id") != currentId)
                .TakeLast(3);
            var rows = stages.Select(entry =>
            {
                var type = entry.Text("stage_type");
                var name = type == "screening" ? "简历筛选" : type == "oc" ? "OC · 口头意向" : entry.Text("stage_label");
                var day = ShortDay(CareerApplication.Date(entry.Text("completed_at").Length == 0 ? entry.Text("entered_at") : entry.Text("completed_at")));
                var status = entry.Text("stage_result") == "rejected" ? "未通过" : type == "oc" ? "已沟通" : entry.Text("stage_status") == "completed" || !schedulingOnly ? "已通过" : "进行中";
                return new TrackRow(entry.Text("id"), string.Join(" · ", new[] { name, day }.OfType<string>()), status, false);
            }).ToList();
            var thisDay = _stage == "offer" ? (_offerIntent == "none" ? (_ocAtSet ? ShortDay(_ocAt) : null) : ShortDay(_offerReceived))
                : IsWindow ? (_deadlineSet ? ShortDay(_end) : null) : (_slotSet ? ShortDay(_start) : null);
            rows.Add(new("this", string.Join(" · ", new[] { CurrentName, thisDay }.OfType<string>()), "本次", true));
            return rows;
        }
    }

    List<SummaryRow> SummaryRows
    {
        get
        {
            var rows = new List<SummaryRow> { new("flag", "阶段", (_kind == "schedule-current" || _reuseCurrentStage ? "当前" : "进入") + $"「{CurrentName}」", false) };
            if (StartsPending)
            {
                var channel = _channel.Trim();
                var resume = _resumes.FirstOrDefault(r => r.Display("id") == _selectedResume)?.Text("title");
                rows.Add(new("link", "投递渠道", channel.Length == 0 ? "还没填 · 可选" : channel + " · 可选", channel.Length == 0));
                rows.Add(new("text", "关联简历", resume is null ? "还没选 · 可选" : resume + " · 可选", resume is null));
            }
            else if (_stage == "offer" && _offerIntent == "none")
            {
                rows.Add(new("clock", "沟通时间", _ocAtSet ? ListDateTime(_ocAt) : "选择沟通时间", !_ocAtSet));
                var salary = _oralSalary.Trim();
                rows.Add(new("text", "口头薪酬", salary.Length == 0 ? "可以之后补充" : salary, salary.Length == 0));
            }
            else if (_stage == "offer")
            {
                rows.Add(new("calendar", "回复截止", _replySet ? ShortDay(_replyDate) ?? "" : "还没填", !_replySet));
                var terms = string.Join(" · ", new[] { _salaryDescription, _offerBase }.Select(x => x.Trim()).Where(x => x.Length > 0));
                rows.Add(new("text", "薪酬与地点", terms.Length == 0 ? "可以之后补充" : terms, terms.Length == 0));
            }
            else if (_stage == "screening") { }
            else if (IsWindow)
            {
                rows.Add(new("calendar", "开放与截止", (_slotSet ? ListDateTime(_start) : "现在") + " 至 " + (_deadlineSet ? ListDateTime(_end) : "待选择截止时间"), false));
                rows.Add(new("check", "我的计划", _planSet ? ListDateTime(_planStart) : "还没定，之后随时可以补", !_planSet));
            }
            else
            {
                rows.Add(new("clock", IsHR ? "沟通时间" : "官方时间", _slotSet ? ListDateTime(_start) + $" · {_duration} 分钟" : "选择开始时间和时长", !_slotSet));
                var note = _prepNote.Trim();
                rows.Add(new("check", IsHR ? "沟通准备" : "我的准备", note.Length == 0 ? "面试准备与复盘" : note, note.Length == 0));
            }
            return rows;
        }
    }

    string? SummaryNote
    {
        get
        {
            if (StartsPending || _stage == "screening") return null;
            if (_stage == "offer") return _offerIntent == "none" ? "OC 只是口头意向\n收到书面 Offer 后再记录正式 Offer" : "接受或婉拒后流程结束\n阶段记录和复盘都会保留";
            if (IsWindow) return "截止时间过后自动进入「等待结果」\n无需手动标记完成";
            if (IsHR) return "沟通结束后自动进入「等待结果」\n无需手动标记完成";
            return $"{(_stage == "interview" ? "面试" : StageName)}结束后自动进入「等待结果」\n无需手动标记完成";
        }
    }

    string SummaryTitle => StartsPending ? "这次投递怎么记" : _stage == "offer" ? (_offerIntent == "none" ? "这次意向怎么记" : "这份 Offer 怎么记") : "这一场怎么安排";

    /// <summary>`.cd3-stage-summary`：点阵面板，含阶段轨迹、将保存的内容与自动状态说明。</summary>
    FrameworkElement FormSummary()
    {
        _summaryHost.Child = SummaryContent();
        var panel = new Grid { CornerRadius = new CornerRadius(12) };
        panel.Children.Add(new V3DotStage(null, null) { CornerRadius = new CornerRadius(12) });
        panel.Children.Add(_summaryHost);
        return panel;
    }

    UIElement SummaryContent()
    {
        var stageForm = NeedsStage || _kind == "offer";
        var rows = stageForm ? SummaryRows : [
            new("flag", "阶段", _kind is "accept" or "decline" ? "本次求职将结束，历史会保留" : Heading, false),
            new("text", "记录", "保留已有阶段与面试记录", false),
        ];
        var track = stageForm ? TrackRows : [];
        var grid = new Grid { Padding = new Thickness(20, 18, 20, 18) };
        grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
        grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
        var top = VStack(0, Sans(stageForm ? SummaryTitle : Heading, 11, Fnt));
        if (track.Count > 0)
        {
            var list = new StackPanel { Spacing = 18 };
            foreach (var row in track)
            {
                var dot = new Grid { Width = 11, Height = 11 };
                if (row.Current) dot.Children.Add(new Ellipse { Width = 11, Height = 11, Stroke = Brush(V3.Stage), StrokeThickness = 2 });
                dot.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = Brush(row.Current ? Txt : Green) });
                FrameworkElement status = row.Current
                    ? new Border { Child = Sans(row.Status, 10.5, V3.White, Medium), Padding = new Thickness(8, 2, 8, 2), Background = Brush(Txt), CornerRadius = new CornerRadius(9) }
                    : Sans(row.Status, 11.5, row.Status is "已通过" or "已沟通" ? Green : Fnt, row.Status is "已通过" or "已沟通" ? Medium : Regular);
                list.Children.Add(Columns(10, (Auto, dot.Pad(-2, 0, -2, 0)), (Star(), Sans(row.Label, 11.5, row.Current ? Txt : Sub).Align(v: VerticalAlignment.Center)), (Auto, status.Align(v: VerticalAlignment.Center))).Also(r => r.MinHeight = 22));
            }
            var rail = new Border { Width = 1, Background = Brush(Sk2), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(3, 10, 0, 10) };
            var box = new Grid { Children = { rail, list } };
            top.Children.Add(new Border { Child = box, Padding = new Thickness(0, 16, 0, 18), BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 0, 0, 1) });
        }
        if (rows.Count > 0)
        {
            top.Children.Add(Sans(stageForm ? $"点「{SubmitLabel}」后保存" : "确认后会更新", 11, Fnt).Top(18));
            foreach (var row in rows)
            {
                var icon = new Border
                {
                    Width = 28, Height = 28, CornerRadius = new CornerRadius(14), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
                    Child = CareerIcon.Make(row.Icon, 14, true, Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center), VerticalAlignment = VerticalAlignment.Top,
                };
                var text = VStack(6, Sans(row.Title, 12.5, row.Muted ? Fnt : Txt, Medium), Sans(row.Text, 11.5, Sub).LineHeight(17).Wrap(3));
                top.Children.Add(Columns(12, (Auto, icon), (Star(), text)).Top(18));
            }
        }
        grid.Children.Add(top);
        if (stageForm && SummaryNote is { } note)
        {
            var foot = Columns(6, (Auto, CareerIcon.Make("clock", 14, true, Fnt).Align(v: VerticalAlignment.Top)), (Star(), Sans(note, 11, Fnt).LineHeight(17).Wrap()));
            foot.Margin = new Thickness(0, 24, 0, 0);
            Grid.SetRow(foot, 2);
            grid.Children.Add(foot);
        }
        return grid;
    }

    // MARK: 字段积木

    FrameworkElement CategoryPicker() => Picker("求职分类", [("", "未分类"), ("internship", "实习"), ("campus", "校招"), ("full_time", "正式")], _category, v => _category = v);

    /// <summary>Swift `Picker(title, selection:)` 的系统样式：标题在左、下拉在右。</summary>
    static FrameworkElement Picker(string title, IReadOnlyList<(string Id, string Label)> options, string selected, Action<string> changed) =>
        HStack(8, Label(title, 13), PickerBox(options, selected, changed));

    static ComboBox PickerBox(IReadOnlyList<(string Id, string Label)> options, string selected, Action<string> changed)
    {
        var box = new ComboBox { FontSize = 13, MinHeight = 0, MinWidth = 120 };
        foreach (var (_, label) in options) box.Items.Add(label);
        box.SelectedIndex = Math.Max(0, options.ToList().FindIndex(o => o.Id == selected));
        box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0) changed(options[box.SelectedIndex].Id); };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, options.FirstOrDefault(o => o.Id == selected).Label ?? "");
        return box;
    }

    /// <summary>Mac `field(_:text:)`：12px 次要色标题 + 圆角输入框。</summary>
    static FrameworkElement Field(string title, string text, Action<string> changed)
    {
        var box = new TextBox { Text = text, PlaceholderText = title, FontSize = 13 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, title);
        box.TextChanged += (_, _) => changed(box.Text);
        return VStack(6, Label(title, 12, Fnt), box);
    }

    static FrameworkElement SystemButton(string title, Action action, bool enabled, bool danger = false)
    {
        var button = new Button { Content = title, IsEnabled = enabled, FontSize = 13 };
        if (danger) button.Foreground = Brush(Red);
        button.Click += (_, _) => action();
        return button;
    }

    static FrameworkElement Labeled(string title, FrameworkElement control) => HStack(8, Label(title, 13), control);

    /// <summary>`formField`：11px 标题（必填红星、右侧提示 10.5px），间距 8。</summary>
    static FrameworkElement FormField(string title, FrameworkElement content, bool required = false, string? hint = null)
    {
        var head = new Grid { Height = 13 };
        var left = HStack(2, Sans(title, 11, Sub), required ? Sans("*", 11, Red) : null);
        head.Children.Add(left);
        if (hint is not null) head.Children.Add(Sans(hint, 10.5, Fnt).Align(HorizontalAlignment.Right));
        content.HorizontalAlignment = HorizontalAlignment.Stretch;
        return VStack(8, head, content);
    }

    /// <summary>`iconInput`：40 高、左右 12、圆角 8 的白底输入框，可带 14px 图标。</summary>
    static FrameworkElement IconInput(string? icon, string placeholder, string text, Action<string> changed)
    {
        var box = new TextBox
        {
            Text = text, PlaceholderText = placeholder, FontSize = 13, FontFamily = SansFamily, BorderThickness = new Thickness(0), Background = Brush(Clear),
            Foreground = Brush(Txt), PlaceholderForeground = Brush(Fnt2), MinHeight = 0, Padding = new Thickness(0, 10, 0, 0), VerticalAlignment = VerticalAlignment.Center,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, placeholder);
        box.TextChanged += (_, _) => changed(box.Text);
        var row = icon is null ? (UIElement)box : Columns(8, (Auto, CareerIcon.Make(icon, 14, true, Fnt).Align(v: VerticalAlignment.Center)), (Star(), box));
        return new Border
        {
            Child = row, Height = 40, Padding = new Thickness(12, 0, 12, 0), Background = Brush(V3.White), CornerRadius = new CornerRadius(8),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
        };
    }

    /// <summary>`DatePicker(displayedComponents: .date)`：只选日期，保留原来的时刻。</summary>
    static FrameworkElement DateField(DateTimeOffset value, Action<DateTimeOffset> changed)
    {
        var picker = new CalendarDatePicker { Date = value, Height = 40, MinWidth = 160, FontSize = 13 };
        picker.DateChanged += (_, e) => { if (e.NewDate is { } date) changed(new DateTimeOffset(date.Date.Add(value.TimeOfDay), value.Offset)); };
        return picker;
    }

    /// <summary>`DatePicker(selection:)`：日期 + 时间。</summary>
    static FrameworkElement DateTimeField(DateTimeOffset value, Action<DateTimeOffset> changed, bool enabled = true)
    {
        var current = value.ToLocalTime();
        var date = new CalendarDatePicker { Date = current, Height = 40, FontSize = 13, IsEnabled = enabled };
        var time = new TimePicker { Time = current.TimeOfDay, ClockIdentifier = "24HourClock", MinWidth = 0, IsEnabled = enabled };
        void Push()
        {
            var day = date.Date ?? current;
            var local = day.Date + time.Time;
            changed(new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local)));
        }
        date.DateChanged += (_, _) => Push();
        time.TimeChanged += (_, _) => Push();
        return HStack(8, date, time);
    }

    /// <summary>`Toggle` + 只在打开时出现的日期选择（回复截止 / 预计入职）。</summary>
    static FrameworkElement OptionalDate(string title, bool on, Action<bool> toggle, DateTimeOffset value, Action<DateTimeOffset> changed)
    {
        var box = new CheckBox { Content = title, IsChecked = on, FontSize = 13 };
        box.Click += (_, _) => toggle(box.IsChecked == true);
        var row = HStack(8, box);
        if (on) row.Children.Add(DateField(value, changed));
        return row;
    }
}
