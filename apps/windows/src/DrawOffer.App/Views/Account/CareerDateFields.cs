using System.Text.RegularExpressions;
using DrawOffer.App.DesignSystem;
using DrawOffer.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using static DrawOffer.App.DesignSystem.V3;

namespace DrawOffer.App.Views.Account;

/// <summary>
/// 求职画像里的日期输入（Windows 稿 01 页 03.05–03.08）：触发器同 CalendarDatePicker（32 高输入框 + 右侧日历图标）。
/// 出生日期在同一个 Flyout 里先选年月（03.05，标题年份可点开 12 年网格 03.06）、再选日（03.07）；
/// 经历的开始 / 结束时间只选年月（03.08 MonthCalendar：‹ 本月 ›，底部「清除」，结束时间多「至今」）。
/// 存的格式不变：出生日期 YYYY-MM-DD，经历 YYYY-MM 或「至今」。
/// </summary>
static class DateFields
{
    public const string Present = "至今";
    const double Width = 236;

    static string Pad(int value) => value.ToString("00");

    /// <summary>读出简历里常见的年月写法：2023-09、2023.9、2023/09、2023年9月。</summary>
    public static (int Year, int Month)? YearMonthOf(string value)
    {
        var match = Regex.Match(value.Trim(), @"^(\d{4})\s*[-./年]\s*(\d{1,2})");
        if (!match.Success) return null;
        var month = int.Parse(match.Groups[2].Value);
        return month is >= 1 and <= 12 ? (int.Parse(match.Groups[1].Value), month) : null;
    }

    public static (int Year, int Month, int Day)? DateOf(string value)
    {
        var match = Regex.Match(value.Trim(), @"^(\d{4})\s*[-./年]\s*(\d{1,2})\s*[-./月]\s*(\d{1,2})");
        if (!match.Success) return null;
        int year = int.Parse(match.Groups[1].Value), month = int.Parse(match.Groups[2].Value), day = int.Parse(match.Groups[3].Value);
        return month is >= 1 and <= 12 && day >= 1 && day <= DateTime.DaysInMonth(year, month) ? (year, month, day) : null;
    }

    static Border Trigger(string label, string value, string placeholder)
    {
        var trigger = CareerProfileView.FieldBox(Sans(value.Length == 0 ? placeholder : value, 14, value.Length == 0 ? Fnt2 : Txt), Icon("calendar", 13, Sub));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(trigger, $"{label}：{(value.Length == 0 ? "未填" : value)}");
        return trigger;
    }

    /// <summary>03.05–03.07 出生日期：先选年月，选月份后原地换成该月日历，点日期保存并关闭。</summary>
    public static Border Birth(string label, string value, Action<string> commit)
    {
        var trigger = Trigger(label, value, "选择日期");
        trigger.OnTap(() =>
        {
            var host = new ContentControl { Width = Width };
            Flyout? flyout = null;
            void Months() => host.Content = MonthGrid(DateOf(value) is { } d ? (d.Year, d.Month) : null, false, (year, month) => Days(year, month), null);
            void Days(int year, int month) => host.Content = DayGrid(year, month, DateOf(value), Months, day =>
            {
                var next = $"{year}-{Pad(month)}-{Pad(day)}";
                if (next != value) commit(next);
                flyout?.Hide();
            }, Days);
            Months();
            flyout = V3Popover.Show(trigger, host, FlyoutPlacementMode.BottomEdgeAlignedLeft, 12);
        }, label);
        return trigger;
    }

    /// <summary>03.08 经历开始 / 结束时间：选年月即保存；底部「清除」，结束时间多「至今」。</summary>
    public static Border YearMonth(string label, string value, bool allowPresent, Action<string> commit)
    {
        var trigger = Trigger(label, value, "选择年月");
        trigger.OnTap(() =>
        {
            Flyout? flyout = null;
            void Pick(string next) { if (next != value) commit(next); flyout?.Hide(); }
            var clear = Sans("清除", 12, value.Length == 0 ? Fnt2 : Fnt).OnTap(() => { if (value.Length > 0) Pick(""); }, "清除");
            UIElement? present = allowPresent
                ? new V3Button(Present, () => Pick(Present), value == Present ? V3Button.Kind.Dark : V3Button.Kind.Ghost, height: 24)
                : null;
            var footer = new Border
            {
                BorderBrush = Brush(Line), BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(4, 10, 0, 0), Margin = new Thickness(0, 8, 0, 0),
                Child = present is null ? clear : Spread(clear, present, 12),
            };
            var grid = MonthGrid(YearMonthOf(value), true, (year, month) => Pick($"{year}-{Pad(month)}"), footer);
            flyout = V3Popover.Show(trigger, new ContentControl { Width = Width, Content = grid }, FlyoutPlacementMode.BottomEdgeAlignedLeft, 12);
        }, label);
        return trigger;
    }

    /// <summary>年月网格：顶部「2027 年」可点开 12 年网格；右侧 ‹ 本月 ›；3×4 月份，选中蓝底白字、圆角 4。</summary>
    static StackPanel MonthGrid((int Year, int Month)? selected, bool showThisMonth, Action<int, int> pick, UIElement? footer)
    {
        var root = new StackPanel();
        var year = selected?.Year ?? Beijing.Now.Year;
        var years = false;
        int Page() => year - (((year - 2000) % 12) + 12) % 12;
        void Render()
        {
            root.Children.Clear();
            var title = HStack(4, Label(years ? $"{Page()} – {Page() + 11}" : $"{year} 年", 13, Txt, Semibold), Sans(years ? "▴" : "▾", 10, Faint))
                .OnTap(() => { years = !years; Render(); }, years ? "收起年份" : "选择年份");
            var nav = HStack(2,
                Arrow("chevron.left", () => { year -= years ? 12 : 1; Render(); }),
                showThisMonth && !years ? Label("本月", 12, Txt, Medium).Pad(6, 0, 6, 0).Align(v: VerticalAlignment.Center).OnTap(() => { var now = Beijing.Now; pick(now.Year, now.Month); }, "本月") : null,
                Arrow("chevron.right", () => { year += years ? 12 : 1; Render(); }));
            root.Children.Add(Spread(title.Align(v: VerticalAlignment.Center), nav, 8).Frame(height: 24).Pad(4, 0, 0, 0));
            var grid = new Grid { ColumnSpacing = 4, RowSpacing = 4, Margin = new Thickness(0, 12, 0, 0) };
            for (var c = 0; c < 3; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
            for (var r = 0; r < 4; r++) grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(34) });
            for (var i = 0; i < 12; i++)
            {
                Border cell;
                if (years)
                {
                    var value = Page() + i;
                    cell = Cell(value.ToString(), value == year, () => { year = value; years = false; Render(); }, 4);
                }
                else
                {
                    var month = i + 1;
                    cell = Cell($"{month} 月", selected is { } s && s.Year == year && s.Month == month, () => pick(year, month), 4);
                }
                Microsoft.UI.Xaml.Controls.Grid.SetRow(cell, i / 3);
                Microsoft.UI.Xaml.Controls.Grid.SetColumn(cell, i % 3);
                grid.Children.Add(cell);
            }
            root.Children.Add(grid);
            if (footer is not null && !years) root.Children.Add(footer);
        }
        Render();
        return root;
    }

    /// <summary>03.07 选日：‹ [2003 年 5 月 ⌄] ›，周一开头；月外日期 #B5B5B0，选中蓝底。</summary>
    static StackPanel DayGrid(int year, int month, (int Year, int Month, int Day)? selected, Action back, Action<int> pick, Action<int, int> shift)
    {
        var lead = ((int)new DateTime(year, month, 1).DayOfWeek + 6) % 7;
        var count = DateTime.DaysInMonth(year, month);
        var previous = month == 1 ? DateTime.DaysInMonth(year - 1, 12) : DateTime.DaysInMonth(year, month - 1);
        var total = (lead + count + 6) / 7 * 7;
        void Shift(int delta)
        {
            var m = month + delta; var y = year;
            if (m < 1) { m = 12; y--; } else if (m > 12) { m = 1; y++; }
            shift(y, m);
        }
        var title = new Border
        {
            Height = 22, Padding = new Thickness(8, 0, 8, 0), CornerRadius = new CornerRadius(4), Background = Brush(V3.Field),
            Child = HStack(4, Label($"{year} 年 {month} 月", 13, Txt, Semibold), Icon("chevron.down", 8, Fnt)).Align(v: VerticalAlignment.Center),
        }.OnTap(back, "重新选择年月");
        var head = Columns(0, (Auto, Arrow("chevron.left", () => Shift(-1))), (Star(), title.Align(HorizontalAlignment.Center)), (Auto, Arrow("chevron.right", () => Shift(1))));
        var grid = new Grid { Margin = new Thickness(0, 8, 0, 0) };
        for (var c = 0; c < 7; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star() });
        var rows = total / 7 + 1;
        for (var r = 0; r < rows; r++) grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(r == 0 ? 24 : 30) });
        string[] week = ["一", "二", "三", "四", "五", "六", "日"];
        for (var c = 0; c < 7; c++)
        {
            var label = Sans(week[c], 12, Fnt).Align(HorizontalAlignment.Center, VerticalAlignment.Center);
            Microsoft.UI.Xaml.Controls.Grid.SetColumn(label, c);
            grid.Children.Add(label);
        }
        for (var index = 0; index < total; index++)
        {
            var day = index - lead + 1;
            FrameworkElement cell = day < 1 || day > count
                ? Sans((day < 1 ? previous + day : day - count).ToString(), 12, Hex(0xB5B5B0)).Align(HorizontalAlignment.Center, VerticalAlignment.Center)
                : Cell(day.ToString(), selected is { } s && s.Year == year && s.Month == month && s.Day == day, () => pick(day), 4, 12);
            Microsoft.UI.Xaml.Controls.Grid.SetRow(cell, index / 7 + 1);
            Microsoft.UI.Xaml.Controls.Grid.SetColumn(cell, index % 7);
            grid.Children.Add(cell);
        }
        return VStack(0, head.Frame(height: 24), grid);
    }

    static V3IconButton Arrow(string symbol, Action action) => new(symbol, symbol == "chevron.left" ? "上一页" : "下一页", action, 24, 11);

    /// <summary>网格单元：悬停只加很浅的底（不是灰色大块），选中项蓝底白字。</summary>
    static Border Cell(string title, bool on, Action action, double radius, double size = 13)
    {
        var cell = new Border
        {
            CornerRadius = new CornerRadius(radius), Background = Brush(on ? Blue : Clear), Margin = new Thickness(1),
            Child = Sans(title, size, on ? White : Txt, on ? Medium : (Windows.UI.Text.FontWeight?)null).Align(HorizontalAlignment.Center, VerticalAlignment.Center),
        };
        if (!on) cell.OnHover(h => cell.Background = Brush(h ? Alpha(Txt, 0.04) : Clear));
        return cell.OnTap(action, title);
    }
}
