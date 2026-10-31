using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Shapes;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Career;

/// <summary>`InterviewScheduleView` 的周视图：星期头、全天开放窗口、24 小时时间格与日程块。</summary>
public sealed partial class InterviewScheduleView
{
    FrameworkElement WeekView()
    {
        var week = Week;
        var windows = Visible.Where(x => x.OpenWindow && x.Overlaps(week, Plus(week, 7))).OrderBy(x => x.End).ToList();
        var shownWindows = _showAllWindows ? windows : windows.Take(3).ToList();
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = Star() });

        var header = new Grid { Height = 56 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = Px(Gutter) });
        for (var index = 0; index < 7; index++)
        {
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            var day = Plus(week, index);
            var today = IsToday(day);
            // `.interview-calendar-day-header.is-week`：星期 10.5、日期 14 放在 30 的圆里，上下间距 9 − 6
            var circle = new Border
            {
                Width = 30, Height = 30, CornerRadius = new CornerRadius(15), Background = Brush(today ? Blue : Clear),
                Child = Number($"{Local(day).Day}", 14, today ? V3.White : Txt, today ? Semibold : Medium).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
            };
            var cell = VStack(3, Sans(Format(day, "ddd"), 10.5, today ? Txt : Fnt, today ? Medium : Regular).Frame(height: 13).Align(HorizontalAlignment.Center), circle)
                .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            Grid.SetColumn(cell, index + 1); header.Children.Add(cell);
        }
        grid.Children.Add(new Border { Child = header, BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 0, 0, 1) });

        if (windows.Count > 0)
        {
            var bars = new StackPanel { Spacing = 3, Padding = new Thickness(0, 4, 0, 4) };
            foreach (var item in shownWindows) bars.Children.Add(WindowBar(item, week));
            if (windows.Count > 3)
                bars.Children.Add(new Border
                {
                    Height = 20, CornerRadius = new CornerRadius(5), Background = Brush(0xEEF1F5),
                    Child = Sans(_showAllWindows ? "收起更多项目" : $"还有 {windows.Count - 3} 项待完成 · 展开查看", 10, Sub, Semibold).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
                }.OnTap(() => { _showAllWindows = !_showAllWindows; Render(); }, _showAllWindows ? "收起更多项目" : "展开查看"));
            var row = Columns(0, (Px(Gutter), Sans("全天", 10, Fnt).Pad(0, 6, 0, 0).Align(v: VerticalAlignment.Top)), (Star(), bars));
            row.MinHeight = 34;
            var allDay = new Border { Child = row, BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(0, 0, 0, 1) };
            Grid.SetRow(allDay, 1); grid.Children.Add(allDay);
        }
        var time = TimeGrid(week);
        time.MinHeight = 120;
        Grid.SetRow(time, 2); grid.Children.Add(time);
        return grid;
    }

    FrameworkElement WindowBar(ScheduledInterview item, DateTimeOffset week)
    {
        var host = new Grid { Height = 22 };
        var color = ColorOf(item);
        var bar = new Border
        {
            Height = 22, CornerRadius = new CornerRadius(5), Background = Brush(Alpha(color, 0.10)), Padding = new Thickness(4, 0, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = HStack(6, Fill(color, 1, 2, 12), Sans(item.Company + " " + item.Label + "开放", 10, Txt, Medium)),
        }.OnTap(() => Open(item), item.Company + " " + item.Label + "开放");
        host.Children.Add(bar);
        host.SizeChanged += (_, e) =>
        {
            var width = e.NewSize.Width / 7;
            var first = Math.Max(0, (int)(Local(StartOfDay(item.Start)).Date - Local(week).Date).TotalDays);
            var last = Math.Min(6, (int)(Local(StartOfDay(item.End.AddSeconds(-1))).Date - Local(week).Date).TotalDays);
            bar.Width = Math.Max(width, (last - first + 1) * width) - 4;
            bar.Margin = new Thickness(first * width + 2, 0, 0, 0);
        };
        return host;
    }

    FrameworkElement TimeGrid(DateTimeOffset week)
    {
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var canvas = new Canvas { Height = HourHeight * 24 };
        scroll.Content = canvas;
        void Build(double total)
        {
            canvas.Children.Clear();
            canvas.Width = total;
            var width = (total - Gutter) / 7;
            for (var hour = 0; hour < 24; hour++)
            {
                Put(canvas, Number($"{hour:00}:00", 10, Fnt, Medium), 0, hour * HourHeight + 3);
                Put(canvas, new Rectangle { Width = Math.Max(0, total - Gutter), Height = 1, Fill = Brush(V3.Line) }, Gutter, hour * HourHeight);
            }
            for (var index = 0; index < 7; index++) Put(canvas, DayColumn(Plus(week, index), width), Gutter + index * width, 0);
            for (var index = 0; index < 7; index++) DayEvents(canvas, Plus(week, index), index, width);
            if (Enumerable.Range(0, 7).Cast<int?>().FirstOrDefault(i => IsToday(Plus(week, i!.Value))) is { } todayIndex)
            {
                var now = Local(DateTimeOffset.Now);
                Put(canvas, new Rectangle { Width = width, Height = 1.5, Fill = Brush(Red) }, Gutter + todayIndex * width, (now.Hour * 60 + now.Minute) / 60.0 * HourHeight);
            }
        }
        var first = true;
        scroll.SizeChanged += (_, e) =>
        {
            if (Math.Abs(e.NewSize.Width - e.PreviousSize.Width) < 0.5 && !first) return;
            Build(e.NewSize.Width);
            if (!first) return;
            first = false;
            // 与 Mac `.task(id: week)` 一样：滚到本周最早一场所在小时（不晚于 8 点）
            var earliest = Visible.Where(x => !x.OpenWindow && x.Start >= week && x.Start < Plus(week, 7)).Select(x => Local(x.Start).Hour).DefaultIfEmpty(8).Min();
            scroll.DispatcherQueue.TryEnqueue(() => scroll.ChangeView(null, Math.Min(8, earliest) * HourHeight, null, true));
        };
        return scroll;
    }

    static void Put(Canvas canvas, FrameworkElement element, double x, double y)
    {
        Canvas.SetLeft(element, x);
        Canvas.SetTop(element, y);
        canvas.Children.Add(element);
    }

    static int Snap(double y, int upper) => Math.Min(upper, Math.Max(0, (int)Math.Round(y / HourHeight * 60 / 15, MidpointRounding.AwayFromZero) * 15));

    FrameworkElement DayColumn(DateTimeOffset day, double width)
    {
        var column = new Border
        {
            Width = width, Height = HourHeight * 24, Background = Brush(Clear), BorderBrush = Brush(V3.Line), BorderThickness = new Thickness(1, 0, 0, 0), AllowDrop = true,
        };
        // 拖出一段时间新建（DragGesture minimumDistance 8）
        double? origin = null;
        column.PointerPressed += (_, e) => { origin = e.GetCurrentPoint(column).Position.Y; column.CapturePointer(e.Pointer); };
        column.PointerReleased += (_, e) =>
        {
            var y = e.GetCurrentPoint(column).Position.Y;
            column.ReleasePointerCapture(e.Pointer);
            if (origin is not { } start || Math.Abs(y - start) < 8) { origin = null; return; }
            origin = null;
            var from = At(day, Snap(Math.Min(start, y), 1425));
            var until = At(day, Math.Max(15, Snap(Math.Max(start, y), 1439)));
            if (until > from) Create(from, until);
        };
        column.DoubleTapped += (_, e) => { e.Handled = true; var from = At(day, Snap(e.GetPosition(column).Y, 1425)); Create(from, from.AddSeconds(1800)); };
        column.DragOver += (_, e) => e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Move;
        column.Drop += async (_, e) =>
        {
            if (!e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text)) return;
            var y = e.GetPosition(column).Y;
            var id = await e.DataView.GetTextAsync();
            if (_interviews.FirstOrDefault(x => x.Id == id) is not { } original || original.Timed is not { Editable: true } item) return;
            var from = At(day, Snap(y, 1425));
            Move(original, item.OpenWindow ? "answer-plan" : "reschedule", from, from + (item.End - item.Start));
        };
        return column;
    }

    void DayEvents(Canvas canvas, DateTimeOffset day, int index, double width)
    {
        var next = Plus(day, 1);
        var events = Visible.Select(x => x.Timed).OfType<ScheduledInterview>().Where(x => x.Overlaps(day, next)).ToList();
        var lanes = ScheduleCalendar.Lanes(events);
        foreach (var item in events)
        {
            var lane = lanes.TryGetValue(item.Id, out var value) ? value : (0, 1);
            var start = item.Start > day ? item.Start : day;
            var end = item.End < next ? item.End : next;
            var local = Local(start);
            var minute = local.Hour * 60 + local.Minute;
            var height = Math.Max(22, (end - start).TotalSeconds / 3600 * HourHeight) - 4;
            var color = ColorOf(item);
            var selected = _selectedId == item.Id;
            // `.interview-calendar-event-stack`：时间 10 着色 → 标题 11.5 Medium → 次要 10，左侧 2px 色条
            var stack = VStack(2,
                Number(Format(item.Start, "HH:mm") + "–" + Format(item.End, "HH:mm"), 10, color, Medium).Frame(height: 12),
                Sans(item.Company + " · " + item.Label, 11.5, Txt, Medium).Frame(height: 15));
            if (height >= 51) stack.Children.Add(Sans(item.OpenWindow ? "我的作答计划" : MeetingLabel(item.Raw), 10, Sub).Frame(height: 12));
            stack.Padding = new Thickness(12, 5, 6, 5);
            var block = new Grid
            {
                Width = Math.Max(0, width / lane.Item2 - 4), Height = height, CornerRadius = new CornerRadius(6), Background = Brush(Mix(V3.White, color, 0.10)),
                BorderBrush = Brush(selected ? Blue : Clear), BorderThickness = new Thickness(1.5),
            };
            block.Children.Add(stack);
            block.Children.Add(new Border { Width = 2, CornerRadius = new CornerRadius(1), Background = Brush(color), Margin = new Thickness(4, 6, 0, 6), HorizontalAlignment = HorizontalAlignment.Left });
            if (item.Editable)
            {
                block.Children.Add(ResizeHandle(item, top: true));
                block.Children.Add(ResizeHandle(item, top: false));
                block.CanDrag = true;
                block.DragStarting += (_, e) => e.Data.SetText(item.Id);
            }
            block.DoubleTapped += (_, e) => { e.Handled = true; Open(item); };
            block.Tapped += (_, e) => { e.Handled = true; _selectedId = item.Id; Render(); };
            block.PointerPressed += (_, e) => e.Handled = true;
            block.PointerReleased += (_, e) => e.Handled = true;
            Put(canvas, block, Gutter + index * width + lane.Item1 * width / lane.Item2 + 2, minute / 60.0 * HourHeight + 2);
        }
    }

    FrameworkElement ResizeHandle(ScheduledInterview item, bool top)
    {
        var handle = new Grid { Height = 5, VerticalAlignment = top ? VerticalAlignment.Top : VerticalAlignment.Bottom, Background = Brush(Clear) };
        handle.Children.Add(new Border { Width = 18, Height = 2, CornerRadius = new CornerRadius(1), Background = Brush(Alpha(ColorOf(item), 0.6)), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        ToolTipService.SetToolTip(handle, top ? "拖动调整开始时间" : "拖动调整结束时间");
        handle.ManipulationMode = ManipulationModes.TranslateY;
        handle.ManipulationStarted += (_, e) => e.Handled = true;
        handle.ManipulationCompleted += (_, e) =>
        {
            e.Handled = true;
            var minutes = (int)Math.Round(e.Cumulative.Translation.Y / HourHeight * 60 / 15, MidpointRounding.AwayFromZero) * 15;
            var from = top ? item.Start.AddMinutes(minutes) : item.Start;
            var until = top ? item.End : item.End.AddMinutes(minutes);
            if ((until - from).TotalSeconds >= 900) Move(_interviews.FirstOrDefault(x => x.Id == item.Id) ?? item, item.OpenWindow ? "answer-plan" : "reschedule", from, until);
        };
        handle.PointerPressed += (_, e) => e.Handled = true;
        return handle;
    }
}
