using System.Text.Json.Nodes;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>Mac `ScheduleAction`：打开新建或改期等表单的一次请求。</summary>
sealed record ScheduleAction(string Kind, ScheduledInterview? Interview, DateTimeOffset Start, DateTimeOffset End);

/// <summary>
/// 05.1 / 05.2 面试日程，对应 Mac `InterviewScheduleView.swift`（Web `ScheduleView`）：SCHEDULE 页头带日期跳转、月 / 周日历，
/// 以及 05.2b 日程详情弹窗。Web 已不再显示「接下来」列表；日历撑满页面剩余高度。
/// </summary>
public sealed partial class InterviewScheduleView : UserControl
{
    const double HourHeight = 64;
    const double Gutter = 52;

    readonly Action _requireAccount;
    readonly Grid _root = new();
    DateTimeOffset _anchor = Beijing.Now;
    string _mode = "week";
    List<ScheduledInterview> _interviews = [];
    List<CareerApplication> _applications = [];
    ScheduleAction? _pending;
    string? _selectedId;
    CareerApplication? _record;
    bool _loading, _showAllWindows, _active;
    string? _failure;
    int _generation;

    static TimeZoneInfo Zone => Beijing.Zone;
    static string Account => App.Session.Phase == Core.Session.SessionViewModel.SessionPhase.SignedIn ? App.Session.User?.Id ?? "" : "";

    public InterviewScheduleView(Action requireAccount)
    {
        _requireAccount = requireAccount;
        Content = _root;
        // ⌘N → Ctrl+N：在当前日期 9:00 新建
        var shortcut = new KeyboardAccelerator { Key = Windows.System.VirtualKey.N, Modifiers = Windows.System.VirtualKeyModifiers.Control };
        shortcut.Invoked += (_, e) => { e.Handled = true; Create(At(StartOfDay(_anchor), 9 * 60)); };
        KeyboardAccelerators.Add(shortcut);
        Loaded += async (_, _) => { _active = true; await LoadAsync(); };
        Unloaded += (_, _) => _active = false;
        Render();
    }

    // MARK: 日期工具

    static DateTime Local(DateTimeOffset date) => TimeZoneInfo.ConvertTime(date, Zone).DateTime;
    static DateTimeOffset Resolve(DateTime local) => new(local, Zone.GetUtcOffset(local));
    static DateTimeOffset StartOfDay(DateTimeOffset date) => Resolve(Local(date).Date);
    static DateTimeOffset Plus(DateTimeOffset date, int days) => Resolve(Local(date).AddDays(days));
    static DateTimeOffset At(DateTimeOffset day, int minute) => Resolve(Local(day).Date.AddMinutes(minute));
    static bool IsToday(DateTimeOffset date) => Local(date).Date == Local(Beijing.Now).Date;
    static string Format(DateTimeOffset date, string pattern) => Local(date).ToString(pattern, System.Globalization.CultureInfo.GetCultureInfo("zh-CN"));

    DateTimeOffset Week => ScheduleCalendar.WeekStart(_anchor, Zone);
    DateTimeOffset Month => Resolve(new DateTime(Local(_anchor).Year, Local(_anchor).Month, 1));
    List<ScheduledInterview> Visible => _interviews.Where(x => x.Text("status") != "cancelled").ToList();
    DateTimeOffset PeriodStart => _mode == "month" ? Month : Week;
    DateTimeOffset PeriodEnd => _mode == "month" ? Resolve(Local(Month).AddMonths(1)) : Plus(Week, 7);

    /// <summary>`scheduleHeadTitle`：2026 年 9 月 / 9 月 21 日 – 27 日。</summary>
    string Heading
    {
        get
        {
            if (_mode == "month") { var m = Local(Month); return $"{m.Year} 年 {m.Month} 月"; }
            DateTime from = Local(Week), to = Local(Plus(Week, 6));
            return from.Month == to.Month ? $"{from.Month} 月 {from.Day} 日 – {to.Day} 日" : $"{from.Month} 月 {from.Day} 日 – {to.Month} 月 {to.Day} 日";
        }
    }

    string Subtitle
    {
        get
        {
            if (Account.Length == 0) return "游客模式 · 登录后管理面试安排";
            var count = Visible.Count(x => x.Overlaps(PeriodStart, PeriodEnd));
            var today = Visible.Count(x => !x.OpenWindow && IsToday(x.Start));
            return $"{(_mode == "month" ? "本月" : "本周")} {count} 个日程" + (today > 0 ? $" · 今天 {today} 场面试" : "");
        }
    }

    // MARK: 布局

    void Render()
    {
        _root.Children.Clear();
        if (_record is { } record)
        {
            _root.Children.Add(new CareerApplicationDetailView(record, () => { _record = null; Render(); _ = LoadAsync(); }, (kind, app) =>
            {
                var next = CareerStage.NextStages(app);
                CareerForm.Show(XamlRoot, new JobAction(kind, app)
                {
                    Stage = kind == "apply" ? "screening" : kind == "schedule-current" ? app.Stage : next.FirstOrDefault(s => s == "interview") ?? next.FirstOrDefault() ?? "screening",
                    Label = kind == "stage" ? JobsBoardView.RoundLabel(app.Raw.Integer("current_round_no") + 1) : app.StageLabel,
                    Round = kind == "schedule-current" ? app.Raw.Integer("current_round_no") : null,
                }, _applications, () => _ = LoadAsync());
            }));
            return;
        }
        var page = new Grid();
        page.RowDefinitions.Add(new RowDefinition { Height = Auto });
        page.RowDefinitions.Add(new RowDefinition { Height = Auto });
        page.RowDefinitions.Add(new RowDefinition { Height = Star() });
        page.Children.Add(Head().Pad(0, 0, 0, 20));
        if (_failure is { } failure)
        {
            var row = HStack(10, Sans(failure, 12.5, Red), new CareerAction("重试", () => _ = LoadAsync(), CareerAction.Kind.Link)).Pad(0, 0, 0, 12);
            Grid.SetRow(row, 1); page.Children.Add(row);
        }
        var calendar = new Grid { MinHeight = 280, Children = { _mode == "month" ? MonthView() : WeekView() } };
        if (_loading) calendar.Children.Add(new ProgressRing { Width = 16, Height = 16, IsActive = true, Margin = new Thickness(6), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top });
        Grid.SetRow(calendar, 2); page.Children.Add(calendar);
        // Web `.career-v3-page` 底部留 24，日历撑满到这里
        var host = new Border { Child = page, Padding = new Thickness(32, 52, 32, 24) };
        host.SizeChanged += (_, e) => { var gutter = Math.Max(0, V3Page.Gutter(e.NewSize.Width)); host.Padding = new Thickness(gutter, 52, gutter, 24); };
        _root.Children.Add(host);
    }

    // MARK: 页头

    FrameworkElement Head()
    {
        var eyebrow = Sans(string.Join(" · ", ["SCHEDULE", $"{Local(PeriodStart).Year} 年", _mode == "month" ? "月视图" : "周视图"]), 12, Fnt, Medium).Frame(height: 18);
        var chevron = Icon("chevron.down", 12, Fnt).Also(i => i.FontWeight = Medium);
        FrameworkElement title = null!;
        title = HStack(8, Serif(Heading, 28), chevron).Also(s => { s.Height = 36; s.Background = Brush(Clear); }).Top(8)
            .OnTap(() => V3Popover.Show(title, DatePickerPopover(), padding: 16), $"{Heading}，选择其他日期");
        var left = VStack(0, eyebrow, title, Sans(Subtitle, 14, Sub).Frame(height: 22).Top(6));
        var mode = new V3Segmented<string>([("month", "月"), ("week", "周")], _mode, segmentWidth: 52, fontSize: 11.5).Tip("日程视图");
        mode.Changed += value => { _mode = value; Render(); };
        var nav = HStack(4,
            NavButton(Icon("chevron.left", 11, Txt).Also(i => i.FontWeight = Semibold), true, "上一周期", () => Shift(-1)),
            NavButton(Sans("今天", 12.5, Txt), false, "今天", () => { _anchor = Beijing.Now; Render(); }),
            NavButton(Icon("chevron.right", 11, Txt).Also(i => i.FontWeight = Semibold), true, "下一周期", () => Shift(1)));
        var right = HStack(8, mode, nav).Top(32);
        return Spread(left, right, 24, VerticalAlignment.Top);
    }

    FrameworkElement DatePickerPopover()
    {
        var view = new CalendarView { SelectionMode = CalendarViewSelectionMode.Single, Width = 300 - 32 };
        view.SelectedDates.Add(_anchor);
        view.SetDisplayDate(_anchor);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(view, _mode == "month" ? "选择月份" : "选择周");
        view.SelectedDatesChanged += (_, e) =>
        {
            if (e.AddedDates.Count == 0) return;
            var picked = e.AddedDates[0];
            _anchor = Resolve(picked.Date.Add(Local(_anchor).TimeOfDay));
            Render();
        };
        return view;
    }

    /// <summary>`.interview-calendar-nav-arrows`（Mac `ScheduleNavStyle`）：30 的描边方块与「今天」胶囊，12.5px、圆角 7。</summary>
    static FrameworkElement NavButton(FrameworkElement content, bool square, string label, Action action)
    {
        var button = new Border
        {
            Child = content.Align(HorizontalAlignment.Center, VerticalAlignment.Center), Height = 30, MinWidth = 30, CornerRadius = new CornerRadius(7),
            Background = Brush(V3.White), BorderBrush = Brush(Cl), BorderThickness = new Thickness(1), Padding = new Thickness(square ? 0 : 10, 0, square ? 0 : 10, 0),
        };
        if (square) button.Width = 30;
        button.PointerPressed += (_, _) => button.Background = Brush(Field);
        button.PointerReleased += (_, _) => button.Background = Brush(V3.White);
        button.PointerExited += (_, _) => button.Background = Brush(V3.White);
        return button.OnTap(action, label);
    }

    void Shift(int amount)
    {
        var local = Local(_anchor);
        _anchor = Resolve(_mode == "month" ? local.AddMonths(amount) : local.AddDays(7 * amount));
        Render();
    }

    void Create(DateTimeOffset start, DateTimeOffset? end = null)
    {
        var value = new ScheduleAction("create", null, start, end ?? start.AddSeconds(1800));
        if (Account.Length == 0) { _pending = value; _requireAccount(); }
        else Present(value);
    }

    void Present(ScheduleAction value)
    {
        if (value.Kind == "create")
            CareerForm.Show(XamlRoot, new JobAction("schedule", null) { Start = value.Start, End = value.End }, _applications, () => _ = LoadAsync());
        else
            ScheduleSessionForm.Show(XamlRoot, value, _interviews, () => _ = LoadAsync());
    }

    void Open(ScheduledInterview item)
    {
        _selectedId = item.Id;
        var detail = _interviews.FirstOrDefault(x => x.Id == item.Id) ?? item;
        ScheduleDetailDialog.Show(XamlRoot, detail, () => _ = LoadAsync(), () =>
        {
            _record = _applications.FirstOrDefault(a => a.Id == detail.ApplicationId);
            Render();
        });
        Render();
    }

    void Move(ScheduledInterview item, string kind, DateTimeOffset start, DateTimeOffset end) => Present(new ScheduleAction(kind, item, start, end));

    /// <summary>Web `INTERVIEW_CALENDAR_COLORS`：没设颜色的三面显示紫色；月视图把灰色日程分散到调色板。</summary>
    internal static Color ColorOf(ScheduledInterview item, bool month = false)
    {
        var key = item.Text("calendar_color");
        if (item.Text("stage_type") == "interview" && item.Raw.Integer("round_no") == 3 && key == "gray") key = "purple";
        if (month && (key == "gray" || key.Length == 0))
        {
            string[] fallback = ["red", "orange", "green", "blue", "purple"];
            // Swift `unicodeScalars.reduce`：按 Unicode 标量求和
            var sum = item.Id.EnumerateRunes().Sum(r => r.Value);
            key = fallback[sum % fallback.Length];
        }
        return Hex(key switch
        {
            "red" => 0xD64545u, "orange" => 0xD9822Bu, "yellow" => 0xC4A236u, "green" => 0x3D8B67u, "blue" => 0x3F6FD8u, "purple" => 0x8B6BC8u, "gray" => 0x96968Fu,
            _ => 0x3F6FD8u,
        });
    }

    /// <summary>`meetingLabel`。</summary>
    internal static string MeetingLabel(JsonNode raw)
    {
        if (raw.Text("mode") == "onsite") return string.Join(" · ", new[] { raw.Text("location"), "现场" }.Where(x => x.Length > 0));
        var url = raw.Text("meeting_url");
        var platform = url.Contains("feishu.cn") || url.Contains("larksuite.com") ? "飞书会议" : url.Contains("meeting.tencent.com") ? "腾讯会议" : url.Contains("nowcoder.com") ? "牛客网" : null;
        var mode = raw.Text("mode") == "video" ? "视频" : raw.Text("mode") == "phone" ? "电话" : "其他方式";
        return string.Join(" · ", new[] { mode, platform }.OfType<string>());
    }

    // MARK: 月视图

    List<ScheduledInterview> Items(DateTimeOffset day)
    {
        var start = StartOfDay(day);
        return Visible.Where(x => !x.OpenWindow && x.Overlaps(start, Plus(start, 1))).OrderBy(x => x.Start).ToList();
    }

    FrameworkElement MonthView()
    {
        var days = ScheduleCalendar.MonthDays(_anchor, Zone);
        var rows = Math.Max(1, days.Count / 7);
        var header = new Grid { Height = 32 };
        string[] names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];
        for (var i = 0; i < 7; i++)
        {
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            // 星期行最小 32 高，标签 24 高、居中，字在标签里下移 2
            var name = Sans(names[i], 10.5, Fnt).Pad(8, 2, 8, 0).Frame(height: 24).Align(HorizontalAlignment.Stretch, VerticalAlignment.Center);
            Grid.SetColumn(name, i); header.Children.Add(name);
        }
        var head = new Border { Child = header, BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 0, 0, 1) };
        var body = new Grid();
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        body.Children.Add(scroll);
        body.SizeChanged += (_, e) =>
        {
            var height = Math.Max(84, e.NewSize.Height / rows);
            var stack = new StackPanel();
            for (var row = 0; row < rows; row++)
            {
                var line = new Grid();
                for (var column = 0; column < 7; column++)
                {
                    line.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
                    var cell = MonthCell(days[row * 7 + column], height);
                    Grid.SetColumn(cell, column); line.Children.Add(cell);
                }
                stack.Children.Add(new Border { Child = line, BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 0, 0, 1) });
            }
            scroll.Content = stack;
            scroll.VerticalScrollMode = height * rows <= e.NewSize.Height + 1 ? ScrollMode.Disabled : ScrollMode.Enabled;
        };
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = Star() });
        grid.Children.Add(head);
        Grid.SetRow(body, 1); grid.Children.Add(body);
        return grid;
    }

    FrameworkElement MonthCell(DateTimeOffset day, double height)
    {
        var events = Items(day);
        var today = IsToday(day);
        var inside = Local(day).Month == Local(Month).Month && Local(day).Year == Local(Month).Year;
        var capacity = Math.Max(1, (int)((height - 36) / 24));
        var shown = events.Count > capacity ? events.Take(capacity - 1).ToList() : events;
        var number = new Border
        {
            Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Background = Brush(today ? Blue : Clear),
            Child = Number($"{Local(day).Day}", 10.5, today ? V3.White : inside ? Txt : Fnt2, today ? Semibold : Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        }.OnTap(() => { _anchor = day; _mode = "week"; Render(); }, Format(day, "M月d日") + "，查看这一周");
        var top = new Grid { Height = 22, Margin = new Thickness(0, 6, 0, 0), Children = { number.Align(HorizontalAlignment.Left) } };
        if (events.Count > shown.Count)
        {
            FrameworkElement more = null!;
            more = Sans($"另有 {events.Count - shown.Count} 项", 10, Fnt).Pad(6, 0, 6, 0).Frame(height: 20).Align(HorizontalAlignment.Right, VerticalAlignment.Center)
                .OnTap(() => V3Popover.Show(more, OverflowList(day, events), padding: 8), $"另有 {events.Count - shown.Count} 项");
            top.Children.Add(more);
        }
        var stack = new StackPanel { Spacing = 8, Children = { top } };
        foreach (var item in shown) stack.Children.Add(MonthEvent(item).Pad(0, 0, 5, 0));
        var cell = new Border
        {
            Child = stack, Padding = new Thickness(4, 0, 0, 4), Height = height, Background = Brush(today ? Alpha(Blue, 0.05) : Clear),
            BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(1, 0, 0, 0), AllowDrop = true,
        };
        cell.DoubleTapped += (_, e) => { e.Handled = true; Create(At(day, 9 * 60)); };
        cell.DragOver += (_, e) => e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Move;
        cell.Drop += async (_, e) =>
        {
            if (!e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text)) return;
            var id = await e.DataView.GetTextAsync();
            if (_interviews.FirstOrDefault(x => x.Id == id) is not { Editable: true, OpenWindow: false } item) return;
            var start = Local(item.Start);
            var from = At(day, start.Hour * 60 + start.Minute);
            Move(item, "reschedule", from, from + (item.End - item.Start));
        };
        return cell;
    }

    FrameworkElement MonthEvent(ScheduledInterview item)
    {
        var row = Columns(5,
            (Auto, new Ellipse { Width = 5, Height = 5, Fill = Brush(ColorOf(item, month: true)) }),
            (Auto, Sans(item.Company, 11, Txt, Medium)),
            (Star(), Sans(item.Label, 11, Sub)),
            (Auto, Number(Format(item.Start, "HH:mm"), 10, Fnt, Regular)));
        foreach (var child in row.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
        var chip = new Border
        {
            Child = row, Padding = new Thickness(6, 0, 6, 0), Height = 20, CornerRadius = new CornerRadius(5), Background = Brush(Field),
            BorderBrush = Brush(_selectedId == item.Id ? Txt : Clear), BorderThickness = new Thickness(1.5),
        };
        ToolTipService.SetToolTip(chip, item.Company + " " + item.Title + " " + item.Label);
        chip.DoubleTapped += (_, e) => { e.Handled = true; Open(item); };
        chip.Tapped += (_, e) => { e.Handled = true; _selectedId = item.Id; Render(); };
        if (item.Editable)
        {
            chip.CanDrag = true;
            chip.DragStarting += (_, e) => e.Data.SetText(item.Id);
        }
        return chip;
    }

    FrameworkElement OverflowList(DateTimeOffset day, List<ScheduledInterview> events)
    {
        var stack = new StackPanel { Spacing = 2, Width = 256 - 16 };
        stack.Children.Add(Sans(Format(day, "M月d日 · ddd"), 12, Fnt, Medium).Pad(8, 6, 8, 8));
        foreach (var item in events)
        {
            var row = Columns(10,
                (Auto, Fill(ColorOf(item, month: true), 2, 3, 30).Align(v: VerticalAlignment.Top)),
                (Star(), VStack(3, Sans(item.Company, 12, Txt, Semibold), Sans(Format(item.Start, "HH:mm") + "–" + Format(item.End, "HH:mm") + " · " + item.Label, 11, Fnt))));
            row.Padding = new Thickness(8);
            row.Background = Brush(Clear);
            stack.Children.Add(row.OnTap(() => Open(item), item.Company));
        }
        return stack;
    }

    async Task LoadAsync()
    {
        var generation = ++_generation;
        if (Account.Length == 0) { _loading = false; _failure = null; Render(); return; }
        // 登录后接着做登录前要做的新建（Mac `onChange(of: account)` 的 pending）
        if (_pending is { } pending) { _pending = null; Present(pending); }
        _loading = true; _failure = null; Render();
        try
        {
            var items = new List<JsonNode>(); var cursor = ""; var seen = new HashSet<string>();
            do
            {
                var query = new Dictionary<string, string> { ["limit"] = "500" };
                if (cursor.Length > 0) query["cursor"] = cursor;
                var page = await App.Session.Api.CareerRequestAsync("/api/interview-sessions", "GET", query);
                if (generation != _generation) return;
                items.AddRange(page.Items("items")); cursor = page.Text("next_cursor");
                if (cursor.Length > 0 && !seen.Add(cursor)) throw new InvalidDataException();
            } while (cursor.Length > 0);
            var jobs = new List<CareerApplication>(); cursor = ""; seen.Clear();
            do
            {
                var query = new Dictionary<string, string> { ["scope"] = "all", ["limit"] = "200" };
                if (cursor.Length > 0) query["cursor"] = cursor;
                var page = await App.Session.Api.CareerRequestAsync("/api/job-applications", "GET", query);
                if (generation != _generation) return;
                jobs.AddRange(page.Items("items").Select(x => new CareerApplication(x))); cursor = page.Text("next_cursor");
                if (cursor.Length > 0 && !seen.Add(cursor)) throw new InvalidDataException();
            } while (cursor.Length > 0);
            _interviews = items.Select(x => new ScheduledInterview(x)).ToList(); _applications = jobs;
        }
        catch (Exception)
        {
            if (generation != _generation) return;
            _failure = "排期加载失败，请检查连接或重新登录后重试。";
        }
        if (generation != _generation) return;
        _loading = false;
        if (_active) Render();
    }
}
