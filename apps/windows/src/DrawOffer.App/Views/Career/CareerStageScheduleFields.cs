using System.Globalization;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;
using static DrawOffer.App.Views.Career.CareerKit;

namespace DrawOffer.App.Views.Career;

/// <summary>
/// Web `AddNextStageDialog` 的时间安排部分（Mac `CareerStageScheduleFields`；`.cd3-time-*`、`.cd3-mode-*`、`.cd3-stage-field`）。
/// 面试与 HR 面是一个固定时段加时长；测评总是窗口；笔试在时段与窗口之间选；AI 面试只能按时段。
/// 绑定值由调用方持有：每个值配一个 setter，控件改动后回写并按新值重绘自己。
/// </summary>
public sealed class CareerStageScheduleFields : UserControl
{
    string _stage;
    readonly bool _isHR;
    bool _window, _startSet, _endSet, _planSet, _allowConflict;
    DateTimeOffset _start, _end, _planStart;
    int _duration, _planDuration;
    string _mode, _link, _interviewer, _note;
    readonly bool _hasError;
    readonly Action<bool> _setWindow, _setStartSet, _setEndSet, _setPlanSet, _setAllowConflict;
    readonly Action<DateTimeOffset> _setStart, _setEnd, _setPlanStart;
    readonly Action<int> _setDuration, _setPlanDuration;
    readonly Action<string> _setMode, _setLink, _setInterviewer, _setNote;
    bool _noteOpen;
    int? _deadlineDays;
    Flyout? _editing;

    public CareerStageScheduleFields(string stage, bool isHR, bool window, Action<bool> setWindow, bool startSet, Action<bool> setStartSet,
        DateTimeOffset start, Action<DateTimeOffset> setStart, bool endSet, Action<bool> setEndSet, DateTimeOffset end, Action<DateTimeOffset> setEnd,
        int duration, Action<int> setDuration, bool planSet, Action<bool> setPlanSet, DateTimeOffset planStart, Action<DateTimeOffset> setPlanStart,
        int planDuration, Action<int> setPlanDuration, string mode, Action<string> setMode, string link, Action<string> setLink,
        string interviewer, Action<string> setInterviewer, string note, Action<string> setNote, bool allowConflict, Action<bool> setAllowConflict, bool hasError)
    {
        (_stage, _isHR, _window, _setWindow, _startSet, _setStartSet, _start, _setStart, _endSet, _setEndSet, _end, _setEnd) =
            (stage, isHR, window, setWindow, startSet, setStartSet, start, setStart, endSet, setEndSet, end, setEnd);
        (_duration, _setDuration, _planSet, _setPlanSet, _planStart, _setPlanStart, _planDuration, _setPlanDuration) =
            (duration, setDuration, planSet, setPlanSet, planStart, setPlanStart, planDuration, setPlanDuration);
        (_mode, _setMode, _link, _setLink, _interviewer, _setInterviewer, _note, _setNote, _allowConflict, _setAllowConflict, _hasError) =
            (mode, setMode, link, setLink, interviewer, setInterviewer, note, setNote, allowConflict, setAllowConflict, hasError);
        StageChanged(stage);
        Render();
    }

    void StageChanged(string value)
    {
        if (value == "assessment" && !_window) Window = true;
        if (value is "ai_interview" or "interview" && _window) Window = false;
    }

    bool InterviewForm => _stage == "interview";
    bool IsWindow => _stage == "assessment" || (_stage == "written_test" && _window);

    bool Window { set { _window = value; _setWindow(value); } }
    bool StartSet { set { _startSet = value; _setStartSet(value); } }
    bool EndSet { set { _endSet = value; _setEndSet(value); } }
    bool PlanSet { set { _planSet = value; _setPlanSet(value); } }
    DateTimeOffset Start { set { _start = value; _setStart(value); } }
    DateTimeOffset End { set { _end = value; _setEnd(value); } }
    DateTimeOffset PlanStart { set { _planStart = value; _setPlanStart(value); } }
    int PlanDuration { set { _planDuration = value; _setPlanDuration(value); } }

    void Render()
    {
        var stack = new StackPanel();
        if (!InterviewForm)
        {
            stack.Children.Add(Sans("时间安排", 12, Txt, Medium).Frame(height: 14).Pad(0, 28, 0, 8));
            stack.Children.Add(Columns(8,
                (Star(), TimeChoice(false, "按时参加", "准点开始，有时长", "clock", _stage == "assessment")),
                (Star(), TimeChoice(true, "截止前完成", _stage == "ai_interview" ? "AI 面试仅支持按时参加" : "期间自己选时间", "flag", _stage == "ai_interview"))));
        }
        var times = IsWindow
            ? Columns(16, (Star(), Labeled("截止时间", DateButton("end", _endSet ? _end : null, "选择截止时间"), required: true)),
                (Star(), Labeled("开放时间", DateButton("start", _startSet ? _start : null, "收到通知就开放"), hint: "不填从现在开始")))
            : Columns(16, (Star(), Labeled(_isHR ? "沟通时间" : "开始时间", DateButton("start", _startSet ? _start : null, "选择开始时间"), required: true)),
                (Star(), Labeled("时长", DurationPicker())));
        foreach (var child in times.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Top;
        stack.Children.Add(times.Top(22));
        if (IsWindow)
        {
            if (_stage == "assessment")
            {
                var chips = HStack(6);
                foreach (var days in new[] { 1, 3, 7 })
                {
                    var chosen = _deadlineDays == days && _endSet;
                    var chip = new Border
                    {
                        Child = Sans(days == 1 ? "24 小时" : $"{days} 天后", 11, chosen ? Txt : Sub).Align(v: VerticalAlignment.Center),
                        Padding = new Thickness(9, 0, 9, 0), Height = 24, CornerRadius = new CornerRadius(12),
                        Background = Brush(chosen ? Stage : V3.White), BorderBrush = Brush(chosen ? Txt : Cl), BorderThickness = new Thickness(1),
                    };
                    var value = days;
                    chips.Children.Add(chip.OnTap(() => { End = Beijing.Now.AddSeconds(value * 86400.0); EndSet = true; _deadlineDays = value; Render(); }, days == 1 ? "24 小时" : $"{days} 天后"));
                }
                stack.Children.Add(chips.Top(8));
            }
            stack.Children.Add(Labeled("我的作答计划", PlanButton(), hint: "可选 · 只提醒自己，不改官方时间").Top(22));
        }
        if (InterviewForm)
        {
            var row = Columns(16,
                (Star(), Labeled(_isHR ? "沟通方式" : "面试方式", ModeSegmented([("video", "视频"), ("onsite", "现场"), ("phone", "电话")]).Top(10))),
                (Star(), Labeled(_isHR ? "联系人" : "面试官", TextInput(_isHR ? "例如：陈老师 · 招聘 HR" : "例如：李老师 · 技术负责人", _interviewer, v => { _interviewer = v; _setInterviewer(v); }))));
            foreach (var child in row.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Top;
            stack.Children.Add(row.Top(22));
            stack.Children.Add(Labeled(_mode == "onsite" ? "面试地点" : "会议链接", TextInput(_mode == "onsite" ? "填写地点" : "粘贴会议链接", _link, v => { _link = v; _setLink(v); }, "link"), hint: "可选").Top(26));
            stack.Children.Add(Labeled(_isHR ? "沟通准备" : "准备提醒", TextInput(_isHR ? "例如：确认薪酬期望、到岗时间与工作地点" : "例如：整理两个项目案例", _note, v => { _note = v; _setNote(v); }, "clock"), hint: "可选 · 只提醒自己").Top(22));
        }
        else
        {
            if (_stage == "written_test" && !IsWindow)
            {
                stack.Children.Add(Labeled("方式", ModeSegmented([("video", "在线"), ("onsite", "线下")]).Top(10)).Top(22));
                stack.Children.Add(Labeled(_mode == "onsite" ? "笔试地点" : "笔试链接", TextInput("粘贴链接或填写地点", _link, v => { _link = v; _setLink(v); }, "link"), hint: "可选").Top(26));
            }
            else
                stack.Children.Add(Labeled(_stage == "assessment" ? "测评链接" : _stage == "written_test" ? "笔试链接" : "面试链接", TextInput("粘贴链接", _link, v => { _link = v; _setLink(v); }, "link"), hint: "可选").Top(22));
            var toggle = HStack(6, Icon(_noteOpen ? "chevron.up" : "plus", 10, Sub), Sans("添加准备备注", 12, Sub), Sans("要带的材料、注意事项", 11, Fnt));
            stack.Children.Add(Tappable(toggle, () => { _noteOpen = !_noteOpen; Render(); }, "添加准备备注").Top(22));
            if (_noteOpen || _note.Length > 0)
            {
                var editor = new TextBox
                {
                    Text = _note, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontSize = 13, FontFamily = SansFamily, Height = 70, Padding = new Thickness(6),
                    CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), BorderBrush = Brush(Cl), Background = Brush(V3.White), Foreground = Brush(Txt),
                }.Named("备注（选填）");
                editor.TextChanged += (_, _) => { _note = editor.Text; _setNote(editor.Text); };
                stack.Children.Add(editor.Top(10));
            }
        }
        if (_hasError)
        {
            var check = new CheckBox { Content = Sans("确认仍保存有时间冲突的安排", 12, Txt), IsChecked = _allowConflict, MinWidth = 0 };
            check.Checked += (_, _) => { _allowConflict = true; _setAllowConflict(true); };
            check.Unchecked += (_, _) => { _allowConflict = false; _setAllowConflict(false); };
            stack.Children.Add(check.Top(14));
        }
        Content = stack;
    }

    FrameworkElement TimeChoice(bool value, string title, string subtitle, string icon, bool disabled)
    {
        var active = IsWindow == value;
        var badge = new Border
        {
            Width = 30, Height = 30, CornerRadius = new CornerRadius(8), Background = Brush(active ? Txt : Field),
            Child = CareerIcon.Make(icon, 14, template: true, tint: active ? V3.White : Sub).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        };
        var copy = VStack(5, Sans(title, 13, disabled ? Fnt : Txt, Medium), Sans(subtitle, 11, Fnt));
        var row = Columns(12, (Auto, badge), (Star(), copy));
        row.VerticalAlignment = VerticalAlignment.Center;
        var grid = new Grid();
        grid.Children.Add(new Border
        {
            Child = row, Padding = new Thickness(14, 0, 14, 0), Height = 64, CornerRadius = new CornerRadius(10), Background = Brush(V3.White),
            BorderBrush = Brush(active ? Txt : Cl), BorderThickness = new Thickness(active ? 1.5 : 1),
        });
        if (active)
            grid.Children.Add(new Border
            {
                Width = 14, Height = 14, CornerRadius = new CornerRadius(7), Background = Brush(Txt), Margin = new Thickness(0, 6, 6, 0),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
                Child = Icon("checkmark", 7, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            });
        grid.Opacity = disabled ? 0.6 : 1;
        return Tappable(grid, () => { Window = value; Render(); }, title, () => !disabled);
    }

    FrameworkElement ModeSegmented((string Value, string Label)[] options)
    {
        var row = new Grid { Padding = new Thickness(3) };
        for (var index = 0; index < options.Length; index++)
        {
            var option = options[index];
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            var on = _mode == option.Value;
            var cell = new Border
            {
                Height = 24, CornerRadius = new CornerRadius(5), Background = Brush(on ? V3.White : Clear),
                Child = Sans(option.Label, 11.5, on ? Txt : Fnt).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            };
            if (on) cell.Elevate(2);
            var tap = Tappable(cell, () => { _mode = option.Value; _setMode(option.Value); Render(); }, option.Label);
            Grid.SetColumn(tap, index);
            row.Children.Add(tap);
        }
        return new Border
        {
            Child = row, Width = options.Length == 3 ? 102 : 72, Height = 30, CornerRadius = new CornerRadius(8), Background = Brush(Field),
            BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Left,
        };
    }

    static FrameworkElement Labeled(string title, FrameworkElement content, bool required = false, string? hint = null)
    {
        var label = HStack(2, Sans(title, 11, Sub), required ? Sans("*", 11, Red) : null);
        var head = Spread(label, hint is null ? new Border() : Sans(hint, 10.5, Fnt), 4);
        head.Height = 13;
        return VStack(8, head, content);
    }

    static Border Input(string icon, string text, bool placeholder = false) => new()
    {
        Child = Columns(8, (Auto, CareerIcon.Make(icon, 14, template: true, tint: Sub)), (Star(), Sans(text, 13, placeholder ? Fnt2 : Txt))).Also(g => g.VerticalAlignment = VerticalAlignment.Center),
        Padding = new Thickness(12, 0, 12, 0), Height = 40, CornerRadius = new CornerRadius(8), Background = Brush(V3.White),
        BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
    };

    static Border TextInput(string placeholder, string text, Action<string> changed, string? icon = null)
    {
        var box = new TextBox
        {
            Text = text, PlaceholderText = placeholder, FontSize = 13, FontFamily = SansFamily, BorderThickness = new Thickness(0), Background = Brush(Clear),
            Foreground = Brush(Txt), PlaceholderForeground = Brush(Fnt2), Padding = new Thickness(0, 9, 0, 0), MinHeight = 0, VerticalAlignment = VerticalAlignment.Center,
        }.Named(placeholder);
        box.TextChanged += (_, _) => changed(box.Text);
        UIElement row = icon is null ? box : Columns(8, (Auto, CareerIcon.Make(icon, 14, template: true, tint: Fnt).Align(v: VerticalAlignment.Center)), (Star(), box));
        return new Border { Child = row, Padding = new Thickness(12, 0, 12, 0), Height = 40, CornerRadius = new CornerRadius(8), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1) };
    }

    FrameworkElement DurationPicker()
    {
        var options = new SortedSet<int> { 30, 60, 90, 120, 180, _duration }.ToList();
        var box = new ComboBox { Height = 40, HorizontalAlignment = HorizontalAlignment.Stretch, FontFamily = SansFamily, FontSize = 13 }.Named("时长");
        foreach (var value in options) box.Items.Add($"{value} 分钟");
        box.SelectedIndex = options.IndexOf(_duration);
        box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0) { _duration = options[box.SelectedIndex]; _setDuration(_duration); } };
        return box;
    }

    static string Stamp(DateTimeOffset date, bool weekday)
    {
        var local = date.ToBeijing();
        var culture = CultureInfo.GetCultureInfo("zh-CN");
        return weekday ? local.ToString("MM月dd日 ddd HH:mm", culture) : local.ToString("MM月dd日 HH:mm", culture);
    }

    FrameworkElement PlanButton()
    {
        var input = Input("clock", _planSet ? Stamp(_planStart, false) + $" · {_planDuration} 分钟" : "选一段打算作答的时间", !_planSet);
        return Tappable(input, () =>
        {
            if (!_planSet) { PlanStart = Max(_startSet ? _start : Beijing.Now, Beijing.Now); PlanDuration = 60; }
            var lower = _startSet ? _start : Beijing.Now;
            var upper = Max(lower, _endSet ? _end : Beijing.Now.AddSeconds(86400.0 * 365));
            var draft = _planStart;
            var duration = _planDuration;
            var minutes = new[] { 30, 60, 90, 120, 180 };
            var picker = new ComboBox { FontFamily = SansFamily, FontSize = 13, MinWidth = 120 }.Named("时长");
            foreach (var value in minutes) picker.Items.Add($"{value} 分钟");
            picker.SelectedIndex = Array.IndexOf(minutes, duration);
            picker.SelectionChanged += (_, _) => { if (picker.SelectedIndex >= 0) duration = minutes[picker.SelectedIndex]; };
            var date = new CalendarDatePicker { Date = draft, MinDate = lower, MaxDate = upper }.Named("开始时间");
            var time = new TimePicker { Time = draft.LocalDateTime.TimeOfDay, ClockIdentifier = "24HourClock", MinuteIncrement = 1 }.Named("开始时间");
            DateTimeOffset Read() => Clamp(Local((date.Date ?? draft).LocalDateTime.Date + time.Time), lower, upper);
            var clear = new CareerAction("清除", () => { PlanSet = false; _editing?.Hide(); Render(); }, CareerAction.Kind.Text);
            var done = new CareerAction("完成", () => { PlanStart = Read(); PlanDuration = duration; PlanSet = true; _editing?.Hide(); Render(); }, CareerAction.Kind.Primary);
            var body = VStack(14, Sans("我的作答计划", 13, Txt, Medium), HStack(8, Sans("开始时间", 12, Sub), date, time), HStack(8, Sans("时长", 12, Sub), picker), Spread(clear, done, 8));
            body.Padding = new Thickness(20);
            body.Width = 300 + 140;
            _editing = V3Popover.Show(input, body, FlyoutPlacementMode.Bottom, 0);
        }, "我的作答计划");
    }

    FrameworkElement DateButton(string key, DateTimeOffset? value, string placeholder)
    {
        var input = Input("calendar", value is { } chosen ? Stamp(chosen, true) : placeholder, value is null);
        return Tappable(input, () =>
        {
            if (value is null) Seed(key);
            var current = key == "end" ? _end : _start;
            var calendar = new CalendarView { SelectionMode = CalendarViewSelectionMode.Single, FirstDayOfWeek = Windows.Globalization.DayOfWeek.Sunday }.Named(key == "end" ? "截止时间" : _isHR ? "沟通时间" : "开始时间");
            calendar.SelectedDates.Add(current);
            calendar.SetDisplayDate(current);
            var time = new TimePicker { Time = current.LocalDateTime.TimeOfDay, ClockIdentifier = "24HourClock", MinuteIncrement = 1 };
            DateTimeOffset Read() => Local((calendar.SelectedDates.Count > 0 ? calendar.SelectedDates[0] : current).LocalDateTime.Date + time.Time);
            var actions = new Grid();
            if (key == "start" && IsWindow) actions.Children.Add(new CareerAction("从现在开始", () => { StartSet = false; _editing?.Hide(); Render(); }, CareerAction.Kind.Text));
            var done = new CareerAction("完成", () =>
            {
                if (key == "end") { End = Read(); EndSet = true; _deadlineDays = null; } else { Start = Read(); StartSet = true; }
                _editing?.Hide(); Render();
            }, CareerAction.Kind.Primary);
            done.HorizontalAlignment = HorizontalAlignment.Right;
            actions.Children.Add(done);
            var body = VStack(14, calendar, time, actions);
            body.Padding = new Thickness(18);
            body.Width = 300;
            _editing = V3Popover.Show(input, body, FlyoutPlacementMode.Bottom, 0);
        }, placeholder);
    }

    /// <summary>第一次选时从下一个半点开始（Web `defaultInterviewStartAt`）。</summary>
    void Seed(string key)
    {
        var baseDate = Beijing.Now.AddSeconds(key == "end" ? 3 * 86400 : 86400).LocalDateTime;
        var hour = new DateTime(baseDate.Year, baseDate.Month, baseDate.Day, baseDate.Hour, 0, 0);
        var date = Local(hour).AddSeconds(baseDate.Minute < 30 ? 30 * 60 : 3600);
        if (key == "end") End = date; else Start = date;
    }

    static DateTimeOffset Max(DateTimeOffset a, DateTimeOffset b) => a > b ? a : b;
    static DateTimeOffset Clamp(DateTimeOffset value, DateTimeOffset low, DateTimeOffset high) => value < low ? low : value > high ? high : value;
}
