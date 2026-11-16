using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Api;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>
/// 05.2b–05.2i 日程详情，对应 Mac `ScheduleDetailDialog`：衬线标题与状态胶囊、插图舞台、信息卡；开放窗口另有个人作答计划。520 宽。
/// </summary>
sealed class ScheduleDetailDialog : UserControl
{
    readonly ScheduledInterview _interview;
    readonly Action _close, _changed, _openRecord;
    readonly StackPanel _body = new() { Padding = new Thickness(32, 28, 32, 28) };
    readonly Border _footer = new() { BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 1, 0, 0) };
    ScheduledInterview? _item;
    bool _planSet, _busy;
    DateTimeOffset _planStart = Beijing.Now;
    int _planMinutes = 120;
    string? _error;

    ScheduleDetailDialog(ScheduledInterview interview, Action close, Action changed, Action openRecord)
    {
        _interview = interview; _close = close; _changed = changed; _openRecord = openRecord;
        Content = VStack(0, _body, _footer);
        Loaded += async (_, _) => await StartAsync();
        Render();
    }

    public static void Show(XamlRoot root, ScheduledInterview interview, Action changed, Action openRecord) =>
        V3Overlay.Show(root, close => V3Dialog.Frame(new ScheduleDetailDialog(interview, close, () => { close(); changed(); }, () => { close(); openRecord(); }), 520));

    ScheduledInterview Current => _item ?? _interview;
    bool IsWindow => Current.OpenWindow;
    string Stage => Current.Label;
    bool IsExam => Stage.Contains("笔试");
    bool IsTest => Stage.Contains("测评");
    bool IsAI => Stage.Contains("ai", StringComparison.OrdinalIgnoreCase);
    bool Cancelled => Current.Text("status") == "cancelled";
    bool Completed => Current.Text("status") == "completed";
    bool Active => !Cancelled && !Completed && Current.Start <= Beijing.Now && Current.End > Beijing.Now;
    bool CanEdit => Current.Editable;
    string KindWord => IsExam ? "笔试" : IsTest ? "测评" : "面试";

    (string Text, Color Ink, Color Soft) Status
    {
        get
        {
            if (Completed) return ("已完成", Green, GreenSoft);
            if (Cancelled) return ("已取消", Fnt, Field);
            if (IsWindow) return ("待完成", V3.Orange, OrangeSoft);
            if (Active) return ("进行中", Blue, BlueSoft);
            return (IsExam || IsAI ? "待参加" : "待面试", Blue, BlueSoft);
        }
    }

    static string Format(DateTimeOffset date, string pattern) =>
        TimeZoneInfo.ConvertTime(date, Beijing.Zone).ToString(pattern, System.Globalization.CultureInfo.GetCultureInfo("zh-CN"));

    string Relative
    {
        get
        {
            var until = (Current.Start - Beijing.Now).TotalSeconds;
            if (!IsWindow && !Cancelled && !Completed && until > 0)
                return until < 86400 ? $" · 还有 {(int)(until / 3600)} 小时 {(int)(until % 3600 / 60)} 分" : $" · {(int)Math.Ceiling(until / 86400)} 天后";
            return IsWindow && !Cancelled && !Completed ? " · 截止前任选时间完成" : "";
        }
    }

    Uri? MeetingUrl => Uri.TryCreate(Current.Text("meeting_url"), UriKind.Absolute, out var url) && url.Scheme.ToLowerInvariant() is "http" or "https" ? url : null;

    (string Title, Action Run)? Primary
    {
        get
        {
            if (Cancelled || Completed) return null;
            if (IsWindow && CanEdit) return ("保存作答计划", () => _ = SavePlanAsync(false));
            if (MeetingUrl is { } url) return (IsExam ? "进入笔试" : IsAI ? "进入 AI 面试" : "进入会议", () => _ = Windows.System.Launcher.LaunchUriAsync(url));
            return null;
        }
    }

    async Task StartAsync()
    {
        if (CareerApplication.Date(_interview.Text("answer_plan_start_at")) is { } start)
        {
            _planSet = true; _planStart = start;
            if (CareerApplication.Date(_interview.Text("answer_plan_end_at")) is { } end) _planMinutes = Math.Max(1, (int)((end - start).TotalSeconds / 60));
        }
        else _planStart = _interview.Start > Beijing.Now ? _interview.Start : Beijing.Now;
        _busy = true; Render();
        try
        {
            var data = await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_interview.Id}");
            _item = new ScheduledInterview(data["session"] ?? new JsonObject());
        }
        catch (Exception) { /* 列表里的副本仍然显示 */ }
        _busy = false; Render();
    }

    void Render()
    {
        _body.Children.Clear();
        var status = Status;
        var pill = new Border { Child = Sans(status.Text, 11, status.Ink, Medium).Align(v: VerticalAlignment.Center), Padding = new Thickness(8, 0, 8, 0), Height = 22, CornerRadius = new CornerRadius(11), Background = Brush(status.Soft) };
        // Windows 稿：弹窗不放 ×，底部「关闭」或 Esc 关闭
        _body.Children.Add(Columns(10, (Auto, Label(Current.Company + " · " + Stage, 20, Txt, Semibold).Align(v: VerticalAlignment.Center)), (Auto, pill.Align(v: VerticalAlignment.Center)), (Star(), new Border())).Frame(height: 29));
        _body.Children.Add(Sans(Current.Title + Relative, 12.5, Sub).Top(5));
        if (_busy && _item is null) _body.Children.Add(Sans("正在加载完整面试详情…", 11.5, Fnt).Top(8));
        _body.Children.Add(new V3DotStage(Art(), 160).Top(18));
        _body.Children.Add(Rows().Top(20));
        if (IsWindow) _body.Children.Add(PlanCard().Top(12));
        if (!IsWindow && Completed) _body.Children.Add(Note("复盘写在求职记录里，这一场不能再拖动改期。", Green));
        if (!IsWindow && Current.Text("mode") == "onsite" && !Completed && !Cancelled) _body.Children.Add(Note("现场面试没有会议链接，地点和时间都在求职记录里改。", Fnt));
        if (_error is { } error) _body.Children.Add(Sans(error, 12, Red).Wrap().Top(10));

        var left = HStack(10);
        if (Primary is not null || (IsWindow && CanEdit))
            left.Children.Add(HStack(4, Sans("查看求职记录", 13, Txt), Icon("arrow.right", 11, Txt)).OnTap(_openRecord, "查看求职记录"));
        var right = HStack(10);
        if (IsWindow && CanEdit && Current.Text("answer_plan_start_at").Length > 0) right.Children.Add(new V3Button("清除计划", () => _ = SavePlanAsync(true), height: 36) { Enabled = !_busy });
        right.Children.Add(new V3Button("关闭", _close, height: 36));
        if (Primary is { } primary) right.Children.Add(new V3Button(primary.Title, primary.Run, V3Button.Kind.Dark, height: 36) { Enabled = !_busy });
        else right.Children.Add(new V3Button("查看求职记录", _openRecord, V3Button.Kind.Dark, height: 36));
        var foot = Spread(left, right, 10);
        foot.Padding = new Thickness(32, 0, 32, 0);
        foot.Height = 76;
        _footer.Child = foot;
    }

    FrameworkElement Rows()
    {
        string[] interviewer = new[] { Current.Text("interviewer_name"), Current.Text("interviewer_title") }.Where(x => x.Length > 0).ToArray();
        var person = interviewer.Length == 2 ? $"{interviewer[0]}（{interviewer[1]}）" : interviewer.FirstOrDefault() ?? "暂未填写";
        var modes = new Dictionary<string, string> { ["video"] = "视频面试", ["onsite"] = "现场面试", ["phone"] = "电话面试" };
        var list = new List<(string Icon, string Label, string Value, bool Strong, bool Muted)>
        {
            IsWindow ? ("calendar", "官方时段", Format(Current.Start, "MM-dd HH:mm") + " – " + Format(Current.End, "MM-dd HH:mm"), true, false)
                : ("clock", Cancelled ? "原定时间" : "时间", Format(Current.Start, "M月d日（ddd） HH:mm") + " – " + Format(Current.End, "HH:mm"), !Cancelled, false),
            ("user", IsExam || IsTest ? "联系人" : "面试官", person, false, person == "暂未填写"),
            ("brief", "形式", modes.TryGetValue(Current.Text("mode"), out var m) ? m : "其他方式", false, false),
        };
        if (Current.Text("location").Length > 0) list.Add(("flag", "地点", Current.Text("location"), false, false));
        if (Current.Text("meeting_url").Length > 0) list.Add(("link", (KindWord == "面试" ? "会议" : KindWord) + "链接", Current.Text("meeting_url"), false, false));
        if (Cancelled && Current.Text("cancellation_reason").Length > 0) list.Add(("text", "取消原因", Current.Text("cancellation_reason"), false, false));
        var stack = new StackPanel();
        for (var index = 0; index < list.Count; index++)
        {
            var row = list[index];
            if (index > 0) stack.Children.Add(Divider());
            FrameworkElement value;
            if (row.Icon == "link" && Uri.TryCreate(row.Value, UriKind.Absolute, out var url))
                value = HStack(4, Number(row.Value, 12.5, Hex(0x2E53AA), Regular).Also(t => t.MaxWidth = 300), CareerIcon.Make("link", 12, true, Hex(0x2E53AA)))
                    .OnTap(() => _ = Windows.System.Launcher.LaunchUriAsync(url), row.Value);
            else value = Sans(row.Value, 12.5, row.Muted ? Fnt : Txt, row.Strong ? Medium : Regular).Also(t => { t.IsTextSelectionEnabled = true; t.MaxWidth = 320; });
            var line = Columns(10, (Auto, CareerIcon.Make(row.Icon, 14, true, Fnt).Align(v: VerticalAlignment.Center)), (Auto, Sans(row.Label, 12, Fnt).Align(v: VerticalAlignment.Center)),
                (Star(), value.Align(HorizontalAlignment.Right, VerticalAlignment.Center).Pad(12, 0, 0, 0)));
            line.Padding = new Thickness(16, 0, 16, 0);
            line.MinHeight = 46;
            stack.Children.Add(line);
        }
        return Card(stack, 12);
    }

    FrameworkElement PlanCard()
    {
        var text = VStack(4, Sans("我的作答计划", 13, Txt, Medium), Sans("仅作为个人时间安排，不会改变官方截止时间。", 11, Fnt));
        FrameworkElement control;
        if (CanEdit)
        {
            var local = TimeZoneInfo.ConvertTime(_planStart, Beijing.Zone);
            var date = new CalendarDatePicker { Date = local, MinDate = Current.Start, MaxDate = Current.End > Current.Start ? Current.End : Current.Start, FontSize = 12, Width = 120 };
            var time = new TimePicker { Time = local.TimeOfDay, ClockIdentifier = "24HourClock", MinWidth = 0, FontSize = 12 };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(date, "计划作答时间");
            void Push()
            {
                var day = (date.Date ?? local).Date + time.Time;
                _planStart = new DateTimeOffset(day, Beijing.Zone.GetUtcOffset(day)); _planSet = true; _error = null;
            }
            date.DateChanged += (_, _) => Push();
            time.TimeChanged += (_, _) => Push();
            var options = new[] { 30, 45, 60, 90, 120, 180, _planMinutes }.Distinct().Order().ToList();
            var minutes = new ComboBox { FontSize = 12, Width = 96, MinHeight = 0 };
            foreach (var option in options) minutes.Items.Add($"{option} 分钟");
            minutes.SelectedIndex = options.IndexOf(_planMinutes);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(minutes, "作答时长");
            minutes.SelectionChanged += (_, _) => { if (minutes.SelectedIndex >= 0) _planMinutes = options[minutes.SelectedIndex]; };
            control = HStack(6, date, time, minutes);
        }
        else control = Number(_planSet ? Format(_planStart, "MM-dd HH:mm") + $" · {_planMinutes} 分钟" : "未安排", 12, Sub, Regular);
        var row = Columns(12, (Star(), text.Align(v: VerticalAlignment.Center)), (Auto, control.Align(v: VerticalAlignment.Center)));
        row.Padding = new Thickness(16, 0, 16, 0);
        row.MinHeight = 64;
        return Card(row, 12);
    }

    static FrameworkElement Note(string text, Color tone) =>
        HStack(8, new Ellipse { Width = 6, Height = 6, Fill = Brush(tone) }, Sans(text, 11.5, Sub)).Top(16);

    /// <summary>`ScheduleArt`：一张日期卡与一张按阶段类型的时段卡。</summary>
    FrameworkElement Art()
    {
        var local = TimeZoneInfo.ConvertTime(Current.Start, Beijing.Zone);
        var date = new Border
        {
            Width = 82, Height = 100, CornerRadius = new CornerRadius(10), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1),
            Child = VStack(0,
                new Border { Height = 23, Background = Brush(Txt), Child = Sans($"{local.Month} 月", 10, V3.White).Align(HorizontalAlignment.Center, VerticalAlignment.Center) },
                Number(Format(Current.Start, "dd"), 30, Txt).Frame(height: 44).Align(HorizontalAlignment.Center),
                Sans(IsWindow ? Format(Current.End, "HH:mm") + " 截止" : Format(Current.Start, "ddd HH:mm"), 10, Sub).Align(HorizontalAlignment.Center)),
        }.Elevate(8);
        var icon = Cancelled ? "flag" : Completed ? "check" : IsWindow ? "edit" : IsAI ? "spark" : IsExam ? "edit" : Current.Text("mode") == "onsite" ? "flag" : "user";
        var kind = Cancelled ? "已取消" : Completed ? "已完成" : IsWindow ? (IsTest ? "在线测评" : "作答窗口") : IsAI ? "AI 面试" : IsExam ? "笔试" : Current.Text("mode") == "onsite" ? "现场面试" : "视频面试";
        var slot = VStack(6,
            HStack(7, CareerIcon.Make(icon, 14, true, Status.Ink), Sans(kind, 11, Txt, Medium)),
            Sans(IsWindow ? Format(Current.Start, "MM-dd") + " 开放 · " + Format(Current.End, "MM-dd") + " 截止" : Format(Current.Start, "HH:mm") + " – " + Format(Current.End, "HH:mm"), 10, Fnt));
        if (IsWindow)
        {
            var total = Math.Max(1, (Current.End - Current.Start).TotalSeconds);
            var ratio = Math.Min(1, Math.Max(0, (Beijing.Now - Current.Start).TotalSeconds / total));
            slot.Children.Add(Layer(Fill(Field, 2, 120, 4), Fill(V3.Orange, 2, 120 * ratio, 4).Align(HorizontalAlignment.Left)).Align(HorizontalAlignment.Left));
            slot.Children.Add(Sans(Current.End > Beijing.Now ? $"还剩 {Math.Max(1, (int)Math.Ceiling((Current.End - Beijing.Now).TotalSeconds / 86400))} 天" : "已截止", 10, Sub));
        }
        var slotCard = new Border { Child = slot, Padding = new Thickness(14), MinWidth = 140, CornerRadius = new CornerRadius(10), Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1) };
        var art = HStack(18, date, slotCard).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(art, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return art;
    }

    async Task SavePlanAsync(bool clear)
    {
        if (!CanEdit || _busy) return;
        var end = _planStart.AddMinutes(_planMinutes);
        if (!clear && (_planStart < Current.Start || end > Current.End)) { _error = "作答计划必须完整落在官方开放时间内。"; Render(); return; }
        _busy = true; _error = null; Render();
        try
        {
            static string Iso(DateTimeOffset date) => date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture);
            var body = new JsonObject
            {
                ["base_lock_version"] = Current.Raw["lock_version"]?.DeepClone() ?? 1,
                ["answer_plan_start_at"] = clear ? null : Iso(_planStart),
                ["answer_plan_end_at"] = clear ? null : Iso(end),
            };
            await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{Current.Id}/answer-plan", "PUT", null, body);
            _busy = false;
            _changed();
            return;
        }
        catch (ApiException error) { _error = error.Status == System.Net.HttpStatusCode.Conflict ? $"记录已更新，请关闭后刷新再试（{error.Code}）。" : $"保存失败（{error.Code}）。"; }
        catch (Exception) { _error = "连接失败，作答计划尚未确认保存。"; }
        _busy = false; Render();
    }
}

/// <summary>
/// 改期 / 作答计划 / 完成 / 取消 / 编辑一场安排，对应 Mac `ScheduleSessionForm`（560×560）。请求体首次提交后冻结，重试复用；
/// 400、409、422（不含 `INTERVIEW_EDIT_CONFLICT`）时解冻以便修改后重提。
/// </summary>
sealed class ScheduleSessionForm : UserControl
{
    readonly ScheduleAction _action;
    readonly IReadOnlyList<ScheduledInterview> _interviews;
    readonly Action _completed, _close;
    readonly StackPanel _content = new() { Spacing = 16, Padding = new Thickness(24) };
    readonly Border _footer = new() { BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 1, 0, 0) };
    readonly TextBlock _title = Label("", 20, Txt, Semibold);
    ScheduledInterview? _item;
    string _kind = "detail";
    DateTimeOffset _start, _end;
    string _reason = "", _mode = "video", _meeting = "", _location = "", _interviewer = "", _interviewerTitle = "", _note = "", _questions = "", _review = "", _improvement = "";
    bool _removePlan, _allowConflict, _busy;
    string? _failure;
    JsonObject? _frozen;

    static readonly Dictionary<string, string> Headings = new()
    {
        ["detail"] = "面试安排", ["reschedule"] = "确认改期", ["answer-plan"] = "个人作答计划", ["complete"] = "完成面试", ["cancel"] = "取消安排", ["edit"] = "编辑安排",
    };

    ScheduleSessionForm(ScheduleAction action, IReadOnlyList<ScheduledInterview> interviews, Action completed, Action close)
    {
        _action = action; _interviews = interviews; _completed = completed; _close = close;
        var head = new Border { Child = _title };
        head.Padding = new Thickness(28, 26, 28, 16);
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
        grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
        grid.Children.Add(head);
        var scroll = new ScrollViewer { Content = _content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroll, 1); grid.Children.Add(scroll);
        Grid.SetRow(_footer, 2); grid.Children.Add(_footer);
        Content = grid;
        Loaded += async (_, _) => await StartAsync();
        Render();
    }

    public static void Show(XamlRoot root, ScheduleAction action, IReadOnlyList<ScheduledInterview> interviews, Action completed) =>
        V3Overlay.Show(root, close =>
        {
            var frame = V3Dialog.Frame(new ScheduleSessionForm(action, interviews, () => { close(); completed(); }, close), 560);
            frame.Height = 560;
            return frame;
        }, dismissible: true);

    static string Display(DateTimeOffset date) => TimeZoneInfo.ConvertTime(date, Beijing.Zone).ToString("M月d日 HH:mm", System.Globalization.CultureInfo.InvariantCulture);

    async Task StartAsync()
    {
        _item = null; _kind = _action.Kind; _start = _action.Start; _end = _action.End; _busy = true; Render();
        try
        {
            var data = await App.Session.Api.CareerRequestAsync($"/api/interview-sessions/{_action.Interview!.Id}");
            _item = new ScheduledInterview(data["session"] ?? new JsonObject());
            Fill();
        }
        catch (Exception error) { _failure = Explain(error); }
        _busy = false; Render();
    }

    void Fill()
    {
        if (_item is not { } item) return;
        _mode = item.Text("mode"); _meeting = item.Text("meeting_url"); _location = item.Text("location");
        _interviewer = item.Text("interviewer_name"); _interviewerTitle = item.Text("interviewer_title"); _note = item.Text("preparation_note");
        _questions = item.Text("questions_markdown"); _review = item.Text("review_summary"); _improvement = item.Text("improvement_markdown");
    }

    void Begin(string command)
    {
        if (_item is not { } item) return;
        _kind = command; _failure = null; _frozen = null; _removePlan = false;
        _start = CareerApplication.Date(item.Text(command == "answer-plan" ? "answer_plan_start_at" : "start_at")) ?? item.Start;
        _end = CareerApplication.Date(item.Text(command == "answer-plan" ? "answer_plan_end_at" : "end_at")) ?? item.End;
        Fill();
        Render();
    }

    void Render()
    {
        _title.Text = Headings.TryGetValue(_kind, out var heading) ? heading : "面试安排";
        _content.Children.Clear();
        var locked = _frozen is not null;
        if (_item is { } item)
        {
            _content.Children.Add(Label(item.Company + " · " + item.Title, 15, Txt, Semibold));
            _content.Children.Add(Label(item.Label + " · " + item.Status(Beijing.Now), 13, Fnt));
            _content.Children.Add(Label(item.OpenWindow ? "开放作答窗口" : "固定面试场次", 12, Fnt));
            if (_kind == "detail")
            {
                var modes = new Dictionary<string, string> { ["video"] = "视频面试", ["onsite"] = "现场面试", ["phone"] = "电话面试", ["other"] = "其他方式" };
                _content.Children.Add(Label(Display(item.Start) + " — " + Display(item.End), 13));
                _content.Children.Add(Label(modes.TryGetValue(item.Text("mode"), out var m) ? m : "其他方式", 13));
                if (item.Text("meeting_url").Length > 0) _content.Children.Add(Selectable("会议 / 作答链接：" + item.Text("meeting_url")));
                if (item.Text("location").Length > 0) _content.Children.Add(Label("地点：" + item.Text("location"), 13).Wrap());
                if (item.Text("interviewer_name").Length > 0) _content.Children.Add(Label("面试官：" + item.Text("interviewer_name") + " " + item.Text("interviewer_title"), 13));
                if (item.Text("preparation_note").Length > 0) _content.Children.Add(Selectable("准备备注：" + item.Text("preparation_note")));
                if (item.OpenWindow && item.Timed is { } plan) _content.Children.Add(Label("个人作答计划：" + Display(plan.Start) + " — " + Display(plan.End), 13));
                foreach (var key in new[] { "questions_markdown", "review_summary", "improvement_markdown" })
                    if (item.Text(key).Length > 0) _content.Children.Add(Selectable(item.Text(key)));
                if (item.Editable)
                {
                    var row = HStack(8, SystemButton("编辑信息", () => Begin("edit")));
                    if (!item.OpenWindow) row.Children.Add(SystemButton("改期", () => Begin("reschedule")));
                    if (item.OpenWindow) row.Children.Add(SystemButton("作答计划", () => Begin("answer-plan")));
                    row.Children.Add(SystemButton("完成", () => Begin("complete")));
                    row.Children.Add(SystemButton("取消安排", () => Begin("cancel")));
                    _content.Children.Add(row);
                }
            }
            else if (_kind is "reschedule" or "answer-plan")
            {
                if (_kind == "answer-plan")
                {
                    var clear = new CheckBox { Content = "清除个人作答计划", IsChecked = _removePlan, IsEnabled = !locked, FontSize = 13 };
                    clear.Click += (_, _) => { _removePlan = clear.IsChecked == true; Render(); };
                    _content.Children.Add(clear);
                }
                if (!_removePlan)
                {
                    _content.Children.Add(HStack(8, Label("开始时间", 13), DateTime(_start, v => { _start = v; Render(); }, !locked)));
                    _content.Children.Add(HStack(8, Label("结束时间", 13), DateTime(_end, v => { _end = v; Render(); }, !locked)));
                }
                if (_kind == "reschedule")
                {
                    var conflicts = ScheduleCalendar.Conflicts(_interviews, item.Id, _start, _end);
                    if (conflicts.Count > 0)
                    {
                        _content.Children.Add(Label($"与 {conflicts.Count} 场安排重叠，请确认时间。", 13, Hex(0xFF9500)));
                        foreach (var conflict in conflicts) _content.Children.Add(Label(conflict.Caption, 12));
                    }
                    var allow = new CheckBox { Content = "确认仍保存有时间冲突的安排", IsChecked = _allowConflict, IsEnabled = !locked, FontSize = 13 };
                    allow.Click += (_, _) => _allowConflict = allow.IsChecked == true;
                    _content.Children.Add(allow);
                }
            }
            else if (_kind == "edit")
            {
                var modes = new (string, string)[] { ("video", "视频"), ("onsite", "现场"), ("phone", "电话"), ("other", "其他") };
                var picker = new ComboBox { FontSize = 13, MinHeight = 0, IsEnabled = !locked };
                foreach (var (_, title) in modes) picker.Items.Add(title);
                picker.SelectedIndex = Math.Max(0, Array.FindIndex(modes, x => x.Item1 == _mode));
                picker.SelectionChanged += (_, _) => { if (picker.SelectedIndex >= 0) _mode = modes[picker.SelectedIndex].Item1; };
                _content.Children.Add(HStack(8, Label("面试方式", 13), picker));
                _content.Children.Add(Field("会议或作答链接", _meeting, v => _meeting = v, locked));
                _content.Children.Add(Field("地点", _location, v => _location = v, locked));
                _content.Children.Add(Field("面试官姓名", _interviewer, v => _interviewer = v, locked));
                _content.Children.Add(Field("面试官职位", _interviewerTitle, v => _interviewerTitle = v, locked));
                _content.Children.Add(Field("准备备注", _note, v => _note = v, locked));
            }
            else if (_kind == "complete")
            {
                _content.Children.Add(Label("确认标记完成；可同时记录面试问题和复盘。", 13));
                _content.Children.Add(Field("面试问题（可选）", _questions, v => _questions = v, locked));
                _content.Children.Add(Field("复盘总结（可选）", _review, v => _review = v, locked));
                _content.Children.Add(Field("改进计划（可选）", _improvement, v => _improvement = v, locked));
            }
            else if (_kind == "cancel")
            {
                _content.Children.Add(Label("确认取消这场安排，历史记录仍会保留。", 13));
                _content.Children.Add(Field("取消原因（可选）", _reason, v => _reason = v, locked));
            }
        }
        if (_failure is { } failure) _content.Children.Add(Selectable(failure, Red));

        var left = HStack(10);
        if (_kind != "detail" && _action.Kind == "detail") left.Children.Add(new CareerAction("返回详情", () => { _kind = "detail"; _frozen = null; Render(); }, CareerAction.Kind.Text) { Enabled = !_busy });
        var right = HStack(10, new V3Button("取消", _close, height: 36) { Enabled = !_busy });
        if (_kind != "detail") right.Children.Add(new V3Button(_busy ? "保存中…" : "确认保存", () => _ = SaveAsync(), V3Button.Kind.Dark, height: 36) { Enabled = !_busy && _item is not null });
        var foot = Spread(left, right, 10);
        foot.Padding = new Thickness(28, 0, 28, 0);
        foot.Height = 76;
        _footer.Child = foot;
    }

    static TextBlock Selectable(string text, Color? color = null) => Label(text, 13, color).Wrap().Also(t => t.IsTextSelectionEnabled = true);

    static Button SystemButton(string title, Action action)
    {
        var button = new Button { Content = title, FontSize = 13 };
        button.Click += (_, _) => action();
        return button;
    }

    /// <summary>Mac `field(_:_:)`：12px 标题 + 2–6 行的圆角输入框。</summary>
    static FrameworkElement Field(string label, string value, Action<string> changed, bool locked)
    {
        var box = new TextBox { Text = value, PlaceholderText = label, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 2 * 20 + 12, MaxHeight = 6 * 20 + 12, FontSize = 13, IsEnabled = !locked };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, label);
        box.TextChanged += (_, _) => changed(box.Text);
        return VStack(6, Label(label, 12), box);
    }

    static FrameworkElement DateTime(DateTimeOffset value, Action<DateTimeOffset> changed, bool enabled)
    {
        var local = TimeZoneInfo.ConvertTime(value, Beijing.Zone);
        var date = new CalendarDatePicker { Date = local, FontSize = 13, IsEnabled = enabled };
        var time = new TimePicker { Time = local.TimeOfDay, ClockIdentifier = "24HourClock", MinWidth = 0, IsEnabled = enabled };
        void Push()
        {
            var day = (date.Date ?? local).Date + time.Time;
            changed(new DateTimeOffset(day, Beijing.Zone.GetUtcOffset(day)));
        }
        date.DateChanged += (_, _) => Push();
        time.TimeChanged += (_, _) => Push();
        return HStack(8, date, time);
    }

    async Task SaveAsync()
    {
        if (_item is not { Editable: true } item || _busy) return;
        if (_kind is "reschedule" or "answer-plan" && !_removePlan && _end <= _start) { _failure = "结束时间须晚于开始时间。"; Render(); return; }
        if (_kind == "answer-plan" && !_removePlan && (_start < item.Start || _end > item.End)) { _failure = "个人作答计划必须位于开放窗口内。"; Render(); return; }
        _busy = true; _failure = null; Render();
        try
        {
            if (_frozen is null)
            {
                static string Iso(DateTimeOffset date) => date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture);
                static JsonNode? Optional(string value) => value.Length == 0 ? null : value;
                var body = new JsonObject { ["base_lock_version"] = item.Raw["lock_version"]?.DeepClone() ?? 1 };
                switch (_kind)
                {
                    case "reschedule":
                        body["start_at"] = Iso(_start); body["end_at"] = Iso(_end); body["timezone"] = JobsBoardView.TimeZoneId(); body["allow_conflict"] = _allowConflict;
                        break;
                    case "answer-plan":
                        body["answer_plan_start_at"] = _removePlan ? null : Iso(_start); body["answer_plan_end_at"] = _removePlan ? null : Iso(_end);
                        break;
                    case "complete":
                        body["questions_markdown"] = _questions; body["review_summary"] = _review; body["improvement_markdown"] = _improvement;
                        break;
                    case "cancel": body["reason"] = Optional(_reason); break;
                    case "edit":
                        body["mode"] = _mode; body["meeting_url"] = Optional(_meeting); body["location"] = Optional(_location);
                        body["interviewer_name"] = Optional(_interviewer); body["interviewer_title"] = Optional(_interviewerTitle); body["preparation_note"] = Optional(_note);
                        break;
                    default: throw new InvalidDataException();
                }
                _frozen = body;
            }
            var path = $"/api/interview-sessions/{item.Id}" + (_kind == "edit" ? "" : $"/{_kind}");
            await App.Session.Api.CareerRequestAsync(path, _kind is "edit" or "answer-plan" ? "PUT" : "POST", null, _frozen.DeepClone());
            _busy = false;
            _completed();
            return;
        }
        catch (Exception error)
        {
            if (error is ApiException api && (int)api.Status is 400 or 422 or 409 && api.Code != "INTERVIEW_EDIT_CONFLICT") _frozen = null;
            _failure = Explain(error);
        }
        _busy = false; Render();
    }

    static string Explain(Exception error)
    {
        if (error is ApiException { Status: System.Net.HttpStatusCode.Unauthorized }) return "登录已失效，请重新登录。";
        if (error is ApiException api)
            return api.Status == System.Net.HttpStatusCode.Conflict ? $"时间或版本冲突（{api.Code}）。请确认时间；若记录已变化，请关闭并刷新。" : $"保存失败（{api.Code}），输入已保留。";
        return "连接失败，结果尚未确认。重试会保留原版本，不会覆盖其他修改。";
    }
}
